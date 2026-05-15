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
    /// `message.id` from the assistant entry. Used together with `requestId`
    /// to deduplicate events that Claude Code wrote to multiple JSONL files
    /// (subagent forks, session resumes). Nil when absent from the line.
    let messageId: String?
    /// Top-level `requestId` from the assistant entry. See `messageId`.
    let requestId: String?

    init(
        timestamp: Date,
        sessionId: String,
        projectPath: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        messageId: String? = nil,
        requestId: String? = nil
    ) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.messageId = messageId
        self.requestId = requestId
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}
