import Foundation

/// In-memory identity proof for the current Cookie. Only AppState installs an
/// identity after /auth/me succeeds; Keychain contents alone never grant access.
@MainActor
final class VerifiedAccountContext {
    private var verifiedCookie: String?
    private(set) var owner: String?

    func confirm(username: String, cookie: String) throws {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !cookie.isEmpty else { throw APIError.invalidResponse }
        verifiedCookie = cookie
        owner = "user:\(normalized)"
    }

    func requireOwner(cookie: String?) throws -> String {
        guard let cookie, !cookie.isEmpty, cookie == verifiedCookie, let owner else {
            throw APIError.unauthorized(message: "请先登录后查看本机安排。")
        }
        return owner
    }

    func clear() {
        verifiedCookie = nil
        owner = nil
    }
}
