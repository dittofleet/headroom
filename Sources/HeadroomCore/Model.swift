import Foundation

/// One usage window of a provider, e.g. the 5-hour session or a weekly cap.
public struct Limit: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case session, weekly, other }

    /// Where a limit starts to need attention, and where it is nearly gone.
    public static let warningPercent: Double = 75
    public static let criticalPercent: Double = 90

    public var kind: Kind
    public var label: String
    /// Percent used as of the fetch, 0...100.
    public var percent: Double
    public var resetsAt: Date?
    public var windowSeconds: Double?

    public init(kind: Kind, label: String, percent: Double, resetsAt: Date?, windowSeconds: Double?) {
        self.kind = kind
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    /// A window that has reset since the fetch is empty, whatever we last saw.
    public func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(percent, 0), 100)
    }

    /// How far through the window we are, 0...1. Usage above this line is
    /// burning faster than the window refills.
    public func elapsedFraction(at now: Date) -> Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0, resetsAt > now else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / windowSeconds, 0), 1)
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var limits: [Limit]
    public var plan: String?
    public var fetchedAt: Date

    public init(limits: [Limit], plan: String?, fetchedAt: Date) {
        self.limits = limits
        self.plan = plan
        self.fetchedAt = fetchedAt
    }

    /// Older than this, numbers are still the best we have but not to be
    /// trusted at a glance.
    public static let staleAfter: TimeInterval = 20 * 60

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > Self.staleAfter
    }

    /// When the first window rolls over, after which these numbers are
    /// known to be wrong.
    public var expiresAt: Date? {
        limits.compactMap(\.resetsAt).filter { $0 > fetchedAt }.min()
    }

    /// The one number worth showing in the menu bar: the window with the
    /// chosen label, else the session window. Falls back to the fullest
    /// window when the provider has neither.
    public func headline(at now: Date, preferring label: String? = nil) -> Limit? {
        limits.first { $0.label == label }
            ?? limits.first { $0.kind == .session }
            ?? limits.max { $0.percent(at: now) < $1.percent(at: now) }
    }
}

public struct FetchFailure: Error, Sendable {
    public var message: String
    /// Server-mandated cooldown. Never fetch before it passes.
    public var retryAfter: TimeInterval?
    /// HTTP status and body, when the server answered.
    public var status: Int?
    var body: Data?

    public init(_ message: String, retryAfter: TimeInterval? = nil, status: Int? = nil, body: Data? = nil) {
        self.message = message
        self.retryAfter = retryAfter
        self.status = status
        self.body = body
    }
}

public protocol Provider: Sendable {
    var id: String { get }
    var name: String { get }
    /// Single letter shown next to the bar in the menu bar.
    var glyph: String { get }
    var usageURL: URL { get }
    func fetch() async -> Result<Snapshot, FetchFailure>
}

public struct ProviderState: Codable, Sendable {
    public var snapshot: Snapshot?
    public var lastError: String?
    /// Next routine refresh. A manual refresh may run earlier.
    public var nextFetchAt: Date = .distantPast
    /// Server-mandated cooldown. Unlike `nextFetchAt`, this also blocks
    /// manual refreshes.
    public var throttledUntil: Date = .distantPast

    public init() {}

    /// Tolerates missing keys, so a cache written by another version still
    /// loads: losing it would also lose a server cooldown.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try? values.decodeIfPresent(Snapshot.self, forKey: .snapshot)
        lastError = try? values.decodeIfPresent(String.self, forKey: .lastError)
        nextFetchAt = (try? values.decodeIfPresent(Date.self, forKey: .nextFetchAt)) ?? .distantPast
        throttledUntil = (try? values.decodeIfPresent(Date.self, forKey: .throttledUntil)) ?? .distantPast
    }
}
