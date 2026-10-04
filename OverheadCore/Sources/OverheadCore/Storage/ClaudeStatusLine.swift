import Foundation

/// Claude Code exposes a subscription's 5-hour and 7-day rate-limit windows only to the
/// configured status-line command. Overhead ships a small helper (`overhead-statusline`) that
/// records that JSON to a file; this type reads the file and installs/removes the helper.
public struct ClaudeStatusLine: Sendable {
    public struct Record: Sendable, Hashable {
        public var observedAt: Date
        public var windows: [PlanStatus.Window]
        public var model: String?
    }

    public static var defaultRecordURL: URL { AppSupport.directory().appendingPathComponent("claude-statusline.json") }
    /// One JSON line per change of the percentages, appended by the helper; see `readHistory`.
    public static var defaultHistoryURL: URL { AppSupport.directory().appendingPathComponent("claude-statusline-history.jsonl") }
    public static var defaultChainURL: URL { AppSupport.directory().appendingPathComponent("statusline-chain") }
    public static var defaultHelperURL: URL { AppSupport.directory().appendingPathComponent("bin/overhead-statusline") }
    public static var defaultSettingsURL: URL { LogFiles.home().appendingPathComponent(".claude/settings.json") }

    // MARK: Reading

    /// Parse the helper's record. Windows whose reset time has passed are dropped, matching
    /// Claude Code's own behaviour.
    public static func read(recordURL: URL = defaultRecordURL, now: Date = Date()) -> Record? {
        guard let data = try? Data(contentsOf: recordURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(obj, now: now)
    }

    /// A record without `rate_limits` is a heartbeat: the status line ran but Claude Code did
    /// not report any windows (documented for claude.ai Pro and Max subscribers only).
    public static func parse(_ obj: [String: Any], now: Date = Date()) -> Record? {
        guard obj["observedAt"] != nil || obj["rate_limits"] != nil else { return nil }
        let limits = obj["rate_limits"] as? [String: Any] ?? [:]
        let observed = (obj["observedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? now
        var windows: [PlanStatus.Window] = []
        func window(_ key: String, title: String, lengthMinutes: Int?) {
            guard let w = limits[key] as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { return }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let reset, reset < now { return }
            let start = lengthMinutes.flatMap { m in reset?.addingTimeInterval(-Double(m) * 60) }
            var detail: String? = nil
            if let used = (w["used_usd"] as? NSNumber)?.doubleValue, let limit = (w["limit_usd"] as? NSNumber)?.doubleValue {
                detail = String(format: "$%.2f of $%.2f", used, limit) + ((w["period"] as? String).map { " \($0)" } ?? "")
            }
            windows.append(.init(title: title, usedPercent: pct, detail: detail, resetsAt: reset, periodStart: start))
        }
        window("five_hour", title: "5-hour window", lengthMinutes: 300)
        window("seven_day", title: "Weekly window", lengthMinutes: 10080)
        window("spend_limit", title: "Spend limit", lengthMinutes: nil)
        return Record(observedAt: observed, windows: windows, model: obj["model"] as? String)
    }

    /// Parse the helper's history file into samples, one per window per line. Each line has the
    /// same shape as the record; windows are kept even if their reset has since passed, because
    /// the point is to show what happened.
    public static func readHistory(historyURL: URL = defaultHistoryURL) -> [PlanSample] {
        guard let data = try? Data(contentsOf: historyURL, options: .mappedIfSafe) else { return [] }
        var out: [PlanSample] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end + 1 }
            guard end > start, let obj = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any],
                  let observed = (obj["observedAt"] as? NSNumber).map({ Date(timeIntervalSince1970: $0.doubleValue) }),
                  let record = parse(obj, now: observed) else { continue }
            for w in record.windows {
                out.append(PlanSample(provider: .claudeCode, observedAt: observed, window: w.title, usedPercent: w.usedPercent, resetsAt: w.resetsAt))
            }
        }
        return out
    }

    // MARK: Installing

