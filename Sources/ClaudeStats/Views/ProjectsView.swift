import SwiftUI

struct ProjectsView: View {
    let rows: [UsageStore.ProjectRow]
    let costs: [String: Double]
    let onSelect: (String) -> Void
    var body: some View {
        VStack(alignment: .leading) {
            Text("Projects placeholder").foregroundStyle(.secondary)
            ForEach(rows, id: \.projectKey) { row in
                Button(action: { onSelect(row.projectKey) }) {
                    Text("\(row.projectKey): \(row.totalTokens)")
                }.buttonStyle(.plain)
            }
        }
        .padding(14)
    }
}
