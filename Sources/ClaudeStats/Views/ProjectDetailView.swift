import SwiftUI

struct ProjectDetailView: View {
    let detail: StatsViewModel.ProjectDetail
    let range: TimeRange
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("Projects").font(.system(size: 12))
                    }
                    .foregroundStyle(Color.accentColor)
                }.buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(
                Text(ProjectName.display(for: detail.projectKey))
                    .font(.system(size: 13, weight: .semibold))
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        StatCard(
                            label: "Tokens",
                            value: formatTokens(detail.totals.totalTokens),
                            sub: "\(Int((detail.percentOfRange * 100).rounded()))% of range"
                        )
                        StatCard(
                            label: "Est. cost",
                            value: detail.cost.map { "$\(String(format: "%.2f", $0))" } ?? "—",
                            sub: "\(detail.totals.sessionCount) session\(detail.totals.sessionCount == 1 ? "" : "s")"
                        )
                    }
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

                    Text("RECENT SESSIONS")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(detail.recentSessions, id: \.sessionId) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(String(s.sessionId.prefix(8)) + "…")
                                        .font(.system(.caption, design: .monospaced))
                                    Text(relativeWhen(s))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatTokens(s.totalTokens))
                                    .font(.system(size: 11)).monospacedDigit()
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

    private func relativeWhen(_ s: UsageStore.SessionRow) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: s.lastTimestamp, relativeTo: Date())
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
