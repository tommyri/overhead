import Foundation

/// Cursor. Two ways in:
///
/// 1. **Personal plans (Pro / Pro+ / Ultra)** — the cursor.com dashboard's own JSON endpoints,
///    authenticated with the user's login session (`WorkosCursorSessionToken` cookie). Not an
///    official API, but it is what the dashboard and every third-party Cursor usage tool use.
///    The session can be imported from the Cursor app (user-triggered) or pasted from a browser.
/// 2. **Teams** — the documented Admin API with a team key.
///    Docs: https://cursor.com/docs/account/teams/admin-api
///
/// Both paths return per-request token counts and cents; the personal path also exposes the
/// plan's included-usage budget via `planStatus`.
public struct CursorProvider: UsageProvider {
    public let id: ProviderID = .cursor
    public static let sessionField = "cursor.sessionToken"
    public static let adminKeyField = "cursor.adminKey"

    public var credentialFields: [CredentialField] {
        [
            CredentialField(key: Self.sessionField, label: "Login session (personal plans)",
                            placeholder: "WorkosCursorSessionToken cookie value", isOptional: true),
            CredentialField(key: Self.adminKeyField, label: "Team Admin API key (teams only)",
                            placeholder: "key_…", isOptional: true),
        ]
    }

    public var credentialImports: [CredentialImport] {
        [
            CredentialImport(
                fieldKey: Self.sessionField,
                buttonTitle: "Import from Cursor app",
                explanation: "Reads the session the Cursor app is signed in with from its local state database (read-only). Nothing is sent anywhere except cursor.com.",
                run: { try CursorLocalSession.importSessionToken() }
            ),
        ]
    }

    public func isConfigured(_ credentials: Credentials) -> Bool {
        !(credentials[Self.sessionField] ?? "").isEmpty || !(credentials[Self.adminKeyField] ?? "").isEmpty
    }

    public var dashboardBaseURL: String
    public var adminBaseURL: String
    private let http: HTTP

    public init(dashboardBaseURL: String = "https://cursor.com", adminBaseURL: String = "https://api.cursor.com", http: HTTP? = nil) {
        self.dashboardBaseURL = dashboardBaseURL
        self.adminBaseURL = adminBaseURL
        if let http {
            self.http = http
        } else {
            // Never let a Set-Cookie from the server replace the credential we were given.
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            self.http = HTTP(session: URLSession(configuration: cfg))
        }
    }

    // MARK: Dispatch

    public func fetch(interval: DateInterval, credentials: Credentials) async throws -> [UsageRecord] {
        if let key = credentials[Self.adminKeyField], !key.isEmpty {
            return try await fetchAdmin(interval: interval, key: key)
        }
        if let raw = credentials[Self.sessionField], !raw.isEmpty {
            return try await fetchPersonal(interval: interval, cookie: try Self.cookieValue(from: raw))
        }
        throw ProviderError.notConfigured
    }

    public func planStatus(credentials: Credentials) async throws -> PlanStatus? {
        guard let raw = credentials[Self.sessionField], !raw.isEmpty else { return nil }
        return try await fetchPlanStatus(cookie: try Self.cookieValue(from: raw))
    }

    // MARK: Session cookie

    /// Accepts anything a user is likely to paste and returns `user_x%3A%3A<jwt>`:
    /// "user_x::jwt", "user_x%3A%3Ajwt", "auth0|user_x::jwt", or "WorkosCursorSessionToken=…".
    /// Throws if the embedded JWT is expired (Cursor refreshes it; re-import fixes it).
    static func cookieValue(from raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = s.range(of: "WorkosCursorSessionToken=") { s = String(s[eq.upperBound...]) }
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        s = s.replacingOccurrences(of: "%3A%3A", with: "::").replacingOccurrences(of: "%3a%3a", with: "::")
        guard let sep = s.range(of: "::") else {
            throw ProviderError.other("Session value must look like “user_…::<token>”. Use “Import from Cursor app” or copy the WorkosCursorSessionToken cookie from cursor.com.")
        }
        var userId = String(s[..<sep.lowerBound])
        let jwt = String(s[sep.upperBound...])
        if let pipe = userId.lastIndex(of: "|") { userId = String(userId[userId.index(after: pipe)...]) }
        guard !userId.isEmpty, jwt.split(separator: ".").count == 3 else {
            throw ProviderError.other("Session value is not a valid Cursor token.")
        }
        if let exp = jwtExpiry(jwt), exp.timeIntervalSinceNow < 60 {
            throw ProviderError.unauthorized("Cursor session has expired. Open the Cursor app (it refreshes its sign-in), then import the session again.")
        }
        return "\(userId)%3A%3A\(jwt)"
    }

    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let exp = obj["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = obj["exp"] as? Int { return Date(timeIntervalSince1970: Double(exp)) }
        return nil
    }

