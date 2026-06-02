import Cocoa
import SwiftUI

// Feature 6 — Apple-style "clean sectioned" chat, rendered in SwiftUI and hosted
// in an AppKit window. Driven by the unchanged ACPClient (QuickChat.swift).

// MARK: - Models

enum ChatRole { case user, assistant }

struct ToolEvent: Identifiable {
    let id: String
    let kind: String
    var title: String
    enum Status { case running, done, failed }
    var status: Status
}

/// A single turn. ObservableObject so streaming mutations re-render only this row.
final class ChatMessage: ObservableObject, Identifiable {
    let id = UUID()
    let role: ChatRole
    @Published var text: String
    @Published var thoughts: String = ""
    @Published var tools: [ToolEvent] = []
    @Published var thinkingSeconds: Int? = nil   // set once thinking ends
    init(role: ChatRole, text: String = "") {
        self.role = role
        self.text = text
    }
}

// MARK: - View model

final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var status: String = "connecting…"
    @Published var isReady = false
    @Published var isStreaming = false
    @Published var draft: String = ""

    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    private var current: ChatMessage?
    private var thinkingStart: Date?
    private var pendingThought = ""
    private var pendingAnswer = ""
    private var flushTimer: Timer?

    // MARK: composer → client
    func submit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !isStreaming, !t.isEmpty else { return }
        draft = ""
        messages.append(ChatMessage(role: .user, text: t))
        let assistant = ChatMessage(role: .assistant)
        messages.append(assistant)
        current = assistant
        thinkingStart = nil
        pendingThought = ""; pendingAnswer = ""
        isStreaming = true
        startFlush()
        onSend?(t)
    }

    func stop() { onStop?() }

    // MARK: client → view  (all called on main)
    func setStatus(_ s: String) {
        status = s
        isReady = (s == "ready")
    }

    func appendThought(_ s: String) {
        if thinkingStart == nil { thinkingStart = Date() }
        pendingThought += s
    }

    func appendAnswer(_ s: String) {
        freezeThinking()
        pendingAnswer += s
    }

    func addTool(id: String, kind: String, title: String) {
        flush()
        guard let a = current else { return }
        a.tools.append(ToolEvent(id: id, kind: kind, title: title, status: .running))
    }

    func updateTool(id: String, status: String) {
        guard let a = current,
              let i = a.tools.firstIndex(where: { $0.id == id }) else { return }
        switch status {
        case "completed": a.tools[i].status = .done
        case "failed":    a.tools[i].status = .failed
        default: break
        }
    }

    func finishTurn() {
        flush()
        freezeThinking()
        if let a = current {
            for i in a.tools.indices where a.tools[i].status == .running { a.tools[i].status = .done }
        }
        isStreaming = false
        stopFlush()
        current = nil
    }

    // MARK: internals
    private func freezeThinking() {
        guard let a = current, a.thinkingSeconds == nil, let start = thinkingStart else { return }
        a.thinkingSeconds = max(1, Int(Date().timeIntervalSince(start).rounded()))
    }

    private func startFlush() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.flush() }
    }
    private func stopFlush() { flushTimer?.invalidate(); flushTimer = nil }

    private func flush() {
        guard let a = current else { return }
        if !pendingThought.isEmpty { a.thoughts += pendingThought; pendingThought = "" }
        if !pendingAnswer.isEmpty { a.text += pendingAnswer; pendingAnswer = "" }
    }
}

// MARK: - Tool display helpers

func sfSymbol(for kind: String) -> String {
    switch kind {
    case "search", "fetch":  return "magnifyingglass"
    case "read":             return "doc.text"
    case "edit":             return "pencil"
    case "execute":          return "terminal"
    case "delete":           return "trash"
    case "move":             return "shippingbox"
    case "think":            return "brain"
    case "switch_mode":      return "arrow.triangle.2.circlepath"
    default:                  return "wrench.and.screwdriver"
    }
}

/// Render inline markdown (bold/italic/code/links), preserving newlines; plain fallback.
func markdownText(_ s: String) -> Text {
    if let attr = try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return Text(attr)
    }
    return Text(s)
}

func toolVerb(for kind: String) -> String {
    switch kind {
    case "search", "fetch":  return "Searching"
    case "read":             return "Reading"
    case "edit":             return "Editing"
    case "execute":          return "Running"
    case "delete":           return "Deleting"
    case "move":             return "Moving"
    case "think":            return "Thinking"
    case "switch_mode":      return "Switching mode"
    default:                  return "Working"
    }
}

