import Foundation
import Security

struct ClaudeCredentials: Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let subscriptionType: String?
    let rateLimitTier: String?
}

protocol KeychainReading {
    /// Returns the Claude Code credentials, or nil if the keychain item is
    /// absent. Throws on access denied / parse failures.
    func readClaudeCredentials() throws -> ClaudeCredentials?

    /// Writes refreshed credentials back to the same keychain item.
    func writeClaudeCredentials(_ creds: ClaudeCredentials) throws
}

enum KeychainError: Error {
    case accessDenied(OSStatus)
    case malformed(String)
}

private struct StoredEnvelope: Codable {
    let claudeAiOauth: StoredOAuth
    struct StoredOAuth: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int64        // milliseconds since epoch
        let subscriptionType: String?
        let rateLimitTier: String?
    }
}

final class KeychainReader: KeychainReading {
    private let service: String

    init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    func readClaudeCredentials() throws -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.accessDenied(status)
        }
        let envelope: StoredEnvelope
        do {
            envelope = try JSONDecoder().decode(StoredEnvelope.self, from: data)
        } catch {
            throw KeychainError.malformed(String(describing: error))
        }
        return ClaudeCredentials(
            accessToken:      envelope.claudeAiOauth.accessToken,
            refreshToken:     envelope.claudeAiOauth.refreshToken,
            expiresAt:        Date(timeIntervalSince1970: TimeInterval(envelope.claudeAiOauth.expiresAt) / 1000),
            subscriptionType: envelope.claudeAiOauth.subscriptionType,
            rateLimitTier:    envelope.claudeAiOauth.rateLimitTier
        )
    }

    func writeClaudeCredentials(_ creds: ClaudeCredentials) throws {
        // Read current envelope, mutate the tokens, write back. Preserves any
        // fields we don't know about.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let existing = item as? Data,
              var raw = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              var oauth = raw["claudeAiOauth"] as? [String: Any] else {
            throw KeychainError.accessDenied(status)
        }
        oauth["accessToken"]  = creds.accessToken
        oauth["refreshToken"] = creds.refreshToken
        oauth["expiresAt"]    = Int64(creds.expiresAt.timeIntervalSince1970 * 1000)
        raw["claudeAiOauth"]  = oauth
        let updated = try JSONSerialization.data(withJSONObject: raw)

        let updateQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecValueData as String: updated]
        let upStatus = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)
        if upStatus != errSecSuccess {
            throw KeychainError.accessDenied(upStatus)
        }
    }
}
