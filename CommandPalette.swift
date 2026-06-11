import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Command Palette
//
// A Spotlight/Raycast-style floating panel summoned by a global hotkey (default
// ⌥Space). Fuzzy-search across app commands, or type a question and press ⏎ to
// get a streamed answer inline via the same `hermes acp` client that powers Quick
// Chat. This is the cohesion spine — later features register commands here.

// MARK: Command model

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String = ""
    var systemImage: String = "command"
    /// If true, running the command leaves the palette open (e.g. inline AI).
    var keepsOpen: Bool = false
    let run: () -> Void
}

// MARK: Global hotkey (Carbon)

/// Registers a single system-wide hotkey via the Carbon Hot Key API (zero
/// third-party dependencies). Calls `onPress` on the main thread when fired.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredId: UInt32?
    private let onPress: () -> Void
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var nextId: UInt32 = 1

    init(onPress: @escaping () -> Void) { self.onPress = onPress }

    /// keyCode/modifiers are Carbon virtual key + modifier masks (e.g. optionKey).
    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        let id = GlobalHotKey.nextId; GlobalHotKey.nextId += 1
        GlobalHotKey.instances[id] = self
        registeredId = id

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let inst = GlobalHotKey.instances[hkID.id] {
                DispatchQueue.main.async { inst.onPress() }
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        let hkID = EventHotKeyID(signature: OSType(0x484B4559 /* 'HKEY' */), id: id)
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        if let id = registeredId { GlobalHotKey.instances.removeValue(forKey: id); registeredId = nil }
    }

    deinit { unregister() }
}

// MARK: Panel

private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: View model

final class PaletteViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [PaletteCommand] = []
    @Published var selection = 0

    // Inline AI state.
    @Published var asking = false
    @Published var answer = ""
    @Published var thinking = ""

    /// Drives the content scale-in on each summon (`onAppear` won't re-fire
    /// because the panel is ordered out, not closed).
    @Published var appearing = false

    // Injected by the controller.
    var commandsProvider: () -> [PaletteCommand] = { [] }
    var makeACP: () -> ACPClient? = { nil }
    var onClose: () -> Void = {}

    private var acp: ACPClient?

    func reset() {
        query = ""; selection = 0
        cancelAsk()
        recompute()
    }

    /// How many of the leading results are "recent" (empty query only) — drives
    /// the RECENT / COMMANDS section captions in the list.
    @Published var recentCount = 0

    func recompute() {
        let all = commandsProvider()
        let q = query.trimmingCharacters(in: .whitespaces)
        var matched: [PaletteCommand]
        if q.isEmpty {
            // Float recently used commands (up to 5) above the rest.
            let rank = Dictionary(uniqueKeysWithValues:
                AppSettings.shared.paletteHistory.prefix(5).enumerated().map { ($1, $0) })
            let recent = all.filter { rank[$0.id] != nil }
                .sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
            matched = recent + all.filter { rank[$0.id] == nil }
            recentCount = recent.count
        } else {
            recentCount = 0
            matched = all
                .compactMap { cmd -> (PaletteCommand, Int)? in
                    guard let s = Self.fuzzyScore(q, cmd.title) else { return nil }
                    return (cmd, s)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
            // Always offer an inline "Ask Hermes" action for free-text queries.
            matched.append(PaletteCommand(
                id: "ask",
                title: "Ask Hermes: “\(q)”",
                subtitle: "Stream an instant answer",
                systemImage: "sparkles",
                keepsOpen: true,
                run: { [weak self] in self?.ask(q) }
            ))
        }
        results = matched
        selection = min(selection, max(0, results.count - 1))
    }

    /// True when the selection last moved via arrow keys — only then should the
    /// list auto-scroll (scrolling under a hovering pointer feels broken).
    var selectionMovedByKeyboard = false

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectionMovedByKeyboard = true
        selection = (selection + delta + results.count) % results.count
    }

    func activateSelection() {
        guard results.indices.contains(selection) else { return }
        let cmd = results[selection]
        // Remember real commands so they float up next time (skip free-text asks).
        if cmd.id != "ask" {
            var history = AppSettings.shared.paletteHistory
            history.removeAll { $0 == cmd.id }
            history.insert(cmd.id, at: 0)
            AppSettings.shared.paletteHistory = history
        }
        cmd.run()
        if !cmd.keepsOpen { onClose() }
    }

    // MARK: Inline AI

    func ask(_ q: String) {
        guard !q.isEmpty, !asking else { return }   // ignore re-entrant ⏎ while a turn streams
        acp?.shutdown(); acp = nil                   // never leak a prior acp subprocess
        answer = ""; thinking = ""; asking = true
        guard let client = makeACP() else { asking = false; answer = "⚠️ Hermes unavailable"; return }
        acp = client
        client.onAnswer = { [weak self] t in self?.answer += t }
        client.onThought = { [weak self] t in self?.thinking += t }
        client.onTurnComplete = { [weak self] _ in
            self?.asking = false
            if AppSettings.shared.voice.speakReplies, let answer = self?.answer, !answer.isEmpty {
                VoiceEngine.shared.speak(answer)
            }
        }
        client.onStatus = { [weak self] s in
            if s == "ready" { client.send(q) }
            else if s.hasPrefix("error") { self?.asking = false; self?.answer = "⚠️ \(s)" }
        }
        client.start()
    }

    func cancelAsk() {
        asking = false; answer = ""; thinking = ""
        acp?.shutdown(); acp = nil
    }

    // MARK: Voice dictation (push-to-talk into the query)

    func toggleDictation() {
        let voice = VoiceEngine.shared
        if case .recording = voice.status {
            voice.stopDictation { [weak self] text in
                guard let self else { return }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { self.query = self.query.isEmpty ? t : self.query + " " + t }
                self.recompute()
            }
        } else {
            voice.startDictation()
        }
    }

    // Subsequence fuzzy score: consecutive + start-of-string bonuses, mild length penalty.
    static func fuzzyScore(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, lastMatch = -1
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += (ti == lastMatch + 1) ? 5 : 1
            if ti == 0 { score += 6 }
            lastMatch = ti; qi += 1
        }
        return qi == q.count ? score - t.count / 20 : nil
    }
}

