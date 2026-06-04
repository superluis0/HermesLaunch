import Cocoa
import SwiftUI
import Charts

// Feature 6 — vibrant SwiftUI + Swift Charts usage dashboard, hosted in an AppKit
// window. Fed by the existing `hermes insights` parser (HermesLaunch.swift).

// MARK: - Data model

struct CategoryStat: Identifiable {
    let id = UUID()
    let name: String
    let value: Int          // tokens (models/platforms) or calls (top tools)
    let subtitle: String?
}

struct DayStat: Identifiable {
    let id = UUID()
    let day: String
    let count: Int
}

struct UsageStats {
    var period: String?
    var sessions: Int?
    var messages: Int?
    var toolCalls: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var activeTime: String?
    var models: [CategoryStat] = []
    var platforms: [CategoryStat] = []
    var topTools: [CategoryStat] = []
    var weekday: [DayStat] = []

    var hasData: Bool { (sessions ?? 0) > 0 || !models.isEmpty }
}

final class UsageModel: ObservableObject {
    @Published var stats: UsageStats?
    @Published var days: Int = 7
    @Published var loading = false
    private let fetch: (Int) -> UsageStats

    init(fetch: @escaping (Int) -> UsageStats) { self.fetch = fetch }

    func load() {
        loading = true
        let d = days
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let s = self.fetch(d)
            DispatchQueue.main.async { self.stats = s; self.loading = false }
        }
    }
}

// MARK: - Helpers

func compactInt(_ n: Int) -> String {
    if n < 1_000 { return "\(n)" }
    if n < 1_000_000 {
        return String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0k", with: "k")
    }
    return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
}

private let vibrantPalette: [Color] = [
    Color(red: 0.30, green: 0.50, blue: 1.00),
    Color(red: 0.62, green: 0.35, blue: 0.96),
    Color(red: 0.95, green: 0.36, blue: 0.62),
    Color(red: 1.00, green: 0.58, blue: 0.20),
    Color(red: 0.20, green: 0.78, blue: 0.62),
    Color(red: 0.36, green: 0.74, blue: 0.98),
    Color(red: 0.98, green: 0.78, blue: 0.25),
    Color(red: 0.55, green: 0.55, blue: 0.60),
]

// MARK: - Dashboard

struct UsageDashboardView: View {
    @ObservedObject var model: UsageModel
    var onOpenFull: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content.padding(16)
            }
        }
        .frame(minWidth: 540, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if model.stats == nil { model.load() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage").font(.system(size: 17, weight: .bold))
                if let p = model.stats?.period {
                    Text(p).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("", selection: $model.days) {
                Text("Today").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            .onChange(of: model.days) { model.load() }

            Button(action: onOpenFull) {
                Image(systemName: "safari").imageScale(.medium)
            }
            .help("Open full web dashboard")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        if let s = model.stats, s.hasData {
            VStack(alignment: .leading, spacing: 18) {
                statCards(s)
                if (s.inputTokens ?? 0) + (s.outputTokens ?? 0) > 0 {
                    ChartCard(title: "Token split", systemImage: "chart.pie.fill") {
                        TokenSplit(input: s.inputTokens ?? 0, output: s.outputTokens ?? 0)
                    }
                }
                if !s.models.isEmpty {
                    ChartCard(title: "Tokens by model", systemImage: "cpu") {
                        CategoryBars(items: s.models, valueLabel: "Tokens", format: compactInt)
                    }
                }
                if s.weekday.contains(where: { $0.count > 0 }) {
                    ChartCard(title: "Activity", systemImage: "calendar") {
                        WeekdayChart(days: s.weekday)
                    }
                }
                if !s.topTools.isEmpty {
                    ChartCard(title: "Top tools", systemImage: "hammer.fill") {
                        CategoryBars(items: s.topTools, valueLabel: "Calls", format: { "\($0)" })
                    }
                }
                if !s.platforms.isEmpty {
                    ChartCard(title: "Platforms", systemImage: "bubble.left.and.bubble.right.fill") {
                        CategoryBars(items: s.platforms, valueLabel: "Tokens", format: compactInt)
                    }
                }
            }
        } else if model.loading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 70)
        } else {
            emptyState
        }
    }

    private func statCards(_ s: UsageStats) -> some View {
        let cards: [(String, String, String, Color)] = [
            ("Sessions",   s.sessions.map { "\($0)" } ?? "—",   "bubble.left.fill",          vibrantPalette[0]),
            ("Total tokens", s.totalTokens.map(compactInt) ?? "—", "number",                  vibrantPalette[1]),
            ("Tool calls", s.toolCalls.map { "\($0)" } ?? "—",  "hammer.fill",                vibrantPalette[2]),
            ("Messages",   s.messages.map { "\($0)" } ?? "—",   "text.bubble.fill",           vibrantPalette[3]),
            ("Active time", s.activeTime ?? "—",                "clock.fill",                 vibrantPalette[4]),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(cards, id: \.0) { c in
                StatCard(title: c.0, value: c.1, systemImage: c.2, tint: c.3)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("No usage in this period").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
    }
}

// MARK: - Stat card

struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [tint.opacity(0.14), tint.opacity(0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.30), lineWidth: 1))
    }
}

