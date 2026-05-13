import XCTest
@testable import ClaudeStats

final class PlanDetectorTests: XCTestCase {
    private final class FakeKeychain: KeychainReading {
        var creds: ClaudeCredentials?
        var error: Error?
        func readClaudeCredentials() throws -> ClaudeCredentials? {
            if let error { throw error }
            return creds
        }
        func writeClaudeCredentials(_ creds: ClaudeCredentials) throws {}
    }

    private func creds(sub: String?, tier: String?) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: .distantFuture,
            subscriptionType: sub, rateLimitTier: tier
        )
    }

    func testMapsMax5x() {
        let k = FakeKeychain()
        k.creds = creds(sub: "max", tier: "default_claude_max_5x")
        let detector = PlanDetector(keychain: k)
        let result = detector.detect()
        XCTAssertEqual(result.tier, .max_5x)
        XCTAssertEqual(result.rawSubscriptionType, "max")
        XCTAssertEqual(result.rawRateLimitTier, "default_claude_max_5x")
    }

    func testMapsMax20x() {
        let k = FakeKeychain()
        k.creds = creds(sub: "max", tier: "default_claude_max_20x")
        XCTAssertEqual(PlanDetector(keychain: k).detect().tier, .max_20x)
    }

    func testMapsPro() {
        let k = FakeKeychain()
        k.creds = creds(sub: "pro", tier: "default_claude_pro")
        XCTAssertEqual(PlanDetector(keychain: k).detect().tier, .pro)
    }

    func testUnknownTierLeavesTierNil() {
        let k = FakeKeychain()
        k.creds = creds(sub: "team", tier: "default_claude_team")
        XCTAssertNil(PlanDetector(keychain: k).detect().tier)
    }

    func testMissingKeychainItemReturnsNilTier() {
        let k = FakeKeychain()
        k.creds = nil
        let result = PlanDetector(keychain: k).detect()
        XCTAssertNil(result.tier)
        XCTAssertEqual(result.rawSubscriptionType, "")
    }

    func testKeychainErrorReturnsNilTier() {
        let k = FakeKeychain()
        k.error = KeychainError.accessDenied(-25300)
        XCTAssertNil(PlanDetector(keychain: k).detect().tier)
    }
}
