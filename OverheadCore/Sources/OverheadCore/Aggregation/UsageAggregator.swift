import Foundation

/// Pure functions that fold `[UsageRecord]` into the shapes the UI needs.
public enum UsageAggregator {

    /// Collapse records sharing (provider, day, model) into one record each.
    public static func dedupe(_ records: [UsageRecord]) -> [UsageRecord] {
        var byID: [String: UsageRecord] = [:]
        for r in records {
            if var existing = byID[r.id] {
                existing.merge(r)
                byID[r.id] = existing
            } else {
                byID[r.id] = r
            }
        }
        return byID.values.sorted { ($0.day, $0.provider.rawValue, $0.model) < ($1.day, $1.provider.rawValue, $1.model) }
    }

    public static func filter(_ records: [UsageRecord], in interval: DateInterval) -> [UsageRecord] {
        records.filter { $0.day >= interval.start && $0.day < interval.end }
    }

    public struct Totals: Sendable, Hashable {
        public var inputTokens = 0
        public var outputTokens = 0
        public var cacheWriteTokens = 0
        public var cacheReadTokens = 0
        public var requests = 0
        /// Reasoning tokens, a subset of `outputTokens`; 0 where no source reported them.
        public var reasoningTokens = 0
        public var cost: UsageRecord.Cost = .unknown
        public var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
        /// Share of output tokens spent on reasoning, when any were reported.
        public var thinkingShare: Double? {
            reasoningTokens > 0 && outputTokens > 0 ? Double(reasoningTokens) / Double(outputTokens) : nil
        }
        /// Share of prompt tokens served from cache.
        public var cacheHitRate: Double? {
            let prompt = inputTokens + cacheReadTokens + cacheWriteTokens
            return prompt > 0 ? Double(cacheReadTokens) / Double(prompt) : nil
        }

        public init() {}

        mutating func add(_ r: UsageRecord) {
            inputTokens += r.inputTokens
            outputTokens += r.outputTokens
            cacheWriteTokens += r.cacheWriteTokens
            cacheReadTokens += r.cacheReadTokens
            requests += r.requests
            reasoningTokens += r.reasoningTokens
            cost = .sum(cost, r.cost)
        }
    }

    // MARK: Cache savings

    /// What prompt caching saved, at list prices, over the records whose model has a price.
    public struct CacheSavings: Sendable, Hashable {
        /// List-price cost with caching as it happened (the record's own estimate where it has one).
        public var withCache: Double
        /// What the same tokens would have cost had every prompt token been billed as fresh input.
        public var withoutCache: Double
        public var saved: Double { withoutCache - withCache }
        /// Share of prompt tokens read from cache, over the priced records.
        public var cacheHitRate: Double
        public init(withCache: Double, withoutCache: Double, cacheHitRate: Double) {
            self.withCache = withCache; self.withoutCache = withoutCache; self.cacheHitRate = cacheHitRate
        }
    }

    /// Both sides are list-price arithmetic, so the result says what caching is worth at the
    /// vendor's API prices. A billed amount (Cursor's plan cents, an API invoice) is not used
    /// for the "with cache" side, since it is not a per-token price and would make the
    /// difference meaningless; an estimated record's own cost is, because that is the same
    /// arithmetic including the 1-hour cache-write premium. nil when no record's model is in
    /// the price table (so nothing can be compared).
    public static func cacheSavings(_ records: [UsageRecord]) -> CacheSavings? {
        var with = 0.0, without = 0.0, prompt = 0, read = 0, priced = false
        for r in records {
            let promptTokens = r.inputTokens + r.cacheReadTokens + r.cacheWriteTokens
            guard let full = PriceTable.estimate(model: r.model, input: promptTokens, output: r.outputTokens, cacheRead: 0, cacheWrite: 0) else { continue }
            let actual: Double
            if case .estimated(let v) = r.cost {
                actual = v
            } else {
                actual = PriceTable.estimate(model: r.model, input: r.inputTokens, output: r.outputTokens, cacheRead: r.cacheReadTokens, cacheWrite: r.cacheWriteTokens) ?? full
            }
            with += actual; without += full
            prompt += promptTokens; read += r.cacheReadTokens
            priced = true
        }
        guard priced else { return nil }
        return CacheSavings(withCache: with, withoutCache: without, cacheHitRate: prompt > 0 ? Double(read) / Double(prompt) : 0)
    }

