# Monthly Usage Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Months tab to the popover that shows per-month token totals and estimated cost for a selectable year, with a segmented control to switch between three breakdown modes (Total / Type / Model). Tapping a month drills into a detail view whose stat-card layout also honours the chosen mode.

**Architecture:** A new SQL helper on `UsageStore` aggregates `(month, model, token-buckets)` for a year window. `StatsViewModel` materialises this into a `YearSummary` of 12 `MonthBucket`s (Jan-first, zero-filled), with per-model breakdown retained on each bucket — that gives both per-model and per-token-type breakdowns for free (sum the type buckets across models). A new `MonthsView` renders a segmented control (`[Total | Type | Model]`), legend strip, year stepper, summary header, and reverse-order month list. Each `MonthRow` renders either a single gradient bar (Total) or a stacked horizontal bar (Type or Model). `MonthDetailView` uses content-replace + Back-button drill pattern (parallel to `ProjectDetailView`) and switches its stat-card grid in Type mode. Breakdown mode is persisted via `@AppStorage("monthsBreakdown")`.

**Tech Stack:** Swift, SwiftUI, SQLite (custom wrapper at `Sources/ClaudeStats/Storage/SQLite.swift`), `@Observable` view model, `@AppStorage` for persistence, XCTest.

**Spec deviations:** The spec proposed a `tokensByMonthAndProject(year:month:calendar:limit:)` helper. On review the existing `tokensByProject(start:end:)` already returns all projects in a window sorted desc with session counts — slicing top 5 in Swift is simpler than adding a parallel SQL helper. We reuse the existing method. This is the only deviation; the user-visible behaviour and tests still match the spec.

---

## File Structure

**New files:**
- `Sources/ClaudeStats/Model/MonthsBreakdown.swift` — small enum with three cases (`.total`, `.type`, `.model`).
- `Sources/ClaudeStats/Views/MonthRow.swift` — single-row component (label, mode-aware bar, tokens, cost).
- `Sources/ClaudeStats/Views/MonthsView.swift` — tab body: segmented control, legend strip, year stepper, summary header, scrollable list of `MonthRow`s.
- `Sources/ClaudeStats/Views/MonthDetailView.swift` — drill-in view (mirrors `ProjectDetailView`): back button, mode-aware stat cards, by-model rows, top-projects rows.

**Modified files:**
- `Sources/ClaudeStats/Storage/UsageStore.swift` — add `tokensByMonthAndModel(year:calendar:)` and `earliestTimestamp()` (no-arg overload).
- `Sources/ClaudeStats/ViewModel/StatsViewModel.swift` — add `MonthBucket`, `YearSummary`, `MonthDetail` types; `monthsYear`/`yearSummary` state; `refreshYearSummary()`; `monthDetail(year:month:)`. Call `refreshYearSummary()` at the end of `refresh()`.
- `Sources/ClaudeStats/App/PopoverView.swift` — add `case months` to `Section`; add `@AppStorage("monthsBreakdown")`; suppress `TimeRangeTabs` when `section == .months`; add `drillMonth` / `drillMonthDetail` state and detail-view branch.
- `Tests/ClaudeStatsTests/UsageStoreTests.swift` — add tests for the two new store methods.
- `Tests/ClaudeStatsTests/StatsViewModelTests.swift` — add tests for `refreshYearSummary()` and `monthDetail(year:month:)`.

---

## Task 1: `UsageStore.tokensByMonthAndModel(year:calendar:)`

**Files:**
- Modify: `Sources/ClaudeStats/Storage/UsageStore.swift` (append a new method inside the `UsageStore` class, after `dailyTokens`, before `earliestTimestamp`)
- Test: `Tests/ClaudeStatsTests/UsageStoreTests.swift` (append three new test methods)

- [ ] **Step 1.1: Write the failing test for basic month/model grouping**

In `Tests/ClaudeStatsTests/UsageStoreTests.swift`, append inside the `final class UsageStoreTests: XCTestCase` body (just before the closing `}` of the class):

```swift
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
```

- [ ] **Step 1.2: Run the test to verify it fails**

Run: `swift test --filter UsageStoreTests/testTokensByMonthAndModelGroupsByMonth`
Expected: FAIL — "value of type 'UsageStore' has no member 'tokensByMonthAndModel'" (compile error).

- [ ] **Step 1.3: Implement `tokensByMonthAndModel`**

In `Sources/ClaudeStats/Storage/UsageStore.swift`, insert the new method between `dailyTokens(start:end:calendar:)` (ends line 272) and `earliestTimestamp(start:end:)` (begins line 274):

```swift
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
```

- [ ] **Step 1.4: Run the test to verify it passes**

Run: `swift test --filter UsageStoreTests/testTokensByMonthAndModelGroupsByMonth`
Expected: PASS.

- [ ] **Step 1.5: Write the failing test for empty year (no data)**

In `Tests/ClaudeStatsTests/UsageStoreTests.swift`, append inside the class:

```swift
    func testTokensByMonthAndModelEmptyYearReturnsEmpty() throws {
        let store = try makeStore()
        let cal = Calendar.current
        let rows = try store.tokensByMonthAndModel(year: 2026, calendar: cal)
        XCTAssertTrue(rows.isEmpty)
    }
```

