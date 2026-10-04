import Foundation

/// Tool calls made by an agentic coding tool on one day: how often each tool was invoked and
/// how many of those invocations failed.
public struct ToolActivity: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)|\(DayKey.string(for: day))|\(tool)|\(project ?? "")" }

    public var provider: ProviderID
    public var day: Date
    /// Tool name as the product reports it, e.g. "Bash", "Edit", "exec_command", "apply_patch".
    public var tool: String
    public var project: String?
    public var calls: Int
    /// Calls whose result was an error (Claude Code `is_error`, Codex non-zero exit code).
    public var errors: Int

    public init(provider: ProviderID, day: Date, tool: String, project: String? = nil, calls: Int = 0, errors: Int = 0) {
        self.provider = provider; self.day = day; self.tool = tool; self.project = project; self.calls = calls; self.errors = errors
    }

    public mutating func merge(_ o: ToolActivity) { calls += o.calls; errors += o.errors }
}

public extension UsageAggregator {
    struct ToolTotals: Sendable, Hashable {
        public var calls = 0
        public var errors = 0
        public init() {}
        public mutating func add(_ t: ToolActivity) { calls += t.calls; errors += t.errors }
        public var errorRate: Double? { calls > 0 ? Double(errors) / Double(calls) : nil }
    }

    static func filter(_ items: [ToolActivity], in interval: DateInterval) -> [ToolActivity] {
        items.filter { $0.day >= interval.start && $0.day < interval.end }
    }

    static func toolTotals(_ items: [ToolActivity]) -> ToolTotals {
        var t = ToolTotals(); for i in items { t.add(i) }; return t
    }

    struct ToolGroup: Sendable, Hashable, Identifiable {
        public var id: String { "\(provider.rawValue)|\(tool)" }
        public var provider: ProviderID
        public var tool: String
        public var totals: ToolTotals
    }

    /// Per (provider, tool), most-called first.
    static func toolTotalsByTool(_ items: [ToolActivity]) -> [ToolGroup] {
        var out: [String: ToolGroup] = [:]
        for t in items {
            let key = "\(t.provider.rawValue)|\(t.tool)"
            var g = out[key] ?? ToolGroup(provider: t.provider, tool: t.tool, totals: ToolTotals())
            g.totals.add(t); out[key] = g
        }
        return out.values.sorted { ($0.totals.calls, $0.tool) > ($1.totals.calls, $1.tool) }
    }

    struct ToolDailyPoint: Sendable, Hashable, Identifiable {
        public var id: String { "\(DayKey.string(for: day))|\(provider.rawValue)" }
        public var day: Date
        public var provider: ProviderID
        public var calls: Int
    }

    static func toolDailySeries(_ items: [ToolActivity], in interval: DateInterval, providers: [ProviderID], calendar: Calendar = .current) -> [ToolDailyPoint] {
        var buckets: [String: ToolDailyPoint] = [:]
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            for p in providers { buckets["\(DayKey.string(for: day))|\(p.rawValue)"] = ToolDailyPoint(day: day, provider: p, calls: 0) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        for t in items where providers.contains(t.provider) {
            buckets["\(DayKey.string(for: t.day))|\(t.provider.rawValue)"]?.calls += t.calls
        }
        return buckets.values.sorted { ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue) }
    }
}
