import Foundation
import Testing
@testable import HeadroomCore

private let now = Date(timeIntervalSince1970: 1_789_873_000)

@Test func claudeParsesLimitsArray() throws {
    let json = """
    {"five_hour": {"utilization": 47.0, "resets_at": "2026-09-20T04:40:00.887823+00:00"},
     "limits": [
      {"kind": "session", "group": "session", "percent": 47, "resets_at": "2026-09-20T04:40:00.887823+00:00", "scope": null},
      {"kind": "weekly_all", "group": "weekly", "percent": 49, "resets_at": "2026-09-25T10:00:00.887843+00:00", "scope": null},
      {"kind": "weekly_scoped", "group": "weekly", "percent": 63, "resets_at": "2026-09-25T10:00:00.888017+00:00",
       "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}},
      {"kind": "session", "percent": true}
     ]}
    """
    let snapshot = try #require(ClaudeProvider.parse(Data(json.utf8), now: now))
    #expect(snapshot.limits.map(\.label) == ["Session", "Weekly", "Fable Weekly"])
    #expect(snapshot.limits.map(\.percent) == [47, 49, 63])
    #expect(snapshot.limits[0].resetsAt == Date(timeIntervalSince1970: 1_789_879_200))
    #expect(snapshot.limits[0].windowSeconds == 18000)
}

@Test func claudeFallsBackToLegacyShape() throws {
    let json = """
    {"five_hour": {"utilization": 12.5, "resets_at": null},
     "seven_day": {"utilization": 30, "resets_at": "2026-09-25T10:00:00Z"},
     "seven_day_opus": null}
    """
    let snapshot = try #require(ClaudeProvider.parse(Data(json.utf8), now: now))
    #expect(snapshot.limits.map(\.label) == ["Session", "Weekly"])
    #expect(snapshot.limits[0].resetsAt == nil)
}

@Test func garbageIsRejected() {
    #expect(ClaudeProvider.parse(Data("<html>".utf8), now: now) == nil)
    #expect(ClaudeProvider.parse(Data("{}".utf8), now: now) == nil)
    #expect(CodexProvider.parse(Data("[]".utf8), now: now) == nil)
    #expect(CodexProvider.parse(Data(#"{"rate_limit": null}"#.utf8), now: now) == nil)
}

@Test func codexParsesWindows() throws {
    let json = """
    {"plan_type": "plus",
     "rate_limit": {"allowed": true,
       "primary_window": {"used_percent": 69, "limit_window_seconds": 18000, "reset_at": 1789880284},
       "secondary_window": {"used_percent": 40, "limit_window_seconds": 604800, "reset_at": 1789925529}},
     "code_review_rate_limit": {"primary_window": {"used_percent": 5, "limit_window_seconds": 604800, "reset_at": 1789925529}, "secondary_window": null},
     "additional_rate_limits": null}
    """
    let snapshot = try #require(CodexProvider.parse(Data(json.utf8), now: now))
    #expect(snapshot.plan == "Plus")
    #expect(snapshot.limits.map(\.label) == ["Session", "Weekly", "Code review Weekly"])
    #expect(snapshot.limits.map(\.kind) == [.session, .weekly, .other])
    #expect(snapshot.limits[1].resetsAt == Date(timeIntervalSince1970: 1_789_925_529))
}

@Test func claudeCredentials() throws {
    let creds = try #require(ClaudeProvider.parseCredentials(Data(
        #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1789891084074, "subscriptionType": "max"}}"#.utf8), source: .keychain(account: "me")))
    #expect(creds.plan == "Max")
    #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_789_891_084.074))
    #expect(creds.refreshToken == nil && creds.scopes.isEmpty)
    #expect(ClaudeProvider.parseCredentials(Data(#"{"claudeAiOauth": {}}"#.utf8), source: .keychain(account: "me")) == nil)
}

@Test func planNames() {
    #expect(ClaudeProvider.planName("max", tier: "default_claude_max_20x") == "Max 20x")
    #expect(ClaudeProvider.planName("max", tier: "default_claude_max_40x") == "Max 40x")
    #expect(ClaudeProvider.planName("max", tier: nil) == "Max")
    #expect(ClaudeProvider.planName("max", tier: "default_claude_max_20x_v2") == "Max")
    #expect(ClaudeProvider.planName("team", tier: "default_claude_max_5x") == "Team Premium")
    #expect(ClaudeProvider.planName("enterprise", tier: "whatever") == "Enterprise")
    #expect(ClaudeProvider.planName("", tier: nil) == nil)
    #expect(CodexProvider.planName("self_serve_business_prolite") == "Business Pro Lite")
    #expect(CodexProvider.planName("prolite") == "Pro Lite")
    #expect(CodexProvider.planName("ent26") == "Enterprise")
    #expect(CodexProvider.planName("edu_plus") == "Edu Plus")
    #expect(CodexProvider.planName("some_NEW_plan_4o") == "Some New Plan 4o")
    #expect(CodexProvider.planName("unknown") == nil)
}

