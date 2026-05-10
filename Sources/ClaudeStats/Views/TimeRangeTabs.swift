import SwiftUI

struct TimeRangeTabs: View {
    @Binding var selection: TimeRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { range in
                Button(action: { selection = range }) {
                    Text(range.label)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selection == range ? Color.gray.opacity(0.4) : Color.clear)
                        .foregroundStyle(selection == range ? Color.primary : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}
