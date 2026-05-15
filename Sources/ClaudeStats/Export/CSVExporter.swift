import Foundation

/// Pure CSV string generator for export. RFC 4180-compatible quoting.
struct CSVExporter {
    static func csv(rows: [ExportData.CSVRow]) -> String {
        var out = "month,project,model,input_tokens,output_tokens,cache_create_tokens,cache_read_tokens,total_tokens,estimated_cost\n"
        for r in rows {
            let month = String(format: "%04d-%02d", r.year, r.month)
            let cost = String(format: "%.2f", r.estimatedCost)
            let cells: [String] = [
                month,
                quoted(r.projectKey),
                quoted(r.model),
                "\(r.inputTokens)",
                "\(r.outputTokens)",
                "\(r.cacheCreateTokens)",
                "\(r.cacheReadTokens)",
                "\(r.totalTokens)",
                cost
            ]
            out += cells.joined(separator: ",")
            out += "\n"
        }
        return out
    }

    /// RFC 4180: quote if value contains `,`, `"`, CR, or LF; double up embedded `"`.
    private static func quoted(_ value: String) -> String {
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        if !needsQuoting { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
