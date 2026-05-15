import XCTest
@testable import ClaudeStats

final class JSONLParserTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        let url = Bundle.module.url(forResource: "sample", withExtension: "jsonl", subdirectory: "Fixtures")
        return try XCTUnwrap(url)
    }

    func testParsesAssistantMessagesWithUsage() throws {
        let parser = JSONLParser()
        let result = try parser.parse(fileURL: fixtureURL(), fromOffset: 0)
        // Two assistant messages with usage; user/progress/queue/malformed all skipped.
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].model, "claude-opus-4-7")
        XCTAssertEqual(result.entries[0].inputTokens, 100)
        XCTAssertEqual(result.entries[0].outputTokens, 200)
        XCTAssertEqual(result.entries[0].cacheCreationTokens, 50)
        XCTAssertEqual(result.entries[0].cacheReadTokens, 300)
        XCTAssertEqual(result.entries[0].sessionId, "abc")
        XCTAssertEqual(result.entries[0].projectPath, "/Users/jappy/code/jappyjan/claude-stats")
        XCTAssertEqual(result.entries[1].model, "claude-sonnet-4-6")
    }

    func testReturnsEndOffsetEqualToFileSize() throws {
        let url = try fixtureURL()
        let parser = JSONLParser()
        let result = try parser.parse(fileURL: url, fromOffset: 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertEqual(result.endOffset, Int64(size))
    }

    func testTruncatedTrailingLineLeavesOffsetAtLastNewline() throws {
        // Build a temp file: one valid line + one half-written line (no trailing newline).
        let valid = #"{"type":"assistant","message":{"model":"m","role":"assistant","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-05-10T10:00:00.000Z","sessionId":"s","cwd":"/p"}"#
        let truncated = #"{"type":"assistant","message":{"model":"m","ro"#
        let content = valid + "\n" + truncated
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trunc-\(UUID().uuidString).jsonl")
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parser = JSONLParser()
        let result = try parser.parse(fileURL: tmp, fromOffset: 0)
        XCTAssertEqual(result.entries.count, 1)
        // Offset should be at end of the first complete line (after its newline).
        let validBytes = Int64((valid + "\n").utf8.count)
        XCTAssertEqual(result.endOffset, validBytes)
    }

    func testIncrementalParseFromOffset() throws {
        let url = try fixtureURL()
        let parser = JSONLParser()
        let firstPass = try parser.parse(fileURL: url, fromOffset: 0)
        // Second pass from the end should yield zero new entries.
        let secondPass = try parser.parse(fileURL: url, fromOffset: firstPass.endOffset)
        XCTAssertEqual(secondPass.entries.count, 0)
    }

    func testExtractsMessageIdAndRequestIdForDedup() throws {
        // Claude Code writes the same assistant event to multiple files
        // (e.g. subagent forks, resumed sessions). ccusage dedupes by
        // (message.id, requestId); we need the same keys on the entry.
        let withIds = #"{"type":"assistant","requestId":"req_abc","message":{"id":"msg_xyz","model":"m","role":"assistant","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-05-10T10:00:00.000Z","sessionId":"s","cwd":"/p"}"#
        let withoutIds = #"{"type":"assistant","message":{"model":"m","role":"assistant","usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-05-10T10:00:01.000Z","sessionId":"s","cwd":"/p"}"#
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ids-\(UUID().uuidString).jsonl")
        try (withIds + "\n" + withoutIds + "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try JSONLParser().parse(fileURL: tmp, fromOffset: 0)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].messageId, "msg_xyz")
        XCTAssertEqual(result.entries[0].requestId, "req_abc")
        XCTAssertNil(result.entries[1].messageId)
        XCTAssertNil(result.entries[1].requestId)
    }
}
