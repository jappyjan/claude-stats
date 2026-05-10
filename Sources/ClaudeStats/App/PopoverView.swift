import SwiftUI

struct PopoverView: View {
    @Bindable var viewModel: StatsViewModel
    @State private var section: Section = .overview
    @State private var drillProjectKey: String? = nil
    @State private var drillDetail: StatsViewModel.ProjectDetail? = nil

    enum Section: String, CaseIterable { case overview, projects }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            if drillProjectKey == nil {
                sectionTabs
                TimeRangeTabs(selection: $viewModel.timeRange)
                    .onChange(of: viewModel.timeRange) { Task { await viewModel.refresh() } }
                Divider()
                Group {
                    switch section {
                    case .overview: OverviewView(overview: viewModel.overview, range: viewModel.timeRange)
                    case .projects:
                        ProjectsView(
                            rows: viewModel.projectRows,
                            costs: [:],  // Task 14 replaces with viewModel.projectCosts
                            onSelect: { key in
                                drillProjectKey = key
                                Task { drillDetail = await viewModel.projectDetail(for: key) }
                            }
                        )
                    }
                }
            } else if let detail = drillDetail {
                ProjectDetailView(detail: detail, range: viewModel.timeRange) {
                    drillProjectKey = nil; drillDetail = nil
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
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
