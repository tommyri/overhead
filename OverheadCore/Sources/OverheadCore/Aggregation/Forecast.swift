import Foundation

/// Straight-line projections. Deliberately simple: readers can see how a number was made.
public enum Forecast {

    // MARK: Plan windows

    public struct WindowProjection: Sendable, Hashable {
        /// Share of the period that has elapsed, 0...1.
        public var elapsedFraction: Double
        /// Usage expected at reset if the current pace continues (percent, may exceed 100).
        public var projectedPercentAtReset: Double
        /// When usage would reach 100% at the current pace, if before the reset.
        public var exhaustsAt: Date?
    }

    /// Project a rolling or billing window from its start, reset and current usage. Returns nil
    /// when the period is unknown or too little of it has elapsed to say anything (under 5%).
    public static func project(_ window: PlanStatus.Window, now: Date = Date()) -> WindowProjection? {
        guard let start = window.periodStart, let end = window.resetsAt, end > start, now > start else { return nil }
        let fraction = min(1, now.timeIntervalSince(start) / end.timeIntervalSince(start))
        guard fraction >= 0.05 else { return nil }
        let pace = window.usedPercent / fraction
        var exhaustsAt: Date? = nil
        if window.usedPercent >= 100 {
            exhaustsAt = now
        } else if pace > 100, window.usedPercent > 0 {
            let secondsToFull = now.timeIntervalSince(start) * (100 / window.usedPercent)
            let at = start.addingTimeInterval(secondsToFull)
            if at < end { exhaustsAt = at }
        }
        return WindowProjection(elapsedFraction: fraction, projectedPercentAtReset: pace, exhaustsAt: exhaustsAt)
    }

    // MARK: Month end

    public struct MonthForecast: Sendable, Hashable {
        public var monthStart: Date
        public var monthEnd: Date
        public var daysElapsed: Int
        public var daysInMonth: Int
        /// Value accrued so far this month.
        public var valueToDate: Double
        /// Average value per day over the recent window used for the projection.
        public var dailyRate: Double
        /// valueToDate + dailyRate × remaining days.
        public var projectedValue: Double
        public var isEstimate: Bool
        public var daysRemaining: Int { max(0, daysInMonth - daysElapsed) }
    }

    /// Month-to-date value plus a projection to month end at the pace of the last `paceDays`
    /// days (or the whole month so far, if shorter). Records outside this month are ignored.
    public static func monthEnd(records: [UsageRecord], now: Date = Date(), paceDays: Int = 7, calendar: Calendar = .current) -> MonthForecast {
        let today = calendar.startOfDay(for: now)
        let comps = calendar.dateComponents([.year, .month], from: now)
        let monthStart = calendar.date(from: comps)!
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let daysInMonth = calendar.dateComponents([.day], from: monthStart, to: monthEnd).day ?? 30
        let daysElapsed = (calendar.dateComponents([.day], from: monthStart, to: today).day ?? 0) + 1

        let mtd = records.filter { $0.day >= monthStart && $0.day < monthEnd }
        let totals = UsageAggregator.totals(mtd)
        let valueToDate = totals.cost.value ?? 0

        let window = min(paceDays, daysElapsed)
        let paceStart = calendar.date(byAdding: .day, value: -(window - 1), to: today)!
        let recent = mtd.filter { $0.day >= paceStart }
        let dailyRate = (UsageAggregator.totals(recent).cost.value ?? 0) / Double(max(1, window))
        let remaining = max(0, daysInMonth - daysElapsed)

        return MonthForecast(monthStart: monthStart, monthEnd: monthEnd, daysElapsed: daysElapsed, daysInMonth: daysInMonth,
                             valueToDate: valueToDate, dailyRate: dailyRate,
                             projectedValue: valueToDate + dailyRate * Double(remaining), isEstimate: totals.cost.isEstimate)
    }
}
