import Foundation

/// Parses OpenAI Codex rollout logs (`~/.codex/sessions/**/rollout-*.jsonl` and
/// `~/.codex/archived_sessions/*.jsonl`).
///
/// Two record shapes carry usage. Newer files have one `token_usage_record` per response
/// (unique `response_id`). Older files only have `event_msg`/`token_count` events whose
/// `last_token_usage` is the delta for the latest response; consecutive events with an
/// unchanged running total are repeats and are skipped. Neither shape names the model, so
/// each is attributed to the most recent preceding `turn_context`.
public struct CodexProvider: UsageProvider {
    public let id: ProviderID = .codexCLI

    public struct Entry: Codable, Sendable, Hashable {
        public var key: String
        public var timestamp: Date
        public var model: String
        /// Raw OpenAI counts: `cached` and `cacheWrite` are subsets of `input`.
        public var input: Int
        public var cached: Int
        public var cacheWrite: Int
        public var output: Int
        public var reasoning: Int
        /// Working directory of the session, when recorded.
        public var cwd: String?
    }

    /// Latest plan rate-limit snapshot found in the logs (ChatGPT-subscription users).
    public struct RateLimits: Codable, Sendable, Hashable {
        public struct Window: Codable, Sendable, Hashable {
            public var usedPercent: Double
            public var windowMinutes: Int
            public var resetsAt: Date?
        }
        public var observedAt: Date
        public var planType: String?
        public var primary: Window?
        public var secondary: Window?
    }

    public var roots: [URL]
    private let cache: ParsedFileCache<Entry>

    public init(roots: [URL]? = nil, cacheDirectory: URL? = nil) {
        let home = LogFiles.home()
        self.roots = roots ?? [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]
        self.cache = ParsedFileCache(name: "codex-v2", directory: cacheDirectory)
    }

    public func fetch(interval: DateInterval, credentials: Credentials) async throws -> [UsageRecord] {
        let files = roots.flatMap { root in
            LogFiles.enumerate(root) { $0.pathExtension == "jsonl" }
        }
        guard !files.isEmpty else {
            throw ProviderError.noData("No Codex logs found under ~/.codex/sessions.")
        }
        let entries = await cache.entries(for: files, parse: Self.parseFile)
        return Self.aggregate(entries)
    }

    public func resetCache() async { await cache.reset() }

    public func planStatus(credentials: Credentials) async throws -> PlanStatus? {
        guard let rl = latestRateLimits() else { return nil }
        var windows: [PlanStatus.Window] = []
        for w in [rl.primary, rl.secondary].compactMap({ $0 }) {
            let start = (w.windowMinutes > 0) ? w.resetsAt?.addingTimeInterval(-Double(w.windowMinutes) * 60) : nil
            windows.append(.init(title: PlanStatus.windowTitle(minutes: w.windowMinutes), usedPercent: w.usedPercent,
                                 resetsAt: w.resetsAt, periodStart: start))
        }
        let tier = rl.planType.flatMap { PlanPrices.chatGPT(planType: $0) }
        let name = tier?.name ?? rl.planType.map { "ChatGPT \($0)" }
        return PlanStatus(
            planName: name,
            observedAt: rl.observedAt,
            windows: windows,
            note: "Codex usage on a ChatGPT plan is included in the subscription; the cost column is what the same tokens would cost on the API.",
            suggestedPlan: name.map { PlanStatus.SuggestedPlan(name: $0, monthlyFeeUSD: tier?.monthly, source: "Codex logs") }
        )
    }

