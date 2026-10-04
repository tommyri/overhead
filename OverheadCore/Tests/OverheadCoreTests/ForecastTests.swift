import Foundation
import Testing
@testable import OverheadCore

@Suite struct ForecastTests {
    @Test func projectsWindowPaceAndExhaustion() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(7 * 86400)
        let now = start.addingTimeInterval(7 * 86400 * 0.25)           // a quarter in
        let w = PlanStatus.Window(title: "Weekly window", usedPercent: 50, resetsAt: end, periodStart: start)
        let p = try #require(Forecast.project(w, now: now))
        #expect(abs(p.elapsedFraction - 0.25) < 1e-9)
        #expect(abs(p.projectedPercentAtReset - 200) < 1e-9)
        #expect(p.exhaustsAt == start.addingTimeInterval(7 * 86400 * 0.5))  // 100% at the halfway mark

        let calm = PlanStatus.Window(title: "Weekly window", usedPercent: 10, resetsAt: end, periodStart: start)
        let q = try #require(Forecast.project(calm, now: now))
        #expect(q.exhaustsAt == nil && abs(q.projectedPercentAtReset - 40) < 1e-9)

        let tooEarly = Forecast.project(w, now: start.addingTimeInterval(60))
        #expect(tooEarly == nil)
        #expect(Forecast.project(PlanStatus.Window(title: "x", usedPercent: 50), now: now) == nil)
    }

    @Test func projectsMonthEndFromRecentPace() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 12))!   // day 10 of 30
        var records: [UsageRecord] = []
        for d in 1...10 {
            let day = cal.date(from: DateComponents(year: 2026, month: 9, day: d))!
            records.append(UsageRecord(provider: .codexCLI, day: day, model: "m", cost: .estimated(d <= 3 ? 1 : 10)))
        }
        records.append(UsageRecord(provider: .codexCLI, day: cal.date(from: DateComponents(year: 2026, month: 8, day: 31))!, model: "m", cost: .estimated(999)))
        let f = Forecast.monthEnd(records: records, now: now, paceDays: 7, calendar: cal)
        #expect(f.daysElapsed == 10 && f.daysInMonth == 30 && f.daysRemaining == 20)
        #expect(abs(f.valueToDate - 73) < 1e-9)                 // 3×1 + 7×10, August ignored
        #expect(abs(f.dailyRate - 10) < 1e-9)                   // last 7 days were all 10
        #expect(abs(f.projectedValue - (73 + 200)) < 1e-9)
        #expect(f.isEstimate)
    }
}
