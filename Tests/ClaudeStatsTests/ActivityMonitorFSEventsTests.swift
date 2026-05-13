import XCTest
@testable import ClaudeStats

/// Integration: verify that writing a file under the watched directory
/// causes ActivityMonitor.onTick to fire within a few seconds. This is a
/// slow test (uses real FSEvents) and is therefore explicitly tagged.
final class ActivityMonitorFSEventsTests: XCTestCase {

    @MainActor
    func testWritingJsonlFireOnTickQuickly() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let dbPath = tmpRoot.appendingPathComponent("usage.db").path
        let store = try UsageStore(path: dbPath)
        let reader = UsageReader(rootDir: tmpRoot, store: store)

        let monitor = ActivityMonitor(reader: reader, watchPath: tmpRoot.path,
                                       safetyInterval: 600)
        let expectation = expectation(description: "onTick fires")
        var ticks = 0
        monitor.onTick = {
            ticks += 1
            if ticks >= 2 {
                expectation.fulfill()
            }
        }
        monitor.start()
        defer { monitor.stop() }

        // Give FSEvents a moment to start before writing.
        try await Task.sleep(nanoseconds: 300_000_000)
        let sample = """
        {"timestamp":"2026-05-13T10:00:00.000Z","sessionId":"s","cwd":"/p","message":{"model":"m","usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        try sample.write(to: tmpRoot.appendingPathComponent("test.jsonl"),
                         atomically: true, encoding: .utf8)

        await fulfillment(of: [expectation], timeout: 5.0)
    }
}
