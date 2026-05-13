# Subscription Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a narrow progress bar above the popover tabs showing the user's
remaining Claude subscription quota for the 5-hour and (Max-only) 7-day
rolling windows, with optional opt-in to Anthropic's `/api/oauth/usage`
endpoint for real numbers and a self-calibrating fallback. Also replace
the existing 10-second polling timer with FSEvents-driven real-time
updates.

**Architecture:** A new `Sources/ClaudeStats/Limits/` module owns
plan-tier detection, rolling-window aggregation against the existing
`UsageStore`, an opt-in API client, and a calibrator that turns
API utilization responses into improved fallback limits over time.
`ActivityMonitor` migrates from `Timer` to `FSEventStream` for near-
instant updates. `StatsViewModel` grows a `limits` property; `PopoverView`
gets a `LimitsBar` sub-view; `SettingsView` gets a Limits section.

**Tech Stack:** Swift 5.9 / SwiftUI on macOS 14+, XCTest, SQLite via
`UsageStore`, FSEvents via CoreServices, macOS Keychain via Security
framework, `URLSession` for HTTPS.

**Spec:** `docs/superpowers/specs/2026-05-13-subscription-limits-design.md`

---

## File map

**New files (sources):**

- `Sources/ClaudeStats/Limits/Plan.swift` — `PlanTier`, `Window`, `WindowLimit` value types
- `Sources/ClaudeStats/Limits/Keychain.swift` — `KeychainReading` protocol + `ClaudeCredentials` + default `KeychainReader`
- `Sources/ClaudeStats/Limits/PlanDetector.swift` — maps Keychain credentials to `PlanTier`
- `Sources/ClaudeStats/Limits/PlanCatalog.swift` — loads bundled + calibration JSON, returns `WindowLimit`
- `Sources/ClaudeStats/Limits/UsageWindowCalculator.swift` — rolling window tokens from `UsageStore`
- `Sources/ClaudeStats/Limits/LimitsAPIClient.swift` — `GET /api/oauth/usage` + token refresh
- `Sources/ClaudeStats/Limits/PlanCalibrator.swift` — records samples, persists median-derived `calibratedLimit`
- `Sources/ClaudeStats/Limits/FSEventsWatcher.swift` — Swift wrapper over `FSEventStream`
- `Sources/ClaudeStats/Resources/plan-limits.json` — bundled fallback token caps per plan/window
- `Sources/ClaudeStats/Views/LimitsBar.swift` — the new progress strip

**New files (tests + fixtures):**

- `Tests/ClaudeStatsTests/PlanCatalogTests.swift`
- `Tests/ClaudeStatsTests/PlanDetectorTests.swift`
- `Tests/ClaudeStatsTests/UsageWindowCalculatorTests.swift`
- `Tests/ClaudeStatsTests/LimitsAPIClientTests.swift`
- `Tests/ClaudeStatsTests/PlanCalibratorTests.swift`
- `Tests/ClaudeStatsTests/ActivityMonitorFSEventsTests.swift`
- `Tests/ClaudeStatsTests/Fixtures/oauth-usage-max-5x.json` — sample API response
- `Tests/ClaudeStatsTests/Fixtures/oauth-usage-pro.json` — Pro response (5h only)
- `Tests/ClaudeStatsTests/Fixtures/oauth-token-refresh.json` — refresh response

**Modified files:**

- `Sources/ClaudeStats/Ingest/ActivityMonitor.swift` — Timer → FSEvents
- `Sources/ClaudeStats/ViewModel/StatsViewModel.swift` — add `limits` state, refresh path
- `Sources/ClaudeStats/App/AppContainer.swift` — wire up new components
- `Sources/ClaudeStats/App/PopoverView.swift` — insert `LimitsBar`
- `Sources/ClaudeStats/Views/SettingsView.swift` — Limits section
- `scripts/build.sh` — copy `plan-limits.json` into `.app` bundle
- `README.md` — short "Limits" subsection
- `Tests/ClaudeStatsTests/StatsViewModelTests.swift` — limits-state assertions (optional smoke)

---

## Task 0: Baseline verification

**Files:** none (pre-flight)

- [ ] **Step 1: Confirm clean tree and latest main**

```bash
git status
git log --oneline -3
```

Expected: working tree clean, top commit is `299d2f9 docs: spec subscription-limits view + FSEvents real-time updates`.

- [ ] **Step 2: Confirm baseline tests pass**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests pass. Note the test count for later comparison.

- [ ] **Step 3: Confirm app still builds**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds with no errors.

---

## Task 1: Plan & Window value types

**Files:**
- Create: `Sources/ClaudeStats/Limits/Plan.swift`

(No tests for this task — pure value types; covered transitively by later test tasks.)

- [ ] **Step 1: Create the Limits directory**

```bash
mkdir -p Sources/ClaudeStats/Limits
```

- [ ] **Step 2: Write `Plan.swift`**

```swift
import Foundation

enum PlanTier: String, Codable, CaseIterable, Equatable {
    case pro
    case max_5x
    case max_20x

    var displayName: String {
        switch self {
        case .pro:     return "Pro"
        case .max_5x:  return "Max 5x"
        case .max_20x: return "Max 20x"
        }
    }
}

enum Window: String, Codable, CaseIterable, Equatable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    var seconds: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 86400
        }
    }

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        }
    }
}

struct WindowLimit: Equatable, Codable {
    let tokens: Int
}
```

