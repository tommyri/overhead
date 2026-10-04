// overhead-statusline — a Claude Code status-line command that records the plan's rate-limit
// windows for Overhead and otherwise behaves like a normal status line.
//
// Claude Code pipes a JSON object to the configured status-line command on every update. If it
// contains `rate_limits`, this tool writes it (with a timestamp) to
// ~/Library/Application Support/Overhead/claude-statusline.json. It then prints a status line:
// the output of the command stored in `statusline-chain` next to that file if one exists (your
// previous status line), otherwise a compact default.
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
// OVERHEAD_SUPPORT_DIR overrides the output folder (used by tests; never set by Claude Code).
let supportDir = ProcessInfo.processInfo.environment["OVERHEAD_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Overhead", isDirectory: true)
let recordURL = supportDir.appendingPathComponent("claude-statusline.json")
let chainURL = supportDir.appendingPathComponent("statusline-chain")

var json: [String: Any] = [:]
if let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] { json = obj }

// 1. Record what we received. Always write a heartbeat so Overhead can tell "the status line
//    ran but the plan reports no windows" apart from "the status line never ran".
do {
    var record: [String: Any] = ["observedAt": Date().timeIntervalSince1970]
    if let limits = json["rate_limits"] as? [String: Any], !limits.isEmpty { record["rate_limits"] = limits }
    if let model = (json["model"] as? [String: Any])?["display_name"] { record["model"] = model }
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? data.write(to: recordURL, options: .atomic)
    }
}

// 2. Chain to the previous status line if one was saved by the installer.
if let chain = try? String(contentsOf: chainURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !chain.isEmpty {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", chain]
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = FileHandle.standardError
    do {
        try p.run()
        inPipe.fileHandleForWriting.write(input)
        inPipe.fileHandleForWriting.closeFile()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        FileHandle.standardOutput.write(out)
        exit(0)
    } catch {
        // fall through to the default line
    }
}

// 3. Default line: model, context, and the plan windows.
var parts: [String] = []
if let model = (json["model"] as? [String: Any])?["display_name"] as? String { parts.append("[\(model)]") }
if let ctx = (json["context_window"] as? [String: Any])?["used_percentage"] as? Double { parts.append("ctx \(Int(ctx.rounded()))%") }
if let limits = json["rate_limits"] as? [String: Any] {
    if let p = (limits["five_hour"] as? [String: Any])?["used_percentage"] as? Double { parts.append("5h \(Int(p.rounded()))%") }
    if let p = (limits["seven_day"] as? [String: Any])?["used_percentage"] as? Double { parts.append("week \(Int(p.rounded()))%") }
    if let p = (limits["spend_limit"] as? [String: Any])?["used_percentage"] as? Double { parts.append("spend \(Int(p.rounded()))%") }
}
print(parts.isEmpty ? "Overhead" : parts.joined(separator: " · "))
