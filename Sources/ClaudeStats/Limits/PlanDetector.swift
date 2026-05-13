import Foundation

struct DetectedPlan: Equatable {
    let tier: PlanTier?
    let rawSubscriptionType: String
    let rawRateLimitTier: String
}

final class PlanDetector {
    private let keychain: KeychainReading

    init(keychain: KeychainReading) {
        self.keychain = keychain
    }

    func detect() -> DetectedPlan {
        let creds = (try? keychain.readClaudeCredentials()) ?? nil
        let sub = creds?.subscriptionType ?? ""
        let tier = creds?.rateLimitTier ?? ""
        return DetectedPlan(
            tier:                 PlanDetector.mapPlan(subscriptionType: sub, rateLimitTier: tier),
            rawSubscriptionType:  sub,
            rawRateLimitTier:     tier
        )
    }

    static func mapPlan(subscriptionType: String, rateLimitTier: String) -> PlanTier? {
        if rateLimitTier.contains("max_20x") { return .max_20x }
        if rateLimitTier.contains("max_5x")  { return .max_5x }
        if subscriptionType == "pro"         { return .pro }
        return nil
    }
}
