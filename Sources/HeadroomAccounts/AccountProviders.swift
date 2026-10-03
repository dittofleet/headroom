import Foundation
import HeadroomCore

extension OAuthClient {
    static let signedOut = "Signed out, sign in again in Headroom"

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
