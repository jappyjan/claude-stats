# claude-stats — design

A macOS menubar app that visualizes local Claude Code usage from JSONL session logs.

## Goals

- At-a-glance view of how much you're using Claude Code (today's tokens) and whether a session is currently active.
- One-click drilldown into per-project, per-model, per-session breakdowns across selectable time ranges.
- Up-to-date model pricing without manual maintenance.
- Zero setup beyond installing the app: no API keys, no daemons, no third-party services.

## Non-goals

- Claude Desktop / claude.ai web usage (data lives server-side; would require an admin API key).
- Cross-device sync, team views, multi-user support.
- Editing or replaying past sessions.
- Notifications, budgets, or alerts (v1).

## Data source

Claude Code writes per-session JSONL files under `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` (and `.../<session-id>/subagents/agent-*.jsonl` for subagents). Each assistant message line includes a `message.usage` object with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, and `cache_read_input_tokens`, plus the `model` ID, a `timestamp`, the `cwd`, and the `sessionId`.

Lines without `message.usage` (queue ops, hook events, user messages, progress events) are skipped.

**Token total** displayed throughout the UI is `input + output + cache_create + cache_read` — all four are billed by Anthropic, so this matches what the cost figure represents. The Overview's "Cache hit rate" and the per-stat sub-labels exist precisely to surface the cache-vs-fresh split for users who care.

## Architecture

Components are small and single-purpose so each can be reasoned about and tested in isolation.

```
JSONL files → UsageReader (incremental) → UsageStore (SQLite)
                                              ↓
ActivityMonitor (mtime check) → StatsViewModel ← time range selection
                                              ↓
                                    MenuBarExtra + PopoverView
```

### Components

1. **`UsageEntry`** — value type for one assistant message: `timestamp, sessionId, projectPath, model, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens`.

2. **`JSONLParser`** — given a file URL and a starting byte offset, streams lines, decodes only those with `message.usage`, yields `UsageEntry` records. Returns the new end offset. Handles a truncated final line (mid-write) by stopping at the last complete line and returning that offset, so the next tick retries cleanly. No persistent state.

3. **`UsageReader`** — walks `~/.claude/projects/**/*.jsonl` (including `subagents/` subdirs). For each file, looks up its `(mtime, last_offset)` in the `file_state` table; skips unchanged files; calls `JSONLParser` with the offset for changed ones; updates `file_state`. Detects deleted files and prunes them.

4. **`UsageStore`** — SQLite wrapper at `~/Library/Application Support/claude-stats/usage.db`. Tables:
   ```sql
   usage_event(id INTEGER PRIMARY KEY, timestamp INTEGER, session_id TEXT,
               project_path TEXT, model TEXT, input_tokens INTEGER,
               output_tokens INTEGER, cache_create_tokens INTEGER,
               cache_read_tokens INTEGER);
   file_state(path TEXT PRIMARY KEY, mtime INTEGER,
              last_offset INTEGER, last_scanned_at INTEGER);
   ```
   Indexes: `(timestamp)`, `(project_path, timestamp)`, `(session_id)`. Aggregations are SQL `SUM`/`GROUP BY` queries; no separate materialized cache — fast enough at this scale (~1k files, ~hundreds of thousands of events).

5. **`ActivityMonitor`** — runs every 10 seconds. Triggers `UsageReader` for changed files. Sets `isActive = true` if any JSONL file's mtime is within the last 30 seconds.

6. **`PricingTable`** + **`PricingFetcher`** — see "Pricing" section.

7. **`StatsViewModel`** (`@Observable`) — owns the timer, current time range, current view (Overview vs Projects vs project drill-in). Exposes published properties consumed by SwiftUI: `todayTokens`, `isActive`, `overview`, `projectRows`, `projectDetail(for:)`. Single owner of UI state.

8. **`ClaudeStatsApp`** + **`PopoverView`** — `@main` SwiftUI app using `MenuBarExtra(label:)` to render the menubar item; `PopoverView` is the click-open content.

### Project name derivation

