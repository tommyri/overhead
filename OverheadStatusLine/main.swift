// overhead-statusline — a Claude Code status-line command that records the plan's rate-limit
// windows for Overhead and otherwise behaves like a normal status line.
//
// Claude Code pipes a JSON object to the configured status-line command on every update. If it
// contains `rate_limits`, this tool writes it (with a timestamp) to
// ~/Library/Application Support/Overhead/claude-statusline.json, and appends a line to
// claude-statusline-history.jsonl whenever the percentages changed (or every 15 minutes while
// they did not), so Overhead can chart them over time. It then prints a status line: the output
// of the command stored in `statusline-chain` next to those files if one exists (your previous
// status line), otherwise a compact default.
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
// OVERHEAD_SUPPORT_DIR overrides the output folder (used by tests; never set by Claude Code).
let supportDir = ProcessInfo.processInfo.environment["OVERHEAD_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Overhead", isDirectory: true)
let recordURL = supportDir.appendingPathComponent("claude-statusline.json")
let historyURL = supportDir.appendingPathComponent("claude-statusline-history.jsonl")
let chainURL = supportDir.appendingPathComponent("statusline-chain")

var json: [String: Any] = [:]
if let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] { json = obj }

/// The values that matter for history: percentage and reset per window.
func signature(_ limits: [String: Any]?) -> String {
    guard let limits else { return "" }
    return ["five_hour", "seven_day", "spend_limit"].map { key in
        let w = limits[key] as? [String: Any]
        return "\(key)=\((w?["used_percentage"] as? NSNumber)?.doubleValue ?? -1)@\((w?["resets_at"] as? NSNumber)?.doubleValue ?? 0)"
    }.joined(separator: ";")
}

// 1. Record what we received. Always write a heartbeat so Overhead can tell "the status line
//    ran but the plan reports no windows" apart from "the status line never ran".
do {
    let now = Date().timeIntervalSince1970
    let previous = (try? Data(contentsOf: recordURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    var record: [String: Any] = ["observedAt": now]
    if let limits = json["rate_limits"] as? [String: Any], !limits.isEmpty { record["rate_limits"] = limits }
    if let model = (json["model"] as? [String: Any])?["display_name"] { record["model"] = model }
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
        try? data.write(to: recordURL, options: .atomic)
    }

    // 2. History: one line per change, at most one every 15 minutes while nothing changes.
    if let limits = record["rate_limits"] as? [String: Any] {
        let unchanged = signature(previous?["rate_limits"] as? [String: Any]) == signature(limits)
        let previousAt = (previous?["observedAt"] as? NSNumber)?.doubleValue ?? 0
        let recent = now - previousAt < 15 * 60
        if !(unchanged && recent),
           let line = try? JSONSerialization.data(withJSONObject: ["observedAt": now, "rate_limits": limits], options: [.sortedKeys]) {
            if let handle = try? FileHandle(forWritingTo: historyURL) {
                handle.seekToEndOfFile(); handle.write(line); handle.write(Data([0x0A])); handle.closeFile()
            } else {
                try? (line + Data([0x0A])).write(to: historyURL)
            }
            // Keep the file small: past 1 MB, drop lines older than 30 days.
            if let size = (try? FileManager.default.attributesOfItem(atPath: historyURL.path)[.size] as? NSNumber)?.intValue, size > 1_000_000,
               let text = try? String(contentsOf: historyURL, encoding: .utf8) {
                let cutoff = now - 30 * 86_400
                let kept = text.split(separator: "\n").filter { l in
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                          let at = (obj["observedAt"] as? NSNumber)?.doubleValue else { return false }
                    return at >= cutoff
                }
                try? (kept.joined(separator: "\n") + "\n").write(to: historyURL, atomically: true, encoding: .utf8)
            }
        }
    }
}

// 3. Chain to the previous status line if one was saved by the installer.
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

// 4. Default line: model, context, and the plan windows.
var parts: [String] = []
if let model = (json["model"] as? [String: Any])?["display_name"] as? String { parts.append("[\(model)]") }
if let ctx = (json["context_window"] as? [String: Any])?["used_percentage"] as? Double { parts.append("ctx \(Int(ctx.rounded()))%") }
if let limits = json["rate_limits"] as? [String: Any] {
    if let p = (limits["five_hour"] as? [String: Any])?["used_percentage"] as? Double { parts.append("5h \(Int(p.rounded()))%") }
    if let p = (limits["seven_day"] as? [String: Any])?["used_percentage"] as? Double { parts.append("week \(Int(p.rounded()))%") }
    if let p = (limits["spend_limit"] as? [String: Any])?["used_percentage"] as? Double { parts.append("spend \(Int(p.rounded()))%") }
}
print(parts.isEmpty ? "Overhead" : parts.joined(separator: " · "))
