import XCTest
@testable import ClaudeStats

/// Stresses UsageStore from many threads at once to catch SQLite
/// connection races. Without proper serialization this used to crash
/// in `sqlite3DbMallocRawNNTyped`.
final class UsageStoreConcurrencyTests: XCTestCase {
    func testConcurrentReadsAndWritesDoNotCrash() throws {
        let store = try UsageStore(path: ":memory:")
        let exp = expectation(description: "concurrent ops complete")
        let opCount = 200
        exp.expectedFulfillmentCount = opCount

        for i in 0..<opCount {
            DispatchQueue.global(qos: .userInitiated).async {
                if i % 3 == 0 {
                    let e = UsageEntry(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                        sessionId: "s\(i)", projectPath: "/p", model: "m",
                        inputTokens: 1, outputTokens: 1,
                        cacheCreationTokens: 0, cacheReadTokens: 0
                    )
                    _ = try? store.insert([e])
                } else if i % 3 == 1 {
                    _ = try? store.totalTokens(
                        start: Date(timeIntervalSince1970: 0),
                        end: Date(timeIntervalSince1970: 1_000_000)
                    )
                } else {
                    _ = try? store.fileState(path: "/some/path\(i % 5).jsonl")
                }
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 10.0)
    }
}
