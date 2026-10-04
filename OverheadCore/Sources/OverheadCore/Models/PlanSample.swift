import Foundation

/// One observation of a subscription window's consumption: "the 5-hour window stood at 37% at
/// 14:05". Codex writes one into its logs on every turn, the Claude status-line helper records
/// one whenever the percentages change, and the app samples the remaining providers on each
/// refresh. Charted on the provider page as "Plan usage over time".
public struct PlanSample: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)|\(window)|\(observedAt.timeIntervalSince1970)" }

    public var provider: ProviderID
    public var observedAt: Date
    /// Same title as the matching `PlanStatus.Window`, e.g. "5-hour window".
    public var window: String
    /// 0...100
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(provider: ProviderID, observedAt: Date, window: String, usedPercent: Double, resetsAt: Date? = nil) {
        self.provider = provider; self.observedAt = observedAt; self.window = window
        self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public extension UsageAggregator {
    static func filter(_ samples: [PlanSample], in interval: DateInterval) -> [PlanSample] {
        samples.filter { $0.observedAt >= interval.start && $0.observedAt < interval.end }
    }

    /// A point on a plan-usage line. Points carry a `series` id so the line breaks, and starts
    /// again from zero, where the window reset between two samples.
    struct PlanPoint: Sendable, Hashable, Identifiable {
        public var id: Int
        public var time: Date
        public var usedPercent: Double
        public var window: String
        public var series: String
        /// Inserted at a reset boundary rather than observed.
        public var isSynthetic: Bool
    }

    /// Turn samples into chartable points: thinned to at most `maxPoints` per window (the last
    /// sample of each time bucket, so peaks before a reset survive; the first sample of a new
    /// period is always kept), with the sawtooth made explicit by holding the last value until
    /// the reset and restarting the next period at zero.
    static func planSeries(_ samples: [PlanSample], maxPoints: Int = 400) -> [PlanPoint] {
        guard let first = samples.map(\.observedAt).min(), let last = samples.map(\.observedAt).max() else { return [] }
        let bucket = max(60.0, last.timeIntervalSince(first) / Double(max(1, maxPoints)))
        var out: [PlanPoint] = []
        var nextID = 0
        for (window, group) in Dictionary(grouping: samples, by: \.window).sorted(by: { $0.key < $1.key }) {
            let sorted = group.sorted { $0.observedAt < $1.observedAt }
            var kept: [PlanSample] = []
            for s in sorted {
                if let k = kept.last,
                   Int(k.observedAt.timeIntervalSince(first) / bucket) == Int(s.observedAt.timeIntervalSince(first) / bucket),
                   k.resetsAt == s.resetsAt {
                    kept[kept.count - 1] = s
                } else {
                    kept.append(s)
                }
            }

            var segment = 0
            var previous: PlanSample? = nil
            func add(_ time: Date, _ pct: Double, synthetic: Bool) {
                out.append(PlanPoint(id: nextID, time: time, usedPercent: pct, window: window, series: "\(window)#\(segment)", isSynthetic: synthetic))
                nextID += 1
            }
            for s in kept {
                // Reset times jitter by a minute between snapshots; only a clearly later reset is a new period.
                if let p = previous, let oldReset = p.resetsAt, let newReset = s.resetsAt,
                   newReset > oldReset.addingTimeInterval(300), oldReset <= s.observedAt {
                    add(oldReset, p.usedPercent, synthetic: true)   // hold until the reset…
                    segment += 1
                    add(oldReset, 0, synthetic: true)               // …then start the new period from zero
                }
                add(s.observedAt, s.usedPercent, synthetic: false)
                previous = s
            }
        }
        return out
    }
}