- [ ] **Step 1.6: Run the test to verify it passes**

Run: `swift test --filter UsageStoreTests/testTokensByMonthAndModelEmptyYearReturnsEmpty`
Expected: PASS (the SQL returns no rows when the table is empty).

- [ ] **Step 1.7: Write the failing test for events outside the year being excluded**

In `Tests/ClaudeStatsTests/UsageStoreTests.swift`, append inside the class:

```swift
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
```

- [ ] **Step 1.8: Run the test to verify it passes**

Run: `swift test --filter UsageStoreTests/testTokensByMonthAndModelExcludesOtherYears`
Expected: PASS.

- [ ] **Step 1.9: Write the failing test for local-time boundary bucketing**

Per the spec: "an event at `2026-01-01 00:30 local` appears in month `01`, not `12` of the prior year." The event's local time is just after midnight Jan 1; the WHERE clause must include it AND the strftime must label it month 01.

In `Tests/ClaudeStatsTests/UsageStoreTests.swift`, append inside the class:

```swift
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
```

- [ ] **Step 1.10: Run the test to verify it passes**

Run: `swift test --filter UsageStoreTests/testTokensByMonthAndModelLocalTimeBoundary`
Expected: PASS.

- [ ] **Step 1.11: Commit**

```bash
git add Sources/ClaudeStats/Storage/UsageStore.swift Tests/ClaudeStatsTests/UsageStoreTests.swift
git commit -m "store: add tokensByMonthAndModel for monthly summary"
```

---

## Task 2: `UsageStore.earliestTimestamp()` (no-arg overload)

The existing `earliestTimestamp(start:end:)` requires a window. The Months tab needs the earliest timestamp anywhere in the DB to compute `earliestYearWithData` for the year-stepper bound. Add a parameter-less overload.

**Files:**
- Modify: `Sources/ClaudeStats/Storage/UsageStore.swift`
- Test: `Tests/ClaudeStatsTests/UsageStoreTests.swift`

- [ ] **Step 2.1: Write the failing test**

In `Tests/ClaudeStatsTests/UsageStoreTests.swift`, append inside the class:

```swift
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
```

- [ ] **Step 2.2: Run the test to verify it fails**

Run: `swift test --filter UsageStoreTests/testEarliestTimestampNoArgs`
Expected: FAIL — "missing argument for parameter 'start'" or similar compile error.

- [ ] **Step 2.3: Add the overload**

In `Sources/ClaudeStats/Storage/UsageStore.swift`, insert immediately above the existing `earliestTimestamp(start:end:)` (line 274):

```swift
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

```

- [ ] **Step 2.4: Run the test to verify it passes**

Run: `swift test --filter UsageStoreTests/testEarliestTimestampNoArgs`
Expected: PASS.

- [ ] **Step 2.5: Commit**

```bash
git add Sources/ClaudeStats/Storage/UsageStore.swift Tests/ClaudeStatsTests/UsageStoreTests.swift
git commit -m "store: add earliestTimestamp() no-arg overload for year stepper bound"
```

---

## Task 3: View-model types and state (`MonthBucket`, `YearSummary`, `MonthDetail`, `monthsYear`, `yearSummary`)

Add the new value types and stored properties. No methods yet — those follow in Tasks 4 and 5.

**Files:**
- Modify: `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`

- [ ] **Step 3.1: Add the three new value types**

In `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`, insert the following struct definitions immediately after the existing `ProjectDetail` struct (after line 45, before `private let store: UsageStore`):

```swift
    struct MonthBucket: Equatable {
        let year: Int
        let month: Int      // 1...12
        let totalTokens: Int
        let estimatedCost: Double
        let byModel: [UsageStore.ModelRow]
    }

    struct YearSummary: Equatable {
        let year: Int
        let months: [MonthBucket]            // 12 entries, Jan first (zero-filled for sparse months)
        let earliestYearWithData: Int?
        let monthsWithData: Int
    }

    struct MonthDetail: Equatable {
        let year: Int
        let month: Int                       // 1...12
        let totalTokens: Int
        let estimatedCost: Double
        let sessionCount: Int
        let projectCount: Int
        let byModel: [UsageStore.ModelRow]
        let topProjects: [UsageStore.ProjectRow]  // up to 5
    }
```

- [ ] **Step 3.2: Add `monthsYear` and `yearSummary` stored properties**

In `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`, insert these stored properties immediately after the existing `var limits: LimitsState = ...` (the line block that begins at line 63):

```swift
    var monthsYear: Int = Calendar.current.component(.year, from: Date())
    var yearSummary: YearSummary = YearSummary(
        year: Calendar.current.component(.year, from: Date()),
        months: [],
        earliestYearWithData: nil,
        monthsWithData: 0
    )
```

- [ ] **Step 3.3: Verify the project still builds**

Run: `swift build`
Expected: build succeeds (these are pure additions — nothing references the new types yet, but the types compile).

- [ ] **Step 3.4: Commit**

```bash
git add Sources/ClaudeStats/ViewModel/StatsViewModel.swift
git commit -m "viewmodel: introduce MonthBucket/YearSummary/MonthDetail types"
```

