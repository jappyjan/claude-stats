import SwiftUI
import Charts
import PDFKit
import AppKit

/// Renders `ExportData` to a multi-page PDF.
/// - Page 1: range header, range totals, monthly bar chart, two donut charts.
/// - Pages 2+: one page per month with non-zero data, mirroring the in-app
///   month drill-in (totals + by-model + top projects).
@MainActor
struct PDFExporter {
    /// US Letter at 72dpi. Adequate for printable reports.
    static let pageSize = CGSize(width: 612, height: 792)

    static func render(_ data: ExportData) -> Data {
        let document = PDFDocument()

        if let summary = renderImage(SummaryPage(data: data)) {
            if let page = PDFPage(image: summary) {
                document.insert(page, at: document.pageCount)
            }
        }

        for bucket in data.months where bucket.totalTokens > 0 {
            if let img = renderImage(MonthPage(bucket: bucket)) {
                if let page = PDFPage(image: img) {
                    document.insert(page, at: document.pageCount)
                }
            }
        }

        return document.dataRepresentation() ?? Data()
    }

    private static func renderImage<V: View>(_ view: V) -> NSImage? {
        let renderer = ImageRenderer(content:
            view.frame(width: pageSize.width, height: pageSize.height)
        )
        renderer.scale = 2.0
        return renderer.nsImage
    }
}

// MARK: - Summary page

private struct SummaryPage: View {
    let data: ExportData

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            totals
            monthlyChart
            HStack(alignment: .top, spacing: 24) {
                tokenTypeDonut
                modelDonut
            }
            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ClaudeStats Usage Report")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.black)
            Text("\(formatDate(data.start))  –  \(formatDate(data.end))")
                .font(.system(size: 13))
                .foregroundStyle(Color.gray)
        }
    }

    private var totals: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCard(label: "TOTAL TOKENS", value: formatTokens(data.totalTokens))
            statCard(label: "EST. COST", value: "$\(String(format: "%.2f", data.estimatedCost))")
            statCard(label: "SESSIONS", value: "\(data.sessionCount)")
            statCard(label: "PROJECTS", value: "\(data.projectCount)")
        }
    }

    private func statCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.gray)
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Color.black)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var monthlyChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MONTHLY TOTALS").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.gray)
            Chart {
                ForEach(Array(data.months.enumerated()), id: \.offset) { _, bucket in
                    BarMark(
                        x: .value("Month", monthLabel(year: bucket.year, month: bucket.month)),
                        y: .value("Tokens", bucket.totalTokens)
                    )
                    .foregroundStyle(Color.purple)
                }
            }
            .frame(height: 160)
        }
    }

    private var tokenTypeDonut: some View {
        let totals = aggregatedTypeTotals
        let slices: [(label: String, value: Int, color: Color)] = [
            ("input", totals.input, .blue),
            ("output", totals.output, .green),
            ("cache-create", totals.cacheCreate, .orange),
            ("cache-read", totals.cacheRead, .purple),
        ]
        return VStack(alignment: .leading, spacing: 4) {
            Text("BY TOKEN TYPE").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.gray)
            Chart {
                ForEach(slices, id: \.label) { s in
                    SectorMark(
                        angle: .value("Tokens", s.value),
                        innerRadius: .ratio(0.55),
                        angularInset: 1
                    )
                    .foregroundStyle(s.color)
                }
            }
            .frame(width: 220, height: 200)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(slices, id: \.label) { s in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 8, height: 8)
                        Text(s.label).font(.system(size: 10)).foregroundStyle(Color.black)
                    }
                }
            }
        }
    }

    private var modelDonut: some View {
        let entries = data.byModelOverall.prefix(6)
        return VStack(alignment: .leading, spacing: 4) {
            Text("BY MODEL").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.gray)
            Chart {
                ForEach(Array(entries), id: \.model) { row in
                    SectorMark(
                        angle: .value("Tokens", row.totalTokens),
                        innerRadius: .ratio(0.55),
                        angularInset: 1
                    )
                    .foregroundStyle(color(forModel: row.model))
                }
            }
            .frame(width: 220, height: 200)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(entries), id: \.model) { row in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(forModel: row.model))
                            .frame(width: 8, height: 8)
                        Text(shortModelLabel(row.model)).font(.system(size: 10)).foregroundStyle(Color.black)
                    }
                }
            }
        }
    }

    private var aggregatedTypeTotals: (input: Int, output: Int, cacheCreate: Int, cacheRead: Int) {
        var input = 0, output = 0, cc = 0, cr = 0
        for m in data.byModelOverall {
            input += m.inputTokens
            output += m.outputTokens
            cc += m.cacheCreateTokens
            cr += m.cacheReadTokens
        }
        return (input, output, cc, cr)
    }

    private func color(forModel model: String) -> Color {
        let lower = model.lowercased()
        if lower.contains("opus") { return .purple }
        if lower.contains("sonnet") { return .blue }
        if lower.contains("haiku") { return .green }
        return .gray
    }

    private func shortModelLabel(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        return String(model.prefix(12))
    }

    private static let monthBarFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f
    }()

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func monthLabel(year: Int, month: Int) -> String {
        var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = 1
        return Calendar.current.date(from: comps).map { Self.monthBarFormatter.string(from: $0) } ?? "\(month)"
    }

    private func formatDate(_ d: Date) -> String {
        Self.rangeFormatter.string(from: d)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}

// MARK: - Per-month page

private struct MonthPage: View {
    let bucket: ExportData.MonthBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.black)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statCard(label: "TOKENS", value: formatTokens(bucket.totalTokens),
                         sub: "\(bucket.sessionCount) session\(bucket.sessionCount == 1 ? "" : "s")")
                statCard(label: "EST. COST", value: "$\(String(format: "%.2f", bucket.estimatedCost))",
                         sub: "\(bucket.projectCount) project\(bucket.projectCount == 1 ? "" : "s")")
            }

            section(title: "BY MODEL") {
                VStack(spacing: 0) {
                    ForEach(bucket.byModel, id: \.model) { row in
                        HStack {
                            Text(shortModelLabel(row.model))
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.vertical, 1).padding(.horizontal, 5)
                                .background(color(forModel: row.model))
                                .foregroundStyle(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Spacer()
                            Text(formatTokens(row.totalTokens))
                                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.black)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }

            section(title: "TOP PROJECTS") {
                VStack(spacing: 0) {
                    ForEach(bucket.topProjects, id: \.projectKey) { row in
                        HStack {
                            Text(ProjectName.display(for: row.projectKey))
                                .font(.system(size: 12)).foregroundStyle(Color.black)
                            Spacer()
                            Text(formatTokens(row.totalTokens))
                                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.black)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    private func statCard(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.gray)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(Color.black)
            Text(sub).font(.system(size: 11)).foregroundStyle(Color.gray)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.gray)
            content()
        }
    }

    private var title: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        var comps = DateComponents(); comps.year = bucket.year; comps.month = bucket.month; comps.day = 1
        return Calendar.current.date(from: comps).map { fmt.string(from: $0) } ?? "\(bucket.month)/\(bucket.year)"
    }

    private func color(forModel model: String) -> Color {
        let lower = model.lowercased()
        if lower.contains("opus") { return .purple }
        if lower.contains("sonnet") { return .blue }
        if lower.contains("haiku") { return .green }
        return .gray
    }

    private func shortModelLabel(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "OPUS" }
        if lower.contains("sonnet") { return "SONNET" }
        if lower.contains("haiku") { return "HAIKU" }
        return String(model.prefix(8)).uppercased()
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
