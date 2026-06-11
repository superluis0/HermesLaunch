import SwiftUI

// MARK: - Kanban board
//
// Native board over `hermes kanban` (JSON-backed). Watch swarm agents work tasks
// in real time, and drive the full lifecycle: create, promote, assign, comment,
// block/unblock, complete, archive, and dispatch agents.

struct KanbanTask: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var body: String?
    var assignee: String?
    var status: String
    var priority: Int?
    var createdAt: Int?
    var startedAt: Int?
    var completedAt: Int?
}

final class KanbanModel: ObservableObject {
    @Published var tasks: [KanbanTask] = []
    @Published var loading = false
    @Published var errorText: String?
    @Published var autoRefresh = true
    @Published var lastDispatch: String?

    /// Pipeline columns, left → right.
    static let columns = ["triage", "todo", "ready", "running", "review", "blocked", "done"]

    private let exec: ([String]) -> String
    private var timer: Timer?

    init(exec: @escaping ([String]) -> String) { self.exec = exec }

    func tasks(in status: String) -> [KanbanTask] {
        tasks.filter { $0.status == status }
            .sorted {
                let p0 = $0.priority ?? 0, p1 = $1.priority ?? 0
                return p0 == p1 ? $0.id < $1.id : p0 > p1
            }
    }

    func load() {
        DispatchQueue.main.async { self.loading = self.tasks.isEmpty }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.exec(["kanban", "list", "--json"])
            let parsed = Self.parse(out)
            DispatchQueue.main.async {
                self.loading = false
                if let parsed { self.tasks = parsed; self.errorText = nil }
                else if self.tasks.isEmpty { self.errorText = out.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }

    static func parse(_ text: String) -> [KanbanTask]? {
        guard let data = text.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode([KanbanTask].self, from: data)
    }

    // MARK: Lifecycle actions (run off-main, then reload)

    private func run(_ args: [String], then reload: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.exec(args)
            if reload { self.load() }
        }
    }

    func create(title: String, body: String, priority: Int) {
        var args = ["kanban", "create", title]
        if !body.isEmpty { args += ["--body", body] }
        if priority != 0 { args += ["--priority", String(priority)] }
        run(args)
    }
    func promote(_ id: String)  { run(["kanban", "promote", id]) }
    func complete(_ id: String) { run(["kanban", "complete", id]) }
    func unblock(_ id: String)  { run(["kanban", "unblock", id]) }
    func archive(_ id: String)  { run(["kanban", "archive", id]) }
    func block(_ id: String, reason: String)  { run(["kanban", "block", id] + (reason.isEmpty ? [] : [reason])) }
    func assign(_ id: String, profile: String) { run(["kanban", "assign", id, profile]) }
    func comment(_ id: String, text: String)   { run(["kanban", "comment", id, text]) }

    func dispatch(max: Int = 4) {
        DispatchQueue.main.async { self.lastDispatch = "Dispatching…" }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.exec(["kanban", "dispatch", "--max", String(max)])
            DispatchQueue.main.async { self.lastDispatch = out.trimmingCharacters(in: .whitespacesAndNewlines) }
            self.load()
        }
    }

    // MARK: Auto-refresh
    //
    // Refcounted: during the shell's pane crossfade the incoming view's onAppear
    // can fire *before* the outgoing view's onDisappear, so a plain start/stop
    // pair could kill the freshly started timer. Stop only when no view remains.

    private var viewCount = 0

    func viewAppeared() {
        viewCount += 1
        startAuto()
    }
    func viewDisappeared() {
        viewCount = max(0, viewCount - 1)
        if viewCount == 0 { stopAuto() }
    }

    private func startAuto() {
        load()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.autoRefresh else { return }
            self.load()
        }
    }
    private func stopAuto() { timer?.invalidate(); timer = nil }
}

// MARK: - View

