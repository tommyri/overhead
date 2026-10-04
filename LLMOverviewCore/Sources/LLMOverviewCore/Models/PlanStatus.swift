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

        public init(title: String, usedPercent: Double, detail: String? = nil, resetsAt: Date? = nil) {
            self.title = title; self.usedPercent = usedPercent; self.detail = detail; self.resetsAt = resetsAt
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

    /// "5-hour window", "Weekly window" from a window length.
    public static func windowTitle(minutes: Int) -> String {
        switch minutes {
        case 0: return "Usage window"
        case ..<120: return "\(minutes)-minute window"
        case ..<1440: return "\(minutes / 60)-hour window"
        case 10080: return "Weekly window"
        default: return "\(minutes / 1440)-day window"
        }
    }
}
