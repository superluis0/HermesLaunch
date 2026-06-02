import Cocoa

// MARK: - ACP client
//
// Drives `hermes acp` (Agent Client Protocol) as a subprocess over newline-delimited
// JSON-RPC 2.0. Surfaces streaming thinking, tool/search activity, and the answer.
//
// Verified wire facts (Hermes 0.15.1, acp lib):
//   • keys are camelCase (sessionId, sessionUpdate, toolCallId, stopReason)
//   • initialize → session/new → session/prompt;  prompt response carries {stopReason}
//   • notifications: method "session/update", params {sessionId, update{sessionUpdate, …}}
//       agent_thought_chunk / agent_message_chunk → content.text
//       tool_call (start)  → toolCallId, kind, title
//       tool_call_update   → toolCallId, status (completed|failed|…)
//   • server may REQUEST session/request_permission — must reply or the turn hangs.

struct ACPError: Error { let message: String }

final class ACPClient {
    private let hermesPath: String
    private var process: Process?
    private var stdinHandle: FileHandle?

    private let ioQueue = DispatchQueue(label: "ai.hermes.acp.io")   // serializes ids/pending/writes/parsing
    private var readBuffer = Data()
    private var nextId = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var sessionId: String?

    // Callbacks — always delivered on the main thread.
    var onStatus: ((String) -> Void)?                       // "connecting…", "ready", "disconnected", "error: …"
    var onThought: ((String) -> Void)?                      // streamed thinking text
    var onAnswer: ((String) -> Void)?                       // streamed answer text
    var onToolStart: ((_ id: String, _ kind: String, _ title: String) -> Void)?
    var onToolUpdate: ((_ id: String, _ status: String) -> Void)?
    var onTurnComplete: ((_ stopReason: String) -> Void)?
    var onSessionTitle: ((String) -> Void)?

    init(hermesPath: String) { self.hermesPath = hermesPath }

    // MARK: Lifecycle

    func start() {
        emitStatus("connecting…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hermesPath)
        p.arguments = ["acp"]

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        stdinHandle = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self = self else { return }
            self.ioQueue.async { self.ingest(d) }
        }
        // Drain stderr (ACP logs go there) so the pipe never blocks the child.
        errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }

        p.terminationHandler = { [weak self] _ in self?.emitStatus("disconnected") }

        do { try p.run() } catch {
            emitStatus("error: \(error.localizedDescription)")
            return
        }
        process = p

        // Handshake: initialize → session/new → (best-effort) set_mode dont_ask.
        request("initialize", ["protocolVersion": 1, "clientCapabilities": [:]]) { [weak self] res in
            guard let self = self else { return }
            if case .failure(let e) = res { self.emitStatus("error: \(e.localizedDescription)"); return }
            self.request("session/new", ["cwd": NSHomeDirectory(), "mcpServers": []]) { res2 in
                switch res2 {
                case .failure(let e):
                    self.emitStatus("error: \(e.localizedDescription)")
                case .success(let r):
                    guard let sid = r["sessionId"] as? String else {
                        self.emitStatus("error: no sessionId"); return
                    }
                    self.sessionId = sid
                    // Reduce approval prompts; harmless if unsupported.
                    self.notify("session/set_mode", ["sessionId": sid, "modeId": "dont_ask"])
                    self.emitStatus("ready")
                }
            }
        }
    }

    func send(_ text: String) {
        guard let sid = sessionId else { return }
        request("session/prompt", ["sessionId": sid,
                                    "prompt": [["type": "text", "text": text]]]) { [weak self] res in
            var reason = "end_turn"
            if case .success(let r) = res { reason = r["stopReason"] as? String ?? "end_turn" }
            self?.main { self?.onTurnComplete?(reason) }
        }
    }

    func cancel() {
        guard let sid = sessionId else { return }
        notify("session/cancel", ["sessionId": sid])
    }

    func shutdown() {
        if let sid = sessionId { notify("session/cancel", ["sessionId": sid]) }
        let handle = stdinHandle
        let proc = process
        ioQueue.async { try? handle?.close() }
        proc?.terminate()
        process = nil
        sessionId = nil
    }

    var isReady: Bool { sessionId != nil }

    // MARK: JSON-RPC plumbing  (all on ioQueue)

    private func request(_ method: String, _ params: [String: Any],
                         _ completion: @escaping (Result<[String: Any], Error>) -> Void) {
        ioQueue.async {
            let id = self.nextId; self.nextId += 1
            self.pending[id] = completion
            self.writeLine(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        ioQueue.async { self.writeLine(["jsonrpc": "2.0", "method": method, "params": params]) }
    }

    private func writeLine(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var line = data; line.append(0x0A)
        do { try stdinHandle?.write(contentsOf: line) } catch { /* child gone */ }
    }

    private func ingest(_ d: Data) {
        readBuffer.append(d)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<nl)
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            if lineData.isEmpty { continue }
            if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                dispatch(obj)
            }
        }
    }

    private func dispatch(_ obj: [String: Any]) {
        let hasMethod = obj["method"] != nil
        // Response to one of our requests (has id, no method).
        if let id = obj["id"] as? Int, !hasMethod {
            let cb = pending.removeValue(forKey: id)
            if let err = obj["error"] as? [String: Any] {
                cb?(.failure(ACPError(message: err["message"] as? String ?? "error")))
            } else {
                cb?(.success(obj["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        // Server→client REQUEST (has id and method) — must answer.
        if let id = obj["id"], let method = obj["method"] as? String {
            handleServerRequest(id: id, method: method, params: obj["params"] as? [String: Any] ?? [:])
            return
        }
        // Notification.
        if let method = obj["method"] as? String, method == "session/update",
           let params = obj["params"] as? [String: Any],
           let update = params["update"] as? [String: Any] {
            handleUpdate(update)
        }
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        if method == "session/request_permission" {
            // Auto-approve: pick the first option whose kind starts with "allow".
            var optionId: String?
            if let options = params["options"] as? [[String: Any]] {
                let allow = options.first { ($0["kind"] as? String)?.hasPrefix("allow") == true }
                optionId = (allow ?? options.first)?["optionId"] as? String
            }
            let outcome: [String: Any] = optionId.map { ["outcome": "selected", "optionId": $0] }
                                                  ?? ["outcome": "cancelled"]
            writeLine(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
        } else {
            // We don't advertise fs/terminal client capability — refuse so the agent uses its own tools.
            writeLine(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32601, "message": "method not supported"]])
        }
    }

    private func handleUpdate(_ u: [String: Any]) {
        guard let su = u["sessionUpdate"] as? String else { return }
        switch su {
        case "agent_thought_chunk":
            if let t = (u["content"] as? [String: Any])?["text"] as? String { main { self.onThought?(t) } }
        case "agent_message_chunk":
            if let t = (u["content"] as? [String: Any])?["text"] as? String { main { self.onAnswer?(t) } }
        case "tool_call":
            let id = u["toolCallId"] as? String ?? ""
            let kind = u["kind"] as? String ?? "other"
            let title = u["title"] as? String ?? ""
            main { self.onToolStart?(id, kind, title) }
        case "tool_call_update":
            let id = u["toolCallId"] as? String ?? ""
            let status = u["status"] as? String ?? ""
            main { self.onToolUpdate?(id, status) }
        case "session_info_update":
            if let t = u["title"] as? String { main { self.onSessionTitle?(t) } }
        default:
            break
        }
    }

    private func emitStatus(_ s: String) { main { self.onStatus?(s) } }
    private func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }
}
