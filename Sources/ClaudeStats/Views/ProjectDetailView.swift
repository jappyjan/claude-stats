import SwiftUI

struct ProjectDetailView: View {
    let detail: StatsViewModel.ProjectDetail
    let range: TimeRange
    var onBack: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            Button("‹ Back", action: onBack)
            Text(detail.projectKey).bold()
            Text("\(detail.totals.totalTokens) tokens")
        }
        .padding(14)
    }
}
