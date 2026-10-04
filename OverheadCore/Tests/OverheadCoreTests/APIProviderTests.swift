import Foundation
import Testing
@testable import OverheadCore

@Suite struct APIProviderTests {

    @Test func anthropicMergesUsageAndCost() async throws {
        let (http, mock) = mockHTTP([
            .init(pathSuffix: "/usage_report/messages", status: 200, body: fixtureData("anthropic-usage")),
            .init(pathSuffix: "/cost_report", status: 200, body: fixtureData("anthropic-cost")),
        ])
        let p = AnthropicAdminProvider(http: http)
        let records = try await p.fetch(interval: octoberWindow(), credentials: [AnthropicAdminProvider.keyField: "k"])
        let opus = try #require(records.first { $0.model == "claude-opus-5" })
        #expect(opus.inputTokens == 1500)
        #expect(opus.cacheWriteTokens == 150)
        #expect(opus.cacheReadTokens == 200)
        #expect(opus.cost == .reported(1.2378912))
        #expect(DayKey.string(for: opus.day) == "2026-10-01")
        let search = try #require(records.first { $0.model == "web_search" })
        #expect(search.cost == .reported(0.5))
        #expect(mock.requests.allSatisfy { $0.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01" })
    }

    @Test func openAINormalizesCacheBucketsAndParsesLineItems() async throws {
        let (http, _) = mockHTTP([
            .init(pathSuffix: "/usage/completions", status: 200, body: fixtureData("openai-completions")),
            .init(pathSuffix: "/organization/costs", status: 200, body: fixtureData("openai-costs")),
        ])
        let p = OpenAIAdminProvider(http: http)
        let records = try await p.fetch(interval: octoberWindow(), credentials: [OpenAIAdminProvider.keyField: "k"])
        let r = try #require(records.first { $0.model == "gpt-5" })
        #expect(r.inputTokens == 500)
        #expect(r.cacheReadTokens == 400)
        #expect(r.cacheWriteTokens == 100)
        #expect(r.outputTokens == 500)
        #expect(r.requests == 5)
        #expect(r.cost == .reported(0.1))
        #expect(DayKey.string(for: r.day) == "2026-10-01")
    }