- [ ] **Step 3: Verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStats/Limits/Plan.swift
git commit -m "limits: add PlanTier, Window, WindowLimit value types"
```

---

## Task 2: PlanCatalog + bundled JSON + build.sh

**Files:**
- Create: `Sources/ClaudeStats/Resources/plan-limits.json`
- Create: `Sources/ClaudeStats/Limits/PlanCatalog.swift`
- Create: `Tests/ClaudeStatsTests/PlanCatalogTests.swift`
- Modify: `scripts/build.sh`

- [ ] **Step 1: Create bundled fallback JSON**

`Sources/ClaudeStats/Resources/plan-limits.json`:

```json
{
  "pro":     { "five_hour": { "tokens": 250000 },  "seven_day": null },
  "max_5x":  { "five_hour": { "tokens": 1250000 }, "seven_day": { "tokens": 15000000 } },
  "max_20x": { "five_hour": { "tokens": 5000000 }, "seven_day": { "tokens": 60000000 } }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/ClaudeStatsTests/PlanCatalogTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class PlanCatalogTests: XCTestCase {
    private func bundledFixture() -> Data {
        Data("""
        {
          "pro":     { "five_hour": { "tokens": 250000 },  "seven_day": null },
          "max_5x":  { "five_hour": { "tokens": 1250000 }, "seven_day": { "tokens": 15000000 } },
          "max_20x": { "five_hour": { "tokens": 5000000 }, "seven_day": { "tokens": 60000000 } }
        }
        """.utf8)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-\(UUID().uuidString).json")
    }

    func testReturnsBundledLimitWhenNoCalibration() throws {
        let url = tempURL()
        let catalog = try PlanCatalog(bundledData: bundledFixture(), calibrationURL: url)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 1_250_000)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .sevenDay)?.tokens, 15_000_000)
        XCTAssertNil(catalog.limit(plan: .pro, window: .sevenDay))
    }

    func testCalibrationOverlayShadowsBundled() throws {
        let url = tempURL()
        let calibration = """
        {
          "max_5x": { "five_hour": { "samples": [], "calibratedLimit": 1300000 } }
        }
        """
        try calibration.write(to: url, atomically: true, encoding: .utf8)
        let catalog = try PlanCatalog(bundledData: bundledFixture(), calibrationURL: url)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 1_300_000)
        // Non-calibrated window still falls through to bundled.
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .sevenDay)?.tokens, 15_000_000)
        try? FileManager.default.removeItem(at: url)
    }

    func testReloadCalibrationPicksUpFileChanges() throws {
        let url = tempURL()
        let catalog = try PlanCatalog(bundledData: bundledFixture(), calibrationURL: url)
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 1_250_000)

        try """
        {"max_5x": {"five_hour": {"samples": [], "calibratedLimit": 1400000}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        catalog.reloadCalibration()
        XCTAssertEqual(catalog.limit(plan: .max_5x, window: .fiveHour)?.tokens, 1_400_000)
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 3: Run tests — verify they fail**

```bash
swift test --filter PlanCatalogTests 2>&1 | tail -15
```

Expected: compile error (`PlanCatalog` not defined).

- [ ] **Step 4: Implement `PlanCatalog.swift`**

`Sources/ClaudeStats/Limits/PlanCatalog.swift`:

```swift
import Foundation

private struct BundledLimits: Decodable {
    let pro: PerPlan
    let max_5x: PerPlan
    let max_20x: PerPlan
    struct PerPlan: Decodable {
        let five_hour: WindowLimit?
        let seven_day: WindowLimit?
    }
}

private struct CalibrationFile: Decodable {
    let pro: PerPlan?
    let max_5x: PerPlan?
    let max_20x: PerPlan?
    struct PerPlan: Decodable {
        let five_hour: PerWindow?
        let seven_day: PerWindow?
    }
    struct PerWindow: Decodable {
        let calibratedLimit: Int?
    }
}

final class PlanCatalog {
    private let bundled: BundledLimits
    private let calibrationURL: URL
    private var calibration: CalibrationFile?

    init(bundledData: Data, calibrationURL: URL) throws {
        self.bundled = try JSONDecoder().decode(BundledLimits.self, from: bundledData)
        self.calibrationURL = calibrationURL
        loadCalibration()
    }

    func reloadCalibration() {
        loadCalibration()
    }

    private func loadCalibration() {
        guard let data = try? Data(contentsOf: calibrationURL) else {
            calibration = nil
            return
        }
        calibration = try? JSONDecoder().decode(CalibrationFile.self, from: data)
    }

    func limit(plan: PlanTier, window: Window) -> WindowLimit? {
        if let calibrated = calibratedValue(plan: plan, window: window) {
            return WindowLimit(tokens: calibrated)
        }
        return bundledValue(plan: plan, window: window)
    }

    private func bundledValue(plan: PlanTier, window: Window) -> WindowLimit? {
        let perPlan: BundledLimits.PerPlan
        switch plan {
        case .pro:     perPlan = bundled.pro
        case .max_5x:  perPlan = bundled.max_5x
        case .max_20x: perPlan = bundled.max_20x
        }
        switch window {
        case .fiveHour: return perPlan.five_hour
        case .sevenDay: return perPlan.seven_day
        }
    }

    private func calibratedValue(plan: PlanTier, window: Window) -> Int? {
        guard let calibration else { return nil }
        let perPlan: CalibrationFile.PerPlan?
        switch plan {
        case .pro:     perPlan = calibration.pro
        case .max_5x:  perPlan = calibration.max_5x
        case .max_20x: perPlan = calibration.max_20x
        }
        let perWindow: CalibrationFile.PerWindow?
        switch window {
        case .fiveHour: perWindow = perPlan?.five_hour
        case .sevenDay: perWindow = perPlan?.seven_day
        }
        return perWindow?.calibratedLimit
    }
}
```

- [ ] **Step 5: Run tests — verify they pass**

```bash
swift test --filter PlanCatalogTests 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 6: Update `scripts/build.sh` to bundle the JSON**

Edit `scripts/build.sh`. Find the line:

```bash
cp Sources/ClaudeStats/Resources/pricing-fallback.json "$APP/Contents/Resources/"
```

Add immediately after it:

```bash
cp Sources/ClaudeStats/Resources/plan-limits.json "$APP/Contents/Resources/"
```

- [ ] **Step 7: Verify build script still runs cleanly**

```bash
./scripts/build.sh 2>&1 | tail -5
```

Expected: "Built ClaudeStats.app at version …".

- [ ] **Step 8: Verify the JSON ended up in the bundle**

```bash
ls ClaudeStats.app/Contents/Resources/plan-limits.json
```

Expected: file exists.

- [ ] **Step 9: Commit**

```bash
git add Sources/ClaudeStats/Resources/plan-limits.json \
        Sources/ClaudeStats/Limits/PlanCatalog.swift \
        Tests/ClaudeStatsTests/PlanCatalogTests.swift \
        scripts/build.sh
git commit -m "limits: PlanCatalog with bundled fallback + calibration overlay"
```

---

## Task 3: Keychain protocol + default reader + ClaudeCredentials

**Files:**
- Create: `Sources/ClaudeStats/Limits/Keychain.swift`

(No standalone tests — the protocol is exercised through `PlanDetectorTests` and `LimitsAPIClientTests` in later tasks.)

- [ ] **Step 1: Write `Keychain.swift`**

```swift
import Foundation
import Security

struct ClaudeCredentials: Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let subscriptionType: String?
    let rateLimitTier: String?
}

protocol KeychainReading {
    /// Returns the Claude Code credentials, or nil if the keychain item is
    /// absent. Throws on access denied / parse failures.
    func readClaudeCredentials() throws -> ClaudeCredentials?

    /// Writes refreshed credentials back to the same keychain item.
    func writeClaudeCredentials(_ creds: ClaudeCredentials) throws
}

enum KeychainError: Error {
    case accessDenied(OSStatus)
    case malformed(String)
}

private struct StoredEnvelope: Codable {
    let claudeAiOauth: StoredOAuth
    struct StoredOAuth: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int64        // milliseconds since epoch
        let subscriptionType: String?
        let rateLimitTier: String?
    }
}

final class KeychainReader: KeychainReading {
    private let service: String

    init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    func readClaudeCredentials() throws -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.accessDenied(status)
        }
        let envelope: StoredEnvelope
        do {
            envelope = try JSONDecoder().decode(StoredEnvelope.self, from: data)
        } catch {
            throw KeychainError.malformed(String(describing: error))
        }
        return ClaudeCredentials(
            accessToken:      envelope.claudeAiOauth.accessToken,
            refreshToken:     envelope.claudeAiOauth.refreshToken,
            expiresAt:        Date(timeIntervalSince1970: TimeInterval(envelope.claudeAiOauth.expiresAt) / 1000),
            subscriptionType: envelope.claudeAiOauth.subscriptionType,
            rateLimitTier:    envelope.claudeAiOauth.rateLimitTier
        )
    }

    func writeClaudeCredentials(_ creds: ClaudeCredentials) throws {
        // Read current envelope, mutate the tokens, write back. Preserves any
        // fields we don't know about.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let existing = item as? Data,
              var raw = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              var oauth = raw["claudeAiOauth"] as? [String: Any] else {
            throw KeychainError.accessDenied(status)
        }
        oauth["accessToken"]  = creds.accessToken
        oauth["refreshToken"] = creds.refreshToken
        oauth["expiresAt"]    = Int64(creds.expiresAt.timeIntervalSince1970 * 1000)
        raw["claudeAiOauth"]  = oauth
        let updated = try JSONSerialization.data(withJSONObject: raw)

        let updateQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecValueData as String: updated]
        let upStatus = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)
        if upStatus != errSecSuccess {
            throw KeychainError.accessDenied(upStatus)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStats/Limits/Keychain.swift
git commit -m "limits: KeychainReading protocol + default Claude Code-credentials reader"
```

---

## Task 4: PlanDetector

**Files:**
- Create: `Sources/ClaudeStats/Limits/PlanDetector.swift`
- Create: `Tests/ClaudeStatsTests/PlanDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeStatsTests/PlanDetectorTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class PlanDetectorTests: XCTestCase {
    private final class FakeKeychain: KeychainReading {
        var creds: ClaudeCredentials?
        var error: Error?
        func readClaudeCredentials() throws -> ClaudeCredentials? {
            if let error { throw error }
            return creds
        }
        func writeClaudeCredentials(_ creds: ClaudeCredentials) throws {}
    }

    private func creds(sub: String?, tier: String?) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: .distantFuture,
            subscriptionType: sub, rateLimitTier: tier
        )
    }

    func testMapsMax5x() {
        let k = FakeKeychain()
        k.creds = creds(sub: "max", tier: "default_claude_max_5x")
        let detector = PlanDetector(keychain: k)
        let result = detector.detect()
        XCTAssertEqual(result.tier, .max_5x)
        XCTAssertEqual(result.rawSubscriptionType, "max")
        XCTAssertEqual(result.rawRateLimitTier, "default_claude_max_5x")
    }

    func testMapsMax20x() {
        let k = FakeKeychain()
        k.creds = creds(sub: "max", tier: "default_claude_max_20x")
        XCTAssertEqual(PlanDetector(keychain: k).detect().tier, .max_20x)
    }

    func testMapsPro() {
        let k = FakeKeychain()
        k.creds = creds(sub: "pro", tier: "default_claude_pro")
        XCTAssertEqual(PlanDetector(keychain: k).detect().tier, .pro)
    }

    func testUnknownTierLeavesTierNil() {
        let k = FakeKeychain()
        k.creds = creds(sub: "team", tier: "default_claude_team")
        XCTAssertNil(PlanDetector(keychain: k).detect().tier)
    }

    func testMissingKeychainItemReturnsNilTier() {
        let k = FakeKeychain()
        k.creds = nil
        let result = PlanDetector(keychain: k).detect()
        XCTAssertNil(result.tier)
        XCTAssertEqual(result.rawSubscriptionType, "")
    }

    func testKeychainErrorReturnsNilTier() {
        let k = FakeKeychain()
        k.error = KeychainError.accessDenied(-25300)
        XCTAssertNil(PlanDetector(keychain: k).detect().tier)
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter PlanDetectorTests 2>&1 | tail -15
```

Expected: compile error (`PlanDetector` not defined).

- [ ] **Step 3: Implement `PlanDetector.swift`**

```swift
import Foundation

struct DetectedPlan: Equatable {
    let tier: PlanTier?
    let rawSubscriptionType: String
    let rawRateLimitTier: String
}

final class PlanDetector {
    private let keychain: KeychainReading

    init(keychain: KeychainReading) {
        self.keychain = keychain
    }

    func detect() -> DetectedPlan {
        let creds = (try? keychain.readClaudeCredentials()) ?? nil
        let sub = creds?.subscriptionType ?? ""
        let tier = creds?.rateLimitTier ?? ""
        return DetectedPlan(
            tier:                 PlanDetector.mapPlan(subscriptionType: sub, rateLimitTier: tier),
            rawSubscriptionType:  sub,
            rawRateLimitTier:     tier
        )
    }

    static func mapPlan(subscriptionType: String, rateLimitTier: String) -> PlanTier? {
        if rateLimitTier.contains("max_20x") { return .max_20x }
        if rateLimitTier.contains("max_5x")  { return .max_5x }
        if subscriptionType == "pro"         { return .pro }
        return nil
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter PlanDetectorTests 2>&1 | tail -10
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Limits/PlanDetector.swift \
        Tests/ClaudeStatsTests/PlanDetectorTests.swift
git commit -m "limits: PlanDetector maps Keychain credentials to PlanTier"
```

---

## Task 5: UsageWindowCalculator

**Files:**
- Create: `Sources/ClaudeStats/Limits/UsageWindowCalculator.swift`
- Create: `Tests/ClaudeStatsTests/UsageWindowCalculatorTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeStatsTests/UsageWindowCalculatorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter UsageWindowCalculatorTests 2>&1 | tail -15
```

Expected: compile error (`UsageWindowCalculator` not defined).

- [ ] **Step 3: Implement `UsageWindowCalculator.swift`**

```swift
import Foundation

struct UsageWindowCalculator {
    let store: UsageStore

    func tokens(in window: Window, endingAt now: Date) -> Int {
        let start = now.addingTimeInterval(-window.seconds)
        return (try? store.totalTokens(start: start, end: now)) ?? 0
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter UsageWindowCalculatorTests 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Limits/UsageWindowCalculator.swift \
        Tests/ClaudeStatsTests/UsageWindowCalculatorTests.swift
git commit -m "limits: UsageWindowCalculator for rolling 5h/7d token sums"
```

---

## Task 6: LimitsAPIClient (with fixtures + URLProtocol mock)

**Files:**
- Create: `Sources/ClaudeStats/Limits/LimitsAPIClient.swift`
- Create: `Tests/ClaudeStatsTests/LimitsAPIClientTests.swift`
- Create: `Tests/ClaudeStatsTests/Fixtures/oauth-usage-max-5x.json`
- Create: `Tests/ClaudeStatsTests/Fixtures/oauth-usage-pro.json`
- Create: `Tests/ClaudeStatsTests/Fixtures/oauth-token-refresh.json`

- [ ] **Step 1: Add fixtures**

`Tests/ClaudeStatsTests/Fixtures/oauth-usage-max-5x.json`:

```json
{
  "rate_limits": {
    "five_hour":  { "utilization": 42.0, "resets_at": 1715620000 },
    "seven_day":  { "utilization": 18.0, "resets_at": 1715900000 }
  }
}
```

`Tests/ClaudeStatsTests/Fixtures/oauth-usage-pro.json`:

```json
{
  "rate_limits": {
    "five_hour": { "utilization": 12.5, "resets_at": 1715620000 }
  }
}
```

`Tests/ClaudeStatsTests/Fixtures/oauth-token-refresh.json`:

```json
{
  "access_token":  "sk-ant-oat01-new",
  "refresh_token": "sk-ant-ort01-new",
  "expires_in":    28800
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/ClaudeStatsTests/LimitsAPIClientTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class LimitsAPIClientTests: XCTestCase {

    // MARK: - Mock URLProtocol

    final class StubProtocol: URLProtocol {
        struct Stub {
            let statusCode: Int
            let body: Data
            let validate: ((URLRequest) -> Void)?
        }

        nonisolated(unsafe) static var stubs: [(host: String, path: String, stub: Stub)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let req = self.request
            let host = req.url?.host ?? ""
            let path = req.url?.path ?? ""
            guard let entry = Self.stubs.first(where: { $0.host == host && $0.path == path }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            entry.stub.validate?(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: entry.stub.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: entry.stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private final class FakeKeychain: KeychainReading {
        var creds: ClaudeCredentials?
        var lastWritten: ClaudeCredentials?
        func readClaudeCredentials() throws -> ClaudeCredentials? { creds }
        func writeClaudeCredentials(_ creds: ClaudeCredentials) throws { lastWritten = creds }
    }

    override func tearDown() {
        StubProtocol.stubs = []
        super.tearDown()
    }

    func testFetchHappyPathMax5x() async throws {
        let keychain = FakeKeychain()
        keychain.creds = ClaudeCredentials(
            accessToken: "tok", refreshToken: "ref",
            expiresAt: .distantFuture,
            subscriptionType: "max", rateLimitTier: "default_claude_max_5x"
        )
        StubProtocol.stubs = [(
            host: "api.anthropic.com", path: "/api/oauth/usage",
            stub: .init(
                statusCode: 200,
                body: try fixture("oauth-usage-max-5x"),
                validate: { req in
                    XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
                }
            )
        )]
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        let result = try await client.fetchUsage()
        XCTAssertEqual(result.five_hour?.utilization, 42.0)
        XCTAssertEqual(result.seven_day?.utilization, 18.0)
    }

    func testFetchHappyPathProOnlyFiveHour() async throws {
        let keychain = FakeKeychain()
        keychain.creds = ClaudeCredentials(
            accessToken: "tok", refreshToken: "ref",
            expiresAt: .distantFuture,
            subscriptionType: "pro", rateLimitTier: "default_claude_pro"
        )
        StubProtocol.stubs = [(
            host: "api.anthropic.com", path: "/api/oauth/usage",
            stub: .init(statusCode: 200, body: try fixture("oauth-usage-pro"), validate: nil)
        )]
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        let result = try await client.fetchUsage()
        XCTAssertEqual(result.five_hour?.utilization, 12.5)
        XCTAssertNil(result.seven_day)
    }

    func testExpiredTokenTriggersRefresh() async throws {
        let keychain = FakeKeychain()
        keychain.creds = ClaudeCredentials(
            accessToken: "old", refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 1),  // long expired
            subscriptionType: "max", rateLimitTier: "default_claude_max_5x"
        )
        StubProtocol.stubs = [
            (host: "api.anthropic.com", path: "/oauth/token",
             stub: .init(statusCode: 200, body: try fixture("oauth-token-refresh"),
                         validate: { req in
                            XCTAssertEqual(req.httpMethod, "POST")
                         })),
            (host: "api.anthropic.com", path: "/api/oauth/usage",
             stub: .init(statusCode: 200, body: try fixture("oauth-usage-max-5x"),
                         validate: { req in
                            // Should use the refreshed token.
                            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-new")
                         })),
        ]
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        _ = try await client.fetchUsage()
        XCTAssertEqual(keychain.lastWritten?.accessToken, "sk-ant-oat01-new")
        XCTAssertEqual(keychain.lastWritten?.refreshToken, "sk-ant-ort01-new")
    }

    func testHTTP500Throws() async {
        let keychain = FakeKeychain()
        keychain.creds = ClaudeCredentials(
            accessToken: "tok", refreshToken: "ref",
            expiresAt: .distantFuture, subscriptionType: nil, rateLimitTier: nil
        )
        StubProtocol.stubs = [(
            host: "api.anthropic.com", path: "/api/oauth/usage",
            stub: .init(statusCode: 500, body: Data(), validate: nil)
        )]
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        do {
            _ = try await client.fetchUsage()
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    func testNoCredentialsThrows() async {
        let keychain = FakeKeychain()
        keychain.creds = nil
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        do {
            _ = try await client.fetchUsage()
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }
}
```

- [ ] **Step 3: Wire fixtures into the test target**

The existing test target already declares `resources: [.copy("Fixtures")]` in `Package.swift`, so the three new fixture files inside `Tests/ClaudeStatsTests/Fixtures/` will be picked up automatically. No `Package.swift` change required — confirm by inspection:

```bash
grep -A2 "testTarget" Package.swift
```

Expected: `resources: [.copy("Fixtures")]` already present.

- [ ] **Step 4: Run tests — verify they fail**

```bash
swift test --filter LimitsAPIClientTests 2>&1 | tail -15
```

Expected: compile error (`LimitsAPIClient` not defined).

- [ ] **Step 5: Implement `LimitsAPIClient.swift`**

```swift
import Foundation

struct APIRateLimits: Decodable, Equatable {
    struct Window: Decodable, Equatable {
        let utilization: Double
        let resets_at: Int  // unix seconds
    }
    struct Body: Decodable {
        let rate_limits: RateLimits
        struct RateLimits: Decodable {
            let five_hour: Window?
            let seven_day: Window?
        }
    }
    let five_hour: Window?
    let seven_day: Window?

    init(body: Body) {
        self.five_hour = body.rate_limits.five_hour
        self.seven_day = body.rate_limits.seven_day
    }
}

enum LimitsAPIError: Error {
    case noCredentials
    case httpStatus(Int)
    case decodeFailure
    case refreshFailed
}

actor LimitsAPIClient {
    private let keychain: KeychainReading
    private let session: URLSession
    private let now: () -> Date

    private let usageURL  = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let tokenURL  = URL(string: "https://api.anthropic.com/oauth/token")!

    init(keychain: KeychainReading,
         session: URLSession = .shared,
         now: @escaping () -> Date = Date.init) {
        self.keychain = keychain
        self.session = session
        self.now = now
    }

    func fetchUsage() async throws -> APIRateLimits {
        var creds = try keychain.readClaudeCredentials()
        guard var c = creds else { throw LimitsAPIError.noCredentials }
        if c.expiresAt <= now() {
            c = try await refresh(using: c)
            creds = c
        }
        do {
            return try await fetchOnce(with: c.accessToken)
        } catch LimitsAPIError.httpStatus(401) {
            // One retry after a forced refresh.
            let refreshed = try await refresh(using: c)
            return try await fetchOnce(with: refreshed.accessToken)
        }
    }

    private func fetchOnce(with token: String) async throws -> APIRateLimits {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LimitsAPIError.httpStatus(status) }
        do {
            let body = try JSONDecoder().decode(APIRateLimits.Body.self, from: data)
            return APIRateLimits(body: body)
        } catch {
            throw LimitsAPIError.decodeFailure
        }
    }

    private func refresh(using creds: ClaudeCredentials) async throws -> ClaudeCredentials {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(creds.refreshToken)"
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 10

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LimitsAPIError.refreshFailed }
        struct TokenResp: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int   // seconds
        }
        guard let tr = try? JSONDecoder().decode(TokenResp.self, from: data) else {
            throw LimitsAPIError.refreshFailed
        }
        let updated = ClaudeCredentials(
            accessToken:      tr.access_token,
            refreshToken:     tr.refresh_token,
            expiresAt:        now().addingTimeInterval(TimeInterval(tr.expires_in)),
            subscriptionType: creds.subscriptionType,
            rateLimitTier:    creds.rateLimitTier
        )
        try keychain.writeClaudeCredentials(updated)
        return updated
    }
}
```

- [ ] **Step 6: Run tests — verify they pass**

```bash
swift test --filter LimitsAPIClientTests 2>&1 | tail -10
```

Expected: 5 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeStats/Limits/LimitsAPIClient.swift \
        Tests/ClaudeStatsTests/LimitsAPIClientTests.swift \
        Tests/ClaudeStatsTests/Fixtures/oauth-usage-max-5x.json \
        Tests/ClaudeStatsTests/Fixtures/oauth-usage-pro.json \
        Tests/ClaudeStatsTests/Fixtures/oauth-token-refresh.json
git commit -m "limits: LimitsAPIClient for /api/oauth/usage + refresh-token flow"
```

---

## Task 7: PlanCalibrator

**Files:**
- Create: `Sources/ClaudeStats/Limits/PlanCalibrator.swift`
- Create: `Tests/ClaudeStatsTests/PlanCalibratorTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeStatsTests/PlanCalibratorTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

final class PlanCalibratorTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-\(UUID().uuidString).json")
    }

    func testFirstAcceptedSampleSetsCalibratedLimit() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 500_000, utilization: 50.0,
                   now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(cal.calibrated(plan: .max_5x, window: .fiveHour), 1_000_000)
        XCTAssertEqual(cal.sampleCount(plan: .max_5x, window: .fiveHour), 1)
    }

    func testLowUtilizationSampleRejected() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 1000, utilization: 1.0,
                   now: Date(timeIntervalSince1970: 1))
        XCTAssertNil(cal.calibrated(plan: .max_5x, window: .fiveHour))
        XCTAssertEqual(cal.sampleCount(plan: .max_5x, window: .fiveHour), 0)
    }

    func testZeroLocalTokensRejected() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 0, utilization: 50.0,
                   now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(cal.sampleCount(plan: .max_5x, window: .fiveHour), 0)
    }

    func testOutlier3xGuardRejects() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        for i in 0..<5 {
            cal.record(plan: .max_5x, window: .fiveHour,
                       localTokens: 500_000, utilization: 50.0,
                       now: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        XCTAssertEqual(cal.calibrated(plan: .max_5x, window: .fiveHour), 1_000_000)

        // Now an outlier: tokens are 100x larger but utilization low (implies 5M limit).
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 1_000_000, utilization: 20.0,
                   now: Date(timeIntervalSince1970: 100))
        // 1_000_000 / 0.20 = 5_000_000, which is 5x the established 1M — outside the 3x gate.
        XCTAssertEqual(cal.calibrated(plan: .max_5x, window: .fiveHour), 1_000_000)
    }

    func testMedianUsedAcrossSamples() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        // First sample establishes baseline at 1.0M.
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 500_000, utilization: 50.0,
                   now: Date(timeIntervalSince1970: 1))
        // Additional samples within the 3x guard ([333K, 3M]) refine the median.
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 540_000, utilization: 50.0,  // inferred 1.08M
                   now: Date(timeIntervalSince1970: 2))
        cal.record(plan: .max_5x, window: .fiveHour,
                   localTokens: 1_200_000, utilization: 50.0, // inferred 2.4M (within 3x of 1.08M after update)
                   now: Date(timeIntervalSince1970: 3))
        let cal2 = cal.calibrated(plan: .max_5x, window: .fiveHour) ?? 0
        // Median of {1_000_000, 1_080_000, 2_400_000} = 1_080_000.
        XCTAssertEqual(cal2, 1_080_000)
    }

    func testWritePersistsAcrossInstances() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let cal = PlanCalibrator(fileURL: url)
            cal.record(plan: .max_5x, window: .fiveHour,
                       localTokens: 500_000, utilization: 50.0,
                       now: Date(timeIntervalSince1970: 1))
        }
        let cal2 = PlanCalibrator(fileURL: url)
        XCTAssertEqual(cal2.calibrated(plan: .max_5x, window: .fiveHour), 1_000_000)
    }

    func testTrimToFiftySamples() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cal = PlanCalibrator(fileURL: url)
        for i in 0..<60 {
            cal.record(plan: .max_5x, window: .fiveHour,
                       localTokens: 500_000, utilization: 50.0,
                       now: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        XCTAssertEqual(cal.sampleCount(plan: .max_5x, window: .fiveHour), 50)
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter PlanCalibratorTests 2>&1 | tail -15
```

Expected: compile error (`PlanCalibrator` not defined).

- [ ] **Step 3: Implement `PlanCalibrator.swift`**

```swift
import Foundation

private struct StoredSample: Codable, Equatable {
    let ts: Int
    let localTokens: Int
    let utilization: Double
    let inferredLimit: Int
}

private struct StoredWindow: Codable {
    var samples: [StoredSample]
    var calibratedLimit: Int?
}

private struct StoredPlan: Codable {
    var five_hour: StoredWindow?
    var seven_day: StoredWindow?
}

private struct StoredFile: Codable {
    var pro: StoredPlan?
    var max_5x: StoredPlan?
    var max_20x: StoredPlan?
}

final class PlanCalibrator {
    static let minUtilization = 5.0
    static let maxSamples = 50
    static let outlierFactor = 3.0

    private let fileURL: URL
    private var data: StoredFile
    private let queue = DispatchQueue(label: "claude-stats.calibrator")

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(StoredFile.self, from: raw) {
            self.data = decoded
        } else {
            self.data = StoredFile(pro: nil, max_5x: nil, max_20x: nil)
        }
    }

    func calibrated(plan: PlanTier, window: Window) -> Int? {
        queue.sync { window(plan: plan, window: window)?.calibratedLimit }
    }

    func sampleCount(plan: PlanTier, window: Window) -> Int {
        queue.sync { window(plan: plan, window: window)?.samples.count ?? 0 }
    }

    func record(plan: PlanTier, window: Window,
                localTokens: Int, utilization: Double, now: Date) {
        queue.sync {
            guard utilization >= Self.minUtilization, localTokens > 0 else { return }
            let inferred = Int(Double(localTokens) / (utilization / 100.0))
            // Outlier guard against existing calibrated value.
            if let current = self.window(plan: plan, window: window)?.calibratedLimit, current > 0 {
                let lower = Double(current) / Self.outlierFactor
                let upper = Double(current) * Self.outlierFactor
                if Double(inferred) < lower || Double(inferred) > upper { return }
            }
            let sample = StoredSample(
                ts: Int(now.timeIntervalSince1970),
                localTokens: localTokens,
                utilization: utilization,
                inferredLimit: inferred
            )
            appendSample(sample, plan: plan, window: window)
            persistSnapshot()
        }
    }

    private func window(plan: PlanTier, window: Window) -> StoredWindow? {
        let stored: StoredPlan?
        switch plan {
        case .pro:     stored = data.pro
        case .max_5x:  stored = data.max_5x
        case .max_20x: stored = data.max_20x
        }
        switch window {
        case .fiveHour: return stored?.five_hour
        case .sevenDay: return stored?.seven_day
        }
    }

    private func appendSample(_ sample: StoredSample, plan: PlanTier, window: Window) {
        var perPlan = self.storedPlan(plan)
        var perWindow = (window == .fiveHour ? perPlan.five_hour : perPlan.seven_day)
                        ?? StoredWindow(samples: [], calibratedLimit: nil)
        perWindow.samples.append(sample)
        if perWindow.samples.count > Self.maxSamples {
            perWindow.samples.removeFirst(perWindow.samples.count - Self.maxSamples)
        }
        perWindow.calibratedLimit = Self.median(of: perWindow.samples.map { $0.inferredLimit })
        switch window {
        case .fiveHour: perPlan.five_hour = perWindow
        case .sevenDay: perPlan.seven_day = perWindow
        }
        writePlan(perPlan, for: plan)
    }

    private func storedPlan(_ plan: PlanTier) -> StoredPlan {
        switch plan {
        case .pro:     return data.pro     ?? StoredPlan()
        case .max_5x:  return data.max_5x  ?? StoredPlan()
        case .max_20x: return data.max_20x ?? StoredPlan()
        }
    }

    private func writePlan(_ stored: StoredPlan, for plan: PlanTier) {
        switch plan {
        case .pro:     data.pro = stored
        case .max_5x:  data.max_5x = stored
        case .max_20x: data.max_20x = stored
        }
    }

    private static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    private func persistSnapshot() {
        // Atomic write: tmp file in same directory + rename.
        guard let raw = try? JSONEncoder().encode(data) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try raw.write(to: tmp, options: .atomic)
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter PlanCalibratorTests 2>&1 | tail -10
```

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStats/Limits/PlanCalibrator.swift \
        Tests/ClaudeStatsTests/PlanCalibratorTests.swift
git commit -m "limits: PlanCalibrator records samples and persists median-based limits"
```

---

## Task 8: FSEventsWatcher + ActivityMonitor refactor

**Files:**
- Create: `Sources/ClaudeStats/Limits/FSEventsWatcher.swift`
- Modify: `Sources/ClaudeStats/Ingest/ActivityMonitor.swift`
- Create: `Tests/ClaudeStatsTests/ActivityMonitorFSEventsTests.swift`

*Note: `FSEventsWatcher` is shared infrastructure, but lives under `Limits/` only because that's where this plan adds it — it could move later if other subsystems want it. For now it's only used by `ActivityMonitor`.*

- [ ] **Step 1: Implement `FSEventsWatcher.swift`**

```swift
import Foundation
import CoreServices

/// Minimal wrapper over FSEventStream that fires a callback (debounced)
/// when anything under the watched directory changes.
final class FSEventsWatcher {
    private let path: String
    private let latency: TimeInterval
    private let debounce: TimeInterval
    private let callback: () -> Void

    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?

    init(path: String,
         latency: TimeInterval = 0.2,
         debounce: TimeInterval = 0.2,
         callback: @escaping () -> Void) {
        self.path = path
        self.latency = latency
        self.debounce = debounce
        self.callback = callback
    }

    /// Returns true if the FSEvents stream started successfully.
    @discardableResult
    func start() -> Bool {
        stop()
        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info,
            retain: nil, release: nil, copyDescription: nil
        )
        let paths = [path] as CFArray
        let flags: UInt32 = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleFire()
            },
            &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags
        ) else {
            return false
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        if !FSEventStreamStart(s) {
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    func stop() {
        pendingWork?.cancel()
        pendingWork = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func scheduleFire() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.callback()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit { stop() }
}
```

- [ ] **Step 2: Refactor `ActivityMonitor.swift`**

Replace the entire current contents of `Sources/ClaudeStats/Ingest/ActivityMonitor.swift` with:

```swift
import Foundation

@MainActor
final class ActivityMonitor {
    private let reader: UsageReader
    private let watchPath: String
    private let safetyInterval: TimeInterval
    private let activeThreshold: TimeInterval

    private var watcher: FSEventsWatcher?
    private var fallbackTimer: Timer?

    var onTick: (() -> Void)?

    init(reader: UsageReader,
         watchPath: String,
         safetyInterval: TimeInterval = 60,
         activeThreshold: TimeInterval = 30) {
        self.reader = reader
        self.watchPath = watchPath
        self.safetyInterval = safetyInterval
        self.activeThreshold = activeThreshold
    }

    func start() {
        stop()
        let watcher = FSEventsWatcher(path: watchPath) { [weak self] in
            self?.tickNow()
        }
        if watcher.start() {
            self.watcher = watcher
        } else {
            // FSEvents creation failed — fall back to a 10s polling Timer,
            // matching the previous behavior.
            schedulePollingTimer(interval: 10)
        }
        scheduleSafetyTimer()
        tickNow()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    func tickNow() {
        Task.detached { [reader] in
            try? reader.scan()
            await MainActor.run { [weak self] in
                self?.onTick?()
            }
        }
    }

    var isActive: Bool { reader.isActive(within: activeThreshold) }

    private func scheduleSafetyTimer() {
        let t = Timer(timeInterval: safetyInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t
    }

    private func schedulePollingTimer(interval: TimeInterval) {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t
    }
}
```

The public surface (`start`, `stop`, `tickNow`, `isActive`, `onTick`) is unchanged. The init signature gained a required `watchPath`.

- [ ] **Step 3: Update the call site in `AppContainer`**

Edit `Sources/ClaudeStats/App/AppContainer.swift`. Find this line:

```swift
let monitor = ActivityMonitor(reader: reader)
```

Replace with:

```swift
let monitor = ActivityMonitor(reader: reader, watchPath: claudeRoot.path)
```

- [ ] **Step 4: Verify the project still compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 5: Verify all existing tests still pass**

```bash
swift test 2>&1 | tail -10
```

Expected: all pre-existing tests still pass (since `ActivityMonitor` had no tests before, and the public surface is unchanged for other callers).

- [ ] **Step 6: Add an integration smoke test for FSEvents**

`Tests/ClaudeStatsTests/ActivityMonitorFSEventsTests.swift`:

```swift
import XCTest
@testable import ClaudeStats

/// Integration: verify that writing a file under the watched directory
/// causes ActivityMonitor.onTick to fire within a few seconds. This is a
/// slow test (uses real FSEvents) and is therefore explicitly tagged.
final class ActivityMonitorFSEventsTests: XCTestCase {

    @MainActor
    func testWritingJsonlFireOnTickQuickly() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let dbPath = tmpRoot.appendingPathComponent("usage.db").path
        let store = try UsageStore(path: dbPath)
        let reader = UsageReader(rootDir: tmpRoot, store: store)

        let monitor = ActivityMonitor(reader: reader, watchPath: tmpRoot.path,
                                       safetyInterval: 600)
        let expectation = expectation(description: "onTick fires")
        var ticks = 0
        monitor.onTick = {
            ticks += 1
            if ticks >= 2 {
                expectation.fulfill()
            }
        }
        monitor.start()
        defer { monitor.stop() }

        // Give FSEvents a moment to start before writing.
        try await Task.sleep(nanoseconds: 300_000_000)
        let sample = """
        {"timestamp":"2026-05-13T10:00:00.000Z","sessionId":"s","cwd":"/p","message":{"model":"m","usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        try sample.write(to: tmpRoot.appendingPathComponent("test.jsonl"),
                         atomically: true, encoding: .utf8)

        await fulfillment(of: [expectation], timeout: 5.0)
    }
}
```

- [ ] **Step 7: Run the FSEvents test**

```bash
swift test --filter ActivityMonitorFSEventsTests 2>&1 | tail -10
```

Expected: 1 test passes (within ~1-2 seconds locally).

If this test is flaky on CI, gate it behind an env var by wrapping the body in `try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_FSEVENTS_TESTS"] == "1")`. For now, keep it on.

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeStats/Limits/FSEventsWatcher.swift \
        Sources/ClaudeStats/Ingest/ActivityMonitor.swift \
        Sources/ClaudeStats/App/AppContainer.swift \
        Tests/ClaudeStatsTests/ActivityMonitorFSEventsTests.swift
