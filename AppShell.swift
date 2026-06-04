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
    let openModelWizard: () -> Void
}

final class ShellModel: ObservableObject {
    @Published var selection: ShellSection = .chat
    @Published var chatTitle: String = "Chat"

    let services: HermesServices
    init(services: HermesServices) { self.services = services }

    // Lazily created + retained so each pane keeps its state across navigation.
    private(set) lazy var chat: ChatSession = {
        let session = ChatSession(hermesPath: services.hermesPath)
        session.onTitle = { [weak self] t in self?.chatTitle = t.isEmpty ? "Chat" : t }
        session.start()
        return session
    }()
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
        NavigationSplitView {
            VStack(spacing: 0) {
                brandHeader
                sidebarList
            }
            .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 640)
    }

    private var brandHeader: some View {
        HStack(spacing: DS.Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.brandGradient)
                Text("H").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
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
            set: { if let v = $0 { model.selection = v } })
        return List(selection: selection) {
            ForEach(ShellSection.allCases) { sec in
                Label(sec == .chat ? model.chatTitle : sec.title, systemImage: sec.symbol)
                    .lineLimit(1)
                    .tag(sec)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .chat:        ChatView(vm: model.chat.vm)
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
                    brandSection
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Preset brand swatches (hex).
    private static let brandSwatches = ["#8C59F5", "#2563EB", "#0EA5E9", "#10B981",
                                        "#F59E0B", "#EF4444", "#EC4899", "#64748B"]

    private var brandSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HLSectionHeader(title: "Brand color", subtitle: "Tints the sidebar mark and accents")
            HLCard {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack(spacing: DS.Space.sm) {
                        // Default (gradient) chip.
                        swatch(fill: AnyShapeStyle(LinearGradient(colors: [DS.violet, DS.pink],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing)),
                               selected: settings.brandColorHex == nil) {
                            settings.brandColorHex = nil
                        }
                        ForEach(Self.brandSwatches, id: \.self) { hex in
                            swatch(fill: AnyShapeStyle(Color(hex: hex) ?? .gray),
                                   selected: settings.brandColorHex?.caseInsensitiveCompare(hex) == .orderedSame) {
                                settings.brandColorHex = hex
                            }
                        }
                    }
                    HStack {
                        ColorPicker("Custom color", selection: Binding(
                            get: { Color(hex: settings.brandColorHex ?? "") ?? DS.accent },
                            set: { settings.brandColorHex = $0.hexString }))
                        .labelsHidden()
                        Text("Custom color").font(DS.Typography.body)
                        Spacer()
                        if settings.brandColorHex != nil {
                            Button("Reset") { settings.brandColorHex = nil }.buttonStyle(.hlSecondary)
                        }
                    }
                }
            }
        }
    }

    private func swatch(fill: AnyShapeStyle, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(selected ? 0.9 : 0.0), lineWidth: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                )
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
