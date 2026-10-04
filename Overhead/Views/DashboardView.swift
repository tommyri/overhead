import SwiftUI
import Charts
import OverheadCore

enum ChartMetric: String, CaseIterable, Identifiable {
    case cost, tokens, requests
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cost: return "Value"
        case .tokens: return "Tokens"
        case .requests: return "Requests"
        }
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var metric: ChartMetric = .cost

    var body: some View {
        let records = model.recordsInRange
        let totals = UsageAggregator.totals(records)
        let byProvider = UsageAggregator.totalsByProvider(records)
        let providers = model.providersWithData.sorted { $0.paletteSlot < $1.paletteSlot }

        let paid = model.paidSummary(in: model.currentInterval, providers: model.activeProviders)
        let comparison = model.paidVsValue(in: model.currentInterval, providers: providers)
        let hasSubscriptions = comparison.contains { $0.plan.isSubscription }
        let previous = model.previousTotals().map { StatComparison(totals: $0, label: model.rangePreset.previousLabel) }

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatRow(totals: totals, days: dayCount, paid: paid, comparison: previous, cacheSavings: UsageAggregator.cacheSavings(records))

                if records.isEmpty {
                    EmptyState()
                } else {
                    ChartCard(title: "Paid vs value") {
                        PaidVsValueTable(rows: comparison, interval: model.currentInterval)
                    }

                    ChartCard(title: "This month, projected") {
                        MonthForecastTable(providers: providers)
                    }

                    ChartCard(title: "Daily \(metric.title.lowercased()) by provider") {
                        Picker("Metric", selection: $metric) {
                            ForEach(ChartMetric.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    } content: {
                        DailyStackedChart(
                            points: UsageAggregator.dailySeries(records, in: model.currentInterval, providers: providers),
                            providers: providers,
                            metric: metric
                        )
                        .frame(height: 260)
                        if metric == .cost, hasSubscriptions {
                            Text("Value is what the tokens would cost at API list prices. For subscription plans that is not what you pay; see “Paid vs value”.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    HStack(alignment: .top, spacing: 20) {
                        ChartCard(title: "By provider") {
                            ProviderBreakdown(byProvider: byProvider, providers: providers, grandTotal: totals)
                        }
                        .frame(maxWidth: .infinity)

                        ChartCard(title: "Top models") {
                            ModelTable(models: Array(UsageAggregator.totalsByModel(records).prefix(12)), showProvider: true)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    let projects = UsageAggregator.totalsByProject(records)
                    if !projects.isEmpty {
                        ChartCard(title: "By project") {
                            ProjectTable(projects: projects, limit: 10, showProvider: true)
                        }
                    }

                    let sessions = model.sessionsInRange
                    let hourly = model.hourlyInRange
                    if !sessions.isEmpty || !hourly.isEmpty {
                        ChartCard(title: "Sessions and working hours") {
                            SessionsView(sessions: sessions, hourly: hourly, interval: model.currentInterval, providers: providers, showProvider: true)
                        }
                    }

                    let code = model.codeInRange
                    if !code.isEmpty {
                        ChartCard(title: "AI code output") {
                            CodeOutputView(code: code, interval: model.currentInterval, providers: providers, showProvider: true)
                        }
                    }

                    let tools = model.toolsInRange
                    if !tools.isEmpty {
                        ChartCard(title: "Tool usage") {
                            ToolUsageView(tools: tools, requests: totals.requests, interval: model.currentInterval, providers: providers, showProvider: true)
                        }
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

// MARK: - Stat tiles

/// Totals of the period before the selected range, for the deltas on the tiles.
struct StatComparison {
    let totals: UsageAggregator.Totals
    /// e.g. "the previous 30 days"
    let label: String
}

struct StatRow: View {
    let totals: UsageAggregator.Totals
    let days: Int
    /// What was actually paid in the range (prorated fees + API bills). nil hides the tile.
    var paid: AppModel.PaidSummary? = nil
    var comparison: StatComparison? = nil
    /// What prompt caching saved at list prices. nil hides the tile in favour of cache reads.
    var cacheSavings: UsageAggregator.CacheSavings? = nil

    var body: some View {
        let value = totals.cost.value
        HStack(spacing: 14) {
            if let paid {
                StatTile(title: "Paid", value: paidText(paid), footnote: paidFootnote(paid))
            }
            StatTile(title: paid == nil ? "Cost" : "Value", value: Fmt.cost(totals.cost),
                     footnote: value.map { "\(Fmt.usd($0 / Double(days), estimate: totals.cost.isEstimate)) per day" },
                     delta: delta(value ?? 0, comparison?.totals.cost.value ?? 0), deltaLabel: comparison?.label)
            StatTile(title: "Tokens", value: Fmt.tokens(totals.totalTokens),
                     footnote: "\(Fmt.tokens(totals.inputTokens)) in · \(Fmt.tokens(totals.outputTokens)) out",
                     delta: delta(Double(totals.totalTokens), Double(comparison?.totals.totalTokens ?? 0)), deltaLabel: comparison?.label)
            if let cacheSavings {
                StatTile(title: "Cache savings", value: Fmt.usd(cacheSavings.saved, estimate: true),
                         footnote: String(format: "%.0f%% cache hit rate", cacheSavings.cacheHitRate * 100))
                    .help("Without prompt caching the same tokens would have cost \(Fmt.usd(cacheSavings.withoutCache, estimate: true)) at list prices instead of \(Fmt.usd(cacheSavings.withCache, estimate: true)). Only models with a known list price are counted.")
            } else {
                StatTile(title: "Cache reads", value: Fmt.tokens(totals.cacheReadTokens), footnote: cacheHitText)
            }
            StatTile(title: "Requests", value: totals.requests > 0 ? Fmt.count(totals.requests) : "—",
                     footnote: nil,
                     delta: delta(Double(totals.requests), Double(comparison?.totals.requests ?? 0)), deltaLabel: comparison?.label)
        }
    }

    private func delta(_ current: Double, _ previous: Double) -> Double? {
        guard comparison != nil else { return nil }
        return UsageAggregator.change(current, from: previous)
    }

    private func paidText(_ p: AppModel.PaidSummary) -> String {
        if p.total == 0 && !p.missingFee.isEmpty { return "—" }
        return Fmt.usd(p.total)
    }

    private func paidFootnote(_ p: AppModel.PaidSummary) -> String? {
        if p.missingFee.count == 1 {
            return "Set \(p.missingFee[0].displayName) fee in Settings"
        } else if !p.missingFee.isEmpty {
            return "Set plan fees in Settings"
        }
        var parts: [String] = []
        if p.fees > 0 { parts.append("\(Fmt.usd(p.fees)) plans, prorated") }
        if p.billed > 0 { parts.append("\(Fmt.usd(p.billed)) API") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var cacheHitText: String? {
        let denom = totals.inputTokens + totals.cacheReadTokens + totals.cacheWriteTokens
        guard denom > 0 else { return nil }
        let pct = Double(totals.cacheReadTokens) / Double(denom) * 100
        return String(format: "%.0f%% of prompt tokens", pct)
    }
}

/// Subscription fee (prorated to the range) next to the API-equivalent value of what was used.
struct PaidVsValueTable: View {
    @Environment(AppModel.self) private var model
    let rows: [AppModel.PaidVsValue]
    let interval: DateInterval

    var body: some View {
        let maxAmount = max(1, rows.map { max($0.paid ?? 0, $0.value.value ?? 0) }.max() ?? 1)
        let totalPaid = rows.compactMap(\.paid).reduce(0, +)
        let totalValue = rows.reduce(UsageRecord.Cost.unknown) { .sum($0, $1.value) }
        let anyMissing = rows.contains { $0.plan.isSubscription && $0.paid == nil }

        VStack(spacing: 0) {
            HStack {
                Text("Provider").frame(maxWidth: .infinity, alignment: .leading)
                Text("Paid").frame(width: 90, alignment: .trailing)
                Text("Value").frame(width: 90, alignment: .trailing)
                Text("Value ÷ paid").frame(width: 90, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            Divider()
            ForEach(rows) { row in
                VStack(spacing: 5) {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(row.provider.color).frame(width: 7, height: 7)
                            Text(row.provider.displayName)
                            Text(row.plan.isSubscription ? (row.plan.planName ?? "plan") : "API")
                                .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.paid.map { Fmt.usd($0) } ?? (row.plan.isSubscription ? "set fee" : "—"))
                            .frame(width: 90, alignment: .trailing)
                            .foregroundStyle(row.paid == nil ? .secondary : .primary)
                        Text(Fmt.cost(row.value)).frame(width: 90, alignment: .trailing)
                        Text(Fmt.multiple(row.multiple)).frame(width: 90, alignment: .trailing)
                            .foregroundStyle(multipleColor(row.multiple))
                    }
                    .font(.callout.monospacedDigit())
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 2) {
                            Capsule().fill(.secondary.opacity(0.35))
                                .frame(width: max(2, geo.size.width * CGFloat((row.paid ?? 0) / maxAmount)), height: 3)
                            Capsule().fill(row.provider.color)
                                .frame(width: max(2, geo.size.width * CGFloat((row.value.value ?? 0) / maxAmount)), height: 3)
                        }
                    }
                    .frame(height: 8)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedProvider = row.provider }
                .help("Open \(row.provider.displayName)")
                Divider()
            }
            HStack {
                Text("Total").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                Text(anyMissing ? "—" : Fmt.usd(totalPaid)).frame(width: 90, alignment: .trailing)
                Text(Fmt.cost(totalValue)).frame(width: 90, alignment: .trailing)
                Text(anyMissing || totalPaid == 0 ? "—" : Fmt.multiple((totalValue.value ?? 0) / totalPaid))
                    .frame(width: 90, alignment: .trailing)
            }
            .font(.callout.monospacedDigit().weight(.medium))
            .padding(.top, 8)
            HStack(spacing: 14) {
                Label("Paid", systemImage: "line.horizontal.3").labelStyle(.titleOnly)
                    .foregroundStyle(.secondary)
                Text("grey bar · fee prorated to the \(dayCount)-day range, or billed API cost")
                Spacer()
            }
            .font(.caption2).foregroundStyle(.tertiary).padding(.top, 6)
        }
    }

    private var dayCount: Int {
        max(1, Calendar.current.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
    }

    private func multipleColor(_ m: Double?) -> Color {
        guard let m else { return .secondary }
        return m >= 1 ? .primary : .orange
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let footnote: String?
    /// Relative change against the previous period (0.18 = +18%). nil shows nothing.
    var delta: Double? = nil
    var deltaLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let delta {
                    HStack(spacing: 2) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 8, weight: .bold))
                        Text(String(format: "%.0f%%", abs(delta) * 100))
                    }
                    .font(.caption2.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("\(delta >= 0 ? "Up" : "Down") \(String(format: "%.0f%%", abs(delta) * 100)) against \(deltaLabel ?? "the previous period")")
                }
            }
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                Text(" ").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Cards

struct ChartCard<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(title: String, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.accessory = accessory; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension ChartCard where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Daily stacked chart

struct DailyStackedChart: View {
    let points: [UsageAggregator.DailyPoint]
    let providers: [ProviderID]
    let metric: ChartMetric
    @State private var hoveredDay: Date? = nil

    private func value(_ p: UsageAggregator.DailyPoint) -> Double {
        switch metric {
        case .cost: return p.cost
        case .tokens: return Double(p.tokens)
        case .requests: return Double(p.requests)
        }
    }

    var body: some View {
        Chart(points) { p in
            BarMark(
                x: .value("Day", p.day, unit: .day),
                y: .value(metric.title, value(p))
            )
            .foregroundStyle(by: .value("Provider", p.provider.displayName))
            .cornerRadius(3)
            .opacity(hoveredDay == nil || Calendar.current.isDate(hoveredDay!, inSameDayAs: p.day) ? 1 : 0.45)
        }
        .chartForegroundStyleScale(domain: providers.map(\.displayName), range: providers.map(\.color))
        .chartLegend(providers.count > 1 ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(axisLabel(d)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartXSelection(value: $hoveredDay)
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let hoveredDay, let x = proxy.position(forX: hoveredDay) {
                    let rows = points.filter { Calendar.current.isDate($0.day, inSameDayAs: hoveredDay) && value($0) > 0 }
                    if !rows.isEmpty {
                        TooltipView(day: hoveredDay, rows: rows, metric: metric)
                            .offset(x: min(max(x - 90, 0), geo.size.width - 200), y: 0)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func axisLabel(_ d: Double) -> String {
        switch metric {
        case .cost: return d == 0 ? "$0" : (d < 10 ? String(format: "$%.1f", d) : "$\(Int(d))")
        case .tokens, .requests: return d == 0 ? "0" : Fmt.tokens(Int(d))
        }
    }
}

private struct TooltipView: View {
    let day: Date
    let rows: [UsageAggregator.DailyPoint]
    let metric: ChartMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.caption.weight(.semibold))
            ForEach(rows.sorted { $0.provider.paletteSlot < $1.provider.paletteSlot }) { r in
                HStack(spacing: 6) {
                    Circle().fill(r.provider.color).frame(width: 7, height: 7)
                    Text(r.provider.displayName).font(.caption)
                    Spacer(minLength: 12)
                    Text(formatted(r)).font(.caption.monospacedDigit())
                }
            }
            Divider()
            HStack {
                Text("Total").font(.caption.weight(.semibold))
                Spacer()
                Text(total).font(.caption.monospacedDigit().weight(.semibold))
            }
        }
        .padding(8)
        .frame(width: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4, y: 2)
    }

    private func formatted(_ r: UsageAggregator.DailyPoint) -> String {
        switch metric {
        case .cost: return Fmt.usd(r.cost)
        case .tokens: return Fmt.tokens(r.tokens)
        case .requests: return Fmt.count(r.requests)
        }
    }
    private var total: String {
        switch metric {
        case .cost: return Fmt.usd(rows.reduce(0) { $0 + $1.cost })
        case .tokens: return Fmt.tokens(rows.reduce(0) { $0 + $1.tokens })
        case .requests: return Fmt.count(rows.reduce(0) { $0 + $1.requests })
        }
    }
}

// MARK: - Provider breakdown

struct ProviderBreakdown: View {
    @Environment(AppModel.self) private var model
    let byProvider: [ProviderID: UsageAggregator.Totals]
    let providers: [ProviderID]
    let grandTotal: UsageAggregator.Totals

    var body: some View {
        let total = grandTotal.cost.value ?? 0
        VStack(spacing: 10) {
            ForEach(providers) { p in
                let t = byProvider[p] ?? UsageAggregator.Totals()
                let share = total > 0 ? (t.cost.value ?? 0) / total : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(p.color).frame(width: 9, height: 9)
                        Text(p.displayName).font(.callout)
                        Spacer()
                        Text(Fmt.tokens(t.totalTokens)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(Fmt.cost(t.cost)).font(.callout.monospacedDigit().weight(.medium))
                            .frame(width: 90, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(p.color).frame(width: max(2, geo.size.width * share))
                        }
                    }
                    .frame(height: 5)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selectedProvider = p }
                .help("Open \(p.displayName)")
            }
        }
    }
}

// MARK: - Model table

struct ModelTable: View {
    let models: [UsageAggregator.ModelTotals]
    let showProvider: Bool

    var body: some View {
        // Reasoning tokens are only reported by Claude Code and Codex; hide the column otherwise.
        let showThinking = models.contains { $0.totals.reasoningTokens > 0 }
        VStack(spacing: 0) {
            HStack {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 80, alignment: .trailing)
                Text("Reqs").frame(width: 60, alignment: .trailing)
                if showThinking {
                    Text("Thinking").frame(width: 70, alignment: .trailing)
                        .help("Share of output tokens spent on reasoning, where the tool reports it")
                }
                Text("Cost").frame(width: 90, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.bottom, 6)
            Divider()
            ForEach(models) { m in
                HStack {
                    HStack(spacing: 6) {
                        if showProvider { Circle().fill(m.provider.color).frame(width: 7, height: 7) }
                        Text(Fmt.modelName(m.model)).lineLimit(1).help(m.model.isEmpty ? m.provider.displayName : m.model)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.tokens(m.totals.totalTokens)).frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                    Text(m.totals.requests > 0 ? Fmt.count(m.totals.requests) : "—").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                    if showThinking {
                        Text(m.totals.thinkingShare.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                            .frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                            .help(m.totals.reasoningTokens > 0 ? "\(Fmt.tokens(m.totals.reasoningTokens)) reasoning tokens of \(Fmt.tokens(m.totals.outputTokens)) output" : "No reasoning tokens reported")
                    }
                    Text(Fmt.cost(m.totals.cost)).frame(width: 90, alignment: .trailing).fontWeight(.medium)
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 5)
                Divider()
            }
            if models.isEmpty {
                Text("No usage in this range").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Month forecast

/// Month-to-date value and a straight-line projection to month end, next to what the month
/// will cost in fees.
struct MonthForecastTable: View {
    @Environment(AppModel.self) private var model
    let providers: [ProviderID]

    var body: some View {
        let month = DateRangePreset.thisMonth.interval()
        let rows = providers.map { p -> (ProviderID, Forecast.MonthForecast, Double?) in
            let f = Forecast.monthEnd(records: model.recordsByProvider[p] ?? [])
            let plan = model.billingPlan(for: p)
            let paid: Double? = plan.isSubscription ? (plan.hasFee ? plan.monthlyFeeUSD : nil) : nil
            return (p, f, paid)
        }
        let total = Forecast.monthEnd(records: model.allRecords)
        let totalPaid = rows.compactMap(\.2).reduce(0, +)
        let anyMissingFee = rows.contains { model.billingPlan(for: $0.0).isSubscription && $0.2 == nil }

        VStack(spacing: 0) {
            HStack {
                Text("Provider").frame(maxWidth: .infinity, alignment: .leading)
                Text("So far").frame(width: 90, alignment: .trailing)
                Text("Projected").frame(width: 90, alignment: .trailing)
                Text("Fee").frame(width: 80, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            Divider()
            ForEach(rows, id: \.0) { provider, f, paid in
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(provider.color).frame(width: 7, height: 7)
                        Text(provider.displayName)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.usd(f.valueToDate, estimate: f.isEstimate)).frame(width: 90, alignment: .trailing).foregroundStyle(.secondary)
                    Text(Fmt.usd(f.projectedValue, estimate: true)).frame(width: 90, alignment: .trailing).fontWeight(.medium)
                    Text(paid.map { Fmt.usd($0) } ?? (model.billingPlan(for: provider).isSubscription ? "set fee" : "—"))
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(paid == nil ? .secondary : .primary)
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedProvider = provider }
                Divider()
            }
            HStack {
                Text("Total").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.usd(total.valueToDate, estimate: total.isEstimate)).frame(width: 90, alignment: .trailing)
                Text(Fmt.usd(total.projectedValue, estimate: true)).frame(width: 90, alignment: .trailing)
                Text(anyMissingFee ? "—" : Fmt.usd(totalPaid)).frame(width: 80, alignment: .trailing)
            }
            .font(.callout.monospacedDigit().weight(.medium))
            .padding(.top, 8)
            Text("Day \(total.daysElapsed) of \(total.daysInMonth). Projection continues the last 7 days' average for the remaining \(total.daysRemaining) day\(total.daysRemaining == 1 ? "" : "s"); fees are the full monthly price.")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 0)
        .onAppear { _ = month }
    }
}

// MARK: - AI code output

/// Lines of code accepted from AI tools per day, with suggested-vs-accepted where known.
struct CodeOutputView: View {
    let code: [CodeActivity]
    let interval: DateInterval
    let providers: [ProviderID]
    var showProvider = true
    @State private var hoveredDay: Date? = nil

    var body: some View {
        let totals = UsageAggregator.codeTotals(code)
        // Acceptance is only meaningful for sources that report suggestions (Cursor).
        let suggested = UsageAggregator.codeTotals(code.filter { $0.suggestedLines > 0 })
        let groups = UsageAggregator.codeTotalsByProviderAndKind(code)
        let present = providers.filter { p in code.contains { $0.provider == p } }
        let series = UsageAggregator.codeDailySeries(code, in: interval, providers: present)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                StatTile(title: "Lines accepted", value: Fmt.count(totals.linesAdded), footnote: totals.linesRemoved > 0 ? "\(Fmt.count(totals.linesRemoved)) removed" : nil)
                StatTile(title: "Edits applied", value: totals.edits > 0 ? Fmt.count(totals.edits) : "—",
                         footnote: totals.edits > 0 ? "\(Fmt.count(totals.linesAdded / max(1, totals.edits))) lines per edit" : nil)
                StatTile(title: "Acceptance", value: suggested.acceptanceRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                         footnote: suggested.acceptanceRate != nil ? "of \(Fmt.count(suggested.suggestedLines)) suggested (Cursor)"
                                   : (suggested.suggestedLines > 0 ? "Cursor counts not comparable" : "Cursor reports suggestions"))
                StatTile(title: "Per day", value: Fmt.count(totals.linesAdded / max(1, dayCount)), footnote: "\(dayCount) days")
            }

            Chart(series) { p in
                BarMark(x: .value("Day", p.day, unit: .day), y: .value("Lines", p.linesAdded))
                    .foregroundStyle(by: .value("Provider", p.provider.displayName))
                    .cornerRadius(3)
                    .opacity(hoveredDay == nil || Calendar.current.isDate(hoveredDay!, inSameDayAs: p.day) ? 1 : 0.45)
            }
            .chartForegroundStyleScale(domain: present.map(\.displayName), range: present.map(\.color))
            .chartLegend(present.count > 1 ? .visible : .hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.tokens(Int(d))) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartXSelection(value: $hoveredDay)
            .frame(height: 180)

            VStack(spacing: 0) {
                HStack {
                    Text("Source").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Accepted").frame(width: 90, alignment: .trailing)
                    Text("Removed").frame(width: 90, alignment: .trailing)
                    Text("Suggested").frame(width: 90, alignment: .trailing)
                    Text("Edits").frame(width: 70, alignment: .trailing)
                }
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                Divider()
                ForEach(groups) { g in
                    HStack {
                        HStack(spacing: 6) {
                            if showProvider { Circle().fill(g.provider.color).frame(width: 7, height: 7) }
                            Text(showProvider ? "\(g.provider.displayName) · \(kindName(g.kind))" : kindName(g.kind))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.count(g.totals.linesAdded)).frame(width: 90, alignment: .trailing).fontWeight(.medium)
                        Text(g.totals.linesRemoved > 0 ? Fmt.count(g.totals.linesRemoved) : "—").frame(width: 90, alignment: .trailing).foregroundStyle(.secondary)
                        Text(g.totals.suggestedLines > 0 ? Fmt.count(g.totals.suggestedLines) : "—").frame(width: 90, alignment: .trailing).foregroundStyle(.secondary)
                        Text(g.totals.edits > 0 ? Fmt.count(g.totals.edits) : "—").frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                    }
                    .font(.callout.monospacedDigit())
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            Text("Claude Code and Codex: lines in edits whose tool result was not an error. Cursor: Tab and Composer lines as counted by Cursor itself. Lines are a rough measure of output, not of quality.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var dayCount: Int {
        max(1, Calendar.current.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
    }

    private func kindName(_ k: String) -> String {
        switch k {
        case "edits": return "edits"
        case "tab": return "Tab"
        case "composer": return "Composer"
        default: return k
        }
    }
}

// MARK: - Tool usage

/// How often each tool was called and how often it failed, per day and per tool.
struct ToolUsageView: View {
    let tools: [ToolActivity]
    /// Model requests in the same range, for the calls-per-request tile.
    let requests: Int
    let interval: DateInterval
    let providers: [ProviderID]
    var showProvider = true
    var limit = 12
    @State private var hoveredDay: Date? = nil

    var body: some View {
        let totals = UsageAggregator.toolTotals(tools)
        let groups = UsageAggregator.toolTotalsByTool(tools)
        let shown = Array(groups.prefix(limit))
        let maxCalls = max(1, shown.first?.totals.calls ?? 1)
        let present = providers.filter { p in tools.contains { $0.provider == p } }
        let series = UsageAggregator.toolDailySeries(tools, in: interval, providers: present)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                StatTile(title: "Tool calls", value: Fmt.count(totals.calls), footnote: "\(groups.count) distinct tools")
                StatTile(title: "Per request", value: requests > 0 ? String(format: "%.1f", Double(totals.calls) / Double(requests)) : "—",
                         footnote: requests > 0 ? "calls per model request" : nil)
                StatTile(title: "Failed calls", value: Fmt.count(totals.errors),
                         footnote: totals.errorRate.map { String(format: "%.1f%% of calls", $0 * 100) })
                StatTile(title: "Per day", value: Fmt.count(totals.calls / max(1, dayCount)), footnote: "\(dayCount) days")
            }

            Chart(series) { p in
                BarMark(x: .value("Day", p.day, unit: .day), y: .value("Calls", p.calls))
                    .foregroundStyle(by: .value("Provider", p.provider.displayName))
                    .cornerRadius(3)
                    .opacity(hoveredDay == nil || Calendar.current.isDate(hoveredDay!, inSameDayAs: p.day) ? 1 : 0.45)
            }
            .chartForegroundStyleScale(domain: present.map(\.displayName), range: present.map(\.color))
            .chartLegend(present.count > 1 ? .visible : .hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.tokens(Int(d))) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartXSelection(value: $hoveredDay)
            .frame(height: 160)

            VStack(spacing: 0) {
                HStack {
                    Text("Tool").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Calls").frame(width: 80, alignment: .trailing)
                    Text("Failed").frame(width: 80, alignment: .trailing)
                    Text("Share").frame(width: 70, alignment: .trailing)
                }
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                Divider()
                ForEach(shown) { g in
                    VStack(spacing: 4) {
                        HStack {
                            HStack(spacing: 6) {
                                if showProvider { Circle().fill(g.provider.color).frame(width: 7, height: 7) }
                                Text(Fmt.toolName(g.tool)).lineLimit(1).help(g.tool)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Fmt.count(g.totals.calls)).frame(width: 80, alignment: .trailing).fontWeight(.medium)
                            Text(g.totals.errors > 0 ? Fmt.count(g.totals.errors) : "—").frame(width: 80, alignment: .trailing)
                                .foregroundStyle(g.totals.errors > 0 ? Color.orange : Color.secondary)
                            Text(totals.calls > 0 ? String(format: "%.0f%%", Double(g.totals.calls) / Double(totals.calls) * 100) : "—")
                                .frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                        }
                        .font(.callout.monospacedDigit())
                        GeometryReader { geo in
                            Capsule().fill(g.provider.color.opacity(0.8))
                                .frame(width: max(2, geo.size.width * CGFloat(g.totals.calls) / CGFloat(maxCalls)))
                        }
                        .frame(height: 3)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
                if groups.count > shown.count {
                    Text("+\(groups.count - shown.count) more tools").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
            Text("Claude Code: tool_use blocks and their results. Codex: function and custom tool calls with their exit codes. Cursor exposes no tool data.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var dayCount: Int {
        max(1, Calendar.current.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
    }
}

// MARK: - Project table

/// Usage per working directory, from the local coding tools that record one.
struct ProjectTable: View {
    let projects: [UsageAggregator.ProjectTotals]
    var limit: Int = .max
    var showProvider = true

    var body: some View {
        let shown = Array(projects.prefix(limit))
        let maxValue = max(0.01, shown.map { $0.totals.cost.value ?? 0 }.max() ?? 0)
        VStack(spacing: 0) {
            HStack {
                Text("Project").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 80, alignment: .trailing)
                Text("Reqs").frame(width: 60, alignment: .trailing)
                Text("Value").frame(width: 90, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            Divider()
            ForEach(shown) { p in
                VStack(spacing: 4) {
                    HStack {
                        HStack(spacing: 6) {
                            if showProvider {
                                HStack(spacing: 2) {
                                    ForEach(p.providers) { prov in Circle().fill(prov.color).frame(width: 7, height: 7) }
                                }
                            }
                            Text(p.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.tokens(p.totals.totalTokens)).frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                        Text(p.totals.requests > 0 ? Fmt.count(p.totals.requests) : "—").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                        Text(Fmt.cost(p.totals.cost)).frame(width: 90, alignment: .trailing).fontWeight(.medium)
                    }
                    .font(.callout.monospacedDigit())
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(p.providers) { prov in
                                let v = p.byProvider[prov]?.cost.value ?? 0
                                if v > 0 {
                                    Capsule().fill(prov.color).frame(width: max(2, geo.size.width * CGFloat(v / maxValue)))
                                }
                            }
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.vertical, 5)
                .help(UsageRecord.displayPath(p.path))
                Divider()
            }
            if projects.count > shown.count {
                Text("+\(projects.count - shown.count) more project\(projects.count - shown.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            Text("From the working directory recorded by Claude Code and Codex; API and Cursor usage carries no project.")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Empty state

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No usage in this range").font(.title3.weight(.semibold))
            Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack {
                Button("Refresh") { Task { await model.refreshAll(force: true) } }
                Button("Open Settings…") { openSettings() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var hint: String {
        let failing = model.activeProviders.filter { if case .failed = model.statusByProvider[$0] ?? .idle { return true }; return false }
        let unconfigured = model.activeProviders.filter { model.statusByProvider[$0] == .notConfigured }
        if !failing.isEmpty { return "Some providers failed to load: \(failing.map(\.displayName).joined(separator: ", ")). Check the sidebar for details." }
        if !unconfigured.isEmpty { return "\(unconfigured.map(\.displayName).joined(separator: ", ")) need credentials. Add them in Settings → Providers." }
        if model.activeProviders.isEmpty { return "Enable at least one provider in Settings → Providers." }
        return "Try a longer range, or enable more providers in Settings."
    }
}
