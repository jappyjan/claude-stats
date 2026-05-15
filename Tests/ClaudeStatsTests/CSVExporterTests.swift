import XCTest
@testable import ClaudeStats

final class CSVExporterTests: XCTestCase {
    func testCSVHeaderAndSingleRow() {
        let rows = [
            ExportData.CSVRow(
                year: 2026, month: 1,
                projectKey: "/p", model: "claude-opus-4-7",
                inputTokens: 100, outputTokens: 50,
                cacheCreateTokens: 10, cacheReadTokens: 5,
                totalTokens: 165, estimatedCost: 1.23
            )
        ]
        let csv = CSVExporter.csv(rows: rows)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "month,project,model,input_tokens,output_tokens,cache_create_tokens,cache_read_tokens,total_tokens,estimated_cost")
        XCTAssertEqual(lines[1], "2026-01,/p,claude-opus-4-7,100,50,10,5,165,1.23")
    }

    func testCSVQuotesProjectPathContainingComma() {
        let rows = [
            ExportData.CSVRow(
                year: 2026, month: 5,
                projectKey: "/path/with,comma", model: "m",
                inputTokens: 1, outputTokens: 0,
                cacheCreateTokens: 0, cacheReadTokens: 0,
                totalTokens: 1, estimatedCost: 0
            )
        ]
        let csv = CSVExporter.csv(rows: rows)
        XCTAssertTrue(csv.contains("\"/path/with,comma\""))
    }

    func testCSVDoublesEmbeddedQuotes() {
        let rows = [
            ExportData.CSVRow(
                year: 2026, month: 5,
                projectKey: "/has\"quote", model: "m",
                inputTokens: 1, outputTokens: 0,
                cacheCreateTokens: 0, cacheReadTokens: 0,
                totalTokens: 1, estimatedCost: 0
            )
        ]
        let csv = CSVExporter.csv(rows: rows)
        // Expected: "/has""quote" with surrounding quotes.
        XCTAssertTrue(csv.contains("\"/has\"\"quote\""))
    }

    func testCSVEmptyRowsYieldsHeaderOnly() {
        let csv = CSVExporter.csv(rows: [])
        XCTAssertEqual(csv, "month,project,model,input_tokens,output_tokens,cache_create_tokens,cache_read_tokens,total_tokens,estimated_cost\n")
    }
}