`project_path` is the cwd recorded in each JSONL line. Display name is the last path component, with these normalizations:
- `/Users/jappy/code/<org>/<repo>/...` → `<repo>`
- `/Users/jappy/code/jappyjan/<repo>/...` → `<repo>`
- Worktree paths under `<repo>/.claude/worktrees/<name>` collapse back to `<repo>` so worktree sessions aggregate with their parent.
- Paths starting with `/Users/jappy/-` (encoded by Claude Code for sessions outside any project) become `no-project`.

## UI

A single `MenuBarExtra` with a custom popover (~380 px wide, max ~480 px tall, scrollable).

### Menubar label

- **Active**: green dot + today's total tokens (`● 412k`).
- **Idle**: gray dot + today's total tokens (`● 412k`).
- "Active" = any tracked JSONL had mtime within the last 30 seconds.

### Popover top section

- **Status line**: `● Active in N session(s)` or `● Idle` on the left; `412k today · ~$3.20` on the right.
- **Section tabs**: `Overview` | `Projects` (the two top-level views).
- **Time range tabs** (segmented control): `Today` | `7d` | `30d` | `All`. Applies to whichever section is active.

### Overview view

- 2×2 grid of stat cards: **Total tokens**, **Est. cost**, **Sessions**, **Cache hit rate** (`cache_read / (cache_read + cache_create + input)`). Each card has a one-line sub-label:
  - Tokens / cost: `+18% vs prior period` (the same-length window immediately before the selected one). On `All`, the sub-label is the date of the first event instead.
  - Sessions: project count (`5 projects`).
  - Cache hit rate: total cache reads in the period (`256k cache reads`).
- **Last 14 days** trend: 14 stacked bars; today's bar highlighted in green; empty days rendered as a thin gray stub.
- **By model** list: one row per model used in the selected range, sorted by token count desc. Model chip + tokens + cost.

### Projects view

- One row per project, sorted by tokens desc.
- Row layout: project name + relative-size bar (longest project = 100%) on the left; tokens and cost right-aligned.
- Click any row → drill-in.

### Project drill-in

- Header: `‹ Projects` back button + project name.
- Time range tabs preserved (range carries over from the list view).
- 2-card stat grid: **Tokens** (with "% of total in this range") and **Est. cost** (with session count).
- **By model** breakdown for this project.
- **Recent sessions** list — most recent 10 sessions in the range, showing session ID prefix, relative time + duration, tokens, and cost. Scrolls if more exist.
- Footer shows the full project path.

### Footer

- Left: summary count (e.g. `5 projects · 12 sessions`) on Overview/Projects; full path on drill-in.
- Right: `⚙` opens a small settings sheet (launch at login toggle, "rebuild index" button, "open data folder", version).

## Pricing

Cost figures use a per-model rate table (`PricingTable`) covering input, output, cache-write, and cache-read prices per million tokens.

### Source

Primary: LiteLLM's community-maintained pricing JSON.

```
https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/model_prices_and_context_window_backup.json
```

Reasons:
- Single JSON file with rates for all Anthropic models (and many others), keyed by model ID.
- Updated within days of upstream price changes by an active OSS project.
- No API key, no auth, no rate limit issues at our usage volume.
- Anthropic's `/v1/models` API does not expose pricing, so we can't use it.

### Cache & refresh