@Test func claudeRenewalResponse() throws {
    let renewal = try #require(ClaudeProvider.parseRenewal(Data(
        #"{"token_type": "Bearer", "access_token": "new", "expires_in": 28800, "refresh_token": "", "refresh_token_expires_in": 2592000, "scope": "user:inference user:profile"}"#.utf8), now: now))
    #expect(renewal.token == "new")
    #expect(renewal.refreshToken == nil, "an empty refresh token means the old one stays")
    #expect(renewal.expiresAt == now.addingTimeInterval(28800))
    #expect(renewal.refreshTokenExpiresAt == now.addingTimeInterval(2_592_000))
    #expect(renewal.scopes == ["user:inference", "user:profile"])
    #expect(ClaudeProvider.parseRenewal(Data(#"{"error": "invalid_grant"}"#.utf8), now: now) == nil)
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

@Test func booleansAreNotNumbers() {
    #expect(Parse.epochDate(true) == nil)
    #expect(Parse.number(false) == nil)
}

@Test func snapshotStalenessAndExpiry() {
    let soon = Limit(kind: .session, label: "Session", percent: 1, resetsAt: now.addingTimeInterval(100), windowSeconds: nil)
    let past = Limit(kind: .weekly, label: "Weekly", percent: 1, resetsAt: now.addingTimeInterval(-5), windowSeconds: nil)
    let snapshot = Snapshot(limits: [past, soon], plan: nil, fetchedAt: now)
    #expect(snapshot.expiresAt == now.addingTimeInterval(100))
    #expect(!snapshot.isStale(at: now.addingTimeInterval(19 * 60)))
    #expect(snapshot.isStale(at: now.addingTimeInterval(21 * 60)))
}

@Test func limitRollsOverAfterReset() {
    let limit = Limit(kind: .session, label: "Session", percent: 80, resetsAt: now.addingTimeInterval(3600), windowSeconds: 18000)
    #expect(limit.percent(at: now) == 80)
    #expect(limit.percent(at: now.addingTimeInterval(3601)) == 0)
    #expect(limit.elapsedFraction(at: now) == 0.8)
    #expect(limit.elapsedFraction(at: now.addingTimeInterval(3601)) == nil)
}

@Test func headlineIsAlwaysTheSession() {
    let session = Limit(kind: .session, label: "Session", percent: 20, resetsAt: nil, windowSeconds: nil)
    let weekly = Limit(kind: .weekly, label: "Weekly", percent: 95, resetsAt: nil, windowSeconds: nil)
    #expect(Snapshot(limits: [session, weekly], plan: nil, fetchedAt: now).headline(at: now) == session)
    #expect(Snapshot(limits: [weekly], plan: nil, fetchedAt: now).headline(at: now) == weekly)
}

@Test func headlineFollowsTheChosenLimit() {
    let session = Limit(kind: .session, label: "Session", percent: 20, resetsAt: nil, windowSeconds: nil)
    let weekly = Limit(kind: .weekly, label: "Weekly", percent: 40, resetsAt: nil, windowSeconds: nil)
    let scoped = Limit(kind: .weekly, label: "Fable Weekly", percent: 95, resetsAt: nil, windowSeconds: nil)
    let snapshot = Snapshot(limits: [session, weekly, scoped], plan: nil, fetchedAt: now)
    #expect(snapshot.headline(at: now, preferring: "Weekly") == weekly)
    #expect(snapshot.headline(at: now, preferring: "Fable Weekly") == scoped)
    // A choice the provider no longer reports falls back to the session.
    #expect(snapshot.headline(at: now, preferring: "Opus Weekly") == session)
    // Without a session either, it is the fullest window.
    let noSession = Snapshot(limits: [weekly, scoped], plan: nil, fetchedAt: now)
    #expect(noSession.headline(at: now, preferring: "Opus Weekly") == scoped)
}

@Test func formatting() {
    #expect(Format.duration(59) == "now")
    #expect(Format.duration(44 * 60) == "44m")
    #expect(Format.duration(3600) == "1h")
    #expect(Format.duration(6240) == "1h 44m")
    #expect(Format.duration(5 * 86400 + 7 * 3600 + 120) == "5d 7h")
    #expect(Format.percent(99.9) == "99%")
    #expect(Format.age(now.addingTimeInterval(-12.7), now: now) == "12s ago")
    #expect(Format.age(now.addingTimeInterval(-59.9), now: now) == "59s ago")
    #expect(Format.age(now.addingTimeInterval(-60), now: now) == "1m ago")
    #expect(Format.age(now.addingTimeInterval(-90), now: now) == "1m ago")
    #expect(Format.age(now.addingTimeInterval(5), now: now) == "0s ago")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let locale = Locale(identifier: "en_US")
    #expect(Format.reset(now.addingTimeInterval(6240), now: now, calendar: calendar, locale: locale).hasSuffix("· in 1h 44m"))
    #expect(Format.reset(now.addingTimeInterval(5 * 86400), now: now, calendar: calendar, locale: locale).hasPrefix("Resets Thu"))
    #expect(Format.reset(nil, now: now) == "No active window")
}

private struct StubProvider: Provider {
    let id = "stub", name = "Stub", glyph = "S"
    let usageURL = URL(string: "https://example.com")!
    func fetch() async -> Result<Snapshot, FetchFailure> { .failure(FetchFailure("unused")) }
}

@MainActor @Test func engineHonorsCooldownsAndKeepsLastGoodData() {
    let provider = StubProvider()
    let engine = Engine(providers: [provider], cacheFile: nil)
    #expect(engine.isDue(provider, manual: false, now: now))

    let snapshot = Snapshot(limits: [Limit(kind: .session, label: "Session", percent: 10, resetsAt: now.addingTimeInterval(600), windowSeconds: 18000)], plan: nil, fetchedAt: now)
    engine.apply(.success(snapshot), to: provider, now: now)
    #expect(!engine.isDue(provider, manual: false, now: now.addingTimeInterval(60)))
    #expect(engine.isDue(provider, manual: true, now: now.addingTimeInterval(60)))
    #expect(engine.isDue(provider, manual: false, now: now.addingTimeInterval(301)))

    // A 429 blocks even manual refreshes, caps absurd cooldowns, and keeps the data.
    engine.apply(.failure(FetchFailure("Rate limited", retryAfter: 99999)), to: provider, now: now)
    #expect(!engine.isDue(provider, manual: true, now: now.addingTimeInterval(3599)))
    #expect(engine.isDue(provider, manual: true, now: now.addingTimeInterval(3601)))
    #expect(engine.state(provider).snapshot == snapshot)
    #expect(engine.state(provider).lastError == "Rate limited")
}

@Test func providerStateLoadsFromOtherVersions() throws {
    let old = #"{"claude": {"nextFetchAt": 5, "throttledUntil": 9, "someFutureKey": true}, "codex": {}}"#
    let states = try JSONDecoder().decode([String: ProviderState].self, from: Data(old.utf8))
    #expect(states["claude"]?.throttledUntil == Date(timeIntervalSinceReferenceDate: 9))
    #expect(states["codex"]?.nextFetchAt == .distantPast)

    var state = ProviderState()
    state.snapshot = Snapshot(limits: [Limit(kind: .weekly, label: "Weekly", percent: 5, resetsAt: now, windowSeconds: 1)], plan: "Max", fetchedAt: now)
    state.lastError = "Offline"
    let decoded = try JSONDecoder().decode(ProviderState.self, from: JSONEncoder().encode(state))
    #expect(decoded.snapshot == state.snapshot && decoded.lastError == "Offline")
}

@MainActor @Test func engineNeverPollsFasterThanTheFloor() {
    let provider = StubProvider()
    let engine = Engine(providers: [provider], cacheFile: nil)
    // A reset that is always moments away, or already behind us mid-fetch.
    for offset in [5.0, -1.0] {
        let snapshot = Snapshot(limits: [Limit(kind: .other, label: "Odd", percent: 1, resetsAt: now.addingTimeInterval(offset), windowSeconds: 60)], plan: nil, fetchedAt: now.addingTimeInterval(-2))
        engine.apply(.success(snapshot), to: provider, now: now)
        #expect(!engine.isDue(provider, manual: false, now: now.addingTimeInterval(60)))
        #expect(engine.isDue(provider, manual: false, now: now.addingTimeInterval(121)))
    }
}

@MainActor @Test func engineRefetchesWhenAWindowRollsOver() {
    let provider = StubProvider()
    let engine = Engine(providers: [provider], cacheFile: nil)
    let snapshot = Snapshot(limits: [Limit(kind: .session, label: "Session", percent: 10, resetsAt: now.addingTimeInterval(200), windowSeconds: 18000)], plan: nil, fetchedAt: now)
    engine.apply(.success(snapshot), to: provider, now: now)
    #expect(!engine.isDue(provider, manual: false, now: now.addingTimeInterval(210)))
    #expect(engine.isDue(provider, manual: false, now: now.addingTimeInterval(216)))
}
