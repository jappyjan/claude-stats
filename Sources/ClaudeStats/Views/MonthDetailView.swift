import SwiftUI

struct MonthDetailView: View {
    let detail: StatsViewModel.MonthDetail
    let mode: MonthsBreakdown
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Months").font(.system(size: 12))
                    }
                    .foregroundStyle(Color.accentColor)
                }.buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    headerStatCards
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

                    Text("TOP PROJECTS")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(detail.topProjects, id: \.projectKey) { row in
                            HStack {
                                Text(ProjectName.display(for: row.projectKey))
                                    .font(.system(size: 12))
                                Spacer()
                                Text(formatTokens(row.totalTokens))
                                    .font(.system(size: 12)).monospacedDigit()
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

    @ViewBuilder
    private var headerStatCards: some View {
        switch mode {
        case .total, .model:
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatCard(
                    label: "Tokens",
                    value: formatTokens(detail.totalTokens),
                    sub: "\(detail.sessionCount) session\(detail.sessionCount == 1 ? "" : "s")"
                )
                StatCard(
                    label: "Est. cost",
                    value: "$\(String(format: "%.2f", detail.estimatedCost))",
                    sub: "\(detail.projectCount) project\(detail.projectCount == 1 ? "" : "s")"
                )
            }
        case .type:
            let totals = typeTotals
            VStack(spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatCard(label: "Input", value: formatTokens(totals.input), sub: "")
                    StatCard(label: "Output", value: formatTokens(totals.output), sub: "")
                    StatCard(label: "Cache-create", value: formatTokens(totals.cacheCreate), sub: "")
                    StatCard(label: "Cache-read", value: formatTokens(totals.cacheRead), sub: "")
                }
                StatCard(
                    label: "Est. cost",
                    value: "$\(String(format: "%.2f", detail.estimatedCost))",
                    sub: "\(detail.sessionCount) session\(detail.sessionCount == 1 ? "" : "s") · \(detail.projectCount) project\(detail.projectCount == 1 ? "" : "s")"
                )
            }
        }
    }

    private var typeTotals: (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        var input = 0, output = 0, cc = 0, cr = 0
        for m in detail.byModel {
            input += m.inputTokens
            output += m.outputTokens
            cc += m.cacheCreateTokens
            cr += m.cacheReadTokens
        }
        return (input, output, cc, cr)
    }

    private var title: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        var comps = DateComponents()
        comps.year = detail.year
        comps.month = detail.month
        comps.day = 1
        if let date = Calendar.current.date(from: comps) {
            return fmt.string(from: date)
        }
        return "\(detail.month)/\(detail.year)"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
