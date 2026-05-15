import SwiftUI

struct MonthsView: View {
    @Bindable var viewModel: StatsViewModel
    @Binding var breakdown: MonthsBreakdown
    let onSelectMonth: (Int, Int) -> Void  // (year, month)
    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            breakdownPicker
            if breakdown != .total {
                legend
            }
            Divider()
            yearStepper
            Divider()
            headerSummary
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(displayBuckets, id: \.month) { bucket in
                        Button(action: { onSelectMonth(bucket.year, bucket.month) }) {
                            MonthRow(
                                bucket: bucket,
                                mode: breakdown,
                                widthFraction: widthFraction(for: bucket)
                            )
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            Divider()
            footer
        }
        .onAppear { viewModel.refreshYearSummary() }
        .onChange(of: viewModel.monthsYear) { viewModel.refreshYearSummary() }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(
                viewModel: viewModel,
                initialYear: viewModel.monthsYear,
                onDismiss: { showExportSheet = false }
            )
        }
    }

    private var breakdownPicker: some View {
        HStack(spacing: 2) {
            ForEach(MonthsBreakdown.allCases) { mode in
                Button(action: { breakdown = mode }) {
                    Text(mode.label)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(breakdown == mode ? Color.gray.opacity(0.4) : Color.clear)
                        .foregroundStyle(breakdown == mode ? Color.primary : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    @ViewBuilder
    private var legend: some View {
        switch breakdown {
        case .total:
            EmptyView()
        case .type:
            HStack(spacing: 12) {
                legendChip(color: .blue, label: "input")
                legendChip(color: .green, label: "output")
                legendChip(color: .orange, label: "cache-create")
                legendChip(color: .purple, label: "cache-read")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 6)
        case .model:
            HStack(spacing: 12) {
                ForEach(legendModels, id: \.self) { m in
                    legendChip(color: MonthRow.color(forModel: m), label: shortModelLabel(m))
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 6)
        }
    }

    private func legendChip(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var legendModels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for bucket in viewModel.yearSummary.months {
            for row in bucket.byModel where !seen.contains(row.model) {
                seen.insert(row.model)
                ordered.append(row.model)
            }
        }
        return ordered
    }

    private func shortModelLabel(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        return String(model.prefix(8))
    }

    private var yearStepper: some View {
        HStack(spacing: 12) {
            Button(action: stepBack) {
                Image(systemName: "chevron.left")
                    .foregroundStyle(canStepBack ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canStepBack)
            Text("\(viewModel.monthsYear, format: .number.grouping(.never))")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 48)
            Button(action: stepForward) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(canStepForward ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canStepForward)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var headerSummary: some View {
        let visible = displayBuckets
        let yearTotal = visible.reduce(0) { $0 + $1.totalTokens }
        let yearCost = visible.reduce(0.0) { $0 + $1.estimatedCost }
        return HStack {
            Text("\(viewModel.monthsYear, format: .number.grouping(.never))")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            Text("·").foregroundStyle(.secondary)
            Text("\(formatTokens(yearTotal)) tokens")
                .font(.system(size: 12)).monospacedDigit()
            Text("·").foregroundStyle(.secondary)
            Text("$\(String(format: "%.2f", yearCost))")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Text("\(viewModel.yearSummary.monthsWithData) month\(viewModel.yearSummary.monthsWithData == 1 ? "" : "s") with data")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export…") { showExportSheet = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var displayBuckets: [StatsViewModel.MonthBucket] {
        let now = Date()
        let cal = Calendar.current
        let currentYear = cal.component(.year, from: now)
        let currentMonth = cal.component(.month, from: now)
        let filtered: [StatsViewModel.MonthBucket]
        if viewModel.monthsYear == currentYear {
            filtered = viewModel.yearSummary.months.filter { $0.month <= currentMonth }
        } else {
            filtered = viewModel.yearSummary.months
        }
        return filtered.reversed()
    }

    private func widthFraction(for bucket: StatsViewModel.MonthBucket) -> Double {
        let maxTokens = viewModel.yearSummary.months.map(\.totalTokens).max() ?? 0
        guard maxTokens > 0 else { return 0 }
        return Double(bucket.totalTokens) / Double(maxTokens)
    }

    private var canStepBack: Bool {
        guard let earliest = viewModel.yearSummary.earliestYearWithData else { return false }
        return viewModel.monthsYear > earliest
    }

    private var canStepForward: Bool {
        let currentYear = Calendar.current.component(.year, from: Date())
        return viewModel.monthsYear < currentYear
    }

    private func stepBack() { viewModel.monthsYear -= 1 }
    private func stepForward() { viewModel.monthsYear += 1 }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
