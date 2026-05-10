import SwiftUI

struct ProjectsView: View {
    let rows: [UsageStore.ProjectRow]
    let costs: [String: Double]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows, id: \.projectKey) { row in
                    Button(action: { onSelect(row.projectKey) }) {
                        ProjectRow(
                            row: row,
                            cost: costs[row.projectKey],
                            widthFraction: maxTokens == 0 ? 0 : Double(row.totalTokens) / Double(maxTokens)
                        )
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var maxTokens: Int { rows.first?.totalTokens ?? 0 }
}
