import Foundation
import Testing
@testable import OverheadCore

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
}

@Suite struct ThinkingShareTests {
    @Test func claudeThinkingTokensFlowIntoRecords() throws {
        let entries = try ClaudeCodeProvider.parseFile(fixture("claude-session"))
        let a = try #require(entries.first { $0.key.hasPrefix("msg_A") })
        #expect(a.thinking == 1200)
        let records = ClaudeCodeProvider.aggregate(entries)
        let totals = UsageAggregator.totals(records)
        #expect(totals.reasoningTokens == 1200)
        #expect(totals.thinkingShare.map { abs($0 - 1200.0 / Double(7816 + 50)) < 0.0001 } == true)
    }

    @Test func codexReasoningTokensFlowIntoRecords() throws {
        let records = CodexProvider.aggregate(try CodexProvider.parseFile(fixture("codex-new")))
        let byModel = UsageAggregator.totalsByModel(records)
        #expect(byModel.first { $0.model == "gpt-5-codex" }?.totals.reasoningTokens == 128)
        #expect(byModel.first { $0.model == "gpt-5.5" }?.totals.thinkingShare == nil)   // none reported → no share
    }

    @Test func recordsDecodeWithoutTheNewField() throws {
        let json = #"{"provider":"codex-cli","day":0,"model":"m","inputTokens":1,"outputTokens":2,"cacheWriteTokens":0,"cacheReadTokens":0,"requests":1,"cost":{"unknown":{}}}"#
        let r = try JSONDecoder().decode(UsageRecord.self, from: Data(json.utf8))
        #expect(r.reasoningTokens == 0)
    }
}

@Suite struct CacheSavingsTests {
    @Test func savingsCompareListPriceWithAndWithoutCache() throws {
        let day = Calendar.current.startOfDay(for: Date())
        // Sonnet 4.5: $3 input, $0.30 cache read. 1M cached tokens cost $0.30 instead of $3.
        var r = UsageRecord(provider: .claudeCode, day: day, model: "claude-sonnet-4-5", inputTokens: 1000, cacheReadTokens: 1_000_000)
        r.cost = .estimated(PriceTable.estimate(model: r.model, input: 1000, output: 0, cacheRead: 1_000_000, cacheWrite: 0)!)
        let unknown = UsageRecord(provider: .cursor, day: day, model: "mystery-model", inputTokens: 5, cost: .reported(1))
        // A billed amount is ignored on the "with cache" side: Cursor's $5 for 200 Grok tokens is a plan
        // charge, not a token price, and must not turn the savings negative.
        let billed = UsageRecord(provider: .cursor, day: day, model: "grok-4.7", inputTokens: 100, outputTokens: 100, cost: .reported(5))
        let s = try #require(UsageAggregator.cacheSavings([r, unknown, billed]))
        #expect(abs(s.withoutCache - 3.003 - 0.0008) < 0.0001)
        #expect(abs(s.withCache - 0.303 - 0.0008) < 0.0001)
        #expect(abs(s.saved - 2.7) < 0.0001)
        #expect(abs(s.cacheHitRate - 1_000_000.0 / 1_001_100.0) < 0.0001)
        #expect(UsageAggregator.cacheSavings([unknown]) == nil)
    }

    @Test func changeIsRelativeToPrevious() {
        #expect(UsageAggregator.change(118, from: 100) == 0.18)
        #expect(UsageAggregator.change(50, from: 100) == -0.5)
        #expect(UsageAggregator.change(5, from: 0) == nil)
    }
}

@Suite struct PreviousPeriodTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    @Test func rollingPresetsShiftBackByTheirLength() {
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 15))!
        let prev = DateRangePreset.last7.previousInterval(now: now, calendar: cal)
        #expect(prev.start == cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!)
        #expect(prev.end == cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!)
        #expect(DateRangePreset.today.previousInterval(now: now, calendar: cal).start == cal.date(from: DateComponents(year: 2026, month: 10, day: 3))!)
    }

    @Test func monthPresetsCompareLikeWithLike() {
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 15))!
        let thisMonth = DateRangePreset.thisMonth.previousInterval(now: now, calendar: cal)
        #expect(thisMonth.start == cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!)
        #expect(thisMonth.end == cal.date(from: DateComponents(year: 2026, month: 9, day: 5))!)      // Oct 1–4 → Sep 1–4
        let lastMonth = DateRangePreset.lastMonth.previousInterval(now: now, calendar: cal)
        #expect(lastMonth.start == cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!)
        #expect(lastMonth.end == cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!)
    }
}

@Suite struct PlanHistoryTests {
    @Test func codexSnapshotsAttachToThePrecedingResponse() throws {
        let entries = try CodexProvider.parseFile(fixture("codex-new"))
        let first = try #require(entries.first { $0.key == "resp_1" })
        #expect(first.rateLimits?.count == 1)
        #expect(entries.first { $0.key == "resp_2" }?.rateLimits == nil)
        let samples = CodexProvider.aggregatePlanHistory(entries)
        #expect(samples.map(\.window) == ["5-hour window", "Weekly window"])
        #expect(samples[0].usedPercent == 12 && samples[1].usedPercent == 4)
        #expect(samples[0].resetsAt == Date(timeIntervalSince1970: 1762296387))
    }

