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
}
