import Foundation

/// Plan-window samples taken by the app itself on each refresh, for providers whose own data
/// has no history (Cursor's included-usage budget, for instance). One JSON file per provider
/// under `~/Library/Application Support/Overhead/plan-history/`. Only used while the app runs,
/// so gaps are expected; the chart draws straight lines across them.
public actor PlanHistoryStore {
    private let directory: URL
    private var loaded: [ProviderID: [PlanSample]] = [:]
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public init(directory: URL? = nil) {
        self.directory = directory ?? AppSupport.directory().appendingPathComponent("plan-history", isDirectory: true)
    }

    private func url(for provider: ProviderID) -> URL { directory.appendingPathComponent("\(provider.rawValue).json") }

    public func samples(for provider: ProviderID) -> [PlanSample] {
        if let s = loaded[provider] { return s }
        let s = (try? Data(contentsOf: url(for: provider))).flatMap { try? decoder.decode([PlanSample].self, from: $0) } ?? []
        loaded[provider] = s
        return s
    }

    /// Append one sample per window whose value or reset time changed since the last sample for
    /// that window, or whose last sample is older than `minInterval`. Samples older than
    /// `retention` are dropped. Returns how many samples were added.
    @discardableResult
    public func record(_ status: PlanStatus, for provider: ProviderID, now: Date = Date(),
                       minInterval: TimeInterval = 6 * 3600, retention: TimeInterval = 90 * 86_400) -> Int {
        var all = samples(for: provider)
        let cutoff = now.addingTimeInterval(-retention)
        all.removeAll { $0.observedAt < cutoff }
        var added = 0
        for w in status.windows {
            let last = all.last { $0.window == w.title }
            if let last, last.usedPercent == w.usedPercent, last.resetsAt == w.resetsAt,
               status.observedAt.timeIntervalSince(last.observedAt) < minInterval { continue }
            if let last, last.observedAt >= status.observedAt { continue }
            all.append(PlanSample(provider: provider, observedAt: status.observedAt, window: w.title, usedPercent: w.usedPercent, resetsAt: w.resetsAt))
            added += 1
        }
        guard added > 0 || all.count != samples(for: provider).count else { return 0 }
        all.sort { $0.observedAt < $1.observedAt }
        loaded[provider] = all
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(all) { try? data.write(to: url(for: provider), options: .atomic) }
        return added
    }

    public func clear(_ provider: ProviderID) {
        loaded[provider] = nil
        try? FileManager.default.removeItem(at: url(for: provider))
    }
}
