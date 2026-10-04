import SwiftUI
import Charts
import OverheadCore

/// How a provider's plan windows filled up over the selected range: one line per window, broken
/// and restarted from zero at each reset, with the alert threshold as a reference line.
struct PlanHistoryView: View {
    let provider: ProviderID
    /// Samples already filtered to `interval`.
    let samples: [PlanSample]
    let interval: DateInterval
    let threshold: Int
    @State private var hovered: Date? = nil

    /// Fixed window order so colors never depend on which windows happen to have data.
    private static let windowOrder = ["5-hour window", "Weekly window", "Spend limit", "Included usage", "Cursor models (Auto)", "Other models"]

    private var windows: [String] {
        let present = Set(samples.map(\.window))
        let known = Self.windowOrder.filter { present.contains($0) }
        return known + present.subtracting(known).sorted()
    }

    private func color(_ index: Int) -> Color {
        switch index {
        case 0: return provider.color
        case 1: return Color.primary.opacity(0.55)
        default: return Color.secondary.opacity(0.45)
        }
    }

    var body: some View {
        let windows = windows
        let points = UsageAggregator.planSeries(samples)
        let end = max(min(interval.end, Date()), interval.start.addingTimeInterval(60))
        let span = end.timeIntervalSince(interval.start)

        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Used", p.usedPercent), series: .value("Series", p.series))
                        .foregroundStyle(by: .value("Window", p.window))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                }
                RuleMark(y: .value("Alert threshold", Double(threshold)))
                    .foregroundStyle(.orange.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("alerts at \(threshold)%").font(.caption2).foregroundStyle(.tertiary)
                    }
                if let hovered {
                    RuleMark(x: .value("Hovered", hovered)).foregroundStyle(.quaternary)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: interval.start...end)
            .chartForegroundStyleScale(domain: windows, range: windows.indices.map(color))
            .chartLegend(windows.count > 1 ? .visible : .hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    if span <= 2 * 86_400 {
                        AxisValueLabel(format: .dateTime.hour().minute())
                    } else {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
            }
            .chartXSelection(value: $hovered)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let hovered, let x = proxy.position(forX: hovered) {
                        PlanHistoryTooltip(time: hovered, rows: rows(at: hovered, windows: windows))
                            .offset(x: min(max(x - 100, 0), geo.size.width - 220), y: 0)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 180)

            Text(footnote).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// The last known value of each window at `time`, or "reset" when the window reset since.
    private func rows(at time: Date, windows: [String]) -> [(String, String, Color)] {
        windows.enumerated().compactMap { index, window in
            let before = samples.filter { $0.window == window && $0.observedAt <= time }
            guard let last = before.max(by: { $0.observedAt < $1.observedAt }) else { return nil }
            if let reset = last.resetsAt, reset <= time { return (window, "reset", color(index)) }
            return (window, String(format: "%.0f%%", last.usedPercent), color(index))
        }
    }

    private var footnote: String {
        switch provider {
        case .codexCLI: return "One point per Codex turn, from the rate-limit snapshot Codex writes to its session log. Lines restart from zero where a window reset."
        case .claudeCode: return "Recorded by the status-line helper whenever Claude Code's percentages change. Lines restart from zero where a window reset."
        default: return "Sampled by Overhead on each refresh while it is running; gaps are drawn as straight lines."
        }
    }
}

private struct PlanHistoryTooltip: View {
    let time: Date
    let rows: [(String, String, Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(time, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                .font(.caption.weight(.semibold))
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.2).frame(width: 7, height: 7)
                    Text(row.0).font(.caption)
                    Spacer(minLength: 12)
                    Text(row.1).font(.caption.monospacedDigit())
                }
            }
            if rows.isEmpty { Text("No data yet").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4, y: 2)
    }
}
