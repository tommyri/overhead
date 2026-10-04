import SwiftUI
import OverheadCore

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.hasAlerts ? "exclamationmark.triangle.fill" : "brain")
            Text(Fmt.cost(model.menuBarCost)).monospacedDigit()
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let today = UsageAggregator.filter(model.allRecords, in: DateRangePreset.today.interval())
        let month = UsageAggregator.filter(model.allRecords, in: DateRangePreset.thisMonth.interval())
        let todayBy = UsageAggregator.totalsByProvider(today)
        let monthBy = UsageAggregator.totalsByProvider(month)
        let providers = ProviderID.chartOrder.filter { model.enabledProviders.contains($0) }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.cost(UsageAggregator.totals(today).cost))
                        .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("This month").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.cost(UsageAggregator.totals(month).cost))
                        .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                }
            }

            Divider()

            MenuBarLimits(providers: providers)

            if providers.isEmpty {
                Text("No providers enabled").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Today").font(.caption2).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("Month").font(.caption2).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                    ForEach(providers) { p in
                        let status = model.statusByProvider[p] ?? .idle
                        GridRow {
                            HStack(spacing: 6) {
                                Circle().fill(p.color).frame(width: 8, height: 8)
                                Text(p.displayName).font(.callout)
                                if case .failed = status {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange).help(status.text)
                                } else if case .notConfigured = status {
                                    Image(systemName: "key.slash").font(.caption2).foregroundStyle(.secondary).help(status.text)
                                } else if case .loading = status {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            Text(Fmt.cost(todayBy[p]?.cost ?? .unknown)).font(.callout.monospacedDigit())
                            Text(Fmt.cost(monthBy[p]?.cost ?? .unknown)).font(.callout.monospacedDigit())
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    Task { await model.refreshAll(force: true) }
                } label: {
                    if model.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .disabled(model.isRefreshing)
                Spacer()
                Button("Settings…") { openSettings() }
                Button("Open") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)

            HStack {
                if let last = model.lastRefresh {
                    Text("Updated \(Fmt.relative(last))").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}


/// Plan windows with their alert state, for the popover.
private struct MenuBarLimits: View {
    @Environment(AppModel.self) private var model
    let providers: [ProviderID]

    private struct Item: Identifiable {
        let provider: ProviderID
        let window: PlanStatus.Window
        var id: String { "\(provider.rawValue)|\(window.title)" }
    }

    private var items: [Item] {
        providers.flatMap { p in (model.planStatus[p]?.windows ?? []).map { Item(provider: p, window: $0) } }
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    LimitRow(provider: item.provider, window: item.window,
                             alert: model.activeAlerts.first { $0.provider == item.provider && $0.window.title == item.window.title })
                }
            }
            Divider()
        }
    }
}

private struct LimitRow: View {
    let provider: ProviderID
    let window: PlanStatus.Window
    let alert: PlanAlert?

    private var tint: Color {
        guard let alert else { return .accentColor }
        return alert.level == .critical ? .red : .orange
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(provider.color).frame(width: 8, height: 8)
            Text("\(provider.displayName) · \(window.title.lowercased())").font(.caption).lineLimit(1)
            Spacer()
            if let alert {
                Image(systemName: alert.level == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(tint).help(alert.detail)
            }
            Text(String(format: "%.0f%%", window.usedPercent))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(alert == nil ? Color.primary : tint)
        }
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(2, geo.size.width * min(1, window.usedPercent / 100)))
            }
        }
        .frame(height: 4)
    }
}
