import Foundation
import Testing
@testable import OverheadCore

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
}

@Suite struct ToolActivityTests {
    @Test func claudeCountsCallsAndErrorsPerTool() throws {
        let entries = try ClaudeCodeProvider.parseFile(fixture("claude-session"))
        let a = try #require(entries.first { $0.key.hasPrefix("msg_A") })
        #expect(a.toolCalls == ["Edit": 2, "Write": 1])
        #expect(a.toolErrors == ["Edit": 1])                      // toolu_3 was rejected
        let tools = ClaudeCodeProvider.aggregateTools(entries, provider: .claudeCode)
        let edit = try #require(tools.first { $0.tool == "Edit" })
        #expect(edit.calls == 2 && edit.errors == 1 && edit.project == "/Users/demo/proj-a")
        let groups = UsageAggregator.toolTotalsByTool(tools)
        #expect(groups.first?.tool == "Edit")
        #expect(abs((UsageAggregator.toolTotals(tools).errorRate ?? 0) - 1.0 / 3.0) < 1e-9)
    }

    @Test func codexCountsToolCallsWithExitCodes() throws {
        let entries = try CodexProvider.parseFile(fixture("codex-new"))
        let first = try #require(entries.first { $0.key == "resp_1" })
        #expect(first.toolCalls == ["apply_patch": 2])
        #expect(first.toolErrors == ["apply_patch": 1])           // exit_code 1 on the second patch
        let tools = CodexProvider.aggregateTools(entries)
        #expect(tools.count == 1 && tools[0].calls == 2 && tools[0].errors == 1)
    }

    @Test func codexOutputErrorDetection() {
        #expect(CodexProvider.outputIsError(#"{"output":"ok","metadata":{"exit_code":0}}"#) == false)
        #expect(CodexProvider.outputIsError(#"{"output":"boom","metadata":{"exit_code":2}}"#) == true)
        #expect(CodexProvider.outputIsError("apply_patch verification failed: x") == true)
        #expect(CodexProvider.outputIsError("plain text result") == false)
    }
}
