import Foundation

/// Persists the last successful fetch for each provider as JSON under
/// ~/Library/Application Support/Overhead/cache/<provider>.json so the app
/// shows data instantly on launch and survives API outages.
public actor UsageCache {
    public struct Snapshot: Codable, Sendable {
        public var fetchedAt: Date
        public var records: [UsageRecord]
        public var code: [CodeActivity]
        public var tools: [ToolActivity]
        public var plan: [PlanSample]
        public var sessions: [SessionActivity]
        public var hourly: [HourlyActivity]
        public init(fetchedAt: Date, records: [UsageRecord], code: [CodeActivity] = [], tools: [ToolActivity] = [], plan: [PlanSample] = [],
                    sessions: [SessionActivity] = [], hourly: [HourlyActivity] = []) {
            self.fetchedAt = fetchedAt
            self.records = records
            self.code = code
            self.tools = tools
            self.plan = plan
            self.sessions = sessions
            self.hourly = hourly
        }
        enum CodingKeys: String, CodingKey { case fetchedAt, records, code, tools, plan, sessions, hourly }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
            records = try c.decode([UsageRecord].self, forKey: .records)
            code = try c.decodeIfPresent([CodeActivity].self, forKey: .code) ?? []
            tools = try c.decodeIfPresent([ToolActivity].self, forKey: .tools) ?? []
            plan = try c.decodeIfPresent([PlanSample].self, forKey: .plan) ?? []
            sessions = try c.decodeIfPresent([SessionActivity].self, forKey: .sessions) ?? []
            hourly = try c.decodeIfPresent([HourlyActivity].self, forKey: .hourly) ?? []
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
            self.directory = AppSupport.directory().appendingPathComponent("cache", isDirectory: true)
        }
    }

    private func url(for provider: ProviderID) -> URL {
        directory.appendingPathComponent("\(provider.rawValue).json")
    }

    public func load(_ provider: ProviderID) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(for: provider)) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public func save(_ provider: ProviderID, records: [UsageRecord], code: [CodeActivity] = [], tools: [ToolActivity] = [], plan: [PlanSample] = [],
                     sessions: [SessionActivity] = [], hourly: [HourlyActivity] = [], fetchedAt: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snap = Snapshot(fetchedAt: fetchedAt, records: records, code: code, tools: tools, plan: plan, sessions: sessions, hourly: hourly)
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


/// ~/Library/Application Support/Overhead, migrating the folder from earlier app names.
public enum AppSupport {
    public static let folderName = "Overhead"
    static let legacyFolderNames = ["LLM Overview"]

    public static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            for legacy in legacyFolderNames {
                let old = base.appendingPathComponent(legacy, isDirectory: true)
                if FileManager.default.fileExists(atPath: old.path) {
                    try? FileManager.default.moveItem(at: old, to: dir)
                    break
                }
            }
        }
        return dir
    }
}
