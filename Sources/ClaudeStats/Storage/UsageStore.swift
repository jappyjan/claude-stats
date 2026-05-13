import Foundation

/// Safely convert a Date's timeIntervalSince1970 to Int64, clamping to Int64 bounds.
private func clampedTimestamp(_ date: Date) -> Int64 {
    let t = date.timeIntervalSince1970
    if t >= Double(Int64.max) { return Int64.max }
    if t <= Double(Int64.min) { return Int64.min }
    return Int64(t)
}

final class UsageStore: @unchecked Sendable {
    struct ProjectRow: Equatable {
        let projectKey: String
        let totalTokens: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreateTokens: Int
        let cacheReadTokens: Int
        let sessionCount: Int
    }
    struct ModelRow: Equatable {
        let model: String
        let totalTokens: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreateTokens: Int
        let cacheReadTokens: Int
    }
    struct TokenTotals: Equatable {
        let input: Int, output: Int, cacheCreate: Int, cacheRead: Int
        var total: Int { input + output + cacheCreate + cacheRead }
    }
    struct FileState: Equatable {
        let mtime: Int64
        let lastOffset: Int64
    }
    struct SessionRow: Equatable {
        let sessionId: String
        let projectKey: String
        let firstTimestamp: Date
        let lastTimestamp: Date
        let totalTokens: Int
    }
    struct ProjectModelRow: Equatable {
        let projectKey: String
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreateTokens: Int
        let cacheReadTokens: Int
    }

    private let db: SQLite

