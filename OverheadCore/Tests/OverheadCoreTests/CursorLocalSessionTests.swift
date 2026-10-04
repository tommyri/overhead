import Foundation
import SQLite3
import Testing
@testable import OverheadCore

@Suite struct CursorLocalSessionTests {
    /// Build a tiny state.vscdb look-alike with the given ItemTable rows.
    private func makeDB(_ rows: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil)
        for (k, v) in rows {
            sqlite3_exec(db, "INSERT INTO ItemTable VALUES ('\(k)', '\(v)')", nil, nil, nil)
        }
        return url
    }

    private func fakeJWT(sub: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": sub, "exp": 4_102_444_800])
        let b64 = payload.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9.\(b64).sig"
    }

    @Test func buildsCookieValueFromStoredToken() throws {
        let jwt = fakeJWT(sub: "auth0|user_123")
        let db = try makeDB(["cursorAuth/accessToken": jwt, "cursorAuth/stripeMembershipType": "pro_plus"])
        defer { try? FileManager.default.removeItem(at: db) }
        #expect(try CursorLocalSession.importSessionToken(databaseURL: db) == "user_123::\(jwt)")
        #expect(CursorLocalSession.membershipType(databaseURL: db) == "pro_plus")
    }

    /// Cursor keeps its store in WAL mode with the connection open; the newest token may
    /// only exist in the -wal file. Reproduces the "unable to open database file" failure.
    @Test func readsWALModeDatabaseWhileAnotherConnectionHoldsIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-wal-\(UUID().uuidString).vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer {
            sqlite3_close(db)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil)
        let jwt = fakeJWT(sub: "auth0|user_wal")
        sqlite3_exec(db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(jwt)')", nil, nil, nil)
        // No checkpoint: the row lives only in the -wal file, like a freshly refreshed token.
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(try CursorLocalSession.importSessionToken(databaseURL: url) == "user_wal::\(jwt)")
    }

    @Test func reportsMissingSignIn() throws {
        let db = try makeDB(["something/else": "x"])
        defer { try? FileManager.default.removeItem(at: db) }
        #expect(throws: CursorLocalSession.ImportError.self) {
            _ = try CursorLocalSession.importSessionToken(databaseURL: db)
        }
    }

    @Test func decodesURLSafeBase64Subject() {
        #expect(CursorLocalSession.jwtSubject(fakeJWT(sub: "auth0|user_abc")) == "auth0|user_abc")
        #expect(CursorLocalSession.jwtSubject("not-a-jwt") == nil)
    }
}
