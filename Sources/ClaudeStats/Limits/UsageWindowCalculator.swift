import Foundation

struct UsageWindowCalculator {
    let store: UsageStore

    /// Returns the limit-weighted token total in the window. cache_read
    /// is counted at 10% to match Anthropic's API cost ratio, since the
    /// plan-limit accounting most likely uses the same weighting.
    func tokens(in window: Window, endingAt now: Date) -> Int {
        let start = now.addingTimeInterval(-window.seconds)
        return (try? store.limitTokens(start: start, end: now)) ?? 0
    }
}
