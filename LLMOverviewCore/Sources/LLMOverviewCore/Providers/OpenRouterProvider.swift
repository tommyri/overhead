import Foundation

/// OpenRouter. With a regular key we only get the key's rolling usage totals (today's spend);
/// a Management key unlocks `/activity`, which gives 30 days of per-day, per-model history.
/// Docs: https://openrouter.ai/docs/api-reference/limits
public struct OpenRouterProvider: UsageProvider {
    public let id: ProviderID = .openRouter
    public static let keyField = "openrouter.apiKey"
    public static let managementField = "openrouter.managementKey"

    public var credentialFields: [CredentialField] {
        [
            CredentialField(key: Self.keyField, label: "API key", placeholder: "sk-or-v1-…"),
            CredentialField(key: Self.managementField, label: "Management key (optional)", placeholder: "enables 30-day per-model history", isOptional: true),
        ]
    }

    public var baseURL: String
    private let http: HTTP

    public init(baseURL: String = "https://openrouter.ai/api/v1", http: HTTP = HTTP()) {
        self.baseURL = baseURL
        self.http = http
    }

    struct KeyResponse: Decodable {
        let data: KeyData
        struct KeyData: Decodable {
            let usage: Double?
            let usage_daily: Double?
            let usage_weekly: Double?
            let usage_monthly: Double?
            let limit: Double?
            let limit_remaining: Double?
        }
    }

    struct ActivityResponse: Decodable {
        let data: [Row]
        struct Row: Decodable {
            let date: String
            let model: String?
            let usage: Double?
            let requests: Int?
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let reasoning_tokens: Int?
        }
    }

    public func fetch(interval: DateInterval, credentials: Credentials) async throws -> [UsageRecord] {
        guard let key = credentials[Self.keyField], !key.isEmpty else { throw ProviderError.notConfigured }

        if let mgmt = credentials[Self.managementField], !mgmt.isEmpty {
            let url = URL(string: "\(baseURL)/activity")!
            let res = try await http.json(ActivityResponse.self, .init(url: url, headers: ["Authorization": "Bearer \(mgmt)"]))
            var records: [String: UsageRecord] = [:]
            for row in res.data {
                guard let day = DayKey.localDay(fromISOPrefix: row.date) else { continue }
                let model = row.model ?? ""
                let rid = "\(DayKey.string(for: day))|\(model)"
                var r = records[rid] ?? UsageRecord(provider: .openRouter, day: day, model: model)
                r.inputTokens += row.prompt_tokens ?? 0
                r.outputTokens += row.completion_tokens ?? 0
                r.requests += row.requests ?? 0
                r.cost = .sum(r.cost, .reported(row.usage ?? 0))
                records[rid] = r
            }
            // /activity covers completed UTC days only; add today from the key endpoint.
            if let today = try? await todayRecord(key: key) {
                let rid = "\(today.dayKey)|"
                if records[rid] == nil { records[rid] = today }
            }
            return records.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
        }

        return [try await todayRecord(key: key)]
    }

    private func todayRecord(key: String) async throws -> UsageRecord {
        let url = URL(string: "\(baseURL)/key")!
        let res = try await http.json(KeyResponse.self, .init(url: url, headers: ["Authorization": "Bearer \(key)"]))
        return UsageRecord(provider: .openRouter, day: DayKey.startOfDay(Date()), model: "",
                           cost: .reported(res.data.usage_daily ?? 0))
    }
}
