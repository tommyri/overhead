import Foundation

/// Persists the last successful fetch for each provider as JSON under
/// ~/Library/Application Support/LLM Overview/cache/<provider>.json so the app
/// shows data instantly on launch and survives API outages.
public actor UsageCache {
    public struct Snapshot: Codable, Sendable {
        public var fetchedAt: Date
        public var records: [UsageRecord]
        public init(fetchedAt: Date, records: [UsageRecord]) {
            self.fetchedAt = fetchedAt
            self.records = records
        }
    }

    private let directory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("LLM Overview/cache", isDirectory: true)
        }
    }

    private func url(for provider: ProviderID) -> URL {
        directory.appendingPathComponent("\(provider.rawValue).json")
    }

    public func load(_ provider: ProviderID) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(for: provider)) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public func save(_ provider: ProviderID, records: [UsageRecord], fetchedAt: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snap = Snapshot(fetchedAt: fetchedAt, records: records)
        let data = try encoder.encode(snap)
        try data.write(to: url(for: provider), options: .atomic)
    }

    public func clear(_ provider: ProviderID) {
        try? FileManager.default.removeItem(at: url(for: provider))
    }

    public func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
