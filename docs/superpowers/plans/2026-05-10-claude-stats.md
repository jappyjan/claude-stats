# claude-stats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menubar app (`ClaudeStats.app`) that visualizes local Claude Code usage from JSONL session logs, with an Overview tab (totals, trend, model breakdown) and a Projects tab (per-project bars + drill-in).

**Architecture:** Swift Package, SwiftUI `MenuBarExtra`, single-binary executable bundled into a `.app`. Reads `~/.claude/projects/**/*.jsonl` incrementally into a SQLite database via `import SQLite3`, queries aggregations via SQL, refreshes pricing from LiteLLM's community JSON. Components are small and testable: parser → store → reader → view-model → views.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14+, system `SQLite3`, `URLSession`, `SMAppService`. Zero third-party dependencies.

**Reference spec:** `docs/superpowers/specs/2026-05-10-claude-stats-design.md`

---

## File map

```
claude-stats/
├── .gitignore
├── Package.swift
├── README.md
├── Sources/ClaudeStats/
│   ├── App/
│   │   ├── ClaudeStatsApp.swift
│   │   └── PopoverView.swift
│   ├── Views/
│   │   ├── OverviewView.swift
│   │   ├── ProjectsView.swift
│   │   ├── ProjectDetailView.swift
│   │   ├── TimeRangeTabs.swift
│   │   ├── ProjectRow.swift
│   │   ├── StatCard.swift
│   │   ├── TrendChart.swift
│   │   ├── ModelChip.swift
│   │   └── SettingsSheet.swift
│   ├── Model/
│   │   ├── UsageEntry.swift
│   │   ├── TimeRange.swift
│   │   ├── ProjectName.swift
│   │   └── PricingTable.swift
│   ├── Storage/
│   │   ├── SQLite.swift
│   │   └── UsageStore.swift
│   ├── Ingest/
│   │   ├── JSONLParser.swift
│   │   ├── UsageReader.swift
│   │   └── ActivityMonitor.swift
│   ├── Pricing/
│   │   └── PricingFetcher.swift
│   ├── ViewModel/
│   │   └── StatsViewModel.swift
│   └── Resources/
│       ├── pricing-fallback.json
│       └── Info.plist
├── Tests/ClaudeStatsTests/
│   ├── JSONLParserTests.swift
│   ├── UsageStoreTests.swift
│   ├── UsageReaderTests.swift
│   ├── PricingTableTests.swift
│   ├── PricingFetcherTests.swift
│   ├── TimeRangeTests.swift
│   ├── ProjectNameTests.swift
│   ├── StatsViewModelTests.swift
│   └── Fixtures/
│       └── sample.jsonl
└── scripts/
    ├── build.sh
    └── install.sh
```

---

### Task 1: Project scaffolding

**Files:**
- Create: `claude-stats/.gitignore`
- Create: `claude-stats/Package.swift`
- Create: `claude-stats/README.md`
- Create: `claude-stats/Sources/ClaudeStats/main.swift` (placeholder, replaced in Task 11)
- Create: `claude-stats/Tests/ClaudeStatsTests/SmokeTests.swift`

- [ ] **Step 1: Initialize git and add `.gitignore`**

```bash
cd /Users/jappy/code/jappyjan/claude-stats
git init
```

Create `.gitignore`:

```
.build/
.swiftpm/
.DS_Store
*.xcodeproj
ClaudeStats.app/
.superpowers/
```

