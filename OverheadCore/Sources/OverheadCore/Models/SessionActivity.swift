import Foundation

/// One session of an agentic coding tool: a Claude Code transcript (subagents folded into their
/// parent) or a Codex rollout. Built from the per-response entries the parsers already keep.
public struct SessionActivity: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)|\(sessionID)" }

    public var provider: ProviderID
    public var sessionID: String
    public var project: String?
    /// First and last model response.
    public var start: Date
    public var end: Date
    /// Seconds of activity: the gaps between consecutive responses, each counted up to the idle
    /// threshold (`SessionAggregator.idleThreshold`), so a transcript left open overnight does
    /// not count the night.
    public var activeSeconds: Double
    public var requests: Int
    public var totalTokens: Int
    public var outputTokens: Int
    /// API-equivalent value at list prices, when every model in the session has a price.
    public var cost: Double?

    public init(provider: ProviderID, sessionID: String, project: String? = nil, start: Date, end: Date,
                activeSeconds: Double, requests: Int, totalTokens: Int, outputTokens: Int, cost: Double?) {
        self.provider = provider; self.sessionID = sessionID; self.project = project; self.start = start; self.end = end
        self.activeSeconds = activeSeconds; self.requests = requests; self.totalTokens = totalTokens
        self.outputTokens = outputTokens; self.cost = cost
    }

    /// Wall-clock span from first to last response.
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Model responses per local hour of a local day, for the weekday × hour heatmap.
public struct HourlyActivity: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)|\(DayKey.string(for: day))|\(hour)" }

    public var provider: ProviderID
    /// Local midnight.
    public var day: Date
    /// 0...23, local time.
    public var hour: Int
    public var requests: Int
    public var tokens: Int

    public init(provider: ProviderID, day: Date, hour: Int, requests: Int = 0, tokens: Int = 0) {
        self.provider = provider; self.day = day; self.hour = hour; self.requests = requests; self.tokens = tokens
    }

    public mutating func merge(_ o: HourlyActivity) { requests += o.requests; tokens += o.tokens }
}

/// Builds sessions and hourly activity from per-response items, shared by the local parsers.
public enum SessionAggregator {
    /// Gaps between responses longer than this are idle time and are not counted as active.
    public static let idleThreshold: TimeInterval = 15 * 60

    /// What the aggregator needs to know about one model response.
    public struct Item: Sendable {
        public var session: String
        public var timestamp: Date
        public var model: String
        public var cwd: String?
        /// Disjoint token buckets.
        public var input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int
        public init(session: String, timestamp: Date, model: String, cwd: String?, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int = 0) {
            self.session = session; self.timestamp = timestamp; self.model = model; self.cwd = cwd
            self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.cacheWrite1h = cacheWrite1h
        }
    }

    public static func sessions(_ items: [Item], provider: ProviderID, resolver: ProjectResolver = ProjectResolver()) -> [SessionActivity] {
        let grouped = Dictionary(grouping: items, by: \.session)
        let projects = resolver.resolve(items.map(\.cwd))
        var out: [SessionActivity] = []
        for (session, group) in grouped {
            let sorted = group.sorted { $0.timestamp < $1.timestamp }
            guard let first = sorted.first, let last = sorted.last else { continue }
            var active = 0.0
            var previous = first.timestamp
            for item in sorted.dropFirst() {
                active += min(item.timestamp.timeIntervalSince(previous), idleThreshold)
                previous = item.timestamp
            }
            var cost: Double? = 0
            var total = 0, output = 0
            for item in sorted {
                total += item.input + item.output + item.cacheRead + item.cacheWrite
                output += item.output
                if let c = cost, let e = PriceTable.estimate(model: item.model, input: item.input, output: item.output, cacheRead: item.cacheRead,
                                                               cacheWrite: item.cacheWrite, cacheWrite1h: item.cacheWrite1h) {
                    cost = c + e
                } else {
                    cost = nil
                }
            }
            // The most common working directory names the session's project.
            let cwd = Dictionary(grouping: sorted.compactMap(\.cwd), by: { $0 }).max { $0.value.count < $1.value.count }?.key
            out.append(SessionActivity(provider: provider, sessionID: session, project: cwd.flatMap { projects[$0] },
                                       start: first.timestamp, end: last.timestamp, activeSeconds: active,
                                       requests: sorted.count, totalTokens: total, outputTokens: output, cost: cost))
        }
        return out.sorted { $0.start < $1.start }
    }