    @Test func windowTitlesRoundJitteredLengths() {
        #expect(PlanStatus.windowTitle(minutes: 299) == "5-hour window")
        #expect(PlanStatus.windowTitle(minutes: 300) == "5-hour window")
        #expect(PlanStatus.windowTitle(minutes: 10079) == "Weekly window")
        #expect(PlanStatus.windowTitle(minutes: 10080) == "Weekly window")
        #expect(PlanStatus.windowTitle(minutes: 0) == "Usage window")
        #expect(PlanStatus.windowTitle(minutes: 43_200) == "30-day window")
    }

    @Test func seriesBreakAtResetsAndThinPlateaus() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset1 = t0.addingTimeInterval(5 * 3600), reset2 = reset1.addingTimeInterval(5 * 3600)
        let samples = [
            PlanSample(provider: .codexCLI, observedAt: t0, window: "5-hour window", usedPercent: 10, resetsAt: reset1),
            PlanSample(provider: .codexCLI, observedAt: t0.addingTimeInterval(3600), window: "5-hour window", usedPercent: 40, resetsAt: reset1),
            PlanSample(provider: .codexCLI, observedAt: t0.addingTimeInterval(6 * 3600), window: "5-hour window", usedPercent: 5, resetsAt: reset2),
            PlanSample(provider: .codexCLI, observedAt: t0, window: "Weekly window", usedPercent: 50, resetsAt: t0.addingTimeInterval(86_400)),
            PlanSample(provider: .codexCLI, observedAt: t0.addingTimeInterval(3600), window: "Weekly window", usedPercent: 50, resetsAt: t0.addingTimeInterval(86_400)),
        ]
        let points = UsageAggregator.planSeries(samples, maxPoints: 1000)
        let fiveHour = points.filter { $0.window == "5-hour window" }
        #expect(Set(fiveHour.map(\.series)).count == 2)                            // one break at the reset
        #expect(fiveHour.filter(\.isSynthetic).map(\.usedPercent) == [40, 0])        // hold at 40 until reset, restart at 0
        #expect(fiveHour.filter(\.isSynthetic).allSatisfy { $0.time == reset1 })
        #expect(points.filter { $0.window == "Weekly window" }.count == 2)           // separate buckets, both kept
        let weekly = samples.filter { $0.window == "Weekly window" }
            + [PlanSample(provider: .codexCLI, observedAt: t0.addingTimeInterval(1800), window: "Weekly window", usedPercent: 50, resetsAt: t0.addingTimeInterval(86_400))]
        let coarse = UsageAggregator.planSeries(weekly, maxPoints: 1)                   // one-hour buckets
        #expect(coarse.map(\.time) == [t0.addingTimeInterval(1800), t0.addingTimeInterval(3600)])   // last sample of each bucket
    }

    @Test func readsStatusLineHistoryKeepingExpiredWindows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"observedAt":1700000000,"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1700010000},"seven_day":{"used_percentage":41,"resets_at":1700500000}}}"#,
            #"{"observedAt":1700003600,"rate_limits":{"five_hour":{"used_percentage":35,"resets_at":1700010000}}}"#,
            "not json",
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let samples = ClaudeStatusLine.readHistory(historyURL: url)
        #expect(samples.count == 3)
        #expect(samples.filter { $0.window == "5-hour window" }.map(\.usedPercent) == [20, 35])
        #expect(samples.allSatisfy { $0.provider == .claudeCode })
        #expect(ClaudeStatusLine.readHistory(historyURL: url.appendingPathExtension("missing")).isEmpty)
    }

    @Test func storeRecordsOnlyChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plan-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanHistoryStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = t0.addingTimeInterval(10 * 86_400)
        func status(_ pct: Double, at: Date) -> PlanStatus {
            PlanStatus(planName: "Cursor Pro", observedAt: at, windows: [.init(title: "Included usage", usedPercent: pct, resetsAt: reset)])
        }
        #expect(await store.record(status(10, at: t0), for: .cursor, now: t0) == 1)
        #expect(await store.record(status(10, at: t0.addingTimeInterval(600)), for: .cursor, now: t0) == 0)          // unchanged, recent
        #expect(await store.record(status(12, at: t0.addingTimeInterval(1200)), for: .cursor, now: t0) == 1)         // changed
        #expect(await store.record(status(12, at: t0.addingTimeInterval(8 * 3600)), for: .cursor, now: t0) == 1)     // unchanged but stale
        let reloaded = PlanHistoryStore(directory: dir)
        #expect(await reloaded.samples(for: .cursor).map(\.usedPercent) == [10, 12, 12])
        await store.clear(.cursor)
        #expect(await store.samples(for: .cursor).isEmpty)
    }

    @Test func snapshotDecodesWithoutPlanSamples() throws {
        let json = #"{"fetchedAt":"2026-10-04T10:00:00Z","records":[]}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let snap = try d.decode(UsageCache.Snapshot.self, from: Data(json.utf8))
        #expect(snap.plan.isEmpty && snap.tools.isEmpty)
    }
}
