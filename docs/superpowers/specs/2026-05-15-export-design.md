# Usage data export — design

Date: 2026-05-15
Status: Approved

An "Export…" button on the **Months** tab that lets the user pick a date
range and write two files to a folder: a per-`(month, project, model)`
CSV and a multi-page PDF report.

## Goals

- Let the user save their ClaudeStats usage data outside the app in a
  spreadsheet-friendly form (CSV) and a printable visual report (PDF).
- Range is user-controlled to the day.
- PDF mirrors the in-app aesthetic of the Months tab and its drill-in,
  with summary charts up top and per-month detail pages below.

## Non-goals

- Configurable PDF layout (always the same multi-page structure).
- Direct `.xlsx` generation. CSV is the spreadsheet path.
- Hour / minute date precision. Day granularity is plenty.
- Streaming export for very large databases. We materialise the full
  range in memory (bounded by the user-chosen range).
- Scheduled / recurring exports.
- Append-to-existing-file. Each export writes new files.

## UI

### Entry point

A new button in the Months tab footer area:

```
┌────────────────────────────────────────┐
│  …month list above…                    │
├────────────────────────────────────────┤
│  5 months with data       [Export…]    │  ← new button
└────────────────────────────────────────┘
```

The button is right-aligned in a small footer strip immediately under
the month list's ScrollView, on the same horizontal line as the
existing "N months with data" caption (which moves to the left).

### Export sheet

Tapping `Export…` presents a SwiftUI sheet (`.sheet(isPresented:)`)
containing:

```
┌────────────────────────────────────────┐
│  Export usage data                     │  ← title
├────────────────────────────────────────┤
│  Start  [📅 Jan 15, 2026 ▾]            │
│  End    [📅 May 15, 2026 ▾]            │
│                                        │
│  Presets:                              │
│   [ This year ]  [ Last 3 months ]     │
│   [ All time ]                         │
├────────────────────────────────────────┤
│              [ Cancel ]  [ Export… ]   │
└────────────────────────────────────────┘
```

- Start and end use SwiftUI `DatePicker` with `displayedComponents:
  .date` (day granularity).
- Initial start = first day of the currently-visible year in the Months
  tab. Initial end = today.
- Presets clamp start/end accordingly:
  - **This year** → Jan 1 of current year → today.
  - **Last 3 months** → today minus 90 days → today.
  - **All time** → earliest event date (from
    `UsageStore.earliestTimestamp()`) → today. Disabled if the store
    is empty.
- `Cancel` dismisses the sheet without exporting.
- `Export…` is disabled when start > end. Tapping it opens an
  `NSOpenPanel` configured for folder selection
  (`canChooseDirectories = true`, `canChooseFiles = false`,
  `canCreateDirectories = true`). After the user picks a folder, the
  sheet writes both files into that folder and dismisses.

### Filenames

```
claude-stats_<startISO>_to_<endISO>.csv
claude-stats_<startISO>_to_<endISO>.pdf
```

`<startISO>` and `<endISO>` are `yyyy-MM-dd`, e.g.
`claude-stats_2026-01-15_to_2026-05-15.csv`.

If a file with the same name exists, it is overwritten silently — the
user explicitly chose the destination folder.

### Progress / errors

The sheet shows a `ProgressView` overlay while exporting (typical time
is <500 ms for a year of data). On success the sheet dismisses. On
failure (folder not writable, store error) an alert shows the error
message and the sheet stays open so the user can retry.

## Data model

### `ExportData` (new value type)

```swift
struct ExportData {
    struct MonthBucket: Equatable {
        let year: Int
        let month: Int                       // 1...12
        let totalTokens: Int
        let estimatedCost: Double
        let sessionCount: Int
        let projectCount: Int
        let byModel: [UsageStore.ModelRow]   // ordered by total tokens desc
        let topProjects: [UsageStore.ProjectRow]  // up to 5
    }
    struct CSVRow: Equatable {
        let year: Int
        let month: Int
        let projectKey: String
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreateTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
        let estimatedCost: Double
    }
    let start: Date
    let end: Date
    let totalTokens: Int
    let estimatedCost: Double
    let sessionCount: Int
    let projectCount: Int
    let byModelOverall: [UsageStore.ModelRow]   // ordered desc, range-wide
    let months: [MonthBucket]                   // ordered chronologically (oldest first)
    let csvRows: [CSVRow]                       // already sorted (month asc, project, model)
}
```

