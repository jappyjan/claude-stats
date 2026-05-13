# Subscription limits — design

Date: 2026-05-13
Status: Approved

A new view in the menubar popover that shows how much of the user's Claude
subscription has been consumed in the windows Anthropic enforces (rolling
5-hour and, for Max plans, rolling 7-day). Plus a switch from 10-second
polling to FSEvents-driven real-time updates of the existing token/cost
display.

## Goals

- Show, at the top of the popover, narrow progress bars for the
  subscription-limit windows that apply to the user's plan.
- Auto-detect the plan tier from data already stored locally by Claude
  Code (macOS Keychain), with a manual override in Settings.
- Default to **local computation** — sum tokens in rolling 5h/7d windows
  from the existing JSONL data, compared against documented plan limits.
- Offer **opt-in API mode** that calls
  `GET https://api.anthropic.com/api/oauth/usage` (the same endpoint
  Claude Code's `/usage` slash command uses) for real numbers. Off by
  default; degrades cleanly to local computation on any failure.
- **Self-calibrating fallback**: when API mode is on, derive real plan
  limits from `local_tokens / (utilization / 100)` and persist them.
  Calibrated limits survive disabling API mode.
- Replace the existing 10-second polling timer with FSEvents on
  `~/.claude/projects` so token/cost numbers update within a fraction of
  a second of any session activity. Falls back to the existing 10s
  timer if FSEvents stream creation fails.

## Non-goals

- Claude Code hooks integration. FSEvents on the JSONL directory gives
  the same "instant updates" property with zero user-side configuration,
  so hooks would add a knob without buying anything.
- Notifications, sounds, or system alerts when limits are approached.
  (Possible later — explicit non-goal for v1.)
- Aggregating usage across multiple Macs. Local computation is
  per-machine. The opt-in API mode reflects the real account-wide number
  when enabled.
- Editing or estimating cost-per-window. Token-based only.
- Tracking the Anthropic developer API's per-minute rate limits
  (`anthropic-ratelimit-*` headers). Those are a different system from
  the subscription-plan windows we care about here.

## Data sources

### Anthropic OAuth usage endpoint

`GET https://api.anthropic.com/api/oauth/usage` with `Authorization:
Bearer <access_token>` returns:

```json
{
  "rate_limits": {
    "five_hour": {
      "utilization": 42.0,
      "resets_at": 1715620000
    },
    "seven_day": {
      "utilization": 18.0,
      "resets_at": 1715900000
    }
  }
}
```

- `utilization` is a 0–100 percentage.
- `resets_at` is a Unix epoch in seconds when that window resets.
- Either window key can be absent depending on plan (Pro: only
  `five_hour`; Max: both).
- The endpoint and field names were verified by reading symbols in the
  shipped Claude Code binary (v2.1.140). They are not part of any
  documented public API and may change without notice — see error
  handling.

### Keychain credentials

macOS Keychain stores Claude Code's OAuth state under
`security find-generic-password -s 'Claude Code-credentials'`. The
password value is a JSON object:

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt": 1778687485455,
    "scopes": ["user:profile", "user:sessions:claude_code", ...],
    "subscriptionType": "max",
    "rateLimitTier": "default_claude_max_5x"
  }
}
```

We use `subscriptionType` and `rateLimitTier` for **plan auto-detection**
(no API call needed). We use `accessToken` / `refreshToken` only when
the user has explicitly turned on **API mode**.

### Local JSONL data

Already ingested into `UsageStore` (SQLite) by the existing
`UsageReader`. The rolling-window aggregations are SQL `SUM(...) WHERE
timestamp BETWEEN ...`.

## Architecture

```
~/.claude/projects/**/*.jsonl
        │  (FSEvents stream, 200ms debounce)
        ▼
  UsageReader ─────────────► UsageStore (SQLite)
                                      │
                                      ▼
           UsageWindowCalculator  (5h, 7d rolling sums)
                                      │
                                      ▼
  PlanDetector ──► PlanCatalog ──► StatsViewModel.limits ──► LimitsBar
   (Keychain)      (bundled +                                   │
                    calibrated)                                 │
                          ▲                                     │
                          │                                     │
                  PlanCalibrator ◄── LimitsAPIClient (opt-in) ◄─┘
                                       (Keychain token,
                                        /api/oauth/usage)