git commit -m "ingest: switch ActivityMonitor from 10s polling to FSEvents"
```

---

## Task 9: StatsViewModel — limits state

**Files:**
- Modify: `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`

(Tests for the limits state are exercised end-to-end in Task 13's smoke flow; the underlying components already have unit coverage.)

- [ ] **Step 1: Add new types and dependencies to `StatsViewModel.swift`**

Edit `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`. Add at the top of the file (after `import Observation`):

```swift
import Foundation
import Observation

struct LimitsWindowProgress: Equatable {
    enum Source: String, Equatable { case local, api }
    let window: Window
    let used: Int
    let limit: Int
    let percent: Double
    let resetsAt: Date?
    let source: Source
}

struct LimitsState: Equatable {
    var plan: PlanTier?
    var windows: [LimitsWindowProgress]
    var lastAPIRefresh: Date?
    var apiError: String?
    var calibrationSamples: [Window: Int]
}
```

- [ ] **Step 2: Extend the `StatsViewModel` initializer**

Replace the existing `private let store: UsageStore` / `private(set) var pricing: PricingTable` / `init` block with:

```swift
    private let store: UsageStore
    private(set) var pricing: PricingTable

    // Limits subsystem.
    private let calculator: UsageWindowCalculator
    private let catalog: PlanCatalog
    private let detector: PlanDetector
    private let calibrator: PlanCalibrator
    private let apiClient: LimitsAPIClient

    var timeRange: TimeRange = .today
    var todayTokens: Int = 0
    var isActive: Bool = false
    var overview: Overview = .init()
    var projectRows: [UsageStore.ProjectRow] = []
    var projectCosts: [String: Double] = [:]
    var limits: LimitsState = .init(plan: nil, windows: [], lastAPIRefresh: nil,
                                     apiError: nil, calibrationSamples: [:])

    private var lastAPIFetch: Date?
    private var inFlightAPIFetch: Bool = false

    init(store: UsageStore,
         pricing: PricingTable,
         calculator: UsageWindowCalculator,
         catalog: PlanCatalog,
         detector: PlanDetector,
         calibrator: PlanCalibrator,
         apiClient: LimitsAPIClient) {
        self.store = store
        self.pricing = pricing
        self.calculator = calculator
        self.catalog = catalog
        self.detector = detector
        self.calibrator = calibrator
        self.apiClient = apiClient
    }