- On launch, fetch if cached copy is older than 24 hours.
- A 24-hour `Timer` re-fetches in the background while the app runs.
- On `NSWorkspace.didWakeNotification`, re-check staleness and refetch if needed (Timers don't accumulate fires during sleep).
- Cache file: `~/Library/Caches/claude-stats/pricing.json` plus a sibling `pricing.json.meta` with the fetch timestamp.
- On fetch failure: keep the existing cache; retry on next 24h tick. Never block the UI.

### Bundled fallback

A `pricing-fallback.json` shipped inside the app bundle (`Resources/`), same shape as the LiteLLM file, captured at build time. Used only when no cached copy exists yet AND the network fetch fails (e.g., brand-new install while offline). Lets the app function without ever having reached the network.

### Lookup

`PricingTable.cost(for: UsageEntry) -> Double?` — returns `nil` for unknown models. Unknown models still have their tokens counted and shown; cost cells render `—`.

## Refresh cadence

Multiple loops at different intervals:

| Loop | Interval | Trigger | Purpose |
|---|---|---|---|
| Activity monitor | 10s | `Timer` | Incremental JSONL scan, active flag, today's totals |
| Pricing refresh | 24h | `Timer` | Re-fetch LiteLLM JSON if needed |
| Wake handling | event | `NSWorkspace.didWakeNotification` | One activity tick + pricing staleness check |
| Midnight rollover | event | one-shot `Timer` to next local midnight | Recompute "today" aggregates and reschedule |

The midnight rollover matters because the app may stay open for weeks; without it, "today's tokens" would silently mean "the day the app launched."

## Edge cases

- **Truncated final JSONL line** (file written mid-message): parser detects decode failure on the last line, leaves `last_offset` at the start of that line, retries on next tick.
- **Subagent JSONLs** (`.../subagents/agent-*.jsonl`): included in totals — their tokens hit the same account.
- **File deletion**: detected on each directory walk; row pruned from `file_state`. Existing `usage_event` rows are kept (historical totals stay correct).
- **Unknown model ID**: tokens counted; cost rendered as `—`.
- **Cold start with no DB**: first run shows an "Indexing…" state in the popover during the initial scan (~10–30s on a 223 MB / 1k-file corpus).
- **Time-zone changes**: midnight rollover uses the current locale at fire time, so a manual TZ change picks up the new boundary on next reschedule.

## Project layout

```
claude-stats/
├── Package.swift
├── README.md
├── Sources/ClaudeStats/
│   ├── App/             ClaudeStatsApp.swift, PopoverView.swift
│   ├── Views/           OverviewView, ProjectsView, ProjectDetailView,
│   │                    TimeRangeTabs, ProjectRow, SettingsSheet
│   ├── Model/           UsageEntry, TimeRange, PricingTable
│   ├── Storage/         UsageStore (SQLite), Schema
│   ├── Ingest/          JSONLParser, UsageReader, ActivityMonitor
│   ├── Pricing/         PricingFetcher
│   ├── ViewModel/       StatsViewModel
│   └── Resources/       pricing-fallback.json, Info.plist
├── Tests/ClaudeStatsTests/
│   ├── JSONLParserTests.swift
│   ├── UsageStoreTests.swift
│   ├── PricingTableTests.swift
│   ├── TimeRangeTests.swift
│   └── Fixtures/sample.jsonl
└── scripts/
    ├── build.sh         swift build -c release + bundle assembly
    └── install.sh       build + copy to ~/Applications + open
```

## Build & install

- **Toolchain**: Swift Package Manager. `swift build -c release`.
- **Minimum macOS**: 14.0 (required for `MenuBarExtra`, `@Observable`, `SMAppService`).
- **Dependencies**: none third-party. SQLite via the system `import SQLite3`.
- **App bundle**: `scripts/build.sh` produces `ClaudeStats.app/Contents/{MacOS,Resources}/` with the binary, `Info.plist` (`LSUIElement = true` to suppress Dock icon), and `pricing-fallback.json`.
- **Install**: `scripts/install.sh` runs build, copies to `~/Applications/ClaudeStats.app`, opens it. Gatekeeper warns on first launch (no codesigning); right-click → Open dismisses.
- **Launch at login**: `SMAppService.mainApp.register()`. Toggle lives in the settings sheet, off by default.

## Test strategy

Unit tests for parts with non-trivial logic; manual verification for UI.

- `JSONLParserTests` — fixture covering: standard assistant message with usage; line without `message.usage` (skipped); subagent message; hook progress event; truncated final line (recovered); malformed JSON line (skipped without halting).
- `UsageStoreTests` — in-memory SQLite. Insert events, run aggregations for each time range, verify incremental insert via `last_offset` tracking.
- `PricingTableTests` — known model returns expected per-token math; unknown model returns `nil`; cost calculation handles all four token categories.
- `TimeRangeTests` — boundaries for Today / 7d / 30d / All; midnight rollover with mocked clock; DST and TZ-change behavior.

No UI tests for v1.

## Open questions / deferred

- Whether to add a "this month" range — deferred; `30d` is close enough.
- Whether to show currency in user's locale — deferred; USD only for now.
- Notifications (e.g. "you've spent $X today") — explicit non-goal for v1.
