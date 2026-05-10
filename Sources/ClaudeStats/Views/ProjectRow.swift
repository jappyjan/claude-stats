import SwiftUI

struct ProjectRow: View {
    let row: UsageStore.ProjectRow
    let cost: Double?
    let widthFraction: Double // 0.0–1.0

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ProjectName.display(for: row.projectKey))
                    .font(.system(size: 13, weight: .medium))
                GeometryReader { geo in
                    LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * widthFraction, height: 3)
                        .clipShape(Capsule())
                }
                .frame(height: 3)
            }
            Spacer()
            Text(formatTokens(row.totalTokens))
                .font(.system(size: 12)).monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            Text(cost.map { "$\(String(format: "%.2f", $0))" } ?? "—")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
