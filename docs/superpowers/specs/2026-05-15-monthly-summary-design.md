# Monthly usage summary — design

Date: 2026-05-15
Status: Approved

A new **Months** tab in the popover that shows per-month token totals and
estimated cost for a selectable year, with a tap-to-drill-in detail view
per month.

## Goals

- Let the user see how their Claude Code usage breaks down by calendar
  month — tokens used and estimated cost.
- Selectable year, defaulting to the current year, with quick navigation
  to prior years that have data.
- Drill-in per month showing model-level cost and the top projects for
  that month, consistent with the existing project drill-in UX.
- Reuse the established SQL aggregation path. No new persisted state,
  no schema changes.

## Non-goals

- Year-over-year comparisons or trend overlays across years.
- CSV / clipboard export of monthly data. (Possible later; explicit
  non-goal here.)
- Forecasting or budget alerts. The Limits view already covers
  current-window consumption.
- Sub-monthly granularity (weekly bars) inside this tab. The Overview's
  14-day chart and the Today/7d/30d ranges already cover short windows.

## UI

### Tab structure

A third tab `Months` is added to the existing `Section` enum in
`PopoverView.swift` alongside `overview` and `projects`. The popover's
`TimeRangeTabs` row is **hidden** when the Months tab is active —
months are inherently their own time bucketing, and the global range
selector wouldn't compose meaningfully with a year selector.

### Layout (top to bottom inside the Months tab)

```
┌────────────────────────────────────────┐
│  ◀   2026   ▶            12 months    │  ← year stepper
├────────────────────────────────────────┤
│  2026 · 12.4M tokens · $42.17          │  ← year summary header
├────────────────────────────────────────┤
│  May        ████████████   3.2M  $11  │
│  Apr        ██████          1.8M   $6 │
│  Mar        ███             0.7M   $2 │
│  …                                     │
│  Jan        ░                  0   $0 │
└────────────────────────────────────────┘
```

- **Year stepper.** `◀ 2026 ▶`. The `◀` button is disabled when the
  current year shown is the earliest year with any usage. The `▶`
  button is disabled when the shown year equals the current calendar
  year. A small caption to the right shows how many months in the
  selected year have non-zero data (e.g. "5 months with data").

- **Year summary header.** One line: `{year} · {total-tokens} ·
  ${total-cost}`. Tokens formatted with the same helper used elsewhere
  (k/M suffix). Cost formatted to two decimals.

- **Month list.** One row per month in the selected year (Jan – Dec,
  newest month first so the most-recent month is at the top — matches
  how a user reading top-down expects most-recent data). Each row:
  - Month name (3-letter, e.g. `May`).
  - Mini horizontal bar whose width is `monthTokens / maxMonthTokens`
    for the year. The max is computed from the year being displayed.
    A row with zero tokens shows a faint placeholder bar (1–2px tall
    track) so the row height stays consistent.
  - Total tokens (right-aligned, monospaced digits).
  - Estimated cost (right-aligned, monospaced digits, two decimals).
  - The row is a button. Tapping it pushes a `MonthDetailView` into the
    popover by using the same "replace content + Back button" pattern
    `ProjectDetailView` uses today.

- **Future months** in the current year are not rendered. (E.g.,
  viewing 2026 in May 2026 shows Jan–May only.) Past years always show
  all 12 months.

### Month detail view

Layout mirrors `ProjectDetailView`:

```
┌────────────────────────────────────────┐
│  ◀ Back                                │
├────────────────────────────────────────┤
│  May 2026                              │
│  3.2M tokens · $11.42                  │
│  18 sessions · 4 projects              │
├────────────────────────────────────────┤
│  BY MODEL                              │
│  [opus-4-7]     2.1M tokens   $8.10    │
│  [sonnet-4-6]   1.1M tokens   $3.32    │
│  …                                     │
├────────────────────────────────────────┤
│  TOP PROJECTS (up to 5)                │
│  claude-stats         1.8M  $6.40      │
│  some-other-project   0.9M  $3.10      │
│  …                                     │
└────────────────────────────────────────┘
```

Projects are listed up to a limit of 5, by total tokens descending.
"More projects" is not surfaced — the existing Projects tab covers that
need.

## Architecture

### `MonthBucket` (new value type)

```swift
struct MonthBucket: Equatable {
    let year: Int
    let month: Int      // 1...12
    let totalTokens: Int
    let estimatedCost: Double
    let byModel: [UsageStore.ModelRow]   // for drill-in
    // Note: project rows for the drill-in are queried on demand,
    // not held here, to keep MonthBucket cheap to recompute.
}
```

A `MonthBucket` represents one month of data already enriched with
cost (computed against the live `PricingTable`). Holding `byModel` on
the bucket means the drill-in's model breakdown renders without a
second store query.

### `UsageStore.tokensByMonthAndModel(year:calendar:)`

A new SQL helper:

```swift
func tokensByMonthAndModel(year: Int, calendar: Calendar)
    throws -> [(month: Int, model: String, tokens: TokenTotals)]
```

Internal implementation: build the start/end timestamps for Jan 1 and
Jan 1 of the next year in the given calendar, then a single query:

```sql
SELECT
  strftime('%m', timestamp, 'unixepoch', 'localtime') AS month,
  model,
  SUM(input_tokens), SUM(output_tokens),
  SUM(cache_create_tokens), SUM(cache_read_tokens)
FROM usage_event
WHERE timestamp >= ? AND timestamp < ?
GROUP BY month, model
ORDER BY month;
```

`localtime` matches how `dailyTokens` buckets days (local-time
`Calendar.current.startOfDay`). Months are returned as strings (`"05"`)
parsed into `Int` in Swift.

