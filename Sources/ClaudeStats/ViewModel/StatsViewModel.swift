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
        var firstEventDate: Date? = nil
    }

    struct ProjectDetail: Equatable {
        let projectKey: String
        let totals: UsageStore.ProjectRow
        let cost: Double?
        let percentOfRange: Double
        let byModel: [UsageStore.ModelRow]
        let recentSessions: [UsageStore.SessionRow]
    }

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
    var monthsYear: Int = Calendar.current.component(.year, from: Date())
    var yearSummary: YearSummary = YearSummary(
        year: Calendar.current.component(.year, from: Date()),
        months: [],
        earliestYearWithData: nil,
        monthsWithData: 0
    )

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
            let nextTodayTokens = try store.totalTokens(start: todayBounds.start, end: todayBounds.end)

            // Project rows for the selected range.
            let nextProjectRows = try store.tokensByProject(start: bounds.start, end: bounds.end)

            let projModelRows = try store.tokensByProjectAndModel(start: bounds.start, end: bounds.end)
            var nextProjectCosts: [String: Double] = [:]
            for r in projModelRows {
                let c = pricing.cost(model: r.model,
                                     input: r.inputTokens,
                                     output: r.outputTokens,
                                     cacheCreate: r.cacheCreateTokens,
                                     cacheRead: r.cacheReadTokens)
                if let c { nextProjectCosts[r.projectKey, default: 0] += c }
            }

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

            let firstDate = try store.earliestTimestamp(start: bounds.start, end: bounds.end)

            let denom = totals.input + totals.cacheCreate + totals.cacheRead
            let hitRate = denom == 0 ? 0 : Double(totals.cacheRead) / Double(denom)

            let nextOverview = Overview(
                totalTokens: totals.total,
                totalCost: totalCost,
                sessionCount: sessions,
                projectCount: nextProjectRows.count,
                cacheHitRate: hitRate,
                dailyTokens: dailyTokens,
                byModel: byModel,
                priorTotalTokens: priorTokens,
                priorTotalCost: priorCost,
                firstEventDate: firstDate
            )

            // Atomic assignment of all published state.
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
    }

    /// Used by Settings to give the user immediate feedback when they
    /// toggle API mode on. Bypasses the 60s throttle and surfaces any
    /// error directly to the caller. Sets `lastAPIFetch` so subsequent
    /// FSEvents-triggered refresh calls respect the cooldown.
    func fetchAPILimitsNow() async -> String? {
        let now = Date()
        lastAPIFetch = now
        do {
            let response = try await apiClient.fetchUsage()
            applyAPIResponse(response, now: now)
            return nil
        } catch {
            let message = String(describing: error)
            limits.apiError = message
            return message
        }
    }

    /// Clears any persisted API error. Called when the user turns API
    /// mode off so the UI doesn't keep showing a stale "?" indicator.
    func clearAPIError() {
        limits.apiError = nil
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

    /// Helper for the export sheet's "All time" preset. Returns nil if the
    /// store has no events.
    func earliestEventDate() -> Date? {
        (try? store.earliestTimestamp())
    }

    /// Materialises an `ExportData` for the user-facing date range. `start` and
    /// `end` are day-precision bounds — `end` is INCLUSIVE (the day of `end` is
    /// included in the export). The orchestrator expands `end` by one day
    /// internally to query SQL with a half-open interval. The user's `start`
    /// and `end` are stored verbatim on the returned `ExportData` so the PDF
    /// header and filename both render the dates the user actually picked.
    /// Pricing is applied at call time from the current `PricingTable`.
    func buildExportData(start: Date, end: Date) async throws -> ExportData {
        let cal = Calendar.current
        let rangeStart = cal.startOfDay(for: start)
        let rangeEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end)) ?? end
        let raw = try store.tokensByMonthProjectModel(start: rangeStart, end: rangeEnd, calendar: cal)

        var csvRows: [ExportData.CSVRow] = []
        csvRows.reserveCapacity(raw.count)
        for r in raw {
            let total = r.tokens.total
            let cost = pricing.cost(
                model: r.model,
                input: r.tokens.input,
                output: r.tokens.output,
                cacheCreate: r.tokens.cacheCreate,
                cacheRead: r.tokens.cacheRead
            ) ?? 0
            csvRows.append(ExportData.CSVRow(
                year: r.year, month: r.month,
                projectKey: r.projectKey, model: r.model,
                inputTokens: r.tokens.input,
                outputTokens: r.tokens.output,
                cacheCreateTokens: r.tokens.cacheCreate,
                cacheReadTokens: r.tokens.cacheRead,
                totalTokens: total,
                estimatedCost: cost
            ))
        }

        // Group raw rows by (year, month) for buckets and by model for overall.
        var rowsByMonth: [String: [(projectKey: String, model: String, tokens: UsageStore.TokenTotals)]] = [:]
        var modelTotals: [String: UsageStore.TokenTotals] = [:]
        for r in raw {
            let key = "\(r.year)-\(r.month)"
            rowsByMonth[key, default: []].append((r.projectKey, r.model, r.tokens))
            let cur = modelTotals[r.model] ?? UsageStore.TokenTotals(input: 0, output: 0, cacheCreate: 0, cacheRead: 0)
            modelTotals[r.model] = UsageStore.TokenTotals(
                input: cur.input + r.tokens.input,
                output: cur.output + r.tokens.output,
                cacheCreate: cur.cacheCreate + r.tokens.cacheCreate,
                cacheRead: cur.cacheRead + r.tokens.cacheRead
            )
        }

        // Build MonthBuckets in chronological order. For each month, derive
        // sessionCount and topProjects from the store, clipped to the
        // intersection of (month bounds, requested range).
        var buckets: [ExportData.MonthBucket] = []
        var seenMonths: Set<Int64> = []
        var uniqueMonths: [(year: Int, month: Int)] = []
        for r in raw {
            let key = Int64(r.year) * 100 + Int64(r.month)
            if seenMonths.insert(key).inserted {
                uniqueMonths.append((year: r.year, month: r.month))
            }
        }
        uniqueMonths.sort { ($0.year, $0.month) < ($1.year, $1.month) }
        for ym in uniqueMonths {
            var startComps = DateComponents()
            startComps.year = ym.year
            startComps.month = ym.month
            startComps.day = 1
            startComps.timeZone = cal.timeZone
            guard let monthStart = cal.date(from: startComps),
                  let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)
            else { continue }
            let lo = max(rangeStart, monthStart)
            let hi = min(rangeEnd, monthEnd)
            let sessions = try store.sessionCount(start: lo, end: hi)
            let projects = try store.tokensByProject(start: lo, end: hi)

            // ByModel for this month (sorted desc by total).
            let monthRaw = rowsByMonth["\(ym.year)-\(ym.month)"] ?? []
            var byModelMap: [String: UsageStore.TokenTotals] = [:]
            for entry in monthRaw {
                let cur = byModelMap[entry.model] ?? UsageStore.TokenTotals(input: 0, output: 0, cacheCreate: 0, cacheRead: 0)
                byModelMap[entry.model] = UsageStore.TokenTotals(
                    input: cur.input + entry.tokens.input,
                    output: cur.output + entry.tokens.output,
                    cacheCreate: cur.cacheCreate + entry.tokens.cacheCreate,
                    cacheRead: cur.cacheRead + entry.tokens.cacheRead
                )
            }
            let byModel: [UsageStore.ModelRow] = byModelMap.map { model, t in
                UsageStore.ModelRow(
                    model: model,
                    totalTokens: t.total,
                    inputTokens: t.input,
                    outputTokens: t.output,
                    cacheCreateTokens: t.cacheCreate,
                    cacheReadTokens: t.cacheRead
                )
            }.sorted { $0.totalTokens > $1.totalTokens }
            let totalTokens = byModel.reduce(0) { $0 + $1.totalTokens }
            let cost = byModel.reduce(0.0) { acc, row in
                acc + (pricing.cost(
                    model: row.model,
                    input: row.inputTokens,
                    output: row.outputTokens,
                    cacheCreate: row.cacheCreateTokens,
                    cacheRead: row.cacheReadTokens
                ) ?? 0)
            }
            buckets.append(ExportData.MonthBucket(
                year: ym.year, month: ym.month,
                totalTokens: totalTokens,
                estimatedCost: cost,
                sessionCount: sessions,
                projectCount: projects.count,
                byModel: byModel,
                topProjects: Array(projects.prefix(5))
            ))
        }

        // Range-wide totals.
        let totalTokens = buckets.reduce(0) { $0 + $1.totalTokens }
        let totalCost = buckets.reduce(0.0) { $0 + $1.estimatedCost }
        let sessionCount = try store.sessionCount(start: rangeStart, end: rangeEnd)
        let allProjects = try store.tokensByProject(start: rangeStart, end: rangeEnd)
        let byModelOverall: [UsageStore.ModelRow] = modelTotals.map { model, t in
            UsageStore.ModelRow(
                model: model,
                totalTokens: t.total,
                inputTokens: t.input,
                outputTokens: t.output,
                cacheCreateTokens: t.cacheCreate,
                cacheReadTokens: t.cacheRead
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        return ExportData(
            start: start, end: end,
            totalTokens: totalTokens,
            estimatedCost: totalCost,
            sessionCount: sessionCount,
            projectCount: allProjects.count,
            byModelOverall: byModelOverall,
            months: buckets,
            csvRows: csvRows
        )
    }

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
    /// since last fetch, and not already in flight. The 60s throttle
    /// applies to attempts, not just successes, so a persistent failure
    /// doesn't hammer the endpoint on every FSEvents tick.
    private func maybeFetchAPILimits(now: Date) {
        guard useAPI, !inFlightAPIFetch else { return }
        if let last = lastAPIFetch, now.timeIntervalSince(last) < 60 { return }
        inFlightAPIFetch = true
        lastAPIFetch = now
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