```

- [ ] **Step 3: Add the limits-recompute helper**

Inside `StatsViewModel`, after `projectDetail(for:)` and before `computeCost(...)`, add:

```swift
    /// User-facing settings read from UserDefaults each call so toggle changes
    /// in SettingsView take effect on the next refresh.
    private var useAPI: Bool {
        UserDefaults.standard.bool(forKey: "useUsageAPI")
    }

    private var planOverride: PlanTier? {
        guard let raw = UserDefaults.standard.string(forKey: "planOverride"),
              raw != "auto" else { return nil }
        return PlanTier(rawValue: raw)
    }

    private func effectivePlan() -> PlanTier? {
        if let override = planOverride { return override }
        return detector.detect().tier
    }

    /// Always runs (purely local computation). Cheap.
    private func recomputeLocalLimits(now: Date) {
        let plan = effectivePlan()
        guard let plan else {
            limits = LimitsState(plan: nil, windows: [],
                                  lastAPIRefresh: limits.lastAPIRefresh,
                                  apiError: limits.apiError,
                                  calibrationSamples: limits.calibrationSamples)
            return
        }
        var windows: [LimitsWindowProgress] = []
        for w in Window.allCases {
            guard let lim = catalog.limit(plan: plan, window: w) else { continue }
            let used = calculator.tokens(in: w, endingAt: now)
            let pct = lim.tokens == 0 ? 0 : Double(used) / Double(lim.tokens)
            windows.append(.init(
                window: w, used: used, limit: lim.tokens,
                percent: min(pct, 1.0), resetsAt: nil, source: .local
            ))
        }
        var samples: [Window: Int] = [:]
        for w in Window.allCases {
            samples[w] = calibrator.sampleCount(plan: plan, window: w)
        }
        limits = LimitsState(plan: plan, windows: windows,
                              lastAPIRefresh: limits.lastAPIRefresh,
                              apiError: limits.apiError,
                              calibrationSamples: samples)
    }

    /// Non-blocking. Kicks off an API fetch if opt-in is enabled, ≥60s
    /// since last fetch, and not already in flight.
    private func maybeFetchAPILimits(now: Date) {
        guard useAPI, !inFlightAPIFetch else { return }
        if let last = lastAPIFetch, now.timeIntervalSince(last) < 60 { return }
        inFlightAPIFetch = true
        let client = apiClient
        Task { @MainActor [weak self] in
            defer { self?.inFlightAPIFetch = false }
            do {
                let response = try await client.fetchUsage()
                self?.applyAPIResponse(response, now: now)
            } catch {
                self?.limits.apiError = String(describing: error)
            }
        }
    }

    private func applyAPIResponse(_ response: APIRateLimits, now: Date) {
        guard let plan = effectivePlan() else { return }
        var merged = limits.windows
        let apiWindows: [(Window, APIRateLimits.Window)] = [
            (.fiveHour, response.five_hour),
            (.sevenDay, response.seven_day)
        ].compactMap { (w, payload) in
            payload.map { (w, $0) }
        }
        for (window, payload) in apiWindows {
            let localTokens = calculator.tokens(in: window, endingAt: now)
            // Calibrate before reading the limit.
            calibrator.record(plan: plan, window: window,
                               localTokens: localTokens,
                               utilization: payload.utilization, now: now)
            catalog.reloadCalibration()
            // Use the (possibly newly calibrated) limit, treat API utilization as authoritative.
            let limit = catalog.limit(plan: plan, window: window)?.tokens ?? 0
            let used = limit > 0 ? Int(Double(limit) * payload.utilization / 100.0) : localTokens
            let pct = min(max(payload.utilization / 100.0, 0), 1)
            let resetsAt = Date(timeIntervalSince1970: TimeInterval(payload.resets_at))
            let progress = LimitsWindowProgress(
                window: window, used: used, limit: limit,
                percent: pct, resetsAt: resetsAt, source: .api
            )
            if let idx = merged.firstIndex(where: { $0.window == window }) {
                merged[idx] = progress
            } else {
                merged.append(progress)
            }
        }
        var samples: [Window: Int] = [:]
        for w in Window.allCases {
            samples[w] = calibrator.sampleCount(plan: plan, window: w)
        }
        limits = LimitsState(plan: plan, windows: merged,
                              lastAPIRefresh: now, apiError: nil,
                              calibrationSamples: samples)
        lastAPIFetch = now
    }
