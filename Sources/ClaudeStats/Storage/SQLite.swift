import Foundation
import SQLite3

/// Thin error-throwing wrapper over the C SQLite API.
final class SQLite {
    enum DBError: Error { case open(String); case prepare(String); case step(String); case exec(String) }

    private let handle: OpaquePointer
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var h: OpaquePointer?
        let rc = sqlite3_open(path, &h)
        guard rc == SQLITE_OK, let h = h else {
            throw DBError.open(String(cString: sqlite3_errstr(rc)))
        }
        self.handle = h
        sqlite3_exec(h, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        defer { sqlite3_free(err) }
        if rc != SQLITE_OK {
            throw DBError.exec(err.map { String(cString: $0) } ?? "exec failed")
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt = stmt else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(stmt: stmt, db: handle)
    }

    final class Statement {
        private let stmt: OpaquePointer
        private let db: OpaquePointer
        init(stmt: OpaquePointer, db: OpaquePointer) { self.stmt = stmt; self.db = db }
        deinit { sqlite3_finalize(stmt) }

        @discardableResult
        func bind(_ index: Int32, _ value: Int64) -> Statement { sqlite3_bind_int64(stmt, index, value); return self }
        @discardableResult
        func bind(_ index: Int32, _ value: Int) -> Statement { sqlite3_bind_int64(stmt, index, Int64(value)); return self }
        @discardableResult
        func bind(_ index: Int32, _ value: String) -> Statement {
            sqlite3_bind_text(stmt, index, value, -1, SQLite.SQLITE_TRANSIENT); return self
        }
        @discardableResult
        func bind(_ index: Int32, _ value: String?) -> Statement {
            if let value = value {
                sqlite3_bind_text(stmt, index, value, -1, SQLite.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, index)
            }
            return self
        }

        func step() throws -> Bool {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { return true }
            if rc == SQLITE_DONE { return false }
            throw DBError.step(String(cString: sqlite3_errmsg(db)))
        }

        func reset() { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }

        func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
        func string(_ col: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, col) else { return "" }
            return String(cString: c)
        }
    }

    func transaction(_ work: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try work()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
