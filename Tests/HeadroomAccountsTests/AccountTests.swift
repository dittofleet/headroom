import Foundation
import Testing
@testable import HeadroomAccounts
@testable import HeadroomCore

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
}

/// A JWT with these claims and no real signature, which is all the parsing looks at.
private func jwt(_ claims: [String: Any]) -> String {
    let payload = OAuthSignIn.base64URL(try! JSONSerialization.data(withJSONObject: claims))
    return "eyJhbGciOiJub25lIn0.\(payload).sig"
}

@Test func claudeAuthorizeURLMatchesClaudeCode() {
    let attempt = OAuthSignIn(client: .claude, port: 54321)
    let url = attempt.authorizeURL
    #expect(url.absoluteString.hasPrefix("https://claude.com/cai/oauth/authorize?"))
    let items = query(url)
    #expect(items["code"] == "true")
    #expect(items["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    #expect(items["redirect_uri"] == "http://localhost:54321/callback")
    #expect(items["scope"]?.split(separator: " ").contains("user:profile") == true)
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["state"] == attempt.state)
    // The challenge is the verifier's SHA-256, never the verifier itself.
    #expect(items["code_challenge"] != attempt.verifier)
    #expect(items["code_challenge"]?.count == 43)
}

@Test func codexAuthorizeURLMatchesTheCodexCLI() {
    let attempt = OAuthSignIn(client: .codex, port: 1455)
    let items = query(attempt.authorizeURL)
    #expect(attempt.authorizeURL.host == "auth.openai.com")
    #expect(items["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
    #expect(items["redirect_uri"] == "http://localhost:1455/auth/callback")
    #expect(items["scope"] == "openid profile email offline_access")
    #expect(items["codex_cli_simplified_flow"] == "true")
}

@Test func redirectYieldsTheCodeOnlyForThisAttempt() throws {
    let attempt = OAuthSignIn(client: .claude, port: 1)
    let state = attempt.state.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    #expect(attempt.code(fromRequestTarget: "/favicon.ico") == nil)
    let good = try #require(attempt.code(fromRequestTarget: "/callback?code=abc&state=\(state)"))
    #expect(try good.get() == "abc")
    let forged = try #require(attempt.code(fromRequestTarget: "/callback?code=abc&state=other"))
    #expect(throws: FetchFailure.self) { try forged.get() }
    let denied = try #require(attempt.code(fromRequestTarget: "/callback?error=access_denied&state=\(state)"))
    #expect(throws: FetchFailure.self) { try denied.get() }
}

@Test func codexTokensComeFromTheJWTs() async throws {
    let access = jwt(["exp": 1_790_000_000])
    let id = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct"]])
    let body = try JSONSerialization.data(withJSONObject: ["access_token": access, "id_token": id, "refresh_token": "r1"])
    let tokens = try #require(OAuthClient.codex.tokens(from: body, replacing: nil, now: Date()))
    #expect(tokens.accessToken == access)
    #expect(tokens.refreshToken == "r1")
    #expect(tokens.accountID == "acct")
    #expect(tokens.expiresAt == Date(timeIntervalSince1970: 1_790_000_000))

    // A renewal without a new refresh token or account keeps the old ones.
    let renewal = try JSONSerialization.data(withJSONObject: ["access_token": jwt(["exp": 1_790_100_000])])
    let renewed = try #require(OAuthClient.codex.tokens(from: renewal, replacing: tokens, now: Date()))
    #expect(renewed.refreshToken == "r1")
    #expect(renewed.accountID == "acct")
    #expect(renewed.expiresAt == Date(timeIntervalSince1970: 1_790_100_000))
}

@Test func tokensRenewAMinuteEarly() {
    let tokens = AccountTokens(accessToken: "t", expiresAt: Date(timeIntervalSince1970: 1000), scopes: [])
    #expect(tokens.isLive(at: Date(timeIntervalSince1970: 900)))
    #expect(!tokens.isLive(at: Date(timeIntervalSince1970: 950)))
}
