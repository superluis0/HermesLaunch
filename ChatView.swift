import Cocoa
import SwiftUI

// Feature 6 — Apple-style "clean sectioned" chat, rendered in SwiftUI and hosted
// in an AppKit window. Driven by the unchanged ACPClient (QuickChat.swift).

// MARK: - Models

enum ChatRole { case user, assistant }

struct ModelOption: Identifiable, Equatable { let id: String; let name: String }
struct ChatCommand: Identifiable { var id: String { name }; let name: String; let hasInput: Bool }

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
    /// Block-parsed form of `text` for assistant turns. Computed once whenever the
    /// text changes (see `ChatViewModel.flush`) so SwiftUI layout never re-parses —
    /// re-parsing inside `View.body` on a growing stream pegged the main thread and
    /// froze the app (the markdown parser is O(n) over the whole accumulated reply).
    @Published var blocks: [MarkdownBlock] = []
    @Published var thoughts: String = ""
    @Published var tools: [ToolEvent] = []
    @Published var thinkingSeconds: Int? = nil   // set once thinking ends
    var imageThumb: NSImage? = nil
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
    @Published var models: [ModelOption] = []
    @Published var currentModel: String?
    @Published var commands: [ChatCommand] = []
    @Published var pendingImage: PendingImage?

    struct PendingImage { let base64: String; let mime: String; let thumb: NSImage?; let name: String }

    var onSend: ((_ text: String, _ images: [(base64: String, mime: String)]) -> Void)?
    var onStop: (() -> Void)?
    var onSetModel: ((String) -> Void)?          // switch the live ACP session
    var onPersistModel: ((String) -> Void)?      // write the choice to the global default

    private var current: ChatMessage?
    private var thinkingStart: Date?
    private var pendingThought = ""
    private var pendingAnswer = ""
    private var flushTimer: Timer?

    // MARK: composer → client
    func submit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let img = pendingImage
        guard isReady, !isStreaming, (!t.isEmpty || img != nil) else { return }
        draft = ""; pendingImage = nil
        let um = ChatMessage(role: .user, text: t.isEmpty ? "🖼 Image" : t)
        um.imageThumb = img?.thumb
        beginTurn(user: um)
        let images = img.map { [(base64: $0.base64, mime: $0.mime)] } ?? []
        onSend?(t, images)
    }

    /// Run a slash command (sent as a normal prompt; the ACP adapter intercepts it).
    func runCommand(_ name: String) {
        guard isReady, !isStreaming else { return }
        beginTurn(user: ChatMessage(role: .user, text: "/\(name)"))
        onSend?("/\(name)", [])
    }

    /// `persist: true` (the user picking from the in-chat dropdown) also writes the
    /// choice back to the global default model; `persist: false` (a programmatic
    /// sync from a config-side change) only switches the live session, so the two
    /// directions don't loop.
    func selectModel(_ id: String, persist: Bool = true) {
        guard id != currentModel else { return }
        currentModel = id
        onSetModel?(id)
        if persist { onPersistModel?(id) }
    }

    func attach(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        pendingImage = PendingImage(base64: data.base64EncodedString(),
                                    mime: Self.mime(for: url.pathExtension),
                                    thumb: NSImage(contentsOf: url),
                                    name: url.lastPathComponent)
    }

    private func beginTurn(user: ChatMessage) {
        messages.append(user)
        let assistant = ChatMessage(role: .assistant)
        messages.append(assistant)
        current = assistant
        thinkingStart = nil; pendingThought = ""; pendingAnswer = ""
        isStreaming = true
        startFlush()
    }

    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
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

    /// Clear the transcript and streaming state (used when a chat reconnects to a
    /// fresh ACP session). `models`/`currentModel`/`commands` are left intact — the
    /// new session repopulates them via its own callbacks.
    func reset() {
        stopFlush()
        messages.removeAll()
        current = nil
        isStreaming = false
        thinkingStart = nil
        pendingThought = ""
        pendingAnswer = ""
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
        if !pendingAnswer.isEmpty {
            a.text += pendingAnswer; pendingAnswer = ""
            // Parse here (once per content change), never in the view's layout path.
            a.blocks = MarkdownBlock.parse(a.text)
        }
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
/// Inline markdown only (bold/italic/links/code spans) → a single `Text`.
func markdownText(_ s: String) -> Text {
    if let attr = try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return Text(attr)
    }
    return Text(s)
}

