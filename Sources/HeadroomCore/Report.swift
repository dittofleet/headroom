import Foundation

/// What the CLI prints for one provider: the numbers the app last saved, as
/// they stand now. It never fetches, so any number of agents can ask
/// without touching the endpoint's small quota.
public struct UsageReport: Encodable, Sendable {
    public struct LimitUsage: Encodable, Sendable {
        public var label: String
        public var percentUsed: Int
        public var resetsAt: Date?
    }

    public var plan: String?
    public var checkedAt: Date?
    /// Over 20 minutes old: the app is not running or cannot refresh.
    public var stale: Bool
    /// Why the last refresh failed. The numbers are the last good ones.
    public var error: String?
    public var limits: [LimitUsage]

    public init(_ state: ProviderState, now: Date) {
        let snapshot = state.snapshot
        plan = snapshot?.plan
        checkedAt = snapshot?.fetchedAt
        stale = snapshot?.isStale(at: now) ?? true
        error = state.lastError
        limits = snapshot?.limits.map { LimitUsage($0, now: now) } ?? []
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// "Claude (Max), checked 2m ago", then a line per limit.
    public func text(name: String, now: Date) -> String {
        var header = name + (plan.map { " (\($0))" } ?? "")
        header += checkedAt.map { ", checked " + Format.age($0, now: now) + (stale ? " (stale)" : "") } ?? ", no numbers yet"
        if let error { header += ", last refresh failed: " + error }
        let lines = limits.map { limit in
            "  \(limit.label): \(limit.percentUsed)%" + (limit.resetsAt.map { ", resets in " + Format.duration($0.timeIntervalSince(now)) } ?? "")
        }
        return ([header] + lines).joined(separator: "\n")
    }
}

extension UsageReport.LimitUsage {
    init(_ limit: Limit, now: Date) {
        label = limit.label
        percentUsed = Format.wholePercent(limit.percent(at: now))
        resetsAt = limit.resetsAt.flatMap { $0 > now ? $0 : nil }
    }
}