    @Test func openAIUnauthorizedSurfacesAsProviderError() async {
        let (http, _) = mockHTTP([
            .init(pathSuffix: "/usage/completions", status: 401, body: Data(#"{"error":{"message":"Invalid key"}}"#.utf8)),
        ])
        let p = OpenAIAdminProvider(http: http)
        await #expect(throws: ProviderError.self) {
            _ = try await p.fetch(interval: octoberWindow(), credentials: [OpenAIAdminProvider.keyField: "bad"])
        }
    }

    @Test func cursorAdminSumsEventsPerDayAndModel() async throws {
        let (http, mock) = mockHTTP([
            .init(pathSuffix: "/teams/filtered-usage-events", status: 200, body: fixtureData("cursor-events")),
        ])
        let p = CursorProvider(http: http)
        let records = try await p.fetch(interval: octoberWindow(), credentials: [CursorProvider.adminKeyField: "key_x"])
        let r = try #require(records.first)
        #expect(r.model == "claude-4.5-sonnet")
        #expect(r.requests == 2)
        #expect(r.inputTokens == 136)
        #expect(r.cacheReadTokens == 11964)
        #expect(abs((r.cost.value ?? 0) - 0.2136232) < 1e-9)
        let auth = try #require(mock.requests.first?.value(forHTTPHeaderField: "Authorization"))
        #expect(auth == "Basic " + Data("key_x:".utf8).base64EncodedString())
    }

    @Test func xaiReadsTimeSeriesAndStripsChatPrefix() async throws {
        let (http, _) = mockHTTP([
            .init(pathSuffix: "/billing/teams/team1/usage", status: 200, body: fixtureData("xai-usage")),
        ])
        let p = XAIProvider(http: http)
        let records = try await p.fetch(interval: octoberWindow(), credentials: [XAIProvider.keyField: "k", XAIProvider.teamField: "team1"])
        #expect(records.count == 1)
        #expect(records[0].model == "grok-4-0709")
        #expect(records[0].cost == .reported(0.75973725))
    }

    @Test func openRouterUsesActivityWithManagementKey() async throws {
        let (http, _) = mockHTTP([
            .init(pathSuffix: "/activity", status: 200, body: fixtureData("openrouter-activity")),
            .init(pathSuffix: "/key", status: 200, body: fixtureData("openrouter-key")),
        ])
        let p = OpenRouterProvider(http: http)
        let records = try await p.fetch(interval: octoberWindow(), credentials: [
            OpenRouterProvider.keyField: "k", OpenRouterProvider.managementField: "m",
        ])
        let gpt = try #require(records.first { $0.model == "openai/gpt-4.1" })
        #expect(gpt.inputTokens == 50 && gpt.outputTokens == 125 && gpt.requests == 5)
        #expect(gpt.cost == .reported(0.015))
        let today = try #require(records.first { $0.model == "" })
        #expect(today.cost == .reported(1.25))
    }

    @Test func openRouterFallsBackToKeyEndpoint() async throws {
        let (http, _) = mockHTTP([.init(pathSuffix: "/key", status: 200, body: fixtureData("openrouter-key"))])
        let p = OpenRouterProvider(http: http)
        let records = try await p.fetch(interval: octoberWindow(), credentials: [OpenRouterProvider.keyField: "k"])
        #expect(records.count == 1)
        #expect(records[0].cost == .reported(1.25))
    }

    @Test func optionalCredentialsDoNotBlockConfiguration() {
        let p = OpenRouterProvider()
        #expect(p.isConfigured([OpenRouterProvider.keyField: "k"]))
        #expect(!p.isConfigured([:]))
    }
}

// MARK: - Cursor personal (dashboard session) mode

private func fakeCursorJWT(expOffset: TimeInterval) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["sub": "auth0|user_42", "exp": Int(Date().timeIntervalSince1970 + expOffset)])
    let b64 = payload.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "eyJhbGciOiJSUzI1NiJ9.\(b64).c2ln"
}

@Suite struct CursorPersonalTests {
    private var session: Credentials { [CursorProvider.sessionField: "user_42::\(fakeCursorJWT(expOffset: 3600))"] }

    @Test func normalizesPastedSessionValues() throws {
        let jwt = fakeCursorJWT(expOffset: 3600)
        let want = "user_42%3A%3A\(jwt)"
        #expect(try CursorProvider.cookieValue(from: "user_42::\(jwt)") == want)
        #expect(try CursorProvider.cookieValue(from: "auth0|user_42::\(jwt)") == want)
        #expect(try CursorProvider.cookieValue(from: "user_42%3A%3A\(jwt)") == want)
        #expect(try CursorProvider.cookieValue(from: "WorkosCursorSessionToken=user_42%3A%3A\(jwt); Path=/") == want)
    }

