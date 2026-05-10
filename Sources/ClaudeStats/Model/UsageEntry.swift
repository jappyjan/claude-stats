import Foundation

struct UsageEntry: Equatable {
    let timestamp: Date
    let sessionId: String
    let projectPath: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}