struct KanbanBoardView: View {
    @ObservedObject var model: KanbanModel
    @State private var prompt: KanbanPrompt?
    @State private var showNewTask = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let err = model.errorText, model.tasks.isEmpty {
                emptyState(err)
            } else {
                board
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(DS.bg)
        .onAppear { model.viewAppeared() }
        .onDisappear { model.viewDisappeared() }
        .sheet(isPresented: $showNewTask) { newTaskSheet }
        .sheet(item: $prompt) { p in promptSheet(p) }
    }

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "rectangle.split.3x1.fill").foregroundStyle(DS.accent)
            Text("Kanban").font(DS.Typography.title)
            if model.loading { ProgressView().controlSize(.small) }
            Spacer()
            if let d = model.lastDispatch, !d.isEmpty {
                Text(d).font(DS.Typography.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 220)
            }
            Toggle("Live", isOn: $model.autoRefresh).toggleStyle(.switch).controlSize(.small)
            Button { model.dispatch() } label: { Label("Dispatch", systemImage: "bolt.fill") }
                .buttonStyle(.hlSecondary).help("Spawn agents for ready tasks")
            Button { showNewTask = true } label: { Label("New Task", systemImage: "plus") }
                .buttonStyle(.hlPrimary)
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
    }

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                ForEach(KanbanModel.columns, id: \.self) { col in
                    column(col)
                }
            }
            .padding(DS.Space.md)
        }
    }

    private func column(_ status: String) -> some View {
        let items = model.tasks(in: status)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                HLStatusDot(color: color(for: status))
                Text(status.capitalized).font(DS.Typography.heading)
                Text("\(items.count)").font(DS.Typography.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.xs)
            ScrollView {
                LazyVStack(spacing: DS.Space.sm) {
                    ForEach(items) { task in card(task) }
                }
            }
        }
        .frame(width: 244)
        .padding(DS.Space.sm)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }

    private func card(_ task: KanbanTask) -> some View {
        KanbanCardView(task: task, model: model, prompt: $prompt)
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: DS.Space.md) {
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No tasks yet").font(DS.Typography.heading)
            Text(message.isEmpty ? "Create a task to get started." : message)
                .font(DS.Typography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { showNewTask = true } label: { Label("New Task", systemImage: "plus") }.buttonStyle(.hlPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(DS.Space.xl)
    }

    private func color(for status: String) -> Color {
        switch status {
        case "running": return DS.accent
        case "done":    return DS.success
        case "blocked": return DS.danger
        case "review":  return DS.warning
        default:        return .secondary
        }
    }

    // MARK: Sheets

    @State private var newTitle = ""
    @State private var newBody = ""
    @State private var newPriority = 0

    private var newTaskSheet: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("New Task").font(DS.Typography.title)
            TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder)
            TextField("Body (optional)", text: $newBody, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6)
            Stepper("Priority: \(newPriority)", value: $newPriority, in: 0...10)
            HStack {
                Spacer()
                Button("Cancel") { showNewTask = false; resetNew() }.buttonStyle(.hlSecondary)
                Button("Create") {
                    let t = newTitle.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { model.create(title: t, body: newBody, priority: newPriority) }
                    showNewTask = false; resetNew()
                }.buttonStyle(.hlPrimary).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.lg).frame(width: 420)
    }

    private func resetNew() { newTitle = ""; newBody = ""; newPriority = 0 }

    @State private var promptText = ""
    private func promptSheet(_ p: KanbanPrompt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(p.kind.title).font(DS.Typography.heading)
            TextField(p.kind.placeholder, text: $promptText).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { prompt = nil; promptText = "" }.buttonStyle(.hlSecondary)
                Button(p.kind.action) {
                    let text = promptText.trimmingCharacters(in: .whitespaces)
                    switch p.kind {
                    case .block:   model.block(p.taskId, reason: text)
                    case .assign:  if !text.isEmpty { model.assign(p.taskId, profile: text) }
                    case .comment: if !text.isEmpty { model.comment(p.taskId, text: text) }
                    }
                    prompt = nil; promptText = ""
                }.buttonStyle(.hlPrimary)
            }
        }
        .padding(DS.Space.lg).frame(width: 380)
    }
}

/// One task card. Separate view so it can carry hover state (and, later, drag).
private struct KanbanCardView: View {
    let task: KanbanTask
    @ObservedObject var model: KanbanModel
    @Binding var prompt: KanbanPrompt?
    @State private var hovering = false

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(alignment: .top) {
                    Text(task.title).font(DS.Typography.body.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    Menu {
                        Button("Promote ▸") { model.promote(task.id) }
                        Button("Complete ✓") { model.complete(task.id) }
                        if task.status == "blocked" { Button("Unblock") { model.unblock(task.id) } }
                        else { Button("Block…") { prompt = .init(kind: .block, taskId: task.id) } }
                        Button("Assign…") { prompt = .init(kind: .assign, taskId: task.id) }
                        Button("Comment…") { prompt = .init(kind: .comment, taskId: task.id) }
                        Divider()
                        Button("Archive", role: .destructive) { model.archive(task.id) }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                        .menuStyle(.borderlessButton).frame(width: 22)
                }
                if let b = task.body, !b.isEmpty {
                    Text(b).font(DS.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: DS.Space.sm) {
                    if task.status == "running" {
                        ProgressView().controlSize(.small)
                    }
                    if let a = task.assignee, !a.isEmpty {
                        Label(a, systemImage: "person.fill").font(DS.Typography.micro).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(task.id).font(DS.Typography.micro).foregroundStyle(.tertiary)
                }
            }
        }
        .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: 6, y: 2)
        .offset(y: hovering ? -1 : 0)
        .animation(DS.Motion.quick, value: hovering)
        .onHover { hovering = $0 }
    }
}

struct KanbanPrompt: Identifiable {
    enum Kind {
        case block, assign, comment
        var title: String { self == .block ? "Block task" : self == .assign ? "Assign task" : "Add comment" }
        var placeholder: String { self == .block ? "Reason (optional)" : self == .assign ? "Profile name" : "Comment" }
        var action: String { self == .block ? "Block" : self == .assign ? "Assign" : "Comment" }
    }
    let id = UUID()
    let kind: Kind
    let taskId: String
}