    public static func hourly(_ items: [Item], provider: ProviderID, calendar: Calendar = .current) -> [HourlyActivity] {
        var out: [String: HourlyActivity] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.timestamp)
            let hour = calendar.component(.hour, from: item.timestamp)
            let cell = HourlyActivity(provider: provider, day: day, hour: hour, requests: 1,
                                      tokens: item.input + item.output + item.cacheRead + item.cacheWrite)
            if var existing = out[cell.id] { existing.merge(cell); out[cell.id] = existing } else { out[cell.id] = cell }
        }
        return out.values.sorted { ($0.day, $0.hour) < ($1.day, $1.hour) }
    }
}

public extension UsageAggregator {
    static func filter(_ items: [SessionActivity], in interval: DateInterval) -> [SessionActivity] {
        items.filter { $0.start >= interval.start && $0.start < interval.end }
    }

    static func filter(_ items: [HourlyActivity], in interval: DateInterval) -> [HourlyActivity] {
        items.filter { $0.day >= interval.start && $0.day < interval.end }
    }

    struct SessionTotals: Sendable, Hashable {
        public var count = 0
        public var activeSeconds = 0.0
        public var requests = 0
        public var totalTokens = 0
        public var longest: SessionActivity? = nil
        public var medianActiveSeconds = 0.0
        public init() {}
        public var averageActiveSeconds: Double { count > 0 ? activeSeconds / Double(count) : 0 }
        public var requestsPerSession: Double { count > 0 ? Double(requests) / Double(count) : 0 }
        public var tokensPerSession: Int { count > 0 ? totalTokens / count : 0 }
    }

    static func sessionTotals(_ sessions: [SessionActivity]) -> SessionTotals {
        var t = SessionTotals()
        for s in sessions {
            t.count += 1; t.activeSeconds += s.activeSeconds; t.requests += s.requests; t.totalTokens += s.totalTokens
            if (t.longest?.activeSeconds ?? -1) < s.activeSeconds { t.longest = s }
        }
        let sorted = sessions.map(\.activeSeconds).sorted()
        if !sorted.isEmpty {
            t.medianActiveSeconds = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return t
    }

    /// One cell per weekday × hour, every cell present (zero-filled). `weekday` uses the
    /// calendar's numbering (1 = Sunday in the Gregorian calendar).
    struct HeatCell: Sendable, Hashable, Identifiable {
        public var id: String { "\(weekday)|\(hour)" }
        public var weekday: Int
        public var hour: Int
        public var requests: Int
        public var tokens: Int
    }

    static func heatmap(_ hourly: [HourlyActivity], calendar: Calendar = .current) -> [HeatCell] {
        var cells: [String: HeatCell] = [:]
        for weekday in 1...7 { for hour in 0..<24 { cells["\(weekday)|\(hour)"] = HeatCell(weekday: weekday, hour: hour, requests: 0, tokens: 0) } }
        for h in hourly {
            let weekday = calendar.component(.weekday, from: h.day)
            cells["\(weekday)|\(h.hour)"]?.requests += h.requests
            cells["\(weekday)|\(h.hour)"]?.tokens += h.tokens
        }
        return cells.values.sorted { ($0.weekday, $0.hour) < ($1.weekday, $1.hour) }
    }

    /// Weekdays in the calendar's display order, starting at its first weekday.
    static func orderedWeekdays(calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }
}