    private func dashboardHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": "WorkosCursorSessionToken=\(cookie)",
            "Origin": dashboardBaseURL,           // required by cursor.com's CSRF check on POSTs
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Overhead/0.1 (macOS)",
        ]
    }

    // MARK: Personal: per-request events

    struct PersonalEventsPage: Decodable {
        let totalUsageEventsCount: LenientInt?
        let usageEventsDisplay: [Event]?
        struct Event: Decodable {
            let timestamp: LenientDouble?     // epoch ms, usually a string
            let model: String?
            let kind: String?
            let isTokenBasedCall: Bool?
            let isChargeable: Bool?
            let chargedCents: LenientDouble?
            let cursorTokenFee: LenientDouble?
            let tokenUsage: TokenUsage?
            struct TokenUsage: Decodable {
                let inputTokens: LenientInt?
                let outputTokens: LenientInt?
                let cacheWriteTokens: LenientInt?
                let cacheReadTokens: LenientInt?
                let totalCents: LenientDouble?
            }
        }
    }

    private func fetchPersonal(interval: DateInterval, cookie: String) async throws -> [UsageRecord] {
        let headers = dashboardHeaders(cookie: cookie)
        let url = URL(string: "\(dashboardBaseURL)/api/dashboard/get-filtered-usage-events")!
        var records: [String: UsageRecord] = [:]
        var seen: Set<String> = []

        for chunk in DayKey.chunks(interval, maxDays: 31) {
            let startMs = max(0, Int64(chunk.start.timeIntervalSince1970 * 1000))
            let endMs = Int64(chunk.end.timeIntervalSince1970 * 1000) - 1
            var page = 1
            var received = 0
            var total = Int.max
            while received < total && page <= 100 {
                let body: [String: Any] = [
                    "teamId": 0,
                    "startDate": String(startMs),
                    "endDate": String(endMs),
                    "page": page,
                    "pageSize": 500,
                ]
                let data = try JSONSerialization.data(withJSONObject: body)
                let res = try await http.json(PersonalEventsPage.self, .init(url: url, method: "POST", headers: headers, body: data))
                total = res.totalUsageEventsCount.v ?? 0
                guard let events = res.usageEventsDisplay, !events.isEmpty else { break }
                received += events.count
                for ev in events {
                    guard let ms = ev.timestamp.v else { continue }
                    let tu = ev.tokenUsage
                    // No stable event id; a newest-first page boundary can shift while we page.
                    let fingerprint = "\(Int64(ms))|\(ev.model ?? "")|\(tu?.inputTokens.v ?? 0)|\(tu?.outputTokens.v ?? 0)|\(ev.chargedCents.v ?? 0)"
                    guard seen.insert(fingerprint).inserted else { continue }

                    let day = DayKey.startOfDay(Date(timeIntervalSince1970: ms / 1000))
                    let model = ev.model ?? ""
                    let rid = "\(DayKey.string(for: day))|\(model)"
                    var r = records[rid] ?? UsageRecord(provider: .cursor, day: day, model: model)
                    r.inputTokens += tu?.inputTokens.v ?? 0
                    r.outputTokens += tu?.outputTokens.v ?? 0
                    r.cacheWriteTokens += tu?.cacheWriteTokens.v ?? 0
                    r.cacheReadTokens += tu?.cacheReadTokens.v ?? 0
                    r.requests += 1
                    // chargedCents = what the plan deducts (included budget or on-demand), incl. token fee.
                    let cents = ev.chargedCents.v ?? tu?.totalCents.v ?? 0
                    r.cost = .sum(r.cost, .reported(cents / 100))
                    records[rid] = r
                }
                page += 1
            }
        }
        return records.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    // MARK: Personal: plan budget

    struct UsageSummary: Decodable {
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let membershipType: String?
        let isUnlimited: Bool?
        let individualUsage: Individual?
        struct Individual: Decodable {
            let plan: Plan?
            let onDemand: OnDemand?
            struct Plan: Decodable {
                let enabled: Bool?
                let used: LenientInt?
                let limit: LenientInt?
                let remaining: LenientInt?
                let autoPercentUsed: LenientDouble?
                let apiPercentUsed: LenientDouble?
                let totalPercentUsed: LenientDouble?
            }
            struct OnDemand: Decodable {
                let enabled: Bool?
                let used: LenientInt?
                let limit: LenientInt?
            }
        }
    }

    struct StripeProfile: Decodable {
        let membershipType: String?
        let individualMembershipType: String?
        let teamMembershipType: String?
        let isTeamMember: Bool?
        let isYearlyPlan: Bool?
        let subscriptionStatus: String?
    }

    private func fetchPlanStatus(cookie: String) async throws -> PlanStatus? {
        var headers = dashboardHeaders(cookie: cookie)
        headers["Origin"] = nil
        headers["Content-Type"] = nil
        let summary = try await http.json(UsageSummary.self, .init(url: URL(string: "\(dashboardBaseURL)/api/usage-summary")!, headers: headers))
        // The account endpoint distinguishes Pro+ from Pro and knows about annual billing;
        // the usage summary alone reports "pro" for both. Optional: fall back if it fails.
        let profile = try? await http.json(StripeProfile.self, .init(url: URL(string: "\(dashboardBaseURL)/api/auth/stripe")!, headers: headers))
        return Self.planStatus(from: summary, profile: profile)
    }

    static func planStatus(from s: UsageSummary, profile: StripeProfile? = nil) -> PlanStatus? {
        guard let plan = s.individualUsage?.plan else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let cycleEnd = s.billingCycleEnd.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
        let cycleStart = s.billingCycleStart.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
        func usd(_ cents: Int?) -> String? { cents.map { String(format: "$%.2f", Double($0) / 100) } }

        var windows: [PlanStatus.Window] = []
        if let pct = plan.totalPercentUsed.v {
            // The dashboard's cents fields and its headline percentage are known to disagree
            // on some plans; only show the dollar detail when they tell the same story.
            var detail: String? = nil
            if let usedC = plan.used.v, let limitC = plan.limit.v, limitC > 0,
               abs(Double(usedC) / Double(limitC) * 100 - pct) <= 1.5,
               let used = usd(usedC), let limit = usd(limitC) {
                detail = "\(used) of \(limit) included"
            }
            windows.append(.init(title: "Included usage", usedPercent: pct, detail: detail, resetsAt: cycleEnd, periodStart: cycleStart))
        }
        if let pct = plan.autoPercentUsed.v, plan.apiPercentUsed.v != nil {
            windows.append(.init(title: "Cursor models (Auto)", usedPercent: pct, resetsAt: nil))
        }
        if let pct = plan.apiPercentUsed.v, plan.autoPercentUsed.v != nil {
            windows.append(.init(title: "Other models", usedPercent: pct, resetsAt: nil))
        }
        var note: String? = nil
        if let od = s.individualUsage?.onDemand, od.enabled == true, let used = usd(od.used.v) {
            note = "On-demand (beyond included): \(used)" + (usd(od.limit.v).map { " of \($0) limit" } ?? "") + "."
        }
        let membership = profile?.individualMembershipType ?? profile?.membershipType ?? s.membershipType
        let tier = membership.flatMap { PlanPrices.cursor(membershipType: $0, yearly: profile?.isYearlyPlan ?? false) }
        let name = tier?.name ?? membership.map { "Cursor \($0)" }
        // The summary alone cannot tell Pro+ from Pro, so only the account endpoint is
        // authoritative enough to (re)write the detected plan.
        let suggestion: PlanStatus.SuggestedPlan? = (profile != nil) ? name.map {
            PlanStatus.SuggestedPlan(name: $0, monthlyFeeUSD: tier?.monthly, source: "cursor.com account")
        } : nil
        return PlanStatus(planName: name, observedAt: Date(), windows: windows, note: note, suggestedPlan: suggestion)
    }

    // MARK: Teams: Admin API

    struct AdminEventsPage: Decodable {
        let usageEvents: [Event]
        let pagination: Pagination?
        struct Pagination: Decodable { let hasNextPage: Bool? }
        struct Event: Decodable {
            let timestamp: String?        // epoch ms as a string
            let model: String?
            let chargedCents: Double?
            let tokenUsage: TokenUsage?
            struct TokenUsage: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?
                let cacheWriteTokens: Int?
                let cacheReadTokens: Int?
                let totalCents: Double?
            }
        }
    }

    private func fetchAdmin(interval: DateInterval, key: String) async throws -> [UsageRecord] {
        let basic = Data("\(key):".utf8).base64EncodedString()
        let headers = ["Authorization": "Basic \(basic)", "Content-Type": "application/json"]
        let url = URL(string: "\(adminBaseURL)/teams/filtered-usage-events")!

        var records: [String: UsageRecord] = [:]
        for chunk in DayKey.chunks(interval, maxDays: 30) {
            var page = 1
            var hasNext = true
            while hasNext && page <= 200 {
                let body: [String: Any] = [
                    "startDate": Int(chunk.start.timeIntervalSince1970 * 1000),
                    "endDate": Int(chunk.end.timeIntervalSince1970 * 1000),
                    "page": page,
                    "pageSize": 500,
                ]
                let data = try JSONSerialization.data(withJSONObject: body)
                let res = try await http.json(AdminEventsPage.self, .init(url: url, method: "POST", headers: headers, body: data))
                for ev in res.usageEvents {
                    guard let tsString = ev.timestamp, let ms = Double(tsString) else { continue }
                    let day = DayKey.startOfDay(Date(timeIntervalSince1970: ms / 1000))
                    let model = ev.model ?? ""
                    let rid = "\(DayKey.string(for: day))|\(model)"
                    var r = records[rid] ?? UsageRecord(provider: .cursor, day: day, model: model)
                    r.inputTokens += ev.tokenUsage?.inputTokens ?? 0
                    r.outputTokens += ev.tokenUsage?.outputTokens ?? 0
                    r.cacheWriteTokens += ev.tokenUsage?.cacheWriteTokens ?? 0
                    r.cacheReadTokens += ev.tokenUsage?.cacheReadTokens ?? 0
                    r.requests += 1
                    r.cost = .sum(r.cost, .reported((ev.chargedCents ?? 0) / 100))
                    records[rid] = r
                }
                hasNext = res.pagination?.hasNextPage ?? false
                page += 1
            }
        }
        return records.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }
}
