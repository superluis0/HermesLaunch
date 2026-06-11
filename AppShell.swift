import SwiftUI
import AppKit

// MARK: - Unified app shell
//
// One window, one sidebar, every feature as a pane. The existing per-feature
// SwiftUI views are reused verbatim as detail panes; their models live on
// ShellModel so pane state survives navigation.

enum ShellSection: String, CaseIterable, Identifiable {
    case chat, models, kanban, scheduled, automations, tools, sessions, skills, logs, usage, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .models: return "Models"
        case .kanban: return "Kanban"
        case .scheduled: return "Scheduled"
        case .automations: return "Automations"
        case .tools: return "Tools & MCP"
        case .sessions: return "Sessions"
        case .skills: return "Skills"
        case .logs: return "Logs"
        case .usage: return "Usage"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .models: return "cpu"
        case .kanban: return "rectangle.split.3x1.fill"
        case .scheduled: return "calendar.badge.clock"
        case .automations: return "bolt.badge.clock"
        case .tools: return "slider.horizontal.3"
        case .sessions: return "clock.arrow.circlepath"
        case .skills: return "puzzlepiece.extension"
        case .logs: return "doc.text.magnifyingglass"
        case .usage: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }
}

/// Closures the panes need from the AppDelegate. Keeps the shell decoupled from
/// the menu-bar plumbing while reusing its battle-tested helpers.
struct HermesServices {
    let hermesPath: String
    let exec: ([String]) -> String
    let resume: (String) -> Void
    let openFullDashboard: () -> Void
    let usageFetch: (Int) -> UsageStats
    let openMenuBarStyle: () -> Void
    // Model picker
    let currentModel: () -> (model: String, provider: String, baseURL: String)?
    let providerBaseURLs: () -> [String: String]
    let applyModel: (_ model: String, _ provider: String, _ baseURL: String?) -> Void
    /// Persist a model chosen inside a chat as the new global default (provider
    /// left untouched; does not re-propagate back into the open chats).
    let persistChatModel: (_ model: String) -> Void
    let openModelWizard: () -> Void
}

final class ShellModel: ObservableObject {
    @Published var selection: ShellSection = .chat

    // Status-bar state, pushed from the AppDelegate's pollState timer.
    @Published var gatewayRunning = false
    @Published var statusModel: String = ""
    @Published var hermesVersion: String = ""

    func updateStatus(gatewayRunning: Bool, model: String, version: String) {
        self.gatewayRunning = gatewayRunning
        self.statusModel = model
        self.hermesVersion = version
    }

    let services: HermesServices
    init(services: HermesServices) { self.services = services }

    // Lazily created + retained so each pane keeps its state across navigation.
    // `chats` is created on first access (opening the Chat pane). We avoid `lazy`
    // here so other code can *peek* at whether it exists (`existingChats`) without
    // forcing a `hermes acp` session to spawn for a user who never opened Chat.
    private var _chats: ChatsModel?
    var chats: ChatsModel {
        if let c = _chats { return c }
        let c = ChatsModel(hermesPath: services.hermesPath, persistModel: services.persistChatModel)
        _chats = c; return c
    }
    /// The chats model only if it has already been created (no side effects).
    var existingChats: ChatsModel? { _chats }

    private(set) lazy var models = ModelPickerModel(services: services)
    private(set) lazy var kanban = KanbanModel(exec: services.exec)
    private(set) lazy var cron = CronModel(exec: services.exec)
    private(set) lazy var automations = AutomationsModel(exec: services.exec,
                                                         onManageCron: { [weak self] in self?.selection = .scheduled })
    private(set) lazy var tools = ToolsMCPModel(exec: services.exec)
    private(set) lazy var sessions = SessionsModel(exec: services.exec, onResume: services.resume)
    private(set) lazy var skills = SkillsModel(exec: services.exec)
    private(set) lazy var logs = LogModel(exec: services.exec)
    private(set) lazy var usage = UsageModel(fetch: services.usageFetch)
}

// MARK: - Shell view

