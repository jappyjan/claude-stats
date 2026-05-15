import Foundation

/// Everything the export renderers need. Built by
/// `StatsViewModel.buildExportData(start:end:)` and consumed by
/// `CSVExporter` and `PDFExporter`.
struct ExportData: Equatable {
    struct MonthBucket: Equatable {
        let year: Int
        let month: Int                          // 1...12
        let totalTokens: Int
        let estimatedCost: Double
        let sessionCount: Int
        let projectCount: Int
        let byModel: [UsageStore.ModelRow]      // ordered desc by total tokens
        let topProjects: [UsageStore.ProjectRow]   // up to 5
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
    let byModelOverall: [UsageStore.ModelRow]
    let months: [MonthBucket]                    // chronological (oldest first)
    let csvRows: [CSVRow]                        // (year asc, month asc, project, model)
}
