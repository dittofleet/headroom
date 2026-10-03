import CryptoKit
import Foundation
import HeadroomCore
import Security

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
}