// MARK: View

struct PaletteView: View {
    @ObservedObject var vm: PaletteViewModel
    @ObservedObject private var voice = VoiceEngine.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.4)
            if vm.asking || !vm.answer.isEmpty {
                answerPane
            } else {
                resultsList
            }
        }
        .frame(width: 680, height: 440)
        .background(HLVisualEffect(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10))
        )
        .scaleEffect(vm.appearing ? 1 : 0.97)
        .animation(DS.Motion.quick, value: vm.appearing)
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "sparkles").foregroundStyle(DS.accent).font(.system(size: 16, weight: .semibold))
            TextField("Search commands or ask Hermes…", text: $vm.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($focused)
                .onChange(of: vm.query) { vm.recompute() }
            if vm.asking { ProgressView().controlSize(.small) }
            micButton
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: 56)
    }

    @ViewBuilder private var micButton: some View {
        switch voice.status {
        case .transcribing, .loadingModel:
            ProgressView().controlSize(.small)
        default:
            Button(action: { vm.toggleDictation() }) {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isRecording ? DS.danger : .secondary)
                    .scaleEffect(isRecording ? 1.0 + CGFloat(voice.level) * 0.4 : 1)
                    .animation(DS.Motion.quick, value: voice.level)
            }
            .buttonStyle(.plain)
            .help("Dictate locally (Parakeet)")
        }
    }

    private var isRecording: Bool { if case .recording = voice.status { return true } else { return false } }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(vm.results.enumerated()), id: \.element.id) { idx, cmd in
                        if vm.recentCount > 0 {
                            if idx == 0 { sectionCaption("RECENT") }
                            else if idx == vm.recentCount { sectionCaption("COMMANDS") }
                        }
                        row(cmd, selected: idx == vm.selection)
                            .id(idx)
                            .onTapGesture { vm.selection = idx; vm.activateSelection() }
                            // Hover moves the selection (Raycast-style), reusing
                            // the selected fill as the hover affordance.
                            .onHover { if $0 { vm.selectionMovedByKeyboard = false; vm.selection = idx } }
                    }
                }
                .padding(DS.Space.sm)
            }
            .onChange(of: vm.selection) {
                if vm.selectionMovedByKeyboard { proxy.scrollTo(vm.selection, anchor: .center) }
            }
        }
    }

    private func sectionCaption(_ title: String) -> some View {
        Text(title)
            .font(DS.Typography.micro)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.md)
            .padding(.top, DS.Space.xs)
    }

    private func row(_ cmd: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: cmd.systemImage)
                .frame(width: 22)
                .foregroundStyle(selected ? DS.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title).font(DS.Typography.body)
                if !cmd.subtitle.isEmpty {
                    Text(cmd.subtitle).font(DS.Typography.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? DS.accent.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var answerPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if !vm.thinking.isEmpty {
                    Text(vm.thinking)
                        .font(DS.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Text(vm.answer.isEmpty ? "…" : vm.answer)
                    .font(DS.Typography.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Esc to dismiss")
                    .font(DS.Typography.micro).foregroundStyle(.tertiary)
                    .padding(.top, DS.Space.xs)
            }
            .padding(DS.Space.lg)
        }
    }
}

// MARK: Controller

final class PaletteController: NSObject, NSWindowDelegate {
    private var panel: PalettePanel?
    private let vm = PaletteViewModel()
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?

    /// Called each time the palette is shown — lets the owner refresh dynamic
    /// commands (recent sessions, etc.) before they're displayed.
    var onWillShow: () -> Void = {}

    func configure(commands: @escaping () -> [PaletteCommand],
                   makeACP: @escaping () -> ACPClient?) {
        vm.commandsProvider = commands
        vm.makeACP = makeACP
        vm.onClose = { [weak self] in self?.hide() }
    }

    /// Re-rank the command list (e.g. after async dynamic commands load in).
    func reloadCommands() { DispatchQueue.main.async { [weak self] in self?.vm.recompute() } }

    /// Default summon hotkey: ⌥Space (Carbon `optionKey`, virtual key 49 = Space).
    func registerHotKey(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) {
        let hk = GlobalHotKey(onPress: { [weak self] in self?.toggle() })
        hk.register(keyCode: keyCode, modifiers: modifiers)
        hotKey = hk
    }

    func toggle() { (panel?.isVisible ?? false) ? hide() : show() }

    /// Show the palette, optionally pre-filling the query and/or asking Hermes immediately.
    func summon(query: String? = nil, ask: Bool = false) {
        show()
        guard let query, !query.isEmpty else { return }
        vm.query = query
        vm.recompute()
        if ask { vm.ask(query) }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Position: horizontally centered, ~20% from the top of the active screen.
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            let x = vf.midX - size.width / 2
            let y = vf.maxY - size.height - vf.height * 0.18
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        onWillShow()
        vm.reset()
        NSApp.activate(ignoringOtherApps: true)
        // Entrance: fade the panel in (AppKit) + scale the content up (SwiftUI).
        vm.appearing = false
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async { [weak self] in self?.vm.appearing = true }
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        vm.cancelAsk()
        panel?.orderOut(nil)
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let host = NSHostingView(rootView: ThemedScene { PaletteView(vm: vm) })
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        return panel
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel?.isVisible == true else { return e }
            switch Int(e.keyCode) {
            case kVK_DownArrow: self.vm.move(1); return nil
            case kVK_UpArrow:   self.vm.move(-1); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter: self.vm.activateSelection(); return nil
            case kVK_Escape:
                if self.vm.asking || !self.vm.answer.isEmpty { self.vm.cancelAsk(); self.vm.recompute() }
                else { self.hide() }
                return nil
            default: return e
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    // Dismiss when the panel loses key (click elsewhere / app switch).
    func windowDidResignKey(_ notification: Notification) { hide() }
}