// MARK: - Block-level markdown renderer
//
// AttributedString only does *inline* markdown — headings, lists, fenced code,
// and blockquotes show up as raw "##", "-", "```". This lightweight, zero-dependency
// renderer splits the text into blocks and lays each out natively, parsing inline
// formatting per-block via `markdownText`.

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case numbered([String])
    case code(String)
    case quote(String)
    case rule

    static func isBullet(_ l: String) -> Bool {
        let t = l.drop(while: { $0 == " " })
        return t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")
    }
    static func isNumbered(_ l: String) -> Bool {
        let t = l.drop(while: { $0 == " " })
        guard let dot = t.firstIndex(of: ".") else { return false }
        let num = t[t.startIndex..<dot]
        return !num.isEmpty && num.allSatisfy(\.isNumber) && t[t.index(after: dot)...].hasPrefix(" ")
    }
    static func stripMarker(_ l: String) -> String {
        var t = String(l.drop(while: { $0 == " " }))
        if let r = t.range(of: #"^([-*+]|\d+\.)\s+"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        return t
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.isEmpty { i += 1; continue }

            // Fenced code block (collect until closing fence or EOF — handles streaming).
            if line.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }   // skip closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                blocks.append(.rule); i += 1; continue
            }

            if let r = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = line[line.startIndex..<r.upperBound].filter { $0 == "#" }.count
                blocks.append(.heading(level: level, text: String(line[r.upperBound...])))
                i += 1; continue
            }

            if line.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst().drop(while: { $0 == " " })))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if isBullet(lines[i]) {
                var items: [String] = []
                while i < lines.count && isBullet(lines[i]) { items.append(stripMarker(lines[i])); i += 1 }
                blocks.append(.bullet(items)); continue
            }

            if isNumbered(lines[i]) {
                var items: [String] = []
                while i < lines.count && isNumbered(lines[i]) { items.append(stripMarker(lines[i])); i += 1 }
                blocks.append(.numbered(items)); continue
            }

            // Paragraph: gather consecutive plain lines until a blank line or block starter.
            var para: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || t.hasPrefix("#") || t.hasPrefix(">")
                    || isBullet(lines[i]) || isNumbered(lines[i])
                    || t == "---" || t == "***" || t == "___" { break }
                para.append(t); i += 1
            }
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
        }
        return blocks
    }
}

