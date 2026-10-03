import Foundation
import Testing
@testable import HeadroomCore
@testable import HeadroomMac

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

@Test func cliLinkOnlyManagesItsOwnLink() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appendingPathComponent("bin")
    let binary = dir.appendingPathComponent("New/Headroom.app/Contents/MacOS/headroom-cli")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: binary)
    let link = CLILink(binary: binary, binDir: bin)

    #expect(link.state == .missing)
    try link.install()
    #expect(link.state == .installed)
    try link.install()
    #expect(link.state == .installed)

    // A link to a copy of the app that has since gone is repaired.
    try FileManager.default.removeItem(at: link.link)
    try FileManager.default.createSymbolicLink(atPath: link.link.path, withDestinationPath: dir.appendingPathComponent("Old/Headroom.app/Contents/MacOS/headroom-cli").path)
    #expect(link.state == .stale)
    link.repairIfStale()
    #expect(link.state == .installed)
    try link.uninstall()
    #expect(link.state == .missing)

    // Another copy of the app that is still there keeps its link.
    let other = dir.appendingPathComponent("Other/Headroom.app/Contents/MacOS/headroom-cli")
    try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: other)
    try FileManager.default.createSymbolicLink(atPath: link.link.path, withDestinationPath: other.path)
    #expect(link.state == .foreign)
    link.repairIfStale()
    #expect(link.state == .foreign)
    try FileManager.default.removeItem(at: link.link)

    // A headroom-cli outside an app bundle was linked by hand.
    try FileManager.default.createSymbolicLink(atPath: link.link.path, withDestinationPath: dir.appendingPathComponent("tools/headroom-cli").path)
    #expect(link.state == .foreign)
    link.repairIfStale()
    #expect(link.state == .foreign)
    try FileManager.default.removeItem(at: link.link)

    // Someone else's file is refused, and survives an uninstall, until the
    // user agrees to replace it.
    try Data("mine".utf8).write(to: link.link)
    #expect(link.state == .foreign)
    #expect(throws: CLILink.Failure.self) { try link.install() }
    try link.uninstall()
    #expect(try Data(contentsOf: link.link) == Data("mine".utf8))
    try link.install(replacing: true)
    #expect(link.state == .installed)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path) == ["headroom"])
}
