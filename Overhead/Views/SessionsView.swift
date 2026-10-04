import SwiftUI
import Charts
import OverheadCore

/// Sessions of the local coding tools (count, active time, longest) and a weekday × hour heatmap
/// of when model responses happen.
struct SessionsView: View {
    let sessions: [SessionActivity]
    let hourly: [HourlyActivity]
    let interval: DateInterval
    let providers: [ProviderID]
    var showProvider = true
    var limit = 8

    var body: some View {
        let totals = UsageAggregator.sessionTotals(sessions)
        let longest = sessions.sorted { $0.activeSeconds > $1.activeSeconds }.prefix(limit)
        // One hue for the heatmap: the provider's on its own page, the accent across providers.
        let hue = providers.count == 1 ? providers[0].color : Color.accentColor

        VStack(alignment: .leading, spacing: 14) {
            if !sessions.isEmpty {
                HStack(spacing: 14) {
                    StatTile(title: "Sessions", value: Fmt.count(totals.count),
                             footnote: String(format: "%.1f per day", Double(totals.count) / Double(dayCount)))
                    StatTile(title: "Active time", value: Fmt.duration(totals.activeSeconds),
                             footnote: "median \(Fmt.duration(totals.medianActiveSeconds)) per session")
                    StatTile(title: "Longest session", value: totals.longest.map { Fmt.duration($0.activeSeconds) } ?? "—",
                             footnote: totals.longest.map { longestFootnote($0) })
                    StatTile(title: "Per session", value: String(format: "%.0f", totals.requestsPerSession),
                             footnote: "responses · \(Fmt.tokens(totals.tokensPerSession)) tokens")
                }
            }

            if !hourly.isEmpty {
                Text("Activity by weekday and hour").font(.subheadline.weight(.medium))
                ActivityHeatmap(cells: UsageAggregator.heatmap(hourly), hue: hue)
            }

            if !longest.isEmpty {
                Text("Longest sessions").font(.subheadline.weight(.medium))
                VStack(spacing: 0) {
                    HStack {
                        Text("Started").frame(width: 150, alignment: .leading)
                        Text("Project").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Active").frame(width: 70, alignment: .trailing)
                        Text("Responses").frame(width: 80, alignment: .trailing)
                        Text("Tokens").frame(width: 80, alignment: .trailing)
                        Text("Value").frame(width: 80, alignment: .trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                    Divider()
                    ForEach(longest) { s in
                        HStack {
                            HStack(spacing: 6) {
                                if showProvider { Circle().fill(s.provider.color).frame(width: 7, height: 7) }
                                Text(s.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                            }
                            .frame(width: 150, alignment: .leading)
                            Text(s.project.map { ($0 as NSString).lastPathComponent } ?? "—").lineLimit(1)
                                .help(s.project.map(UsageRecord.displayPath) ?? "No working directory recorded")
                                .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(s.project == nil ? .secondary : .primary)
                            Text(Fmt.duration(s.activeSeconds)).frame(width: 70, alignment: .trailing).fontWeight(.medium)
                                .help("Spanned \(Fmt.duration(s.duration)) from first to last response")
                            Text(Fmt.count(s.requests)).frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                            Text(Fmt.tokens(s.totalTokens)).frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                            Text(s.cost.map { Fmt.usd($0, estimate: true) } ?? "—").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                        }
                        .font(.callout.monospacedDigit())
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }

            Text("A session is one Claude Code transcript (its subagents included) or one Codex rollout. Active time counts the gaps between responses up to 15 minutes; longer pauses are idle. The heatmap counts model responses by local weekday and hour. Cursor and API usage carry no time of day.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var dayCount: Int {
        max(1, Calendar.current.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
    }

    private func longestFootnote(_ s: SessionActivity) -> String {
        let when = s.start.formatted(.dateTime.month(.abbreviated).day())
        if let p = s.project { return "\(when) · \((p as NSString).lastPathComponent)" }
        return when
    }
}

/// 7 × 24 grid of model responses, one sequential hue from light to dark. Rows are numeric
/// (first weekday at the top) so every cell is a true rectangle with a small gap around it.
struct ActivityHeatmap: View {
    let cells: [UsageAggregator.HeatCell]
    let hue: Color
    @State private var hovered: (weekday: Int, hour: Int)? = nil

    private let weekdays = UsageAggregator.orderedWeekdays()
    private let symbols = Calendar.current.shortWeekdaySymbols

    private func name(_ weekday: Int) -> String { symbols[(weekday - 1) % 7] }
    /// Row 6 is the top of the chart (y grows upward), so the first weekday goes there.
    private func row(_ weekday: Int) -> Int { 6 - (weekdays.firstIndex(of: weekday) ?? 0) }

    var body: some View {
        let maxRequests = max(1, cells.map(\.requests).max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            Chart(cells) { cell in
                RectangleMark(
                    xStart: .value("Hour", Double(cell.hour) + 0.06),
                    xEnd: .value("Hour", Double(cell.hour) + 0.94),
                    yStart: .value("Day", Double(row(cell.weekday)) + 0.08),
                    yEnd: .value("Day", Double(row(cell.weekday)) + 0.92)
                )
                .foregroundStyle(hue.opacity(cell.requests == 0 ? 0.06 : 0.18 + 0.82 * Double(cell.requests) / Double(maxRequests)))
                .cornerRadius(2)
                .opacity(hovered == nil || (hovered?.weekday == cell.weekday && hovered?.hour == cell.hour) ? 1 : 0.7)
            }
            .chartXScale(domain: 0...24)
            .chartYScale(domain: 0...7)
            .chartXAxis {
                AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21, 24]) { v in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel { if let h = v.as(Int.self) { Text(String(format: "%02d", h)) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: (0..<7).map { Double($0) + 0.5 }) { v in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(name(weekdays[6 - Int(d)])) } }
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { hovered = nil; return }
                                let origin = geo[plot].origin
                                let point = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
                                if let hour: Double = proxy.value(atX: point.x), let y: Double = proxy.value(atY: point.y),
                                   hour >= 0, hour < 24, y >= 0, y < 7 {
                                    hovered = (weekdays[6 - Int(y)], Int(hour))
                                } else {
                                    hovered = nil
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                    if let hovered, let cell = cells.first(where: { $0.weekday == hovered.weekday && $0.hour == hovered.hour }),
                       let plot = proxy.plotFrame, let x = proxy.position(forX: Double(hovered.hour) + 0.5) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(name(cell.weekday)) \(String(format: "%02d", cell.hour)):00–\(String(format: "%02d", (cell.hour + 1) % 24)):00").font(.caption.weight(.semibold))
                            Text("\(Fmt.count(cell.requests)) responses · \(Fmt.tokens(cell.tokens)) tokens").font(.caption.monospacedDigit())
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 3, y: 1)
                        .offset(x: min(max(geo[plot].origin.x + x - 90, 0), geo.size.width - 190), y: 0)
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 190)

            HStack(spacing: 6) {
                Text("fewer").font(.caption2).foregroundStyle(.tertiary)
                LinearGradient(colors: [hue.opacity(0.18), hue], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 80, height: 6).clipShape(Capsule())
                Text("more").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Hours in local time; the darkest cell is \(Fmt.count(maxRequests)) responses.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
