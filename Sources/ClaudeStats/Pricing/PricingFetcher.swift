import Foundation

actor PricingFetcher {
    static let liteLLMURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/model_prices_and_context_window_backup.json"
    )!
    /// Cache TTL — re-fetch when cached copy is older than this.
    static let cacheTTL: TimeInterval = 7 * 86400

    private let cacheDir: URL
    private let bundledFallback: Data
    private let fetcher: () async throws -> Data

    init(cacheDir: URL, bundledFallback: Data, fetcher: @escaping () async throws -> Data) {
        self.cacheDir = cacheDir
        self.bundledFallback = bundledFallback
        self.fetcher = fetcher
    }

    static func defaultFetcher() -> @Sendable () async throws -> Data {
        return {
            let (data, _) = try await URLSession.shared.data(from: liteLLMURL)
            return data
        }
    }

    func load() async throws -> PricingTable {
        try ensureCacheDir()
        if let cached = readCacheIfFresh() {
            return try PricingTable.fromJSON(cached)
        }
        do {
            let data = try await fetcher()
            try writeCache(data)
            return try PricingTable.fromJSON(data)
        } catch {
            // Network fail: try stale cache, then bundled fallback.
            if let stale = readCacheIgnoringAge() {
                return try PricingTable.fromJSON(stale)
            }
            return try PricingTable.fromJSON(bundledFallback)
        }
    }

    /// Force a refresh attempt, used by the daily timer. Silent on failure.
    func refresh() async {
        do {
            let data = try await fetcher()
            try writeCache(data)
        } catch {
            // Fail silently — load() will fall back to cache/bundled next time.
        }
    }

    // MARK: - Cache files

    private var cachedPath: URL { cacheDir.appendingPathComponent("pricing.json") }
    private var stampPath: URL { cacheDir.appendingPathComponent("pricing.json.fetched_at") }

    private func ensureCacheDir() throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func readCacheIfFresh() -> Data? {
        guard FileManager.default.fileExists(atPath: cachedPath.path),
              let stamp = try? String(contentsOf: stampPath, encoding: .utf8),
              let ts = TimeInterval(stamp.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        guard Date().timeIntervalSince1970 - ts < Self.cacheTTL else { return nil }
        return try? Data(contentsOf: cachedPath)
    }

    private func readCacheIgnoringAge() -> Data? {
        try? Data(contentsOf: cachedPath)
    }

    private func writeCache(_ data: Data) throws {
        try data.write(to: cachedPath)
        try "\(Date().timeIntervalSince1970)".write(to: stampPath, atomically: true, encoding: .utf8)
    }
}