- [ ] **Step 2: Create `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-stats", targets: ["ClaudeStats"]),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeStats",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ClaudeStatsTests",
            dependencies: ["ClaudeStats"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 3: Create placeholder `main.swift` and a smoke test**

`Sources/ClaudeStats/main.swift`:

```swift
print("ClaudeStats")
```

`Tests/ClaudeStatsTests/SmokeTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class SmokeTests: XCTestCase {
    func testItCompiles() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 4: Create empty `Resources/` directory and a stub README**

```bash
mkdir -p Sources/ClaudeStats/Resources
touch Sources/ClaudeStats/Resources/.gitkeep
```

`README.md`:

```markdown
# claude-stats

A macOS menubar app showing your Claude Code usage from local JSONL logs.

## Install

    git clone <repo>
    cd claude-stats
    ./scripts/install.sh

The app will appear in `~/Applications/ClaudeStats.app` and launch automatically.
```

- [ ] **Step 5: Verify build and tests pass**

Run:
```bash
swift build
swift test
```
Expected: both succeed; smoke test passes.

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "scaffold: initialize Swift package with smoke test"
```

---

### Task 2: TimeRange enum

**Files:**
- Create: `Sources/ClaudeStats/Model/TimeRange.swift`
- Test: `Tests/ClaudeStatsTests/TimeRangeTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeStatsTests/TimeRangeTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class TimeRangeTests: XCTestCase {
    // Reference moment: 2026-05-10 14:00:00 UTC
    let now = Date(timeIntervalSince1970: 1778423400)
    let cal = Calendar(identifier: .gregorian)

    func testTodayStartsAtLocalMidnight() {
        let r = TimeRange.today.bounds(now: now, calendar: utc())
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 1778371200)) // 2026-05-10 00:00 UTC
        XCTAssertEqual(r.end, now)
    }

    func testSevenDaysGoesBackSevenFullDays() {
        let r = TimeRange.last7Days.bounds(now: now, calendar: utc())
        // Start = midnight 7 days ago
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 1778371200 - 6 * 86400))
        XCTAssertEqual(r.end, now)
    }

    func testThirtyDaysGoesBackThirty() {
        let r = TimeRange.last30Days.bounds(now: now, calendar: utc())
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 1778371200 - 29 * 86400))
        XCTAssertEqual(r.end, now)
    }

    func testAllStartsAtEpoch() {
        let r = TimeRange.all.bounds(now: now, calendar: utc())
        XCTAssertEqual(r.start, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.end, now)
    }

    func testPriorPeriodTodayIsYesterday() {
        let r = TimeRange.today.priorBounds(now: now, calendar: utc())
        let yesterdayStart = Date(timeIntervalSince1970: 1778371200 - 86400)
        XCTAssertEqual(r?.start, yesterdayStart)
        XCTAssertEqual(r?.end, Date(timeIntervalSince1970: 1778371200))
    }

    func testPriorPeriodAllIsNil() {
        XCTAssertNil(TimeRange.all.priorBounds(now: now, calendar: utc()))
    }

    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter TimeRangeTests`
Expected: FAIL — `TimeRange` not defined.

- [ ] **Step 3: Implement `TimeRange`**

`Sources/ClaudeStats/Model/TimeRange.swift`:

```swift
import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case last30Days
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "7d"
        case .last30Days: return "30d"
        case .all: return "All"
        }
    }

    struct Bounds: Equatable {
        let start: Date
        let end: Date
    }

    func bounds(now: Date = Date(), calendar: Calendar = .current) -> Bounds {
        let midnight = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return Bounds(start: midnight, end: now)
        case .last7Days:
            return Bounds(start: midnight.addingTimeInterval(-6 * 86400), end: now)
        case .last30Days:
            return Bounds(start: midnight.addingTimeInterval(-29 * 86400), end: now)
        case .all:
            return Bounds(start: Date(timeIntervalSince1970: 0), end: now)
        }
    }

    /// Same-length window immediately preceding `bounds`. Nil for `.all`.
    func priorBounds(now: Date = Date(), calendar: Calendar = .current) -> Bounds? {
        guard self != .all else { return nil }
        let current = bounds(now: now, calendar: calendar)
        let length = current.end.timeIntervalSince(current.start)
        return Bounds(
            start: current.start.addingTimeInterval(-length),
            end: current.start
        )
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter TimeRangeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Model/TimeRange.swift Tests/ClaudeStatsTests/TimeRangeTests.swift
git commit -m "model: add TimeRange enum with bounds and prior-period helpers"
```

---

### Task 3: ProjectName helper

**Files:**
- Create: `Sources/ClaudeStats/Model/ProjectName.swift`
- Test: `Tests/ClaudeStatsTests/ProjectNameTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeStatsTests/ProjectNameTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class ProjectNameTests: XCTestCase {
    func testStandardOrgRepoPath() {
        XCTAssertEqual(
            ProjectName.display(for: "/Users/jappy/code/attraccess/Attraccess"),
            "Attraccess"
        )
    }

    func testJappyjanRepoPath() {
        XCTAssertEqual(
            ProjectName.display(for: "/Users/jappy/code/jappyjan/claude-stats"),
            "claude-stats"
        )
    }

    func testWorktreeCollapsesToParentRepo() {
        XCTAssertEqual(
            ProjectName.display(for: "/Users/jappy/code/attraccess/Attraccess/.claude/worktrees/naughty-tharp"),
            "Attraccess"
        )
    }

    func testNoProjectPath() {
        XCTAssertEqual(
            ProjectName.display(for: "/Users/jappy/-no-project"),
            "no-project"
        )
    }

    func testUnknownPathFallsBackToLastComponent() {
        XCTAssertEqual(
            ProjectName.display(for: "/tmp/scratch/foo"),
            "foo"
        )
    }

    func testCanonicalKeyCollapsesWorktrees() {
        let a = ProjectName.canonicalKey(for: "/Users/jappy/code/attraccess/Attraccess")
        let b = ProjectName.canonicalKey(for: "/Users/jappy/code/attraccess/Attraccess/.claude/worktrees/naughty-tharp")
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ProjectNameTests`
Expected: FAIL — `ProjectName` not defined.

- [ ] **Step 3: Implement `ProjectName`**

`Sources/ClaudeStats/Model/ProjectName.swift`:

```swift
import Foundation

enum ProjectName {
    /// Display name for a project, derived from its cwd.
    static func display(for path: String) -> String {
        let canonical = canonicalKey(for: path)
        if canonical.hasPrefix("/Users/jappy/-") {
            return String(canonical.dropFirst("/Users/jappy/-".count))
        }
        return (canonical as NSString).lastPathComponent
    }

    /// Canonical project key — collapses worktrees to their parent repo path.
    static func canonicalKey(for path: String) -> String {
        // Worktree pattern: <repo>/.claude/worktrees/<name>[/...]
        if let range = path.range(of: "/.claude/worktrees/") {
            return String(path[..<range.lowerBound])
        }
        return path
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ProjectNameTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Model/ProjectName.swift Tests/ClaudeStatsTests/ProjectNameTests.swift
git commit -m "model: add ProjectName with worktree collapse and display formatting"
```

---

### Task 4: UsageEntry + JSONLParser

**Files:**
- Create: `Sources/ClaudeStats/Model/UsageEntry.swift`
- Create: `Sources/ClaudeStats/Ingest/JSONLParser.swift`
- Create: `Tests/ClaudeStatsTests/Fixtures/sample.jsonl`
- Test: `Tests/ClaudeStatsTests/JSONLParserTests.swift`

- [ ] **Step 1: Create the test fixture**

`Tests/ClaudeStatsTests/Fixtures/sample.jsonl`:

```jsonl
{"type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-05-10T10:00:00.000Z","sessionId":"abc","cwd":"/Users/jappy/code/jappyjan/claude-stats"}
{"type":"assistant","message":{"model":"claude-opus-4-7","role":"assistant","usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":50,"cache_read_input_tokens":300}},"timestamp":"2026-05-10T10:00:05.000Z","sessionId":"abc","cwd":"/Users/jappy/code/jappyjan/claude-stats"}
{"type":"progress","data":{"hookEvent":"PostToolUse"},"timestamp":"2026-05-10T10:00:06.000Z","sessionId":"abc","cwd":"/Users/jappy/code/jappyjan/claude-stats"}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-05-10T10:01:00.000Z","sessionId":"abc","cwd":"/Users/jappy/code/jappyjan/claude-stats"}
{this line is malformed JSON
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-05-10T10:02:00.000Z","sessionId":"abc"}
```

- [ ] **Step 2: Write failing tests**

`Tests/ClaudeStatsTests/JSONLParserTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class JSONLParserTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        let url = Bundle.module.url(forResource: "sample", withExtension: "jsonl", subdirectory: "Fixtures")
        return try XCTUnwrap(url)
    }

    func testParsesAssistantMessagesWithUsage() throws {
        let parser = JSONLParser()
        let result = try parser.parse(fileURL: fixtureURL(), fromOffset: 0)
        // Two assistant messages with usage; user/progress/queue/malformed all skipped.
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].model, "claude-opus-4-7")
        XCTAssertEqual(result.entries[0].inputTokens, 100)
        XCTAssertEqual(result.entries[0].outputTokens, 200)
        XCTAssertEqual(result.entries[0].cacheCreationTokens, 50)
        XCTAssertEqual(result.entries[0].cacheReadTokens, 300)
        XCTAssertEqual(result.entries[0].sessionId, "abc")
        XCTAssertEqual(result.entries[0].projectPath, "/Users/jappy/code/jappyjan/claude-stats")
        XCTAssertEqual(result.entries[1].model, "claude-sonnet-4-6")
    }

    func testReturnsEndOffsetEqualToFileSize() throws {
        let url = try fixtureURL()
        let parser = JSONLParser()
        let result = try parser.parse(fileURL: url, fromOffset: 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertEqual(result.endOffset, Int64(size))
    }

    func testTruncatedTrailingLineLeavesOffsetAtLastNewline() throws {
        // Build a temp file: one valid line + one half-written line (no trailing newline).
        let valid = #"{"type":"assistant","message":{"model":"m","role":"assistant","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-05-10T10:00:00.000Z","sessionId":"s","cwd":"/p"}"#
        let truncated = #"{"type":"assistant","message":{"model":"m","ro"#
        let content = valid + "\n" + truncated
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trunc-\(UUID().uuidString).jsonl")
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parser = JSONLParser()
        let result = try parser.parse(fileURL: tmp, fromOffset: 0)
        XCTAssertEqual(result.entries.count, 1)
        // Offset should be at end of the first complete line (after its newline).
        let validBytes = Int64((valid + "\n").utf8.count)
        XCTAssertEqual(result.endOffset, validBytes)
    }

    func testIncrementalParseFromOffset() throws {
        let url = try fixtureURL()
        let parser = JSONLParser()
        let firstPass = try parser.parse(fileURL: url, fromOffset: 0)
        // Second pass from the end should yield zero new entries.
        let secondPass = try parser.parse(fileURL: url, fromOffset: firstPass.endOffset)
        XCTAssertEqual(secondPass.entries.count, 0)
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter JSONLParserTests`
Expected: FAIL — `JSONLParser` and `UsageEntry` not defined.

- [ ] **Step 4: Implement `UsageEntry`**

`Sources/ClaudeStats/Model/UsageEntry.swift`:

```swift
import Foundation

struct UsageEntry: Equatable {
    let timestamp: Date
    let sessionId: String
    let projectPath: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}
```

- [ ] **Step 5: Implement `JSONLParser`**

`Sources/ClaudeStats/Ingest/JSONLParser.swift`:

```swift
import Foundation

struct JSONLParser {
    struct ParseResult {
        let entries: [UsageEntry]
        let endOffset: Int64
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func parse(fileURL: URL, fromOffset offset: Int64) throws -> ParseResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.readToEnd() ?? Data()

        var entries: [UsageEntry] = []
        var consumedBytes: Int64 = 0
        var lineStart = data.startIndex

        for index in data.indices {
            if data[index] == 0x0A { // '\n'
                let lineRange = lineStart..<index
                if let entry = decodeLine(data[lineRange]) {
                    entries.append(entry)
                }
                consumedBytes = Int64(index - data.startIndex + 1)
                lineStart = data.index(after: index)
            }
        }
        // Anything after the last newline is incomplete; leave it for next time.

        return ParseResult(entries: entries, endOffset: offset + consumedBytes)
    }

    private func decodeLine(_ data: Data) -> UsageEntry? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let type = obj["type"] as? String, type == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let timestampStr = obj["timestamp"] as? String,
              let timestamp = Self.isoFormatter.date(from: timestampStr),
              let sessionId = obj["sessionId"] as? String,
              let cwd = obj["cwd"] as? String
        else { return nil }

        return UsageEntry(
            timestamp: timestamp,
            sessionId: sessionId,
            projectPath: cwd,
            model: model,
            inputTokens: (usage["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage["output_tokens"] as? Int) ?? 0,
            cacheCreationTokens: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheReadTokens: (usage["cache_read_input_tokens"] as? Int) ?? 0
        )
    }
}
```

- [ ] **Step 6: Run tests to verify pass**

Run: `swift test --filter JSONLParserTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeStats/Model/UsageEntry.swift Sources/ClaudeStats/Ingest/JSONLParser.swift Tests/ClaudeStatsTests/JSONLParserTests.swift Tests/ClaudeStatsTests/Fixtures/sample.jsonl
git commit -m "ingest: add JSONLParser with truncated-line recovery and incremental offset"
```

---

### Task 5: SQLite wrapper + UsageStore

**Files:**
- Create: `Sources/ClaudeStats/Storage/SQLite.swift`
- Create: `Sources/ClaudeStats/Storage/UsageStore.swift`
- Test: `Tests/ClaudeStatsTests/UsageStoreTests.swift`

- [ ] **Step 1: Implement a thin SQLite wrapper**

`Sources/ClaudeStats/Storage/SQLite.swift`:

```swift
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

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw DBError.exec(msg)
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
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT); return self
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
```

- [ ] **Step 2: Write failing tests for `UsageStore`**

`Tests/ClaudeStatsTests/UsageStoreTests.swift`:

```swift
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
        input: Int = 100, output: Int = 50,
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
```

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter UsageStoreTests`
Expected: FAIL — `UsageStore` not defined.

- [ ] **Step 4: Implement `UsageStore`**

`Sources/ClaudeStats/Storage/UsageStore.swift`:

```swift
import Foundation

final class UsageStore {
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
        stmt.bind(1, Int64(start.timeIntervalSince1970)).bind(2, Int64(end.timeIntervalSince1970))
        _ = try stmt.step()
        return Int(stmt.int(0))
    }

    func tokenTotals(start: Date, end: Date) throws -> TokenTotals {
        let stmt = try db.prepare("""
            SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(cache_create_tokens),0), COALESCE(SUM(cache_read_tokens),0)
            FROM usage_event WHERE timestamp BETWEEN ? AND ?
        """)
        stmt.bind(1, Int64(start.timeIntervalSince1970)).bind(2, Int64(end.timeIntervalSince1970))
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
        stmt.bind(1, Int64(start.timeIntervalSince1970)).bind(2, Int64(end.timeIntervalSince1970))
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
        stmt.bind(1, Int64(start.timeIntervalSince1970)).bind(2, Int64(end.timeIntervalSince1970))
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
        stmt.bind(1, Int64(start.timeIntervalSince1970)).bind(2, Int64(end.timeIntervalSince1970))
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
        stmt.bind(1, Int64(start.timeIntervalSince1970))
            .bind(2, Int64(end.timeIntervalSince1970))
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
        stmt.bind(1, Int64(start.timeIntervalSince1970)).bind(2, Int64(end.timeIntervalSince1970))
        var result: [Date: Int] = [:]
        while try stmt.step() {
            let ts = Date(timeIntervalSince1970: TimeInterval(stmt.int(0)))
            let day = calendar.startOfDay(for: ts)
            result[day, default: 0] += Int(stmt.int(1))
        }
        return result
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
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter UsageStoreTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStats/Storage/ Tests/ClaudeStatsTests/UsageStoreTests.swift
git commit -m "storage: add SQLite wrapper and UsageStore with aggregations"
```

---

### Task 6: UsageReader (incremental directory scan)

**Files:**
- Create: `Sources/ClaudeStats/Ingest/UsageReader.swift`
- Test: `Tests/ClaudeStatsTests/UsageReaderTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeStatsTests/UsageReaderTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class UsageReaderTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ relPath: String, _ lines: [String]) throws -> URL {
        let url = tmp.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func validLine(model: String, ts: String) -> String {
        #"{"type":"assistant","message":{"model":"\#(model)","role":"assistant","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s","cwd":"/p"}"#
    }

    func testInitialScanInsertsAllAssistantLines() throws {
        _ = try write("proj-a/sess1.jsonl", [validLine(model: "m1", ts: "2026-05-10T10:00:00.000Z")])
        _ = try write("proj-a/sess1/subagents/agent-x.jsonl", [validLine(model: "m2", ts: "2026-05-10T10:01:00.000Z")])
        let store = try UsageStore(path: ":memory:")
        let reader = UsageReader(rootDir: tmp, store: store)
        try reader.scan()
        XCTAssertEqual(try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)), 4)
    }

    func testIncrementalScanOnlyReadsNewLines() throws {
        let url = try write("proj/sess.jsonl", [validLine(model: "m1", ts: "2026-05-10T10:00:00.000Z")])
        let store = try UsageStore(path: ":memory:")
        let reader = UsageReader(rootDir: tmp, store: store)
        try reader.scan()
        XCTAssertEqual(try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)), 2)

        // Append and bump mtime.
        try (validLine(model: "m1", ts: "2026-05-10T10:05:00.000Z") + "\n").data(using: .utf8)!.append(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        try reader.scan()
        XCTAssertEqual(try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)), 4)
    }

    func testUnchangedFileIsSkipped() throws {
        let url = try write("proj/sess.jsonl", [validLine(model: "m1", ts: "2026-05-10T10:00:00.000Z")])
        let store = try UsageStore(path: ":memory:")
        let reader = UsageReader(rootDir: tmp, store: store)
        try reader.scan()
        let before = try store.fileState(path: url.path)?.lastOffset
        try reader.scan() // no changes — should be a no-op
        let after = try store.fileState(path: url.path)?.lastOffset
        XCTAssertEqual(before, after)
        XCTAssertEqual(try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)), 2)
    }

    func testActiveIfFileMtimeWithinThreshold() throws {
        let url = try write("proj/sess.jsonl", [validLine(model: "m1", ts: "2026-05-10T10:00:00.000Z")])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: url.path)
        let reader = UsageReader(rootDir: tmp, store: try UsageStore(path: ":memory:"))
        XCTAssertTrue(reader.isActive(within: 30))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: url.path)
        XCTAssertFalse(reader.isActive(within: 30))
    }
}

private extension Data {
    func append(to url: URL) throws {
        if let h = try? FileHandle(forWritingTo: url) {
            try h.seekToEnd()
            try h.write(contentsOf: self)
            try h.close()
        } else {
            try self.write(to: url)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter UsageReaderTests`
Expected: FAIL — `UsageReader` not defined.

- [ ] **Step 3: Implement `UsageReader`**

`Sources/ClaudeStats/Ingest/UsageReader.swift`:

```swift
import Foundation

final class UsageReader {
    private let rootDir: URL
    private let store: UsageStore
    private let parser = JSONLParser()

    init(rootDir: URL, store: UsageStore) {
        self.rootDir = rootDir
        self.store = store
    }

    /// One full pass over the directory tree. Inserts only new entries.
    func scan() throws {
        guard FileManager.default.fileExists(atPath: rootDir.path) else { return }
        for url in jsonlFiles() {
            try processFile(url)
        }
    }

    /// True if any tracked JSONL file has been modified within `seconds` of now.
    func isActive(within seconds: TimeInterval) -> Bool {
        let cutoff = Date().addingTimeInterval(-seconds)
        for url in jsonlFiles() {
            if let mtime = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
               mtime > cutoff {
                return true
            }
        }
        return false
    }

    private func jsonlFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootDir,
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" {
                urls.append(url)
            }
        }
        return urls
    }

    private func processFile(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mdate = attrs[.modificationDate] as? Date else { return }
        let mtime = Int64(mdate.timeIntervalSince1970)
        let size = (attrs[.size] as? Int64) ?? 0

        let prior = try store.fileState(path: url.path)
        if let prior = prior, prior.mtime == mtime, prior.lastOffset == size {
            return // unchanged
        }

        let startOffset = prior?.lastOffset ?? 0
        let result = try parser.parse(fileURL: url, fromOffset: startOffset)
        try store.insert(result.entries)
        try store.upsertFileState(path: url.path, mtime: mtime, lastOffset: result.endOffset)
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter UsageReaderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Ingest/UsageReader.swift Tests/ClaudeStatsTests/UsageReaderTests.swift
git commit -m "ingest: add UsageReader with incremental scan and active-session check"
```

---

### Task 7: PricingTable

**Files:**
- Create: `Sources/ClaudeStats/Model/PricingTable.swift`
- Create: `Sources/ClaudeStats/Resources/pricing-fallback.json`
- Test: `Tests/ClaudeStatsTests/PricingTableTests.swift`

- [ ] **Step 1: Create `pricing-fallback.json`**

`Sources/ClaudeStats/Resources/pricing-fallback.json` — minimal subset matching the LiteLLM JSON shape (subset of fields we use). Captured 2026-05-10:

```json
{
  "claude-opus-4-7": {
    "input_cost_per_token": 0.000015,
    "output_cost_per_token": 0.000075,
    "cache_creation_input_token_cost": 0.00001875,
    "cache_read_input_token_cost": 0.0000015
  },
  "claude-opus-4-6": {
    "input_cost_per_token": 0.000015,
    "output_cost_per_token": 0.000075,
    "cache_creation_input_token_cost": 0.00001875,
    "cache_read_input_token_cost": 0.0000015
  },
  "claude-sonnet-4-6": {
    "input_cost_per_token": 0.000003,
    "output_cost_per_token": 0.000015,
    "cache_creation_input_token_cost": 0.00000375,
    "cache_read_input_token_cost": 0.0000003
  },
  "claude-haiku-4-5": {
    "input_cost_per_token": 0.000001,
    "output_cost_per_token": 0.000005,
    "cache_creation_input_token_cost": 0.00000125,
    "cache_read_input_token_cost": 0.0000001
  },
  "claude-haiku-4-5-20251001": {
    "input_cost_per_token": 0.000001,
    "output_cost_per_token": 0.000005,
    "cache_creation_input_token_cost": 0.00000125,
    "cache_read_input_token_cost": 0.0000001
  }
}
```

- [ ] **Step 2: Write failing tests**

`Tests/ClaudeStatsTests/PricingTableTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class PricingTableTests: XCTestCase {
    func testCostForKnownModel() {
        let table = PricingTable(rates: [
            "claude-opus-4-7": .init(input: 0.000015, output: 0.000075, cacheCreate: 0.00001875, cacheRead: 0.0000015)
        ])
        let entry = UsageEntry(
            timestamp: Date(), sessionId: "s", projectPath: "/p", model: "claude-opus-4-7",
            inputTokens: 1000, outputTokens: 500,
            cacheCreationTokens: 200, cacheReadTokens: 10000
        )
        let cost = table.cost(for: entry)
        // 1000*1.5e-5 + 500*7.5e-5 + 200*1.875e-5 + 10000*1.5e-6
        // = 0.015 + 0.0375 + 0.00375 + 0.015 = 0.07125
        XCTAssertEqual(cost ?? 0, 0.07125, accuracy: 1e-9)
    }

    func testCostForUnknownModelReturnsNil() {
        let table = PricingTable(rates: [:])
        let entry = UsageEntry(
            timestamp: Date(), sessionId: "s", projectPath: "/p", model: "claude-unknown",
            inputTokens: 1000, outputTokens: 500, cacheCreationTokens: 0, cacheReadTokens: 0
        )
        XCTAssertNil(table.cost(for: entry))
    }

    func testFromJSONParsesLiteLLMShape() throws {
        let json = #"""
        {
          "claude-opus-4-7": {
            "input_cost_per_token": 0.000015,
            "output_cost_per_token": 0.000075,
            "cache_creation_input_token_cost": 0.00001875,
            "cache_read_input_token_cost": 0.0000015,
            "max_tokens": 8192
          },
          "gpt-4": {
            "input_cost_per_token": 0.00003,
            "output_cost_per_token": 0.00006
          }
        }
        """#
        let table = try PricingTable.fromJSON(Data(json.utf8))
        XCTAssertNotNil(table.rate(for: "claude-opus-4-7"))
        XCTAssertEqual(table.rate(for: "claude-opus-4-7")?.input, 0.000015)
        // Non-anthropic entries are still loaded; we just don't surface them.
        XCTAssertNotNil(table.rate(for: "gpt-4"))
    }

    func testTotalCostAggregatedAcrossEntries() {
        let table = PricingTable(rates: [
            "m": .init(input: 1, output: 2, cacheCreate: 3, cacheRead: 4)
        ])
        let entries = [
            UsageEntry(timestamp: Date(), sessionId: "s", projectPath: "/p", model: "m",
                       inputTokens: 1, outputTokens: 1, cacheCreationTokens: 1, cacheReadTokens: 1),
            UsageEntry(timestamp: Date(), sessionId: "s", projectPath: "/p", model: "m",
                       inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0),
        ]
        XCTAssertEqual(table.totalCost(for: entries), 11)
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter PricingTableTests`
Expected: FAIL — `PricingTable` not defined.

- [ ] **Step 4: Implement `PricingTable`**

`Sources/ClaudeStats/Model/PricingTable.swift`:

```swift
import Foundation

struct PricingTable {
    struct Rate: Equatable {
        let input: Double
        let output: Double
        let cacheCreate: Double
        let cacheRead: Double
    }

    private let rates: [String: Rate]

    init(rates: [String: Rate]) { self.rates = rates }

    func rate(for model: String) -> Rate? { rates[model] }

    func cost(for entry: UsageEntry) -> Double? {
        guard let r = rates[entry.model] else { return nil }
        return Double(entry.inputTokens) * r.input
            + Double(entry.outputTokens) * r.output
            + Double(entry.cacheCreationTokens) * r.cacheCreate
            + Double(entry.cacheReadTokens) * r.cacheRead
    }

    /// Cost for a flat token breakdown — used by `UsageStore` aggregations.
    func cost(model: String, input: Int, output: Int, cacheCreate: Int, cacheRead: Int) -> Double? {
        guard let r = rates[model] else { return nil }
        return Double(input) * r.input
            + Double(output) * r.output
            + Double(cacheCreate) * r.cacheCreate
            + Double(cacheRead) * r.cacheRead
    }

    func totalCost(for entries: [UsageEntry]) -> Double {
        entries.reduce(0.0) { acc, e in acc + (cost(for: e) ?? 0) }
    }

    static func fromJSON(_ data: Data) throws -> PricingTable {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "PricingTable", code: 1)
        }
        var out: [String: Rate] = [:]
        for (model, raw) in obj {
            guard let dict = raw as? [String: Any] else { continue }
            let input = (dict["input_cost_per_token"] as? Double) ?? 0
            let output = (dict["output_cost_per_token"] as? Double) ?? 0
            let cacheCreate = (dict["cache_creation_input_token_cost"] as? Double) ?? 0
            let cacheRead = (dict["cache_read_input_token_cost"] as? Double) ?? 0
            // Only keep entries that at least have input+output costs.
            if input > 0 || output > 0 {
                out[model] = Rate(input: input, output: output, cacheCreate: cacheCreate, cacheRead: cacheRead)
            }
        }
        return PricingTable(rates: out)
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter PricingTableTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStats/Model/PricingTable.swift Sources/ClaudeStats/Resources/pricing-fallback.json Tests/ClaudeStatsTests/PricingTableTests.swift
git commit -m "model: add PricingTable with LiteLLM JSON parser and bundled fallback"
```

---

### Task 8: PricingFetcher (download, cache, fallback)

**Files:**
- Create: `Sources/ClaudeStats/Pricing/PricingFetcher.swift`
- Test: `Tests/ClaudeStatsTests/PricingFetcherTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeStatsTests/PricingFetcherTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class PricingFetcherTests: XCTestCase {
    private var cacheDir: URL!
    override func setUpWithError() throws {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func testReturnsBundledFallbackWhenNoCacheAndFetchFails() async throws {
        let fallback = #"{"claude-test":{"input_cost_per_token":1,"output_cost_per_token":2}}"#
        let fetcher = PricingFetcher(
            cacheDir: cacheDir,
            bundledFallback: Data(fallback.utf8),
            fetcher: { throw URLError(.notConnectedToInternet) }
        )
        let table = try await fetcher.load()
        XCTAssertNotNil(table.rate(for: "claude-test"))
    }

    func testWritesAndReadsCacheOnSuccess() async throws {
        let payload = #"{"claude-net":{"input_cost_per_token":3,"output_cost_per_token":4}}"#
        let fetcher = PricingFetcher(
            cacheDir: cacheDir,
            bundledFallback: Data(),
            fetcher: { Data(payload.utf8) }
        )
        let table = try await fetcher.load()
        XCTAssertEqual(table.rate(for: "claude-net")?.input, 3)
        // File is on disk.
        let cached = cacheDir.appendingPathComponent("pricing.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }

    func testUsesCachedDataWhenFreshAndFetcherFails() async throws {
        // Pre-seed cache.
        let payload = #"{"claude-cached":{"input_cost_per_token":5,"output_cost_per_token":6}}"#
        try Data(payload.utf8).write(to: cacheDir.appendingPathComponent("pricing.json"))
        try "\(Date().timeIntervalSince1970)".write(
            to: cacheDir.appendingPathComponent("pricing.json.fetched_at"),
            atomically: true, encoding: .utf8
        )
        let fetcher = PricingFetcher(
            cacheDir: cacheDir,
            bundledFallback: Data(),
            fetcher: { throw URLError(.timedOut) }
        )
        let table = try await fetcher.load()
        XCTAssertNotNil(table.rate(for: "claude-cached"))
    }

    func testRefetchesWhenCacheStale() async throws {
        // Pre-seed STALE cache (8 days old).
        let stale = #"{"claude-stale":{"input_cost_per_token":1,"output_cost_per_token":1}}"#
        try Data(stale.utf8).write(to: cacheDir.appendingPathComponent("pricing.json"))
        let oldTime = Date().timeIntervalSince1970 - (8 * 86400)
        try "\(oldTime)".write(
            to: cacheDir.appendingPathComponent("pricing.json.fetched_at"),
            atomically: true, encoding: .utf8
        )
        let fresh = #"{"claude-fresh":{"input_cost_per_token":9,"output_cost_per_token":9}}"#
        let fetcher = PricingFetcher(
            cacheDir: cacheDir,
            bundledFallback: Data(),
            fetcher: { Data(fresh.utf8) }
        )
        let table = try await fetcher.load()
        XCTAssertNotNil(table.rate(for: "claude-fresh"))
        XCTAssertNil(table.rate(for: "claude-stale"))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter PricingFetcherTests`
Expected: FAIL — `PricingFetcher` not defined.

- [ ] **Step 3: Implement `PricingFetcher`**

`Sources/ClaudeStats/Pricing/PricingFetcher.swift`:

```swift
import Foundation

actor PricingFetcher {
    static let liteLLMURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/model_prices_and_context_window_backup.json"
    )!
    /// Refresh interval — re-fetch when cache is older than this.
    static let cacheTTL: TimeInterval = 7 * 86400

    private let cacheDir: URL
    private let bundledFallback: Data
    private let fetcher: () async throws -> Data

    init(cacheDir: URL, bundledFallback: Data, fetcher: @escaping () async throws -> Data) {
        self.cacheDir = cacheDir
        self.bundledFallback = bundledFallback
        self.fetcher = fetcher
    }

    convenience init(cacheDir: URL, bundledFallback: Data) {
        self.init(cacheDir: cacheDir, bundledFallback: bundledFallback, fetcher: {
            let (data, _) = try await URLSession.shared.data(from: PricingFetcher.liteLLMURL)
            return data
        })
    }

    func load() async throws -> PricingTable {
        try ensureCacheDir()
        if let cached = readCacheIfFresh() {
            return try PricingTable.fromJSON(cached)
        }
        do {
            let data = try await fetcher()
            try writeCache(data)
            return try PricingTable.fromJSON(data)
        } catch {
            // Network fail: try stale cache, then bundled fallback.
            if let stale = readCacheIgnoringAge() {
                return try PricingTable.fromJSON(stale)
            }
            return try PricingTable.fromJSON(bundledFallback)
        }
    }

    /// Force a refresh attempt, used by the daily timer.
    func refresh() async {
        do {
            let data = try await fetcher()
            try writeCache(data)
        } catch {
            // Silent failure — load() will fall back to cache/bundled next time.
        }
    }

    // MARK: - Cache files

    private var cachedPath: URL { cacheDir.appendingPathComponent("pricing.json") }
    private var stampPath: URL { cacheDir.appendingPathComponent("pricing.json.fetched_at") }

    private func ensureCacheDir() throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func readCacheIfFresh() -> Data? {
        guard FileManager.default.fileExists(atPath: cachedPath.path),
              let stamp = try? String(contentsOf: stampPath),
              let ts = TimeInterval(stamp.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        guard Date().timeIntervalSince1970 - ts < Self.cacheTTL else { return nil }
        return try? Data(contentsOf: cachedPath)
    }

    private func readCacheIgnoringAge() -> Data? {
        try? Data(contentsOf: cachedPath)
    }

    private func writeCache(_ data: Data) throws {
        try data.write(to: cachedPath)
        try "\(Date().timeIntervalSince1970)".write(to: stampPath, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter PricingFetcherTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Pricing/PricingFetcher.swift Tests/ClaudeStatsTests/PricingFetcherTests.swift
git commit -m "pricing: add PricingFetcher with cache, TTL, and bundled fallback"
```

---

### Task 9: ActivityMonitor (timer + active flag)

**Files:**
- Create: `Sources/ClaudeStats/Ingest/ActivityMonitor.swift`

This component wraps `Timer` + `UsageReader`. Its behavior under timer firing is mostly observed via integration in `StatsViewModel`; we keep it small and don't add a dedicated test. The `UsageReader.isActive` logic that backs it is already covered.

- [ ] **Step 1: Implement `ActivityMonitor`**

`Sources/ClaudeStats/Ingest/ActivityMonitor.swift`:

```swift
import Foundation

@MainActor
final class ActivityMonitor {
    private let reader: UsageReader
    private let interval: TimeInterval
    private let activeThreshold: TimeInterval
    private var timer: Timer?

    var onTick: (() -> Void)?

    init(reader: UsageReader, interval: TimeInterval = 10, activeThreshold: TimeInterval = 30) {
        self.reader = reader
        self.interval = interval
        self.activeThreshold = activeThreshold
    }

    func start() {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tickNow()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func tickNow() {
        try? reader.scan()
        onTick?()
    }

    var isActive: Bool { reader.isActive(within: activeThreshold) }
}
```

- [ ] **Step 2: Verify build still passes**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStats/Ingest/ActivityMonitor.swift
git commit -m "ingest: add ActivityMonitor wrapping reader with periodic timer"
```

---

### Task 10: StatsViewModel

**Files:**
- Create: `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`
- Test: `Tests/ClaudeStatsTests/StatsViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeStatsTests/StatsViewModelTests.swift`:

```swift
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
            entry(secondsAgo: 60, project: "/A", input: 100),
            entry(secondsAgo: 60, project: "/B", input: 500),
            entry(secondsAgo: 60, project: "/C", input: 300),
        ])
        let vm = StatsViewModel(store: store, pricing: PricingTable(rates: [:]))
        await vm.refresh()
        XCTAssertEqual(vm.projectRows.map { $0.projectKey }, ["/B", "/C", "/A"])
    }

    func testTimeRangeChangeTriggersRefresh() async throws {
        let store = try makeStore(events: [
            entry(secondsAgo: 60, input: 100),
            entry(secondsAgo: 10 * 86400, input: 5000),
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
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter StatsViewModelTests`
Expected: FAIL — `StatsViewModel` not defined.

- [ ] **Step 3: Implement `StatsViewModel`**

`Sources/ClaudeStats/ViewModel/StatsViewModel.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class StatsViewModel {
    struct Overview: Equatable {
        var totalTokens: Int = 0
        var totalCost: Double = 0
        var sessionCount: Int = 0
        var projectCount: Int = 0
        var cacheHitRate: Double = 0
        var dailyTokens: [Date: Int] = [:]
        var byModel: [UsageStore.ModelRow] = []
        var priorTotalTokens: Int? = nil
        var priorTotalCost: Double? = nil
    }

    struct ProjectDetail: Equatable {
        let projectKey: String
        let totals: UsageStore.ProjectRow
        let cost: Double?
        let percentOfRange: Double
        let byModel: [UsageStore.ModelRow]
        let recentSessions: [UsageStore.SessionRow]
    }

    private let store: UsageStore
    private(set) var pricing: PricingTable

    var timeRange: TimeRange = .today
    var todayTokens: Int = 0
    var isActive: Bool = false
    var overview: Overview = .init()
    var projectRows: [UsageStore.ProjectRow] = []

    init(store: UsageStore, pricing: PricingTable) {
        self.store = store
        self.pricing = pricing
    }

    func update(pricing: PricingTable) {
        self.pricing = pricing
    }

    func refresh() async {
        let now = Date()
        let cal = Calendar.current
        let bounds = timeRange.bounds(now: now, calendar: cal)
        let priorBounds = timeRange.priorBounds(now: now, calendar: cal)

        do {
            // Today total — independent of selected range.
            let todayBounds = TimeRange.today.bounds(now: now, calendar: cal)
            todayTokens = try store.totalTokens(start: todayBounds.start, end: todayBounds.end)

            // Project rows for the selected range.
            projectRows = try store.tokensByProject(start: bounds.start, end: bounds.end)

            // Overview
            let totals = try store.tokenTotals(start: bounds.start, end: bounds.end)
            let sessions = try store.sessionCount(start: bounds.start, end: bounds.end)
            let byModel = try store.tokensByModel(start: bounds.start, end: bounds.end)
            // Daily tokens for the trend chart: always last 14 days regardless of selected range.
            let trendStart = cal.startOfDay(for: now).addingTimeInterval(-13 * 86400)
            let dailyTokens = try store.dailyTokens(start: trendStart, end: now, calendar: cal)
            let totalCost = computeCost(byModel: byModel)

            var priorTokens: Int? = nil
            var priorCost: Double? = nil
            if let prior = priorBounds {
                priorTokens = try store.totalTokens(start: prior.start, end: prior.end)
                let priorByModel = try store.tokensByModel(start: prior.start, end: prior.end)
                priorCost = computeCost(byModel: priorByModel)
            }

            let denom = totals.input + totals.cacheCreate + totals.cacheRead
            let hitRate = denom == 0 ? 0 : Double(totals.cacheRead) / Double(denom)

            overview = Overview(
                totalTokens: totals.total,
                totalCost: totalCost,
                sessionCount: sessions,
                projectCount: projectRows.count,
                cacheHitRate: hitRate,
                dailyTokens: dailyTokens,
                byModel: byModel,
                priorTotalTokens: priorTokens,
                priorTotalCost: priorCost
            )
        } catch {
            // Leave previous state on error; surfaced via logging when wired.
        }
    }

    func projectDetail(for projectKey: String) async -> ProjectDetail? {
        let now = Date()
        let cal = Calendar.current
        let bounds = timeRange.bounds(now: now, calendar: cal)
        do {
            let allRows = try store.tokensByProject(start: bounds.start, end: bounds.end)
            guard let row = allRows.first(where: { $0.projectKey == projectKey }) else { return nil }
            let byModel = try store.tokensByModel(start: bounds.start, end: bounds.end, projectKey: projectKey)
            let sessions = try store.recentSessions(limit: 10, projectKey: projectKey, start: bounds.start, end: bounds.end)
            let cost = computeCost(byModel: byModel)
            let totalRange = allRows.reduce(0) { $0 + $1.totalTokens }
            let pct = totalRange == 0 ? 0 : Double(row.totalTokens) / Double(totalRange)
            return ProjectDetail(
                projectKey: projectKey, totals: row, cost: cost,
                percentOfRange: pct, byModel: byModel, recentSessions: sessions
            )
        } catch {
            return nil
        }
    }

    private func computeCost(byModel rows: [UsageStore.ModelRow]) -> Double {
        rows.reduce(0.0) { acc, row in
            acc + (pricing.cost(model: row.model,
                                input: row.inputTokens,
                                output: row.outputTokens,
                                cacheCreate: row.cacheCreateTokens,
                                cacheRead: row.cacheReadTokens) ?? 0)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter StatsViewModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/ViewModel/StatsViewModel.swift Tests/ClaudeStatsTests/StatsViewModelTests.swift
git commit -m "viewmodel: add StatsViewModel orchestrating store + pricing"
```

---

### Task 11: App entry, MenuBarExtra, popover skeleton

**Files:**
- Delete: `Sources/ClaudeStats/main.swift`
- Create: `Sources/ClaudeStats/App/ClaudeStatsApp.swift`
- Create: `Sources/ClaudeStats/App/PopoverView.swift`
- Create: `Sources/ClaudeStats/App/AppContainer.swift` (DI)

- [ ] **Step 1: Delete the placeholder `main.swift`**

```bash
git rm Sources/ClaudeStats/main.swift
```

- [ ] **Step 2: Create the dependency container**

`Sources/ClaudeStats/App/AppContainer.swift`:

```swift
import Foundation

@MainActor
final class AppContainer {
    let store: UsageStore
    let reader: UsageReader
    let monitor: ActivityMonitor
    let pricingFetcher: PricingFetcher
    let viewModel: StatsViewModel

    init() {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("claude-stats", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let cache = try! FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("claude-stats", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let dbPath = appSupport.appendingPathComponent("usage.db").path
        self.store = try! UsageStore(path: dbPath)

        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        self.reader = UsageReader(rootDir: claudeRoot, store: store)

        let bundled = Bundle.module.url(forResource: "pricing-fallback", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) } ?? Data("{}".utf8)
        self.pricingFetcher = PricingFetcher(cacheDir: cache, bundledFallback: bundled)

        let initialPricing = (try? PricingTable.fromJSON(bundled)) ?? PricingTable(rates: [:])
        self.viewModel = StatsViewModel(store: store, pricing: initialPricing)

        self.monitor = ActivityMonitor(reader: reader)
        monitor.onTick = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.viewModel.isActive = self.monitor.isActive
                await self.viewModel.refresh()
            }
        }
    }

    func startBackgroundWork() {
        monitor.start()
        Task {
            let table = try? await pricingFetcher.load()
            if let table { await MainActor.run { viewModel.update(pricing: table) } }
        }
    }
}
```

- [ ] **Step 3: Create the SwiftUI app**

`Sources/ClaudeStats/App/ClaudeStatsApp.swift`:

```swift
import SwiftUI

@main
struct ClaudeStatsApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(viewModel: container.viewModel)
                .frame(width: 380)
                .onAppear { container.startBackgroundWork() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(container.viewModel.isActive ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(formatTokens(container.viewModel.todayTokens))
                    .font(.system(size: 13, weight: .regular, design: .default).monospacedDigit())
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 4: Create the empty popover container**

`Sources/ClaudeStats/App/PopoverView.swift`:

```swift
import SwiftUI

struct PopoverView: View {
    @Bindable var viewModel: StatsViewModel
    @State private var section: Section = .overview
    @State private var drillProjectKey: String? = nil
    @State private var drillDetail: StatsViewModel.ProjectDetail? = nil

    enum Section: String, CaseIterable { case overview, projects }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            if drillProjectKey == nil {
                sectionTabs
                TimeRangeTabs(selection: $viewModel.timeRange)
                    .onChange(of: viewModel.timeRange) { Task { await viewModel.refresh() } }
                Divider()
                Group {
                    switch section {
                    case .overview: OverviewView(overview: viewModel.overview, range: viewModel.timeRange)
                    case .projects:
                        ProjectsView(rows: viewModel.projectRows, pricing: viewModel.pricing,
                                     onSelect: { key in
                                         drillProjectKey = key
                                         Task { drillDetail = await viewModel.projectDetail(for: key) }
                                     })
                    }
                }
            } else if let detail = drillDetail {
                ProjectDetailView(detail: detail, range: viewModel.timeRange) {
                    drillProjectKey = nil; drillDetail = nil
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusRow: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(viewModel.isActive ? .green : .secondary).frame(width: 7, height: 7)
                Text(viewModel.isActive ? "Active" : "Idle").font(.caption)
            }
            Spacer()
            Text("\(formatTokens(viewModel.todayTokens)) today · ~$\(String(format: "%.2f", viewModel.overview.totalCost))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    private var sectionTabs: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases, id: \.self) { s in
                Button(action: { section = s }) {
                    Text(s.rawValue.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        .foregroundStyle(section == s ? Color.primary : Color.secondary)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(section == s ? Color.accentColor : Color.clear).frame(height: 2)
                        }
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 5: Build (it will fail until views exist) — skip building until Task 12**

Move on to Task 12. (Or temporarily stub the missing views with `Text("…")` to verify compile, then revert.)

- [ ] **Step 6: Commit (with stubs in place — see step 5)**

If you stubbed views to verify compile:

```bash
git add Sources/ClaudeStats/App/
git commit -m "app: add MenuBarExtra entry point and popover skeleton"
```

Otherwise commit alongside Task 12.

---

### Task 12: TimeRangeTabs + StatCard + ModelChip + TrendChart

**Files:**
- Create: `Sources/ClaudeStats/Views/TimeRangeTabs.swift`
- Create: `Sources/ClaudeStats/Views/StatCard.swift`
- Create: `Sources/ClaudeStats/Views/ModelChip.swift`
- Create: `Sources/ClaudeStats/Views/TrendChart.swift`

- [ ] **Step 1: TimeRangeTabs**

`Sources/ClaudeStats/Views/TimeRangeTabs.swift`:

```swift
import SwiftUI

struct TimeRangeTabs: View {
    @Binding var selection: TimeRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { range in
                Button(action: { selection = range }) {
                    Text(range.label)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selection == range ? Color.gray.opacity(0.4) : Color.clear)
                        .foregroundStyle(selection == range ? Color.primary : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}
```

- [ ] **Step 2: StatCard**

`Sources/ClaudeStats/Views/StatCard.swift`:

```swift
import SwiftUI

struct StatCard: View {
    let label: String
    let value: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(sub)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 3: ModelChip**

`Sources/ClaudeStats/Views/ModelChip.swift`:

```swift
import SwiftUI

struct ModelChip: View {
    let model: String

    var body: some View {
        Text(shortName)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .padding(.vertical, 1).padding(.horizontal, 5)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var shortName: String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "OPUS" }
        if lower.contains("sonnet") { return "SONNET" }
        if lower.contains("haiku") { return "HAIKU" }
        return String(model.prefix(8)).uppercased()
    }

    private var color: Color {
        let lower = model.lowercased()
        if lower.contains("opus") { return Color.purple }
        if lower.contains("sonnet") { return Color.blue }
        if lower.contains("haiku") { return Color.green }
        return Color.gray
    }
}
```

- [ ] **Step 4: TrendChart**

`Sources/ClaudeStats/Views/TrendChart.swift`:

```swift
import SwiftUI

struct TrendChart: View {
    let dailyTokens: [Date: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST 14 DAYS").font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days(), id: \.self) { day in
                    let v = dailyTokens[day] ?? 0
                    let h = max(2, CGFloat(v) / CGFloat(maxValue) * 56)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Calendar.current.isDateInToday(day) ? Color.green : Color.purple.gradient.opacity(0.85))
                        .frame(height: h)
                        .frame(maxWidth: .infinity)
                }
            }.frame(height: 56)
            HStack {
                Text("14d ago").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("today").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func days() -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
    }

    private var maxValue: Int {
        max(1, dailyTokens.values.max() ?? 1)
    }
}
```

- [ ] **Step 5: Build to verify compile**

Run: `swift build`
Expected: still missing OverviewView, ProjectsView, ProjectDetailView. That's fine — Task 13 adds them. Or stub temporarily to verify these compile in isolation.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStats/Views/TimeRangeTabs.swift Sources/ClaudeStats/Views/StatCard.swift Sources/ClaudeStats/Views/ModelChip.swift Sources/ClaudeStats/Views/TrendChart.swift
git commit -m "views: add TimeRangeTabs, StatCard, ModelChip, TrendChart"
```

---

### Task 13: OverviewView

**Files:**
- Create: `Sources/ClaudeStats/Views/OverviewView.swift`

- [ ] **Step 1: Implement `OverviewView`**

`Sources/ClaudeStats/Views/OverviewView.swift`:

```swift
import SwiftUI

struct OverviewView: View {
    let overview: StatsViewModel.Overview
    let range: TimeRange

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatCard(label: "Total tokens", value: formatTokens(overview.totalTokens), sub: tokenSub)
                    StatCard(label: "Est. cost", value: "$\(String(format: "%.2f", overview.totalCost))", sub: costSub)
                    StatCard(label: "Sessions", value: "\(overview.sessionCount)", sub: "\(overview.projectCount) project\(overview.projectCount == 1 ? "" : "s")")
                    StatCard(label: "Cache hit rate", value: "\(Int((overview.cacheHitRate * 100).rounded()))%", sub: cacheSub)
                }
                .padding(.horizontal, 14)

                TrendChart(dailyTokens: overview.dailyTokens)
                    .padding(.horizontal, 14)

                Text("BY MODEL · \(range.label.uppercased())")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(overview.byModel, id: \.model) { row in
                        HStack {
                            ModelChip(model: row.model)
                            Spacer()
                            Text(formatTokens(row.totalTokens)).font(.system(size: 12)).monospacedDigit()
                        }
                        .padding(.vertical, 6).padding(.horizontal, 14)
                        Divider()
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var tokenSub: String {
        if let prior = overview.priorTotalTokens, prior > 0 {
            let delta = Double(overview.totalTokens - prior) / Double(prior) * 100
            let sign = delta >= 0 ? "+" : ""
            return "\(sign)\(Int(delta.rounded()))% vs prior period"
        }
        return ""
    }
    private var costSub: String {
        if let prior = overview.priorTotalCost, prior > 0 {
            let delta = (overview.totalCost - prior) / prior * 100
            let sign = delta >= 0 ? "+" : ""
            return "\(sign)\(Int(delta.rounded()))% vs prior period"
        }
        return ""
    }
    private var cacheSub: String {
        let reads = overview.byModel.reduce(0) { $0 + $1.cacheReadTokens }
        return "\(formatTokens(reads)) cache reads"
    }
    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/ClaudeStats/Views/OverviewView.swift
git commit -m "views: add OverviewView with stat grid, trend, and model breakdown"
```

---

### Task 14: ProjectsView + ProjectRow

**Files:**
- Create: `Sources/ClaudeStats/Views/ProjectRow.swift`
- Create: `Sources/ClaudeStats/Views/ProjectsView.swift`

- [ ] **Step 1: ProjectRow**

`Sources/ClaudeStats/Views/ProjectRow.swift`:

```swift
import SwiftUI

struct ProjectRow: View {
    let row: UsageStore.ProjectRow
    let cost: Double?
    let widthFraction: Double // 0.0–1.0

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ProjectName.display(for: row.projectKey))
                    .font(.system(size: 13, weight: .medium))
                GeometryReader { geo in
                    LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * widthFraction, height: 3)
                        .clipShape(Capsule())
                }
                .frame(height: 3)
            }
            Spacer()
            Text(formatTokens(row.totalTokens))
                .font(.system(size: 12)).monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            Text(cost.map { "$\(String(format: "%.2f", $0))" } ?? "—")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 2: ProjectsView**

`Sources/ClaudeStats/Views/ProjectsView.swift`:

```swift
import SwiftUI

struct ProjectsView: View {
    let rows: [UsageStore.ProjectRow]
    let pricing: PricingTable
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows, id: \.projectKey) { row in
                    Button(action: { onSelect(row.projectKey) }) {
                        ProjectRow(
                            row: row,
                            cost: rowCost(row),
                            widthFraction: maxTokens == 0 ? 0 : Double(row.totalTokens) / Double(maxTokens)
                        )
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var maxTokens: Int { rows.first?.totalTokens ?? 0 }

    private func rowCost(_ row: UsageStore.ProjectRow) -> Double? {
        // Cost requires per-model breakdown; we approximate by summing token rates of unknown distribution.
        // For an approximate row-level number, use the dominant model in that range.
        // (Detail view shows precise per-model cost.)
        return nil
    }
}
```

The above's row-level cost is `nil` for simplicity — detail view shows precise cost. To show a per-row cost we'd need a per-project-per-model breakdown. Defer that to a follow-up (`ProjectsView` row currently shows `—` for cost when nil).

- [ ] **Step 3: Update `UsageStore` to expose per-project-per-model so we can compute row cost properly — minimal addition**

Add to `Sources/ClaudeStats/Storage/UsageStore.swift`:

```swift
struct ProjectModelRow: Equatable {
    let projectKey: String, model: String
    let inputTokens: Int, outputTokens: Int, cacheCreateTokens: Int, cacheReadTokens: Int
}

func tokensByProjectAndModel(start: Date, end: Date) throws -> [ProjectModelRow] {
    let stmt = try db.prepare("""
        SELECT project_key, model,
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_create_tokens), SUM(cache_read_tokens)
        FROM usage_event WHERE timestamp BETWEEN ? AND ?
        GROUP BY project_key, model
    """)
    stmt.bind(1, Int64(start.timeIntervalSince1970)).bind(2, Int64(end.timeIntervalSince1970))
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
```

- [ ] **Step 4: Update `StatsViewModel` to expose project costs**

In `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`, add:

```swift
var projectCosts: [String: Double] = [:]
```

Inside `refresh()`, after computing project rows:

```swift
let projModelRows = try store.tokensByProjectAndModel(start: bounds.start, end: bounds.end)
var costs: [String: Double] = [:]
for r in projModelRows {
    let c = pricing.cost(model: r.model, input: r.inputTokens, output: r.outputTokens,
                         cacheCreate: r.cacheCreateTokens, cacheRead: r.cacheReadTokens)
    if let c { costs[r.projectKey, default: 0] += c }
}
projectCosts = costs
```

- [ ] **Step 5: Wire `projectCosts` into `ProjectsView`**

In `PopoverView.swift`, change the `.projects` case:

```swift
case .projects:
    ProjectsView(rows: viewModel.projectRows,
                 costs: viewModel.projectCosts,
                 onSelect: { key in
                     drillProjectKey = key
                     Task { drillDetail = await viewModel.projectDetail(for: key) }
                 })
```

And update `ProjectsView.swift`:

```swift
struct ProjectsView: View {
    let rows: [UsageStore.ProjectRow]
    let costs: [String: Double]
    let onSelect: (String) -> Void
    // ... body unchanged except rowCost:
    private func rowCost(_ row: UsageStore.ProjectRow) -> Double? { costs[row.projectKey] }
    // ... and pass `cost: rowCost(row)` as before
}
```

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStats/Views/ProjectRow.swift Sources/ClaudeStats/Views/ProjectsView.swift Sources/ClaudeStats/Storage/UsageStore.swift Sources/ClaudeStats/ViewModel/StatsViewModel.swift Sources/ClaudeStats/App/PopoverView.swift
git commit -m "views: add ProjectsView with per-project bars and cost"
```

---

### Task 15: ProjectDetailView

**Files:**
- Create: `Sources/ClaudeStats/Views/ProjectDetailView.swift`

- [ ] **Step 1: Implement `ProjectDetailView`**

`Sources/ClaudeStats/Views/ProjectDetailView.swift`:

```swift
import SwiftUI

struct ProjectDetailView: View {
    let detail: StatsViewModel.ProjectDetail
    let range: TimeRange
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Projects").font(.system(size: 13))
                    }
                    .foregroundStyle(Color.accentColor)
                }.buttonStyle(.plain)
                Spacer()
                Text(ProjectName.display(for: detail.projectKey))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 60)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        StatCard(
                            label: "Tokens",
                            value: formatTokens(detail.totals.totalTokens),
                            sub: "\(Int((detail.percentOfRange * 100).rounded()))% of range"
                        )
                        StatCard(
                            label: "Est. cost",
                            value: detail.cost.map { "$\(String(format: "%.2f", $0))" } ?? "—",
                            sub: "\(detail.totals.sessionCount) session\(detail.totals.sessionCount == 1 ? "" : "s")"
                        )
                    }
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

                    Text("RECENT SESSIONS")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(detail.recentSessions, id: \.sessionId) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(String(s.sessionId.prefix(8)) + "…")
                                        .font(.system(.caption, design: .monospaced))
                                    Text(relativeWhen(s))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatTokens(s.totalTokens))
                                    .font(.system(size: 11)).monospacedDigit()
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

    private func relativeWhen(_ s: UsageStore.SessionRow) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: s.lastTimestamp, relativeTo: Date())
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 2: Build the full app**

Run: `swift build`
Expected: builds cleanly. (If it fails, fix any signature mismatch — the views and view model must match.)

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStats/Views/ProjectDetailView.swift
git commit -m "views: add ProjectDetailView drill-in with stats, model breakdown, sessions"
```

---

### Task 16: Midnight rollover + wake handling + 24h pricing refresh

**Files:**
- Modify: `Sources/ClaudeStats/App/AppContainer.swift`

- [ ] **Step 1: Add scheduling logic**

In `Sources/ClaudeStats/App/AppContainer.swift`, add a private method and wire it into `startBackgroundWork`:

```swift
import AppKit  // add to existing imports

extension AppContainer {
    func startBackgroundWork() {
        monitor.start()
        Task { await refreshPricingNow() }
        scheduleMidnightRollover()
        scheduleDailyPricingRefresh()
        registerWakeNotifications()
    }

    private func refreshPricingNow() async {
        await pricingFetcher.refresh()
        if let table = try? await pricingFetcher.load() {
            await MainActor.run { viewModel.update(pricing: table) }
        }
    }

    private func scheduleMidnightRollover() {
        let cal = Calendar.current
        let now = Date()
        let nextMidnight = cal.date(bySettingHour: 0, minute: 0, second: 0,
                                    of: cal.date(byAdding: .day, value: 1, to: now)!)!
        let interval = nextMidnight.timeIntervalSince(now)
        Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.viewModel.refresh()
                self?.scheduleMidnightRollover()
            }
        }
    }

    private func scheduleDailyPricingRefresh() {
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { await self?.refreshPricingNow() }
        }
    }

    private func registerWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.tickNow()
                await self?.refreshPricingNow()
            }
        }
    }
}
```

Replace the original simpler `startBackgroundWork` with the version above.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStats/App/AppContainer.swift
git commit -m "app: add midnight rollover, daily pricing refresh, wake handling"
```

