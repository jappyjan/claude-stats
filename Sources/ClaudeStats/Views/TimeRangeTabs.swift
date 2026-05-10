import SwiftUI

struct TimeRangeTabs: View {
    @Binding var selection: TimeRange
    var body: some View {
        HStack {
            ForEach(TimeRange.allCases) { r in
                Button(r.label) { selection = r }
                    .buttonStyle(.bordered)
                    .tint(selection == r ? .accentColor : .secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}