    init(path: String) throws {
        self.db = try SQLite(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS usage_event (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                session_id TEXT NOT NULL,
                project_path TEXT NOT NULL,
                project_key TEXT NOT NULL,
                model TEXT NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_create_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_event(timestamp);
            CREATE INDEX IF NOT EXISTS idx_usage_proj_ts ON usage_event(project_key, timestamp);
            CREATE INDEX IF NOT EXISTS idx_usage_session ON usage_event(session_id);
            CREATE TABLE IF NOT EXISTS file_state (
                path TEXT PRIMARY KEY,
                mtime INTEGER NOT NULL,
                last_offset INTEGER NOT NULL,
                last_scanned_at INTEGER NOT NULL
            );
        """)
    }

    func insert(_ entries: [UsageEntry]) throws {
        guard !entries.isEmpty else { return }
        try db.transaction {
            let stmt = try db.prepare("""
                INSERT INTO usage_event
                (timestamp, session_id, project_path, project_key, model,
                 input_tokens, output_tokens, cache_create_tokens, cache_read_tokens)
                VALUES (?,?,?,?,?,?,?,?,?)
            """)
            for e in entries {
                stmt.reset()
                stmt
                    .bind(1, Int64(e.timestamp.timeIntervalSince1970))
                    .bind(2, e.sessionId)
                    .bind(3, e.projectPath)
                    .bind(4, ProjectName.canonicalKey(for: e.projectPath))
                    .bind(5, e.model)
                    .bind(6, e.inputTokens)
                    .bind(7, e.outputTokens)
                    .bind(8, e.cacheCreationTokens)
                    .bind(9, e.cacheReadTokens)
                _ = try stmt.step()
            }
        }
    }

    func totalTokens(start: Date, end: Date) throws -> Int {
        let stmt = try db.prepare("""
            SELECT COALESCE(SUM(input_tokens + output_tokens + cache_create_tokens + cache_read_tokens), 0)
            FROM usage_event WHERE timestamp BETWEEN ? AND ?
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        _ = try stmt.step()
        return Int(stmt.int(0))
    }

    /// Tokens weighted for subscription-limit accounting. Matches Anthropic
    /// API cost weighting: cache_read counts at 10% of full, other token
    /// types at 100%. Use `totalTokens(start:end:)` for cost/overview
    /// figures — the limit accounting needs a different denominator.
    func limitTokens(start: Date, end: Date) throws -> Int {
        let stmt = try db.prepare("""
            SELECT COALESCE(SUM(input_tokens + output_tokens + cache_create_tokens + cache_read_tokens / 10), 0)
            FROM usage_event WHERE timestamp BETWEEN ? AND ?
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        _ = try stmt.step()
        return Int(stmt.int(0))
    }

    func tokenTotals(start: Date, end: Date) throws -> TokenTotals {
        let stmt = try db.prepare("""
            SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(cache_create_tokens),0), COALESCE(SUM(cache_read_tokens),0)
            FROM usage_event WHERE timestamp BETWEEN ? AND ?
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        _ = try stmt.step()
        return TokenTotals(
            input: Int(stmt.int(0)), output: Int(stmt.int(1)),
            cacheCreate: Int(stmt.int(2)), cacheRead: Int(stmt.int(3))
        )
    }

    func sessionCount(start: Date, end: Date) throws -> Int {
        let stmt = try db.prepare("""
            SELECT COUNT(DISTINCT session_id) FROM usage_event WHERE timestamp BETWEEN ? AND ?
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        _ = try stmt.step()
        return Int(stmt.int(0))
    }

    func tokensByProject(start: Date, end: Date) throws -> [ProjectRow] {
        let stmt = try db.prepare("""
            SELECT project_key,
                   SUM(input_tokens + output_tokens + cache_create_tokens + cache_read_tokens),
                   SUM(input_tokens), SUM(output_tokens),
                   SUM(cache_create_tokens), SUM(cache_read_tokens),
                   COUNT(DISTINCT session_id)
            FROM usage_event WHERE timestamp BETWEEN ? AND ?
            GROUP BY project_key ORDER BY 2 DESC
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        var rows: [ProjectRow] = []
        while try stmt.step() {
            rows.append(ProjectRow(
                projectKey: stmt.string(0),
                totalTokens: Int(stmt.int(1)),
                inputTokens: Int(stmt.int(2)),
                outputTokens: Int(stmt.int(3)),
                cacheCreateTokens: Int(stmt.int(4)),
                cacheReadTokens: Int(stmt.int(5)),
                sessionCount: Int(stmt.int(6))
            ))
        }
        return rows
    }

    func tokensByProjectAndModel(start: Date, end: Date) throws -> [ProjectModelRow] {
        let stmt = try db.prepare("""
            SELECT project_key, model,
                   SUM(input_tokens), SUM(output_tokens),
                   SUM(cache_create_tokens), SUM(cache_read_tokens)
            FROM usage_event WHERE timestamp BETWEEN ? AND ?
            GROUP BY project_key, model
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        var rows: [ProjectModelRow] = []
        while try stmt.step() {
            rows.append(ProjectModelRow(
                projectKey: stmt.string(0), model: stmt.string(1),
                inputTokens: Int(stmt.int(2)), outputTokens: Int(stmt.int(3)),
                cacheCreateTokens: Int(stmt.int(4)), cacheReadTokens: Int(stmt.int(5))
            ))
        }
        return rows
    }

    func tokensByModel(start: Date, end: Date, projectKey: String? = nil) throws -> [ModelRow] {
        let where_ = projectKey == nil
            ? "timestamp BETWEEN ? AND ?"
            : "timestamp BETWEEN ? AND ? AND project_key = ?"
        let stmt = try db.prepare("""
            SELECT model,
                   SUM(input_tokens + output_tokens + cache_create_tokens + cache_read_tokens),
                   SUM(input_tokens), SUM(output_tokens),
                   SUM(cache_create_tokens), SUM(cache_read_tokens)
            FROM usage_event WHERE \(where_)
            GROUP BY model ORDER BY 2 DESC
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        if let projectKey = projectKey { stmt.bind(3, projectKey) }
        var rows: [ModelRow] = []
        while try stmt.step() {
            rows.append(ModelRow(
                model: stmt.string(0),
                totalTokens: Int(stmt.int(1)),
                inputTokens: Int(stmt.int(2)),
                outputTokens: Int(stmt.int(3)),
                cacheCreateTokens: Int(stmt.int(4)),
                cacheReadTokens: Int(stmt.int(5))
            ))
        }
        return rows
    }

    func recentSessions(limit: Int, projectKey: String, start: Date, end: Date) throws -> [SessionRow] {
        let stmt = try db.prepare("""
            SELECT session_id, project_key, MIN(timestamp), MAX(timestamp),
                   SUM(input_tokens + output_tokens + cache_create_tokens + cache_read_tokens)
            FROM usage_event WHERE timestamp BETWEEN ? AND ? AND project_key = ?
            GROUP BY session_id ORDER BY MAX(timestamp) DESC LIMIT ?
        """)
        stmt.bind(1, clampedTimestamp(start))
            .bind(2, clampedTimestamp(end))
            .bind(3, projectKey)
            .bind(4, limit)
        var rows: [SessionRow] = []
        while try stmt.step() {
            rows.append(SessionRow(
                sessionId: stmt.string(0),
                projectKey: stmt.string(1),
                firstTimestamp: Date(timeIntervalSince1970: TimeInterval(stmt.int(2))),
                lastTimestamp: Date(timeIntervalSince1970: TimeInterval(stmt.int(3))),
                totalTokens: Int(stmt.int(4))
            ))
        }
        return rows
    }

    func dailyTokens(start: Date, end: Date, calendar: Calendar = .current) throws -> [Date: Int] {
        // Pull events in range, group by local-day in Swift (SQLite doesn't know timezone).
        let stmt = try db.prepare("""
            SELECT timestamp, input_tokens + output_tokens + cache_create_tokens + cache_read_tokens
            FROM usage_event WHERE timestamp BETWEEN ? AND ?
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        var result: [Date: Int] = [:]
        while try stmt.step() {
            let ts = Date(timeIntervalSince1970: TimeInterval(stmt.int(0)))
            let day = calendar.startOfDay(for: ts)
            result[day, default: 0] += Int(stmt.int(1))
        }
        return result
    }

    func earliestTimestamp(start: Date, end: Date) throws -> Date? {
        let stmt = try db.prepare("""
            SELECT MIN(timestamp) FROM usage_event WHERE timestamp BETWEEN ? AND ?
        """)
        stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
        _ = try stmt.step()
        let value = stmt.int(0)
        return value == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(value))
    }

    func upsertFileState(path: String, mtime: Int64, lastOffset: Int64, scannedAt: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        let stmt = try db.prepare("""
            INSERT INTO file_state(path, mtime, last_offset, last_scanned_at)
            VALUES (?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                mtime=excluded.mtime,
                last_offset=excluded.last_offset,
                last_scanned_at=excluded.last_scanned_at
        """)
        stmt.bind(1, path).bind(2, mtime).bind(3, lastOffset).bind(4, scannedAt)
        _ = try stmt.step()
    }

    func fileState(path: String) throws -> FileState? {
        let stmt = try db.prepare("SELECT mtime, last_offset FROM file_state WHERE path = ?")
        stmt.bind(1, path)
        guard try stmt.step() else { return nil }
        return FileState(mtime: stmt.int(0), lastOffset: stmt.int(1))
    }

    func deleteFileState(path: String) throws {
        let stmt = try db.prepare("DELETE FROM file_state WHERE path = ?")
        stmt.bind(1, path)
        _ = try stmt.step()
    }
}