---

### Task 17: Settings sheet + launch-at-login

**Files:**
- Create: `Sources/ClaudeStats/Views/SettingsSheet.swift`
- Modify: `Sources/ClaudeStats/App/PopoverView.swift`

- [ ] **Step 1: Implement `SettingsSheet`**

`Sources/ClaudeStats/Views/SettingsSheet.swift`:

```swift
import SwiftUI
import ServiceManagement

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    var onRebuildIndex: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin.toggle()
                    }
                }
            Button("Rebuild index") { onRebuildIndex(); dismiss() }
                .help("Re-scans all JSONL files from scratch")
            Button("Open data folder") {
                let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("claude-stats")
                NSWorkspace.shared.open(url)
            }
            HStack {
                Spacer()
                Text("v1.0.0").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
```

- [ ] **Step 2: Add a footer + settings trigger to `PopoverView`**

At the end of `PopoverView.body`'s outer VStack (after the section/drill content), add:

```swift
Divider()
HStack {
    Text("\(viewModel.overview.projectCount) projects · \(viewModel.overview.sessionCount) sessions")
        .font(.system(size: 11)).foregroundStyle(.secondary)
    Spacer()
    Button(action: { showSettings = true }) {
        Image(systemName: "gearshape").font(.system(size: 11))
    }.buttonStyle(.plain).foregroundStyle(.secondary)
}
.padding(.horizontal, 14).padding(.vertical, 6)
.sheet(isPresented: $showSettings) {
    SettingsSheet(onRebuildIndex: { /* wired in step 3 */ })
}
```

