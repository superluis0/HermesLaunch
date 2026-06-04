import Cocoa
import SwiftUI

// Feature 10 · Phase 4 — Skills browser over `hermes skills`.

struct SkillSearchItem: Identifiable, Decodable {
    var id: String { identifier }
    let name: String
    let identifier: String
    let source: String?
    let trustLevel: String?
    let description: String?
}

struct InstalledSkill: Identifiable {
    var id: String { name + "|" + category }
    let name: String
    let category: String
    let source: String
    let status: String
    var truncated: Bool { name.hasSuffix("…") }
    var removable: Bool { !truncated && source != "builtin" && source != "local" }
}

final class SkillsModel: ObservableObject {
    enum Tab { case search, installed }
    @Published var tab: Tab = .search
    @Published var query = ""
    @Published var results: [SkillSearchItem] = []
    @Published var installed: [InstalledSkill] = []
    @Published var busy = false
    @Published var installing: Set<String> = []
    @Published var note: String?

    private let exec: ([String]) -> String
    init(exec: @escaping ([String]) -> String) { self.exec = exec }

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        busy = true; note = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let json = self.exec(["skills", "search", q, "--json", "--limit", "30"])
            let items = SkillsModel.decode(json)
            DispatchQueue.main.async { self.results = items; self.busy = false
                if items.isEmpty { self.note = "No results for “\(q)”." } }
        }
    }

    func loadInstalled() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = SkillsModel.parseInstalled(self.exec(["skills", "list"]))
            DispatchQueue.main.async { self.installed = parsed; self.busy = false }
        }
    }

    func install(_ item: SkillSearchItem) {
        installing.insert(item.identifier)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.exec(["skills", "install", item.identifier, "--yes"])
            DispatchQueue.main.async {
                self.installing.remove(item.identifier)
                let ok = out.lowercased().contains("install") && !out.lowercased().contains("blocked") && !out.lowercased().contains("error")
                self.note = ok ? "Installed “\(item.name)”." : "“\(item.name)”: \(String(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160)))"
            }
        }
    }

    func uninstall(_ s: InstalledSkill) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.exec(["skills", "uninstall", s.name, "--yes"])
            DispatchQueue.main.async { self.note = "Uninstalled “\(s.name)”." }
            let parsed = SkillsModel.parseInstalled(self.exec(["skills", "list"]))
            DispatchQueue.main.async { self.installed = parsed; self.busy = false }
        }
    }

    func updateAll() {
        busy = true; note = "Updating skills…"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.exec(["skills", "update"])
            let parsed = SkillsModel.parseInstalled(self.exec(["skills", "list"]))
            DispatchQueue.main.async { self.installed = parsed; self.busy = false; self.note = "Skills updated." }
        }
    }

    static func decode(_ json: String) -> [SkillSearchItem] {
        guard let data = json.data(using: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return (try? dec.decode([SkillSearchItem].self, from: data)) ?? []
    }

    // Rich box-table → rows. Splitting on "│" isolates data rows (header uses ┃).
    static func parseInstalled(_ text: String) -> [InstalledSkill] {
        var out: [InstalledSkill] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard line.contains("│") else { continue }
            var cells = line.components(separatedBy: "│").map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            guard cells.count == 5, cells[0] != "Name", !cells[0].isEmpty else { continue }
            out.append(InstalledSkill(name: cells[0], category: cells[1], source: cells[2], status: cells[4]))
        }
        return out
    }
}

// MARK: - View

struct SkillsView: View {
    @ObservedObject var model: SkillsModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                Text("Search").tag(SkillsModel.Tab.search)
                Text("Installed").tag(SkillsModel.Tab.installed)
            }
            .labelsHidden().pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .onChange(of: model.tab) { _, t in if t == .installed && model.installed.isEmpty { model.loadInstalled() } }

            Divider()
            if model.tab == .search { searchTab } else { installedTab }

            if let note = model.note {
                Divider()
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search skills (e.g. pdf, github, maps)", text: $model.query)
                    .textFieldStyle(.plain).onSubmit { model.search() }
                if model.busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Button("Search") { model.search() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results) { item in
                        resultRow(item); Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func resultRow(_ item: SkillSearchItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13, weight: .semibold))
                    if let t = item.trustLevel { badge(t, color: t == "trusted" ? .green : .secondary) }
                    if let s = item.source { badge(s, color: .blue) }
                }
                if let d = item.description, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(item.identifier).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.installing.contains(item.identifier) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 64)
            } else {
                Button("Install") { model.install(item) }.controlSize(.small).fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var installedTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.installed.count) installed").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { model.loadInstalled() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button("Update") { model.updateAll() }.help("Update hub-installed skills")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.installed) { s in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: 13, weight: .medium))
                                HStack(spacing: 6) {
                                    if !s.category.isEmpty { badge(s.category, color: .secondary) }
                                    badge(s.source, color: .blue)
                                    badge(s.status, color: s.status == "enabled" ? .green : .orange)
                                }
                            }
                            Spacer(minLength: 8)
                            if s.removable {
                                Button(role: .destructive) { model.uninstall(s) } label: { Image(systemName: "trash") }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .onAppear { if model.installed.isEmpty { model.loadInstalled() } }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
