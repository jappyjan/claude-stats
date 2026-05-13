import Foundation

struct APIRateLimits: Decodable, Equatable {
    struct Window: Decodable, Equatable {
        let utilization: Double
        let resets_at: Int  // unix seconds
    }
    struct Body: Decodable {
        let rate_limits: RateLimits
        struct RateLimits: Decodable {
            let five_hour: Window?
            let seven_day: Window?
        }
    }
    let five_hour: Window?
    let seven_day: Window?

    init(body: Body) {
        self.five_hour = body.rate_limits.five_hour
        self.seven_day = body.rate_limits.seven_day
    }
}

enum LimitsAPIError: Error {
    case noCredentials
    case httpStatus(Int)
    case decodeFailure
    case refreshFailed
}

actor LimitsAPIClient {
    private let keychain: KeychainReading
    private let session: URLSession
    private let now: () -> Date

    private let usageURL  = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let tokenURL  = URL(string: "https://api.anthropic.com/oauth/token")!

    init(keychain: KeychainReading,
         session: URLSession = .shared,
         now: @escaping () -> Date = Date.init) {
        self.keychain = keychain
        self.session = session
        self.now = now
    }

    func fetchUsage() async throws -> APIRateLimits {
        var creds = try keychain.readClaudeCredentials()
        guard var c = creds else { throw LimitsAPIError.noCredentials }
        if c.expiresAt <= now() {
            c = try await refresh(using: c)
            creds = c
        }
        do {
            return try await fetchOnce(with: c.accessToken)
        } catch LimitsAPIError.httpStatus(401) {
            // One retry after a forced refresh.
            let refreshed = try await refresh(using: c)
            return try await fetchOnce(with: refreshed.accessToken)
        }
    }

    private func fetchOnce(with token: String) async throws -> APIRateLimits {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LimitsAPIError.httpStatus(status) }
        do {
            let body = try JSONDecoder().decode(APIRateLimits.Body.self, from: data)
            return APIRateLimits(body: body)
        } catch {
            throw LimitsAPIError.decodeFailure
        }
    }

    private func refresh(using creds: ClaudeCredentials) async throws -> ClaudeCredentials {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(creds.refreshToken)"
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 10

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LimitsAPIError.refreshFailed }
        struct TokenResp: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int   // seconds
        }
        guard let tr = try? JSONDecoder().decode(TokenResp.self, from: data) else {
            throw LimitsAPIError.refreshFailed
        }
        let updated = ClaudeCredentials(
            accessToken:      tr.access_token,
            refreshToken:     tr.refresh_token,
            expiresAt:        now().addingTimeInterval(TimeInterval(tr.expires_in)),
            subscriptionType: creds.subscriptionType,
            rateLimitTier:    creds.rateLimitTier
        )
        try keychain.writeClaudeCredentials(updated)
        return updated
    }
}