// MARK: - Chart card shell

struct ChartCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1))
    }
}

// MARK: - Token split donut

struct TokenSplit: View {
    let input: Int
    let output: Int
    private var total: Int { input + output }
    private var inFrac: CGFloat { total > 0 ? CGFloat(input) / CGFloat(total) : 0 }

    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 16)
                Circle()
                    .trim(from: 0, to: inFrac)
                    .stroke(LinearGradient(colors: [vibrantPalette[0], vibrantPalette[5]], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: inFrac, to: 1)
                    .stroke(LinearGradient(colors: [vibrantPalette[1], vibrantPalette[2]], startPoint: .bottom, endPoint: .top),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(compactInt(total)).font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("tokens").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 124, height: 124)
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 12) {
                legend(color: vibrantPalette[0], label: "Input", value: input)
                legend(color: vibrantPalette[1], label: "Output", value: output)
            }
            Spacer()
        }
    }

    private func legend(color: Color, label: String, value: Int) -> some View {
        let pct = total > 0 ? Int((Double(value) / Double(total) * 100).rounded()) : 0
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(compactInt(value))  ·  \(pct)%").font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        }
    }
}

// MARK: - Category bar chart (models / tools / platforms)

struct CategoryBars: View {
    let items: [CategoryStat]
    let valueLabel: String
    let format: (Int) -> String

    var body: some View {
        Chart(items) { item in
            BarMark(
                x: .value(valueLabel, item.value),
                y: .value("Name", item.name)
            )
            .foregroundStyle(by: .value("Name", item.name))
            .cornerRadius(5)
            .annotation(position: .trailing, alignment: .leading) {
                Text(format(item.value)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .chartForegroundStyleScale(range: vibrantPalette)
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { _ in
                AxisValueLabel().font(.system(size: 11))
            }
        }
        .frame(height: CGFloat(items.count) * 30 + 12)
    }
}

// MARK: - Weekday activity

struct WeekdayChart: View {
    let days: [DayStat]

    var body: some View {
        Chart(days) { d in
            BarMark(
                x: .value("Day", d.day),
                y: .value("Sessions", d.count)
            )
            .foregroundStyle(LinearGradient(colors: [vibrantPalette[1], vibrantPalette[0]],
                                            startPoint: .top, endPoint: .bottom))
            .cornerRadius(5)
        }
        .chartXScale(domain: days.map { $0.day })
        .chartYAxis {
            AxisMarks(position: .leading) { AxisValueLabel().font(.system(size: 10)) }
        }
        .chartXAxis {
            AxisMarks { AxisValueLabel().font(.system(size: 10)) }
        }
        .frame(height: 150)
    }
}
