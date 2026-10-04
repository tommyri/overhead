import Foundation
import SQLite3
import Testing
@testable import OverheadCore

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
}

@Suite struct CodeActivityTests {
    @Test func lineCountingHelpers() {
        #expect(CodeActivity.lineCount(nil) == 0)
        #expect(CodeActivity.lineCount("") == 0)
        #expect(CodeActivity.lineCount("one") == 1)
        #expect(CodeActivity.lineCount("a\nb\nc") == 3)
        #expect(CodeActivity.lineCount("a\nb\n") == 2)
        let d = CodeActivity.diffCounts("*** Begin Patch\n*** Update File: x\n@@\n-gone\n+here\n+and here\n--- not a header? it is\n+++ also header\n*** End Patch")
        #expect(d.added == 2 && d.removed == 1)
    }

    @Test func claudeCountsOnlyAppliedEdits() throws {
        let entries = try ClaudeCodeProvider.parseFile(fixture("claude-session"))
        let a = try #require(entries.first { $0.key.hasPrefix("msg_A") })
        // Edit toolu_1: +4 −2; Write toolu_2: +3; Edit toolu_3 rejected (is_error) → excluded.
        #expect(a.linesAdded == 7 && a.linesRemoved == 2 && a.edits == 2)
        let code = ClaudeCodeProvider.aggregateCode(entries)
        #expect(code.count == 1)
        #expect(code[0].kind == "edits" && code[0].project == "/Users/demo/proj-a")
        #expect(code[0].linesAdded == 7)
    }

    @Test func codexCountsSuccessfulPatchesOnly() throws {
        let entries = try CodexProvider.parseFile(fixture("codex-new"))
        let first = try #require(entries.first { $0.key == "resp_1" })
        #expect(first.linesAdded == 2 && first.linesRemoved == 1 && first.edits == 1)   // call_2 failed verification
        let code = CodexProvider.aggregateCode(entries)
        #expect(code.count == 1 && code[0].linesAdded == 2 && code[0].project == "/x")
    }

    @Test func cursorDailyStatsFromStateDatabase() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("code-\(UUID().uuidString).vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil)
        sqlite3_exec(db, #"INSERT INTO ItemTable VALUES ('aiCodeTracking.dailyStats.v1.5.2026-10-01', '{"date":"2026-10-01","tabSuggestedLines":120,"tabAcceptedLines":45,"composerSuggestedLines":300,"composerAcceptedLines":280}')"#, nil, nil, nil)
        sqlite3_exec(db, #"INSERT INTO ItemTable VALUES ('aiCodeTracking.other', '{"x":1}')"#, nil, nil, nil)
        sqlite3_close(db)
        defer { try? FileManager.default.removeItem(at: url) }

        var p = CursorProvider()
        p.localStateDatabase = url
        let code = try await p.codeActivity(interval: DateInterval(start: .distantPast, end: .distantFuture), credentials: [:])
        #expect(code.count == 2)
        let tab = try #require(code.first { $0.kind == "tab" })
        #expect(tab.linesAdded == 45 && tab.suggestedLines == 120)
        let totals = UsageAggregator.codeTotals(code)
        #expect(totals.linesAdded == 325 && totals.suggestedLines == 420)
        #expect(abs((totals.acceptanceRate ?? 0) - 325.0 / 420.0) < 1e-9)
        var odd = UsageAggregator.CodeTotals(); odd.linesAdded = 500; odd.suggestedLines = 100
        #expect(odd.acceptanceRate == nil)          // accepted > suggested: not comparable
    }
}
