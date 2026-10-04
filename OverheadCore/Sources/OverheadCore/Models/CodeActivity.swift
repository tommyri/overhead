import Foundation

/// Lines of code produced by an AI tool on one day: accepted edits from Claude Code and
/// Codex, suggested-vs-accepted lines from Cursor's Tab and Composer.
public struct CodeActivity: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)|\(DayKey.string(for: day))|\(kind)|\(project ?? "")" }

    public var provider: ProviderID
    public var day: Date
    /// "edits" (agent edit tools), "tab" (Cursor Tab completions), "composer" (Cursor agent).
    public var kind: String
    public var project: String?
    /// Lines the tool added and that were applied/accepted.
    public var linesAdded: Int
    /// Lines removed by applied edits (0 where the source does not report it).
    public var linesRemoved: Int
    /// Lines the tool proposed, where the source reports suggestions (Cursor). 0 otherwise.
    public var suggestedLines: Int
    /// Number of applied edits, where known.
    public var edits: Int

    public init(provider: ProviderID, day: Date, kind: String, project: String? = nil,
                linesAdded: Int = 0, linesRemoved: Int = 0, suggestedLines: Int = 0, edits: Int = 0) {
        self.provider = provider; self.day = day; self.kind = kind; self.project = project
        self.linesAdded = linesAdded; self.linesRemoved = linesRemoved; self.suggestedLines = suggestedLines; self.edits = edits
    }

    public mutating func merge(_ o: CodeActivity) {
        linesAdded += o.linesAdded; linesRemoved += o.linesRemoved; suggestedLines += o.suggestedLines; edits += o.edits
    }

    /// Count the lines a text occupies (empty text = 0 lines).
    public static func lineCount(_ s: String?) -> Int {
        guard let s, !s.isEmpty else { return 0 }
        var n = 1
        for ch in s.utf8 where ch == 0x0A { n += 1 }
        if s.hasSuffix("\n") { n -= 1 }
        return max(1, n)
    }

    /// Count added and removed lines in a unified-diff-like body (lines starting with "+"/"-",
    /// ignoring headers "+++", "---" and Codex patch directives "*** ...").
    public static func diffCounts(_ patch: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("***") { continue }
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }
}

public extension UsageAggregator {
    struct CodeTotals: Sendable, Hashable {
        public var linesAdded = 0
        public var linesRemoved = 0
        public var suggestedLines = 0
        public var edits = 0
        public init() {}
        public mutating func add(_ c: CodeActivity) {
            linesAdded += c.linesAdded; linesRemoved += c.linesRemoved; suggestedLines += c.suggestedLines; edits += c.edits
        }
        /// Share of suggested lines that were accepted, where suggestions are reported. nil when
        /// the source's counts are not comparable (Cursor can report more accepted than suggested
        /// lines, since accepted edits may exceed the suggestion shown).
        public var acceptanceRate: Double? {
            guard suggestedLines > 0, linesAdded <= suggestedLines else { return nil }
            return Double(linesAdded) / Double(suggestedLines)
        }
    }

    static func filter(_ items: [CodeActivity], in interval: DateInterval) -> [CodeActivity] {
        items.filter { $0.day >= interval.start && $0.day < interval.end }
    }

    static func codeTotals(_ items: [CodeActivity]) -> CodeTotals {
        var t = CodeTotals(); for c in items { t.add(c) }; return t
    }

    struct CodeGroup: Sendable, Hashable, Identifiable {
        public var id: String { "\(provider.rawValue)|\(kind)" }
        public var provider: ProviderID
        public var kind: String
        public var totals: CodeTotals
    }

    static func codeTotalsByProviderAndKind(_ items: [CodeActivity]) -> [CodeGroup] {
        var out: [String: CodeGroup] = [:]
        for c in items {
            let key = "\(c.provider.rawValue)|\(c.kind)"
            var g = out[key] ?? CodeGroup(provider: c.provider, kind: c.kind, totals: CodeTotals())
            g.totals.add(c); out[key] = g
        }
        return out.values.sorted { ($0.provider.paletteSlot, $0.kind) < ($1.provider.paletteSlot, $1.kind) }
    }

    struct CodeDailyPoint: Sendable, Hashable, Identifiable {
        public var id: String { "\(DayKey.string(for: day))|\(provider.rawValue)" }
        public var day: Date
        public var provider: ProviderID
        public var linesAdded: Int
    }

    static func codeDailySeries(_ items: [CodeActivity], in interval: DateInterval, providers: [ProviderID], calendar: Calendar = .current) -> [CodeDailyPoint] {
        var buckets: [String: CodeDailyPoint] = [:]
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            for p in providers { buckets["\(DayKey.string(for: day))|\(p.rawValue)"] = CodeDailyPoint(day: day, provider: p, linesAdded: 0) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        for c in items where providers.contains(c.provider) {
            let key = "\(DayKey.string(for: c.day))|\(c.provider.rawValue)"
            buckets[key]?.linesAdded += c.linesAdded
        }
        return buckets.values.sorted { ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue) }
    }
}
