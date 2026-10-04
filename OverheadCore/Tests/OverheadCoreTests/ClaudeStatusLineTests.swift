import Foundation
import Testing
@testable import OverheadCore

@Suite struct ClaudeStatusLineTests {
    @Test func parsesWindowsAndDropsExpiredOnes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let obj: [String: Any] = [
            "observedAt": 1_799_999_000.0,
            "model": "Opus 5.5",
            "rate_limits": [
                "five_hour": ["used_percentage": 23.5, "resets_at": 1_800_000_000 + 7_200],
                "seven_day": ["used_percentage": 41.2, "resets_at": 1_800_000_000 + 3 * 86_400],
                "spend_limit": ["used_percentage": 62.8, "resets_at": 1_800_000_000 - 60],   // already reset → dropped
            ],
        ]
        let r = try #require(ClaudeStatusLine.parse(obj, now: now))
        #expect(r.model == "Opus 5.5")
        #expect(r.observedAt == Date(timeIntervalSince1970: 1_799_999_000))
        #expect(r.windows.map(\.title) == ["5-hour window", "Weekly window"])
        let five = r.windows[0]
        #expect(five.usedPercent == 23.5)
        #expect(five.periodStart == five.resetsAt?.addingTimeInterval(-5 * 3600))
        #expect(ClaudeStatusLine.parse(["model": "x"], now: now) == nil)                      // not a record
        let heartbeat = try #require(ClaudeStatusLine.parse(["observedAt": 1_800_000_000.0], now: now))
        #expect(heartbeat.windows.isEmpty)                                                     // ran, no windows
    }

    @Test func installsAndRemovesPreservingAnExistingStatusLine() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("statusline-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let settings = base.appendingPathComponent("settings.json")
        try #"{"statusLine":{"type":"command","command":"~/.claude/my-statusline.sh"},"model":"opus"}"#.write(to: settings, atomically: true, encoding: .utf8)
        let source = base.appendingPathComponent("helper-src"); try "#!/bin/sh\necho hi\n".write(to: source, atomically: true, encoding: .utf8)
        let helper = base.appendingPathComponent("bin/overhead-statusline")
        let chain = base.appendingPathComponent("statusline-chain")
        let record = base.appendingPathComponent("claude-statusline.json")

        try ClaudeStatusLine.install(helperSource: source, settingsURL: settings, helperURL: helper, chainURL: chain)
        var st = ClaudeStatusLine.status(settingsURL: settings, helperURL: helper, recordURL: record, chainURL: chain)
        #expect(st.installed && st.chainedCommand == "~/.claude/my-statusline.sh" && !st.hasWindows)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect((written["statusLine"] as? [String: Any])?["command"] as? String == helper.path)
        #expect(written["model"] as? String == "opus")                       // other settings untouched
        #expect(try fm.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix("settings.json.overhead-backup-") })

        try ClaudeStatusLine.remove(settingsURL: settings, helperURL: helper, chainURL: chain, recordURL: record)
        st = ClaudeStatusLine.status(settingsURL: settings, helperURL: helper, recordURL: record, chainURL: chain)
        #expect(!st.installed && st.chainedCommand == nil)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "~/.claude/my-statusline.sh")
        #expect(!fm.fileExists(atPath: helper.path))
    }
}
