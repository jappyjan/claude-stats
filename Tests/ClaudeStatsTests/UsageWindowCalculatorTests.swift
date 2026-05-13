import XCTest
@testable import ClaudeStats

final class UsageWindowCalculatorTests: XCTestCase {
    private func makeStore() throws -> UsageStore {
        try UsageStore(path: ":memory:")
    }

    private func entry(ts: TimeInterval, tokens: Int) -> UsageEntry {
        UsageEntry(
            timestamp: Date(timeIntervalSince1970: ts),
            sessionId: "s", projectPath: "/p", model: "m",
            inputTokens: tokens, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0
        )
    }

    func testFiveHourSumsLastFiveHours() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try store.insert([
            entry(ts: now.timeIntervalSince1970 - 3600,      tokens: 100),  // 1h ago — in
            entry(ts: now.timeIntervalSince1970 - 4 * 3600,  tokens: 50),   // 4h ago — in
            entry(ts: now.timeIntervalSince1970 - 6 * 3600,  tokens: 1000), // 6h ago — out
            entry(ts: now.timeIntervalSince1970 - 5 * 3600,  tokens: 7),    // 5h on boundary — in (inclusive)
        ])
        let calc = UsageWindowCalculator(store: store)
        XCTAssertEqual(calc.tokens(in: .fiveHour, endingAt: now), 157)
    }

    func testSevenDaySumsLastSevenDays() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 10_000_000)
        try store.insert([
            entry(ts: now.timeIntervalSince1970 - 86400,        tokens: 200), // 1d ago — in
            entry(ts: now.timeIntervalSince1970 - 6 * 86400,    tokens: 50),  // 6d ago — in
            entry(ts: now.timeIntervalSince1970 - 8 * 86400,    tokens: 1000) // 8d ago — out
        ])
        let calc = UsageWindowCalculator(store: store)
        XCTAssertEqual(calc.tokens(in: .sevenDay, endingAt: now), 250)
    }

    func testEmptyStoreReturnsZero() throws {
        let store = try makeStore()
        let calc = UsageWindowCalculator(store: store)
        XCTAssertEqual(calc.tokens(in: .fiveHour, endingAt: Date()), 0)
        XCTAssertEqual(calc.tokens(in: .sevenDay, endingAt: Date()), 0)
    }

}
