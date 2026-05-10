import SwiftUI

struct ModelChip: View {
    let model: String

    var body: some View {
        Text(shortName)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .padding(.vertical, 1).padding(.horizontal, 5)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var shortName: String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "OPUS" }
        if lower.contains("sonnet") { return "SONNET" }
        if lower.contains("haiku") { return "HAIKU" }
        return String(model.prefix(8)).uppercased()
    }

    private var color: Color {
        let lower = model.lowercased()
        if lower.contains("opus") { return Color.purple }
        if lower.contains("sonnet") { return Color.blue }
        if lower.contains("haiku") { return Color.green }
        return Color.gray
    }
}
