import SwiftUI
import OverheadCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            Group {
                if let p = model.selectedProvider {
                    ProviderDetailView(provider: p)
                } else {
                    DashboardView()
                }
            }
            .navigationTitle(model.selectedProvider?.displayName ?? "Overview")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Range", selection: $model.rangePreset) {
                    ForEach(DateRangePreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 440)

                Button {
                    Task { await model.refreshAll(force: true) }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help("Refresh all providers (⌘R)")
                .disabled(model.isRefreshing)

                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Providers & credentials")
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedProvider) {
            Section {
                Label("Overview", systemImage: "chart.bar.xaxis")
                    .tag(Optional<ProviderID>.none)
            }
            Section("Providers") {
                ForEach(model.activeProviders) { p in
                    ProviderRow(provider: p)
                        .tag(Optional(p))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let last = model.lastRefresh {
                Text("Refreshed \(Fmt.relative(last))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }
}

private struct ProviderRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderID

    var body: some View {
        let totals = UsageAggregator.totals(model.records(for: provider))
        let status = model.statusByProvider[provider] ?? .idle
        HStack(spacing: 8) {
            Circle().fill(provider.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                Text(Fmt.cost(totals.cost))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if case .loading = status {
                ProgressView().controlSize(.mini)
            } else if case .failed = status {
                Image(systemName: status.symbol).foregroundStyle(status.tint).help(status.text)
            } else if case .notConfigured = status {
                Image(systemName: status.symbol).foregroundStyle(status.tint).help(status.text)
            }
        }
    }
}
