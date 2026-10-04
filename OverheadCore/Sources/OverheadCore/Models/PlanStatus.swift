import Foundation

/// Subscription-plan consumption that is not a per-token cost: Codex's ChatGPT rolling
/// windows, Cursor's included-usage budget, etc. Shown as progress bars on the provider page.
public struct PlanStatus: Codable, Sendable, Hashable {
    public struct Window: Codable, Sendable, Hashable, Identifiable {
        public var id: String { title }
        public var title: String
        /// 0...100
        public var usedPercent: Double
        /// e.g. "$14.20 of $60.00"
        public var detail: String?
        public var resetsAt: Date?
        /// Start of the current period, when known; enables projections.
        public var periodStart: Date?

        public init(title: String, usedPercent: Double, detail: String? = nil, resetsAt: Date? = nil, periodStart: Date? = nil) {
            self.title = title; self.usedPercent = usedPercent; self.detail = detail; self.resetsAt = resetsAt
            self.periodStart = periodStart
        }
    }

    /// What the provider's own account data says the user is subscribed to.
    public struct SuggestedPlan: Codable, Sendable, Hashable {
        public var name: String
        /// List price per month, if the tier is known. nil → user must enter it.
        public var monthlyFeeUSD: Double?
        /// Where it came from, e.g. "cursor.com account", "Codex logs", "~/.claude.json".
        public var source: String
        public init(name: String, monthlyFeeUSD: Double?, source: String) {
            self.name = name; self.monthlyFeeUSD = monthlyFeeUSD; self.source = source
        }
    }

    public var planName: String?
    public var observedAt: Date
    public var windows: [Window]
    /// Caveat shown under the bars.
    public var note: String?
    public var suggestedPlan: SuggestedPlan?

    public init(planName: String?, observedAt: Date, windows: [Window], note: String? = nil, suggestedPlan: SuggestedPlan? = nil) {
        self.planName = planName; self.observedAt = observedAt; self.windows = windows; self.note = note
        self.suggestedPlan = suggestedPlan
    }

    /// "5-hour window", "Weekly window" from a window length. Lengths are rounded, because Codex
    /// reports the same window as 299 or 300 minutes (10079 or 10080) from one snapshot to the next.
    public static func windowTitle(minutes: Int) -> String {
        switch minutes {
        case 0: return "Usage window"
        case ..<120: return "\(minutes)-minute window"
        case ..<1440: return "\(Int((Double(minutes) / 60).rounded()))-hour window"
        case 9_900...10_260: return "Weekly window"
        default: return "\(Int((Double(minutes) / 1440).rounded()))-day window"
        }
    }
}