```

### New module: `Sources/ClaudeStats/Limits/`

#### `PlanCatalog.swift`

Loads `Resources/plan-limits.json` (the bundled fallback table) and
overlays the contents of
`~/Library/Application Support/claude-stats/plan-calibration.json` if it
exists.

Public surface:

```swift
enum PlanTier: String, Codable { case pro, max_5x, max_20x }
enum Window: String, Codable { case fiveHour = "five_hour"
                                    sevenDay  = "seven_day" }
struct WindowLimit { let tokens: Int }

final class PlanCatalog {
    init(bundled: Data, calibrationURL: URL)
    func limit(plan: PlanTier, window: Window) -> WindowLimit?
    func reloadCalibration()  // called after PlanCalibrator writes
}
```

If a calibrated value exists for the (plan, window) pair, it shadows the
bundled value. If neither exists, returns `nil` (a Pro user looking up
`seven_day` returns `nil`, which the UI renders as "bar hidden").

#### `Resources/plan-limits.json`

Best-guess starting values, in tokens. These are deliberate over- or
under-estimates that get refined by `PlanCalibrator` over time. Initial
values:

```json
{
  "pro":     { "five_hour": { "tokens":   250000 }, "seven_day": null },
  "max_5x":  { "five_hour": { "tokens":  1250000 },
               "seven_day": { "tokens": 15000000 } },
  "max_20x": { "five_hour": { "tokens":  5000000 },
               "seven_day": { "tokens": 60000000 } }
}
```

#### `PlanDetector.swift`

Reads the Keychain item via `SecItemCopyMatching` with
`kSecClassGenericPassword` and `kSecAttrService` = `Claude Code-credentials`.
Parses the JSON value, returns:

```swift
struct DetectedPlan {
    let tier: PlanTier?
    let rawSubscriptionType: String   // e.g. "max"
    let rawRateLimitTier: String      // e.g. "default_claude_max_5x"
}
```

Mapping:

- `rateLimitTier == "default_claude_max_5x"` → `.max_5x`
- `rateLimitTier == "default_claude_max_20x"` → `.max_20x`
- `subscriptionType == "pro"` (and no `max_*` tier) → `.pro`
- anything else → `tier = nil` (user picks manually in Settings)

Keychain access prompts the user the first time. Result cached for the
app session.

#### `UsageWindowCalculator.swift`

Pure aggregation, no state:

```swift
struct UsageWindowCalculator {
    let store: UsageStore
    func tokens(in window: Window, endingAt now: Date) -> Int
    // Wraps UsageStore.totalTokens(start:end:) with the right offset.
    // five_hour:  end - 5*3600  ..  end
    // seven_day:  end - 7*86400 ..  end
}
```

Reuses `UsageStore.totalTokens(start:end:)` (already exists). No new
SQL needed.

#### `LimitsAPIClient.swift`

```swift
struct APIRateLimits: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resets_at: Int          // unix seconds
    }
    let five_hour: Window?
    let seven_day: Window?
}

actor LimitsAPIClient {
    init(keychain: KeychainReading, session: URLSessionProtocol = URLSession.shared)
    func fetchUsage() async throws -> APIRateLimits
}

protocol KeychainReading {
    func readClaudeCredentials() throws -> ClaudeCredentials
    func writeClaudeCredentials(_ creds: ClaudeCredentials) throws
}

