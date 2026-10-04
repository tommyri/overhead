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

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatRow(totals: totals, days: dayCount, paid: paid)

                if records.isEmpty {
                    EmptyState()
                } else {
                    ChartCard(title: "Paid vs value") {
                        PaidVsValueTable(rows: comparison, interval: model.currentInterval)
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

struct StatRow: View {
    let totals: UsageAggregator.Totals
    let days: Int
    /// What was actually paid in the range (prorated fees + API bills). nil hides the tile.
    var paid: AppModel.PaidSummary? = nil

    var body: some View {
        let value = totals.cost.value
        HStack(spacing: 14) {
            if let paid {
                StatTile(title: "Paid", value: paidText(paid), footnote: paidFootnote(paid))
            }
            StatTile(title: paid == nil ? "Cost" : "Value", value: Fmt.cost(totals.cost),
                     footnote: value.map { "\(Fmt.usd($0 / Double(days), estimate: totals.cost.isEstimate)) per day" })
            StatTile(title: "Tokens", value: Fmt.tokens(totals.totalTokens),
                     footnote: "\(Fmt.tokens(totals.inputTokens)) in · \(Fmt.tokens(totals.outputTokens)) out")
            StatTile(title: "Cache reads", value: Fmt.tokens(totals.cacheReadTokens),
                     footnote: cacheHitText)
            StatTile(title: "Requests", value: totals.requests > 0 ? Fmt.count(totals.requests) : "—",
                     footnote: nil)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
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
        VStack(spacing: 0) {
            HStack {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 80, alignment: .trailing)
                Text("Reqs").frame(width: 60, alignment: .trailing)
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
