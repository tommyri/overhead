import SwiftUI
import OverheadCore

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain")
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
