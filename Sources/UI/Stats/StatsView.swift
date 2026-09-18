import Charts
import SwiftUI

struct StatsView: View {
    @ObservedObject var store: StatsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.records.isEmpty {
                    ContentUnavailableView("暂无统计数据", systemImage: "chart.bar",
                                           description: Text("翻译几次后这里会出现图表。"))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    summary
                    requestsPerDayChart
                    tokensByEngineChart
                    latencyChart
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("清空", role: .destructive) { store.clear() }
                    .disabled(store.records.isEmpty)
            }
        }
    }

    // MARK: - Summary tiles

    private var summary: some View {
        HStack(spacing: 16) {
            // Not "总请求": the store keeps only the most recent
            // `StatsStore.maxRecords`, so once that many have gone through, this
            // number stops moving and the label would be a lie.
            tile("已记录请求", "\(store.records.count)",
                 caption: store.isAtCapacity ? "最近 \(store.records.count) 次" : nil)
            tile("成功率", successRateText, caption: failureCaption)
            tile("总 Token", totalTokens.map(compact) ?? "—")
            tile("平均延迟", String(format: "%.1fs", avgLatency))
        }
    }

    /// Rounded to whole percent only when nothing failed. With thousands of
    /// records a single failure is 0.02%, and "%.0f%%" printed that as a clean
    /// 100% — the rate looked perfect while the failures sat right there in the
    /// store, invisible in the chart too (one bar segment in eight hundred).
    private var successRateText: String {
        let failures = store.records.count - successCount
        if failures == 0 { return "100%" }
        return String(format: "%.2f%%", successRate * 100)
    }

    /// The count is what actually tells you something once the rate rounds to
    /// nothing: "4 次失败" is legible where "99.92%" is easy to skim past.
    private var failureCaption: String? {
        let failures = store.records.filter { $0.status == .failed }.count
        let cancelled = store.records.filter { $0.status == .cancelled }.count
        var parts: [String] = []
        if failures > 0 { parts.append("失败 \(failures)") }
        if cancelled > 0 { parts.append("取消 \(cancelled)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func tile(_ label: String, _ value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit()
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }

    // MARK: - Charts

    private var requestsPerDayChart: some View {
        section("每日请求数") {
            Chart(requestsPerDay, id: \.self) { item in
                // `plotted`, not `count`: see `StatsChartLayout` — a lone
                // failure among hundreds is otherwise sub-pixel.
                BarMark(x: .value("日期", item.day, unit: .day),
                        y: .value("请求数", item.plotted))
                .foregroundStyle(by: .value("状态", item.status))
            }
            .chartForegroundStyleScale([
                "成功": Color.accentColor, "失败": Color.red, "取消": Color.gray,
            ])
            .frame(height: 200)
        }
    }

    private var tokensByEngineChart: some View {
        section("各引擎 Token 用量") {
            if tokensByEngine.isEmpty {
                Text("provider 未返回 token 用量。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(tokensByEngine, id: \.engine) { item in
                    BarMark(x: .value("引擎", item.engine),
                            y: .value("Token", item.tokens))
                    .foregroundStyle(Color.accentColor)
                }
                .frame(height: 200)
            }
        }
    }

    private var latencyChart: some View {
        section("延迟分布") {
            Chart(latencyBuckets, id: \.label) { item in
                BarMark(x: .value("区间", item.label),
                        y: .value("次数", item.count))
                .foregroundStyle(Color.teal)
            }
            .frame(height: 200)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    // MARK: - Aggregations

    private var successCount: Int {
        store.records.filter { $0.status == .success }.count
    }

    private var successRate: Double {
        guard !store.records.isEmpty else { return 0 }
        return Double(successCount) / Double(store.records.count)
    }

    private var totalTokens: Int? {
        let sum = store.records.compactMap(\.totalTokens).reduce(0, +)
        return sum > 0 ? sum : nil
    }

    private var avgLatency: Double {
        guard !store.records.isEmpty else { return 0 }
        return store.records.map(\.durationSeconds).reduce(0, +) / Double(store.records.count)
    }

    private struct DayBucket: Hashable {
        let day: Date
        let status: String
        let count: Int
        /// Bar height, which differs from `count` only where a segment would
        /// otherwise be invisible. See `StatsChartLayout`.
        let plotted: Double
    }

    private var requestsPerDay: [DayBucket] {
        let cal = Calendar.current
        var byDay: [Date: [String: Int]] = [:]
        for r in store.records {
            let day = cal.startOfDay(for: r.date)
            byDay[day, default: [:]][statusLabel(r.status), default: 0] += 1
        }
        let axisMax = byDay.values.map { $0.values.reduce(0, +) }.max() ?? 0
        return byDay.keys.sorted().flatMap { day -> [DayBucket] in
            let counts = byDay[day] ?? [:]
            // Stable order, so the stack reads the same way every day.
            let segments = Self.statusOrder
                .filter { counts[$0] != nil }
                .map { (status: $0, count: counts[$0] ?? 0) }
            return StatsChartLayout.plotted(
                segments: segments, axisMax: axisMax, successLabel: Self.successLabel
            ).map { DayBucket(day: day, status: $0.status, count: $0.count, plotted: $0.plotted) }
        }
    }

    private static let successLabel = "成功"
    private static let statusOrder = ["成功", "失败", "取消"]

    private var tokensByEngine: [(engine: String, tokens: Int)] {
        var sums: [String: Int] = [:]
        for r in store.records {
            if let t = r.totalTokens { sums[r.engineName, default: 0] += t }
        }
        return sums.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    private var latencyBuckets: [(label: String, count: Int)] {
        let bounds: [(String, ClosedRange<Double>)] = [
            ("<1s", 0...1), ("1–3s", 1...3), ("3–5s", 3...5), ("5–10s", 5...10), (">10s", 10...(.infinity)),
        ]
        return bounds.map { label, range in
            (label, store.records.filter { range.contains($0.durationSeconds) }.count)
        }
    }

    private func statusLabel(_ s: RecordStatus) -> String {
        switch s {
        case .success: return "成功"
        case .failed: return "失败"
        case .cancelled: return "取消"
        }
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