---

## Task 4: `StatsViewModel.refreshYearSummary()`

Materialises the year's 12 `MonthBucket`s from the store and applies pricing. Also computes `earliestYearWithData` and `monthsWithData`. Called on tab visibility, year change, and at the end of `refresh()`.

**Files:**
- Modify: `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`
- Test: `Tests/ClaudeStatsTests/StatsViewModelTests.swift`

- [ ] **Step 4.1: Write the failing test — refreshYearSummary yields 12 entries**

In `Tests/ClaudeStatsTests/StatsViewModelTests.swift`, append inside the `final class StatsViewModelTests: XCTestCase` body (before the closing `}` of the class):

```swift
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
```

- [ ] **Step 4.2: Run the test to verify it fails**

Run: `swift test --filter StatsViewModelTests/testRefreshYearSummaryYields12Entries`
Expected: FAIL — "value of type 'StatsViewModel' has no member 'refreshYearSummary'".

- [ ] **Step 4.3: Implement `refreshYearSummary()`**

In `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`, insert the new method immediately after `projectDetail(for:)` (which currently ends at line 204). The new method body is sync — it does no awaits.

```swift
    /// Recomputes `yearSummary` for the current `monthsYear` using the
    /// configured store and pricing table. Always produces 12 month
    /// entries (Jan first), zero-filling months with no data. Cost per
    /// month is computed at call time from `pricing`, so a pricing
    /// refresh propagates on the next call.
    func refreshYearSummary() {
        let year = monthsYear
        let cal = Calendar.current
        do {
            let rows = try store.tokensByMonthAndModel(year: year, calendar: cal)
            let earliest = try store.earliestTimestamp()
            let earliestYear = earliest.map { cal.component(.year, from: $0) }

            var byMonth: [Int: [UsageStore.ModelRow]] = [:]
            for r in rows {
                let modelRow = UsageStore.ModelRow(
                    model: r.model,
                    totalTokens: r.tokens.total,
                    inputTokens: r.tokens.input,
                    outputTokens: r.tokens.output,
                    cacheCreateTokens: r.tokens.cacheCreate,
                    cacheReadTokens: r.tokens.cacheRead
                )
                byMonth[r.month, default: []].append(modelRow)
            }

            var buckets: [MonthBucket] = []
            for month in 1...12 {
                let models = (byMonth[month] ?? [])
                    .sorted { $0.totalTokens > $1.totalTokens }
                let totalTokens = models.reduce(0) { $0 + $1.totalTokens }
                let cost = computeCost(byModel: models)
                buckets.append(MonthBucket(
                    year: year, month: month,
                    totalTokens: totalTokens,
                    estimatedCost: cost,
                    byModel: models
                ))
            }
            let monthsWithData = buckets.filter { $0.totalTokens > 0 }.count
            yearSummary = YearSummary(
                year: year,
                months: buckets,
                earliestYearWithData: earliestYear,
                monthsWithData: monthsWithData
            )
        } catch {
            // Leave previous state on error.
        }
    }
```

- [ ] **Step 4.4: Run the test to verify it passes**

Run: `swift test --filter StatsViewModelTests/testRefreshYearSummaryYields12Entries`
Expected: PASS.

- [ ] **Step 4.5: Write the failing test — `monthsWithData` counts non-empty months**

In `Tests/ClaudeStatsTests/StatsViewModelTests.swift`, append inside the class:

```swift
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
```

- [ ] **Step 4.6: Run the test to verify it passes**

Run: `swift test --filter StatsViewModelTests/testRefreshYearSummaryCountsMonthsWithData`
Expected: PASS.

- [ ] **Step 4.7: Write the failing test — `earliestYearWithData` reflects min timestamp**

In `Tests/ClaudeStatsTests/StatsViewModelTests.swift`, append inside the class:

```swift
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
```

- [ ] **Step 4.8: Run the test to verify it passes**

Run: `swift test --filter StatsViewModelTests/testRefreshYearSummaryEarliestYearWithData`
Expected: PASS.

- [ ] **Step 4.9: Write the failing test — cost applies pricing per model**

In `Tests/ClaudeStatsTests/StatsViewModelTests.swift`, append inside the class:

```swift
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
```

- [ ] **Step 4.10: Run the test to verify it passes**

Run: `swift test --filter StatsViewModelTests/testRefreshYearSummaryAppliesPricingPerMonth`
Expected: PASS.

- [ ] **Step 4.11: Wire `refreshYearSummary()` into `refresh()`**

The spec says `refresh()` should re-run the year summary so FSEvents-triggered updates keep the Months tab fresh. The work is cheap (single query, ≤24 rows), so call it unconditionally.

In `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`, locate the `refresh()` method (begins at line 89). At the very end of the `do { ... }` block, immediately after `maybeFetchAPILimits(now: now)` (currently the last statement of the `do`), insert:

```swift
            refreshYearSummary()
```

Final lines of the `do { ... }` block should look like:

