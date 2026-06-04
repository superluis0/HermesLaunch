import SwiftUI
import Foundation

// MARK: - In-app model picker
//
// Lists the user's authenticated providers + their models (from Hermes'
// ~/.hermes/provider_models_cache.json) and switches the default model in-app via
// `hermes config set` — no terminal. First-time provider sign-in (OAuth) still
// uses the interactive wizard, reachable from the footer.

struct ProviderModels: Identifiable {
    var id: String { provider }
    let provider: String
    let models: [String]
}

final class ModelPickerModel: ObservableObject {
    @Published var providers: [ProviderModels] = []
    @Published var current: (model: String, provider: String)?
    @Published var query = ""
    @Published var loading = false
    @Published var note: String?

    private let services: HermesServices
    init(services: HermesServices) { self.services = services }

    private var cacheURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/provider_models_cache.json")
    }

    /// Friendly provider names; falls back to the raw slug.
    static let displayNames: [String: String] = [
        "anthropic": "Anthropic",
        "openai-codex": "OpenAI (Codex)",
        "nous": "Nous Portal",
        "xai-oauth": "xAI",
        "openrouter": "OpenRouter",
        "ollama": "Ollama",
    ]
    func displayName(_ slug: String) -> String { Self.displayNames[slug] ?? slug.capitalized }

    func load() {
        DispatchQueue.main.async { self.loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = Self.parse(self.cacheURL)
            let cur = self.services.currentModel().map { ($0.model, $0.provider) }
            DispatchQueue.main.async {
                self.providers = parsed
                self.current = cur
                self.note = parsed.isEmpty
                    ? "No providers found yet. Sign in to one below to get started."
                    : nil
                self.loading = false
            }
        }
    }

    static func parse(_ url: URL) -> [ProviderModels] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var result: [ProviderModels] = []
        for (provider, value) in obj {
            guard let dict = value as? [String: Any], let models = dict["models"] as? [String] else { continue }
            result.append(ProviderModels(provider: provider, models: models))
        }
        return result.sorted { $0.provider < $1.provider }
    }

    func filtered(_ models: [String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter { $0.lowercased().contains(q) }
    }

    func isCurrent(_ model: String, _ provider: String) -> Bool {
        current?.model == model && current?.provider == provider
    }

    func select(model: String, provider: String) {
        // Same provider → leave base_url untouched (it's already correct).
        // Different provider → use a known base_url if we have one; otherwise let
        // Hermes resolve it from the provider at runtime.
        let baseURL: String? = (provider == current?.provider) ? nil : services.providerBaseURLs()[provider]
        current = (model, provider)   // optimistic; AppDelegate refreshes status/menu
        services.applyModel(model, provider, baseURL)
    }

    func openWizard() { services.openModelWizard() }
}

// MARK: - View

struct ModelPickerView: View {
    @ObservedObject var model: ModelPickerModel
    @State private var expanded: Set<String> = []
    @State private var didInitExpansion = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.load() }
    }

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "cpu").foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Models").font(DS.Typography.title)
                if let c = model.current {
                    Text("Current: \(c.model) · \(model.displayName(c.provider))")
                        .font(DS.Typography.caption).foregroundStyle(.secondary)
                }
            }
            if model.loading { ProgressView().controlSize(.small) }
            Spacer()
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter models…", text: $model.query).textFieldStyle(.plain)
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
            Divider().opacity(0.4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                    if let note = model.note {
                        Text(note).font(DS.Typography.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.providers) { group in
                        let models = model.filtered(group.models)
                        if !models.isEmpty {
                            // While filtering, force every section open so matches show.
                            let isOpen = !model.query.isEmpty || expanded.contains(group.provider)
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                providerHeader(group, count: models.count, open: isOpen)
                                if isOpen {
                                    ForEach(models, id: \.self) { m in
                                        row(model: m, provider: group.provider)
                                    }
                                }
                            }
                        }
                    }
                    footer
                }
                .padding(DS.Space.lg)
            }
        }
        .onAppear(perform: initExpansion)
        .onChange(of: model.providers.count) { initExpansion() }
    }

    private func providerHeader(_ group: ProviderModels, count: Int, open: Bool) -> some View {
        Button {
            withAnimation(DS.Motion.quick) {
                if expanded.contains(group.provider) { expanded.remove(group.provider) }
                else { expanded.insert(group.provider) }
            }
        } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(model.displayName(group.provider)).font(DS.Typography.heading).foregroundStyle(.secondary)
                Text("\(count)").font(DS.Typography.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!model.query.isEmpty)   // sections are forced-open while filtering
    }

    /// Expand the current model's provider by default; collapse the rest.
    private func initExpansion() {
        guard !didInitExpansion, !model.providers.isEmpty else { return }
        didInitExpansion = true
        if let cur = model.current?.provider, model.providers.contains(where: { $0.provider == cur }) {
            expanded = [cur]
        } else {
            expanded = Set(model.providers.map(\.provider))
        }
    }

    private func row(model m: String, provider: String) -> some View {
        let selected = model.isCurrent(m, provider)
        return Button {
            model.select(model: m, provider: provider)
        } label: {
            HStack(spacing: DS.Space.md) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? DS.accent : .secondary)
                Text(m).font(DS.Typography.body)
                Spacer()
            }
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? DS.accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Divider().opacity(0.4)
            HStack {
                Text("Need a different provider?").font(DS.Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.openWizard() } label: { Label("Sign in via terminal…", systemImage: "terminal") }
                    .buttonStyle(.hlSecondary)
            }
        }
        .padding(.top, DS.Space.sm)
    }
}
