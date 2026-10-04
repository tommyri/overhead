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
        /// Working directory of the session, when recorded.
        public var cwd: String?
        /// Lines added/removed by Edit/Write/MultiEdit/NotebookEdit calls in this response
        /// whose tool result was not an error, and how many such edits there were.
        public var linesAdded: Int?
        public var linesRemoved: Int?
        public var edits: Int?
    }

    public var roots: [URL]
    private let cache: ParsedFileCache<Entry>

    public init(roots: [URL]? = nil, cacheDirectory: URL? = nil) {
        let home = LogFiles.home()
        self.roots = roots ?? [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions", isDirectory: true),
        ]
        self.cache = ParsedFileCache(name: "claude-code-v3", directory: cacheDirectory)
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
        let cwd: String?
        let message: Message?
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
            let content: [Block]?
            // A plain-string `content` is not an array; treat it as no blocks.
            enum CodingKeys: String, CodingKey { case id, model, usage, content }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decodeIfPresent(String.self, forKey: .id)
                model = try c.decodeIfPresent(String.self, forKey: .model)
                usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
                content = try? c.decodeIfPresent([Block].self, forKey: .content)
            }
        }
        struct Block: Decodable {
            let type: String?
            let id: String?
            let name: String?
            let input: EditInput?
            let tool_use_id: String?
            let is_error: Bool?
        }
        struct EditInput: Decodable {
            let old_string: String?
            let new_string: String?
            let content: String?
            let new_source: String?
            let edits: [SubEdit]?
            struct SubEdit: Decodable { let old_string: String?; let new_string: String? }
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
        // Edits proposed in a response, keyed by tool_use id, until their result arrives.
        var pendingEdits: [String: (entryKey: String, added: Int, removed: Int)] = [:]
        var applied: [String: (added: Int, removed: Int, edits: Int)] = [:]

        try LogFiles.forEachLine(in: url) { line in
            if line.containsASCII("\"tool_result\""), line.containsASCII("\"type\":\"user\"") {
                guard let rec = try? decoder.decode(Line.self, from: line), let blocks = rec.message?.content else { return }
                for b in blocks where b.type == "tool_result" {
                    guard let id = b.tool_use_id, let edit = pendingEdits.removeValue(forKey: id) else { continue }
                    if b.is_error != true {
                        var a = applied[edit.entryKey] ?? (0, 0, 0)
                        a.added += edit.added; a.removed += edit.removed; a.edits += 1
                        applied[edit.entryKey] = a
                    }
                }
                return
            }
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
                cacheRead: usage.cache_read_input_tokens ?? 0,
                cwd: UsageRecord.projectKey(rec.cwd)
            )
            if byKey[key] == nil { order.append(key) }
            byKey[key] = entry   // last occurrence wins (final output_tokens)
            for b in msg.content ?? [] where b.type == "tool_use" {
                guard let id = b.id, let name = b.name, let counts = Self.editLines(tool: name, input: b.input) else { continue }
                pendingEdits[id] = (key, counts.added, counts.removed)
            }
        }
        return order.compactMap { k -> Entry? in
            guard var e = byKey[k] else { return nil }
            if let a = applied[k] { e.linesAdded = a.added; e.linesRemoved = a.removed; e.edits = a.edits }
            return e
        }
    }

    /// Lines an edit tool call would add/remove. nil for tools that do not write code.
    private static func editLines(tool: String, input: Line.EditInput?) -> (added: Int, removed: Int)? {
        switch tool {
        case "Edit":
            return (CodeActivity.lineCount(input?.new_string), CodeActivity.lineCount(input?.old_string))
        case "MultiEdit":
            var a = 0, r = 0
            for e in input?.edits ?? [] { a += CodeActivity.lineCount(e.new_string); r += CodeActivity.lineCount(e.old_string) }
            return (a, r)
        case "Write":
            return (CodeActivity.lineCount(input?.content), 0)
        case "NotebookEdit":
            return (CodeActivity.lineCount(input?.new_source), 0)
        default:
            return nil
        }
    }

    public func codeActivity(interval: DateInterval, credentials: Credentials) async throws -> [CodeActivity] {
        let files = roots.flatMap { root in LogFiles.enumerateIncludingHidden(root) { $0.pathExtension == "jsonl" } }
        let entries = await cache.entries(for: files, parse: Self.parseFile)
        return Self.aggregateCode(entries)
    }

    public static func aggregateCode(_ entries: [Entry], resolver: ProjectResolver = ProjectResolver()) -> [CodeActivity] {
        var unique: [String: Entry] = [:]
        for e in entries where (e.edits ?? 0) > 0 {
            if let existing = unique[e.key], (existing.edits ?? 0) >= (e.edits ?? 0) { continue }
            unique[e.key] = e
        }
        let projects = resolver.resolve(unique.values.map(\.cwd))
        var out: [String: CodeActivity] = [:]
        for e in unique.values {
            let day = DayKey.startOfDay(e.timestamp)
            let project = e.cwd.flatMap { projects[$0] }
            let item = CodeActivity(provider: .claudeCode, day: day, kind: "edits", project: project,
                                    linesAdded: e.linesAdded ?? 0, linesRemoved: e.linesRemoved ?? 0, edits: e.edits ?? 0)
            if var existing = out[item.id] { existing.merge(item); out[item.id] = existing } else { out[item.id] = item }
        }
        return out.values.sorted { ($0.day, $0.project ?? "") < ($1.day, $1.project ?? "") }
    }

    /// Global dedupe (same response can appear in an audit log and a nested transcript),
    /// then roll up to (day, model) with estimated cost.
    public static func aggregate(_ entries: [Entry], resolver: ProjectResolver = ProjectResolver()) -> [UsageRecord] {
        var unique: [String: Entry] = [:]
        for e in entries {
            if let existing = unique[e.key], existing.output >= e.output { continue }
            unique[e.key] = e
        }
        let projects = resolver.resolve(unique.values.map(\.cwd))
        var records: [String: UsageRecord] = [:]
        var oneHourWrites: [String: Int] = [:]
        for e in unique.values {
            let day = DayKey.startOfDay(e.timestamp)
            let project = e.cwd.flatMap { projects[$0] }
            let rid = "\(DayKey.string(for: day))|\(e.model)|\(project ?? "")"
            var r = records[rid] ?? UsageRecord(provider: .claudeCode, day: day, model: e.model, project: project)
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
        .sorted { ($0.day, $0.model, $0.project ?? "") < ($1.day, $1.model, $1.project ?? "") }
    }
}
