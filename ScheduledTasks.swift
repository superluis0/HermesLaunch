import Cocoa
import SwiftUI

// Feature 10 · Phase 1 — Scheduled Tasks: a native panel over `hermes cron`.

struct CronJob: Identifiable {
    let id: String
    var name: String
    var schedule: String
    var repeatStr: String
    var nextRun: String
    var deliver: String
    var active: Bool
}

final class CronModel: ObservableObject {
    @Published var jobs: [CronJob] = []
    @Published var schedulerRunning = false
    @Published var loading = false

    private let exec: ([String]) -> String   // wraps captureHermes (blocks; call off-main)
    init(exec: @escaping ([String]) -> String) { self.exec = exec }

    func load() {
        DispatchQueue.main.async { self.loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = self.exec(["cron", "list", "--all"])
            let status = self.exec(["cron", "status"])
            let jobs = CronModel.parse(list)
            let running = status.lowercased().contains("running")
            DispatchQueue.main.async {
                self.jobs = jobs
                self.schedulerRunning = running
                self.loading = false
            }
        }
    }

    func create(schedule: String, prompt: String, deliver: String, name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var args = ["cron", "create", schedule]
            if !prompt.isEmpty { args.append(prompt) }
            args += ["--deliver", deliver]
            if !name.isEmpty { args += ["--name", name] }
            _ = self.exec(args)
            self.load()
        }
    }

    func action(_ verb: String, _ id: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.exec(["cron", verb, id])
            self.load()
        }
    }

    // Parse the block format:
    //   <id> [active]
    //     Name:      …
    //     Schedule:  …
    //     Repeat:    …
    //     Next run:  …
    //     Deliver:   …
    static func parse(_ text: String) -> [CronJob] {
        var jobs: [CronJob] = []
        var cur: CronJob?
        func flush() { if let c = cur { jobs.append(c); cur = nil } }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if let open = line.firstIndex(of: "["), line.hasSuffix("]"),
               line.distance(from: line.startIndex, to: open) >= 6 {
                // header: "<id> [status]"
                let id = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
                let status = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
                if id.allSatisfy({ $0.isHexDigit }) {
                    flush()
                    cur = CronJob(id: id, name: id, schedule: "", repeatStr: "", nextRun: "", deliver: "", active: status == "active")
                    continue
                }
            }
            guard cur != nil else { continue }
            if let v = value(line, "Name:")      { cur?.name = v }
            else if let v = value(line, "Schedule:") { cur?.schedule = v }
            else if let v = value(line, "Repeat:")   { cur?.repeatStr = v }
            else if let v = value(line, "Next run:") { cur?.nextRun = v }
            else if let v = value(line, "Deliver:")  { cur?.deliver = v }
        }
        flush()
        return jobs
    }

    private static func value(_ line: String, _ label: String) -> String? {
        guard line.hasPrefix(label) else { return nil }
        return String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }

    static func friendlyNextRun(_ s: String) -> String {
        if s.isEmpty { return "—" }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: s)
        if date == nil { let i2 = ISO8601DateFormatter(); i2.formatOptions = [.withInternetDateTime]; date = i2.date(from: s) }
        guard let d = date else { return s }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - View