Add the state:

```swift
@State private var showSettings = false
```

- [ ] **Step 3: Add a "rebuild index" action on `AppContainer`**

In `AppContainer.swift`:

```swift
func rebuildIndex() async {
    let appSupport = try! FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("claude-stats")
    try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("usage.db"))
    try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("usage.db-wal"))
    try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("usage.db-shm"))
    // Note: store/reader/viewModel will need to be re-created — for v1, instruct the user to relaunch.
}
```

For v1 simplicity, the rebuild button removes the DB and prompts the user to relaunch the app. Update `SettingsSheet` to surface that:

```swift
Button("Rebuild index (relaunch required)") {
    Task { await container.rebuildIndex(); dismiss(); NSApp.terminate(nil) }
}
```

Pass `container` into `SettingsSheet` from `PopoverView` (add `let container: AppContainer` to `PopoverView` and `SettingsSheet`).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Views/SettingsSheet.swift Sources/ClaudeStats/App/PopoverView.swift Sources/ClaudeStats/App/AppContainer.swift
git commit -m "views: add SettingsSheet with launch-at-login and rebuild-index"
```

---

### Task 18: Info.plist + build/install scripts

**Files:**
- Create: `Sources/ClaudeStats/Resources/Info.plist`
- Create: `scripts/build.sh`
- Create: `scripts/install.sh`

- [ ] **Step 1: Create `Info.plist`**

`Sources/ClaudeStats/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeStats</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeStats</string>
    <key>CFBundleIdentifier</key>
    <string>de.janjaap.claude-stats</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeStats</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Create `scripts/build.sh`**

