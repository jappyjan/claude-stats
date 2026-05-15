import SwiftUI

struct LimitsBar: View {
    let state: LimitsState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if state.windows.isEmpty {
                placeholderRow
            } else {
                progressRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            ForEach(state.windows, id: \.window) { w in
                segment(for: w)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func segment(for w: LimitsWindowProgress) -> some View {
        HStack(spacing: 6) {
            Text(w.window.shortLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: w.percent))
                        .frame(width: max(2, geo.size.width * w.percent))
                }
            }
            .frame(height: 6)
            Text(percentLabel(w.percent))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .help(tooltip(for: w))
    }

    private var placeholderRow: some View {
        Button(action: { openWindow(id: "settings") }) {
            HStack(spacing: 4) {
                Text("Set your plan in Settings →")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func color(for pct: Double) -> Color {
        switch pct {
        case 0..<0.6: return .accentColor
        case 0.6..<0.85: return .orange
        default: return .red
        }
    }

    private func percentLabel(_ pct: Double) -> String {
        "\(Int((pct * 100).rounded()))%"
    }

    private func tooltip(for w: LimitsWindowProgress) -> String {
        let usedStr = format(tokens: w.used)
        let limitStr = format(tokens: w.limit)
        return "\(usedStr) / \(limitStr) tokens"
    }

    private func format(tokens n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
