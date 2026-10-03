import CryptoKit
import Foundation
import Security

// Sessions of our own, for where there is no CLI to borrow one from: the
// phone. Sign-in goes through the same OAuth client and loopback redirect
// the CLI's own login uses, so the result is a separate session. Renewing
// it never signs the CLI out, and the other way around.

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

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date?, scopes: [String], accountID: String? = nil, plan: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountID = accountID
        self.plan = plan
    }

    /// A minute early, so a token doesn't run out between here and the server.
    func isLive(at now: Date) -> Bool {
        (expiresAt ?? .distantFuture) > now.addingTimeInterval(60)
    }
}

/// Tokens in the keychain, one item per provider, readable while the phone
/// is locked so lock screen widgets can still refresh.
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

    private func query(_ id: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecUseDataProtectionKeychain as String: true,
        ]
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
        return [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    public func remove(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }

    /// Runs `body` holding this provider's renewal lock, across processes.
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

/// A lock between processes that is a directory, created atomically, rather
/// than an flock: iOS kills a suspended process that holds a file lock in a
/// shared container, and a renewal can be suspended mid-request. Claude Code
/// locks its own renewals the same way.
enum DirectoryLock {
    /// A lock older than this was left by a process that died holding it.
    static let staleAfter: TimeInterval = 60

    static func take(_ lock: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        func create() -> Bool { (try? fm.createDirectory(at: lock, withIntermediateDirectories: false)) != nil }
        if create() { return true }
        let modified = (try? fm.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date) ?? .distantPast
        guard Date().timeIntervalSince(modified) > staleAfter else { return false }
        try? fm.removeItem(at: lock)
        return create()
    }

    static func release(_ lock: URL) {
        try? FileManager.default.removeItem(at: lock)
    }
}

/// A CLI's OAuth client, used the way the CLI's own login uses it.
public struct OAuthClient: Sendable {
    /// Also the provider id the tokens are stored under.
    enum Flavor: String, Sendable { case claude, codex }

    let flavor: Flavor
    public var id: String { flavor.rawValue }
    let authorizeURL: URL
    let tokenURL: URL
    let clientID: String
    let scopes: [String]
    /// The port the redirect has to come back on: Codex's client accepts
    /// only its one. Nil takes any free port.
    public let port: UInt16?
    public let callbackPath: String
    let extraParameters: [(String, String)]

    /// Claude Code's client, with the scopes it asks for on a claude.ai login.
    public static let claude = OAuthClient(
        flavor: .claude,
        authorizeURL: URL(string: "https://claude.com/cai/oauth/authorize")!,
        tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        scopes: ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"],
        port: nil,
        callbackPath: "/callback",
        extraParameters: [("code", "true")]
    )

    /// The Codex CLI's client.
    public static let codex = OAuthClient(
        flavor: .codex,
        authorizeURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
        scopes: ["openid", "profile", "email", "offline_access"],
        port: 1455,
        callbackPath: "/auth/callback",
        extraParameters: [
            ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"),
            ("originator", "codex_cli_rs"),
        ]
    )

    static let signedOut = "Signed out, sign in again in Headroom"
}

/// One sign-in attempt: the page to open, and the trade of the code the
/// redirect brings back for tokens.
public struct OAuthSignIn: Sendable {
    public let client: OAuthClient
    public let port: UInt16
    let verifier: String
    let state: String

    public init(client: OAuthClient, port: UInt16) {
        self.client = client
        self.port = port
        verifier = Self.random(byteCount: 64)
        state = Self.random(byteCount: 32)
    }

    var redirectURI: String { "http://localhost:\(port)\(client.callbackPath)" }

    public var authorizeURL: URL {
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: client.authorizeURL, resolvingAgainstBaseURL: false)!
        let parameters = client.extraParameters + [
            ("response_type", "code"),
            ("client_id", client.clientID),
            ("redirect_uri", redirectURI),
            ("scope", client.scopes.joined(separator: " ")),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        components.queryItems = parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" bare, which a server reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The code in a request that reached the redirect listener. Nil when
    /// the request is for something else, such as a favicon.
    public func code(fromRequestTarget target: String) -> Result<String, FetchFailure>? {
        guard let components = URLComponents(string: target), components.path == client.callbackPath else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        guard query["state"] == state else { return .failure(FetchFailure("Sign-in answered for a different attempt")) }
        if let error = query["error"] {
            return .failure(FetchFailure(query["error_description"] ?? error))
        }
        guard let code = query["code"], !code.isEmpty else { return .failure(FetchFailure("Sign-in returned no code")) }
        return .success(code)
    }

    public func exchange(_ code: String) async -> Result<AccountTokens, FetchFailure> {
        let now = Date()
        let response: Result<Data, FetchFailure>
        switch client.flavor {
        case .claude:
            response = await HTTP.post(client.tokenURL, json: [
                "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                "client_id": client.clientID, "code_verifier": verifier, "state": state,
            ], authHint: "Sign-in was refused")
        case .codex:
            response = await HTTP.post(client.tokenURL, form: [
                ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                ("client_id", client.clientID), ("code_verifier", verifier),
            ], authHint: "Sign-in was refused")
        }
        switch response {
        case .success(let data):
            guard var tokens = client.tokens(from: data, replacing: nil, now: now) else {
                return .failure(FetchFailure("Sign-in failed, unrecognized response"))
            }
            if client.flavor == .claude {
                tokens.plan = await PlanLookup.shared.plan(token: tokens.accessToken, scopes: tokens.scopes)
            }
            return .success(tokens)
        case .failure(let failure):
            return .failure(FetchFailure("Sign-in failed, \(failure.message.lowercased())"))
        }
    }

    static func random(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension OAuthClient {
    /// A token response as stored tokens, keeping from `old` whatever the
    /// server did not send again.
    func tokens(from data: Data, replacing old: AccountTokens?, now: Date) -> AccountTokens? {
        switch flavor {
        case .claude:
            guard let renewal = ClaudeProvider.parseRenewal(data, now: now) else { return nil }
            return AccountTokens(
                accessToken: renewal.token,
                refreshToken: renewal.refreshToken ?? old?.refreshToken,
                expiresAt: renewal.expiresAt,
                scopes: renewal.scopes.isEmpty ? old?.scopes ?? scopes : renewal.scopes,
                plan: old?.plan
            )
        case .codex:
            guard let root = Parse.object(data) else { return nil }
            guard let accessToken = root["access_token"] as? String, !accessToken.isEmpty else { return nil }
            let idClaims = (root["id_token"] as? String).flatMap(Self.jwtClaims)
            let auth = idClaims?["https://api.openai.com/auth"] as? [String: Any]
            return AccountTokens(
                accessToken: accessToken,
                refreshToken: (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? old?.refreshToken,
                expiresAt: Self.jwtClaims(accessToken).flatMap { Parse.epochDate($0["exp"]) },
                scopes: old?.scopes ?? scopes,
                accountID: auth?["chatgpt_account_id"] as? String ?? old?.accountID
            )
        }
    }

    /// The claims of a JWT, unverified: they only say which account and
    /// until when, and the server checks the token itself.
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload).flatMap(Parse.object)
    }

    /// Fetches with the stored session: renewed first when it has expired,
    /// and once more if the server turns down a token we took for live.
    func fetch(store: AccountStore, request: @Sendable (AccountTokens) async -> Result<Data, FetchFailure>) async -> Result<(Data, AccountTokens), FetchFailure> {
        guard var tokens = store.load(id) else {
            return .failure(FetchFailure("Not signed in"))
        }
        var renewed = false
        if !tokens.isLive(at: Date()) {
            switch await renew(tokens, store: store) {
            case .success(let fresh): (tokens, renewed) = (fresh, true)
            case .failure(let failure): return .failure(failure)
            }
        }
        var result = await request(tokens)
        if case .failure(let failure) = result, failure.status == 401, !renewed {
            switch await renew(tokens, store: store) {
            case .success(let fresh): tokens = fresh
            case .failure(let failure): return .failure(failure)
            }
            result = await request(tokens)
        }
        let final = tokens
        return result.map { ($0, final) }
    }

    /// Trades the refresh token for new tokens, one process at a time.
    func renew(_ seen: AccountTokens, store: AccountStore) async -> Result<AccountTokens, FetchFailure> {
        await store.locked(id) {
            // Signed out, or renewed by another process, while we waited
            // for the lock.
            guard let current = store.load(self.id) else {
                return .failure(FetchFailure(Self.signedOut))
            }
            if current.accessToken != seen.accessToken, current.isLive(at: Date()) {
                return .success(current)
            }
            guard let refreshToken = current.refreshToken else {
                // Nothing to renew with: signed out, so the app offers to sign in.
                store.remove(self.id)
                return .failure(FetchFailure(Self.signedOut))
            }
            let now = Date()
            // Codex renews with the scopes of its ID token, not offline_access.
            let scope = self.flavor == .claude ? current.scopes.joined(separator: " ") : "openid profile email"
            let response = await HTTP.post(self.tokenURL, json: [
                "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": self.clientID, "scope": scope,
            ], authHint: Self.signedOut)
            switch response {
            case .success(let data):
                guard let fresh = self.tokens(from: data, replacing: current, now: now) else {
                    return .failure(FetchFailure("Token renewal failed, unrecognized response"))
                }
                // The old refresh token may already be spent, so a failed
                // write, or a sign-out since, is as good as signed out.
                guard store.replace(fresh, for: self.id) else {
                    return .failure(FetchFailure(Self.signedOut))
                }
                return .success(fresh)
            case .failure(let failure) where Self.isSpent(failure):
                // Asking again would only get the same answer, so this is
                // signed out, and the app offers to sign in.
                store.remove(self.id)
                return .failure(FetchFailure(Self.signedOut))
            case .failure(let failure):
                return .failure(FetchFailure("Token renewal failed, \(failure.message.lowercased())", retryAfter: failure.retryAfter))
            }
        }
    }

    /// The refresh token itself is gone: revoked, superseded, or expired.
    /// Any other 400 is about the request and not the session.
    static func isSpent(_ failure: FetchFailure) -> Bool {
        if failure.status == 401 { return true }
        guard failure.status == 400, let root = failure.body.flatMap(Parse.object) else { return false }
        if root["error"] as? String == "invalid_grant" { return true }
        // ChatGPT's: "refresh_token_expired", "_reused", "_invalidated".
        let code = (root["error"] as? [String: Any])?["code"] as? String ?? root["code"] as? String
        return code?.hasPrefix("refresh_token_") ?? false
    }
}

/// A provider fetched with a session of our own, which `client` signs in.
public protocol AccountProvider: Provider {
    var client: OAuthClient { get }
}

/// Claude usage with a session of our own, from `OAuthClient.claude`.
public struct ClaudeAccountProvider: AccountProvider {
    private static let base = ClaudeProvider()
    public var id: String { Self.base.id }
    public var name: String { Self.base.name }
    public var glyph: String { Self.base.glyph }
    public var usageURL: URL { Self.base.usageURL }
    public var client: OAuthClient { .claude }

    let store: AccountStore

    public init(store: AccountStore) {
        self.store = store
    }

    public func fetch() async -> Result<Snapshot, FetchFailure> {
        let result = await client.fetch(store: store) { tokens in
            await HTTP.get(
                ClaudeProvider.endpoint,
                headers: ClaudeProvider.oauthHeaders(token: tokens.accessToken).merging(["Content-Type": "application/json"]) { $1 },
                authHint: OAuthClient.signedOut
            )
        }
        let data: Data, tokens: AccountTokens
        switch result {
        case .success(let fetched): (data, tokens) = fetched
        case .failure(let failure): return .failure(failure)
        }
        guard var snapshot = ClaudeProvider.parse(data, now: Date()) else { return .failure(FetchFailure("Unrecognized response")) }
        // As on the Mac: the plan as of the last sign-in, until the profile,
        // asked about hourly, says otherwise.
        snapshot.plan = await PlanLookup.shared.plan(token: tokens.accessToken, scopes: tokens.scopes) ?? tokens.plan
        return .success(snapshot)
    }
}

/// Codex usage with a session of our own, from `OAuthClient.codex`.
public struct CodexAccountProvider: AccountProvider {
    private static let base = CodexProvider()
    public var id: String { Self.base.id }
    public var name: String { Self.base.name }
    public var glyph: String { Self.base.glyph }
    public var usageURL: URL { Self.base.usageURL }
    public var client: OAuthClient { .codex }

    let store: AccountStore

    public init(store: AccountStore) {
        self.store = store
    }

    public func fetch() async -> Result<Snapshot, FetchFailure> {
        let result = await client.fetch(store: store) { tokens in
            await HTTP.get(CodexProvider.endpoint, headers: CodexProvider.headers(token: tokens.accessToken, accountID: tokens.accountID), authHint: OAuthClient.signedOut)
        }
        return result.flatMap { data, _ in
            CodexProvider.parse(data, now: Date()).map(Result.success) ?? .failure(FetchFailure("Unrecognized response"))
        }
    }
}
