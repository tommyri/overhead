import Foundation

/// xAI Management API billing usage, aggregated per day and description (model).
/// Docs: https://docs.x.ai/developers/rest-api-reference/management/billing
public struct XAIProvider: UsageProvider {
    public let id: ProviderID = .xai
    public static let keyField = "xai.managementKey"
    public static let teamField = "xai.teamId"

    public var credentialFields: [CredentialField] {
        [
            CredentialField(key: Self.keyField, label: "Management API key", placeholder: "xai-…"),
            CredentialField(key: Self.teamField, label: "Team ID", placeholder: "from console.x.ai → Team settings", isPlainText: true),
        ]
    }

    public var baseURL: String
    private let http: HTTP

    public init(baseURL: String = "https://management-api.x.ai", http: HTTP = HTTP()) {
        self.baseURL = baseURL
        self.http = http
    }

    struct UsageResponse: Decodable {
        let timeSeries: [Series]?
        let limitReached: Bool?
        struct Series: Decodable {
            let group: [String]?
            let groupLabels: [String]?
            let dataPoints: [Point]?
            struct Point: Decodable {
                let timestamp: String
                let values: [Double]?
            }
        }
    }

    public func fetch(interval: DateInterval, credentials: Credentials) async throws -> [UsageRecord] {
        guard let key = credentials[Self.keyField], !key.isEmpty,
              let team = credentials[Self.teamField]?.trimmingCharacters(in: .whitespaces), !team.isEmpty
        else { throw ProviderError.notConfigured }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let body: [String: Any] = [
            "analyticsRequest": [
                "timeRange": [
                    "startTime": fmt.string(from: interval.start),
                    "endTime": fmt.string(from: interval.end),
                    "timezone": "Etc/GMT",
                ],
                "timeUnit": "TIME_UNIT_DAY",
                "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]],
                "groupBy": ["description"],
                "filters": [],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = URL(string: "\(baseURL)/v1/billing/teams/\(team)/usage")!
        let res = try await http.json(UsageResponse.self, .init(url: url, method: "POST", headers: ["Authorization": "Bearer \(key)"], body: data))

        var records: [String: UsageRecord] = [:]
        for series in res.timeSeries ?? [] {
            let label = series.groupLabels?.first ?? series.group?.first ?? ""
            let model = Self.model(fromDescription: label)
            for point in series.dataPoints ?? [] {
                guard let usd = point.values?.first, usd != 0,
                      let day = DayKey.localDay(fromISOPrefix: point.timestamp) else { continue }
                let rid = "\(DayKey.string(for: day))|\(model)"
                var r = records[rid] ?? UsageRecord(provider: .xai, day: day, model: model)
                r.cost = .sum(r.cost, .reported(usd))
                records[rid] = r
            }
        }
        return records.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    /// "Chat grok-4-0709" → "grok-4-0709"; keeps other labels (image, search) intact.
    static func model(fromDescription d: String) -> String {
        let trimmed = d.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("chat ") { return String(trimmed.dropFirst(5)) }
        return trimmed
    }
}
