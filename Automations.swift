import SwiftUI

// MARK: - Automations hub
//
// One place for event-driven + scheduled agent activation: cron jobs
// (`hermes cron`), shell hooks (`hermes hooks`), and webhooks (`hermes webhook`).
// Scheduled-task editing lives in the dedicated Scheduled Tasks window; this hub
// surfaces status across all three trigger types and the actions that are safe
// to drive from a GUI.

final class AutomationsModel: ObservableObject {
    @Published var cronText = ""
    @Published var hooksText = ""
    @Published var webhookText = ""
    @Published var loading = false

    private let exec: ([String]) -> String
    let onManageCron: () -> Void

    init(exec: @escaping ([String]) -> String, onManageCron: @escaping () -> Void) {
        self.exec = exec; self.onManageCron = onManageCron
    }

    func load() {
        DispatchQueue.main.async { self.loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let cron = self.exec(["cron", "list"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let hooks = self.exec(["hooks", "list"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let webhook = self.exec(["webhook", "list"]).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.cronText = cron; self.hooksText = hooks; self.webhookText = webhook
                self.loading = false
            }
        }
    }

    func hooksDoctor() {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.exec(["hooks", "doctor"]).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.hooksText = out }
        }
    }
}

// MARK: - View

struct AutomationsView: View {
    @ObservedObject var model: AutomationsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    section(title: "Scheduled (cron)",
                            subtitle: "Recurring agent jobs",
                            icon: "calendar.badge.clock",
                            text: model.cronText,
                            emptyHint: "No scheduled jobs.") {
                        Button { model.onManageCron() } label: { Label("Manage…", systemImage: "slider.horizontal.3") }
                            .buttonStyle(.hlSecondary)
                    }
                    section(title: "Shell hooks",
                            subtitle: "Run scripts on agent lifecycle events",
                            icon: "terminal",
                            text: model.hooksText,
                            emptyHint: "No shell hooks configured in ~/.hermes/config.yaml.") {
                        Button { model.hooksDoctor() } label: { Label("Doctor", systemImage: "stethoscope") }
                            .buttonStyle(.hlSecondary)
                    }
                    section(title: "Webhooks",
                            subtitle: "Event-driven activation over HTTP",
                            icon: "bolt.horizontal.circle",
                            text: model.webhookText,
                            emptyHint: "Webhook platform is not enabled.") {
                        EmptyView()
                    }
                }
                .padding(DS.Space.lg)
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .background(DS.bg)
        .onAppear { model.load() }
    }

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "bolt.badge.clock").foregroundStyle(DS.accent)
            Text("Automations").font(DS.Typography.title)
            if model.loading { ProgressView().controlSize(.small) }
            Spacer()
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
    }

    private func section<Actions: View>(title: String, subtitle: String, icon: String,
                                        text: String, emptyHint: String,
                                        @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Image(systemName: icon).foregroundStyle(DS.accent)
                HLSectionHeader(title: title, subtitle: subtitle)
                actions()
            }
            HLCard {
                Text(text.isEmpty ? emptyHint : text)
                    .font(DS.Typography.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
