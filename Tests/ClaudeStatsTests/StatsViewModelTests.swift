import XCTest
@testable import ClaudeStats

@MainActor
final class StatsViewModelTests: XCTestCase {
    private func makeStore(events: [UsageEntry]) throws -> UsageStore {
        let s = try UsageStore(path: ":memory:")
        try s.insert(events)
        return s
    }

    private func entry(secondsAgo: Int, model: String = "claude-opus-4-7", project: String = "/p1",
                       input: Int = 100, output: Int = 50, cacheCreate: Int = 0, cacheRead: Int = 0,
                       session: String = "s") -> UsageEntry {
        UsageEntry(
            timestamp: Date().addingTimeInterval(-Double(secondsAgo)),
            sessionId: session, projectPath: project, model: model,
            inputTokens: input, outputTokens: output,
            cacheCreationTokens: cacheCreate, cacheReadTokens: cacheRead
        )
    }

    func testTodayTokensAggregatesAcrossModels() async throws {
        let store = try makeStore(events: [
            entry(secondsAgo: 60, input: 100, output: 50, cacheCreate: 25, cacheRead: 75),
            entry(secondsAgo: 120, input: 10, output: 5, cacheCreate: 0, cacheRead: 0),
        ])
        let vm = StatsViewModel(store: store, pricing: PricingTable(rates: [:]))
        await vm.refresh()
        XCTAssertEqual(vm.todayTokens, 265)
    }

    func testProjectRowsSortedByTokensDesc() async throws {
        let store = try makeStore(events: [
            entry(secondsAgo: 60, project: "/A", input: 100, output: 0),
            entry(secondsAgo: 60, project: "/B", input: 500, output: 0),
            entry(secondsAgo: 60, project: "/C", input: 300, output: 0),
        ])
        let vm = StatsViewModel(store: store, pricing: PricingTable(rates: [:]))
        await vm.refresh()
        XCTAssertEqual(vm.projectRows.map { $0.projectKey }, ["/B", "/C", "/A"])
    }

    func testTimeRangeChangeTriggersRefresh() async throws {
        let store = try makeStore(events: [
            entry(secondsAgo: 60, input: 100, output: 0),
            entry(secondsAgo: 10 * 86400, input: 5000, output: 0),
        ])
        let vm = StatsViewModel(store: store, pricing: PricingTable(rates: [:]))
        vm.timeRange = .today
        await vm.refresh()
        let today = vm.todayTokens // unaffected by range
        let rangeTodayTotal = vm.overview.totalTokens
        vm.timeRange = .last30Days
        await vm.refresh()
        XCTAssertGreaterThan(vm.overview.totalTokens, rangeTodayTotal)
        XCTAssertEqual(vm.todayTokens, today)
    }

    func testCacheHitRatePercent() async throws {
        let store = try makeStore(events: [
            entry(secondsAgo: 60, input: 100, output: 0, cacheCreate: 100, cacheRead: 200),
        ])
        let vm = StatsViewModel(store: store, pricing: PricingTable(rates: [:]))
        await vm.refresh()
        // hit rate = cacheRead / (input + cacheCreate + cacheRead) = 200 / 400 = 0.5
        XCTAssertEqual(vm.overview.cacheHitRate, 0.5, accuracy: 1e-9)
    }
}