```bash
#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="ClaudeStats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/claude-stats "$APP/Contents/MacOS/ClaudeStats"
cp Sources/ClaudeStats/Resources/Info.plist "$APP/Contents/Info.plist"

# Bundle resources processed by SPM.
RESBUNDLE="$(find .build/release -name 'ClaudeStats_ClaudeStats.bundle' -type d | head -1)"
if [ -n "$RESBUNDLE" ]; then
    cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
fi

echo "Built $APP"
```

Mark executable:

```bash
chmod +x scripts/build.sh
```

- [ ] **Step 3: Create `scripts/install.sh`**

```bash
#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/ClaudeStats.app"
cp -R "ClaudeStats.app" "$DEST/"
open "$DEST/ClaudeStats.app"
echo "Installed to $DEST/ClaudeStats.app"
```

```bash
chmod +x scripts/install.sh
```

- [ ] **Step 4: Run the build script**

Run: `./scripts/build.sh`
Expected: produces `ClaudeStats.app/` in repo root.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Resources/Info.plist scripts/
git commit -m "build: add Info.plist and build/install scripts for .app bundle"
```

---

### Task 19: Manual end-to-end verification + README polish

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run the install script**

Run: `./scripts/install.sh`
Expected: `ClaudeStats.app` opens; menubar item appears.

- [ ] **Step 2: Verify the menubar label**

Click the menubar — it should show:
- Green dot if any JSONL was modified in the last 30s; grey dot otherwise.
- A token count like `412k`, computed from your real `~/.claude/projects/`.

If the count is 0 the first time, give the indexer ~30 seconds to complete the cold scan.

- [ ] **Step 3: Verify the popover**

Open the popover and check:
- Status row shows correct active/idle state and `Xk today · ~$Y.YY`.
- "Overview" tab shows: stat grid (totals, cost, sessions, cache hit rate), 14-day trend (today highlighted), per-model breakdown.
- "Projects" tab shows projects sorted by tokens with bars.
- Click a project → drill-in shows that project's stats, model breakdown, and recent sessions.
- "‹ Projects" returns to the list.
- Time range tabs `Today / 7d / 30d / All` change the numbers as expected.
- ⚙ opens settings; toggle launch-at-login; click rebuild index (it will quit the app and you relaunch).

- [ ] **Step 4: Verify pricing refresh**

Quit the app. Delete `~/Library/Caches/claude-stats/pricing.json` and `pricing.json.fetched_at`. Disconnect from Wi-Fi. Relaunch:
- Cost numbers should still display using the bundled fallback table.
Reconnect Wi-Fi; in 24h (or kill the app and relaunch) the LiteLLM JSON should be fetched and cached.

- [ ] **Step 5: Verify activity detection**

Run a Claude Code command in another terminal — within 10s, the menubar dot should turn green.

- [ ] **Step 6: Verify midnight rollover (optional)**

Temporarily change `scheduleMidnightRollover` to fire in 30 seconds for a manual test:
```swift
let interval: TimeInterval = 30
```
Verify "today's tokens" recomputes. Revert the change.

- [ ] **Step 7: Polish README**

Replace `README.md` with:

```markdown
# claude-stats