```

- [ ] **Step 4: Hook the helpers into `refresh()`**

Inside the existing `refresh()` method, **after** the existing
`overview = nextOverview` assignment (still inside the `do { ... }`
block), append:

```swift
            recomputeLocalLimits(now: now)
            maybeFetchAPILimits(now: now)
```

`now` is already defined at the top of `refresh()`.

- [ ] **Step 5: Verify it compiles**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds. Will need an updated `AppContainer` to actually run, which we'll wire up in Task 12.

- [ ] **Step 6: Run all existing tests**

```bash
swift test 2>&1 | tail -10
```

Expected: existing `StatsViewModelTests.swift` will fail to compile because the initializer changed. Move to Step 7.

- [ ] **Step 7: Update `StatsViewModelTests.swift` for the new initializer**

Open `Tests/ClaudeStatsTests/StatsViewModelTests.swift`. Find each place that constructs `StatsViewModel(store:, pricing:)` and replace with the full init. Add this helper near the top of the test class:

```swift
    @MainActor
    private func makeViewModel(store: UsageStore, pricing: PricingTable) -> StatsViewModel {
        let bundled = Data("""
        {
          "pro":     {"five_hour": {"tokens": 250000}, "seven_day": null},
          "max_5x":  {"five_hour": {"tokens": 1250000}, "seven_day": {"tokens": 15000000}},
          "max_20x": {"five_hour": {"tokens": 5000000}, "seven_day": {"tokens": 60000000}}
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
```

Then replace every `StatsViewModel(store: store, pricing: pricing)` in that file with `makeViewModel(store: store, pricing: pricing)`.

- [ ] **Step 8: Verify all tests still pass**

```bash
swift test 2>&1 | tail -10
```

Expected: existing test count, all passing.

- [ ] **Step 9: Commit**

```bash
git add Sources/ClaudeStats/ViewModel/StatsViewModel.swift \
        Tests/ClaudeStatsTests/StatsViewModelTests.swift
git commit -m "viewmodel: add limits state with local + opt-in API path"
```

---

## Task 10: LimitsBar view

**Files:**
- Create: `Sources/ClaudeStats/Views/LimitsBar.swift`

(SwiftUI view — no automated tests, exercised manually in Task 13.)

- [ ] **Step 1: Write `LimitsBar.swift`**

```swift
import SwiftUI

struct LimitsBar: View {
    let state: LimitsState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if state.windows.isEmpty {
                placeholderRow
            } else {
                progressRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            ForEach(state.windows, id: \.window) { w in
                segment(for: w)
            }
            if state.apiError != nil {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(state.apiError ?? "")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func segment(for w: LimitsWindowProgress) -> some View {
        HStack(spacing: 6) {
            Text(w.window.shortLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: w.percent))
                        .frame(width: max(2, geo.size.width * w.percent))
                }
            }
            .frame(height: 6)
            Text(percentLabel(w.percent))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .help(tooltip(for: w))
    }

    private var placeholderRow: some View {
        Button(action: { openWindow(id: "settings") }) {
            HStack(spacing: 4) {
                Text("Set your plan in Settings →")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func color(for pct: Double) -> Color {
        switch pct {
        case 0..<0.6: return .accentColor
        case 0.6..<0.85: return .orange
        default: return .red
        }
    }

    private func percentLabel(_ pct: Double) -> String {
        "\(Int((pct * 100).rounded()))%"
    }

    private func tooltip(for w: LimitsWindowProgress) -> String {
        let usedStr = format(tokens: w.used)
        let limitStr = format(tokens: w.limit)
        var parts: [String] = ["\(usedStr) / \(limitStr) tokens"]
        if let r = w.resetsAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append("resets \(formatter.localizedString(for: r, relativeTo: Date()))")
        }
        if w.source == .api { parts.append("from API") }
        return parts.joined(separator: " · ")
    }

    private func format(tokens n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStats/Views/LimitsBar.swift
git commit -m "views: LimitsBar progress strip for 5h/7d windows"
```

---

## Task 11: Insert LimitsBar into PopoverView

**Files:**
- Modify: `Sources/ClaudeStats/App/PopoverView.swift`

- [ ] **Step 1: Insert LimitsBar between statusRow and sectionTabs**

Open `Sources/ClaudeStats/App/PopoverView.swift`. Find:

```swift
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            if drillProjectKey == nil {
                sectionTabs
```

Replace with:

```swift
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            LimitsBar(state: viewModel.limits)
            if drillProjectKey == nil {
                sectionTabs
```

- [ ] **Step 2: Verify the build**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStats/App/PopoverView.swift
git commit -m "popover: render LimitsBar above section tabs"
```

---

## Task 12: AppContainer wiring + plan-label helper

**Files:**
- Modify: `Sources/ClaudeStats/App/AppContainer.swift`

- [ ] **Step 1: Add stored properties for the new components**

Open `Sources/ClaudeStats/App/AppContainer.swift`. Find the existing
stored-property block at the top of the class:

```swift
    let store: UsageStore
    let reader: UsageReader
    let monitor: ActivityMonitor
    let pricingFetcher: PricingFetcher
    let viewModel: StatsViewModel
    let updater: UpdaterController
```

Add immediately below:

```swift
    let catalog: PlanCatalog
    let detector: PlanDetector
```

- [ ] **Step 2: Replace the entire `init()` body**

Replace the entire `init()` method body with:

```swift
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

        let bundled = Bundle.main.url(forResource: "pricing-fallback", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) } ?? Data("{}".utf8)
        self.pricingFetcher = PricingFetcher(
            cacheDir: cache,
            bundledFallback: bundled,
            fetcher: PricingFetcher.defaultFetcher()
        )

        let initialPricing = (try? PricingTable.fromJSON(bundled)) ?? PricingTable(rates: [:])

        // ---- Limits subsystem ----
        let planLimitsData = Bundle.main.url(forResource: "plan-limits", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            ?? Data(#"""
            {"pro":{"five_hour":{"tokens":250000},"seven_day":null},
             "max_5x":{"five_hour":{"tokens":1250000},"seven_day":{"tokens":15000000}},
             "max_20x":{"five_hour":{"tokens":5000000},"seven_day":{"tokens":60000000}}}
            """#.utf8)
        let calibrationURL = appSupport.appendingPathComponent("plan-calibration.json")
        self.catalog = (try? PlanCatalog(bundledData: planLimitsData, calibrationURL: calibrationURL))
            ?? (try! PlanCatalog(bundledData: Data(#"""
            {"pro":{"five_hour":null,"seven_day":null},
             "max_5x":{"five_hour":null,"seven_day":null},
             "max_20x":{"five_hour":null,"seven_day":null}}
            """#.utf8), calibrationURL: calibrationURL))
        let keychain = KeychainReader()
        self.detector = PlanDetector(keychain: keychain)
        let calculator = UsageWindowCalculator(store: store)
        let calibrator = PlanCalibrator(fileURL: calibrationURL)
        let apiClient = LimitsAPIClient(keychain: keychain)

        self.viewModel = StatsViewModel(
            store: store, pricing: initialPricing,
            calculator: calculator, catalog: catalog,
            detector: detector, calibrator: calibrator,
            apiClient: apiClient
        )

        let monitor = ActivityMonitor(reader: reader, watchPath: claudeRoot.path)
        self.monitor = monitor
        monitor.onTick = { [weak viewModel, weak monitor] in
            guard let viewModel = viewModel, let monitor = monitor else { return }
            Task { @MainActor in
                viewModel.isActive = monitor.isActive
                await viewModel.refresh()
            }
        }

        self.updater = UpdaterController()
    }
```

Note: the `self.catalog` and `self.detector` assignments must happen
before `self.viewModel = StatsViewModel(... catalog: catalog, detector: detector ...)`
references them. The local `catalog` and `detector` shadowing works
because `self.` assignments above bound the same instances.

- [ ] **Step 3: Add the `detectedPlanLabel` computed property**

Add to `AppContainer` (anywhere in the class body, e.g. just above
`rebuildIndex()`):

```swift
    var detectedPlanLabel: String {
        guard let tier = detector.detect().tier else { return "" }
        return tier.displayName
    }
```

- [ ] **Step 4: Verify the project builds end-to-end**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 5: Run the full test suite**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass (baseline count + new tests added in earlier tasks).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStats/App/AppContainer.swift
git commit -m "container: wire Limits subsystem into StatsViewModel"
```

---

## Task 13: SettingsView — Limits section

**Files:**
- Modify: `Sources/ClaudeStats/Views/SettingsView.swift`

- [ ] **Step 1: Add limits controls to `SettingsView`**

Open `Sources/ClaudeStats/Views/SettingsView.swift`. Replace the entire file with:

```swift
import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoUpdate: Bool
    @AppStorage("useUsageAPI") private var useAPI: Bool = false
    @AppStorage("planOverride") private var planOverrideRaw: String = "auto"
    @State private var apiAlertMessage: String?
    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _autoUpdate = State(initialValue: container.updater.automaticallyChecks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 14, weight: .semibold))

            GroupBox("Limits") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Plan", selection: $planOverrideRaw) {
                        Text("Auto (\(autoLabel()))").tag("auto")
                        Text("Pro").tag(PlanTier.pro.rawValue)
                        Text("Max 5x").tag(PlanTier.max_5x.rawValue)
                        Text("Max 20x").tag(PlanTier.max_20x.rawValue)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: planOverrideRaw) { _, _ in
                        Task { await container.viewModel.refresh() }
                    }

                    Toggle("Use Anthropic API for real numbers", isOn: $useAPI)
                        .onChange(of: useAPI) { _, newValue in
                            if newValue {
                                Task {
                                    await container.viewModel.refresh()
                                    if let err = container.viewModel.limits.apiError {
                                        await MainActor.run {
                                            apiAlertMessage = err
                                            useAPI = false
                                        }
                                    }
                                }
                            }
                        }
                    if useAPI {
                        let count = (container.viewModel.limits.calibrationSamples
                                      .values.reduce(0, +))
                        Text("Calibrated from \(count) sample\(count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Calibration uses tokens from this Mac only. If you also use Claude Code on other machines, limit estimates may read low.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
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

            Toggle("Automatically check for updates", isOn: $autoUpdate)
                .onChange(of: autoUpdate) { _, on in
                    container.updater.automaticallyChecks = on
                }

            Button("Check for updates now") {
                container.updater.checkForUpdates()
            }

            Button("Rebuild index (relaunch required)") {
                Task {
                    await container.rebuildIndex()
                    NSApp.terminate(nil)
                }
            }

            Button("Open data folder") {
                let url = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("claude-stats")
                NSWorkspace.shared.open(url)
            }

            Spacer()

            HStack {
                Spacer()
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360, height: 420)
        .alert("Couldn't read from Keychain", isPresented: .constant(apiAlertMessage != nil)) {
            Button("OK") { apiAlertMessage = nil }
        } message: {
            Text(apiAlertMessage ?? "")
        }
    }

    private func autoLabel() -> String {
        let detected = container.detectedPlanLabel
        return detected.isEmpty ? "no plan detected" : "detected: \(detected)"
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds. Both `container.viewModel` and
`container.detectedPlanLabel` were added in Task 12.

- [ ] **Step 3: Run the full test suite**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStats/Views/SettingsView.swift
git commit -m "settings: add Limits section (plan picker, API toggle, sample count)"
```

---

## Task 14: README documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a `Limits` subsection to README**

Open `README.md`. Just after the existing `## Updates` section and before `## Pricing`, insert:

```markdown
## Limits

A progress strip above the popover tabs shows how much of your
subscription window you've consumed:

- **5h** — the rolling 5-hour quota Anthropic enforces on Pro and Max
  plans.
- **7d** — the rolling 7-day cap on Max plans only.

Your plan is auto-detected from Claude Code's Keychain entry, or you
can override it in **Settings → Limits**. By default the bar uses local
JSONL data compared against documented plan limits — the numbers are
approximations.

Toggle **Settings → Use Anthropic API for real numbers** to switch to
the same `/api/oauth/usage` endpoint Claude Code's `/usage` command
uses. The first time you enable this, macOS will prompt you to grant
Keychain access for the Claude Code credentials item. Once enabled,
the app also begins calibrating its bundled fallback limits against the
real numbers — so even if you later turn the toggle off, your local
estimates become more accurate over time.

Note: calibration uses tokens from this Mac only. If you also use
Claude Code on other machines under the same account, the local
estimate may read low.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README section explaining the Limits view"
```

---

## Task 15: Manual smoke test

**Files:** none.

This task runs the app end-to-end and verifies behavior. There are no
unit tests for the UI integration — these visual checks are the
acceptance test.

- [ ] **Step 1: Build the app bundle**

```bash
./scripts/build.sh
```

Expected: `ClaudeStats.app` produced.

- [ ] **Step 2: Run it and open the popover**

```bash
open ClaudeStats.app
```

Click the menubar item. Verify:

- The status row + token total render as before.
- A new narrow `LimitsBar` appears directly below the status row.
- At least one progress segment is shown (with `5h` label).
- If you're on Max, both `5h` and `7d` segments are visible side by side.
- Colors: green/blue at <60%, orange at 60-85%, red at >85%.

- [ ] **Step 3: Verify hover tooltip**

Hover over a segment. Tooltip should read something like
`530k / 1.26M tokens` (no `resets …` clause yet because API mode is off).

- [ ] **Step 4: Open Settings**

Click the gear icon. Verify:

- New "Limits" group box appears at the top.
- Plan picker shows `Auto (detected: Max 5x)` (or your plan).
- "Use Anthropic API for real numbers" toggle is off.

- [ ] **Step 5: Toggle API mode on**

Click the toggle. macOS should prompt for Keychain access — click
Always Allow. Within a few seconds:

- The progress segment values may update.
- Hover tooltip now includes `resets in Xh Ym · from API`.
- The Settings panel shows `Calibrated from 1 sample` (or higher).

If the API call fails, an alert pops up and the toggle resets to off.
That's the expected error path.

- [ ] **Step 6: Verify FSEvents real-time updates**

Open a Claude Code session in another terminal. Send any prompt that
consumes tokens. Within ~1 second, the popover's token total and
`5h` percent should update without any explicit refresh.

- [ ] **Step 7: Force-quit and re-launch**

```bash
killall ClaudeStats
open ClaudeStats.app
```

Verify settings persist:

- API toggle still on.
- Calibration sample count persists.
- Bar renders with previously calibrated limits.

- [ ] **Step 8: Verify calibration file exists**

```bash
ls -la "$HOME/Library/Application Support/claude-stats/plan-calibration.json"
cat  "$HOME/Library/Application Support/claude-stats/plan-calibration.json" | head -20
```

Expected: file present with at least one sample.

- [ ] **Step 9: Tag the implementation as ready for release**

```bash
git log --oneline -20
```

Verify the limits-related commits are stacked cleanly on top of `299d2f9`.
Once the maintainer is happy, a release tag `v1.0.x` can be pushed.

---

## Self-review checklist (for the implementing engineer)

After completing all tasks, run through this final check:

- [ ] `swift test` — full suite green; new test count ≈ baseline + 25
- [ ] `./scripts/build.sh` — bundle builds; `plan-limits.json` is inside `Contents/Resources/`
- [ ] Manual smoke test (Task 15) — all visual checks pass
- [ ] Confirm no leftover `TODO` / `FIXME` markers introduced:
  ```bash
  git diff main -- Sources Tests | grep -E "^\+.*(TODO|FIXME|XXX)" || echo "clean"
  ```
