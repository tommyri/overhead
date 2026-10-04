import Foundation
import SQLite3

/// Reads the sign-in session the Cursor desktop app keeps in its own SQLite state store, so
/// the user can reuse it for cursor.com's dashboard endpoints without copying a cookie from
/// the browser. Only invoked when the user presses "Import from Cursor app" in Settings.
public enum CursorLocalSession {
    public enum ImportError: Error, LocalizedError {
        case notFound
        case cannotOpen(String)
        case noToken
        case malformedToken

        public var errorDescription: String? {
            switch self {
            case .notFound: return "Cursor's state database was not found. Is Cursor installed and have you signed in?"
            case .cannotOpen(let m): return "Could not open Cursor's state database: \(m)"
            case .noToken: return "Cursor is not signed in (no access token stored)."
            case .malformedToken: return "Cursor's stored token has an unexpected format."
            }
        }
    }

    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Returns the value for the `WorkosCursorSessionToken` cookie: `<userId>::<accessToken>`,
    /// where userId is the JWT subject after its identity-provider prefix ("auth0|user_x" → "user_x").
    public static func importSessionToken(databaseURL: URL = defaultDatabaseURL) throws -> String {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw ImportError.notFound }
        var token = try readItem(key: "cursorAuth/accessToken", databaseURL: databaseURL) ?? ""
        // Some versions store the value JSON-quoted.
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard !token.isEmpty else { throw ImportError.noToken }
        guard let sub = jwtSubject(token) else { throw ImportError.malformedToken }
        let userId = sub.split(separator: "|").last.map(String.init) ?? sub
        return "\(userId)::\(token)"
    }

    /// Plan name Cursor caches locally (e.g. "pro", "pro_plus", "ultra"), if present.
    public static func membershipType(databaseURL: URL = defaultDatabaseURL) -> String? {
        try? readItem(key: "cursorAuth/stripeMembershipType", databaseURL: databaseURL)
    }

    /// Daily AI code statistics Cursor keeps locally (`aiCodeTracking.dailyStats.*`), one per day.
    public struct DailyCodeStats: Decodable, Sendable {
        public let date: String?
        public let tabSuggestedLines: Int?
        public let tabAcceptedLines: Int?
        public let composerSuggestedLines: Int?
        public let composerAcceptedLines: Int?
    }

    public static func dailyCodeStats(databaseURL: URL = defaultDatabaseURL) throws -> [DailyCodeStats] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let rows = try readItems(prefix: "aiCodeTracking.dailyStats.", databaseURL: databaseURL)
        let decoder = JSONDecoder()
        return rows.compactMap { key, value in
            guard var stats = try? decoder.decode(DailyCodeStats.self, from: Data(value.utf8)) else { return nil }
            if stats.date == nil, let last = key.split(separator: ".").last { stats = DailyCodeStats(date: String(last), tabSuggestedLines: stats.tabSuggestedLines, tabAcceptedLines: stats.tabAcceptedLines, composerSuggestedLines: stats.composerSuggestedLines, composerAcceptedLines: stats.composerAcceptedLines) }
            return stats
        }
    }

    // MARK: SQLite

    /// Cursor keeps the store in WAL mode with its connection open. We snapshot the main file
    /// *and* its write-ahead log into a private temp folder and open that copy read-write:
    /// read-only would fail with "unable to open database file" because SQLite cannot create
    /// the -shm side file, and without the -wal copy a freshly refreshed token could be missed.
    /// Cursor's own files are never opened for writing.
    static func readItem(key: String, databaseURL: URL) throws -> String? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("overhead-cursor-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let copy = dir.appendingPathComponent("state.vscdb")
        try fm.copyItem(at: databaseURL, to: copy)
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        if fm.fileExists(atPath: wal.path) {
            try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw ImportError.cannotOpen(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImportError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        // Value may be TEXT or a BLOB holding UTF-8.
        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
        default:
            guard let cstr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: cstr)
        }
    }

    /// All ItemTable rows whose key starts with `prefix`, read from a private snapshot.
    static func readItems(prefix: String, databaseURL: URL) throws -> [(key: String, value: String)] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("overhead-cursor-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("state.vscdb")
        try fm.copyItem(at: databaseURL, to: copy)
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        if fm.fileExists(atPath: wal.path) { try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db); throw ImportError.cannotOpen(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable WHERE key LIKE ? ESCAPE '\\'", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImportError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let pattern = prefix.replacingOccurrences(of: "_", with: "\\_") + "%"
        sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let k = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: k)
            let value: String?
            if sqlite3_column_type(stmt, 1) == SQLITE_BLOB, let bytes = sqlite3_column_blob(stmt, 1) {
                value = String(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1))), encoding: .utf8)
            } else if let v = sqlite3_column_text(stmt, 1) {
                value = String(cString: v)
            } else { value = nil }
            if let value { out.append((key, value)) }
        }
        return out
    }

    /// Decode the `sub` claim of a JWT without verifying it (we only need the user id).
    static func jwtSubject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }
}
