import Foundation

struct UsageWindowCalculator {
    let store: UsageStore

    func tokens(in window: Window, endingAt now: Date) -> Int {
        let start = now.addingTimeInterval(-window.seconds)
        return (try? store.totalTokens(start: start, end: now)) ?? 0
    }
}