    @Test func rejectsExpiredOrMalformedSession() {
        #expect(throws: ProviderError.self) {
            _ = try CursorProvider.cookieValue(from: "user_42::\(fakeCursorJWT(expOffset: -10))")
        }
        #expect(throws: ProviderError.self) {
            _ = try CursorProvider.cookieValue(from: "garbage")
        }
    }

    @Test func parsesPersonalEventsLeniently() async throws {
        let (http, mock) = mockHTTP([
            .init(pathSuffix: "/api/dashboard/get-filtered-usage-events", status: 200, body: fixtureData("cursor-personal-events")),
        ])
        let p = CursorProvider(http: http)
        let records = try await p.fetch(interval: octoberWindow(), credentials: session)
        let opus = try #require(records.first { $0.model == "claude-4.6-opus-high-thinking" })
        #expect(opus.outputTokens == 20525)                   // string number decoded
        #expect(opus.cacheReadTokens == 298176)
        #expect(abs((opus.cost.value ?? 0) - 1.2473) < 1e-9)  // chargedCents arrived as a string
        let grok = records.filter { $0.model == "grok-4.7" }
        #expect(grok.count == 2)                               // two different days
        #expect(grok.map(\.requests).reduce(0, +) == 2)

        let req = try #require(mock.requests.first)
        #expect(req.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
        #expect(req.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=user_42%3A%3A") == true)
        let body = try #require(requestBody(req))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["teamId"] as? Int == 0)
        #expect(json["startDate"] is String)                   // epoch ms as string, like the dashboard
    }

    @Test func stopsOnEmptyWindow() async throws {
        let (http, mock) = mockHTTP([
            .init(pathSuffix: "/api/dashboard/get-filtered-usage-events", status: 200, body: Data("{}".utf8)),
        ])
        let p = CursorProvider(http: http)
        let records = try await p.fetch(interval: octoberWindow(), credentials: session)
        #expect(records.isEmpty)
        #expect(mock.requests.count == 1)
    }

    @Test func buildsPlanStatusFromUsageSummary() async throws {
        let (http, mock) = mockHTTP([
            .init(pathSuffix: "/api/usage-summary", status: 200, body: fixtureData("cursor-usage-summary")),
        ])
        let p = CursorProvider(http: http)
        let ps = try #require(try await p.planStatus(credentials: session))
        #expect(ps.planName == "Cursor Pro+")
        let included = try #require(ps.windows.first { $0.title == "Included usage" })
        #expect(included.usedPercent == 42)
        #expect(included.detail == "$25.20 of $60.00 included")
        #expect(included.resetsAt != nil)
        #expect(ps.windows.count == 3)
        #expect(ps.note?.contains("$3.15") == true)
        #expect(mock.requests.first?.value(forHTTPHeaderField: "Cookie")?.contains("user_42%3A%3A") == true)
    }

    @Test func prefersAccountEndpointTierOverSummary() async throws {
        let stripe = Data(#"{"membershipType":"pro","individualMembershipType":"pro_plus","isTeamMember":false,"isYearlyPlan":false,"subscriptionStatus":"active"}"#.utf8)
        let (http, _) = mockHTTP([
            .init(pathSuffix: "/api/usage-summary", status: 200, body: fixtureData("cursor-usage-summary")),
            .init(pathSuffix: "/api/auth/stripe", status: 200, body: stripe),
        ])
        let ps = try #require(try await CursorProvider(http: http).planStatus(credentials: session))
        #expect(ps.planName == "Cursor Pro+")
        #expect(ps.suggestedPlan?.monthlyFeeUSD == 60)
        #expect(ps.suggestedPlan?.source == "cursor.com account")
    }

    @Test func fallsBackToSummaryTierWhenAccountEndpointFails() async throws {
        let (http, _) = mockHTTP([
            .init(pathSuffix: "/api/usage-summary", status: 200, body: fixtureData("cursor-usage-summary")),
            .init(pathSuffix: "/api/auth/stripe", status: 500, body: Data()),
        ])
        let ps = try #require(try await CursorProvider(http: http).planStatus(credentials: session))
        #expect(ps.planName == "Cursor Pro+")   // fixture summary says pro_plus
        #expect(ps.suggestedPlan == nil)        // but it is not allowed to rewrite the billing plan
    }

    @Test func hidesDollarDetailWhenItContradictsThePercent() async throws {
        let body = Data(#"{"membershipType":"pro","individualUsage":{"plan":{"used":2000,"limit":2000,"totalPercentUsed":16,"autoPercentUsed":17,"apiPercentUsed":0}}}"#.utf8)
        let (http, _) = mockHTTP([.init(pathSuffix: "/api/usage-summary", status: 200, body: body)])
        let ps = try #require(try await CursorProvider(http: http).planStatus(credentials: session))
        let included = try #require(ps.windows.first { $0.title == "Included usage" })
        #expect(included.usedPercent == 16)
        #expect(included.detail == nil)
    }

    @Test func isConfiguredWithEitherCredential() {
        let p = CursorProvider()
        #expect(p.isConfigured([CursorProvider.sessionField: "x"]))
        #expect(p.isConfigured([CursorProvider.adminKeyField: "x"]))
        #expect(!p.isConfigured([:]))
    }
}