    /// Relative change from `previous` to `current` (0.18 = +18%). nil when there is nothing to
    /// compare against.
    public static func change(_ current: Double, from previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }

    public static func totals(_ records: [UsageRecord]) -> Totals {
        var t = Totals()
        for r in records { t.add(r) }
        return t
    }

    public static func totalsByProvider(_ records: [UsageRecord]) -> [ProviderID: Totals] {
        var out: [ProviderID: Totals] = [:]
        for r in records { out[r.provider, default: Totals()].add(r) }
        return out
    }

    public struct ModelTotals: Sendable, Hashable, Identifiable {
        public var id: String { "\(provider.rawValue)|\(model)" }
        public var provider: ProviderID
        public var model: String
        public var totals: Totals
    }

    public static func totalsByModel(_ records: [UsageRecord]) -> [ModelTotals] {
        var out: [String: ModelTotals] = [:]
        for r in records {
            let key = "\(r.provider.rawValue)|\(r.model)"
            if var m = out[key] {
                m.totals.add(r); out[key] = m
            } else {
                var t = Totals(); t.add(r)
                out[key] = ModelTotals(provider: r.provider, model: r.model, totals: t)
            }
        }
        return out.values.sorted { ($0.totals.cost.value ?? 0, $0.totals.totalTokens) > ($1.totals.cost.value ?? 0, $1.totals.totalTokens) }
    }

    /// Usage grouped by working directory (local coding tools only).
    public struct ProjectTotals: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public var path: String
        /// Folder name, with the parent folder added when two projects share a name.
        public var name: String
        public var totals: Totals
        public var byProvider: [ProviderID: Totals]
        public var providers: [ProviderID] { ProviderID.chartOrder.filter { byProvider[$0] != nil } }
    }

    public static func totalsByProject(_ records: [UsageRecord]) -> [ProjectTotals] {
        var out: [String: ProjectTotals] = [:]
        for r in records {
            guard let path = r.project else { continue }
            var p = out[path] ?? ProjectTotals(path: path, name: (path as NSString).lastPathComponent, totals: Totals(), byProvider: [:])
            p.totals.add(r)
            p.byProvider[r.provider, default: Totals()].add(r)
            out[path] = p
        }
        // Disambiguate duplicate folder names with their parent folder.
        var byName: [String: [String]] = [:]
        for p in out.values { byName[p.name, default: []].append(p.path) }
        for (name, paths) in byName where paths.count > 1 {
            for path in paths {
                let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                out[path]?.name = parent.isEmpty ? name : "\(parent)/\(name)"
            }
        }
        return out.values.sorted { ($0.totals.cost.value ?? 0, $0.totals.totalTokens) > ($1.totals.cost.value ?? 0, $1.totals.totalTokens) }
    }

    /// One point per (day, provider) for stacked daily charts. Days with no usage are
    /// filled with zero so the x-axis is continuous across the requested interval.
    public struct DailyPoint: Sendable, Hashable, Identifiable {
        public var id: String { "\(DayKey.string(for: day))|\(provider.rawValue)" }
        public var day: Date
        public var provider: ProviderID
        public var cost: Double
        public var tokens: Int
        public var requests: Int
    }

    public static func dailySeries(_ records: [UsageRecord], in interval: DateInterval, providers: [ProviderID], calendar: Calendar = .current) -> [DailyPoint] {
        var buckets: [String: DailyPoint] = [:]
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            for p in providers {
                let key = "\(DayKey.string(for: day))|\(p.rawValue)"
                buckets[key] = DailyPoint(day: day, provider: p, cost: 0, tokens: 0, requests: 0)
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        for r in records where providers.contains(r.provider) {
            let key = "\(r.dayKey)|\(r.provider.rawValue)"
            guard var b = buckets[key] else { continue }
            b.cost += r.cost.value ?? 0
            b.tokens += r.totalTokens
            b.requests += r.requests
            buckets[key] = b
        }
        return buckets.values.sorted { ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue) }
    }
}
