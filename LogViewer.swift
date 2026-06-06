import Cocoa
import SwiftUI

// Feature 10 · Phase 3 — In-app log viewer over `hermes logs`.

final class LogModel: ObservableObject {
    @Published var text = ""
    @Published var logName = "agent"          // agent · errors · gateway · gui
    @Published var level = "All"              // All · DEBUG · INFO · WARNING · ERROR
    @Published var following = false
    @Published var loading = false

    static let logs = ["agent", "errors", "gateway", "gui"]
    static let levels = ["All", "DEBUG", "INFO", "WARNING", "ERROR"]
    private let lines = 500

    private let exec: ([String]) -> String
    private var timer: Timer?
    init(exec: @escaping ([String]) -> String) { self.exec = exec }

    func refresh() {
        let name = logName, lvl = level
        DispatchQueue.main.async { self.loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            var args = ["logs", name, "-n", String(self.lines)]
            if lvl != "All" { args += ["--level", lvl] }
            let out = self.exec(args)
            DispatchQueue.main.async {
                self.text = out.trimmingCharacters(in: .whitespacesAndNewlines)
                self.loading = false
            }
        }
    }

    func setFollowing(_ on: Bool) {
        following = on
        timer?.invalidate(); timer = nil
        if on {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

struct LogView: View {
    @ObservedObject var model: LogModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.text.isEmpty ? "—" : model.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("END")
                }
                .onChange(of: model.text) { proxy.scrollTo("END", anchor: .bottom) }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(DS.bg)
        .onAppear { model.refresh() }
        .onDisappear { model.stop() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.logName) {
                ForEach(LogModel.logs, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden().frame(width: 120)
            .onChange(of: model.logName) { model.refresh() }

            Picker("", selection: $model.level) {
                ForEach(LogModel.levels, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 110)
            .onChange(of: model.level) { model.refresh() }

            Spacer()

            Toggle("Follow", isOn: Binding(
                get: { model.following },
                set: { model.setFollowing($0) }
            )).toggleStyle(.switch)

            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
