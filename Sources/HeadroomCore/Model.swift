import Foundation

/// One usage window of a provider, e.g. the 5-hour session or a weekly cap.
public struct Limit: Codable, Equatable, Sendable {
    /// `weekly` is the weekly limit for every model, and `scopedWeekly` one
    /// model's own, like Fable's.
    public enum Kind: String, Codable, Sendable { case session, weekly, scopedWeekly, other }

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

    /// A weekly limit for one model, like Fable's, rather than the general one.
    public var isScoped: Bool { kind == .scopedWeekly }
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

    /// `threshold` is for where refreshes are further apart, like widgets.
    public func isStale(at now: Date, after threshold: TimeInterval = staleAfter) -> Bool {
        now.timeIntervalSince(fetchedAt) > threshold
    }

    /// When the first window rolls over, after which these numbers are
    /// known to be wrong.
    public var expiresAt: Date? {
        limits.compactMap(\.resetsAt).filter { $0 > fetchedAt }.min()
    }

    /// The one number worth showing in the menu bar: the window with the
    /// chosen label, else the session window. Falls back to the fullest
    /// window when the provider has neither. Stacked leads with its top lane.
    public func headline(at now: Date, preferring label: String? = nil) -> Limit? {
        if label == stackedChoice, let top = stacked(at: now)?.top { return top }
        return limits.first { $0.label == label }
            ?? limits.first { $0.kind == .session }
            ?? limits.max { $0.percent(at: now) < $1.percent(at: now) }
    }

    /// The weekly limit for every model.
    public var generalWeekly: Limit? {
        limits.first { $0.kind == .weekly }
    }

    /// The two lanes of a Stacked row. With a session: the session over the
    /// general weekly, or over a scoped weekly like Fable's when that one is
    /// fuller, which `replacesWeekly` flags. Without: the general weekly over
    /// the fullest scoped one.
    public func stacked(at now: Date) -> (top: Limit, bottom: Limit, replacesWeekly: Bool)? {
        let general = generalWeekly
        let scoped = limits.filter(\.isScoped).max { $0.percent(at: now) < $1.percent(at: now) }
        if let session = limits.first(where: { $0.kind == .session }) {
            // On a tie the general weekly stays.
            let bottom = [general, scoped].compactMap { $0 }.max { $0.percent(at: now) < $1.percent(at: now) }
            return bottom.map { (session, $0, $0.isScoped) }
        }
        guard let general, let scoped else { return nil }
        return (general, scoped, false)
    }

    /// What a provider could lead with: each limit, plus `stackedChoice`
    /// when there is something to stack.
    public func choices(at now: Date) -> [String] {
        limits.map(\.label) + (stacked(at: now) == nil ? [] : [stackedChoice])
    }

    /// What a stored choice shows as: `stackedChoice`, or the label of the
    /// limit leading. A Stacked choice with nothing to stack shows the plain
    /// session.
    public func shownChoice(_ choice: String?, at now: Date) -> String? {
        if choice == stackedChoice, stacked(at: now) != nil { return stackedChoice }
        return headline(at: now, preferring: choice)?.label
    }
}

/// The choice of what a provider leads with that shows two limits, one over
/// the other (see `Snapshot.stacked`), rather than a single limit. Stored in place of
/// a limit's label, on the Mac for the menu bar and on iOS for the widgets.
public let stackedChoice = "Stacked"

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
    /// Nil for a provider with no usage page on the web.
    var usageURL: URL? { get }
    func fetch() async -> Result<Snapshot, FetchFailure>
}

/// Where a limit stands: fine, needing attention, or nearly gone.
public enum Level: Sendable {
    case normal, warning, critical

    public init(percent: Double) {
        self = percent >= Limit.criticalPercent ? .critical : percent >= Limit.warningPercent ? .warning : .normal
    }
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

    /// Why the last refresh failed, and on a second line when the next is due.
    public func notice(at now: Date) -> String? {
        guard let lastError else { return nil }
        let wait = nextFetchAt.timeIntervalSince(now)
        return wait > 0 ? "\(lastError)\nRetrying in \(Format.duration(wait))" : lastError
    }

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
