import XCTest
@testable import ClaudeStats

@MainActor
final class StatsViewModelTests: XCTestCase {
    private func makeStore(events: [UsageEntry]) throws -> UsageStore {
        let s = try UsageStore(path: ":memory:")
        try s.insert(events)
        return s
    }

    @MainActor
    private func makeViewModel(store: UsageStore, pricing: PricingTable) -> StatsViewModel {
        let bundled = Data("""
        {
          "pro":     {"five_hour": {"tokens": 25000000}, "seven_day": null},
          "max_5x":  {"five_hour": {"tokens": 120000000}, "seven_day": {"tokens": 3500000000}},
          "max_20x": {"five_hour": {"tokens": 480000000}, "seven_day": {"tokens": 14000000000}}
        }
        """.utf8)
        let calibURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("svm-\(UUID().uuidString).json")
        let catalog = try! PlanCatalog(bundledData: bundled, calibrationURL: calibURL)
        return StatsViewModel(
            store: store, pricing: pricing,
            calculator: UsageWindowCalculator(store: store),
            catalog: catalog,
            detector: PlanDetector(keychain: NoOpKeychain()),
            calibrator: PlanCalibrator(fileURL: calibURL),
            apiClient: LimitsAPIClient(keychain: NoOpKeychain())
        )
    }

    private final class NoOpKeychain: KeychainReading {
        func readClaudeCredentials() throws -> ClaudeCredentials? { nil }
        func writeClaudeCredentials(_ creds: ClaudeCredentials) throws {}
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
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        await vm.refresh()
        XCTAssertEqual(vm.todayTokens, 265)
    }

    func testProjectRowsSortedByTokensDesc() async throws {
        let store = try makeStore(events: [
            entry(secondsAgo: 60, project: "/A", input: 100, output: 0),
            entry(secondsAgo: 60, project: "/B", input: 500, output: 0),
            entry(secondsAgo: 60, project: "/C", input: 300, output: 0),
        ])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        await vm.refresh()
        XCTAssertEqual(vm.projectRows.map { $0.projectKey }, ["/B", "/C", "/A"])
    }

    func testTimeRangeChangeTriggersRefresh() async throws {
        let store = try makeStore(events: [
            entry(secondsAgo: 60, input: 100, output: 0),
            entry(secondsAgo: 10 * 86400, input: 5000, output: 0),
        ])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
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
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        await vm.refresh()
        // hit rate = cacheRead / (input + cacheCreate + cacheRead) = 200 / 400 = 0.5
        XCTAssertEqual(vm.overview.cacheHitRate, 0.5, accuracy: 1e-9)
    }
}
