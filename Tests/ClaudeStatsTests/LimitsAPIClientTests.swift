import XCTest
@testable import ClaudeStats

final class LimitsAPIClientTests: XCTestCase {

    // MARK: - Mock URLProtocol

    final class StubProtocol: URLProtocol {
        struct Stub {
            let statusCode: Int
            let body: Data
            let validate: ((URLRequest) -> Void)?
        }

        nonisolated(unsafe) static var stubs: [(host: String, path: String, stub: Stub)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let req = self.request
            let host = req.url?.host ?? ""
            let path = req.url?.path ?? ""
            guard let entry = Self.stubs.first(where: { $0.host == host && $0.path == path }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            entry.stub.validate?(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: entry.stub.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: entry.stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private final class FakeKeychain: KeychainReading {
        var creds: ClaudeCredentials?
        var lastWritten: ClaudeCredentials?
        func readClaudeCredentials() throws -> ClaudeCredentials? { creds }
        func writeClaudeCredentials(_ creds: ClaudeCredentials) throws { lastWritten = creds }
    }

    override func tearDown() {
        StubProtocol.stubs = []
        super.tearDown()
    }

    func testFetchHappyPathMax5x() async throws {
        let keychain = FakeKeychain()
        keychain.creds = ClaudeCredentials(
            accessToken: "tok", refreshToken: "ref",
            expiresAt: .distantFuture,
            subscriptionType: "max", rateLimitTier: "default_claude_max_5x"
        )
        StubProtocol.stubs = [(
            host: "api.anthropic.com", path: "/api/oauth/usage",
            stub: .init(
                statusCode: 200,
                body: try fixture("oauth-usage-max-5x"),
                validate: { req in
                    XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
                }
            )
        )]
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        let result = try await client.fetchUsage()
        XCTAssertEqual(result.five_hour?.utilization, 42.0)
        XCTAssertEqual(result.seven_day?.utilization, 18.0)
    }

    func testFetchHappyPathProOnlyFiveHour() async throws {
        let keychain = FakeKeychain()
        keychain.creds = ClaudeCredentials(
            accessToken: "tok", refreshToken: "ref",
            expiresAt: .distantFuture,
            subscriptionType: "pro", rateLimitTier: "default_claude_pro"
        )
        StubProtocol.stubs = [(
            host: "api.anthropic.com", path: "/api/oauth/usage",
            stub: .init(statusCode: 200, body: try fixture("oauth-usage-pro"), validate: nil)
        )]
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        let result = try await client.fetchUsage()
        XCTAssertEqual(result.five_hour?.utilization, 12.5)
        XCTAssertNil(result.seven_day)
    }

    func testExpiredTokenTriggersRefresh() async throws {
        let keychain = FakeKeychain()
        keychain.creds = ClaudeCredentials(
            accessToken: "old", refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 1),  // long expired
            subscriptionType: "max", rateLimitTier: "default_claude_max_5x"
        )
        StubProtocol.stubs = [
            (host: "api.anthropic.com", path: "/oauth/token",
             stub: .init(statusCode: 200, body: try fixture("oauth-token-refresh"),
                         validate: { req in
                            XCTAssertEqual(req.httpMethod, "POST")
                         })),
            (host: "api.anthropic.com", path: "/api/oauth/usage",
             stub: .init(statusCode: 200, body: try fixture("oauth-usage-max-5x"),
                         validate: { req in
                            // Should use the refreshed token.
                            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-new")
                         })),
        ]
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        _ = try await client.fetchUsage()
        XCTAssertEqual(keychain.lastWritten?.accessToken, "sk-ant-oat01-new")
        XCTAssertEqual(keychain.lastWritten?.refreshToken, "sk-ant-ort01-new")
    }

    func testHTTP500Throws() async {
        let keychain = FakeKeychain()
        keychain.creds = ClaudeCredentials(
            accessToken: "tok", refreshToken: "ref",
            expiresAt: .distantFuture, subscriptionType: nil, rateLimitTier: nil
        )
        StubProtocol.stubs = [(
            host: "api.anthropic.com", path: "/api/oauth/usage",
            stub: .init(statusCode: 500, body: Data(), validate: nil)
        )]
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        do {
            _ = try await client.fetchUsage()
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    func testNoCredentialsThrows() async {
        let keychain = FakeKeychain()
        keychain.creds = nil
        let client = LimitsAPIClient(keychain: keychain, session: mockSession(), now: { Date() })
        do {
            _ = try await client.fetchUsage()
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }
}