```swift
            todayTokens = nextTodayTokens
            projectRows = nextProjectRows
            projectCosts = nextProjectCosts
            overview = nextOverview
            recomputeLocalLimits(now: now)
            maybeFetchAPILimits(now: now)
            refreshYearSummary()
        } catch {
            // Leave previous state on error; surfaced via logging when wired.
        }
```

- [ ] **Step 4.12: Run all tests to confirm no regressions**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 4.13: Commit**

```bash
git add Sources/ClaudeStats/ViewModel/StatsViewModel.swift Tests/ClaudeStatsTests/StatsViewModelTests.swift
git commit -m "viewmodel: add refreshYearSummary for monthly summary tab"
```

---

## Task 5: `StatsViewModel.monthDetail(year:month:)`

Returns a populated `MonthDetail` for a given (year, month). Mirrors `projectDetail(for:)`. Reads totals/byModel/cost from the cached `MonthBucket`, queries session count and project list from the store.

**Files:**
- Modify: `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`
- Test: `Tests/ClaudeStatsTests/StatsViewModelTests.swift`

- [ ] **Step 5.1: Write the failing test — monthDetail returns top 5 projects and counts**

In `Tests/ClaudeStatsTests/StatsViewModelTests.swift`, append inside the class:

```swift
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
```

- [ ] **Step 5.2: Run the test to verify it fails**

Run: `swift test --filter StatsViewModelTests/testMonthDetailTopProjectsLimitedToFive`
Expected: FAIL — "value of type 'StatsViewModel' has no member 'monthDetail'".

- [ ] **Step 5.3: Implement `monthDetail(year:month:)`**

In `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`, insert the new method immediately after `refreshYearSummary()` (added in Task 4):

```swift
    /// Builds a `MonthDetail` for the given (year, month). Totals/byModel/cost
    /// come from the cached `MonthBucket` for that month in `yearSummary`;
    /// session count and per-project rows come from a per-month store query.
    /// Returns nil if the month falls outside the cached year or on store error.
    func monthDetail(year: Int, month: Int) async -> MonthDetail? {
        guard yearSummary.year == year,
              let bucket = yearSummary.months.first(where: { $0.month == month })
        else { return nil }
        let cal = Calendar.current
        var startComps = DateComponents()
        startComps.year = year
        startComps.month = month
        startComps.day = 1
        startComps.timeZone = cal.timeZone
        guard let monthStart = cal.date(from: startComps),
              let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)
        else { return nil }
        do {
            let projects = try store.tokensByProject(start: monthStart, end: monthEnd)
            let sessions = try store.sessionCount(start: monthStart, end: monthEnd)
            return MonthDetail(
                year: year, month: month,
                totalTokens: bucket.totalTokens,
                estimatedCost: bucket.estimatedCost,
                sessionCount: sessions,
                projectCount: projects.count,
                byModel: bucket.byModel,
                topProjects: Array(projects.prefix(5))
            )
        } catch {
            return nil
        }
    }
```

- [ ] **Step 5.4: Run the test to verify it passes**

Run: `swift test --filter StatsViewModelTests/testMonthDetailTopProjectsLimitedToFive`
Expected: PASS.

- [ ] **Step 5.5: Write the failing test — monthDetail returns nil for year other than yearSummary.year**

In `Tests/ClaudeStatsTests/StatsViewModelTests.swift`, append inside the class:

```swift
    func testMonthDetailNilForWrongYear() async throws {
        let store = try makeStore(events: [])
        let vm = makeViewModel(store: store, pricing: PricingTable(rates: [:]))
        vm.monthsYear = 2026
        vm.refreshYearSummary()
        let detail = await vm.monthDetail(year: 2024, month: 1)
        XCTAssertNil(detail)
    }
```

- [ ] **Step 5.6: Run the test to verify it passes**

Run: `swift test --filter StatsViewModelTests/testMonthDetailNilForWrongYear`
Expected: PASS.

- [ ] **Step 5.7: Run all tests to confirm no regressions**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 5.8: Commit**

```bash
git add Sources/ClaudeStats/ViewModel/StatsViewModel.swift Tests/ClaudeStatsTests/StatsViewModelTests.swift
git commit -m "viewmodel: add monthDetail for Months tab drill-in"
```

---

## Task 6: `MonthsBreakdown` enum + `MonthRow` view (mode-aware)

Adds the breakdown enum used across the Months tab, then the row component. The row renders one of three bar styles based on the chosen mode.

**Files:**
- Create: `Sources/ClaudeStats/Model/MonthsBreakdown.swift`
- Create: `Sources/ClaudeStats/Views/MonthRow.swift`

- [ ] **Step 6.1: Create the `MonthsBreakdown` enum**

Create `Sources/ClaudeStats/Model/MonthsBreakdown.swift` with this content:

```swift
import Foundation

enum MonthsBreakdown: String, CaseIterable, Identifiable {
    case total
    case type
    case model

    var id: String { rawValue }

    var label: String {
        switch self {
        case .total: return "Total"
        case .type: return "Type"
        case .model: return "Model"
        }
    }
}
```

- [ ] **Step 6.2: Verify the enum builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 6.3: Create the `MonthRow` view**

Create `Sources/ClaudeStats/Views/MonthRow.swift` with this content:

