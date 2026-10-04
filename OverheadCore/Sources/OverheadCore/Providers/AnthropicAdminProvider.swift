import Foundation

/// Anthropic Admin API: organization-wide token usage grouped by model, plus billed cost.
/// Docs: https://platform.claude.com/docs/en/manage-claude/usage-cost-api
public struct AnthropicAdminProvider: UsageProvider {
    public let id: ProviderID = .anthropicAPI
    public static let keyField = "anthropic.adminKey"

    public var credentialFields: [CredentialField] {
        [CredentialField(key: Self.keyField, label: "Admin API key", placeholder: "sk-ant-admin01-…")]
    }

    public var baseURL: String
    private let http: HTTP

    public init(baseURL: String = "https://api.anthropic.com", http: HTTP = HTTP()) {
        self.baseURL = baseURL
        self.http = http
    }

    // MARK: Wire types

    struct UsagePage: Decodable {
        let data: [Bucket]
        let has_more: Bool?
        let next_page: String?
        struct Bucket: Decodable {
            let starting_at: String
            let results: [Result]
        }
        struct Result: Decodable {
            let uncached_input_tokens: Int?
            let cache_creation: CacheCreation?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
            let model: String?
            struct CacheCreation: Decodable {
                let ephemeral_1h_input_tokens: Int?
                let ephemeral_5m_input_tokens: Int?
            }
        }
    }

    struct CostPage: Decodable {
        let data: [Bucket]
        let has_more: Bool?
        let next_page: String?
        struct Bucket: Decodable {
            let starting_at: String
            let results: [Result]
        }
        struct Result: Decodable {
            let amount: String          // decimal string, in cents
            let currency: String?
            let cost_type: String?
            let description: String?
            let model: String?
        }
    }

    // MARK: Fetch

    public func fetch(interval: DateInterval, credentials: Credentials) async throws -> [UsageRecord] {
        guard let key = credentials[Self.keyField], !key.isEmpty else { throw ProviderError.notConfigured }
        let headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]

        var records: [String: UsageRecord] = [:]
        func slot(_ day: Date, _ model: String) -> UsageRecord {
            records["\(DayKey.string(for: day))|\(model)"] ?? UsageRecord(provider: .anthropicAPI, day: day, model: model)
        }
        func store(_ r: UsageRecord) { records["\(r.dayKey)|\(r.model)"] = r }

        for chunk in DayKey.chunks(interval, maxDays: 31) {
            // Usage by model.
            var page: String? = nil
            repeat {
                let url = HTTP.url("\(baseURL)/v1/organizations/usage_report/messages", query: [
                    "starting_at": DayKey.rfc3339(chunk.start),
                    "ending_at": DayKey.rfc3339(chunk.end),
                    "bucket_width": "1d",
                    "limit": "31",
                    "group_by[]": "model",
                    "page": page,
                ])
                let res = try await http.json(UsagePage.self, .init(url: url, headers: headers))
                for bucket in res.data {
                    guard let day = DayKey.localDay(fromISOPrefix: bucket.starting_at) else { continue }
                    for row in bucket.results {
                        var r = slot(day, row.model ?? "")
                        r.inputTokens += row.uncached_input_tokens ?? 0
                        r.cacheWriteTokens += (row.cache_creation?.ephemeral_5m_input_tokens ?? 0) + (row.cache_creation?.ephemeral_1h_input_tokens ?? 0)
                        r.cacheReadTokens += row.cache_read_input_tokens ?? 0
                        r.outputTokens += row.output_tokens ?? 0
                        store(r)
                    }
                }
                page = (res.has_more ?? false) ? res.next_page : nil
            } while page != nil

            // Billed cost, grouped by description so each row carries its model.
            page = nil
            repeat {
                let url = HTTP.url("\(baseURL)/v1/organizations/cost_report", query: [
                    "starting_at": DayKey.rfc3339(chunk.start),
                    "ending_at": DayKey.rfc3339(chunk.end),
                    "bucket_width": "1d",
                    "limit": "31",
                    "group_by[]": "description",
                    "page": page,
                ])
                let res = try await http.json(CostPage.self, .init(url: url, headers: headers))
                for bucket in res.data {
                    guard let day = DayKey.localDay(fromISOPrefix: bucket.starting_at) else { continue }
                    for row in bucket.results {
                        guard let cents = Double(row.amount) else { continue }
                        // Non-token line items (web search, code execution) get their own row.
                        let model = row.model ?? row.cost_type ?? row.description ?? ""
                        var r = slot(day, model)
                        r.cost = .sum(r.cost, .reported(cents / 100))
                        store(r)
                    }
                }
                page = (res.has_more ?? false) ? res.next_page : nil
            } while page != nil
        }

        // Rows that have tokens but no cost line (e.g. priority tier is excluded from the
        // cost report) fall back to a list-price estimate so the dashboard is not blank.
        return records.values.map { r in
            var r = r
            if case .unknown = r.cost, r.totalTokens > 0,
               let est = PriceTable.estimate(model: r.model, input: r.inputTokens, output: r.outputTokens,
                                             cacheRead: r.cacheReadTokens, cacheWrite: r.cacheWriteTokens) {
                r.cost = .estimated(est)
            }
            return r
        }
        .sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }
}