// MARK: - Chat view

struct ChatView: View {
    @ObservedObject var vm: ChatViewModel
    private let hermesGradient = LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 0.96),
                                                         Color(red: 0.93, green: 0.36, blue: 0.62)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 460, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if vm.messages.isEmpty {
                        emptyState.padding(.top, 80)
                    }
                    ForEach(vm.messages) { msg in
                        TurnView(message: msg, hermesGradient: hermesGradient)
                        if msg.id != vm.messages.last?.id {
                            Divider().padding(.leading, 52).opacity(0.5)
                        }
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.vertical, 10)
            }
            .onChange(of: vm.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            // Keep pinned to the bottom while content streams in.
            .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                if vm.isStreaming { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(hermesGradient)
            Text("Ask Hermes anything")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("It can search the web, read files, and run tools.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Hermes…", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 11).fill(.quaternary.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary, lineWidth: 1))
                    .onSubmit { vm.submit() }

                if vm.isStreaming {
                    Button(action: { vm.stop() }) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop")
                } else {
                    Button(action: { vm.submit() }) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? AnyShapeStyle(hermesGradient) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    .disabled(!canSend)
                    .help("Send")
                }
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(vm.status).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("↩ send   ⇧↩ newline").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        vm.isReady && !vm.isStreaming && !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusColor: Color {
        if vm.status.hasPrefix("error") { return .red }
        if vm.isReady { return .green }
        return .orange
    }
}

// MARK: - Turn

struct TurnView: View {
    @ObservedObject var message: ChatMessage
    let hermesGradient: LinearGradient
    @State private var expandThinking = true

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                Text(message.role == .user ? "You" : "Hermes")
                    .font(.system(size: 12.5, weight: .semibold))

                if message.role == .assistant {
                    if !message.thoughts.isEmpty { thinking }
                    if !message.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(message.tools) { ToolRow(tool: $0) }
                        }
                    }
                }

                if !message.text.isEmpty {
                    (message.role == .assistant ? markdownText(message.text) : Text(message.text))
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(message.role == .user ? AnyShapeStyle(Color.accentColor.gradient)
                                            : AnyShapeStyle(hermesGradient))
                .frame(width: 28, height: 28)
            Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var thinking: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expandThinking.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: expandThinking ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    if let s = message.thinkingSeconds {
                        Text("Thought for \(s)s")
                    } else {
                        Text("Thinking…")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expandThinking {
                Text(message.thoughts)
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
            }
        }
        // Auto-collapse once thinking is done.
        .onChange(of: message.thinkingSeconds) { newValue in
            if newValue != nil { withAnimation(.easeInOut(duration: 0.2)) { expandThinking = false } }
        }
    }
}

// MARK: - Tool row

struct ToolRow: View {
    let tool: ToolEvent

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: sfSymbol(for: tool.kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 15)
            Text(tool.title.isEmpty ? toolVerb(for: tool.kind) : tool.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            statusIcon
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder private var statusIcon: some View {
        switch tool.status {
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red)
        }
    }
}

// MARK: - AppKit host

final class ChatWindowController: NSObject, NSWindowDelegate {
    private let hermesPath: String
    private let onClose: () -> Void
    private var client: ACPClient!
    private var window: NSWindow!
    private let vm = ChatViewModel()

    init(hermesPath: String, onClose: @escaping () -> Void) {
        self.hermesPath = hermesPath
        self.onClose = onClose
        super.init()
    }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Hermes Chat"
        window.minSize = NSSize(width: 460, height: 460)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: ChatView(vm: vm))

        client = ACPClient(hermesPath: hermesPath)
        vm.onSend = { [weak self] t in self?.client.send(t) }
        vm.onStop = { [weak self] in self?.client.cancel() }

        client.onStatus      = { [weak self] s in self?.vm.setStatus(s) }
        client.onThought     = { [weak self] t in self?.vm.appendThought(t) }
        client.onAnswer      = { [weak self] t in self?.vm.appendAnswer(t) }
        client.onToolStart   = { [weak self] id, kind, title in self?.vm.addTool(id: id, kind: kind, title: title) }
        client.onToolUpdate  = { [weak self] id, status in self?.vm.updateTool(id: id, status: status) }
        client.onSessionTitle = { [weak self] t in self?.window.title = "Hermes — \(t)" }
        client.onTurnComplete = { [weak self] _ in self?.vm.finishTurn() }
        client.start()
    }

    func windowWillClose(_ notification: Notification) {
        client?.shutdown()
        onClose()
    }
}
