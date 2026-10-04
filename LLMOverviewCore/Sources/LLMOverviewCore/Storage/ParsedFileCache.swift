import Foundation

/// Incremental parse cache for log directories. Each file is parsed once and its extracted
/// entries stored alongside the file's size and mtime; on later runs only changed or new
/// files are re-read. Persisted as JSON under Application Support so launches are fast.
public actor ParsedFileCache<Entry: Codable & Sendable> {
    public struct FileState: Codable, Sendable {
        public var size: UInt64
        public var modified: Date
        public var entries: [Entry]
    }

    private var states: [String: FileState] = [:]
    private var loaded = false
    private let storeURL: URL

    public init(name: String, directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LLM Overview/index", isDirectory: true)
        storeURL = dir.appendingPathComponent("\(name).json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        states = (try? d.decode([String: FileState].self, from: data)) ?? [:]
    }

    private func persist() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(states) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Returns the union of entries across `files`, re-parsing only files whose size or
    /// mtime changed. Files that no longer exist are dropped from the cache.
    public func entries(
        for files: [URL],
        maxConcurrency: Int = 4,
        parse: @escaping @Sendable (URL) throws -> [Entry]
    ) async -> [Entry] {
        loadIfNeeded()
        let fm = FileManager.default
        var stale: [(URL, UInt64, Date)] = []
        var keep: Set<String> = []

        for url in files {
            let path = url.path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            keep.insert(path)
            if let s = states[path], s.size == size, s.modified == mtime { continue }
            stale.append((url, size, mtime))
        }

        // Drop vanished files.
        for key in states.keys where !keep.contains(key) { states[key] = nil }

        // Parse changed files with bounded parallelism.
        var parsed: [(String, FileState)] = []
        var iterator = stale.makeIterator()
        await withTaskGroup(of: (String, FileState)?.self) { group in
            var running = 0
            func addNext() {
                guard let (url, size, mtime) = iterator.next() else { return }
                running += 1
                group.addTask {
                    guard let entries = try? parse(url) else { return nil }
                    return (url.path, FileState(size: size, modified: mtime, entries: entries))
                }
            }
            for _ in 0..<maxConcurrency { addNext() }
            while running > 0, let result = await group.next() {
                running -= 1
                if let result { parsed.append(result) }
                addNext()
            }
        }
        for (path, state) in parsed { states[path] = state }
        if !parsed.isEmpty || states.count != keep.count { persist() }

        return states.values.flatMap(\.entries)
    }

    public func reset() {
        states = [:]
        loaded = true
        try? FileManager.default.removeItem(at: storeURL)
    }
}

/// Shared helpers for the local log parsers.
enum LogFiles {
    static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Recursively list files under `root` whose name matches `predicate`.
    static func enumerate(_ root: URL, where predicate: (URL) -> Bool) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if predicate(url) { out.append(url) }
        }
        return out
    }

    /// Enumerate including hidden directories (needed for nested ".claude" folders).
    static func enumerateIncludingHidden(_ root: URL, where predicate: (URL) -> Bool) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants]) else { return out }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if predicate(url) { out.append(url) }
        }
        return out
    }

    /// Iterate over non-empty lines of a file as `Data` slices without copying the whole
    /// file into a String.
    static func forEachLine(in url: URL, _ body: (Data) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start { try body(data[start..<end]) }
            start = end + 1
        }
    }

    static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func parseDate(_ s: String, fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}

extension Data {
    /// Cheap substring test used to skip lines before JSON decoding.
    func containsASCII(_ needle: String) -> Bool {
        range(of: Data(needle.utf8)) != nil
    }
}
