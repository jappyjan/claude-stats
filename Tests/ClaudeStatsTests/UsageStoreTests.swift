import XCTest
@testable import ClaudeStats

final class UsageStoreTests: XCTestCase {
    private func makeStore() throws -> UsageStore {
        try UsageStore(path: ":memory:")
    }

    private func entry(
        ts: TimeInterval,
        project: String = "/p1",
        model: String = "claude-opus-4-7",
        input: Int = 100, output: Int = 0,
        cacheCreate: Int = 0, cacheRead: Int = 0,
        session: String = "s1"
    ) -> UsageEntry {
        UsageEntry(
            timestamp: Date(timeIntervalSince1970: ts),
            sessionId: session,
            projectPath: project,
            model: model,
            inputTokens: input, outputTokens: output,
            cacheCreationTokens: cacheCreate, cacheReadTokens: cacheRead
        )
    }

    func testInsertAndTotalTokens() throws {
        let store = try makeStore()
        try store.insert([
            entry(ts: 1000, input: 10, output: 20, cacheCreate: 5, cacheRead: 100),
            entry(ts: 2000, input: 1, output: 2, cacheCreate: 0, cacheRead: 0),
        ])
        let total = try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(total, 138)
    }

    func testTokensByProjectGroupsByCanonicalKey() throws {
        let store = try makeStore()
        try store.insert([
            entry(ts: 1000, project: "/Users/jappy/code/foo/Bar", input: 100),
            entry(ts: 1100, project: "/Users/jappy/code/foo/Bar/.claude/worktrees/x", input: 50),
            entry(ts: 1200, project: "/Users/jappy/code/foo/Other", input: 30),
        ])
        let rows = try store.tokensByProject(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 9999))
        let bar = rows.first { $0.projectKey == "/Users/jappy/code/foo/Bar" }
        XCTAssertEqual(bar?.totalTokens, 150)
        XCTAssertEqual(rows.count, 2)
    }

    func testTokensByModel() throws {
        let store = try makeStore()
        try store.insert([
            entry(ts: 1000, model: "claude-opus-4-7", input: 100, output: 50),
            entry(ts: 1100, model: "claude-sonnet-4-6", input: 10, output: 5),
            entry(ts: 1200, model: "claude-opus-4-7", input: 30, output: 15),
        ])
        let rows = try store.tokensByModel(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 9999))
        let opus = rows.first { $0.model == "claude-opus-4-7" }
        XCTAssertEqual(opus?.totalTokens, 195)
        XCTAssertEqual(rows.count, 2)
    }

    func testFileStateRoundTrip() throws {
        let store = try makeStore()
        try store.upsertFileState(path: "/x.jsonl", mtime: 100, lastOffset: 500)
        let fs = try store.fileState(path: "/x.jsonl")
        XCTAssertEqual(fs?.mtime, 100)
        XCTAssertEqual(fs?.lastOffset, 500)
    }

    func testSessionsCountInRange() throws {
        let store = try makeStore()
        try store.insert([
            entry(ts: 1000, session: "a"),
            entry(ts: 1100, session: "a"),
            entry(ts: 1200, session: "b"),
        ])
        let count = try store.sessionCount(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 9999))
        XCTAssertEqual(count, 2)
    }

    func testCacheReadAndCreateTotals() throws {
        let store = try makeStore()
        try store.insert([
            entry(ts: 1000, input: 10, output: 5, cacheCreate: 100, cacheRead: 200),
            entry(ts: 1100, input: 1, output: 1, cacheCreate: 50, cacheRead: 800),
        ])
        let totals = try store.tokenTotals(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 9999))
        XCTAssertEqual(totals.input, 11)
        XCTAssertEqual(totals.output, 6)
        XCTAssertEqual(totals.cacheCreate, 150)
        XCTAssertEqual(totals.cacheRead, 1000)
    }

    func testDailyTokensGroupsByLocalDay() throws {
        let store = try makeStore()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 2026-05-10 12:00 UTC and 2026-05-10 23:30 UTC are the same UTC day.
        // 2026-05-11 00:30 UTC is the next day.
        let day1Noon = Date(timeIntervalSince1970: 1778414400)   // 2026-05-10 12:00 UTC
        let day1Late = Date(timeIntervalSince1970: 1778455800)   // 2026-05-10 23:30 UTC
        let day2Early = Date(timeIntervalSince1970: 1778459400)  // 2026-05-11 00:30 UTC
        try store.insert([
            UsageEntry(timestamp: day1Noon, sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 10, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: day1Late, sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 5, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: day2Early, sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 7, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let result = try store.dailyTokens(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 2_000_000_000),
            calendar: utc
        )
        let day1Midnight = Date(timeIntervalSince1970: 1778371200)  // 2026-05-10 00:00 UTC
        let day2Midnight = Date(timeIntervalSince1970: 1778457600)  // 2026-05-11 00:00 UTC
        XCTAssertEqual(result[day1Midnight], 15)
        XCTAssertEqual(result[day2Midnight], 7)
        XCTAssertEqual(result.count, 2)
    }

    func testTokensByMonthAndModelGroupsByMonth() throws {
        let store = try makeStore()
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        try store.insert([
            UsageEntry(timestamp: mkDate(2026, 1, 10), sessionId: "s", projectPath: "/p",
                       model: "claude-opus-4-7", inputTokens: 100, outputTokens: 50,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 1, 20), sessionId: "s", projectPath: "/p",
                       model: "claude-sonnet-4-6", inputTokens: 30, outputTokens: 10,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 3, 5), sessionId: "s", projectPath: "/p",
                       model: "claude-opus-4-7", inputTokens: 200, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let rows = try store.tokensByMonthAndModel(year: 2026, calendar: cal)
        XCTAssertEqual(rows.count, 3)
        let janOpus = rows.first { $0.month == 1 && $0.model == "claude-opus-4-7" }
        XCTAssertEqual(janOpus?.tokens.input, 100)
        XCTAssertEqual(janOpus?.tokens.output, 50)
        let janSonnet = rows.first { $0.month == 1 && $0.model == "claude-sonnet-4-6" }
        XCTAssertEqual(janSonnet?.tokens.input, 30)
        let marOpus = rows.first { $0.month == 3 && $0.model == "claude-opus-4-7" }
        XCTAssertEqual(marOpus?.tokens.input, 200)
    }

    func testTokensByMonthAndModelEmptyYearReturnsEmpty() throws {
        let store = try makeStore()
        let cal = Calendar.current
        let rows = try store.tokensByMonthAndModel(year: 2026, calendar: cal)
        XCTAssertTrue(rows.isEmpty)
    }

    func testTokensByMonthAndModelExcludesOtherYears() throws {
        let store = try makeStore()
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        try store.insert([
            UsageEntry(timestamp: mkDate(2025, 12, 31, 23), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 999, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 6, 15), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 100, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2027, 1, 1, 1), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 888, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let rows = try store.tokensByMonthAndModel(year: 2026, calendar: cal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].month, 6)
        XCTAssertEqual(rows[0].tokens.input, 100)
    }

    func testTokensByMonthAndModelLocalTimeBoundary() throws {
        let store = try makeStore()
        let cal = Calendar.current
        // 2026-01-01 00:30 in the local TZ (whatever the process TZ is).
        let jan1Local = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 30))!
        try store.insert([
            UsageEntry(timestamp: jan1Local, sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 42, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0)
        ])
        let rowsIn2026 = try store.tokensByMonthAndModel(year: 2026, calendar: cal)
        XCTAssertEqual(rowsIn2026.count, 1)
        XCTAssertEqual(rowsIn2026[0].month, 1)
        XCTAssertEqual(rowsIn2026[0].tokens.input, 42)
        let rowsIn2025 = try store.tokensByMonthAndModel(year: 2025, calendar: cal)
        XCTAssertTrue(rowsIn2025.isEmpty)
    }

    func testEarliestTimestampNoArgs() throws {
        let store = try makeStore()
        XCTAssertNil(try store.earliestTimestamp())
        try store.insert([
            entry(ts: 5_000, input: 1),
            entry(ts: 1_000, input: 1),
            entry(ts: 3_000, input: 1),
        ])
        let earliest = try store.earliestTimestamp()
        XCTAssertEqual(earliest, Date(timeIntervalSince1970: 1_000))
    }

    func testTokensByMonthProjectModelGroups() throws {
        let store = try makeStore()
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        try store.insert([
            UsageEntry(timestamp: mkDate(2026, 1, 10), sessionId: "s", projectPath: "/p1",
                       model: "claude-opus-4-7", inputTokens: 100, outputTokens: 50,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 1, 20), sessionId: "s", projectPath: "/p1",
                       model: "claude-opus-4-7", inputTokens: 30, outputTokens: 10,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 1, 25), sessionId: "s", projectPath: "/p2",
                       model: "claude-sonnet-4-6", inputTokens: 5, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 3, 1), sessionId: "s", projectPath: "/p1",
                       model: "claude-opus-4-7", inputTokens: 200, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let start = mkDate(2026, 1, 1, 0)
        let end = mkDate(2027, 1, 1, 0)
        let rows = try store.tokensByMonthProjectModel(start: start, end: end, calendar: cal)
        XCTAssertEqual(rows.count, 3)
        let janP1Opus = rows.first { $0.year == 2026 && $0.month == 1 && $0.projectKey == "/p1" && $0.model == "claude-opus-4-7" }
        XCTAssertEqual(janP1Opus?.tokens.input, 130)
        XCTAssertEqual(janP1Opus?.tokens.output, 60)
        let janP2Sonnet = rows.first { $0.year == 2026 && $0.month == 1 && $0.projectKey == "/p2" && $0.model == "claude-sonnet-4-6" }
        XCTAssertEqual(janP2Sonnet?.tokens.input, 5)
        let marP1Opus = rows.first { $0.year == 2026 && $0.month == 3 && $0.projectKey == "/p1" && $0.model == "claude-opus-4-7" }
        XCTAssertEqual(marP1Opus?.tokens.input, 200)
    }

    func testTokensByMonthProjectModelExcludesOutOfRange() throws {
        let store = try makeStore()
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        try store.insert([
            UsageEntry(timestamp: mkDate(2026, 1, 14, 23), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 1, 15, 1), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 2, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 5, 15, 23), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 4, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 5, 16, 1), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 8, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        // Range: 2026-01-15 00:00 (inclusive) to 2026-05-16 00:00 (exclusive).
        let start = mkDate(2026, 1, 15, 0)
        let end = mkDate(2026, 5, 16, 0)
        let rows = try store.tokensByMonthProjectModel(start: start, end: end, calendar: cal)
        // Should include the Jan 15 01:00 event (input=2) and May 15 23:00 event (input=4); exclude the others.
        let totalInput = rows.reduce(0) { $0 + $1.tokens.input }
        XCTAssertEqual(totalInput, 6)
    }
}
