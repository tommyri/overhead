import Foundation

/// OpenAI Usage + Costs API (organization scope, Admin key).
/// Docs: https://developers.openai.com/api/reference/administration/overview
public struct OpenAIAdminProvider: UsageProvider {
    public let id: ProviderID = .openAIAPI
    public static let keyField = "openai.adminKey"

    public var credentialFields: [CredentialField] {
        [CredentialField(key: Self.keyField, label: "Admin API key", placeholder: "sk-admin-…")]
    }

    public var baseURL: String
    private let http: HTTP

    public init(baseURL: String = "https://api.openai.com", http: HTTP = HTTP()) {
        self.baseURL = baseURL
        self.http = http
    }

    // MARK: Wire types

    struct Page<R: Decodable>: Decodable {
        let data: [Bucket]
        let has_more: Bool?
        let next_page: String?
        struct Bucket: Decodable {
            let start_time: Double
            let results: [R]
        }
    }

    struct CompletionsResult: Decodable {
        let input_tokens: Int?
        let input_cached_tokens: Int?
        let input_cache_write_tokens: Int?
        let input_cache_write_12h_tokens: Int?
        let output_tokens: Int?
        let num_model_requests: Int?
        let model: String?
    }

    struct CostResult: Decodable {
        let amount: Amount?
        let line_item: String?
        struct Amount: Decodable {
            let value: Double?
            let currency: String?
        }
    }

    // MARK: Fetch

    public func fetch(interval: DateInterval, credentials: Credentials) async throws -> [UsageRecord] {
        guard let key = credentials[Self.keyField], !key.isEmpty else { throw ProviderError.notConfigured }
        let headers = ["Authorization": "Bearer \(key)"]

        var records: [String: UsageRecord] = [:]
        func slot(_ day: Date, _ model: String) -> UsageRecord {
            records["\(DayKey.string(for: day))|\(model)"] ?? UsageRecord(provider: .openAIAPI, day: day, model: model)
        }
        func store(_ r: UsageRecord) { records["\(r.dayKey)|\(r.model)"] = r }

        // Usage: ≤31 daily buckets per request.
        for chunk in DayKey.chunks(interval, maxDays: 31) {
            var page: String? = nil
            repeat {
                let url = HTTP.url("\(baseURL)/v1/organization/usage/completions", query: [
                    "start_time": String(Int(chunk.start.timeIntervalSince1970)),
                    "end_time": String(Int(chunk.end.timeIntervalSince1970)),
                    "bucket_width": "1d",
                    "limit": "31",
                    "group_by[]": "model",
                    "page": page,
                ])
                let res = try await http.json(Page<CompletionsResult>.self, .init(url: url, headers: headers))
                for bucket in res.data {
                    let day = DayKey.localDay(fromUTC: Date(timeIntervalSince1970: bucket.start_time))
                    for row in bucket.results {
                        var r = slot(day, row.model ?? "")
                        let total = row.input_tokens ?? 0
                        let cached = min(row.input_cached_tokens ?? 0, total)
                        let writes = min((row.input_cache_write_tokens ?? 0) + (row.input_cache_write_12h_tokens ?? 0), total - cached)
                        r.inputTokens += total - cached - writes
                        r.cacheReadTokens += cached
                        r.cacheWriteTokens += writes
                        r.outputTokens += row.output_tokens ?? 0
                        r.requests += row.num_model_requests ?? 0
                        store(r)
                    }
                }
                page = (res.has_more ?? false) ? res.next_page : nil
            } while page != nil
        }

        // Costs: up to 180 daily buckets per request, line items carry "<model>, <token type>".
        var page: String? = nil
        repeat {
            let url = HTTP.url("\(baseURL)/v1/organization/costs", query: [
                "start_time": String(Int(interval.start.timeIntervalSince1970)),
                "end_time": String(Int(interval.end.timeIntervalSince1970)),
                "bucket_width": "1d",
                "limit": "180",
                "group_by[]": "line_item",
                "page": page,
            ])
            let res = try await http.json(Page<CostResult>.self, .init(url: url, headers: headers))
            for bucket in res.data {
                let day = DayKey.localDay(fromUTC: Date(timeIntervalSince1970: bucket.start_time))
                for row in bucket.results {
                    guard let value = row.amount?.value else { continue }
                    let model = Self.model(fromLineItem: row.line_item)
                    var r = slot(day, model)
                    r.cost = .sum(r.cost, .reported(value))
                    store(r)
                }
            }
            page = (res.has_more ?? false) ? res.next_page : nil
        } while page != nil

        return records.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    /// "gpt-5, input_tokens" → "gpt-5". Unknown shapes are kept whole so nothing is lost.
    static func model(fromLineItem item: String?) -> String {
        guard let item, !item.isEmpty else { return "" }
        if let comma = item.firstIndex(of: ",") {
            return item[..<comma].trimmingCharacters(in: .whitespaces)
        }
        return item
    }
}