    /// Scan recently modified session files, newest first, for the newest `rate_limits`
    /// block. Subagent and review sessions often carry none, so keep going until a few
    /// files have yielded one (bounded so a huge log directory stays cheap).
    public func latestRateLimits() -> RateLimits? {
        let files = roots.flatMap { LogFiles.enumerate($0) { $0.pathExtension == "jsonl" } }
        let recent = files
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, d)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(60)
        var best: RateLimits?
        var hits = 0
        for (url, _) in recent {
            if let rl = try? Self.parseRateLimits(url) {
                hits += 1
                if best == nil || rl.observedAt > best!.observedAt { best = rl }
                if hits >= 3 { break }
            }
        }
        return best
    }

    // MARK: Parsing

    private struct Usage: Decodable, Equatable {
        let input_tokens: Int?
        let cached_input_tokens: Int?
        let cache_write_input_tokens: Int?
        let output_tokens: Int?
        let reasoning_output_tokens: Int?
        let total_tokens: Int?
    }

    private struct Line: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let model: String?
            let cwd: String?
            let turn_id: String?
            let info: Info?
            let response_id: String?
            let usage: Usage?
            let rate_limits: RateLimitsPayload?
        }
        struct Info: Decodable {
            let total_token_usage: Usage?
            let last_token_usage: Usage?
        }
        struct RateLimitsPayload: Decodable {
            let plan_type: String?
            let primary: Window?
            let secondary: Window?
            struct Window: Decodable {
                let used_percent: Double?
                let window_minutes: Int?
                let resets_at: Double?
            }
        }
    }

    public static func parseFile(_ url: URL) throws -> [Entry] {
        let decoder = JSONDecoder()
        let iso = LogFiles.makeISO8601()
        let isoPlain = ISO8601DateFormatter()

        var currentModel = ""
        var currentCwd: String? = nil
        var modelByTurn: [String: String] = [:]
        var cwdByTurn: [String: String?] = [:]
        var usageRecords: [Entry] = []
        var seenResponseIDs: Set<String> = []
        var countEvents: [Entry] = []
        var previousTotal: Usage?

        try LogFiles.forEachLine(in: url) { line in
            let isTurn = line.containsASCII("\"turn_context\"")
            let isMeta = line.containsASCII("\"session_meta\"")
            let isUsageRecord = line.containsASCII("\"token_usage_record\"")
            let isTokenCount = line.containsASCII("\"token_count\"")
            guard isTurn || isMeta || isUsageRecord || isTokenCount else { return }
            guard let rec = try? decoder.decode(Line.self, from: line), let payload = rec.payload else { return }
            let date = rec.timestamp.flatMap { LogFiles.parseDate($0, fractional: iso, plain: isoPlain) }

            switch rec.type {
            case "session_meta":
                if currentCwd == nil, let c = UsageRecord.projectKey(payload.cwd) { currentCwd = c }
            case "turn_context":
                if let m = payload.model, !m.isEmpty {
                    currentModel = m
                    if let t = payload.turn_id { modelByTurn[t] = m }
                }
                if let c = UsageRecord.projectKey(payload.cwd) {
                    currentCwd = c
                    if let t = payload.turn_id { cwdByTurn[t] = c }
                }
            case "token_usage_record":
                guard let u = payload.usage, let rid = payload.response_id, let date else { return }
                guard seenResponseIDs.insert(rid).inserted else { return }
                let model = payload.turn_id.flatMap { modelByTurn[$0] } ?? currentModel
                let cwd = payload.turn_id.flatMap { cwdByTurn[$0] ?? nil } ?? currentCwd
                usageRecords.append(Self.entry(key: rid, date: date, model: model, cwd: cwd, u))
            case "event_msg":
                guard payload.type == "token_count", let info = payload.info,
                      let total = info.total_token_usage, let last = info.last_token_usage, let date else { return }
                if let prev = previousTotal, prev == total { return }
                previousTotal = total
                let key = "\(rec.timestamp ?? "")|\(total.input_tokens ?? 0)|\(total.output_tokens ?? 0)|\(total.cached_input_tokens ?? 0)"
                countEvents.append(Self.entry(key: key, date: date, model: currentModel, cwd: currentCwd, last))
            default:
                break
            }
        }
        // Prefer the precise per-response records when a file has them.
        return usageRecords.isEmpty ? countEvents : usageRecords
    }

    private static func entry(key: String, date: Date, model: String, cwd: String?, _ u: Usage) -> Entry {
        Entry(key: key, timestamp: date, model: model.isEmpty ? "unknown" : model,
              input: u.input_tokens ?? 0, cached: u.cached_input_tokens ?? 0,
              cacheWrite: u.cache_write_input_tokens ?? 0, output: u.output_tokens ?? 0,
              reasoning: u.reasoning_output_tokens ?? 0, cwd: cwd)
    }

    static func parseRateLimits(_ url: URL) throws -> RateLimits? {
        let decoder = JSONDecoder()
        let iso = LogFiles.makeISO8601()
        let isoPlain = ISO8601DateFormatter()
        var latest: RateLimits?
        try LogFiles.forEachLine(in: url) { line in
            guard line.containsASCII("\"rate_limits\""), line.containsASCII("\"token_count\"") else { return }
            guard let rec = try? decoder.decode(Line.self, from: line), let rl = rec.payload?.rate_limits,
                  let ts = rec.timestamp, let date = LogFiles.parseDate(ts, fractional: iso, plain: isoPlain) else { return }
            func window(_ w: Line.RateLimitsPayload.Window?) -> RateLimits.Window? {
                guard let w, let pct = w.used_percent else { return nil }
                return .init(usedPercent: pct, windowMinutes: w.window_minutes ?? 0,
                             resetsAt: w.resets_at.map { Date(timeIntervalSince1970: $0) })
            }
            latest = RateLimits(observedAt: date, planType: rl.plan_type, primary: window(rl.primary), secondary: window(rl.secondary))
        }
        return latest
    }

    // MARK: Aggregation

    public static func aggregate(_ entries: [Entry], resolver: ProjectResolver = ProjectResolver()) -> [UsageRecord] {
        var unique: [String: Entry] = [:]
        for e in entries where unique[e.key] == nil { unique[e.key] = e }

        let projects = resolver.resolve(unique.values.map(\.cwd))
        var records: [String: UsageRecord] = [:]
        for e in unique.values {
            let day = DayKey.startOfDay(e.timestamp)
            let project = e.cwd.flatMap { projects[$0] }
            let rid = "\(DayKey.string(for: day))|\(e.model)|\(project ?? "")"
            var r = records[rid] ?? UsageRecord(provider: .codexCLI, day: day, model: e.model, project: project)
            // Normalize to disjoint buckets: uncached input, cache read, cache write, output.
            let cacheRead = min(e.cached, e.input)
            let cacheWrite = min(e.cacheWrite, max(0, e.input - cacheRead))
            r.inputTokens += max(0, e.input - cacheRead - cacheWrite)
            r.cacheReadTokens += cacheRead
            r.cacheWriteTokens += cacheWrite
            r.outputTokens += e.output
            r.requests += 1
            records[rid] = r
        }
        return records.values.map { r in
            var r = r
            if let c = PriceTable.estimate(model: r.model, input: r.inputTokens, output: r.outputTokens,
                                           cacheRead: r.cacheReadTokens, cacheWrite: r.cacheWriteTokens) {
                r.cost = .estimated(c)
            }
            return r
        }
        .sorted { ($0.day, $0.model, $0.project ?? "") < ($1.day, $1.model, $1.project ?? "") }
    }
}
