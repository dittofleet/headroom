import Foundation

/// A CLI's OAuth client, used the way the CLI's own login uses it.
public struct OAuthClient: Sendable {
    /// Also the provider id the tokens are stored under.
    package enum Flavor: String, Sendable { case claude, codex }

    package let flavor: Flavor
    public var id: String { flavor.rawValue }
    package let authorizeURL: URL
    package let tokenURL: URL
    package let clientID: String
    package let scopes: [String]
    /// The port the redirect has to come back on: Codex's client accepts
    /// only its one. Nil takes any free port.
    public let port: UInt16?
    public let callbackPath: String
    package let extraParameters: [(String, String)]

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

    /// The refresh token itself is gone: revoked, superseded, or expired.
    /// Any other 400 is about the request and not the session.
    package static func isSpent(_ failure: FetchFailure) -> Bool {
        if failure.status == 401 { return true }
        guard failure.status == 400, let root = failure.body.flatMap(Parse.object) else { return false }
        if root["error"] as? String == "invalid_grant" { return true }
        // ChatGPT's: "refresh_token_expired", "_reused", "_invalidated".
        let code = (root["error"] as? [String: Any])?["code"] as? String ?? root["code"] as? String
        return code?.hasPrefix("refresh_token_") ?? false
    }
}
