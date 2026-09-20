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
    #expect(snapshot.limits.map(\.label) == ["Session", "Weekly", "Weekly · Fable"])
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
    #expect(snapshot.limits.map(\.label) == ["Session", "Weekly", "Code review · Weekly"])
    #expect(snapshot.limits.map(\.kind) == [.session, .weekly, .other])
    #expect(snapshot.limits[1].resetsAt == Date(timeIntervalSince1970: 1_789_925_529))
}

@Test func claudeCredentials() throws {
    let creds = try #require(ClaudeProvider.parseCredentials(Data(
        #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1789891084074, "subscriptionType": "max"}}"#.utf8)))
    #expect(creds.plan == "Max")
    #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_789_891_084.074))
    #expect(ClaudeProvider.parseCredentials(Data(#"{"claudeAiOauth": {}}"#.utf8)) == nil)
}

@Test func limitRollsOverAfterReset() {
    let limit = Limit(kind: .session, label: "Session", percent: 80, resetsAt: now.addingTimeInterval(3600), windowSeconds: 18000)
    #expect(limit.percent(at: now) == 80)
    #expect(limit.percent(at: now.addingTimeInterval(3601)) == 0)
    #expect(limit.elapsedFraction(at: now) == 0.8)
    #expect(limit.elapsedFraction(at: now.addingTimeInterval(3601)) == nil)
}

@Test func headlinePrefersSessionUntilSomethingIsNearlyOut() {
    let session = Limit(kind: .session, label: "Session", percent: 20, resetsAt: nil, windowSeconds: nil)
    var weekly = Limit(kind: .weekly, label: "Weekly", percent: 85, resetsAt: nil, windowSeconds: nil)
    #expect(Snapshot(limits: [session, weekly], plan: nil, fetchedAt: now).headline(at: now) == session)
    weekly.percent = 95
    #expect(Snapshot(limits: [session, weekly], plan: nil, fetchedAt: now).headline(at: now) == weekly)
}

@Test func formatting() {
    #expect(Format.duration(59) == "now")
    #expect(Format.duration(44 * 60) == "44m")
    #expect(Format.duration(3600) == "1h")
    #expect(Format.duration(6240) == "1h 44m")
    #expect(Format.duration(5 * 86400 + 7 * 3600 + 120) == "5d 7h")
    #expect(Format.percent(99.9) == "99%")

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

@MainActor @Test func engineRefetchesWhenAWindowRollsOver() {
    let provider = StubProvider()
    let engine = Engine(providers: [provider], cacheFile: nil)
    let snapshot = Snapshot(limits: [Limit(kind: .session, label: "Session", percent: 10, resetsAt: now.addingTimeInterval(100), windowSeconds: 18000)], plan: nil, fetchedAt: now)
    engine.apply(.success(snapshot), to: provider, now: now)
    #expect(!engine.isDue(provider, manual: false, now: now.addingTimeInterval(90)))
    #expect(engine.isDue(provider, manual: false, now: now.addingTimeInterval(120)))
}