### `UsageStore.tokensByMonthAndProject(year:month:calendar:limit:)`

Used by the month drill-in to list top projects for a month:

```swift
func tokensByMonthAndProject(year: Int, month: Int,
                              calendar: Calendar, limit: Int)
    throws -> [UsageStore.ProjectRow]
```

Computes the month's start/end timestamps and runs the existing
`tokensByProject`-style query restricted to that window, ordered by
total tokens desc, limited to `limit` rows.

### `StatsViewModel` additions

```swift
struct YearSummary: Equatable {
    let year: Int
    let months: [MonthBucket]            // 12 entries, Jan first; sparse months get 0s
    let earliestYearWithData: Int?       // for stepper bounds
    let monthsWithData: Int              // for the caption
}

struct MonthDetail: Equatable {
    let year: Int
    let month: Int                       // 1...12
    let totalTokens: Int
    let estimatedCost: Double
    let sessionCount: Int
    let projectCount: Int
    let byModel: [UsageStore.ModelRow]   // ordered by total tokens desc
    let topProjects: [UsageStore.ProjectRow]  // up to 5
}

var monthsYear: Int = Calendar.current.component(.year, from: Date())
var yearSummary: YearSummary = …
```

The `MonthsView` reverses the Jan-first array when rendering so the
most-recent month appears at the top. Keeping the stored shape Jan-Dec
makes index-based access predictable and keeps tests asserting against
calendar-natural ordering.

Cost for individual model rows in `MonthDetail` is computed at render
time via `PricingTable.cost(model:input:output:cacheCreate:cacheRead:)`
— the same pattern the existing Overview and project detail views use,
so a pricing refresh propagates without rebuilding stored detail
records.

A new method `refreshYearSummary()` runs when:
- the Months tab becomes visible, or
- `monthsYear` changes, or
- `refresh()` runs and the Months tab is currently visible.

It calls `tokensByMonthAndModel` once, groups results by month in
Swift, and applies `PricingTable.cost(model:…)` to compute cost per
month. The Jan–Dec array is filled with zero `MonthBucket`s for months
that had no rows.

`earliestYearWithData` is computed once and cached — a single
`SELECT MIN(timestamp)` query, derived from `store.earliestTimestamp`,
re-run when the database is rebuilt but otherwise stable. (Once
known, it only ever decreases when older data appears.)

`monthDetail(year:month:)` — analogous to the existing
`projectDetail(for:)`. Looks up the cached `MonthBucket` (for tokens +
byModel + cost) and calls `tokensByMonthAndProject` for the top
projects.

### View files

- `MonthsView.swift` — the new tab body. Owns the year selection
  binding via the view-model. Renders the year stepper, header, and
  month list. Tapping a row sets `drillMonth = (year, month)` and
  fetches the detail.
- `MonthDetailView.swift` — modeled after `ProjectDetailView`.
- `MonthRow.swift` (optional, small) — single-row component for
  consistency with `ProjectRow`.

### `PopoverView` wiring

- Add `case months` to `Section`.
- Suppress the `TimeRangeTabs` when `section == .months`.
- Introduce a parallel drill state for months:
  `@State private var drillMonth: (year: Int, month: Int)? = nil`
  with a fetched `StatsViewModel.MonthDetail?` analogous to
  `drillDetail`.

## Edge cases

- **No data in selected year.** Show the same 12-month layout, all zero
  rows, year summary `0 tokens · $0.00`, caption "0 months with data".
- **No data at all.** Default `monthsYear` to current year. Stepper's
  `◀` is disabled. Tab still renders without crashing.
- **Future months in the current year.** Suppressed. The list shows
  only Jan through the current month.
- **Pricing changes mid-session.** `PricingTable` is observed and a
  pricing refresh triggers `refreshYearSummary()` via the existing
  `refresh()` path. Cost recomputes from stored tokens — no stale
  costs persisted.
- **Models without pricing data.** Cost contribution is 0 for those
  tokens (same behavior as Overview today). Tokens still count.
- **Switching tabs.** `refreshYearSummary()` is idempotent. Running it
  twice in quick succession is cheap (single query).
- **Daylight-saving boundaries.** `localtime` in SQLite uses the
  system's local TZ rules, including DST. Acceptable — months are
  coarse enough that DST shifts are not material.

## Performance

The new query touches the entire `usage_event` table but is bounded by
a year-long window and grouped to ≤ 12 × (# models) rows — small
result set, well-served by the existing `idx_usage_ts` index. On a
database with hundreds of thousands of events, this is a low-tens-of-
milliseconds query and runs only on tab/year change.

## Testing

- `UsageStoreTests`:
  - Inserts spanning multiple months / multiple models / multiple
    years; assert the year-scoped query returns the correct
    `(month, model, tokens)` grouping.
  - Empty year returns an empty result; the view-model layer is
    responsible for zero-filling to 12 rows.
  - Local-time bucketing: an event at `2026-01-01 00:30 local`
    appears in month `01`, not `12` of the prior year.
- `StatsViewModelTests`:
  - Setting `monthsYear` and calling `refreshYearSummary()` produces
    exactly 12 entries with the expected per-month tokens, byModel,
    and cost given a fake store and pricing table.
  - Current-year case: months strictly after the current month are
    included as zero rows. (Suppression of future months happens at
    render time in the view, not in the data layer — keeps the data
    shape stable for tests.)
  - `monthsWithData` matches the count of months whose `totalTokens > 0`.
- View tests aren't part of the existing test surface for the app, so
  no new SwiftUI snapshot tests — manual verification via `swift run`.

## Out of scope (future)

- Year-over-year comparison overlay.
- Export to CSV/clipboard.
- Per-month budget targets with notifications.
- Quarterly / fiscal-year bucketing.
