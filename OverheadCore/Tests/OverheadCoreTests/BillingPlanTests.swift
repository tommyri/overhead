import Foundation
import Testing
@testable import OverheadCore

@Suite struct BillingPlanTests {
    private let cal = Calendar(identifier: .gregorian)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func wholeMonthIsOneFee() {
        let sept = DateInterval(start: day(2026, 9, 1), end: day(2026, 10, 1))
        #expect(abs(BillingPlan.prorate(monthlyFee: 60, over: sept, calendar: cal) - 60) < 1e-9)
    }

    @Test func partialMonthIsDayWeighted() {
        let firstHalf = DateInterval(start: day(2026, 9, 1), end: day(2026, 9, 16)) // 15 of 30 days
        #expect(abs(BillingPlan.prorate(monthlyFee: 60, over: firstHalf, calendar: cal) - 30) < 1e-9)
    }

    @Test func rangeAcrossMonthsSumsEachMonthsShare() {
        // 16 days of Sept (15..30) + 4 days of Oct (1..4) with a $31 fee: 16/30*31 + 4/31*31
        let range = DateInterval(start: day(2026, 9, 15), end: day(2026, 10, 5))
        let want = 16.0 / 30.0 * 31 + 4.0
        #expect(abs(BillingPlan.prorate(monthlyFee: 31, over: range, calendar: cal) - want) < 1e-9)
    }

    @Test func payPerUseAndUnsetFeeHaveNoPaidAmount() {
        let range = DateInterval(start: day(2026, 9, 1), end: day(2026, 10, 1))
        #expect(BillingPlan(kind: .payPerUse, monthlyFeeUSD: 100).paid(in: range, calendar: cal) == nil)
        #expect(BillingPlan(kind: .subscription, monthlyFeeUSD: 0).paid(in: range, calendar: cal) == nil)
        #expect(BillingPlan(kind: .subscription, monthlyFeeUSD: 20).paid(in: range, calendar: cal) == 20)
    }

    @Test func defaultsMatchHowEachSourceIsBilled() {
        #expect(BillingPlan.default(for: .codexCLI).isSubscription)
        #expect(BillingPlan.default(for: .cursor).isSubscription)
        #expect(!BillingPlan.default(for: .openAIAPI).isSubscription)
    }
}
