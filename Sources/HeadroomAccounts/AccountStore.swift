import Foundation
import HeadroomCore
import Security

// Sessions of our own, for where there is no CLI to borrow one from (the
// phone), or the CLI's is better left alone (the Mac). Sign-in goes
// through the same OAuth client and loopback redirect the CLI's own login
// uses, so the result is a separate session. Renewing it never signs the
// CLI out, and the other way around.

/// A signed-in session with one provider.
public struct AccountTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]
    /// Codex's ChatGPT account, sent along with every request.
    public var accountID: String?
    /// Claude's plan as of sign-in, for when the profile can't be asked.
    /// Codex's comes with its usage instead.
    public var plan: String?
    /// Who signed in, to show. Also stored as the item's comment, which can
    /// be read without the tokens.
    public var email: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date?, scopes: [String], accountID: String? = nil, plan: String? = nil, email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountID = accountID
        self.plan = plan
        self.email = email
    }

    /// A minute early, so a token doesn't run out between here and the server.
    func isLive(at now: Date) -> Bool {
        (expiresAt ?? .distantFuture) > now.addingTimeInterval(60)
    }
}

/// Tokens in the keychain, one item per account: on the Mac one per
/// provider, keyed by its id. On the phone, readable
/// while it is locked so lock screen widgets can still refresh. On the Mac,
/// in the login keychain: the data protection one needs entitlements a
/// local build doesn't have.
public struct AccountStore: Sendable {
    private static let service = "io.github.dittofleet.headroom.account"

    /// Shared by the app and its widgets.
    let accessGroup: String?
    /// Holds the locks taken around a renewal. Both providers rotate refresh
    /// tokens, so two processes renewing the same one at once would sign
    /// the slower one out.
    let lockDirectory: URL?

    public init(accessGroup: String?, lockDirectory: URL?) {
        self.accessGroup = accessGroup
        self.lockDirectory = lockDirectory
    }

    /// Every item when `id` is nil.
    private func query(_ id: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        if let id { query[kSecAttrAccount as String] = id }
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load(_ id: String) -> AccountTokens? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AccountTokens.self, from: data)
    }

    /// Whether there are tokens at all, without reading them.
    public func contains(_ id: String) -> Bool {
        SecItemCopyMatching(query(id) as CFDictionary, nil) == errSecSuccess
    }

    /// Every id there are tokens for, and who signed in, without reading
    /// the tokens.
    public func accounts() -> [(id: String, email: String?)] {
        var query = query(nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return (result as? [[String: Any]] ?? []).compactMap { item in
            (item[kSecAttrAccount as String] as? String).map { ($0, item[kSecAttrComment as String] as? String) }
        }
    }

    /// Who signed in, without reading the tokens: on the Mac, that can ask
    /// for the keychain password.
    public func email(_ id: String) -> String? {
        var query = query(id)
        query[kSecReturnAttributes as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[kSecAttrComment as String] as? String
    }

    /// Stores a sign-in's tokens, replacing any there were.
    @discardableResult
    public func save(_ tokens: AccountTokens, for id: String) -> Bool {
        guard let attributes = Self.attributes(tokens) else { return false }
        if update(attributes, for: id) { return true }
        return SecItemAdd(query(id).merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    /// Stores renewed tokens, but only over ones still there: a renewal
    /// that finishes after a sign-out must not sign back in.
    func replace(_ tokens: AccountTokens, for id: String) -> Bool {
        Self.attributes(tokens).map { update($0, for: id) } ?? false
    }

    private func update(_ attributes: [String: Any], for id: String) -> Bool {
        SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }

    private static func attributes(_ tokens: AccountTokens) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(tokens) else { return nil }
        var attributes: [String: Any] = [kSecValueData as String: data]
        // Not the label: the Mac's login keychain fills that in.
        if let email = tokens.email { attributes[kSecAttrComment as String] = email }
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return attributes
    }

    /// Whether the tokens are gone, including when there were none.
    @discardableResult
    public func remove(_ id: String) -> Bool {
        [errSecSuccess, errSecItemNotFound].contains(SecItemDelete(query(id) as CFDictionary))
    }

    /// Runs `body` holding this account's renewal lock, across processes.
    /// Waits for one another process holds, up to when it counts as stale.
    func locked<T: Sendable>(_ id: String, _ body: @Sendable () async -> T) async -> T {
        guard let lockDirectory else { return await body() }
        let lock = lockDirectory.appendingPathComponent("\(id).lock")
        let giveUp = Date().addingTimeInterval(DirectoryLock.staleAfter + 5)
        while !DirectoryLock.take(lock), Date() < giveUp {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        defer { DirectoryLock.release(lock) }
        return await body()
    }
}