struct ClaudeCredentials {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let subscriptionType: String?
    let rateLimitTier: String?
}
```

The default implementation wraps `SecItemCopyMatching` /
`SecItemUpdate` against service `Claude Code-credentials`. Tests inject
a fake.

Behavior:

- Reads `accessToken` from Keychain on each call.
- If `expiresAt < now`, calls
  `POST https://api.anthropic.com/oauth/token` with `grant_type=refresh_token`
  and writes the new tokens back to Keychain (matching how Claude Code
  refreshes them).
- One `URLSession.dataTask`-equivalent call with a 10s timeout.
- Decodes the response. Any failure (network, 4xx, 5xx, decode) throws.
- The decoder is tolerant: unknown fields are ignored, missing window
  keys are `nil`. If both `five_hour` and `seven_day` are `nil`, the
  result is still valid (just nothing to display from API).

#### `PlanCalibrator.swift`

Records (timestamp, plan, window, local_tokens, utilization) samples,
discards outliers, computes a median-based calibrated limit, persists.

```swift
struct CalibrationSample: Codable {
    let ts: Int             // unix seconds
    let localTokens: Int
    let utilization: Double
    let inferredLimit: Int
}

final class PlanCalibrator {
    init(fileURL: URL)
    func record(plan: PlanTier, window: Window,
                localTokens: Int, utilization: Double, now: Date)
    func calibrated(plan: PlanTier, window: Window) -> Int?
    func sampleCount(plan: PlanTier, window: Window) -> Int
}
```

**Sample-rejection rules**:

1. `utilization < 5.0` — small denominators amplify error.
2. `localTokens == 0` — no signal.
3. `inferredLimit` outside `[currentCalibrated / 3, currentCalibrated * 3]`
   when a calibrated value already exists — outlier guard.

**Storage**: `~/Library/Application Support/claude-stats/plan-calibration.json`.
Structure:

```json
{
  "max_5x": {
    "five_hour": {
      "samples": [
        { "ts": 1715600000, "localTokens": 530000,
          "utilization": 42.0, "inferredLimit": 1261905 },
        { "ts": 1715603600, "localTokens": 612000,
          "utilization": 48.7, "inferredLimit": 1256673 }
      ],
      "calibratedLimit": 1259289
    },
    "seven_day": { ... }
  }
}
```

Trim to the last **50 samples** per (plan, window). Recompute
`calibratedLimit` as the median of kept samples after each accepted
record. Write atomically: write to a temp file in the same directory,
then `rename(2)`.

### Modified: `Sources/ClaudeStats/Ingest/ActivityMonitor.swift`

Replace the 10s `Timer` with an `FSEventStream`.

- Stream created on `~/.claude/projects` with flags
  `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`,
  latency `0.2`.
- Scheduled on `CFRunLoopGetMain()`, mode `kCFRunLoopDefaultMode`.
- Callback marshals to `@MainActor`, resets a 200ms `DispatchWorkItem`
  debounce. On debounce fire, calls `reader.scan()` off the main actor,
  then invokes the existing `onTick` callback.
- **Safety-net Timer**: keep a 60-second `Timer` that also calls
  `scan()` + `onTick`, so any FSEvents miss (deep sleep, network mount,
  filesystem oddity) is recovered within a minute.
- **Wake handling**: on `NSWorkspace.didWakeNotification`, destroy and
  recreate the stream (FSEvents streams can become stale across sleep)
  and force one immediate scan.
- **Fallback**: if `FSEventStreamCreate` returns null or `Start` fails,
  fall back to the current 10s polling Timer. Log the failure to
  Console.app.

`isActive` derivation is unchanged (mtime within 30s).

The existing `onTick` callback contract is preserved so no caller
changes.

### Modified: `Sources/ClaudeStats/ViewModel/StatsViewModel.swift`

Add `limits` to the published state:

```swift
struct WindowProgress: Equatable {
    enum Source { case local, api }
    let window: Window
    let used: Int           // tokens (local or API-side)
    let limit: Int          // tokens (calibrated, bundled, or API-implied)
    let percent: Double     // 0..1, clamped
    let resetsAt: Date?     // present when source == .api or for fixed windows
    let source: Source
}

struct LimitsState: Equatable {
    let plan: PlanTier?
    let windows: [WindowProgress]
    let lastAPIRefresh: Date?
    let apiError: String?   // optional, surfaces in tooltip
}

var limits: LimitsState = .init(plan: nil, windows: [], lastAPIRefresh: nil, apiError: nil)
```

On every `refresh()`:

1. Compute local `WindowProgress` for each applicable window using
   `UsageWindowCalculator` and `PlanCatalog`. Always set source `.local`.
2. If API mode is on and ≥60s since last API fetch, kick off a
   non-blocking `Task` that calls `LimitsAPIClient.fetchUsage()`.
   - On success: produce API-source `WindowProgress` for each returned
     window (preferring API over local), record a calibrator sample,
     reload the catalog, publish the merged state.
   - On failure: keep the most recent successful API result if any
     (with a stale indicator), log error message; never block the local
     state from publishing.

### Modified: `Sources/ClaudeStats/App/PopoverView.swift`

Insert `LimitsBar(state: viewModel.limits)` between the existing
`statusRow` and `sectionTabs`. Component height ~22pt.

### New: `Sources/ClaudeStats/Views/LimitsBar.swift`

Renders one progress segment per applicable window, side by side. Each
segment:

- `5h` or `7d` label (10pt, secondary color)
- Track (gray) + fill (color depends on percent)
- Percent label, right-aligned, monospaced digit
- Color thresholds:
  - 0–60%: `.accentColor`
  - 60–85%: `.orange`
  - 85–100%: `.red`
- Tooltip on hover: `530k / 1.26M tokens · resets in 2h 14m` (or
  `resets 13:42` if `resetsAt` falls today).

Special states:

- No plan detected and no override: render a single-line clickable hint
  `Set your plan in Settings →` that opens settings.
- API error present: small faded `?` next to the percent; tooltip shows
  the error message.
- No windows applicable (e.g. Pro without `seven_day`): only the `5h` bar
  is rendered.

### Modified: `Sources/ClaudeStats/Views/SettingsView.swift`

Add a new section above "Launch at login":

```swift
GroupBox("Limits") {
    Picker("Plan", selection: $planOverride) {
        Text("Auto (detected: \(detectedLabel))").tag(PlanOverride.auto)
        Text("Pro").tag(PlanOverride.pro)
        Text("Max 5x").tag(PlanOverride.max_5x)
        Text("Max 20x").tag(PlanOverride.max_20x)
    }
    Toggle("Use Anthropic API for real numbers", isOn: $useAPI)
    if useAPI {
        Text("Calibrated from \(calibrationSampleCount) samples")
            .font(.caption).foregroundStyle(.secondary)
        Text("Note: calibration uses tokens from this Mac only. If you also use Claude Code on other machines, limit estimates may read low.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
```

Toggling `useAPI` to on triggers an immediate `LimitsAPIClient.fetchUsage()`
so the user sees feedback. If the call throws, show an `Alert` with the
error and reset the toggle to off.

### Modified: `scripts/build.sh`

After the existing `cp Sources/ClaudeStats/Resources/pricing-fallback.json
"$APP/Contents/Resources/"` line, add:

```bash
cp Sources/ClaudeStats/Resources/plan-limits.json "$APP/Contents/Resources/"
```

`PlanCatalog` loads it via
`Bundle.main.url(forResource: "plan-limits", withExtension: "json")` —
same pattern as `pricing-fallback.json` in `AppContainer`.

### Modified: `Sources/ClaudeStats/App/AppContainer.swift`

- Construct the new components (`PlanCatalog`, `PlanDetector`,
  `UsageWindowCalculator`, `LimitsAPIClient`, `PlanCalibrator`) in
  `init()`.
