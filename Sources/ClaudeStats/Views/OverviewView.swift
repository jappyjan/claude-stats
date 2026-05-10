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
        if range == .all, let first = overview.firstEventDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "since \(formatter.string(from: first))"
        }
        return ""
    }
    private var costSub: String {
        if let prior = overview.priorTotalCost, prior > 0 {
            let delta = (overview.totalCost - prior) / prior * 100
            let sign = delta >= 0 ? "+" : ""
            return "\(sign)\(Int(delta.rounded()))% vs prior period"
        }
        if range == .all, let first = overview.firstEventDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "since \(formatter.string(from: first))"
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
