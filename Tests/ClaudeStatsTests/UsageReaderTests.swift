import XCTest
@testable import ClaudeStats

final class UsageReaderTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ relPath: String, _ lines: [String]) throws -> URL {
        let url = tmp.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func validLine(model: String, ts: String) -> String {
        #"{"type":"assistant","message":{"model":"\#(model)","role":"assistant","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s","cwd":"/p"}"#
    }

    private func dedupableLine(model: String, ts: String, msg: String, req: String, tokens: Int = 1) -> String {
        #"{"type":"assistant","requestId":"\#(req)","message":{"id":"\#(msg)","model":"\#(model)","role":"assistant","usage":{"input_tokens":\#(tokens),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s","cwd":"/p"}"#
    }

    func testInitialScanInsertsAllAssistantLines() throws {
        _ = try write("proj-a/sess1.jsonl", [validLine(model: "m1", ts: "2026-05-10T10:00:00.000Z")])
        _ = try write("proj-a/sess1/subagents/agent-x.jsonl", [validLine(model: "m2", ts: "2026-05-10T10:01:00.000Z")])
        let store = try UsageStore(path: ":memory:")
        let reader = UsageReader(rootDir: tmp, store: store)
        try reader.scan()
        XCTAssertEqual(try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)), 4)
    }

    func testIncrementalScanOnlyReadsNewLines() throws {
        let url = try write("proj/sess.jsonl", [validLine(model: "m1", ts: "2026-05-10T10:00:00.000Z")])
        let store = try UsageStore(path: ":memory:")
        let reader = UsageReader(rootDir: tmp, store: store)
        try reader.scan()
        XCTAssertEqual(try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)), 2)

        // Append and bump mtime.
        try (validLine(model: "m1", ts: "2026-05-10T10:05:00.000Z") + "\n").data(using: .utf8)!.append(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        try reader.scan()
        XCTAssertEqual(try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)), 4)
    }

    func testUnchangedFileIsSkipped() throws {
        let url = try write("proj/sess.jsonl", [validLine(model: "m1", ts: "2026-05-10T10:00:00.000Z")])
        let store = try UsageStore(path: ":memory:")
        let reader = UsageReader(rootDir: tmp, store: store)
        try reader.scan()
        let before = try store.fileState(path: url.path)?.lastOffset
        try reader.scan() // no changes — should be a no-op
        let after = try store.fileState(path: url.path)?.lastOffset
        XCTAssertEqual(before, after)
        XCTAssertEqual(try store.totalTokens(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)), 2)
    }

    func testSameAssistantEventInTwoFilesIsCountedOnce() throws {
        // Claude Code writes the same usage event to multiple JSONL files
        // (subagent forks, session resumes). Dedup by (messageId, requestId)
        // happens in UsageStore; verify the end-to-end pipeline honors it.
        let line = dedupableLine(model: "m", ts: "2026-05-10T10:00:00.000Z",
                                 msg: "msg_same", req: "req_same", tokens: 100)
        _ = try write("proj-a/sess1.jsonl", [line])
        _ = try write("proj-a/sess1/subagents/agent-x.jsonl", [line])
        let store = try UsageStore(path: ":memory:")
        let reader = UsageReader(rootDir: tmp, store: store)
        try reader.scan()
        XCTAssertEqual(
            try store.totalTokens(start: Date(timeIntervalSince1970: 0),
                                  end: Date(timeIntervalSince1970: .greatestFiniteMagnitude)),
            100
        )
    }

    func testActiveIfFileMtimeWithinThreshold() throws {
        let url = try write("proj/sess.jsonl", [validLine(model: "m1", ts: "2026-05-10T10:00:00.000Z")])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: url.path)
        let reader = UsageReader(rootDir: tmp, store: try UsageStore(path: ":memory:"))
        XCTAssertTrue(reader.isActive(within: 30))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: url.path)
        XCTAssertFalse(reader.isActive(within: 30))
    }
}

private extension Data {
    func append(to url: URL) throws {
        if let h = try? FileHandle(forWritingTo: url) {
            try h.seekToEnd()
            try h.write(contentsOf: self)
            try h.close()
        } else {
            try self.write(to: url)
        }
    }
}
