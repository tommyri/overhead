import Foundation
import Testing
@testable import OverheadCore

@Suite struct PlanDetectionTests {
    @Test func cursorTiers() {
        #expect(PlanPrices.cursor(membershipType: "pro_plus")?.name == "Cursor Pro+")
        #expect(PlanPrices.cursor(membershipType: "pro_plus")?.monthly == 60)
        #expect(PlanPrices.cursor(membershipType: "pro_plus", yearly: true)?.monthly == 48)
        #expect(PlanPrices.cursor(membershipType: "ultra")?.monthly == 200)
        #expect(PlanPrices.cursor(membershipType: "mystery") == nil)
    }

    @Test func chatGPTTiers() {
        #expect(PlanPrices.chatGPT(planType: "plus")?.monthly == 20)
        #expect(PlanPrices.chatGPT(planType: "pro")?.monthly == 200)
        #expect(PlanPrices.chatGPT(planType: "prolite")?.name == "ChatGPT Pro 100")
        #expect(PlanPrices.chatGPT(planType: "prolite")?.monthly == 100)
        #expect(PlanPrices.chatGPT(planType: "promax")?.monthly == 500)
        #expect(PlanPrices.chatGPT(planType: "team")?.name == "ChatGPT Business")
        #expect(PlanPrices.chatGPT(planType: "business")?.name == "ChatGPT Enterprise")
    }

    @Test func claudeTeamPremiumSeatFromRateLimitTier() {
        let t = PlanPrices.claude(organizationType: "claude_team", seatTier: "team_tier_1", billingType: "stripe_subscription", rateLimitTier: "default_claude_max_5x")
        #expect(t?.name == "Claude Team (Premium seat)")
        #expect(t?.monthly == 125)
        #expect(PlanPrices.claude(organizationType: "claude_team", seatTier: "team_standard", billingType: nil, rateLimitTier: nil)?.monthly == 25)
        #expect(PlanPrices.claude(organizationType: "claude_max", seatTier: nil, billingType: nil, rateLimitTier: "default_claude_max_5x")?.name == "Claude Max 5x")
        #expect(PlanPrices.claude(organizationType: "claude_pro", seatTier: nil, billingType: nil, rateLimitTier: "default_claude_ai")?.monthly == 20)
        #expect(PlanPrices.claude(organizationType: nil, seatTier: nil, billingType: nil, rateLimitTier: "default_claude_max_20x")?.name == "Claude Max 20x")
    }

    @Test func claudeCodeReadsAccountConfig() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"oauthAccount":{"organizationType":"claude_team","seatTier":"team_tier_1","userRateLimitTier":"default_claude_max_5x","emailAddress":"x@y.z"}}"#.utf8).write(to: url)
        let s = try #require(ClaudeCodeProvider.detectPlan(configURL: url))
        #expect(s.name == "Claude Team (Premium seat)")
        #expect(s.monthlyFeeUSD == 125)
        #expect(s.source == "~/.claude.json")
        #expect(ClaudeCodeProvider.detectPlan(configURL: url.appendingPathExtension("missing")) == nil)
    }

    @Test func codexPlanStatusCarriesDetectedTier() async throws {
        let fixtures = Bundle.module.url(forResource: "codex-new", withExtension: "jsonl", subdirectory: "Fixtures")!.deletingLastPathComponent()
        let p = CodexProvider(roots: [fixtures], cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("codex-plan-test-\(UUID().uuidString)"))
        let ps = try #require(try await p.planStatus(credentials: [:]))
        #expect(ps.planName == "ChatGPT Plus")
        #expect(ps.suggestedPlan?.monthlyFeeUSD == 20)
        #expect(ps.suggestedPlan?.source == "Codex logs")
        #expect(ps.windows.count == 2)
    }

    @Test func billingPlanDecodesLegacyJSONWithoutNewFields() throws {
        let plan = try JSONDecoder().decode(BillingPlan.self, from: Data(#"{"kind":"subscription","monthlyFeeUSD":60}"#.utf8))
        #expect(plan.monthlyFeeUSD == 60)
        #expect(plan.autoDetected == false)
        #expect(plan.planName == nil)
    }
}
