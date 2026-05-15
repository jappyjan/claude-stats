import Foundation

struct JSONLParser {
    struct ParseResult {
        let entries: [UsageEntry]
        let endOffset: Int64
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func parse(fileURL: URL, fromOffset offset: Int64) throws -> ParseResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.readToEnd() ?? Data()

        var entries: [UsageEntry] = []
        var consumedBytes: Int64 = 0
        var lineStart = data.startIndex

        for index in data.indices {
            if data[index] == 0x0A { // '\n'
                let lineRange = lineStart..<index
                if let entry = decodeLine(data[lineRange]) {
                    entries.append(entry)
                }
                consumedBytes = Int64(index - data.startIndex + 1)
                lineStart = data.index(after: index)
            }
        }
        // Anything after the last newline is incomplete; leave it for next time.

        return ParseResult(entries: entries, endOffset: offset + consumedBytes)
    }

    private func decodeLine(_ data: Data) -> UsageEntry? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let type = obj["type"] as? String, type == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let timestampStr = obj["timestamp"] as? String,
              let timestamp = Self.isoFormatter.date(from: timestampStr),
              let sessionId = obj["sessionId"] as? String,
              let cwd = obj["cwd"] as? String
        else { return nil }

        return UsageEntry(
            timestamp: timestamp,
            sessionId: sessionId,
            projectPath: cwd,
            model: model,
            inputTokens: (usage["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage["output_tokens"] as? Int) ?? 0,
            cacheCreationTokens: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheReadTokens: (usage["cache_read_input_tokens"] as? Int) ?? 0,
            messageId: message["id"] as? String,
            requestId: obj["requestId"] as? String
        )
    }
}