```swift
import SwiftUI

struct MonthRow: View {
    let bucket: StatsViewModel.MonthBucket
    let mode: MonthsBreakdown
    let widthFraction: Double // 0.0–1.0

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(monthLabel)
                    .font(.system(size: 13, weight: .medium))
                GeometryReader { geo in
                    let totalBarWidth = max(
                        geo.size.width * widthFraction,
                        bucket.totalTokens == 0 ? 0 : 2
                    )
                    bar(width: totalBarWidth)
                }
                .frame(height: 3)
            }
            Spacer()
            Text(formatTokens(bucket.totalTokens))
                .font(.system(size: 12)).monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            Text("$\(String(format: "%.2f", bucket.estimatedCost))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func bar(width totalWidth: CGFloat) -> some View {
        switch mode {
        case .total:
            LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                .frame(width: totalWidth, height: 3)
                .clipShape(Capsule())
        case .type, .model:
            HStack(spacing: 0) {
                ForEach(segments, id: \.id) { seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: totalWidth * seg.fraction, height: 3)
                }
            }
            .clipShape(Capsule())
        }
    }

    private struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    private var segments: [Segment] {
        guard bucket.totalTokens > 0 else { return [] }
        let total = Double(bucket.totalTokens)
        switch mode {
        case .total:
            return []
        case .type:
            var input = 0, output = 0, cc = 0, cr = 0
            for m in bucket.byModel {
                input += m.inputTokens
                output += m.outputTokens
                cc += m.cacheCreateTokens
                cr += m.cacheReadTokens
            }
            return [
                Segment(id: "input", fraction: Double(input) / total, color: .blue),
                Segment(id: "output", fraction: Double(output) / total, color: .green),
                Segment(id: "cc", fraction: Double(cc) / total, color: .orange),
                Segment(id: "cr", fraction: Double(cr) / total, color: .purple),
            ].filter { $0.fraction > 0 }
        case .model:
            return bucket.byModel.map { row in
                Segment(
                    id: row.model,
                    fraction: Double(row.totalTokens) / total,
                    color: MonthRow.color(forModel: row.model)
                )
            }.filter { $0.fraction > 0 }
        }
    }

    /// Color palette matching `ModelChip` so legend chips and bar segments line up.
    static func color(forModel model: String) -> Color {
        let lower = model.lowercased()
        if lower.contains("opus") { return .purple }
        if lower.contains("sonnet") { return .blue }
        if lower.contains("haiku") { return .green }
        return .gray
    }

    private var monthLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLL"
        var comps = DateComponents()
        comps.year = bucket.year
        comps.month = bucket.month
        comps.day = 1
        if let date = Calendar.current.date(from: comps) {
            return fmt.string(from: date)
        }
        return "\(bucket.month)"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 6.4: Verify the row builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 6.5: Commit**

```bash
git add Sources/ClaudeStats/Model/MonthsBreakdown.swift Sources/ClaudeStats/Views/MonthRow.swift
git commit -m "views: add MonthsBreakdown enum + mode-aware MonthRow"
```

---

## Task 7: `MonthsView` (tab body with segmented control + legend)

Renders segmented control (`[Total | Type | Model]`), a legend strip (when mode is `.type` or `.model`), year stepper (◀ 2026 ▶, with caption "N months with data"), year summary header, and the reverse-order month list (most-recent month at top). Suppresses future months for the current year. Calls `refreshYearSummary()` on appear and on year change. The breakdown mode is owned by the parent (PopoverView, via `@AppStorage`) and passed in as a binding.

**Files:**
- Create: `Sources/ClaudeStats/Views/MonthsView.swift`

- [ ] **Step 7.1: Create the new file**

Create `Sources/ClaudeStats/Views/MonthsView.swift` with this content:

```swift
import SwiftUI

struct MonthsView: View {
    @Bindable var viewModel: StatsViewModel
    @Binding var breakdown: MonthsBreakdown
    let onSelectMonth: (Int, Int) -> Void  // (year, month)