struct ScheduledTasksView: View {
    @ObservedObject var model: CronModel
    @State private var showNew = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.jobs.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.jobs) { job in JobCard(job: job, model: model) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 540, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.load() }
        .sheet(isPresented: $showNew) { NewTaskSheet(model: model, isPresented: $showNew) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scheduled Tasks").font(.system(size: 17, weight: .bold))
                HStack(spacing: 5) {
                    Circle().fill(model.schedulerRunning ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.schedulerRunning ? "Scheduler running" : "Scheduler stopped (start the gateway)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            Button { showNew = true } label: { Label("New Task", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("No scheduled tasks").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            Text("Create one to run prompts on a schedule — e.g. a morning briefing.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
            Button { showNew = true } label: { Label("New Task", systemImage: "plus") }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobCard: View {
    let job: CronJob
    @ObservedObject var model: CronModel
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(job.active ? "active" : "paused")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill((job.active ? Color.green : Color.orange).opacity(0.2)))
                    .foregroundStyle(job.active ? Color.green : Color.orange)
            }
            row("clock", job.schedule + (job.repeatStr.isEmpty || job.repeatStr == "∞" ? "" : " · ×\(job.repeatStr)"))
            row("calendar", "Next: \(CronModel.friendlyNextRun(job.nextRun))")
            row("paperplane", job.deliver)
            HStack(spacing: 8) {
                Button { model.action("run", job.id) } label: { Label("Run now", systemImage: "play.fill") }
                if job.active {
                    Button { model.action("pause", job.id) } label: { Label("Pause", systemImage: "pause.fill") }
                } else {
                    Button { model.action("resume", job.id) } label: { Label("Resume", systemImage: "play") }
                }
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
        .confirmationDialog("Delete “\(job.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.action("remove", job.id) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct NewTaskSheet: View {
    @ObservedObject var model: CronModel
    @Binding var isPresented: Bool

    // All modes feed the one `hermes cron` scheduler. Once/Every emit interval syntax,
    // Daily/Weekly emit cron expressions, and `.cron` ("Custom") is the raw escape hatch.
    enum Mode: String, CaseIterable { case once = "Once", every = "Every", daily = "Daily", weekly = "Weekly", cron = "Custom" }
    enum Unit: String, CaseIterable { case minute = "minutes", hour = "hours", day = "days"
        var short: String { switch self { case .minute: return "m"; case .hour: return "h"; case .day: return "d" } } }

    @State private var mode: Mode = .every
    @State private var count = 1
    @State private var unit: Unit = .hour
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdays: Set<Int> = [1, 3, 5]
    @State private var cronText = ""
    @State private var prompt = ""
    @State private var name = ""
    @State private var deliver = "local"

    private let deliverOptions = ["local", "origin", "telegram", "discord", "signal"]
    private let weekdaySymbols: [(Int, String)] = [(0, "S"), (1, "M"), (2, "T"), (3, "W"), (4, "T"), (5, "F"), (6, "S")]

    private var scheduleString: String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: time), m = cal.component(.minute, from: time)
        switch mode {
        case .once:   return "\(count)\(unit.short)"
        case .every:  return "every \(count)\(unit.short)"
        case .daily:  return "\(m) \(h) * * *"
        case .weekly: return weekdays.isEmpty ? "" : "\(m) \(h) * * \(weekdays.sorted().map(String.init).joined(separator: ","))"
        case .cron:   return cronText.trimmingCharacters(in: .whitespaces)
        }
    }

    private var unitWord: String { count == 1 ? String(unit.rawValue.dropLast()) : unit.rawValue }
    private var humanReadable: String {
        switch mode {
        case .once:   return "Once, \(count) \(unitWord) from now"
        case .every:  return "Every \(count) \(unitWord)"
        case .daily:  return "Daily at \(timeString)"
        case .weekly:
            let days = weekdays.sorted().map { ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][$0] }.joined(separator: ", ")
            return weekdays.isEmpty ? "Pick at least one day" : "\(days) at \(timeString)"
        case .cron:   return cronText.isEmpty ? "Enter a cron expression" : cronText
        }
    }
    private var timeString: String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: time)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Scheduled Task").font(.system(size: 15, weight: .bold))

            field("Schedule") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)

                    scheduleControls

                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(humanReadable).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("→ \(scheduleString)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }

            field("Task / prompt") {
                TextEditor(text: $prompt).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
            HStack(spacing: 14) {
                field("Name (optional)") { TextField("Morning briefing", text: $name).textFieldStyle(.roundedBorder) }
                field("Deliver to") {
                    Picker("", selection: $deliver) {
                        ForEach(deliverOptions, id: \.self) { Text($0.capitalized).tag($0) }
                    }.labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.create(schedule: scheduleString,
                                 prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                 deliver: deliver, name: name.trimmingCharacters(in: .whitespaces))
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(scheduleString.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    @ViewBuilder private var scheduleControls: some View {
        switch mode {
        case .once, .every:
            HStack(spacing: 8) {
                Stepper(value: $count, in: 1...999) { Text("\(count)").font(.system(size: 13, weight: .medium)).frame(minWidth: 28) }
                Picker("", selection: $unit) {
                    ForEach(Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 120)
                Spacer()
            }
        case .daily:
            DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
        case .weekly:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(weekdaySymbols, id: \.0) { (idx, sym) in
                        let on = weekdays.contains(idx)
                        Text(sym).font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .onTapGesture { if on { weekdays.remove(idx) } else { weekdays.insert(idx) } }
                    }
                }
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
            }
        case .cron:
            VStack(alignment: .leading, spacing: 4) {
                TextField("0 9 * * *", text: $cronText).textFieldStyle(.roundedBorder)
                Text("Raw cron expression — min hour day month weekday (e.g. 0 */3 * * 1-5).")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
