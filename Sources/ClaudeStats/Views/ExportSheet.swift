import SwiftUI
import AppKit

struct ExportSheet: View {
    let viewModel: StatsViewModel
    let initialYear: Int
    let onDismiss: () -> Void

    @State private var start: Date
    @State private var end: Date
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(viewModel: StatsViewModel, initialYear: Int, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.initialYear = initialYear
        self.onDismiss = onDismiss
        let cal = Calendar.current
        let yearStart = cal.date(from: DateComponents(year: initialYear, month: 1, day: 1)) ?? Date()
        _start = State(initialValue: yearStart)
        _end = State(initialValue: cal.startOfDay(for: Date()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export usage data")
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 12) {
                Text("Start").font(.system(size: 12)).frame(width: 44, alignment: .leading)
                DatePicker("", selection: $start, displayedComponents: .date)
                    .labelsHidden()
            }
            HStack(spacing: 12) {
                Text("End").font(.system(size: 12)).frame(width: 44, alignment: .leading)
                DatePicker("", selection: $end, displayedComponents: .date)
                    .labelsHidden()
            }

            Divider()

            Text("PRESETS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("This year") { applyThisYear() }.buttonStyle(.bordered)
                Button("Last 3 months") { applyLast3Months() }.buttonStyle(.bordered)
                Button("All time") { applyAllTime() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.earliestEventDate() == nil)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                Button("Export…") { Task { await exportTapped() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(start > end || isExporting)
            }
        }
        .padding(20)
        .frame(width: 380)
        .overlay {
            if isExporting {
                Color.black.opacity(0.05)
                ProgressView()
            }
        }
    }

    private func applyThisYear() {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        end = cal.startOfDay(for: now)
    }

    private func applyLast3Months() {
        let cal = Calendar.current
        let now = Date()
        end = cal.startOfDay(for: now)
        start = cal.date(byAdding: .day, value: -90, to: end) ?? end
    }

    private func applyAllTime() {
        guard let earliest = viewModel.earliestEventDate() else { return }
        let cal = Calendar.current
        start = cal.startOfDay(for: earliest)
        end = cal.startOfDay(for: Date())
    }

    private func exportTapped() async {
        guard let folder = pickFolder() else { return }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let cal = Calendar.current
            // Half-open: [start-of-day(start), start-of-day(end + 1 day))
            let rangeStart = cal.startOfDay(for: start)
            let rangeEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end)) ?? end
            let data = try await viewModel.buildExportData(start: rangeStart, end: rangeEnd)
            let basename = filenameBase(start: start, end: end)
            let csvURL = folder.appendingPathComponent("\(basename).csv")
            let pdfURL = folder.appendingPathComponent("\(basename).pdf")
            let csvString = CSVExporter.csv(rows: data.csvRows)
            try csvString.write(to: csvURL, atomically: true, encoding: .utf8)
            let pdfData = PDFExporter.render(data)
            try pdfData.write(to: pdfURL)
            onDismiss()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func filenameBase(start: Date, end: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "claude-stats_\(fmt.string(from: start))_to_\(fmt.string(from: end))"
    }
}