- Pass them to `StatsViewModel` (extend its initializer).
- Existing `ActivityMonitor` reference unchanged; its internals change
  but its API stays the same.

## Refresh cadence

| Loop | Trigger | Action |
|---|---|---|
| FSEvents stream | File mutation under `~/.claude/projects` | 200ms debounce → `UsageReader.scan()` → `viewModel.refresh()` |
| 60s safety net | `Timer` | Same as FSEvents — catches gaps |
| API usage fetch | `viewModel.refresh()` if API mode on AND ≥60s since last fetch | Non-blocking `Task` calling `LimitsAPIClient.fetchUsage()` |
| Wake | `NSWorkspace.didWakeNotification` | Recreate FSEvents stream + force one scan + force one API fetch |
| Pricing refresh | 24h `Timer` | Unchanged from current design |
| Midnight rollover | one-shot `Timer` | Unchanged from current design |

The 60s minimum on API fetches prevents hammering the endpoint during
heavy file activity, while still being responsive enough for the
calibration loop.

## Settings persistence

| Setting | Storage | Default |
|---|---|---|
| Plan override (`auto` / `pro` / `max_5x` / `max_20x`) | `UserDefaults` via `@AppStorage` | `auto` |
| Use Anthropic API | `UserDefaults` via `@AppStorage` | `false` |
| Calibration data | `~/Library/Application Support/claude-stats/plan-calibration.json` | empty (no samples) |
| OAuth tokens | Never copied. Read from Keychain on demand only. | — |

Surviving an index rebuild: calibration JSON lives outside the SQLite
DB, so `rebuildIndex()` leaves it intact.

## Error handling

| Failure | Behavior |
|---|---|
| Keychain item missing/denied (plan detect) | `PlanDetector` returns `tier = nil`; UI prompts user to pick a plan in Settings |
| Keychain access denied when toggling API on | One-time error alert; toggle resets to off; local computation continues |
| `/api/oauth/usage` 401 | Try refresh-token exchange once; on success, retry the request; on failure, disable API mode and alert |
| `/api/oauth/usage` 4xx (non-401) / 5xx / network error | Keep last successful API data (if any) with a stale-indicator dot; surface error in tooltip; retry on next tick |
| Response schema unrecognized | Recognized windows still render; unknown fields ignored; missing fields fall back to local. Log the raw response key set to Console.app for diagnostics |
| Calibration sample fails guard rails | Sample dropped silently; current `calibratedLimit` untouched |
| Calibration file unreadable / corrupt | Treat as missing; start fresh; back up corrupt file to `plan-calibration.json.bak.<ts>` |
| FSEvents stream creation fails | Fall back to existing 10s polling Timer; log to Console.app |
| FSEvents stream returns events for a file we don't own | Ignored by `UsageReader.scan()` filtering on `.jsonl` extension under the rooted tree (already done) |

## Multi-machine caveat

Local 5h / 7d token totals come from the JSONL files on this Mac.
Calibration math is `inferred_limit = local_tokens / (utilization /
100)`. If the user runs Claude Code on multiple machines under the same
Anthropic account, the global utilization reported by the API will
include the other machines' activity, but `local_tokens` won't —
producing an inferred limit that's too low.

We accept this tradeoff and document it in:

1. The Settings section near the API toggle (one-line note shown only
   when API mode is enabled).
2. README, under a new "Limits" subsection.

A future improvement could detect this pattern (consistent
`inferred_limit << bundled_guess`) and suppress calibration with a
warning, but that is explicit non-goal for v1.

## Test strategy

