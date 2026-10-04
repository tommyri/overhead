import Foundation

/// Preset reporting windows shown in the toolbar picker.
public enum DateRangePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case today, last7, last30, thisMonth, lastMonth, last90

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today:     return "Today"
        case .last7:     return "7 days"
        case .last30:    return "30 days"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .last90:    return "90 days"
        }
    }

    /// Resolve into a half-open interval `[start, end)` in the local calendar.
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        switch self {
        case .today:
            return DateInterval(start: todayStart, end: tomorrow)
        case .last7:
            return DateInterval(start: calendar.date(byAdding: .day, value: -6, to: todayStart)!, end: tomorrow)
        case .last30:
            return DateInterval(start: calendar.date(byAdding: .day, value: -29, to: todayStart)!, end: tomorrow)
        case .last90:
            return DateInterval(start: calendar.date(byAdding: .day, value: -89, to: todayStart)!, end: tomorrow)
        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: comps)!
            return DateInterval(start: start, end: tomorrow)
        case .lastMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let thisMonthStart = calendar.date(from: comps)!
            let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)!
            return DateInterval(start: lastMonthStart, end: thisMonthStart)
        }
    }

    /// The comparable period before this one, for "vs previous period" deltas: the same number
    /// of days ending where this range starts; for "This month" the same elapsed days of the
    /// previous month; for "Last month" the whole month before.
    public func previousInterval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let current = interval(now: now, calendar: calendar)
        let days = max(1, calendar.dateComponents([.day], from: current.start, to: current.end).day ?? 1)
        switch self {
        case .thisMonth:
            let start = calendar.date(byAdding: .month, value: -1, to: current.start)!
            let end = min(current.start, calendar.date(byAdding: .day, value: days, to: start)!)
            return DateInterval(start: start, end: end)
        case .lastMonth:
            return DateInterval(start: calendar.date(byAdding: .month, value: -1, to: current.start)!, end: current.start)
        default:
            return DateInterval(start: calendar.date(byAdding: .day, value: -days, to: current.start)!, end: current.start)
        }
    }

    /// How the previous period is described next to a delta.
    public var previousLabel: String {
        switch self {
        case .today:     return "yesterday"
        case .last7:     return "the previous 7 days"
        case .last30:    return "the previous 30 days"
        case .last90:    return "the previous 90 days"
        case .thisMonth: return "the same days last month"
        case .lastMonth: return "the month before"
        }
    }
}
