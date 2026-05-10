import SwiftUI

struct TrendChart: View {
    let dailyTokens: [Date: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST 14 DAYS").font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days(), id: \.self) { day in
                    let v = dailyTokens[day] ?? 0
                    let h = max(2, CGFloat(v) / CGFloat(maxValue) * 56)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Calendar.current.isDateInToday(day) ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.purple.opacity(0.85)))
                        .frame(height: h)
                        .frame(maxWidth: .infinity)
                }
            }.frame(height: 56)
            HStack {
                Text("14d ago").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("today").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func days() -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
    }

    private var maxValue: Int {
        max(1, dailyTokens.values.max() ?? 1)
    }
}
