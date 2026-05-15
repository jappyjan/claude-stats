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

    func testRefreshYearSummaryYields12Entries() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int = 15, _ hour: Int = 12) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let store = try makeStore(events: [
            UsageEntry(timestamp: mkDate(2026, 1), sessionId: "s", projectPath: "/p",
                       model: "claude-opus-4-7", inputTokens: 100, outputTokens: 50,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 3), sessionId: "s", projectPath: "/p",
                       model: "claude-opus-4-7", inputTokens: 200, outputTokens: 100,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        vm.monthsYear = 2026
        vm.refreshYearSummary()
        XCTAssertEqual(vm.yearSummary.months.count, 12)
        XCTAssertEqual(vm.yearSummary.year, 2026)
        XCTAssertEqual(vm.yearSummary.months[0].month, 1)
        XCTAssertEqual(vm.yearSummary.months[0].totalTokens, 150)
        XCTAssertEqual(vm.yearSummary.months[1].month, 2)
        XCTAssertEqual(vm.yearSummary.months[1].totalTokens, 0)
        XCTAssertEqual(vm.yearSummary.months[2].month, 3)
        XCTAssertEqual(vm.yearSummary.months[2].totalTokens, 300)
    }

    func testRefreshYearSummaryCountsMonthsWithData() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: 15, hour: 12))!
        }
        let store = try makeStore(events: [
            UsageEntry(timestamp: mkDate(2026, 1), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 10, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 4), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 10, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 11), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 10, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        vm.monthsYear = 2026
        vm.refreshYearSummary()
        XCTAssertEqual(vm.yearSummary.monthsWithData, 3)
    }

    func testRefreshYearSummaryEarliestYearWithData() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: 15, hour: 12))!
        }
        let store = try makeStore(events: [
            UsageEntry(timestamp: mkDate(2024, 7), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 1), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        vm.monthsYear = 2026
        vm.refreshYearSummary()
        XCTAssertEqual(vm.yearSummary.earliestYearWithData, 2024)
    }

    func testRefreshYearSummaryAppliesPricingPerMonth() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: 15, hour: 12))!
        }
        let store = try makeStore(events: [
            UsageEntry(timestamp: mkDate(2026, 1), sessionId: "s", projectPath: "/p",
                       model: "m1", inputTokens: 1_000_000, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 2), sessionId: "s", projectPath: "/p",
                       model: "m1", inputTokens: 500_000, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        // $1 per million input tokens for m1.
        let pricing = PricingTable(rates: [
            "m1": PricingTable.Rate(input: 1e-6, output: 0, cacheCreate: 0, cacheRead: 0)
        ])
        let vm = makeViewModel(store: store, pricing: pricing)
        vm.monthsYear = 2026
        vm.refreshYearSummary()
        XCTAssertEqual(vm.yearSummary.months[0].estimatedCost, 1.0, accuracy: 1e-6)
        XCTAssertEqual(vm.yearSummary.months[1].estimatedCost, 0.5, accuracy: 1e-6)
        XCTAssertEqual(vm.yearSummary.months[2].estimatedCost, 0.0, accuracy: 1e-6)
    }

    func testMonthDetailTopProjectsLimitedToFive() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int = 15) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
        var events: [UsageEntry] = []
        for i in 0..<8 {
            events.append(UsageEntry(
                timestamp: mkDate(2026, 1, i + 1),
                sessionId: "s\(i)",
                projectPath: "/p\(i)",
                model: "m",
                inputTokens: 100 * (10 - i),  // /p0 = 1000, /p1 = 900, ... /p7 = 300
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            ))
        }
        let store = try makeStore(events: events)
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        vm.monthsYear = 2026
        vm.refreshYearSummary()
        let detail = await vm.monthDetail(year: 2026, month: 1)
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.topProjects.count, 5)
        XCTAssertEqual(detail?.topProjects.first?.projectKey, "/p0")
        XCTAssertEqual(detail?.topProjects.first?.totalTokens, 1000)
        XCTAssertEqual(detail?.projectCount, 8)
        XCTAssertEqual(detail?.sessionCount, 8)
    }

    func testMonthDetailNilForWrongYear() async throws {
        let store = try makeStore(events: [])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        vm.monthsYear = 2026
        vm.refreshYearSummary()
        let detail = await vm.monthDetail(year: 2024, month: 1)
        XCTAssertNil(detail)
    }

    func testBuildExportDataTotalsAndBuckets() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int = 15, _ hour: Int = 12) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let store = try makeStore(events: [
            UsageEntry(timestamp: mkDate(2026, 1), sessionId: "s1", projectPath: "/p1",
                       model: "m1", inputTokens: 1_000_000, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 2), sessionId: "s2", projectPath: "/p2",
                       model: "m1", inputTokens: 500_000, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 2), sessionId: "s2", projectPath: "/p2",
                       model: "m2", inputTokens: 250_000, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        // $1 per million input tokens for m1; $2/M for m2.
        let pricing = PricingTable(rates: [
            "m1": PricingTable.Rate(input: 1e-6, output: 0, cacheCreate: 0, cacheRead: 0),
            "m2": PricingTable.Rate(input: 2e-6, output: 0, cacheCreate: 0, cacheRead: 0),
        ])
        let vm = makeViewModel(store: store, pricing: pricing)
        let start = mkDate(2026, 1, 1, 0)
        let end = mkDate(2026, 3, 1, 0)
        let data = try await vm.buildExportData(start: start, end: end)
        XCTAssertEqual(data.totalTokens, 1_750_000)
        XCTAssertEqual(data.estimatedCost, 2.0, accuracy: 1e-6)
        XCTAssertEqual(data.sessionCount, 2)
        XCTAssertEqual(data.projectCount, 2)
        XCTAssertEqual(data.months.count, 2)
        XCTAssertEqual(data.months[0].month, 1)
        XCTAssertEqual(data.months[0].totalTokens, 1_000_000)
        XCTAssertEqual(data.months[1].month, 2)
        XCTAssertEqual(data.months[1].totalTokens, 750_000)
    }

    func testBuildExportDataCSVRowsAreSorted() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int = 15) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
        let store = try makeStore(events: [
            // Intentionally out-of-order inserts to confirm the ORDER BY in SQL.
            UsageEntry(timestamp: mkDate(2026, 3), sessionId: "s", projectPath: "/zzz",
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 1), sessionId: "s", projectPath: "/aaa",
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 1), sessionId: "s", projectPath: "/zzz",
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        let data = try await vm.buildExportData(start: mkDate(2026, 1, 1), end: mkDate(2027, 1, 1))
        XCTAssertEqual(data.csvRows.count, 3)
        XCTAssertEqual(data.csvRows[0].month, 1)
        XCTAssertEqual(data.csvRows[0].projectKey, "/aaa")
        XCTAssertEqual(data.csvRows[1].month, 1)
        XCTAssertEqual(data.csvRows[1].projectKey, "/zzz")
        XCTAssertEqual(data.csvRows[2].month, 3)
        XCTAssertEqual(data.csvRows[2].projectKey, "/zzz")
    }

    func testEarliestEventDateReflectsStore() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: 15, hour: 12))!
        }
        let emptyStore = try makeStore(events: [])
        let emptyVM = makeViewModel(store: emptyStore, pricing: PricingTable(rates: [:]))
        XCTAssertNil(emptyVM.earliestEventDate())

        let populatedStore = try makeStore(events: [
            UsageEntry(timestamp: mkDate(2024, 7), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
            UsageEntry(timestamp: mkDate(2026, 1), sessionId: "s", projectPath: "/p",
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0),
        ])
        let vm = makeViewModel(store: populatedStore, pricing: PricingTable(rates: [:]))
        XCTAssertEqual(vm.earliestEventDate(), mkDate(2024, 7))
    }

    func testBuildExportDataEmptyRangeYieldsZerosAndEmptyArrays() async throws {
        let cal = Calendar.current
        func mkDate(_ year: Int, _ month: Int, _ day: Int = 15) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
        let store = try makeStore(events: [])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        let data = try await vm.buildExportData(start: mkDate(2026, 1), end: mkDate(2026, 12))
        XCTAssertEqual(data.totalTokens, 0)
        XCTAssertEqual(data.estimatedCost, 0.0, accuracy: 1e-9)
        XCTAssertEqual(data.sessionCount, 0)
        XCTAssertEqual(data.projectCount, 0)
        XCTAssertTrue(data.months.isEmpty)
        XCTAssertTrue(data.csvRows.isEmpty)
        XCTAssertTrue(data.byModelOverall.isEmpty)
    }
}