    public enum InstallError: Error, LocalizedError {
        case helperMissing(String)
        case settingsUnreadable(String)
        public var errorDescription: String? {
            switch self {
            case .helperMissing(let p): return "The status-line helper was not found at \(p)."
            case .settingsUnreadable(let m): return "Could not read ~/.claude/settings.json: \(m)"
            }
        }
    }

    public struct Status: Sendable, Hashable {
        public var installed: Bool
        public var chainedCommand: String?
        public var lastRecord: Date?
        public var hasWindows: Bool
    }

    public static func status(settingsURL: URL = defaultSettingsURL, helperURL: URL = defaultHelperURL,
                              recordURL: URL = defaultRecordURL, chainURL: URL = defaultChainURL) -> Status {
        let settings = (try? loadSettings(settingsURL)) ?? [:]
        let command = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let installed = command == helperURL.path
        let chain = try? String(contentsOf: chainURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let attrs = try? FileManager.default.attributesOfItem(atPath: recordURL.path)
        let record = read(recordURL: recordURL)
        return Status(installed: installed, chainedCommand: (chain?.isEmpty == false) ? chain : nil,
                      lastRecord: attrs?[.modificationDate] as? Date, hasWindows: !(record?.windows.isEmpty ?? true))
    }

    /// Copy the helper into Application Support and point Claude Code's status line at it,
    /// keeping any previous status-line command so the helper can chain to it. The settings
    /// file is backed up first.
    public static func install(helperSource: URL, settingsURL: URL = defaultSettingsURL, helperURL: URL = defaultHelperURL,
                               chainURL: URL = defaultChainURL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperSource.path) else { throw InstallError.helperMissing(helperSource.path) }
        try fm.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: helperURL.path) { try fm.removeItem(at: helperURL) }
        try fm.copyItem(at: helperSource, to: helperURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        var settings = try loadSettings(settingsURL)
        if let existing = (settings["statusLine"] as? [String: Any])?["command"] as? String, existing != helperURL.path {
            try existing.write(to: chainURL, atomically: true, encoding: .utf8)
        }
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = helperURL.path
        settings["statusLine"] = statusLine
        try saveSettings(settings, to: settingsURL, backup: true)
    }

    /// Replace the installed helper copy when the app bundle ships a different build of it, so an
    /// app update reaches the status line without reinstalling. Returns true when it was replaced.
    @discardableResult
    public static func refreshHelper(from helperSource: URL, helperURL: URL = defaultHelperURL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperURL.path), fm.fileExists(atPath: helperSource.path) else { return false }
        let installed = try Data(contentsOf: helperURL)
        let bundled = try Data(contentsOf: helperSource)
        guard installed != bundled else { return false }
        let tmp = helperURL.appendingPathExtension("new")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: helperSource, to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(helperURL, withItemAt: tmp)
        return true
    }

    /// Restore the previous status line (or remove ours) and delete the helper and its records.
    public static func remove(settingsURL: URL = defaultSettingsURL, helperURL: URL = defaultHelperURL,
                              chainURL: URL = defaultChainURL, recordURL: URL = defaultRecordURL,
                              historyURL: URL = defaultHistoryURL) throws {
        var settings = try loadSettings(settingsURL)
        if let current = (settings["statusLine"] as? [String: Any])?["command"] as? String, current == helperURL.path {
            if let chain = try? String(contentsOf: chainURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !chain.isEmpty {
                var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
                statusLine["command"] = chain
                settings["statusLine"] = statusLine
            } else {
                settings["statusLine"] = nil
            }
            try saveSettings(settings, to: settingsURL, backup: true)
        }
        for url in [helperURL, chainURL, recordURL, historyURL] { try? FileManager.default.removeItem(at: url) }
    }

    static func loadSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.settingsUnreadable("not a JSON object")
        }
        return obj
    }

    static func saveSettings(_ settings: [String: Any], to url: URL, backup: Bool) throws {
        let fm = FileManager.default
        if backup, fm.fileExists(atPath: url.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? fm.copyItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("settings.json.overhead-backup-\(stamp)"))
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
