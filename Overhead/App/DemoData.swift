import Foundation
import OverheadCore

/// Synthetic data for screenshots and demos. Enabled with the launch argument
/// `-demoData YES`; in that mode nothing is read from disk, fetched, or persisted.
enum DemoData {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demoData") }

    static let providers: [ProviderID] = [.claudeCode, .codexCLI, .cursor, .anthropicAPI]

    /// Thirty days of plausible usage with a weekly rhythm and a couple of busy days.
    static func records(now: Date = Date(), calendar: Calendar = .current) -> [UsageRecord] {
        var rng = SeededGenerator(seed: 20261004)
        let today = calendar.startOfDay(for: now)
        var out: [UsageRecord] = []

        struct Model { let provider: ProviderID; let id: String; let share: Double; let inPerReq: Int; let outPerReq: Int; let cacheRatio: Double; let centsPerReq: Double? }
        // Per-request shapes modelled on real agentic-coding traffic: small fresh input, large
        // cached context re-read every turn, and (for Cursor) the cents the plan deducts.
        let models: [Model] = [
            Model(provider: .claudeCode,   id: "claude-opus-5-5",   share: 0.6,  inPerReq: 110,  outPerReq: 2400, cacheRatio: 2600, centsPerReq: nil),
            Model(provider: .claudeCode,   id: "claude-sonnet-5-5", share: 0.4,  inPerReq: 90,   outPerReq: 1600, cacheRatio: 1900, centsPerReq: nil),
            Model(provider: .codexCLI,     id: "gpt-6-astra",       share: 0.7,  inPerReq: 4200, outPerReq: 320,  cacheRatio: 28,   centsPerReq: nil),
            Model(provider: .codexCLI,     id: "gpt-5.6-sol",       share: 0.3,  inPerReq: 3000, outPerReq: 280,  cacheRatio: 30,   centsPerReq: nil),
            Model(provider: .cursor,       id: "claude-4.6-opus-high-thinking", share: 0.35, inPerReq: 40, outPerReq: 2200, cacheRatio: 35, centsPerReq: 22),
            Model(provider: .cursor,       id: "grok-4.7",          share: 0.35, inPerReq: 30,   outPerReq: 900,  cacheRatio: 30,   centsPerReq: 6),
            Model(provider: .cursor,       id: "composer-2.5-fast", share: 0.3,  inPerReq: 25,   outPerReq: 600,  cacheRatio: 20,   centsPerReq: 2),
            Model(provider: .anthropicAPI, id: "claude-sonnet-5-5", share: 1.0,  inPerReq: 3200, outPerReq: 700,  cacheRatio: 4,    centsPerReq: nil),
        ]
        let dailyRequests: [ProviderID: Int] = [.claudeCode: 240, .codexCLI: 90, .cursor: 30, .anthropicAPI: 90]

        for offset in stride(from: 29, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            let dayFactor = (weekend ? 0.25 : 1.0) * (0.55 + rng.nextDouble() * 0.9) * (offset == 9 || offset == 17 ? 2.4 : 1)
            for m in models {
                let reqs = max(0, Int(Double(dailyRequests[m.provider]!) * m.share * dayFactor * (0.8 + rng.nextDouble() * 0.4)))
                guard reqs > 0 else { continue }
                let input = reqs * m.inPerReq
                let cacheRead = Int(Double(input) * m.cacheRatio)
                let cacheWrite = m.provider == .claudeCode ? Int(Double(cacheRead) * 0.02) : 0
                let output = reqs * m.outPerReq
                var rec = UsageRecord(provider: m.provider, day: day, model: m.id,
                                      inputTokens: input, outputTokens: output,
                                      cacheWriteTokens: cacheWrite, cacheReadTokens: cacheRead, requests: reqs)
                if let cents = m.centsPerReq {
                    rec.cost = .reported(Double(reqs) * cents / 100)
                } else if m.provider == .anthropicAPI,
                          let est = PriceTable.estimate(model: m.id, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite) {
                    rec.cost = .reported((est * 100).rounded() / 100)
                } else if let est = PriceTable.estimate(model: m.id, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite) {
                    rec.cost = .estimated(est)
                }
                out.append(rec)
            }
        }
        return out
    }

    static func planStatus(for provider: ProviderID, now: Date = Date()) -> PlanStatus? {
        let cal = Calendar.current
        switch provider {
        case .codexCLI:
            return PlanStatus(planName: "ChatGPT Plus", observedAt: now.addingTimeInterval(-540), windows: [
                .init(title: "5-hour window", usedPercent: 37, resetsAt: now.addingTimeInterval(2.1 * 3600)),
                .init(title: "Weekly window", usedPercent: 62, resetsAt: cal.date(byAdding: .day, value: 3, to: now)),
            ], note: "Codex usage on a ChatGPT plan is included in the subscription; the cost column is what the same tokens would cost on the API.",
               suggestedPlan: .init(name: "ChatGPT Plus", monthlyFeeUSD: 20, source: "Codex logs"))
        case .cursor:
            return PlanStatus(planName: "Cursor Pro", observedAt: now.addingTimeInterval(-60), windows: [
                .init(title: "Included usage", usedPercent: 48, detail: "$9.60 of $20.00 included", resetsAt: cal.date(byAdding: .day, value: 11, to: now)),
                .init(title: "Cursor models (Auto)", usedPercent: 55),
                .init(title: "Other models", usedPercent: 31),
            ], note: nil, suggestedPlan: .init(name: "Cursor Pro", monthlyFeeUSD: 20, source: "cursor.com account"))
        case .claudeCode:
            return PlanStatus(planName: "Claude Max 5x", observedAt: now, windows: [],
                              suggestedPlan: .init(name: "Claude Max 5x", monthlyFeeUSD: 100, source: "~/.claude.json"))
        default:
            return nil
        }
    }

    static let billingPlans: [ProviderID: BillingPlan] = [
        .claudeCode:   BillingPlan(kind: .subscription, monthlyFeeUSD: 100, autoDetected: true, planName: "Claude Max 5x"),
        .codexCLI:     BillingPlan(kind: .subscription, monthlyFeeUSD: 20,  autoDetected: true, planName: "ChatGPT Plus"),
        .cursor:       BillingPlan(kind: .subscription, monthlyFeeUSD: 20,  autoDetected: true, planName: "Cursor Pro"),
        .anthropicAPI: BillingPlan(kind: .payPerUse),
    ]

    /// Small deterministic generator so demo screenshots are reproducible.
    struct SeededGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
