import Foundation

struct UsageWindowCalculator {
    let store: UsageStore

    /// Returns the token total in the window. Sums all four token types
    /// (input, output, cache_create, cache_read) at full weight — both
    /// ccusage and Anthropic's own plan-limit accounting count cache_read
    /// at full weight against the 5h subscription quota.
    func tokens(in window: Window, endingAt now: Date) -> Int {
        let start = now.addingTimeInterval(-window.seconds)
        return (try? store.totalTokens(start: start, end: now)) ?? 0
    }
}
