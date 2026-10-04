import Foundation
import Testing
@testable import LLMOverviewCore

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
}

@Suite struct ClaudeCodeParserTests {
    @Test func dedupesStreamingLinesAndSkipsSynthetic() throws {
        let entries = try ClaudeCodeProvider.parseFile(fixture("claude-session"))
        #expect(entries.count == 2)
        let a = try #require(entries.first { $0.key.hasPrefix("msg_A") })
        #expect(a.output == 7816)           // last line wins
        #expect(a.cacheWrite == 22868)
        #expect(a.cacheRead == 44228)
        #expect(a.input == 2)
    }

    @Test func aggregatesPerDayAndModel() throws {
        let entries = try ClaudeCodeProvider.parseFile(fixture("claude-session"))
        let records = ClaudeCodeProvider.aggregate(entries + entries) // duplicates across files collapse
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.requests == 1 })
        #expect(records.map(\.outputTokens).reduce(0, +) == 7816 + 50)
    }
}

@Suite struct CodexParserTests {
    @Test func prefersUsageRecordsAndDedupesResponseIDs() throws {
        let entries = try CodexProvider.parseFile(fixture("codex-new"))
        #expect(entries.count == 2)
        let first = try #require(entries.first { $0.key == "resp_1" })
        #expect(first.model == "gpt-5-codex")
        let second = try #require(entries.first { $0.key == "resp_2" })
        #expect(second.model == "gpt-5.5")
    }

    @Test func fallsBackToTokenCountDeltas() throws {
        let entries = try CodexProvider.parseFile(fixture("codex-old"))
        #expect(entries.count == 2) // repeated total skipped, null info skipped
        #expect(entries.map(\.input).reduce(0, +) == 3305 + 2000)
        #expect(entries.allSatisfy { $0.model == "gpt-5-codex" })
    }

    @Test func normalizesCachedTokensIntoDisjointBuckets() throws {
        let records = CodexProvider.aggregate(try CodexProvider.parseFile(fixture("codex-old")))
        let total = UsageAggregator.totals(records)
        #expect(total.cacheReadTokens == 3072 + 1000)
        #expect(total.inputTokens == (3305 - 3072) + (2000 - 1000))
        #expect(total.outputTokens == 247)
    }

    @Test func readsRateLimits() throws {
        let rl = try #require(try CodexProvider.parseRateLimits(fixture("codex-new")))
        #expect(rl.planType == "plus")
        #expect(rl.primary?.usedPercent == 12.0)
        #expect(rl.secondary?.windowMinutes == 10080)
    }
}

@Suite struct AggregatorTests {
    @Test func costSumPropagatesEstimateFlag() {
        let a = UsageRecord.Cost.reported(1)
        let b = UsageRecord.Cost.estimated(2)
        #expect(UsageRecord.Cost.sum(a, b) == .estimated(3))
        #expect(UsageRecord.Cost.sum(a, .unknown) == .reported(1))
        #expect(UsageRecord.Cost.sum(.unknown, .unknown) == .unknown)
    }

    @Test func dailySeriesFillsGaps() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let interval = DateInterval(start: cal.date(byAdding: .day, value: -2, to: start)!, end: cal.date(byAdding: .day, value: 1, to: start)!)
        let rec = UsageRecord(provider: .claudeCode, day: start, model: "m", inputTokens: 10, cost: .estimated(1))
        let series = UsageAggregator.dailySeries([rec], in: interval, providers: [.claudeCode, .codexCLI])
        #expect(series.count == 6)
        #expect(series.filter { $0.cost > 0 }.count == 1)
    }
}

@Suite struct PriceTableTests {
    @Test func normalizesModelIDs() {
        #expect(PriceTable.normalize("anthropic/claude-sonnet-4-5-20250929") == "claude-sonnet-4-5")
        #expect(PriceTable.normalize("GPT-5-Codex") == "gpt-5-codex")
    }
}
