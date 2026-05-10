import XCTest
@testable import ClaudeStats

final class PricingFetcherTests: XCTestCase {
    private var cacheDir: URL!
    override func setUpWithError() throws {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func testReturnsBundledFallbackWhenNoCacheAndFetchFails() async throws {
        let fallback = #"{"claude-test":{"input_cost_per_token":1,"output_cost_per_token":2}}"#
        let fetcher = PricingFetcher(
            cacheDir: cacheDir,
            bundledFallback: Data(fallback.utf8),
            fetcher: { throw URLError(.notConnectedToInternet) }
        )
        let table = try await fetcher.load()
        XCTAssertNotNil(table.rate(for: "claude-test"))
    }

    func testWritesAndReadsCacheOnSuccess() async throws {
        let payload = #"{"claude-net":{"input_cost_per_token":3,"output_cost_per_token":4}}"#
        let fetcher = PricingFetcher(
            cacheDir: cacheDir,
            bundledFallback: Data(),
            fetcher: { Data(payload.utf8) }
        )
        let table = try await fetcher.load()
        XCTAssertEqual(table.rate(for: "claude-net")?.input, 3)
        // File is on disk.
        let cached = cacheDir.appendingPathComponent("pricing.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }

    func testUsesCachedDataWhenFreshAndFetcherFails() async throws {
        // Pre-seed cache.
        let payload = #"{"claude-cached":{"input_cost_per_token":5,"output_cost_per_token":6}}"#
        try Data(payload.utf8).write(to: cacheDir.appendingPathComponent("pricing.json"))
        try "\(Date().timeIntervalSince1970)".write(
            to: cacheDir.appendingPathComponent("pricing.json.fetched_at"),
            atomically: true, encoding: .utf8
        )
        let fetcher = PricingFetcher(
            cacheDir: cacheDir,
            bundledFallback: Data(),
            fetcher: { throw URLError(.timedOut) }
        )
        let table = try await fetcher.load()
        XCTAssertNotNil(table.rate(for: "claude-cached"))
    }

    func testRefetchesWhenCacheStale() async throws {
        // Pre-seed STALE cache (8 days old).
        let stale = #"{"claude-stale":{"input_cost_per_token":1,"output_cost_per_token":1}}"#
        try Data(stale.utf8).write(to: cacheDir.appendingPathComponent("pricing.json"))
        let oldTime = Date().timeIntervalSince1970 - (2 * 86400)  // 2 days old
        try "\(oldTime)".write(
            to: cacheDir.appendingPathComponent("pricing.json.fetched_at"),
            atomically: true, encoding: .utf8
        )
        let fresh = #"{"claude-fresh":{"input_cost_per_token":9,"output_cost_per_token":9}}"#
        let fetcher = PricingFetcher(
            cacheDir: cacheDir,
            bundledFallback: Data(),
            fetcher: { Data(fresh.utf8) }
        )
        let table = try await fetcher.load()
        XCTAssertNotNil(table.rate(for: "claude-fresh"))
        XCTAssertNil(table.rate(for: "claude-stale"))
    }
}
