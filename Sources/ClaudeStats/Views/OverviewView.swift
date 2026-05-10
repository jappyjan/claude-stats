import SwiftUI

struct OverviewView: View {
    let overview: StatsViewModel.Overview
    let range: TimeRange
    var body: some View {
        VStack(alignment: .leading) {
            Text("Overview placeholder").foregroundStyle(.secondary)
            Text("\(overview.totalTokens) tokens, \(overview.sessionCount) sessions")
        }
        .padding(14)
    }
}
