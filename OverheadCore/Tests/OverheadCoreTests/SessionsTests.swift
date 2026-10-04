import Foundation
import Testing
@testable import OverheadCore

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
}

@Suite struct SessionsTests {
    let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c }()

    @Test func claudeResponsesGroupBySessionIdWithIdleCap() throws {
        let entries = try ClaudeCodeProvider.parseFile(fixture("claude-session"))
        #expect(Set(entries.compactMap(\.session)) == ["sess-1"])
        let sessions = SessionAggregator.sessions(ClaudeCodeProvider.sessionItems(entries), provider: .claudeCode)
        let s = try #require(sessions.first)
        #expect(sessions.count == 1 && s.requests == 2)
        #expect(s.activeSeconds == SessionAggregator.idleThreshold)        // 14 hours apart → one idle gap, capped
        #expect(s.duration > 13 * 3600)
        #expect(s.project == "/Users/demo/proj-a" || s.project == "/Users/demo/proj-b")
        #expect(s.cost != nil && s.totalTokens == 2 + 22868 + 44228 + 7816 + 100 + 50)
    }

    @Test func auditLogCopyDoesNotSplitASession() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let real = ClaudeCodeProvider.Entry(key: "msg_1", timestamp: t, model: "claude-opus-5-5", input: 1, output: 5, cacheWrite: 0, cacheWrite1h: 0, cacheRead: 0, session: "sess-9")
        let audit = ClaudeCodeProvider.Entry(key: "msg_1", timestamp: t, model: "claude-opus-5-5", input: 1, output: 9, cacheWrite: 0, cacheWrite1h: 0, cacheRead: 0, session: "file:audit-log")
        #expect(ClaudeCodeProvider.sessionItems([audit, real]).map(\.session) == ["sess-9"])
        #expect(ClaudeCodeProvider.sessionItems([real, audit]).map(\.session) == ["sess-9"])
    }

    @Test func codexRolloutIsOneSession() throws {
        let entries = try CodexProvider.parseFile(fixture("codex-new"))
        #expect(Set(entries.compactMap(\.session)) == ["t1"])
        let sessions = SessionAggregator.sessions(CodexProvider.sessionItems(entries), provider: .codexCLI)
        let s = try #require(sessions.first)
        #expect(sessions.count == 1 && s.requests == 2 && s.activeSeconds == 60 && s.project == "/x")
    }

    @Test func hourlyBucketsAndHeatmapFollowTheCalendar() {
        // Monday 2026-10-05 09:30 UTC and 09:50 UTC, Tuesday 23:10 UTC.
        let monday = utc.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9, minute: 30))!
        let items = [
            SessionAggregator.Item(session: "a", timestamp: monday, model: "m", cwd: nil, input: 10, output: 1, cacheRead: 0, cacheWrite: 0),
            SessionAggregator.Item(session: "a", timestamp: monday.addingTimeInterval(1200), model: "m", cwd: nil, input: 10, output: 1, cacheRead: 0, cacheWrite: 0),
            SessionAggregator.Item(session: "b", timestamp: monday.addingTimeInterval(86_400 + 13 * 3600 + 2400), model: "m", cwd: nil, input: 5, output: 1, cacheRead: 0, cacheWrite: 0),
        ]
        let hourly = SessionAggregator.hourly(items, provider: .claudeCode, calendar: utc)
        #expect(hourly.count == 2)
        #expect(hourly[0].hour == 9 && hourly[0].requests == 2 && hourly[0].tokens == 22)
        #expect(hourly[1].hour == 23 && hourly[1].requests == 1)
        let cells = UsageAggregator.heatmap(hourly, calendar: utc)
        #expect(cells.count == 7 * 24)
        #expect(cells.first { $0.weekday == 2 && $0.hour == 9 }?.requests == 2)      // Monday
        #expect(cells.first { $0.weekday == 3 && $0.hour == 23 }?.requests == 1)     // Tuesday
        #expect(UsageAggregator.orderedWeekdays(calendar: utc) == [2, 3, 4, 5, 6, 7, 1])
    }

    @Test func totalsReportMedianAndLongest() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func s(_ id: String, _ active: Double) -> SessionActivity {
            SessionActivity(provider: .codexCLI, sessionID: id, start: t, end: t.addingTimeInterval(active), activeSeconds: active, requests: 4, totalTokens: 100, outputTokens: 10, cost: 1)
        }
        let totals = UsageAggregator.sessionTotals([s("a", 600), s("b", 3600), s("c", 60), s("d", 1200)])
        #expect(totals.count == 4 && totals.longest?.sessionID == "b")
        #expect(totals.medianActiveSeconds == 900)                                   // (600 + 1200) / 2
        #expect(totals.requestsPerSession == 4 && totals.tokensPerSession == 100)
        #expect(UsageAggregator.sessionTotals([]).longest == nil)
    }

    @Test func snapshotDecodesWithoutSessionFields() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let snap = try d.decode(UsageCache.Snapshot.self, from: Data(#"{"fetchedAt":"2026-10-04T10:00:00Z","records":[]}"#.utf8))
        #expect(snap.sessions.isEmpty && snap.hourly.isEmpty)
    }
}
