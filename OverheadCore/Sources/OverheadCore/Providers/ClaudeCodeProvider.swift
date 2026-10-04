import Foundation

/// Parses Claude Code session transcripts (`~/.claude/projects/**/*.jsonl`) plus the
/// Claude desktop app's agent-mode audit logs. Each API response is written as several
/// lines (one per content block) sharing `message.id`/`requestId`; the final line carries
/// the real `output_tokens`, so we keep the last occurrence per key.
public struct ClaudeCodeProvider: UsageProvider {
    public let id: ProviderID = .claudeCode

    /// One deduplicated API response.
    public struct Entry: Codable, Sendable, Hashable {
        public var key: String
        public var timestamp: Date
        public var model: String
        public var input: Int
        public var output: Int
        public var cacheWrite: Int
        /// Portion of `cacheWrite` written with 1-hour TTL (priced at 2× instead of 1.25×).
        public var cacheWrite1h: Int
        public var cacheRead: Int
    }

    public var roots: [URL]
    private let cache: ParsedFileCache<Entry>

    public init(roots: [URL]? = nil, cacheDirectory: URL? = nil) {
        let home = LogFiles.home()
        self.roots = roots ?? [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions", isDirectory: true),
        ]
        self.cache = ParsedFileCache(name: "claude-code", directory: cacheDirectory)
    }

    public func fetch(interval: DateInterval, credentials: Credentials) async throws -> [UsageRecord] {
        let files = roots.flatMap { root in
            LogFiles.enumerateIncludingHidden(root) { $0.pathExtension == "jsonl" }
        }
        guard !files.isEmpty else {
            throw ProviderError.noData("No Claude Code logs found under ~/.claude/projects.")
        }
        let entries = await cache.entries(for: files, parse: Self.parseFile)
        return Self.aggregate(entries)
    }

    public func resetCache() async { await cache.reset() }

    /// Claude Code caches the signed-in account's organization type and seat tier in
    /// `~/.claude.json` (`oauthAccount`). No usage windows are available locally, so this only
    /// yields the plan name and list price.
    public var accountConfigURL: URL = LogFiles.home().appendingPathComponent(".claude.json")

    public func planStatus(credentials: Credentials) async throws -> PlanStatus? {
        guard let suggestion = Self.detectPlan(configURL: accountConfigURL) else { return nil }
        return PlanStatus(planName: suggestion.name, observedAt: Date(), windows: [], note: nil, suggestedPlan: suggestion)
    }

    static func detectPlan(configURL: URL) -> PlanStatus.SuggestedPlan? {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        let tier = PlanPrices.claude(
            organizationType: account["organizationType"] as? String,
            seatTier: account["seatTier"] as? String,
            billingType: account["billingType"] as? String,
            rateLimitTier: (account["userRateLimitTier"] as? String) ?? (account["organizationRateLimitTier"] as? String)
        )
        guard let tier else { return nil }
        return PlanStatus.SuggestedPlan(name: tier.name, monthlyFeeUSD: tier.monthly, source: "~/.claude.json")
    }

    // MARK: Parsing

    private struct Line: Decodable {
        let type: String
        let timestamp: String?
        let _audit_timestamp: String?
        let requestId: String?
        let message: Message?
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation: CacheCreation?
            struct CacheCreation: Decodable {
                let ephemeral_5m_input_tokens: Int?
                let ephemeral_1h_input_tokens: Int?
            }
        }
    }

    /// Parse one transcript file into per-response entries (deduped within the file).
    public static func parseFile(_ url: URL) throws -> [Entry] {
        let decoder = JSONDecoder()
        let iso = LogFiles.makeISO8601()
        let isoPlain = ISO8601DateFormatter()
        var byKey: [String: Entry] = [:]
        var order: [String] = []

        try LogFiles.forEachLine(in: url) { line in
            guard line.containsASCII("\"type\":\"assistant\"") else { return }
            guard let rec = try? decoder.decode(Line.self, from: line), rec.type == "assistant",
                  let msg = rec.message, let usage = msg.usage,
                  let model = msg.model, model != "<synthetic>",
                  let ts = rec.timestamp ?? rec._audit_timestamp,
                  let date = LogFiles.parseDate(ts, fractional: iso, plain: isoPlain)
            else { return }
            // Message ids are globally unique, so the same response seen in two files
            // (a Cowork audit log and its nested transcript) collapses to one entry.
            let key = (msg.id?.isEmpty == false) ? msg.id! : "\(ts)|\(rec.requestId ?? model)"
            let entry = Entry(
                key: key, timestamp: date, model: model,
                input: usage.input_tokens ?? 0,
                output: usage.output_tokens ?? 0,
                cacheWrite: usage.cache_creation_input_tokens ?? 0,
                cacheWrite1h: usage.cache_creation?.ephemeral_1h_input_tokens ?? 0,
                cacheRead: usage.cache_read_input_tokens ?? 0
            )
            if byKey[key] == nil { order.append(key) }
            byKey[key] = entry   // last occurrence wins (final output_tokens)
        }
        return order.compactMap { byKey[$0] }
    }

    /// Global dedupe (same response can appear in an audit log and a nested transcript),
    /// then roll up to (day, model) with estimated cost.
    public static func aggregate(_ entries: [Entry]) -> [UsageRecord] {
        var unique: [String: Entry] = [:]
        for e in entries {
            if let existing = unique[e.key], existing.output >= e.output { continue }
            unique[e.key] = e
        }
        var records: [String: UsageRecord] = [:]
        var oneHourWrites: [String: Int] = [:]
        for e in unique.values {
            let day = DayKey.startOfDay(e.timestamp)
            let rid = "\(DayKey.string(for: day))|\(e.model)"
            var r = records[rid] ?? UsageRecord(provider: .claudeCode, day: day, model: e.model)
            r.inputTokens += e.input
            r.outputTokens += e.output
            r.cacheWriteTokens += e.cacheWrite
            r.cacheReadTokens += e.cacheRead
            r.requests += 1
            records[rid] = r
            oneHourWrites[rid, default: 0] += min(e.cacheWrite1h, e.cacheWrite)
        }
        return records.map { rid, r in
            var r = r
            let w1h = oneHourWrites[rid] ?? 0
            if let c = PriceTable.estimate(model: r.model, input: r.inputTokens, output: r.outputTokens,
                                           cacheRead: r.cacheReadTokens, cacheWrite: r.cacheWriteTokens - w1h, cacheWrite1h: w1h) {
                r.cost = .estimated(c)
            }
            return r
        }
        .sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }
}