struct MarkdownView: View {
    private let blocks: [MarkdownBlock]
    /// Render pre-parsed blocks. Parsing happens in the view model (on content
    /// change), not here, so repeated layout passes don't re-parse the whole reply.
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }
    /// Convenience for one-off, non-streaming text (parses immediately).
    init(_ source: String) { blocks = MarkdownBlock.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            markdownText(text)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(.primary)
        case .paragraph(let text):
            markdownText(text).font(.system(size: 13)).foregroundStyle(.primary)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").font(.system(size: 13)).foregroundStyle(.secondary)
                        markdownText(item).font(.system(size: 13)).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(idx + 1).").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                        markdownText(item).font(.system(size: 13)).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border.opacity(0.6)))
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(DS.accent.opacity(0.6)).frame(width: 3)
                markdownText(text).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        case .rule:
            Divider()
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: return 20; case 2: return 17; case 3: return 15; default: return 13.5 }
    }
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
    @ObservedObject private var voice = VoiceEngine.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            if !vm.models.isEmpty { modelBar; Divider().opacity(0.5) }
            if vm.messages.isEmpty {
                heroEmptyState
            } else {
                transcript
            }
            composer
        }
        .frame(minWidth: 460, minHeight: 460)
        .background(chatBackground)
    }

    /// Themed background with a faint accent glow behind the hero (Nous-style texture).
    private var chatBackground: some View {
        ZStack {
            DS.bg
            RadialGradient(colors: [DS.accent.opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 520)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var modelBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "cpu").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { vm.currentModel ?? vm.models.first?.id ?? "" },
                set: { vm.selectModel($0) }
            )) {
                ForEach(vm.models) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(maxWidth: 260)
            .disabled(vm.isStreaming)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.messages) { msg in
                        TurnView(message: msg, hermesGradient: DS.brandGradient)
                        if msg.id != vm.messages.last?.id {
                            Divider().padding(.leading, 52).opacity(0.5)
                        }
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.vertical, 10)
            }
            .onChange(of: vm.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            // Keep pinned to the bottom while content streams in.
            .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                if vm.isStreaming { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }

    private var heroEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("HERMES AGENT")
                .font(.system(size: 54, weight: .regular, design: .serif))
                .tracking(3)
                .foregroundStyle(DS.textPrimary)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let img = vm.pendingImage { attachmentChip(img) }
            HStack(alignment: .center, spacing: 6) {
                plusMenu
                TextField("Let's get to work...", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .foregroundStyle(DS.textPrimary)
                    .onSubmit { vm.submit() }
                micButton
                waveformButton
                sendOrStopButton
            }
            .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(DS.border, lineWidth: 1))

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(vm.status).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("↩ send   ⇧↩ newline").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Left "+" — attach an image and access slash commands.
    private var plusMenu: some View {
        Menu {
            Button { pickImage() } label: { Label("Attach image…", systemImage: "photo") }
            if !vm.commands.isEmpty {
                Divider()
                ForEach(vm.commands) { c in
                    Button("/\(c.name)") {
                        if c.hasInput { vm.draft = "/\(c.name) " } else { vm.runCommand(c.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(vm.isStreaming || !vm.isReady)
        .help("Attach & commands")
    }

    /// Push-to-talk dictation into the draft (local Parakeet via VoiceEngine).
    @ViewBuilder private var micButton: some View {
        if settings.voice.dictationEnabled {
            Button(action: toggleDictation) {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 16))
                    .foregroundStyle(isRecording ? DS.danger : DS.textSecondary)
                    .scaleEffect(isRecording ? 1.0 + CGFloat(voice.level) * 0.4 : 1)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Stop dictation" : "Dictate")
        }
    }

    /// Toggle spoken replies (hands-free voice mode).
    private var waveformButton: some View {
        Button {
            var v = settings.voice; v.speakReplies.toggle(); settings.voice = v
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 16))
                .foregroundStyle(settings.voice.speakReplies ? AnyShapeStyle(DS.accent)
                                                              : AnyShapeStyle(DS.textSecondary))
        }
        .buttonStyle(.plain)
        .help(settings.voice.speakReplies ? "Spoken replies on" : "Speak replies")
    }

    @ViewBuilder private var sendOrStopButton: some View {
        if vm.isStreaming {
            Button(action: { vm.stop() }) {
                Image(systemName: "stop.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain).foregroundStyle(DS.textSecondary).help("Stop")
        } else {
            Button(action: { vm.submit() }) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? AnyShapeStyle(DS.brandGradient) : AnyShapeStyle(DS.textTertiary.opacity(0.5)))
            .disabled(!canSend)
            .help("Send")
        }
    }

    private var isRecording: Bool {
        if case .recording = voice.status { return true } else { return false }
    }

    private func toggleDictation() {
        let v = VoiceEngine.shared
        if case .recording = v.status {
            v.stopDictation { [vm] text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { vm.draft = vm.draft.isEmpty ? t : vm.draft + " " + t }
            }
        } else {
            v.startDictation()
        }
    }

    private func attachmentChip(_ img: ChatViewModel.PendingImage) -> some View {
        HStack(spacing: 7) {
            if let t = img.thumb {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text(img.name).font(.system(size: 11)).lineLimit(1)
            Spacer()
            Button { vm.pendingImage = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private func pickImage() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.allowedFileTypes = ["png", "jpg", "jpeg", "gif", "webp"]
        if p.runModal() == .OK, let url = p.url { vm.attach(url: url) }
    }

    private var canSend: Bool {
        vm.isReady && !vm.isStreaming &&
            (!vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.pendingImage != nil)
    }

    private var statusColor: Color {
        if vm.status.hasPrefix("error") { return DS.danger }
        if vm.isReady { return DS.success }
        return DS.warning
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
                    if message.role == .assistant {
                        MarkdownView(blocks: message.blocks)
                    } else {
                        Text(message.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let t = message.imageThumb {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .onChange(of: message.thinkingSeconds) { _, newValue in
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

/// A live chat session: owns the ChatViewModel and its ACPClient and wires them
/// together. Reusable in any container (the unified app's Chat pane embeds it;
/// it no longer carries its own window).
final class ChatSession {
    let vm = ChatViewModel()
    private let hermesPath: String
    private let persistModel: (String) -> Void
    private var client: ACPClient
    private var started = false

    /// Called when the agent reports a session title (for a window/pane label).
    var onTitle: ((String) -> Void)?

    /// `persistModel` writes an in-chat model pick back to the global default
    /// (no-op by default so the session works without the unified-app plumbing).
    init(hermesPath: String, persistModel: @escaping (String) -> Void = { _ in }) {
        self.hermesPath = hermesPath
        self.persistModel = persistModel
        client = ACPClient(hermesPath: hermesPath)
        wire()
    }

    /// Bind the view model and the current ACP client together. Re-runnable so a
    /// `restart()` can rebind a freshly created client.
    private func wire() {
        vm.onSend = { [weak self] t, imgs in self?.client.send(t, images: imgs) }
        vm.onStop = { [weak self] in self?.client.cancel() }
        vm.onSetModel = { [weak self] id in self?.client.setModel(id) }
        vm.onPersistModel = { [weak self] id in self?.persistModel(id) }

        client.onStatus       = { [weak self] s in self?.vm.setStatus(s) }
        client.onThought      = { [weak self] t in self?.vm.appendThought(t) }
        client.onAnswer       = { [weak self] t in self?.vm.appendAnswer(t) }
        client.onToolStart    = { [weak self] id, kind, title in self?.vm.addTool(id: id, kind: kind, title: title) }
        client.onToolUpdate   = { [weak self] id, status in self?.vm.updateTool(id: id, status: status) }
        client.onSessionTitle = { [weak self] t in self?.onTitle?(t) }
        client.onTurnComplete = { [weak self] _ in self?.vm.finishTurn() }
        client.onModels       = { [weak self] models, current in self?.vm.models = models; self?.vm.currentModel = current }
        client.onCommands     = { [weak self] cmds in self?.vm.commands = cmds }
    }

    /// Connect to `hermes acp` (idempotent).
    func start() { guard !started else { return }; started = true; client.start() }
    func shutdown() { client.shutdown() }

    /// True until the user has sent anything — restarting here loses no work.
    var isEmpty: Bool { vm.messages.isEmpty }

    /// Switch this chat's model in place via ACP `session/set_model`, updating the
    /// in-chat picker selection. Best-effort: reliably switches among the running
    /// session's available models (same provider/account).
    func switchModel(_ modelId: String) { vm.selectModel(modelId, persist: false) }

    /// Tear down and reconnect a fresh ACP session, which adopts the current global
    /// default model/provider from `hermes config`. Clears the (empty) transcript.
    func restart() {
        client.shutdown()
        vm.reset()
        client = ACPClient(hermesPath: hermesPath)
        wire()
        started = true
        client.start()
    }
}

// MARK: - Multiple chats

/// One open chat: its live ChatSession plus a display title (the agent reports a
/// title once the conversation has content; until then it's "New Chat").
final class ChatTab: Identifiable, ObservableObject {
    let id = UUID()
    let session: ChatSession
    @Published var title: String = "New Chat"

    init(hermesPath: String, persistModel: @escaping (String) -> Void = { _ in }) {
        session = ChatSession(hermesPath: hermesPath, persistModel: persistModel)
        session.onTitle = { [weak self] t in
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.title = trimmed.isEmpty ? "New Chat" : trimmed
        }
        session.start()
    }
}

/// Manages the set of open chats and which one is active. Each chat is an
/// independent `hermes acp` session, so several can run side by side.
final class ChatsModel: ObservableObject {
    @Published var tabs: [ChatTab] = []
    @Published var activeId: UUID?
    private let hermesPath: String
    private let persistModel: (String) -> Void

    init(hermesPath: String, persistModel: @escaping (String) -> Void = { _ in }) {
        self.hermesPath = hermesPath
        self.persistModel = persistModel
        newChat()
    }

    var active: ChatTab? { tabs.first { $0.id == activeId } }

    func newChat() {
        let tab = ChatTab(hermesPath: hermesPath, persistModel: persistModel)
        tabs.append(tab)
        activeId = tab.id
    }

    func select(_ id: UUID) { activeId = id }

    /// Adopt a newly-chosen global default model across every open chat. Empty
    /// chats reconnect cleanly (a fresh ACP session picks up the new model and
    /// provider); chats that already have messages switch in place, best-effort.
    func applyDefaultModel(_ modelId: String) {
        for tab in tabs {
            if tab.session.isEmpty { tab.session.restart() }
            else { tab.session.switchModel(modelId) }
        }
    }

    func close(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].session.shutdown()
        let wasActive = activeId == id
        tabs.remove(at: idx)
        if tabs.isEmpty {
            newChat()                                   // always keep at least one chat
        } else if wasActive {
            activeId = tabs[min(idx, tabs.count - 1)].id
        }
    }
}

/// The Chat pane: a tab strip of open chats above the active conversation.
struct ChatContainerView: View {
    @ObservedObject var model: ChatsModel

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().opacity(0.5)
            if let active = model.active {
                ChatView(vm: active.session.vm)
                    .id(active.id)   // swap view identity per chat (fresh scroll/state)
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    ChatTabChip(tab: tab,
                                active: tab.id == model.activeId,
                                onSelect: { model.select(tab.id) },
                                onClose: { model.close(tab.id) })
                }
                Button(action: { model.newChat() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.textSecondary)
                .help("New chat")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(DS.surface)
    }
}

private struct ChatTabChip: View {
    @ObservedObject var tab: ChatTab
    let active: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left").font(.system(size: 10))
            Text(tab.title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hover || active ? 0.6 : 0.0)
            .help("Close chat")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(active ? DS.textPrimary : DS.textSecondary)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(active ? DS.accent.opacity(0.18) : DS.surfaceElevated.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(active ? DS.accent.opacity(0.5) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hover = $0 }
    }
}