| Test file | What it covers |
|---|---|
| `PlanCatalogTests.swift` | Bundled JSON loads correctly; calibration file overlays bundled values; missing calibration falls through; Pro `seven_day` returns nil |
| `PlanDetectorTests.swift` | Protocol-injected Keychain reader; `subscriptionType`/`rateLimitTier` mapping for each documented combination; null/garbage tolerated |
| `UsageWindowCalculatorTests.swift` | In-memory `UsageStore`; events on the boundary, far in the past, in the future (clock skew); DST transition; 5h vs 7d math |
| `LimitsAPIClientTests.swift` | `URLProtocol` mock; happy-path parse; 401 → refresh-token exchange → retry; 5xx throws; malformed JSON throws; unknown extra fields ignored; missing window keys yield `nil` |
| `PlanCalibratorTests.swift` | Synthetic sample streams; guard-rail rejection (low utilization, outliers, zero local); median computation; trim-to-50; atomic write produces a valid JSON file at the target path |
| `ActivityMonitorFSEventsTests.swift` | Integration: write a `.jsonl` file under a temp root, verify the callback fires within 1s; gated behind a CI flag because FSEvents reliability in containerized CI varies |
| `LimitsBarSmokeTests.swift` | Renders without crashing at 0% / 50% / 95% / unknown-plan states. Lightweight smoke only — no pixel comparisons |

No tests for FSEvents internals or for the Anthropic endpoint behavior
beyond the contract we observe today.

## Project layout after the change

```
Sources/ClaudeStats/
├── App/                  (unchanged)
├── Ingest/
│   ├── ActivityMonitor   ← FSEvents-based + 60s safety net
│   ├── JSONLParser       (unchanged)
│   └── UsageReader       (unchanged)
├── Limits/               ← NEW
│   ├── LimitsAPIClient
│   ├── PlanCalibrator
│   ├── PlanCatalog
│   ├── PlanDetector
│   └── UsageWindowCalculator
├── Model/                (unchanged)
├── Pricing/              (unchanged)
├── Resources/
│   ├── pricing-fallback.json
│   └── plan-limits.json  ← NEW
├── Storage/              (unchanged)
├── Updates/              (unchanged)
├── ViewModel/
│   └── StatsViewModel    ← + limits state
└── Views/
    ├── LimitsBar         ← NEW
    ├── SettingsView      ← + Limits section
    └── ...               (unchanged)
```

## Edge cases

| Case | Behavior |
|---|---|
| Brand-new install, no calibration data, API off | Bundled fallback limits used. Bars may read inaccurately (esp. for Max). Documented in README. |
| API on, first ever fetch fails | Local computation shown. Toggle stays on; client retries on next tick. Settings shows the error. |
| API on, succeeds once, then permanently fails | Last successful API data shown with a stale-indicator dot, and `LimitsState.apiError` set, for as long as the toggle is on. After **15 minutes** of consecutive failures, the bar swaps to local-source values; the stale dot stays until either a successful fetch or the toggle is flipped off. |
| User edits Keychain item manually / signs out of Claude Code | API mode auto-disables on next 401; user re-enables after re-login. |
| Calibration converges then user changes plan tier (e.g. Pro → Max) | New plan = different bucket in the JSON, so calibration starts fresh for the new tier. Old tier's data is preserved (could be useful if the user reverts). |
| Calibration file corrupted (disk error) | Backed up to `.bak.<ts>` and starts fresh. |
| User on Pro, response unexpectedly includes `seven_day` | Both bars render. We don't fight the data. |
| Five-hour window resets while popover is open | Next refresh recomputes. The bar drops to 0% (or whatever the local recomputation says). No animation required. |
| FSEvents miss during heavy bursty writes | 60s safety-net Timer catches up. Worst-case staleness: 60s. |
| User has zero JSONL files (fresh Claude Code install) | All windows show 0%. Bars still visible if plan is known. |
| App launches with no network | API mode (if on) shows last cached error; local computation works fine. |

## Open questions

None at design approval. The Anthropic endpoint behavior is observed
from the shipped Claude Code binary, not documented, so the schema may
change in a future Claude Code release; that risk is contained to
`LimitsAPIClient` and handled by the schema-tolerant decoder + the
fallback to local computation.
