import SwiftUI

// MARK: - Tools & MCP manager
//
// Toggle Hermes toolsets (`hermes tools`) and manage MCP servers (`hermes mcp`).
// Toolsets parse from `hermes tools list`; toggles call enable/disable.

struct Toolset: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let label: String
    var enabled: Bool
}

final class ToolsMCPModel: ObservableObject {
    @Published var toolsets: [Toolset] = []
    @Published var mcpOutput = ""
    @Published var loading = false
    @Published var busyKeys: Set<String> = []

    private let exec: ([String]) -> String
    init(exec: @escaping ([String]) -> String) { self.exec = exec }

    /// Plain-language descriptions for the built-in toolsets (keyed by toolset name).
    static let descriptions: [String: String] = [
        "web": "Search the web and scrape page content for up-to-date information.",
        "browser": "Drive a real browser to navigate, click, and fill out sites.",
        "terminal": "Run shell commands and manage processes on this machine.",
        "file": "Read, write, and edit files on disk.",
        "code_execution": "Execute code in a sandbox and return the results.",
        "vision": "Analyze images and screenshots.",
        "video": "Analyze video content.",
        "image_gen": "Generate images from text prompts.",
        "video_gen": "Generate video from text prompts.",
        "x_search": "Search posts and profiles on X (Twitter).",
        "moa": "Mixture of Agents — blend several models for harder questions.",
        "tts": "Convert the agent's replies into spoken audio.",
        "skills": "Load and run installed skills (reusable agent abilities).",
        "todo": "Plan and track multi-step tasks while working.",
        "memory": "Persist facts and recall them across future sessions.",
        "context_engine": "Retrieve relevant context from your indexed knowledge.",
        "session_search": "Search across your past conversations.",
        "clarify": "Ask you clarifying questions when a request is ambiguous.",
        "delegation": "Spin up sub-agents to handle subtasks in parallel.",
        "cronjob": "Schedule recurring agent jobs.",
        "messaging": "Send and receive messages across platforms (Telegram, Discord, …).",
    ]

    func load() {
        DispatchQueue.main.async { self.loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let tools = Self.parseToolsets(self.exec(["tools", "list"]))
            let mcp = self.exec(["mcp", "list"]).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.toolsets = tools
                self.mcpOutput = mcp
                self.loading = false
            }
        }
    }

    func setEnabled(_ key: String, _ enabled: Bool) {
        DispatchQueue.main.async {
            self.busyKeys.insert(key)
            // Optimistic UI.
            if let i = self.toolsets.firstIndex(where: { $0.key == key }) { self.toolsets[i].enabled = enabled }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.exec(["tools", enabled ? "enable" : "disable", key])
            let tools = Self.parseToolsets(self.exec(["tools", "list"]))
            DispatchQueue.main.async { self.toolsets = tools; self.busyKeys.remove(key) }
        }
    }

    func mcpAdd(name: String, url: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.exec(["mcp", "add", name, "--url", url]); self.load()
        }
    }
    func mcpRemove(name: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.exec(["mcp", "remove", name]); self.load() }
    }

    // Lines like:  "  ✓ enabled  web  🔍 Web Search & Scraping"
    static func parseToolsets(_ text: String) -> [Toolset] {
        var result: [Toolset] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isEnabled: Bool
            if line.hasPrefix("✓") || line.contains(" enabled ") || line.hasSuffix(" enabled") { isEnabled = true }
            else if line.hasPrefix("✗") || line.contains(" disabled ") { isEnabled = false }
            else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // tokens: [mark, "enabled"/"disabled", key, label words…]
            guard tokens.count >= 3 else { continue }
            let key = tokens[2]
            // Skip the status word; label is the remainder (may start with an emoji).
            let label = tokens.count > 3 ? tokens[3...].joined(separator: " ") : key
            result.append(Toolset(key: key, label: label, enabled: isEnabled))
        }
        return result
    }
}

// MARK: - View

struct ToolsMCPView: View {
    @ObservedObject var model: ToolsMCPModel
    @State private var addName = ""
    @State private var addURL = ""
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    toolsetsSection
                    mcpSection
                }
                .padding(DS.Space.lg)
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.load() }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(DS.accent)
            Text("Tools & MCP").font(DS.Typography.title)
            if model.loading { ProgressView().controlSize(.small) }
            Spacer()
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
    }

    private var toolsetsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HLSectionHeader(title: "Toolsets", subtitle: "Enable or disable agent capabilities")
            ForEach(model.toolsets) { ts in
                HStack(alignment: .top, spacing: DS.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ts.label).font(DS.Typography.body)
                        if let desc = ToolsMCPModel.descriptions[ts.key] {
                            Text(desc).font(DS.Typography.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if model.busyKeys.contains(ts.key) { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { ts.enabled },
                        set: { model.setEnabled(ts.key, $0) }
                    )).labelsHidden().toggleStyle(.switch)
                }
                .padding(.vertical, DS.Space.xs)
                Divider().opacity(0.35)
            }
            if model.toolsets.isEmpty {
                Text("No toolsets reported.").font(DS.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                HLSectionHeader(title: "MCP Servers", subtitle: "Model Context Protocol connections")
                Button { showAdd = true } label: { Label("Add", systemImage: "plus") }.buttonStyle(.hlSecondary)
            }
            HLCard {
                Text(model.mcpOutput.isEmpty ? "No MCP servers configured." : model.mcpOutput)
                    .font(DS.Typography.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Add MCP Server").font(DS.Typography.heading)
            TextField("Name", text: $addName).textFieldStyle(.roundedBorder)
            TextField("Endpoint URL", text: $addURL).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showAdd = false; addName = ""; addURL = "" }.buttonStyle(.hlSecondary)
                Button("Add") {
                    let n = addName.trimmingCharacters(in: .whitespaces)
                    let u = addURL.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty && !u.isEmpty { model.mcpAdd(name: n, url: u) }
                    showAdd = false; addName = ""; addURL = ""
                }.buttonStyle(.hlPrimary)
                    .disabled(addName.trimmingCharacters(in: .whitespaces).isEmpty || addURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.lg).frame(width: 420)
    }
}
