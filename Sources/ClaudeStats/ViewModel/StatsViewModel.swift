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
    var projectCosts: [String: Double] = [:]

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
                priorTotalCost: priorCost
            )

            // Atomic assignment of all published state.
            todayTokens = nextTodayTokens
            projectRows = nextProjectRows
            projectCosts = nextProjectCosts
            overview = nextOverview
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
