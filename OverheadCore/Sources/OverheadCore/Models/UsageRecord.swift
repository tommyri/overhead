import Foundation

/// A normalized slice of usage: one provider, one model, one calendar day.
/// Every provider adapter emits these; everything downstream (charts, totals, menu bar)
/// only understands this shape.
public struct UsageRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)|\(dayKey)|\(model)|\(project ?? "")" }

    public var provider: ProviderID
    /// Start of the local calendar day this record belongs to.
    public var day: Date
    /// Vendor model id, e.g. "claude-sonnet-4-5-20250929" or "gpt-5".  Use "" when the
    /// provider does not break usage down by model (e.g. Cursor request counts).
    public var model: String
    /// Working directory the usage happened in, for local coding tools. nil when unknown.
    public var project: String?

    public var inputTokens: Int
    public var outputTokens: Int
    /// Tokens written to a prompt cache (Anthropic "cache_creation", OpenAI has none).
    public var cacheWriteTokens: Int
    /// Tokens served from a prompt cache (Anthropic "cache_read", OpenAI "input_cached").
    public var cacheReadTokens: Int
    /// Number of model invocations / requests, when known.
    public var requests: Int
    /// Reasoning ("thinking") tokens, a subset of `outputTokens`, where the source reports them
    /// (Claude Code `output_tokens_details.thinking_tokens`, Codex `reasoning_output_tokens`).
    /// 0 when the source does not say.
    public var reasoningTokens: Int

    /// Cost in USD. `reported` comes straight from a billing endpoint; `estimated` was
    /// computed locally from list prices; `unknown` means neither was possible.
    public var cost: Cost

    public enum Cost: Codable, Hashable, Sendable {
        case reported(Double)
        case estimated(Double)
        case unknown

        public var value: Double? {
            switch self {
            case .reported(let v), .estimated(let v): return v
            case .unknown: return nil
            }
        }
        public var isEstimate: Bool {
            if case .estimated = self { return true }
            return false
        }
    }

    public init(
        provider: ProviderID,
        day: Date,
        model: String,
        project: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheReadTokens: Int = 0,
        requests: Int = 0,
        reasoningTokens: Int = 0,
        cost: Cost = .unknown
    ) {
        self.provider = provider
        self.day = day
        self.model = model
        self.project = project
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.requests = requests
        self.reasoningTokens = reasoningTokens
        self.cost = cost
    }

    enum CodingKeys: String, CodingKey {
        case provider, day, model, project, inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, requests, reasoningTokens, cost
    }

    /// Fields added later are optional on decode so older cache files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(ProviderID.self, forKey: .provider)
        day = try c.decode(Date.self, forKey: .day)
        model = try c.decode(String.self, forKey: .model)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheWriteTokens = try c.decode(Int.self, forKey: .cacheWriteTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        requests = try c.decode(Int.self, forKey: .requests)
        reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        cost = try c.decode(Cost.self, forKey: .cost)
    }

    /// All tokens that went through the model, regardless of cache status.
    public var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }

    /// "2026-10-04" in the local calendar — used for grouping and stable ids.
    public var dayKey: String { DayKey.string(for: day) }

    /// Normalize a working directory for use as a project key: trailing slash removed,
    /// empty/root treated as unknown.
    public static func projectKey(_ cwd: String?) -> String? {
        guard var c = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        while c.count > 1 && c.hasSuffix("/") { c.removeLast() }
        return c == "/" ? nil : c
    }

    /// "~/dev/overhead" style display path.
    public static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Merge another record for the same (provider, day, model) into this one.
    public mutating func merge(_ other: UsageRecord) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheWriteTokens += other.cacheWriteTokens
        cacheReadTokens += other.cacheReadTokens
        requests += other.requests
        reasoningTokens += other.reasoningTokens
        cost = Cost.sum(cost, other.cost)
    }
}

public extension UsageRecord.Cost {
    /// Sum two costs. Any estimate in the mix makes the result an estimate; an unknown
    /// combined with a known value keeps the known value (we lose nothing by adding 0).
    static func sum(_ a: Self, _ b: Self) -> Self {
        switch (a, b) {
        case (.unknown, .unknown): return .unknown
        case (.unknown, let x), (let x, .unknown): return x
        case (.reported(let x), .reported(let y)): return .reported(x + y)
        case (.reported(let x), .estimated(let y)),
             (.estimated(let x), .reported(let y)),
             (.estimated(let x), .estimated(let y)): return .estimated(x + y)
        }
    }
}

/// Local-calendar day bucketing shared by every adapter.
public enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func string(for date: Date) -> String {
        formatter.string(from: date)
    }

    public static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// Local midnight for a calendar date given as year/month/day.
    public static func localDay(year: Int, month: Int, day: Int) -> Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Local midnight for the "yyyy-MM-dd" prefix of an ISO-8601 string.
    public static func localDay(fromISOPrefix s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return localDay(year: y, month: m, day: d)
    }

    /// Vendors bucket by UTC day. Map a UTC bucket start to the local day with the same
    /// calendar date, so "2026-10-01" stays October 1st regardless of the user's offset.
    public static func localDay(fromUTC date: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return localDay(year: c.year!, month: c.month!, day: c.day!) ?? startOfDay(date)
    }

    /// Split an interval into windows of at most `maxDays` days (API page limits).
    public static func chunks(_ interval: DateInterval, maxDays: Int) -> [DateInterval] {
        var out: [DateInterval] = []
        var start = interval.start
        while start < interval.end {
            let end = min(interval.end, Calendar.current.date(byAdding: .day, value: maxDays, to: start)!)
            out.append(DateInterval(start: start, end: end))
            start = end
        }
        return out
    }

    /// RFC 3339 in UTC without fractional seconds, as the Anthropic API expects.
    public static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
