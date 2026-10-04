import Foundation
import LLMOverviewCore
setbuf(stdout, nil)

// Usage: llmo [days]   — prints per-provider, per-model totals from local logs.
let days = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 30
let cal = Calendar.current
let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
let interval = DateInterval(start: start, end: end)

func fmtUSD(_ c: UsageRecord.Cost) -> String {
    guard let v = c.value else { return "      —" }
    return (c.isEstimate ? "≈" : " ") + String(format: "$%.2f", v)
}
func fmtTok(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : (n >= 1000 ? String(format: "%.0fK", Double(n) / 1e3) : "\(n)")
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let t = s.count > w ? String(s.prefix(w - 1)) + "…" : s
    let fill = String(repeating: " ", count: max(0, w - t.count))
    return right ? fill + t : t + fill
}
func row(_ cols: [String]) -> String {
    "   " + pad(cols[0], 34) + cols.dropFirst().map { pad($0, 11, right: true) }.joined()
}

let providers: [any UsageProvider] = [ClaudeCodeProvider(), CodexProvider()]
let clock = ContinuousClock()
for p in providers {
    let t0 = clock.now
    do {
        let all = try await p.fetch(interval: interval, credentials: [:])
        let recs = UsageAggregator.filter(all, in: interval)
        let elapsed = clock.now - t0
        let totals = UsageAggregator.totals(recs)
        print("\n== \(p.id.displayName)  (last \(days) days, \(all.count) day/model rows total, parsed in \(elapsed))")
        print(row(["model", "input", "output", "cache w", "cache r", "reqs", "cost"]))
        for m in UsageAggregator.totalsByModel(recs) {
            let t = m.totals
            print(row([m.model, fmtTok(t.inputTokens), fmtTok(t.outputTokens), fmtTok(t.cacheWriteTokens), fmtTok(t.cacheReadTokens), "\(t.requests)", fmtUSD(t.cost)]))
        }
        print(row(["TOTAL", fmtTok(totals.inputTokens), fmtTok(totals.outputTokens), fmtTok(totals.cacheWriteTokens), fmtTok(totals.cacheReadTokens), "\(totals.requests)", fmtUSD(totals.cost)]))
        if let codex = p as? CodexProvider, let rl = codex.latestRateLimits() {
            print("   plan: \(rl.planType ?? "?")  5h window: \(rl.primary.map { "\($0.usedPercent)%" } ?? "-")  weekly: \(rl.secondary.map { "\($0.usedPercent)%" } ?? "-")  (observed \(rl.observedAt))")
        }
    } catch {
        print("\n== \(p.id.displayName): \(error.localizedDescription)")
    }
}
