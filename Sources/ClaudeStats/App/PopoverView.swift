import SwiftUI
import AppKit

struct PopoverView: View {
    @Bindable var viewModel: StatsViewModel
    let container: AppContainer
    @State private var section: Section = .overview
    @State private var drillProjectKey: String? = nil
    @State private var drillDetail: StatsViewModel.ProjectDetail? = nil
    @State private var drillMonth: MonthSelection? = nil
    @State private var drillMonthDetail: StatsViewModel.MonthDetail? = nil
    @State private var showExport: Bool = false
    @AppStorage("monthsBreakdown") private var monthsBreakdown: MonthsBreakdown = .total
    @Environment(\.openWindow) private var openWindow

    enum Section: String, CaseIterable { case overview, projects, months }

    private struct MonthSelection: Equatable {
        let year: Int
        let month: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            LimitsBar(state: viewModel.limits)
            if drillProjectKey == nil && drillMonth == nil && !showExport {
                sectionTabs
                if section != .months {
                    TimeRangeTabs(selection: $viewModel.timeRange)
                        .onChange(of: viewModel.timeRange) { Task { await viewModel.refresh() } }
                }
                Divider()
                Group {
                    switch section {
                    case .overview: OverviewView(overview: viewModel.overview, range: viewModel.timeRange)
                    case .projects:
                        ProjectsView(
                            rows: viewModel.projectRows,
                            costs: viewModel.projectCosts,
                            onSelect: { key in
                                drillProjectKey = key
                                Task { drillDetail = await viewModel.projectDetail(for: key) }
                            }
                        )
                    case .months:
                        MonthsView(
                            viewModel: viewModel,
                            breakdown: $monthsBreakdown,
                            onSelectMonth: { year, month in
                                drillMonth = MonthSelection(year: year, month: month)
                                Task { drillMonthDetail = await viewModel.monthDetail(year: year, month: month) }
                            },
                            onExportTapped: { showExport = true }
                        )
                    }
                }
            } else if showExport {
                ExportSheet(
                    viewModel: viewModel,
                    initialYear: viewModel.monthsYear,
                    onDismiss: { showExport = false }
                )
            } else if let detail = drillDetail {
                ProjectDetailView(detail: detail, range: viewModel.timeRange) {
                    drillProjectKey = nil; drillDetail = nil
                }
            } else if let detail = drillMonthDetail {
                MonthDetailView(detail: detail, mode: monthsBreakdown) {
                    drillMonth = nil; drillMonthDetail = nil
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }

            Divider()
            HStack {
                Text("\(viewModel.overview.projectCount) project\(viewModel.overview.projectCount == 1 ? "" : "s") · \(viewModel.overview.sessionCount) session\(viewModel.overview.sessionCount == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: { openWindow(id: "settings") }) {
                    Image(systemName: "gearshape").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit ClaudeStats")
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .padding(.vertical, 4)
    }

    private var statusRow: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(viewModel.isActive ? .green : .secondary).frame(width: 7, height: 7)
                Text(viewModel.isActive ? "Active" : "Idle").font(.caption)
            }
            Spacer()
            Text("\(formatTokens(viewModel.todayTokens)) today · ~$\(String(format: "%.2f", viewModel.overview.totalCost))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    private var sectionTabs: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases, id: \.self) { s in
                Button(action: { section = s }) {
                    Text(s.rawValue.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        .foregroundStyle(section == s ? Color.primary : Color.secondary)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(section == s ? Color.accentColor : Color.clear).frame(height: 2)
                        }
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
