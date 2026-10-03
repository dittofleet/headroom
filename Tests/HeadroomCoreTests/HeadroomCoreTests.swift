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

@Test func claudeProfilePlan() {
    func plan(_ organization: String) -> String? {
        ClaudeProvider.parseProfile(Data(#"{"organization": \#(organization)}"#.utf8))
    }
    #expect(plan(#"{"organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x"}"#) == "Max 20x")
    #expect(plan(#"{"organization_type": "claude_pro", "rate_limit_tier": "default_claude_ai"}"#) == "Pro")
    #expect(plan(#"{"organization_type": "claude_team", "rate_limit_tier": "default_claude_max_5x"}"#) == "Team Premium")
    #expect(plan(#"{"organization_type": "claude_enterprise"}"#) == "Enterprise")
    #expect(plan(#"{"organization_type": "claude_free"}"#) == "Free")
    #expect(plan(#"{"organization_type": "api", "rate_limit_tier": "auto_prepaid_tier_1"}"#) == nil)
    #expect(ClaudeProvider.parseProfile(Data(#"{"account": {}}"#.utf8)) == nil)
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

@Test func stackedBehindHeadlineIsTheOtherWeeklies() {
    let session = Limit(kind: .session, label: "Session", percent: 20, resetsAt: nil, windowSeconds: nil)
    let weekly = Limit(kind: .weekly, label: "Weekly", percent: 40, resetsAt: nil, windowSeconds: nil)
    let scoped = Limit(kind: .weekly, label: "Fable Weekly", percent: 95, resetsAt: nil, windowSeconds: nil)
    let all = Snapshot(limits: [session, weekly, scoped], plan: nil, fetchedAt: now)
    #expect(all.stackedBehindHeadline(at: now) == [weekly, scoped])
    // Without a session the fullest weekly is in front, not behind.
    let noSession = Snapshot(limits: [weekly, scoped], plan: nil, fetchedAt: now)
    #expect(noSession.stackedBehindHeadline(at: now) == [weekly])
    let sessionOnly = Snapshot(limits: [session], plan: nil, fetchedAt: now)
    #expect(sessionOnly.stackedBehindHeadline(at: now) == [])
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
    var id = "stub", name = "Stub", glyph = "S"
    let usageURL = URL(string: "https://example.com")!
    func fetch() async -> Result<Snapshot, FetchFailure> { .failure(FetchFailure("unused")) }
}

@MainActor @Test func enginesSharingACacheKeepEachOthersState() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let claude = StubProvider(id: "claude"), codex = StubProvider(id: "codex")
    // Two processes, as the iOS app and its widgets, both started before either fetched.
    let app = Engine(providers: [claude, codex], cacheFile: file)
    let widget = Engine(providers: [claude, codex], cacheFile: file)
    widget.apply(.failure(FetchFailure("Rate limited", retryAfter: 600)), to: codex, now: now)
    let snapshot = Snapshot(limits: [Limit(kind: .session, label: "Session", percent: 10, resetsAt: nil, windowSeconds: nil)], plan: nil, fetchedAt: now)
    app.apply(.success(snapshot), to: claude, now: now)
    // The app's save kept the widget's cooldown for Codex.
    let reread = Engine(providers: [claude, codex], cacheFile: file)
    #expect(reread.state(claude).snapshot == snapshot)
    #expect(reread.state(codex).throttledUntil == now.addingTimeInterval(600))
}

@MainActor @Test func clearingKeepsAServerCooldown() {
    let provider = StubProvider()
    let engine = Engine(providers: [provider], cacheFile: nil)
    let snapshot = Snapshot(limits: [Limit(kind: .session, label: "Session", percent: 10, resetsAt: nil, windowSeconds: nil)], plan: nil, fetchedAt: now)
    engine.apply(.success(snapshot), to: provider, now: now)
    engine.apply(.failure(FetchFailure("Rate limited", retryAfter: 600)), to: provider, now: now)
    engine.clear(provider)
    #expect(engine.state(provider).snapshot == nil)
    #expect(!engine.isDue(provider, manual: true, now: now.addingTimeInterval(300)))
    #expect(engine.isDue(provider, manual: true, now: now.addingTimeInterval(601)))
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

@Test func reportReadsLimitsAsTheyStandNow() throws {
    var state = ProviderState()
    state.snapshot = Snapshot(limits: [
        Limit(kind: .session, label: "Session", percent: 80, resetsAt: now.addingTimeInterval(9000), windowSeconds: 18000),
        Limit(kind: .weekly, label: "Weekly", percent: 92, resetsAt: now.addingTimeInterval(-60), windowSeconds: 604800),
        Limit(kind: .other, label: "Odd", percent: 100, resetsAt: nil, windowSeconds: nil),
    ], plan: "Max", fetchedAt: now.addingTimeInterval(-30 * 60))
    state.lastError = "Offline"
    let report = UsageReport(state, now: now)

    #expect(report.stale && report.error == "Offline")
    #expect(report.limits[0].percentUsed == 80)
    // A window that reset after the fetch is empty, whatever was saved.
    #expect(report.limits[1].percentUsed == 0 && report.limits[1].resetsAt == nil)
    #expect(report.text(name: "Claude", now: now).hasPrefix("Claude (Max), checked 30m ago (stale), last refresh failed: Offline\n  Session: 80%, resets in 2h 30m"))
    // A provider the app has never fetched says so, with nothing in it.
    #expect(UsageReport(ProviderState(), now: now).text(name: "Codex", now: now) == "Codex, no numbers yet")

    let json = try #require(JSONSerialization.jsonObject(with: Data(report.json().utf8)) as? [String: Any])
    #expect(Set(json.keys) == ["plan", "checkedAt", "stale", "error", "limits"])
}

@Test func spentRefreshTokensAreRecognized() {
    func failure(_ status: Int, _ body: String) -> FetchFailure {
        FetchFailure("x", status: status, body: Data(body.utf8))
    }
    #expect(OAuthClient.isSpent(failure(401, "")))
    #expect(OAuthClient.isSpent(failure(400, #"{"error": "invalid_grant"}"#)))
    #expect(OAuthClient.isSpent(failure(400, #"{"error": {"code": "refresh_token_reused"}}"#)))
    #expect(!OAuthClient.isSpent(failure(400, #"{"error": "invalid_request"}"#)))
    #expect(!OAuthClient.isSpent(failure(500, #"{"error": "invalid_grant"}"#)))
}

@Test func formEncodingEscapesReservedCharacters() {
    #expect(HTTP.formEncoded([("a", "b c"), ("redirect_uri", "http://localhost:1/x?y=+")])
        == "a=b%20c&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fx%3Fy%3D%2B")
}
