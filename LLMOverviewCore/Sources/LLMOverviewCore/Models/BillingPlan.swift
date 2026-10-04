import Foundation

/// How a provider is paid for. Subscription sources (Codex on a ChatGPT plan, Cursor Pro+,
/// Claude Code on a seat) have a flat monthly fee; the per-token figures the app computes for
/// them are *API-equivalent value*, not spend. Pay-per-use sources bill what they report.
public struct BillingPlan: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case payPerUse, subscription
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .payPerUse: return "Pay per use"
            case .subscription: return "Subscription"
            }
        }
    }

    public var kind: Kind
    /// Flat monthly price in USD. 0 means "not entered yet".
    public var monthlyFeeUSD: Double
    /// The fee was filled in from the provider's own account data and may be refreshed;
    /// false once the user edits it.
    public var autoDetected: Bool
    /// Tier as detected or typed, e.g. "Cursor Pro+", "ChatGPT Plus", "Claude Team (Premium seat)".
    public var planName: String?

    public init(kind: Kind, monthlyFeeUSD: Double = 0, autoDetected: Bool = false, planName: String? = nil) {
        self.kind = kind
        self.monthlyFeeUSD = monthlyFeeUSD
        self.autoDetected = autoDetected
        self.planName = planName
    }

    private enum CodingKeys: String, CodingKey { case kind, monthlyFeeUSD, autoDetected, planName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        monthlyFeeUSD = try c.decodeIfPresent(Double.self, forKey: .monthlyFeeUSD) ?? 0
        autoDetected = try c.decodeIfPresent(Bool.self, forKey: .autoDetected) ?? false
        planName = try c.decodeIfPresent(String.self, forKey: .planName)
    }

    public static func `default`(for provider: ProviderID) -> BillingPlan {
        switch provider {
        case .claudeCode, .codexCLI, .cursor: return BillingPlan(kind: .subscription)
        case .anthropicAPI, .openAIAPI, .xai, .openRouter: return BillingPlan(kind: .payPerUse)
        }
    }

    public var isSubscription: Bool { kind == .subscription }
    public var hasFee: Bool { isSubscription && monthlyFeeUSD > 0 }

    /// The subscription fee attributable to `interval`: each overlapping calendar month
    /// contributes fee × (overlapping days ÷ days in that month). A whole month → one fee;
    /// a 7-day range → about a quarter of one. nil for pay-per-use or when no fee is set.
    public func paid(in interval: DateInterval, calendar: Calendar = .current) -> Double? {
        guard hasFee else { return nil }
        return Self.prorate(monthlyFee: monthlyFeeUSD, over: interval, calendar: calendar)
    }

    public static func prorate(monthlyFee: Double, over interval: DateInterval, calendar: Calendar = .current) -> Double {
        var total = 0.0
        var cursor = calendar.startOfDay(for: interval.start)
        let end = interval.end
        while cursor < end {
            let comps = calendar.dateComponents([.year, .month], from: cursor)
            let monthStart = calendar.date(from: comps)!
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            let daysInMonth = calendar.dateComponents([.day], from: monthStart, to: nextMonth).day ?? 30
            let sliceEnd = min(end, nextMonth)
            let days = calendar.dateComponents([.day], from: cursor, to: sliceEnd).day ?? 0
            total += monthlyFee * Double(days) / Double(daysInMonth)
            cursor = nextMonth
        }
        return total
    }
}
