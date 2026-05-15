import SwiftUI

struct MonthRow: View {
    let bucket: StatsViewModel.MonthBucket
    let mode: MonthsBreakdown
    let widthFraction: Double // 0.0–1.0

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(monthLabel)
                    .font(.system(size: 13, weight: .medium))
                GeometryReader { geo in
                    let totalBarWidth = max(
                        geo.size.width * widthFraction,
                        bucket.totalTokens == 0 ? 0 : 2
                    )
                    bar(width: totalBarWidth)
                }
                .frame(height: 3)
            }
            Spacer()
            Text(formatTokens(bucket.totalTokens))
                .font(.system(size: 12)).monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            Text("$\(String(format: "%.2f", bucket.estimatedCost))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func bar(width totalWidth: CGFloat) -> some View {
        switch mode {
        case .total:
            LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                .frame(width: totalWidth, height: 3)
                .clipShape(Capsule())
        case .type, .model:
            HStack(spacing: 0) {
                ForEach(segments, id: \.id) { seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: totalWidth * seg.fraction, height: 3)
                }
            }
            .clipShape(Capsule())
        }
    }

    private struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    private var segments: [Segment] {
        guard bucket.totalTokens > 0 else { return [] }
        let total = Double(bucket.totalTokens)
        switch mode {
        case .total:
            return []
        case .type:
            var input = 0, output = 0, cc = 0, cr = 0
            for m in bucket.byModel {
                input += m.inputTokens
                output += m.outputTokens
                cc += m.cacheCreateTokens
                cr += m.cacheReadTokens
            }
            return [
                Segment(id: "input", fraction: Double(input) / total, color: .blue),
                Segment(id: "output", fraction: Double(output) / total, color: .green),
                Segment(id: "cc", fraction: Double(cc) / total, color: .orange),
                Segment(id: "cr", fraction: Double(cr) / total, color: .purple),
            ].filter { $0.fraction > 0 }
        case .model:
            return bucket.byModel.map { row in
                Segment(
                    id: row.model,
                    fraction: Double(row.totalTokens) / total,
                    color: MonthRow.color(forModel: row.model)
                )
            }.filter { $0.fraction > 0 }
        }
    }

    /// Color palette matching `ModelChip` so legend chips and bar segments line up.
    static func color(forModel model: String) -> Color {
        let lower = model.lowercased()
        if lower.contains("opus") { return .purple }
        if lower.contains("sonnet") { return .blue }
        if lower.contains("haiku") { return .green }
        return .gray
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLL"
        return f
    }()

    private var monthLabel: String {
        var comps = DateComponents()
        comps.year = bucket.year
        comps.month = bucket.month
        comps.day = 1
        if let date = Calendar.current.date(from: comps) {
            return MonthRow.monthFormatter.string(from: date)
        }
        return "\(bucket.month)"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