A macOS menubar app showing your Claude Code usage from local JSONL session logs.
Two tabs: **Overview** (totals, trend, per-model) and **Projects** (per-project bars + drill-in).
No API keys, no daemons, no third-party services.

## Install

    git clone <repo>
    cd claude-stats
    ./scripts/install.sh

The app will appear in `~/Applications/ClaudeStats.app` and launch automatically.
On first launch, allow it through Gatekeeper (right-click → Open).

## Where the data comes from

`~/.claude/projects/**/*.jsonl` — Claude Code's local session logs.
The app stores aggregations in `~/Library/Application Support/claude-stats/usage.db`.

## Pricing

Pulled from [LiteLLM's community pricing JSON](https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/model_prices_and_context_window_backup.json),
refreshed every 24h while the app runs. A bundled fallback ships inside the app for offline first-launch.

## Development

    swift test
    swift run

## License

MIT (see LICENSE).
```

- [ ] **Step 8: Commit**

```bash
git add README.md
git commit -m "docs: polish README with install, data source, and pricing notes"
```

- [ ] **Step 9: Final verification**

Run: `swift test`
Expected: all tests green.

Run: `./scripts/install.sh`
Expected: app installed and running.

Tag a v1:

```bash
git tag v1.0.0
```

---

## Self-Review Notes

- **Spec coverage check:**
  - ✅ Menubar dot + today's tokens — Task 11.
  - ✅ Active session via mtime within 30s — Tasks 6, 9.
  - ✅ Section tabs Overview / Projects — Task 11.
  - ✅ Time range tabs — Task 12.
  - ✅ Stat cards (4) with sub-labels — Task 13.
  - ✅ 14-day trend — Task 12 (TrendChart) + Task 13 (wired).
  - ✅ Per-model breakdown — Task 13.
  - ✅ Projects bar list with cost — Task 14.
  - ✅ Project drill-in with sessions — Task 15.
  - ✅ Settings (launch-at-login, rebuild, open data) — Task 17.
  - ✅ Pricing fetch + cache + 24h + bundled fallback — Tasks 7, 8, 16.
  - ✅ Midnight rollover + wake handling — Task 16.
  - ✅ Incremental scan + truncated-line recovery — Tasks 4, 6.
  - ✅ Worktree collapse — Task 3.
  - ✅ SQLite via system `import SQLite3` — Task 5.
  - ✅ App bundle with `LSUIElement` — Task 18.
- **No placeholders:** every task has runnable code or shell commands.
- **Type consistency:** `UsageStore.ProjectRow`, `ModelRow`, `SessionRow`, `ProjectModelRow` all consistent across tasks.