    var body: some View {
        VStack(spacing: 0) {
            breakdownPicker
            if breakdown != .total {
                legend
            }
            Divider()
            yearStepper
            Divider()
            headerSummary
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(displayBuckets, id: \.month) { bucket in
                        Button(action: { onSelectMonth(bucket.year, bucket.month) }) {
                            MonthRow(
                                bucket: bucket,
                                mode: breakdown,
                                widthFraction: widthFraction(for: bucket)
                            )
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .onAppear { viewModel.refreshYearSummary() }
        .onChange(of: viewModel.monthsYear) { viewModel.refreshYearSummary() }
    }

    private var breakdownPicker: some View {
        HStack(spacing: 2) {
            ForEach(MonthsBreakdown.allCases) { mode in
                Button(action: { breakdown = mode }) {
                    Text(mode.label)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(breakdown == mode ? Color.gray.opacity(0.4) : Color.clear)
                        .foregroundStyle(breakdown == mode ? Color.primary : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    @ViewBuilder
    private var legend: some View {
        switch breakdown {
        case .total:
            EmptyView()
        case .type:
            HStack(spacing: 12) {
                legendChip(color: .blue, label: "input")
                legendChip(color: .green, label: "output")
                legendChip(color: .orange, label: "cache-create")
                legendChip(color: .purple, label: "cache-read")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 6)
        case .model:
            HStack(spacing: 12) {
                ForEach(legendModels, id: \.self) { m in
                    legendChip(color: MonthRow.color(forModel: m), label: shortModelLabel(m))
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 6)
        }
    }

    private func legendChip(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var legendModels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for bucket in viewModel.yearSummary.months {
            for row in bucket.byModel where !seen.contains(row.model) {
                seen.insert(row.model)
                ordered.append(row.model)
            }
        }
        return ordered
    }

    private func shortModelLabel(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        return String(model.prefix(8))
    }

    private var yearStepper: some View {
        HStack(spacing: 12) {
            Button(action: stepBack) {
                Image(systemName: "chevron.left")
                    .foregroundStyle(canStepBack ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canStepBack)
            Text("\(viewModel.monthsYear, format: .number.grouping(.never))")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 48)
            Button(action: stepForward) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(canStepForward ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canStepForward)
            Spacer()
            Text("\(viewModel.yearSummary.monthsWithData) month\(viewModel.yearSummary.monthsWithData == 1 ? "" : "s") with data")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var headerSummary: some View {
        let yearTotal = viewModel.yearSummary.months.reduce(0) { $0 + $1.totalTokens }
        let yearCost = viewModel.yearSummary.months.reduce(0.0) { $0 + $1.estimatedCost }
        return HStack {
            Text("\(viewModel.monthsYear, format: .number.grouping(.never))")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            Text("·").foregroundStyle(.secondary)
            Text("\(formatTokens(yearTotal)) tokens")
                .font(.system(size: 12)).monospacedDigit()
            Text("·").foregroundStyle(.secondary)
            Text("$\(String(format: "%.2f", yearCost))")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var displayBuckets: [StatsViewModel.MonthBucket] {
        let now = Date()
        let cal = Calendar.current
        let currentYear = cal.component(.year, from: now)
        let currentMonth = cal.component(.month, from: now)
        let filtered: [StatsViewModel.MonthBucket]
        if viewModel.monthsYear == currentYear {
            filtered = viewModel.yearSummary.months.filter { $0.month <= currentMonth }
        } else {
            filtered = viewModel.yearSummary.months
        }
        return filtered.reversed()
    }

    private func widthFraction(for bucket: StatsViewModel.MonthBucket) -> Double {
        let maxTokens = viewModel.yearSummary.months.map(\.totalTokens).max() ?? 0
        guard maxTokens > 0 else { return 0 }
        return Double(bucket.totalTokens) / Double(maxTokens)
    }

    private var canStepBack: Bool {
        guard let earliest = viewModel.yearSummary.earliestYearWithData else { return false }
        return viewModel.monthsYear > earliest
    }

    private var canStepForward: Bool {
        let currentYear = Calendar.current.component(.year, from: Date())
        return viewModel.monthsYear < currentYear
    }

    private func stepBack() { viewModel.monthsYear -= 1 }
    private func stepForward() { viewModel.monthsYear += 1 }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 7.2: Verify it builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 7.3: Commit**

```bash
git add Sources/ClaudeStats/Views/MonthsView.swift
git commit -m "views: add MonthsView with breakdown picker and year stepper"
```

---

## Task 8: `MonthDetailView` (drill-in view, mode-aware)

Mirrors `ProjectDetailView.swift`. In `.total` and `.model` modes shows two stat cards (Tokens + Cost). In `.type` mode shows a 2×2 grid of stat cards (Input / Output / Cache-create / Cache-read) followed by a single Cost card. BY MODEL and TOP PROJECTS lists are always shown.

**Files:**
- Create: `Sources/ClaudeStats/Views/MonthDetailView.swift`

- [ ] **Step 8.1: Create the new file**

Create `Sources/ClaudeStats/Views/MonthDetailView.swift` with this content:

```swift
import SwiftUI

struct MonthDetailView: View {
    let detail: StatsViewModel.MonthDetail
    let mode: MonthsBreakdown
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Months").font(.system(size: 12))
                    }
                    .foregroundStyle(Color.accentColor)
                }.buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    headerStatCards
                        .padding(.horizontal, 14)

                    Text("BY MODEL")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(detail.byModel, id: \.model) { row in
                            HStack {
                                ModelChip(model: row.model)
                                Spacer()
                                Text(formatTokens(row.totalTokens))
                                    .font(.system(size: 12)).monospacedDigit()
                            }
                            .padding(.vertical, 6).padding(.horizontal, 14)
                            Divider()
                        }
                    }

                    Text("TOP PROJECTS")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(detail.topProjects, id: \.projectKey) { row in
                            HStack {
                                Text(ProjectName.display(for: row.projectKey))
                                    .font(.system(size: 12))
                                Spacer()
                                Text(formatTokens(row.totalTokens))
                                    .font(.system(size: 12)).monospacedDigit()
                            }
                            .padding(.vertical, 6).padding(.horizontal, 14)
                            Divider()
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var headerStatCards: some View {
        switch mode {
        case .total, .model:
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatCard(
                    label: "Tokens",
                    value: formatTokens(detail.totalTokens),
                    sub: "\(detail.sessionCount) session\(detail.sessionCount == 1 ? "" : "s")"
                )
                StatCard(
                    label: "Est. cost",
                    value: "$\(String(format: "%.2f", detail.estimatedCost))",
                    sub: "\(detail.projectCount) project\(detail.projectCount == 1 ? "" : "s")"
                )
            }
        case .type:
            let totals = typeTotals
            VStack(spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatCard(label: "Input", value: formatTokens(totals.input), sub: "")
                    StatCard(label: "Output", value: formatTokens(totals.output), sub: "")
                    StatCard(label: "Cache-create", value: formatTokens(totals.cacheCreate), sub: "")
                    StatCard(label: "Cache-read", value: formatTokens(totals.cacheRead), sub: "")
                }
                StatCard(
                    label: "Est. cost",
                    value: "$\(String(format: "%.2f", detail.estimatedCost))",
                    sub: "\(detail.sessionCount) session\(detail.sessionCount == 1 ? "" : "s") · \(detail.projectCount) project\(detail.projectCount == 1 ? "" : "s")"
                )
            }
        }
    }

    private var typeTotals: (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        var input = 0, output = 0, cc = 0, cr = 0
        for m in detail.byModel {
            input += m.inputTokens
            output += m.outputTokens
            cc += m.cacheCreateTokens
            cr += m.cacheReadTokens
        }
        return (input, output, cc, cr)
    }

    private var title: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        var comps = DateComponents()
        comps.year = detail.year
        comps.month = detail.month
        comps.day = 1
        if let date = Calendar.current.date(from: comps) {
            return fmt.string(from: date)
        }
        return "\(detail.month)/\(detail.year)"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 8.2: Verify it builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 8.3: Commit**

```bash
git add Sources/ClaudeStats/Views/MonthDetailView.swift
git commit -m "views: add mode-aware MonthDetailView"
```

---

## Task 9: Wire up `PopoverView` — new tab, suppressed TimeRangeTabs, drill state, `@AppStorage`

Add `case months` to the `Section` enum, suppress `TimeRangeTabs` when on the months tab, add parallel drill state for month detail, and store the breakdown mode via `@AppStorage` so it persists across launches.

**Files:**
- Modify: `Sources/ClaudeStats/App/PopoverView.swift`

- [ ] **Step 9.1: Add `case months` to the Section enum**

In `Sources/ClaudeStats/App/PopoverView.swift`, change line 12:

```swift
    enum Section: String, CaseIterable { case overview, projects }
```

to:

```swift
    enum Section: String, CaseIterable { case overview, projects, months }
```

- [ ] **Step 9.2: Add drill state + persisted breakdown for months**

A small nested struct `MonthSelection` is used instead of a tuple to keep `@State` happy and `Equatable` cheap.

In `Sources/ClaudeStats/App/PopoverView.swift`, immediately after the existing drill state (lines 8–9):

```swift
    @State private var drillProjectKey: String? = nil
    @State private var drillDetail: StatsViewModel.ProjectDetail? = nil
```

insert:

```swift
    @State private var drillMonth: MonthSelection? = nil
    @State private var drillMonthDetail: StatsViewModel.MonthDetail? = nil
    @AppStorage("monthsBreakdown") private var monthsBreakdown: MonthsBreakdown = .total
```

And add the nested struct definition just below the existing `enum Section: String, CaseIterable { ... }` line (was line 12 before this task started; now the modified version from Step 9.1):

```swift
    private struct MonthSelection: Equatable {
        let year: Int
        let month: Int
    }
```

- [ ] **Step 9.3: Suppress `TimeRangeTabs` on the Months tab and wire new views**

In `Sources/ClaudeStats/App/PopoverView.swift`, change the body block beginning at line 18 from:

```swift
            if drillProjectKey == nil {
                sectionTabs
                TimeRangeTabs(selection: $viewModel.timeRange)
                    .onChange(of: viewModel.timeRange) { Task { await viewModel.refresh() } }
                Divider()
                Group {
                    switch section {
                    case .overview: OverviewView(overview: viewModel.overview, range: viewModel.timeRange)
                    case .projects:
                        ProjectsView(
                            rows: viewModel.projectRows,
                            costs: viewModel.projectCosts,
                            onSelect: { key in
                                drillProjectKey = key
                                Task { drillDetail = await viewModel.projectDetail(for: key) }
                            }
                        )
                    }
                }
            } else if let detail = drillDetail {
                ProjectDetailView(detail: detail, range: viewModel.timeRange) {
                    drillProjectKey = nil; drillDetail = nil
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
```

to:

```swift
            if drillProjectKey == nil && drillMonth == nil {
                sectionTabs
                if section != .months {
                    TimeRangeTabs(selection: $viewModel.timeRange)
                        .onChange(of: viewModel.timeRange) { Task { await viewModel.refresh() } }
                }
                Divider()
                Group {
                    switch section {
                    case .overview: OverviewView(overview: viewModel.overview, range: viewModel.timeRange)
                    case .projects:
                        ProjectsView(
                            rows: viewModel.projectRows,
                            costs: viewModel.projectCosts,
                            onSelect: { key in
                                drillProjectKey = key
                                Task { drillDetail = await viewModel.projectDetail(for: key) }
                            }
                        )
                    case .months:
                        MonthsView(
                            viewModel: viewModel,
                            breakdown: $monthsBreakdown,
                            onSelectMonth: { year, month in
                                drillMonth = MonthSelection(year: year, month: month)
                                Task { drillMonthDetail = await viewModel.monthDetail(year: year, month: month) }
                            }
                        )
                    }
                }
            } else if let detail = drillDetail {
                ProjectDetailView(detail: detail, range: viewModel.timeRange) {
                    drillProjectKey = nil; drillDetail = nil
                }
            } else if let detail = drillMonthDetail {
                MonthDetailView(detail: detail, mode: monthsBreakdown) {
                    drillMonth = nil; drillMonthDetail = nil
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
```

- [ ] **Step 9.4: Verify it builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 9.5: Run all tests to confirm no regressions**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 9.6: Commit**

```bash
git add Sources/ClaudeStats/App/PopoverView.swift
git commit -m "popover: wire Months tab with breakdown picker and drill-in"
```

---

## Task 10: Manual verification

Spec calls for manual UI verification (no SwiftUI snapshot tests in this project).

- [ ] **Step 10.1: Build the app**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 10.2: Run the app**

Run: `swift run` (or open `ClaudeStats.app` from DerivedData if running outside Xcode is awkward).
Expected: the menubar icon appears.

- [ ] **Step 10.3: Verify the Overview and Projects tabs still work**

Click the menubar icon, click "Overview" then "Projects". Confirm both still render correctly and the time-range tab row is visible.

- [ ] **Step 10.4: Verify the Months tab basic rendering (Total mode)**

Click "Months". Confirm:
- The time-range tab row is hidden.
- The segmented control `[Total | Type | Model]` is visible with `Total` selected (or whatever mode was last used).
- In `Total` mode: no legend strip is shown.
- The year stepper shows the current year.
- The year summary header shows current-year totals (`{year} · {tokens} tokens · ${cost}`).
- A list of months from current month down to January is visible. Future months in the current year are NOT shown.
- Each row shows a single gradient (purple→pink) bar, total tokens, and cost.
- Months with zero data have a flat row (no visible bar) — that's expected.

- [ ] **Step 10.5: Verify Type mode**

Click `Type` in the segmented control. Confirm:
- A legend strip appears below the segmented control with 4 swatches: input (blue), output (green), cache-create (orange), cache-read (purple).
- Each non-empty month row shows a stacked horizontal bar in those 4 colors.
- The total tokens + cost on the right of each row stays the same as in Total mode.
- Months with zero data still show a flat row.

- [ ] **Step 10.6: Verify Model mode**

Click `Model` in the segmented control. Confirm:
- The legend strip shows a swatch per model present in the year (e.g. opus purple, sonnet blue, haiku green).
- Each non-empty month row shows a stacked horizontal bar segmented by model, with each segment in the matching color.
- Right-side numbers (total tokens + cost) unchanged.

- [ ] **Step 10.7: Verify the year stepper**

- Click ◀: the year decrements, the list refreshes, and the ▶ button becomes enabled.
- At the earliest year with data, ◀ is disabled (grey/half-opacity).
- At the current calendar year, ▶ is disabled.
- For a past year, all 12 months are listed.
- The breakdown selection (Total/Type/Model) is preserved across year changes.

- [ ] **Step 10.8: Verify drill-in honours the chosen mode**

With `Total` mode active, click any month with non-zero data. Confirm:
- The popover content replaces with `MonthDetailView`.
- A `◀ Months` back button appears at the top-left.
- The title shows `{Month} {Year}` (e.g. "May 2026").
- Two stat cards show tokens + cost with session/project counts.
- A `BY MODEL` section lists models.
- A `TOP PROJECTS` section lists up to 5 projects.
- Clicking the back button returns to the Months list with the year stepper and segmented control preserved.

Go back. Switch to `Type` mode and drill into a month. Confirm:
- The header stat cards become a 2×2 grid (Input / Output / Cache-create / Cache-read) followed by a full-width Cost card.
- BY MODEL and TOP PROJECTS sections are unchanged.

Go back. Switch to `Model` mode and drill into a month. Confirm:
- The header stat cards are the same 2-card layout as in Total mode (Tokens + Cost).
- BY MODEL and TOP PROJECTS sections are unchanged.

- [ ] **Step 10.9: Verify breakdown persistence**

Click `Type`. Quit the app (Cmd-Q from the popover). Re-launch. Open the popover and click Months. Confirm `Type` mode is still selected.

- [ ] **Step 10.10: Confirm no regressions**

Spot-check: Today total in the status row still updates as files change (start a Claude Code session if possible). Limits bar still shows.

---

## Self-Review checklist

Run through this before declaring the implementation complete:

- [ ] All tests pass: `swift test`
- [ ] App builds cleanly: `swift build`
- [ ] No new compiler warnings introduced in modified files
- [ ] Each commit has a focused message; nothing is bundled across unrelated tasks
- [ ] `swift run` smoke test passes (Task 10)
