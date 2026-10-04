import SwiftUI
import Charts
import OverheadCore

struct ProviderDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let provider: ProviderID
    @State private var metric: ChartMetric = .cost

    var body: some View {
        let records = model.records(for: provider)
        let totals = UsageAggregator.totals(records)
        let status = model.statusByProvider[provider] ?? .idle

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: status.symbol).foregroundStyle(status.tint)
                    Text(status.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if status == .notConfigured {
                        Button("Add credentials…") { openSettings() }
                    }
                    Button {
                        Task { await model.refresh(provider, force: true) }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(status == .loading)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                StatRow(totals: totals, days: dayCount, paid: model.paidSummary(in: model.currentInterval, providers: [provider]))

                if let ps = model.planStatus[provider], !ps.windows.isEmpty {
                    // Prefer the user's (or detected) billing-plan name over the raw API tier.
                    ChartCard(title: "\(model.billingPlan(for: provider).planName ?? ps.planName ?? "Plan") usage") {
                        PlanStatusView(status: ps)
                    }
                }

                if records.isEmpty {
                    VStack(spacing: 8) {
                        Text("No usage in this range").font(.title3.weight(.semibold))
                        Text(provider.setupHint).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 480)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                } else {
                    ChartCard(title: "Daily \(metric.title.lowercased())") {
                        Picker("Metric", selection: $metric) {
                            ForEach(ChartMetric.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    } content: {
                        DailyStackedChart(
                            points: UsageAggregator.dailySeries(records, in: model.currentInterval, providers: [provider]),
                            providers: [provider],
                            metric: metric
                        )
                        .frame(height: 220)
                    }

                    ChartCard(title: "Models") {
                        ModelTable(models: UsageAggregator.totalsByModel(records), showProvider: false)
                    }

                    ChartCard(title: "Token breakdown") {
                        TokenBreakdown(totals: totals)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dayCount: Int {
        max(1, Calendar.current.dateComponents([.day], from: model.currentInterval.start, to: model.currentInterval.end).day ?? 1)
    }
}

/// Horizontal single-bar composition of the four token classes.
struct TokenBreakdown: View {
    let totals: UsageAggregator.Totals

    private var parts: [(String, Int, Color)] {
        [
            ("Input", totals.inputTokens, Color.primary.opacity(0.75)),
            ("Output", totals.outputTokens, Color.accentColor),
            ("Cache write", totals.cacheWriteTokens, Color.primary.opacity(0.45)),
            ("Cache read", totals.cacheReadTokens, Color.primary.opacity(0.22)),
        ]
    }

    var body: some View {
        let total = max(1, totals.totalTokens)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        if p.1 > 0 {
                            RoundedRectangle(cornerRadius: 2).fill(p.2)
                                .frame(width: max(2, geo.size.width * CGFloat(p.1) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 18) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 10, height: 10)
                        Text(p.0).font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.tokens(p.1)).font(.caption.monospacedDigit())
                    }
                }
                Spacer()
            }
        }
    }
}


/// Progress bars for subscription-plan consumption reported by a provider.
struct PlanStatusView: View {
    let status: PlanStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(status.windows) { w in window(w) }
            }
            HStack(spacing: 4) {
                if let note = status.note { Text(note) }
                Text("Observed \(Fmt.relative(status.observedAt)).")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func window(_ w: PlanStatus.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(w.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", w.usedPercent)).font(.callout.monospacedDigit().weight(.medium))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(w.usedPercent >= 90 ? Color.orange : Color.accentColor)
                        .frame(width: max(2, geo.size.width * min(1, w.usedPercent / 100)))
                }
            }
            .frame(height: 6)
            HStack(spacing: 4) {
                if let detail = w.detail { Text(detail) }
                if let reset = w.resetsAt {
                    if w.detail != nil { Text("·") }
                    Text("resets \(reset, format: .relative(presentation: .named))")
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
