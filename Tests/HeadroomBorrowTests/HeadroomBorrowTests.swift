import Foundation
import Testing
@testable import HeadroomCore
@testable import HeadroomBorrow

private let now = Date(timeIntervalSince1970: 1_789_873_000)

@Test func claudeCredentials() throws {
    let creds = try #require(ClaudeProvider.parseCredentials(Data(
        #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1789891084074, "subscriptionType": "max"}}"#.utf8), source: .keychain(account: "me")))
    #expect(creds.plan == "Max")
    #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_789_891_084.074))
    #expect(creds.refreshToken == nil && creds.scopes.isEmpty)
    #expect(ClaudeProvider.parseCredentials(Data(#"{"claudeAiOauth": {}}"#.utf8), source: .keychain(account: "me")) == nil)
}

@Test func claudeRenewedDocumentKeepsClaudeCodeShape() throws {
    let stored = Data(#"""
    {"claudeAiOauth": {"accessToken": "old", "refreshToken": "r1", "expiresAt": 1789891084074,
     "scopes": ["user:inference"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"},
     "somethingElse": {"kept": true}}
    """#.utf8)
    let renewal = ClaudeProvider.Renewal(token: "new", refreshToken: "r2", expiresAt: now, refreshTokenExpiresAt: now.addingTimeInterval(60), scopes: ["user:inference", "user:profile"])
    let document = try #require(ClaudeProvider.renewedDocument(stored, with: renewal))
    let root = try #require(Parse.object(document))
    let oauth = try #require(root["claudeAiOauth"] as? [String: Any])
    #expect(oauth["accessToken"] as? String == "new")
    #expect(oauth["refreshToken"] as? String == "r2")
    #expect(oauth["expiresAt"] as? Int64 == 1_789_873_000_000)
    #expect(oauth["refreshTokenExpiresAt"] as? Int64 == 1_789_873_060_000)
    #expect(oauth["scopes"] as? [String] == ["user:inference", "user:profile"])
    #expect(oauth["subscriptionType"] as? String == "max" && oauth["rateLimitTier"] as? String == "default_claude_max_5x")
    #expect((root["somethingElse"] as? [String: Any])?["kept"] as? Bool == true)

    // The renewed credentials read back like the originals did.
    let creds = try #require(ClaudeProvider.parseCredentials(document, source: .keychain(account: "me")))
    #expect(creds.token == "new" && creds.refreshToken == "r2" && creds.expiresAt == now && creds.plan == "Max 5x")

    // Without a new refresh token, the stored one stays.
    let kept = try #require(ClaudeProvider.renewedDocument(stored, with: ClaudeProvider.Renewal(token: "n", refreshToken: nil, expiresAt: now, refreshTokenExpiresAt: nil, scopes: [])))
    #expect(ClaudeProvider.parseCredentials(kept, source: .keychain(account: "me"))?.refreshToken == "r1")
    #expect(ClaudeProvider.parseCredentials(kept, source: .keychain(account: "me"))?.scopes == ["user:inference"])
    #expect(ClaudeProvider.renewedDocument(Data("{}".utf8), with: renewal) == nil)
}

@Test func codexCredentials() throws {
    let creds = try #require(CodexProvider.parseCredentials(Data(#"{"tokens": {"access_token": "t", "account_id": "a"}}"#.utf8)))
    #expect(creds.token == "t" && creds.accountID == "a")
    #expect(CodexProvider.parseCredentials(Data(#"{"OPENAI_API_KEY": "k", "tokens": null}"#.utf8)) == nil)
}

@Test func claudeKeychainWriteSwitchesToArgumentsPastSecurityLineLimit() throws {
    let small = TokenRenewer.keychainWrite(Data(repeating: 0x41, count: 1900), account: "me")
    #expect(small.args == ["-i"])
    let line = try #require(small.input.flatMap { String(data: $0, encoding: .utf8) })
    #expect(line.utf8.count <= 4032 && line.hasPrefix("add-generic-password -U -a \"me\" -s ") && line.hasSuffix("\"\n"))

    let large = TokenRenewer.keychainWrite(Data(repeating: 0x41, count: 2000), account: "me")
    #expect(large.input == nil)
    #expect(large.args == ["add-generic-password", "-U", "-a", "me", "-s", ClaudeProvider.keychainService, "-X", String(repeating: "41", count: 2000)])
}
