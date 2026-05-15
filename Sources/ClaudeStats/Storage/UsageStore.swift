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
    private let queue = DispatchQueue(label: "claude-stats.usagestore")

    /// Bump this when usage_event's shape changes in a way that makes
    /// already-stored rows wrong. The init wipes both tables when an older
    /// version is detected so a full rescan re-populates them.
    /// v2: added (message_id, request_id) for dedup matching ccusage.
    private static let schemaVersion: Int64 = 2

    init(path: String) throws {
        self.db = try SQLite(path: path)
        try Self.migrateIfNeeded(db: db)
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
                cache_read_tokens INTEGER NOT NULL,
                message_id TEXT,
                request_id TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_event(timestamp);
            CREATE INDEX IF NOT EXISTS idx_usage_proj_ts ON usage_event(project_key, timestamp);
            CREATE INDEX IF NOT EXISTS idx_usage_session ON usage_event(session_id);
            -- Partial unique index: dedupe assistant events by (message.id, requestId)
            -- when both are present. Same logic ccusage uses. Rows missing either
            -- key are never duplicates as far as this index is concerned, so
            -- INSERT OR IGNORE always lets them through.
            CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_dedup
                ON usage_event(message_id, request_id)
                WHERE message_id IS NOT NULL AND request_id IS NOT NULL;
            CREATE TABLE IF NOT EXISTS file_state (
                path TEXT PRIMARY KEY,
                mtime INTEGER NOT NULL,
                last_offset INTEGER NOT NULL,
                last_scanned_at INTEGER NOT NULL
            );
        """)
    }

    private static func migrateIfNeeded(db: SQLite) throws {
        let current: Int64 = try {
            // Scope the prepared statement so it's finalized before any DROP
            // — an unfinalized read holds a lock that blocks schema changes.
            let stmt = try db.prepare("PRAGMA user_version")
            _ = try stmt.step()
            return stmt.int(0)
        }()
        if current >= schemaVersion { return }
        // Drop both tables: usage_event rows were double-counted under the old
        // schema (no dedup), and file_state must be cleared so UsageReader
        // rescans every JSONL from offset 0 to rebuild with the new shape.
        try db.exec("""
            DROP TABLE IF EXISTS usage_event;
            DROP TABLE IF EXISTS file_state;
            PRAGMA user_version = \(schemaVersion);
        """)
    }

    func insert(_ entries: [UsageEntry]) throws {
        guard !entries.isEmpty else { return }
        try queue.sync {
            try db.transaction {
                // INSERT OR IGNORE: conflict on idx_usage_dedup silently drops
                // duplicate (message_id, request_id) pairs that Claude Code wrote
                // to multiple JSONL files (subagent forks, session resumes).
                let stmt = try db.prepare("""
                    INSERT OR IGNORE INTO usage_event
                    (timestamp, session_id, project_path, project_key, model,
                     input_tokens, output_tokens, cache_create_tokens, cache_read_tokens,
                     message_id, request_id)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
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
                        .bind(10, e.messageId)
                        .bind(11, e.requestId)
                    _ = try stmt.step()
                }
            }
        }
    }

    func totalTokens(start: Date, end: Date) throws -> Int {
        try queue.sync {
            let stmt = try db.prepare("""
                SELECT COALESCE(SUM(input_tokens + output_tokens + cache_create_tokens + cache_read_tokens), 0)
                FROM usage_event WHERE timestamp BETWEEN ? AND ?
            """)
            stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
            _ = try stmt.step()
            return Int(stmt.int(0))
        }
    }

    func tokenTotals(start: Date, end: Date) throws -> TokenTotals {
        try queue.sync {
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
    }

    func sessionCount(start: Date, end: Date) throws -> Int {
        try queue.sync {
            let stmt = try db.prepare("""
                SELECT COUNT(DISTINCT session_id) FROM usage_event WHERE timestamp BETWEEN ? AND ?
            """)
            stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
            _ = try stmt.step()
            return Int(stmt.int(0))
        }
    }

    func tokensByProject(start: Date, end: Date) throws -> [ProjectRow] {
        try queue.sync {
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
    }

    func tokensByProjectAndModel(start: Date, end: Date) throws -> [ProjectModelRow] {
        try queue.sync {
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
    }

    func tokensByModel(start: Date, end: Date, projectKey: String? = nil) throws -> [ModelRow] {
        try queue.sync {
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
    }

    func recentSessions(limit: Int, projectKey: String, start: Date, end: Date) throws -> [SessionRow] {
        try queue.sync {
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
    }

    func dailyTokens(start: Date, end: Date, calendar: Calendar = .current) throws -> [Date: Int] {
        try queue.sync {
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
    }

    /// Aggregate tokens per (month, model) for a single calendar year.
    /// Months are bucketed in SQLite's local time zone via `strftime`+`'localtime'`,
    /// which matches the process TZ (the same TZ `Calendar.current` uses).
    /// Returns at most 12 × (# models) rows, ordered by month asc.
    func tokensByMonthAndModel(year: Int, calendar: Calendar)
        throws -> [(month: Int, model: String, tokens: TokenTotals)]
    {
        var startComps = DateComponents()
        startComps.year = year
        startComps.month = 1
        startComps.day = 1
        startComps.timeZone = calendar.timeZone
        guard let start = calendar.date(from: startComps),
              let end = calendar.date(byAdding: .year, value: 1, to: start)
        else { return [] }
        return try queue.sync {
            let stmt = try db.prepare("""
                SELECT
                  CAST(strftime('%m', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS month,
                  model,
                  SUM(input_tokens), SUM(output_tokens),
                  SUM(cache_create_tokens), SUM(cache_read_tokens)
                FROM usage_event
                WHERE timestamp >= ? AND timestamp < ?
                GROUP BY month, model
                ORDER BY month
            """)
            stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
            var rows: [(month: Int, model: String, tokens: TokenTotals)] = []
            while try stmt.step() {
                rows.append((
                    month: Int(stmt.int(0)),
                    model: stmt.string(1),
                    tokens: TokenTotals(
                        input: Int(stmt.int(2)),
                        output: Int(stmt.int(3)),
                        cacheCreate: Int(stmt.int(4)),
                        cacheRead: Int(stmt.int(5))
                    )
                ))
            }
            return rows
        }
    }

    /// Aggregate tokens per (year, month, project, model) within an arbitrary
    /// day-bounded range. Year/month are bucketed in SQLite's local time zone
    /// via `strftime`+`'localtime'` (matches process TZ + `Calendar.current`).
    /// Returns rows ordered by (year, month, projectKey, model) ascending.
    func tokensByMonthProjectModel(
        start: Date, end: Date, calendar: Calendar
    ) throws -> [(year: Int, month: Int, projectKey: String, model: String, tokens: TokenTotals)] {
        _ = calendar  // calendar parameter retained for API symmetry; SQLite's localtime uses the process TZ.
        return try queue.sync {
            let stmt = try db.prepare("""
                SELECT
                  CAST(strftime('%Y', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS y,
                  CAST(strftime('%m', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS m,
                  project_key,
                  model,
                  SUM(input_tokens), SUM(output_tokens),
                  SUM(cache_create_tokens), SUM(cache_read_tokens)
                FROM usage_event
                WHERE timestamp >= ? AND timestamp < ?
                GROUP BY y, m, project_key, model
                ORDER BY y, m, project_key, model
            """)
            stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
            var rows: [(year: Int, month: Int, projectKey: String, model: String, tokens: TokenTotals)] = []
            while try stmt.step() {
                rows.append((
                    year: Int(stmt.int(0)),
                    month: Int(stmt.int(1)),
                    projectKey: stmt.string(2),
                    model: stmt.string(3),
                    tokens: TokenTotals(
                        input: Int(stmt.int(4)),
                        output: Int(stmt.int(5)),
                        cacheCreate: Int(stmt.int(6)),
                        cacheRead: Int(stmt.int(7))
                    )
                ))
            }
            return rows
        }
    }

    /// Earliest timestamp across all events, or nil if the table is empty.
    /// Used to determine the earliest year of data for the Months tab's
    /// year stepper bound.
    func earliestTimestamp() throws -> Date? {
        try queue.sync {
            let stmt = try db.prepare("SELECT MIN(timestamp) FROM usage_event")
            _ = try stmt.step()
            let value = stmt.int(0)
            return value == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(value))
        }
    }

    func earliestTimestamp(start: Date, end: Date) throws -> Date? {
        try queue.sync {
            let stmt = try db.prepare("""
                SELECT MIN(timestamp) FROM usage_event WHERE timestamp BETWEEN ? AND ?
            """)
            stmt.bind(1, clampedTimestamp(start)).bind(2, clampedTimestamp(end))
            _ = try stmt.step()
            let value = stmt.int(0)
            return value == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(value))
        }
    }

    func upsertFileState(path: String, mtime: Int64, lastOffset: Int64, scannedAt: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try queue.sync {
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
    }

    func fileState(path: String) throws -> FileState? {
        try queue.sync {
            let stmt = try db.prepare("SELECT mtime, last_offset FROM file_state WHERE path = ?")
            stmt.bind(1, path)
            guard try stmt.step() else { return nil }
            return FileState(mtime: stmt.int(0), lastOffset: stmt.int(1))
        }
    }

    func deleteFileState(path: String) throws {
        try queue.sync {
            let stmt = try db.prepare("DELETE FROM file_state WHERE path = ?")
            stmt.bind(1, path)
            _ = try stmt.step()
        }
    }
}
