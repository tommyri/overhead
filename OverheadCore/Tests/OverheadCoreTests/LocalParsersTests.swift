import Foundation
import Testing
@testable import OverheadCore

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

    @Test func recordsProjectFromWorkingDirectory() throws {
        let records = ClaudeCodeProvider.aggregate(try ClaudeCodeProvider.parseFile(fixture("claude-session")))
        #expect(Set(records.compactMap(\.project)) == ["/Users/demo/proj-a", "/Users/demo/proj-b"])  // trailing slash normalized
        let projects = UsageAggregator.totalsByProject(records)
        #expect(projects.map(\.name).sorted() == ["proj-a", "proj-b"])
        #expect(projects.first { $0.name == "proj-a" }?.totals.outputTokens == 7816)
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

    @Test func attributesCodexUsageToSessionDirectory() throws {
        let entries = try CodexProvider.parseFile(fixture("codex-new"))
        #expect(entries.allSatisfy { $0.cwd == "/x" })
        let records = CodexProvider.aggregate(entries)
        #expect(records.allSatisfy { $0.project == "/x" })
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

    @Test func projectNamesAreDisambiguatedByParentFolder() {
        let day = Calendar.current.startOfDay(for: Date())
        let recs = [
            UsageRecord(provider: .claudeCode, day: day, model: "m", project: "/Users/a/work/api", inputTokens: 1, cost: .estimated(3)),
            UsageRecord(provider: .codexCLI,   day: day, model: "m", project: "/Users/a/side/api", inputTokens: 1, cost: .estimated(1)),
            UsageRecord(provider: .codexCLI,   day: day, model: "m", project: "/Users/a/work/web", inputTokens: 1, cost: .estimated(2)),
            UsageRecord(provider: .cursor,     day: day, model: "m", project: nil, inputTokens: 1, cost: .reported(9)),
        ]
        let projects = UsageAggregator.totalsByProject(recs)
        #expect(projects.map(\.name) == ["work/api", "web", "side/api"])   // sorted by cost, duplicates qualified
        #expect(projects[0].providers == [.claudeCode])
        #expect(projects.count == 3)                                       // nil project excluded
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

@Suite struct ProjectResolverTests {
    @Test func foldsSubdirectoriesAndWorktreesIntoTheRepository() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("resolver-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let repo = base.appendingPathComponent("home/dev/app")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("src/Feature"), withIntermediateDirectories: true)
        let worktree = base.appendingPathComponent("home/.codex/worktrees/42/app")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/42\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let loose = base.appendingPathComponent("home/Documents/scratch")
        try fm.createDirectory(at: loose, withIntermediateDirectories: true)

        let r = ProjectResolver(home: base.appendingPathComponent("home").path)
        #expect(r.repoRoot(for: repo.appendingPathComponent("src/Feature").path) == repo.path)
        #expect(r.repoRoot(for: worktree.path) == repo.path)
        #expect(r.repoRoot(for: loose.path) == loose.path)           // no repo: unchanged
        #expect(r.resolve([repo.path, nil, worktree.path]).count == 2)
    }
}
