import Cocoa
import SwiftUI

// Feature 10 · Phase 3 — Sessions browser over `hermes sessions`.

struct SessionRow: Identifiable {
    let id: String
    var title: String
    var preview: String
    var lastActive: String
}

struct SessionStats {
    var total: Int?
    var messages: Int?
    var dbSize: String?
}

final class SessionsModel: ObservableObject {
    @Published var sessions: [SessionRow] = []
    @Published var stats = SessionStats()
    @Published var loading = false
    @Published var query = ""

    private let exec: ([String]) -> String
    let onResume: (String) -> Void

    init(exec: @escaping ([String]) -> String, onResume: @escaping (String) -> Void) {
        self.exec = exec; self.onResume = onResume
    }

    var filtered: [SessionRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    func load() {
        DispatchQueue.main.async { self.loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = SessionsModel.parse(self.exec(["sessions", "list", "--limit", "200"]))
            let stats = SessionsModel.parseStats(self.exec(["sessions", "stats"]))
            DispatchQueue.main.async { self.sessions = rows; self.stats = stats; self.loading = false }
        }
    }

    func rename(_ id: String, _ title: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.exec(["sessions", "rename", id, title]); self.load() }
    }
    func delete(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.exec(["sessions", "delete", id, "--yes"]); self.load() }
    }

    // Columns: Title | Preview | Last Active | ID (fixed width). ID is always the
    // last token; Last Active the one before it. Accepts UUID and timestamp IDs.
    static func parse(_ text: String) -> [SessionRow] {
        var rows: [SessionRow] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.allSatisfy({ $0 == "─" || $0 == "-" || $0 == "=" }) { continue }
            let parts = splitMulti(line)
            guard parts.count >= 2, let id = parts.last else { continue }
            if id == "ID" || parts.first == "Title" { continue }   // header
            let lastActive = parts.count >= 2 ? parts[parts.count - 2] : ""
            let title = (parts.first ?? "—")
            let preview = parts.count >= 4 ? parts[1] : ""
            rows.append(SessionRow(id: id,
                                   title: (title == "—" || title.isEmpty) ? "Untitled" : title,
                                   preview: preview,
                                   lastActive: lastActive))
        }
        return rows
    }

    static func parseStats(_ text: String) -> SessionStats {
        var s = SessionStats()
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if let n = intAfter(line, "Total sessions:") { s.total = n }
            else if let n = intAfter(line, "Total messages:") { s.messages = n }
            else if let r = line.range(of: "Database size:") {
                s.dbSize = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    private static func intAfter(_ line: String, _ marker: String) -> Int? {
        guard let r = line.range(of: marker) else { return nil }
        let digits = line[r.upperBound...].filter { $0.isNumber }
        return Int(digits)
    }

    private static func splitMulti(_ line: String) -> [String] {
        var parts: [String] = []; var cur = ""; var run = 0
        for ch in line {
            if ch == " " { run += 1; if run == 1 { cur.append(ch) } }
            else {
                if run >= 2, !cur.trimmingCharacters(in: .whitespaces).isEmpty {
                    parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
                }
                run = 0; cur.append(ch)
            }
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }
}

// MARK: - View

struct SessionsView: View {
    @ObservedObject var model: SessionsModel
    @State private var renaming: SessionRow?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            if model.filtered.isEmpty {
                Text(model.loading ? "Loading…" : "No sessions").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filtered) { s in
                            row(s)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.load() }
        .sheet(item: $renaming) { s in renameSheet(s) }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions").font(.system(size: 17, weight: .bold))
                Text(statsLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var statsLine: String {
        var bits: [String] = []
        if let t = model.stats.total { bits.append("\(t) sessions") }
        if let m = model.stats.messages { bits.append("\(m) messages") }
        if let d = model.stats.dbSize { bits.append(d) }
        return bits.isEmpty ? "—" : bits.joined(separator: "  ·  ")
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search title, preview, or id", text: $model.query).textFieldStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func row(_ s: SessionRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !s.preview.isEmpty {
                    Text(s.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(s.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(s.lastActive).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            Menu {
                Button("Resume") { model.onResume(s.id) }
                Button("Rename…") { renameText = s.title == "Untitled" ? "" : s.title; renaming = s }
                Button("Delete", role: .destructive) { model.delete(s.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.onResume(s.id) }
    }

    private func renameSheet(_ s: SessionRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Session").font(.system(size: 15, weight: .bold))
            TextField("Title", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { model.rename(s.id, t) }
                    renaming = nil
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
    }
}