`ExportData` is everything the renderers need. The view-model builds
it from store queries + pricing.

### `UsageStore.tokensByMonthProjectModel(start:end:calendar:)`

A new SQL helper grouped on three keys:

```swift
func tokensByMonthProjectModel(
    start: Date, end: Date, calendar: Calendar
) throws -> [(year: Int, month: Int, projectKey: String,
              model: String, tokens: TokenTotals)]
```

Internally uses `strftime('%Y', timestamp, 'unixepoch', 'localtime')`
and `strftime('%m', …)` to bucket by local-time year/month (same
pattern as the existing `tokensByMonthAndModel`), grouped by
`(year, month, project_key, model)`, filtered by `timestamp >= ? AND
timestamp < ?`. Returns at most ~ (#months × #projects × #models) rows.

### `StatsViewModel.buildExportData(start:end:) async throws -> ExportData`

Orchestrator. Calls the new SQL helper once, plus per-month
`sessionCount` and `tokensByProject` queries to populate each
`MonthBucket`'s `sessionCount`, `projectCount`, and `topProjects`. Maps
the raw rows into `CSVRow`s. Computes range-wide totals + `byModelOverall`
by summing across the months. Cost is computed at this layer via the
existing `PricingTable.cost(model:…)`.

The orchestrator is `async throws` (mirrors `projectDetail`/`monthDetail`
style — async to keep call sites consistent, even though the store
calls are synchronous internally).

## Output

### CSV

```
month,project,model,input_tokens,output_tokens,cache_create_tokens,cache_read_tokens,total_tokens,estimated_cost
2026-01,/Users/jappy/code/claude-stats,claude-opus-4-7,12345,6789,0,1024,20158,1.23
2026-01,/Users/jappy/code/claude-stats,claude-sonnet-4-6,…
2026-01,/Users/jappy/code/other-project,claude-opus-4-7,…
2026-02,…
```

- `month` is `yyyy-MM` (zero-padded).
- `project` is the project's canonical key (path-style, same as the
  app's internal key — preserves cross-app correlation).
- `model` is the raw model string (e.g. `claude-opus-4-7`).
- Token columns are integers; `estimated_cost` is a Double with two
  decimals (formatted via `String(format: "%.2f", …)`).
- Standard RFC 4180 quoting: values containing commas, quotes, or
  newlines are double-quoted; embedded quotes are doubled. (Project
  paths can contain spaces but typically not commas; quote defensively
  for any value containing `,`, `"`, `\n`, or `\r`.)
- Rows sorted by `(year, month, project, model)` ascending.

### PDF report

Pages are A4 / US Letter (612 × 792 points by default for US Letter,
adequate for a tidy report). Pages are composed from SwiftUI views
rendered via `ImageRenderer` (one `NSImage` per page) and assembled
via `PDFKit.PDFDocument`.

#### Page 1 — Summary

```
┌────────────────────────────────────────┐
│  ClaudeStats Usage Report              │
│  Jan 15, 2026  –  May 15, 2026         │
├────────────────────────────────────────┤
│  TOTAL TOKENS     12.4M                │
│  EST. COST        $42.17               │
│  SESSIONS         88                   │
│  PROJECTS         6                    │
├────────────────────────────────────────┤
│  Monthly totals                        │
│  [Swift Charts bar chart of the months]│
├────────────────────────────────────────┤
│  By token type        By model         │
│  [Donut: in/out/cc/cr][Donut: models]  │
└────────────────────────────────────────┘
```

- Header uses the same fonts/sizes the app uses elsewhere (system
  font, scaled up for print).
- The 4 totals are rendered as the existing `StatCard` view used in
  the popover, in a 2×2 grid.
- Charts use **Swift Charts** (`import Charts`, available on macOS
  14+). Bar chart: month labels on x, total-tokens on y. Donut charts:
  one per dimension (token type / model), each sized to take ~half the
  width.

#### Page 2+ — Per-month detail

One page per month in the range that has non-zero data. Months with
zero data are skipped (no empty pages). Layout per page:

```
┌────────────────────────────────────────┐
│  January 2026                          │
├────────────────────────────────────────┤
│  [Tokens]   [Est. cost]                │
│   3.2M       $11.42                    │
│   18 sess    4 projects                │
├────────────────────────────────────────┤
│  BY MODEL                              │
│  [opus-4-7]      2.1M     $8.10        │
│  [sonnet-4-6]    1.1M     $3.32        │
│  …                                     │
├────────────────────────────────────────┤
│  TOP PROJECTS (up to 5)                │
│  claude-stats         1.8M  $6.40      │
│  some-other-project   0.9M  $3.10      │
│  …                                     │
└────────────────────────────────────────┘
```

Mirrors the in-app drill-in (`MonthDetailView` in Total mode) — same
stat cards, same `ModelChip`-styled rows, same top-5-projects
treatment. The PDF version uses `ProjectName.display(for:)` for
prettier project labels but the CSV uses the raw canonical key for
unambiguous machine processing.

### Renderer

`PDFExporter` is a `@MainActor` struct with one method:

```swift
@MainActor
struct PDFExporter {
    static func render(_ data: ExportData) -> Data
}
```

Internally builds a SwiftUI view for each page and renders via
`ImageRenderer(content:)`. Each rendered `NSImage` is wrapped in a
`PDFPage` and added to a single `PDFDocument`. Returns the document's
`dataRepresentation()`.

`CSVExporter` is a `Sendable` struct with one method:

```swift
struct CSVExporter {
    static func csv(rows: [ExportData.CSVRow]) -> String
}
```

Pure function. Easy to unit-test deterministically.

### Architecture

```
ExportSheet (View)
  ├── Date pickers + preset buttons + Cancel/Export buttons
  └── On Export, calls viewModel.buildExportData → writes files via:
      ├── CSVExporter.csv(rows:)         → write to <folder>/<basename>.csv
      └── PDFExporter.render(_:)         → write to <folder>/<basename>.pdf
```

The sheet writes the files itself (using `Data.write(to:)` /
`String.write(to:atomically:encoding:)`). The view-model is the
orchestrator that builds `ExportData`; the renderers are pure value
factories that take `ExportData` and return bytes.

### View-model state additions

```swift
@MainActor extension StatsViewModel {
    func buildExportData(start: Date, end: Date) async throws -> ExportData
}
```

No new observable state. The sheet owns its own `@State` for start,
end, and `isExporting`.

## Edge cases

- **Empty range / no data.** The CSV gets a header row only. The PDF
  has only the summary page with `0 tokens / $0.00` and empty charts.
  No per-month pages.
- **Single-day range.** Works the same — typically yields at most one
  month's worth of rows.
- **Range spans years.** All months in the range are included, in
  chronological order.
- **End < Start.** The Export button is disabled.
- **Folder not writable / disk full.** Caught at write time; alert
  shown in the sheet, sheet stays open.
- **Pricing changes between range bounds.** Cost is computed once at
  export time against the current `PricingTable`. (We don't recompute
  historical pricing.)
- **Project keys containing CSV-special characters.** Quoted via RFC
  4180 rules.
- **All Time preset with empty store.** Preset is disabled.
- **Localisation.** Numbers and dates in the PDF use the user's locale
  via `DateFormatter` / `NumberFormatter`. CSV month uses ISO
  `yyyy-MM` regardless of locale (for machine consumption).

## Performance

A year-long range typically yields a few hundred CSV rows. Even a
10-year range is bounded by ~12 × #projects × #models ≈ low thousands.
SQL aggregation is fast. PDF rendering of ~12 pages takes well under
a second on modern hardware.

## Testing

- **`UsageStoreTests`**: assert `tokensByMonthProjectModel` returns the
  expected grouping for a multi-month / multi-project / multi-model
  fixture, and that out-of-range events are excluded.
- **`StatsViewModelTests`**: assert `buildExportData(start:end:)`
  produces correct totals, month buckets, and CSVRow ordering against
  a fake store + pricing.
- **`CSVExporterTests`** (new file): assert deterministic CSV output
  including quoted edge cases (project paths with commas, embedded
  quotes, newlines).
- **PDF**: no snapshot tests in this project (consistent with prior
  features). Manual verification via the sheet.

## Out of scope (future)

- Native `.xlsx` generation.
- Per-project / per-session export modes.
- Email/share-sheet integration.
- Background scheduled exports.
- Hourly granularity inside the day range.