struct AppShellView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject private var settings = AppSettings.shared   // live brand-color updates

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                VStack(spacing: 0) {
                    brandHeader
                    sidebarList
                }
                .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 300)
            } detail: {
                // ZStack so the outgoing and incoming panes coexist during the
                // crossfade; `.id` gives each pane structural identity so the
                // transition fires on selection change. Pane *models* live on
                // ShellModel, so no state is lost.
                ZStack {
                    detail
                        .id(model.selection)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.5)
            statusFooter
        }
        .frame(minWidth: 1040, minHeight: 640)
        .overlay(alignment: .bottom) {
            HLToastView().padding(.bottom, 34)   // clears the status footer
        }
        .tint(DS.accent)
        .preferredColorScheme(DS.theme.isDark ? .dark : .light)
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            HLStatusDot(color: model.gatewayRunning ? DS.success : DS.textTertiary, size: 7)
            Text(model.gatewayRunning ? "Gateway ready" : "Gateway stopped")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !model.statusModel.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "cpu").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.statusModel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !model.hermesVersion.isEmpty {
                Text(model.hermesVersion).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(DS.surface)
    }

    private var brandHeader: some View {
        HStack(spacing: DS.Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.brandGradient)
                Text("H").font(.system(size: 15, weight: .bold)).foregroundStyle(DS.onAccent)
            }
            .frame(width: 26, height: 26)
            Text("HermesLaunch").font(DS.Typography.heading)
            Spacer()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
    }

    private var sidebarList: some View {
        // Native selection binding → arrow-key navigation + VoiceOver announcements.
        let selection = Binding<ShellSection?>(
            get: { model.selection },
            set: { if let v = $0 { withAnimation(DS.Motion.gentle) { model.selection = v } } })
        return List(selection: selection) {
            ForEach(ShellSection.allCases) { sec in
                Label(sec.title, systemImage: sec.symbol)
                    .lineLimit(1)
                    .tag(sec)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .chat:        ChatContainerView(model: model.chats)
        case .models:      ModelPickerView(model: model.models)
        case .kanban:      KanbanBoardView(model: model.kanban)
        case .scheduled:   ScheduledTasksView(model: model.cron)
        case .automations: AutomationsView(model: model.automations)
        case .tools:       ToolsMCPView(model: model.tools)
        case .sessions:    SessionsView(model: model.sessions)
        case .skills:      SkillsView(model: model.skills)
        case .logs:        LogView(model: model.logs)
        case .usage:       UsageDashboardView(model: model.usage, onOpenFull: model.services.openFullDashboard)
        case .settings:    SettingsPane(services: model.services)
        }
    }
}

// MARK: - Settings pane

struct SettingsPane: View {
    let services: HermesServices
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "gearshape").foregroundStyle(DS.accent)
                Text("Settings").font(DS.Typography.title)
                Spacer()
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    themeSection
                    voiceSection
                    shortcutsSection
                    appearanceSection
                    aboutSection
                }
                .padding(DS.Space.lg)
                .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(DS.bg)
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HLSectionHeader(title: "Theme", subtitle: "Recolors the whole app and sets light or dark")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: DS.Space.md)],
                      alignment: .leading, spacing: DS.Space.md) {
                ForEach(HLTheme.allCases) { theme in
                    themeCard(theme)
                }
            }
        }
    }

    private func themeCard(_ theme: HLTheme) -> some View {
        let selected = settings.themeId == theme.id
        return Button {
            settings.themeId = theme.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ThemeSwatch(palette: theme.palette)
                    .frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08)))
                HStack(spacing: 5) {
                    Text(theme.displayName).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(DS.accent)
                    }
                }
                Text(theme.blurb).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(DS.accent) : AnyShapeStyle(DS.border.opacity(0.6)),
                              lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HLSectionHeader(title: "Voice", subtitle: "On-device dictation & spoken replies")
            HLCard {
                HLToggleRow(title: "Speak replies aloud",
                            subtitle: "Synthesize answers with the local Kokoro voice",
                            isOn: Binding(
                                get: { settings.voice.speakReplies },
                                set: { var v = settings.voice; v.speakReplies = $0; settings.voice = v }))
            }
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HLSectionHeader(title: "Shortcuts")
            HLCard {
                HStack {
                    Text("Summon command palette").font(DS.Typography.body)
                    Spacer()
                    Text("⌥Space").font(DS.Typography.mono).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HLSectionHeader(title: "Menu bar")
            HLCard {
                HStack {
                    Text("Menu-bar text style").font(DS.Typography.body)
                    Spacer()
                    Button("Customize…") { services.openMenuBarStyle() }.buttonStyle(.hlSecondary)
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HLSectionHeader(title: "About")
            HLCard {
                VStack(alignment: .leading, spacing: 4) {
                    row("Hermes binary", services.hermesPath)
                    row("App data", AppSettings.supportDir.path)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(DS.Typography.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(DS.Typography.mono).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// Miniature window mock used in the theme-picker cards (sidebar + text rows + accent pill).
private struct ThemeSwatch: View {
    let palette: ThemePalette
    var body: some View {
        ZStack {
            palette.bg
            HStack(spacing: 0) {
                palette.surface.frame(width: 22)   // mini sidebar
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(palette.accent).frame(width: 34, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(palette.textSecondary.opacity(0.7)).frame(width: 52, height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(palette.textTertiary.opacity(0.7)).frame(width: 44, height: 4)
                    Spacer(minLength: 0)
                    Capsule().fill(palette.accent2).frame(width: 30, height: 9)
                }
                .padding(8)
                Spacer(minLength: 0)
            }
        }
    }
}
