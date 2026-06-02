import Cocoa
import UserNotifications
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // MARK: - Outlets
    private var statusItem: NSStatusItem!
    private var statusInfoItem: NSMenuItem!
    private var usageInfoItem: NSMenuItem!
    private var updateInfoItem: NSMenuItem!
    private var headerSeparator: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var sessionsItem: NSMenuItem!
    private var gatewayItem: NSMenuItem!
    private var gatewayStatusItem: NSMenuItem!
    private var profileItem: NSMenuItem!
    private var doctorItem: NSMenuItem!
    private var menuBarDisplayItem: NSMenuItem!
    private var displayIconItem: NSMenuItem!
    private var displayModelItem: NSMenuItem!
    private var displayTokensItem: NSMenuItem!

    // MARK: - Constants
    // Resolved at runtime so the app works on any machine (see resolveHermesPath()).
    // Override with: defaults write <bundle-id> hermesPath /full/path/to/hermes
    // or the HERMES_BIN environment variable.
    private lazy var hermesPath: String = Self.resolveHermesPath()
    private let pgrepPattern = "caffeinate.*hermes --tui"
    private let gatewayLabel = "ai.hermes.gateway"
    private let logsDir = NSString(string: "~/.hermes/logs").expandingTildeInPath
    private let gatewayLog = NSString(string: "~/.hermes/logs/gateway.log").expandingTildeInPath

    // MARK: - State
    private var tuiRunning = false
    private var gatewayRunning = false
    private var gatewayLoaded = false
    private var gatewayPID: Int? = nil
    private var stateInitialized = false
    private var suppressTUIExitNotice = false

    private var statusCache: (text: String, fetched: Date)? = nil
    private var usageCache: (text: String?, fetched: Date)? = nil
    private var updateAvailable = false
    private var updateNotified = false
    private var doctorRunning = false
    private var currentProfile: String? = nil

    private var pollTimer: Timer?
    private var updateTimer: Timer?
    private var menuBarTextTimer: Timer?

    // Model submenu + windows (Tier 2 features)
    private var modelItem: NSMenuItem!
    private var chatController: ChatWindowController?
    private var usageWindow: NSWindow?
    private var usageModel: UsageModel?

    // Customizable "Show model" text effect (Feature 8)
    private var menuBarFXTimer: Timer?
    private var menuBarPhase: Double = 0
    private var menuBarModelText: String?
    private let menuBarFPS: TimeInterval = 0.1      // ~10 fps animation tick
    private var menuBarStyleWindow: NSWindow?
    private var menuBarStyleModel: MenuBarStyleModel?

    private let menuBarStyleKey = "menuBarStyle"
    private var menuBarStyle: MenuBarStyle {
        get {
            guard let data = UserDefaults.standard.data(forKey: menuBarStyleKey),
                  let s = try? JSONDecoder().decode(MenuBarStyle.self, from: data) else { return MenuBarStyle() }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: menuBarStyleKey)
            }
        }
    }

    // MARK: - Menu-bar display mode
    private enum MenuBarDisplay: String {
        case icon, model, tokens
    }
    private let menuBarDisplayKey = "menuBarDisplay"
    private var menuBarDisplay: MenuBarDisplay {
        get {
            let raw = UserDefaults.standard.string(forKey: menuBarDisplayKey) ?? ""
            return MenuBarDisplay(rawValue: raw) ?? .icon
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: menuBarDisplayKey)
        }
    }

    // MARK: - Favorite models (persisted as JSON in UserDefaults)
    private struct FavoriteModel: Codable, Equatable {
        let label: String
        let model: String
        let provider: String
        let baseURL: String
    }
    private let favoriteModelsKey = "favoriteModels"
    private var favoriteModels: [FavoriteModel] {
        get {
            guard let data = UserDefaults.standard.data(forKey: favoriteModelsKey),
                  let list = try? JSONDecoder().decode([FavoriteModel].self, from: data) else { return [] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: favoriteModelsKey)
            }
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()

        // Notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Register as a Services provider so "Send to Hermes" works system-wide.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Initial state + 5s polling
        pollState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollState()
        }

        // Update checker: once 60s after launch, then every 30 minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.checkForUpdate()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }

        // Menu-bar text: restore persisted display mode and start its timer if needed.
        applyMenuBarDisplayMode(initial: true)

        // First-run guidance if the Hermes CLI isn't installed/locatable.
        warnIfHermesMissing()
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Header: status, usage, optional update row
        statusInfoItem = NSMenuItem(title: "Status: …", action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)

        usageInfoItem = NSMenuItem(title: "Today: …", action: nil, keyEquivalent: "")
        usageInfoItem.isEnabled = false
        usageInfoItem.isHidden = true
        menu.addItem(usageInfoItem)

        updateInfoItem = NSMenuItem(title: "● Update available",
                                    action: #selector(installUpdate),
                                    keyEquivalent: "")
        updateInfoItem.target = self
        updateInfoItem.isHidden = true
        menu.addItem(updateInfoItem)

        headerSeparator = NSMenuItem.separator()
        menu.addItem(headerSeparator)

        // Quick Chat — live, streaming ACP chat window
        let quickAsk = NSMenuItem(title: "Quick Chat…",
                                  action: #selector(openChat),
                                  keyEquivalent: "a")
        quickAsk.target = self
        menu.addItem(quickAsk)

        menu.addItem(.separator())

        // Gateway submenu
        gatewayItem = NSMenuItem(title: "Gateway", action: nil, keyEquivalent: "")
        gatewayItem.submenu = buildGatewaySubmenu()
        menu.addItem(gatewayItem)

        // Profile submenu (populated lazily)
        profileItem = NSMenuItem(title: "Profile: …", action: nil, keyEquivalent: "")
        let profileMenu = NSMenu()
        profileMenu.autoenablesItems = false
        profileMenu.delegate = self
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)

        // Model submenu: favorites + picker (populated lazily)
        modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        modelMenu.autoenablesItems = false
        modelMenu.delegate = self
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        doctorItem = NSMenuItem(title: "Run Doctor",
                                action: #selector(runDoctor),
                                keyEquivalent: "")
        doctorItem.target = self
        menu.addItem(doctorItem)

        let usage = NSMenuItem(title: "Usage…",
                               action: #selector(openUsage),
                               keyEquivalent: "")
        usage.target = self
        menu.addItem(usage)

        // Menu Bar Display submenu
        menuBarDisplayItem = NSMenuItem(title: "Menu Bar Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false

        displayIconItem = NSMenuItem(title: "Icon only",
                                     action: #selector(setMenuBarDisplay(_:)), keyEquivalent: "")
        displayIconItem.target = self
        displayIconItem.representedObject = MenuBarDisplay.icon.rawValue
        displayMenu.addItem(displayIconItem)

        displayModelItem = NSMenuItem(title: "Show model",
                                      action: #selector(setMenuBarDisplay(_:)), keyEquivalent: "")
        displayModelItem.target = self
        displayModelItem.representedObject = MenuBarDisplay.model.rawValue
        displayMenu.addItem(displayModelItem)

        displayTokensItem = NSMenuItem(title: "Show today's tokens",
                                       action: #selector(setMenuBarDisplay(_:)), keyEquivalent: "")
        displayTokensItem.target = self
        displayTokensItem.representedObject = MenuBarDisplay.tokens.rawValue
        displayMenu.addItem(displayTokensItem)

        displayMenu.addItem(.separator())
        let customize = NSMenuItem(title: "Customize Style…",
                                   action: #selector(openMenuBarStyle), keyEquivalent: "")
        customize.target = self
        displayMenu.addItem(customize)

        menuBarDisplayItem.submenu = displayMenu
        menu.addItem(menuBarDisplayItem)

        menu.addItem(.separator())

        // Start / Stop
        startItem = NSMenuItem(title: "Start Hermes",
                               action: #selector(startHermes),
                               keyEquivalent: "s")
        startItem.target = self
        menu.addItem(startItem)

        stopItem = NSMenuItem(title: "Stop Hermes",
                              action: #selector(stopHermes),
                              keyEquivalent: "x")
        stopItem.target = self
        menu.addItem(stopItem)

        // Recent sessions submenu (lazy)
        sessionsItem = NSMenuItem(title: "Resume Session", action: nil, keyEquivalent: "")
        let sessionsMenu = NSMenu()
        sessionsMenu.autoenablesItems = false
        sessionsMenu.delegate = self
        sessionsItem.submenu = sessionsMenu
        menu.addItem(sessionsItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About HermesLaunch",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func buildGatewaySubmenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        gatewayStatusItem = NSMenuItem(title: "Status: …", action: nil, keyEquivalent: "")
        gatewayStatusItem.isEnabled = false
        m.addItem(gatewayStatusItem)
        m.addItem(.separator())

        for (title, sel) in [
            ("Restart Gateway", #selector(restartGateway)),
            ("Stop Gateway", #selector(stopGateway)),
            ("Start Gateway", #selector(startGateway)),
        ] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }

        m.addItem(.separator())

        let tail = NSMenuItem(title: "Tail Logs", action: #selector(tailGatewayLogs), keyEquivalent: "")
        tail.target = self
        m.addItem(tail)

        let reveal = NSMenuItem(title: "Reveal Logs in Finder", action: #selector(revealLogs), keyEquivalent: "")
        reveal.target = self
        m.addItem(reveal)

        return m
    }

    // MARK: - Menu delegate

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            pollState()
            updateGatewayStatusItem()
            refreshStatusSnapshot()
            refreshTodayUsage()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sessionsItem.submenu {
            rebuildSessionsMenu(menu)
        } else if menu === profileItem.submenu {
            rebuildProfileMenu(menu)
        } else if menu === modelItem.submenu {
            rebuildModelMenu(menu)
        }
    }

    // MARK: - Polling + icon

    private func pollState() {
        let newTUI = pgrepMatch(pgrepPattern)
        let gw = launchctlGatewayState()

        let prevTUI = tuiRunning
        let prevGW = gatewayRunning

        tuiRunning = newTUI
        gatewayRunning = gw.running
        gatewayLoaded = gw.loaded
        gatewayPID = gw.pid

        if stateInitialized {
            if prevTUI && !tuiRunning {
                if suppressTUIExitNotice {
                    suppressTUIExitNotice = false
                } else {
                    notify(title: "Hermes TUI exited", body: "The TUI process is no longer running.")
                }
            }
            if prevGW && !gatewayRunning {
                let body = gw.lastExit.map { "Last exit status: \($0)." } ?? "Gateway service stopped."
                notify(title: "Hermes gateway stopped", body: body)
            }
        }
        stateInitialized = true

        updateMenuEnabled()
        updateIcon()
        updateMenuBarAnimation()
    }

    private func updateMenuEnabled() {
        startItem.isEnabled = !tuiRunning
        stopItem.isEnabled = tuiRunning
    }

    private func updateGatewayStatusItem() {
        let text: String
        if !gatewayLoaded {
            text = "Status: Not installed"
        } else if gatewayRunning, let pid = gatewayPID {
            text = "Status: Running (PID \(pid))"
        } else {
            text = "Status: Stopped"
        }
        gatewayStatusItem.title = text
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.brandGlyph    // template (winged-H); tints follow contentTintColor
        if gatewayLoaded && !gatewayRunning {
            button.contentTintColor = .systemRed       // gateway loaded but stopped
        } else if tuiRunning {
            button.contentTintColor = .systemBlue       // TUI running
        } else {
            button.contentTintColor = nil               // idle → adapts to menu-bar appearance
        }
    }

    /// Monochrome "H" menu-bar glyph (template image, tinted via contentTintColor).
    private static let brandGlyph: NSImage = {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.black.setFill()

        let postW: CGFloat = 3.2, gap: CGFloat = 3.6, hH: CGFloat = 12.5, crossH: CGFloat = 3.2
        let hW = postW * 2 + gap
        let left = (s - hW) / 2          // centered
        let bottom = (s - hH) / 2
        let r: CGFloat = 0.9
        func rr(_ rect: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r) }
        let h = NSBezierPath()
        h.windingRule = .nonZero
        h.append(rr(NSRect(x: left, y: bottom, width: postW, height: hH)))
        h.append(rr(NSRect(x: left + postW + gap, y: bottom, width: postW, height: hH)))
        h.append(rr(NSRect(x: left, y: s / 2 - crossH / 2, width: hW, height: crossH)))
        h.fill()

        img.unlockFocus()
        img.isTemplate = true
        return img
    }()

    // MARK: - Status snapshot (#4)

    private func refreshStatusSnapshot() {
        if let cache = statusCache, Date().timeIntervalSince(cache.fetched) < 60 {
            statusInfoItem.title = cache.text
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let output = self.captureHermes(["status"])
            let (model, provider) = Self.parseStatusOutput(output)
            let text: String
            if let m = model {
                text = provider.map { "Status: \(m) · \($0)" } ?? "Status: \(m)"
            } else {
                text = "Status: —"
            }
            DispatchQueue.main.async {
                self.statusInfoItem.title = text
                self.statusCache = (text, Date())
            }
        }
    }

    private static func parseStatusOutput(_ text: String) -> (model: String?, provider: String?) {
        var model: String? = nil
        var provider: String? = nil
        for raw in text.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if model == nil, let v = valueAfterLabel(line, label: "Model:") { model = v }
            if provider == nil, let v = valueAfterLabel(line, label: "Provider:") { provider = v }
            if model != nil && provider != nil { break }
        }
        return (model, provider)
    }

    private static func valueAfterLabel(_ line: String, label: String) -> String? {
        guard let range = line.range(of: label) else { return nil }
        let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : tail
    }

    // MARK: - Today's usage (#5)

    private func refreshTodayUsage() {
        if let cache = usageCache, Date().timeIntervalSince(cache.fetched) < 60 {
            applyUsage(cache.text)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let output = self.captureHermes(["insights", "--days", "1"])
            let text = Self.parseInsights(output)
            DispatchQueue.main.async {
                self.applyUsage(text)
                self.usageCache = (text, Date())
            }
        }
    }

    private func applyUsage(_ text: String?) {
        if let text = text {
            usageInfoItem.title = text
            usageInfoItem.isHidden = false
        } else {
            usageInfoItem.isHidden = true
        }
    }

    private static func parseInsights(_ text: String) -> String? {
        // Look for "Sessions:" and "Total tokens:" — each followed by a number.
        var sessions: Int? = nil
        var tokens: Int? = nil
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if sessions == nil, let n = numberAfter(line, marker: "Sessions:") {
                sessions = n
            }
            if tokens == nil, let n = numberAfter(line, marker: "Total tokens:") {
                tokens = n
            }
            if sessions != nil && tokens != nil { break }
        }
        guard let s = sessions, s > 0 else { return nil }
        let t = tokens ?? 0
        return "Today: \(s) session\(s == 1 ? "" : "s") · \(Self.compactNumber(t)) tokens"
    }

    private static func numberAfter(_ line: String, marker: String) -> Int? {
        guard let range = line.range(of: marker) else { return nil }
        let tail = line[range.upperBound...]
        var digits = ""
        var sawDigit = false
        for ch in tail {
            if ch.isWhitespace {
                if sawDigit { break } else { continue }
            }
            if ch == "," { continue }
            if ch.isNumber {
                digits.append(ch)
                sawDigit = true
            } else if sawDigit {
                break
            } else {
                // hit non-number, non-space before any digit — abort
                return nil
            }
        }
        return Int(digits)
    }

    private static func compactNumber(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            let v = Double(n) / 1_000.0
            return String(format: "%.1fk", v).replacingOccurrences(of: ".0k", with: "k")
        }
        let v = Double(n) / 1_000_000.0
        return String(format: "%.1fM", v).replacingOccurrences(of: ".0M", with: "M")
    }

    // MARK: - Profile switcher (#7)

    private struct ProfileRow {
        let name: String
        let isCurrent: Bool
    }

    private func rebuildProfileMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = fetchProfiles()
        if profiles.isEmpty {
            let none = NSMenuItem(title: "No profiles", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            profileItem.title = "Profile: —"
            return
        }
        currentProfile = profiles.first(where: { $0.isCurrent })?.name
        profileItem.title = "Profile: \(currentProfile ?? "—")"
        for p in profiles {
            let item = NSMenuItem(title: p.name,
                                  action: #selector(switchProfile(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = p.name
            item.state = p.isCurrent ? .on : .off
            menu.addItem(item)
        }
    }

    private func fetchProfiles() -> [ProfileRow] {
        let output = captureHermes(["profile", "list"])
        var rows: [ProfileRow] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("Profile") { continue } // header
            if trimmed.allSatisfy({ $0 == "─" || $0 == "-" || $0 == "=" }) { continue }
            let parts = Self.splitOnMultiSpace(line)
            guard let first = parts.first, !first.isEmpty else { continue }
            var name = first
            var current = false
            if name.hasPrefix("◆") {
                name.removeFirst()
                current = true
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            // Skip stray rows like "Distribution" header continuations or empty col.
            if name.lowercased() == "profile" { continue }
            rows.append(ProfileRow(name: name, isCurrent: current))
        }
        return rows
    }

    @objc private func switchProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runHermes(["profile", "use", name], wait: false)
        // Invalidate caches so status snapshot reflects the new profile.
        statusCache = nil
        usageCache = nil
        bumpPoll()
    }

    // MARK: - Model picker (#8)

    @objc private func changeModel() {
        runInTerminal([hermesPath, "model"])
    }

    // MARK: - Menu-bar text + About (v5)

    @objc private func setMenuBarDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MenuBarDisplay(rawValue: raw) else { return }
        menuBarDisplay = mode
        applyMenuBarDisplayMode(initial: false)
    }

    private func applyMenuBarDisplayMode(initial: Bool) {
        let mode = menuBarDisplay
        // Update checkmarks.
        displayIconItem?.state = (mode == .icon) ? .on : .off
        displayModelItem?.state = (mode == .model) ? .on : .off
        displayTokensItem?.state = (mode == .tokens) ? .on : .off

        // Tear down any existing timer.
        menuBarTextTimer?.invalidate()
        menuBarTextTimer = nil

        if mode == .icon {
            statusItem.button?.title = ""
            menuBarModelText = nil
            updateMenuBarAnimation()   // stops the wave timer if it was running
            return
        }

        // Refresh now, then every 120s while this mode is active.
        refreshMenuBarText()
        menuBarTextTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refreshMenuBarText()
        }
        updateMenuBarAnimation()
    }

    private func refreshMenuBarText() {
        let mode = menuBarDisplay
        guard mode != .icon else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var text: String? = nil
            switch mode {
            case .model:
                let (model, _) = Self.parseStatusOutput(self.captureHermes(["status"]))
                if let m = model { text = " \(m)" }
            case .tokens:
                let output = self.captureHermes(["insights", "--days", "1"])
                if let n = Self.numberAfter(self.firstLineContaining(output, "Total tokens:") ?? "",
                                            marker: "Total tokens:") {
                    text = " \(Self.compactNumber(n))"
                }
            case .icon:
                break
            }
            DispatchQueue.main.async {
                // Only apply if the mode hasn't changed out from under us, and don't
                // flicker to empty on a transient fetch failure.
                guard self.menuBarDisplay == mode, let text = text else { return }
                if mode == .model {
                    self.menuBarModelText = text
                    self.renderMenuBarTitle()
                    self.updateMenuBarAnimation()
                } else {
                    self.menuBarModelText = nil
                    self.statusItem.button?.title = text
                }
            }
        }
    }

    private func firstLineContaining(_ text: String, _ marker: String) -> String? {
        for raw in text.split(separator: "\n") where raw.contains(marker) {
            return String(raw)
        }
        return nil
    }

    // MARK: - "Show model" text effect (Feature 8)

    /// Should the effect paint (vs plain text) right now?
    private var menuBarStyled: Bool {
        menuBarDisplay == .model && menuBarModelText != nil
            && (tuiRunning || !menuBarStyle.onlyWhileRunning)
    }

    /// Single place that paints the menu-bar title in `.model` mode.
    private func renderMenuBarTitle() {
        guard let button = statusItem.button else { return }
        guard menuBarDisplay == .model, let text = menuBarModelText else { return }
        if menuBarStyled {
            button.attributedTitle = styledString(text, phase: menuBarPhase)
        } else {
            button.title = text   // plain (adapts to light/dark)
        }
    }

    private func styledString(_ text: String, phase: Double) -> NSAttributedString {
        let style = menuBarStyle
        let palette = style.palette
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: NSFont.menuBarFont(ofSize: 0),
                          range: NSRange(location: 0, length: attr.length))
        let chars = Array(text)
        for i in chars.indices {
            let rgba = MenuBarFX.rgba(style: style.style, palette: palette,
                                      index: i, count: chars.count,
                                      phase: phase, tightness: style.tightness)
            attr.addAttribute(.foregroundColor, value: MenuBarFX.nsColor(rgba),
                              range: NSRange(location: i, length: 1))
        }
        return attr
    }

    /// Starts/stops the animation timer based on mode, style, and TUI state.
    private func updateMenuBarAnimation() {
        let style = menuBarStyle
        let needsAnim = MenuBarFX.needsAnimation(style.style, speed: style.speed)
        let shouldRun = menuBarStyled && needsAnim
        if shouldRun {
            if menuBarFXTimer == nil {
                let drift = MenuBarFX.drift(forSpeed: style.speed)
                menuBarFXTimer = Timer.scheduledTimer(withTimeInterval: menuBarFPS, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.menuBarPhase = MenuBarFX.frac(self.menuBarPhase - drift)  // flows left→right
                    self.renderMenuBarTitle()
                }
            }
        } else {
            menuBarFXTimer?.invalidate()
            menuBarFXTimer = nil
            renderMenuBarTitle()   // paint static style / plain text once
        }
    }

    @objc private func openMenuBarStyle() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = menuBarStyleWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let model = MenuBarStyleModel(style: menuBarStyle)
        model.onChange = { [weak self] newStyle in
            guard let self = self else { return }
            self.menuBarStyle = newStyle
            self.updateMenuBarAnimation()   // re-evaluates animation + repaints
        }
        menuBarStyleModel = model

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Menu Bar Style"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(rootView: MenuBarStyleView(model: model))
        menuBarStyleWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let hermesVersion = captureHermes(["version"])
            .split(separator: "\n").first.map(String.init) ?? "unknown"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "HermesLaunch \(appVersion)"
        alert.informativeText = """
        A menu-bar companion for the Hermes agent — launch the TUI under caffeinate, \
        manage the messaging gateway, resume sessions, and more.

        \(hermesVersion)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Update checker (#12)

    private func checkForUpdate() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let output = self.captureHermes(["update", "--check"])
            let available = Self.parseUpdateOutput(output)
            DispatchQueue.main.async {
                let wasAvailable = self.updateAvailable
                self.updateAvailable = available
                self.updateInfoItem.isHidden = !available
                if available && !wasAvailable && !self.updateNotified {
                    self.notify(title: "Hermes update available",
                                body: "Click ● Update available in the menu to install.")
                    self.updateNotified = true
                }
                if !available {
                    self.updateNotified = false
                }
            }
        }
    }

    private static func parseUpdateOutput(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("up to date") || lower.contains("no update") {
            return false
        }
        if lower.contains("update available") || lower.contains("new version") || lower.contains("available:") {
            return true
        }
        // Default: assume up-to-date to avoid false positives.
        return false
    }

    @objc private func installUpdate() {
        runInTerminal([hermesPath, "update"])
    }

    // MARK: - Doctor (#15)

    @objc private func runDoctor() {
        if doctorRunning { return }
        doctorRunning = true
        doctorItem.title = "Running Doctor…"
        doctorItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let output = self.captureHermes(["doctor"])
            let (failures, warnings) = Self.countDoctorIssues(output)
            // Write the full output to a temp file we can open in Ghostty if needed.
            let logPath = (self.logsDir as NSString).appendingPathComponent("last-doctor.txt")
            try? output.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath))
            DispatchQueue.main.async {
                self.doctorRunning = false
                self.doctorItem.title = "Run Doctor"
                self.doctorItem.isEnabled = true
                let total = failures + warnings
                if total == 0 {
                    self.notify(title: "Hermes Doctor", body: "All checks passed.")
                } else {
                    let body = warnings > 0
                        ? "\(failures) failure\(failures == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")."
                        : "\(failures) failure\(failures == 1 ? "" : "s") detected."
                    self.notify(title: "Hermes Doctor", body: body)
                    self.runInTerminal(["/usr/bin/less", logPath])
                }
            }
        }
    }

    private static func countDoctorIssues(_ text: String) -> (failures: Int, warnings: Int) {
        var fails = 0
        var warns = 0
        for line in text.split(separator: "\n") {
            if line.contains("✗") { fails += 1 }
            if line.contains("⚠") { warns += 1 }
        }
        return (fails, warns)
    }

    // MARK: - State probes

    private func pgrepMatch(_ pattern: String) -> Bool {
        let p = Process()
        p.launchPath = "/usr/bin/pgrep"
        p.arguments = ["-f", pattern]
        let null = Pipe()
        p.standardOutput = null
        p.standardError = null
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private struct GatewayState {
        let loaded: Bool
        let running: Bool
        let pid: Int?
        let lastExit: Int?
    }

    private func launchctlGatewayState() -> GatewayState {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = ["list", gatewayLabel]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return GatewayState(loaded: false, running: false, pid: nil, lastExit: nil)
        }
        if p.terminationStatus != 0 {
            return GatewayState(loaded: false, running: false, pid: nil, lastExit: nil)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        var pid: Int? = nil
        var lastExit: Int? = nil
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\"PID\"") {
                pid = Self.intAfterEquals(trimmed)
            } else if trimmed.hasPrefix("\"LastExitStatus\"") {
                lastExit = Self.intAfterEquals(trimmed)
            }
        }
        return GatewayState(loaded: true, running: pid != nil, pid: pid, lastExit: lastExit)
    }

    private static func intAfterEquals(_ line: String) -> Int? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let tail = line[line.index(after: eq)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
        return Int(tail)
    }

    // MARK: - Notifications

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - Hermes TUI actions

    @objc private func startHermes() {
        ensureGatewayRunning()
        runInTerminal(["/usr/bin/caffeinate", "-is", hermesPath, "--tui"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollState()
        }
    }

    @objc private func stopHermes() {
        suppressTUIExitNotice = true
        let p = Process()
        p.launchPath = "/usr/bin/pkill"
        p.arguments = ["-f", pgrepPattern]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSLog("HermesLaunch stop error: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pollState()
        }
    }

    // MARK: - Gateway actions

    private func ensureGatewayRunning() {
        runHermes(["gateway", "start"], wait: true)
    }

    @objc private func startGateway() {
        runHermes(["gateway", "start"], wait: false)
        bumpPoll()
    }

    @objc private func stopGateway() {
        runHermes(["gateway", "stop"], wait: false)
        bumpPoll()
    }

    @objc private func restartGateway() {
        runHermes(["gateway", "restart"], wait: false)
        bumpPoll()
    }

    @objc private func tailGatewayLogs() {
        runInTerminal(["/usr/bin/tail", "-f", gatewayLog])
    }

    @objc private func revealLogs() {
        let p = Process()
        p.launchPath = "/usr/bin/open"
        p.arguments = [logsDir]
        try? p.run()
    }

    private func runHermes(_ args: [String], wait: Bool) {
        let p = Process()
        p.launchPath = hermesPath
        p.arguments = args
        let null = Pipe()
        p.standardOutput = null
        p.standardError = null
        do {
            try p.run()
            if wait { p.waitUntilExit() }
        } catch {
            NSLog("HermesLaunch runHermes(\(args)) error: \(error)")
        }
    }

    private func captureHermes(_ args: [String]) -> String {
        let p = Process()
        p.launchPath = hermesPath
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func bumpPoll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pollState()
        }
    }

    // MARK: - Sessions submenu

    private func rebuildSessionsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = fetchRecentSessions(limit: 10)
        if entries.isEmpty {
            let none = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for entry in entries {
            let title = "\(Self.truncate(entry.title, to: 40)) — \(entry.lastActive)"
            let item = NSMenuItem(title: title,
                                  action: #selector(resumeSession(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            menu.addItem(item)
        }
    }

    @objc private func resumeSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ensureGatewayRunning()
        runInTerminal(["/usr/bin/caffeinate", "-is", hermesPath, "--resume", id, "--tui"])
        bumpPoll()
    }

    private struct SessionEntry {
        let title: String
        let lastActive: String
        let id: String
    }

    private func fetchRecentSessions(limit: Int) -> [SessionEntry] {
        let text = captureHermes(["sessions", "list", "--limit", String(limit)])
        return Self.parseSessions(text)
    }

    private static func parseSessions(_ text: String) -> [SessionEntry] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
        var out: [SessionEntry] = []
        let idPattern = try? NSRegularExpression(pattern: "^\\d{8}_\\d{6}_[0-9a-fA-F]+$")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.allSatisfy({ $0 == "─" || $0 == "-" || $0 == "=" }) { continue }
            let parts = splitOnMultiSpace(line)
            guard parts.count >= 3 else { continue }
            let id = parts.last!
            if let re = idPattern {
                let range = NSRange(location: 0, length: id.utf16.count)
                if re.firstMatch(in: id, range: range) == nil { continue }
            } else if !id.contains("_") {
                continue
            }
            let title = parts[0]
            let lastActive = parts.count >= 4 ? parts[parts.count - 2] : "—"
            out.append(SessionEntry(title: title.isEmpty ? "—" : title,
                                    lastActive: lastActive,
                                    id: id))
        }
        return out
    }

    private static func splitOnMultiSpace(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var spaceRun = 0
        for ch in line {
            if ch == " " {
                spaceRun += 1
                if spaceRun == 1 { current.append(ch) }
            } else {
                if spaceRun >= 2 && !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
                spaceRun = 0
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    // MARK: - Hermes binary resolution

    /// Locate the `hermes` executable so the app works on any machine.
    /// Order: UserDefaults override → $HERMES_BIN → common install dirs →
    /// the login shell's PATH → bare "hermes".
    private static func resolveHermesPath() -> String {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "hermesPath"),
           fm.isExecutableFile(atPath: custom) { return custom }
        if let env = ProcessInfo.processInfo.environment["HERMES_BIN"],
           fm.isExecutableFile(atPath: env) { return env }

        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            "/usr/bin/hermes",
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }

        if let viaShell = shellResolve("hermes"), fm.isExecutableFile(atPath: viaShell) { return viaShell }
        return "hermes"
    }

    /// Ask the user's login shell to resolve a command from their PATH
    /// (GUI apps don't inherit the shell environment).
    private static func shellResolve(_ tool: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.launchPath = shell
        p.arguments = ["-lc", "command -v \(tool)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    private func warnIfHermesMissing() {
        if FileManager.default.isExecutableFile(atPath: hermesPath) { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hermes CLI not found"
        alert.informativeText = """
        HermesLaunch couldn't locate the `hermes` command. Install the Hermes Agent CLI \
        and make sure it's on your PATH, then relaunch.

        If it's installed in a non-standard location, set the HERMES_BIN environment \
        variable to its full path, or run:

            defaults write \(Bundle.main.bundleIdentifier ?? "HermesLaunch") hermesPath /full/path/to/hermes
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Terminal launch (portable)

    /// Run a command in a visible terminal window. Prefers Ghostty when installed,
    /// otherwise falls back to Terminal.app via a temporary executable `.command`
    /// script — so it works on any Mac without extra setup.
    private func runInTerminal(_ command: [String]) {
        if ghosttyInstalled {
            let p = Process()
            p.launchPath = "/usr/bin/open"
            p.arguments = ["-na", "Ghostty.app", "--args", "-e"] + command
            do { try p.run() } catch { NSLog("HermesLaunch terminal launch error: \(error)") }
            return
        }
        // Fallback: write a .command script and open it (runs in Terminal.app).
        let line = command.map { Self.shellQuote($0) }.joined(separator: " ") + "\n"
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("hermeslaunch-\(UUID().uuidString).command")
        do {
            try line.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            let p = Process()
            p.launchPath = "/usr/bin/open"
            p.arguments = [path]
            try p.run()
        } catch {
            NSLog("HermesLaunch terminal launch error: \(error)")
        }
    }

    private lazy var ghosttyInstalled: Bool = {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil { return true }
        return FileManager.default.fileExists(atPath: "/Applications/Ghostty.app")
    }()

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Services: Send to Hermes (#16)

    @objc func sendToHermes(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let selection = pboard.string(forType: .string), !selection.isEmpty else {
            error.pointee = "No selected text." as NSString
            return
        }
        // Truncate generously — hermes -z reads the whole argv, but >32k chars argv
        // starts to look risky. 8k is plenty for sentence-scale usage.
        let trimmed = String(selection.prefix(8000))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let output = self.captureHermes(["-z", trimmed])
            let response = output.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                // Copy full response to clipboard.
                let general = NSPasteboard.general
                general.clearContents()
                general.setString(response, forType: .string)
                // Notify with a preview.
                let preview = String(response.prefix(200))
                self.notify(title: "Hermes reply (copied to clipboard)",
                            body: preview.isEmpty ? "(no response)" : preview)
            }
        }
    }

    // MARK: - Model submenu + favorites (Tier 2 #5)

    private func rebuildModelMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let favorites = favoriteModels
        let current = currentModelSpec()

        if favorites.isEmpty {
            let none = NSMenuItem(title: "No favorites saved", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for fav in favorites {
                let item = NSMenuItem(title: fav.label,
                                      action: #selector(switchToFavorite(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = fav
                if let c = current, c.model == fav.model, c.provider == fav.provider {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let save = NSMenuItem(title: "Save Current Model as Favorite",
                              action: #selector(saveCurrentFavorite),
                              keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        if !favorites.isEmpty {
            let forget = NSMenuItem(title: "Forget Favorite", action: nil, keyEquivalent: "")
            let forgetMenu = NSMenu()
            forgetMenu.autoenablesItems = false
            for fav in favorites {
                let fi = NSMenuItem(title: fav.label,
                                    action: #selector(forgetFavorite(_:)),
                                    keyEquivalent: "")
                fi.target = self
                fi.representedObject = fav
                forgetMenu.addItem(fi)
            }
            forget.submenu = forgetMenu
            menu.addItem(forget)
        }

        menu.addItem(.separator())

        let picker = NSMenuItem(title: "Change Model… (Picker)",
                                action: #selector(changeModel),
                                keyEquivalent: "")
        picker.target = self
        menu.addItem(picker)
    }

    private func currentModelSpec() -> (model: String, provider: String, baseURL: String)? {
        return Self.parseModelConfig(captureHermes(["config", "show"]))
    }

    private static func parseModelConfig(_ text: String) -> (model: String, provider: String, baseURL: String)? {
        // Parse the line:  Model: {'default': 'gpt-5.5', 'provider': 'openai-codex', 'base_url': '…'}
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard line.contains("'default'") else { continue }
            guard let model = singleQuotedValue(after: "'default':", in: line), !model.isEmpty else { continue }
            let provider = singleQuotedValue(after: "'provider':", in: line) ?? ""
            let baseURL = singleQuotedValue(after: "'base_url':", in: line) ?? ""
            return (model, provider, baseURL)
        }
        return nil
    }

    private static func singleQuotedValue(after key: String, in line: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let tail = line[r.upperBound...]
        guard let open = tail.firstIndex(of: "'") else { return nil }
        let afterOpen = tail.index(after: open)
        guard let close = tail[afterOpen...].firstIndex(of: "'") else { return nil }
        return String(tail[afterOpen..<close])
    }

    @objc private func saveCurrentFavorite() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let spec = self.currentModelSpec() else {
                DispatchQueue.main.async {
                    self.notify(title: "Save favorite failed", body: "Could not read the current model.")
                }
                return
            }
            DispatchQueue.main.async {
                var favs = self.favoriteModels
                if favs.contains(where: { $0.model == spec.model && $0.provider == spec.provider }) {
                    self.notify(title: "Already a favorite", body: spec.model)
                    return
                }
                let label = spec.provider.isEmpty ? spec.model : "\(spec.model) · \(spec.provider)"
                favs.append(FavoriteModel(label: label,
                                          model: spec.model,
                                          provider: spec.provider,
                                          baseURL: spec.baseURL))
                self.favoriteModels = favs
                self.notify(title: "Favorite saved", body: label)
            }
        }
    }

    @objc private func switchToFavorite(_ sender: NSMenuItem) {
        guard let fav = sender.representedObject as? FavoriteModel else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.runHermes(["config", "set", "model.default", fav.model], wait: true)
            if !fav.provider.isEmpty {
                self.runHermes(["config", "set", "model.provider", fav.provider], wait: true)
            }
            if !fav.baseURL.isEmpty {
                self.runHermes(["config", "set", "model.base_url", fav.baseURL], wait: true)
            }
            DispatchQueue.main.async {
                // Invalidate caches so the header + menu-bar text reflect the new model.
                self.statusCache = nil
                self.usageCache = nil
                self.bumpPoll()
                self.refreshMenuBarText()
                self.notify(title: "Model switched", body: fav.label)
            }
        }
    }

    @objc private func forgetFavorite(_ sender: NSMenuItem) {
        guard let fav = sender.representedObject as? FavoriteModel else { return }
        var favs = favoriteModels
        favs.removeAll { $0.model == fav.model && $0.provider == fav.provider }
        favoriteModels = favs
    }

    // MARK: - Quick Chat window (Feature 5 — live ACP chat)

    @objc private func openChat() {
        if chatController == nil {
            chatController = ChatWindowController(hermesPath: hermesPath) { [weak self] in
                self?.chatController = nil   // released on window close → fresh conversation next time
            }
        }
        chatController?.show()
    }

    // MARK: - Usage window (Tier 2 #6)

    @objc private func openUsage() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = usageWindow {
            w.makeKeyAndOrderFront(nil)
            usageModel?.load()
            return
        }

        let model = UsageModel(fetch: { [weak self] days in
            guard let self = self else { return UsageStats() }
            let out = self.captureHermes(["insights", "--days", String(days)])
            return Self.usageStats(from: Self.parseInsightsFull(out))
        })
        usageModel = model

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Usage — Hermes"
        win.minSize = NSSize(width: 540, height: 520)
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(rootView:
            UsageDashboardView(model: model, onOpenFull: { [weak self] in self?.openFullDashboard() }))
        usageWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func openFullDashboard() {
        // Long-running web server on 127.0.0.1:9119; runs in a visible Ghostty window
        // and opens the browser itself.
        runInTerminal([hermesPath, "dashboard"])
    }

    /// Map the parsed insights into the SwiftUI dashboard's value model.
    private static func usageStats(from s: InsightsSummary) -> UsageStats {
        func toInt(_ str: String) -> Int { Int(str.filter { $0.isNumber }) ?? 0 }
        var u = UsageStats()
        u.period = s.period
        u.sessions = s.sessions
        u.messages = s.messages
        u.toolCalls = s.toolCalls
        u.inputTokens = s.inputTokens
        u.outputTokens = s.outputTokens
        u.totalTokens = s.totalTokens
        u.activeTime = s.activeTime
        u.models = s.models.map { CategoryStat(name: $0.name, value: toInt($0.tokens), subtitle: nil) }
        u.platforms = s.platforms.map { CategoryStat(name: $0.name, value: toInt($0.tokens), subtitle: nil) }
        u.topTools = s.topTools.prefix(8).map { CategoryStat(name: $0.name, value: $0.calls, subtitle: nil) }
        u.weekday = s.weekday.map { DayStat(day: $0.day, count: $0.count) }
        return u
    }

    private struct InsightsSummary {
        var period: String?
        var sessions: Int?
        var messages: Int?
        var toolCalls: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var activeTime: String?
        var models: [(name: String, sessions: String, tokens: String)] = []
        var platforms: [(name: String, sessions: String, messages: String, tokens: String)] = []
        var topTools: [(name: String, calls: Int)] = []
        var weekday: [(day: String, count: Int)] = []
    }

    private static func parseInsightsFull(_ text: String) -> InsightsSummary {
        var s = InsightsSummary()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

        for line in lines {
            if s.sessions == nil, let n = numberAfter(line, marker: "Sessions:") { s.sessions = n }
            if s.messages == nil, let n = numberAfter(line, marker: "Messages:") { s.messages = n }
            if s.toolCalls == nil, let n = numberAfter(line, marker: "Tool calls:") { s.toolCalls = n }
            if s.inputTokens == nil, let n = numberAfter(line, marker: "Input tokens:") { s.inputTokens = n }
            if s.outputTokens == nil, let n = numberAfter(line, marker: "Output tokens:") { s.outputTokens = n }
            if s.totalTokens == nil, let n = numberAfter(line, marker: "Total tokens:") { s.totalTokens = n }
            if s.period == nil, let r = line.range(of: "Period:") {
                s.period = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if s.activeTime == nil, line.contains("Active time:") {
                let parts = splitOnMultiSpace(line)
                if let idx = parts.firstIndex(where: { $0.hasPrefix("Active time:") }), idx + 1 < parts.count {
                    s.activeTime = parts[idx + 1]
                }
            }
        }

        s.models = parseInsightsSection(lines, marker: "Models Used").compactMap { row in
            row.count >= 3 ? (row[0], row[row.count - 2], row[row.count - 1]) : nil
        }
        s.platforms = parseInsightsSection(lines, marker: "Platforms").compactMap { row in
            row.count >= 4 ? (row[0], row[1], row[2], row[row.count - 1]) : nil
        }
        s.topTools = parseInsightsSection(lines, marker: "Top Tools").compactMap { row in
            row.count >= 2 ? (row[0], Int(row[1].filter { $0.isNumber }) ?? 0) : nil
        }
        s.weekday = parseWeekday(lines)
        return s
    }

    /// Activity-pattern rows look like `Mon  ███████████████ 6` — take the last
    /// integer on each weekday line, preserving Mon→Sun order.
    private static func parseWeekday(_ lines: [String]) -> [(day: String, count: Int)] {
        let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var out: [(String, Int)] = []
        for day in order {
            guard let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(day) }) else { continue }
            let nums = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            out.append((day, nums.last ?? 0))
        }
        return out
    }

    /// Collect data rows of a box-drawn insights table: skips the ──── divider and
    /// the column-header line, then reads rows until the next blank line.
    private static func parseInsightsSection(_ lines: [String], marker: String) -> [[String]] {
        guard let startIdx = lines.firstIndex(where: { $0.contains(marker) }) else { return [] }
        var rows: [[String]] = []
        var sawDivider = false
        var i = startIdx + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if sawDivider && !rows.isEmpty { break }
                i += 1
                continue
            }
            if trimmed.allSatisfy({ $0 == "─" || $0 == "-" || $0 == "=" }) {
                sawDivider = true
                i += 1
                continue
            }
            if !sawDivider { i += 1; continue }
            let parts = splitOnMultiSpace(lines[i])
            // Skip the column-header line (e.g. "Model … Sessions … Tokens").
            if rows.isEmpty, let head = parts.first,
               ["Model", "Platform", "Tool", "Skill"].contains(head) {
                i += 1
                continue
            }
            rows.append(parts)
            i += 1
        }
        return rows
    }

    // MARK: - Image helpers

    private static func truncate(_ s: String, to n: Int) -> String {
        if s.count <= n { return s }
        return String(s.prefix(n - 1)) + "…"
    }
}
