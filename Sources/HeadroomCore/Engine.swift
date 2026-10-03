import Foundation

/// Decides when each provider is fetched and keeps the last good numbers.
///
/// Both endpoints are unofficial and the Claude one has a very small quota
/// (polling it every minute earns hour-long 429s), so the rules are: refresh
/// sparingly, never inside a server-sent retry-after, and keep showing the
/// last snapshot when a refresh fails.
@MainActor
public final class Engine {
    public static let refreshInterval: TimeInterval = 5 * 60
    /// Floor between fetches that a manual refresh can't go below.
    public static let manualInterval: TimeInterval = 30
    static let failureBackoff: TimeInterval = 2 * 60
    static let maxRetryAfter: TimeInterval = 60 * 60
    static let rolloverGrace: TimeInterval = 15

    /// Where the app keeps its state, and where the CLI reads it.
    nonisolated public static let defaultCacheFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("headroom/state.json")

    /// The saved state per provider id. Empty when there is none yet.
    nonisolated public static func savedStates(at cacheFile: URL) -> [String: ProviderState] {
        load(cacheFile) ?? [:]
    }

    /// Nil when nothing readable is saved, so callers can keep what they have.
    nonisolated private static func load(_ cacheFile: URL?) -> [String: ProviderState]? {
        guard let cacheFile, let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONDecoder().decode([String: ProviderState].self, from: data)
    }

    public let providers: [any Provider]
    private var states: [String: ProviderState]
    public var onChange: (() -> Void)?

    private let cacheFile: URL?
    /// The fetch under way for each provider, so a refresh that wants to
    /// wait for the numbers can await one it didn't start.
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// In memory only: the manual floor is about this process's behavior,
    /// and a relaunch should not inherit it.
    private var lastAttempt: [String: Date] = [:]

    public init(providers: [any Provider], cacheFile: URL?) {
        self.providers = providers
        self.cacheFile = cacheFile
        states = Self.load(cacheFile) ?? [:]
    }

    /// Picks up what another process sharing the cache file has saved since,
    /// such as the iOS app and its widgets.
    public func reload() {
        guard let saved = Self.load(cacheFile) else { return }
        states = saved
        onChange?()
    }

    /// Changes one provider's state and saves, on top of whatever another
    /// process sharing the cache file saved since: saving all of ours
    /// would put back its old numbers and cooldowns for the others.
    private func update(_ id: String, _ change: (inout ProviderState?) -> Void) {
        if let saved = Self.load(cacheFile) { states = saved }
        change(&states[id])
        save()
        onChange?()
    }

    public func state(_ provider: any Provider) -> ProviderState {
        states[provider.id] ?? ProviderState()
    }

    public func isFetching(_ provider: any Provider) -> Bool {
        inFlight[provider.id] != nil
    }

    /// Forgets a provider's numbers, as after a sign-in or sign-out: they
    /// belonged to a session that is gone, and so does a fetch under way.
    /// A server cooldown stands, since it may be the account's.
    public func clear(_ provider: any Provider) {
        inFlight.removeValue(forKey: provider.id)?.cancel()
        lastAttempt[provider.id] = nil
        update(provider.id) { state in
            var cleared = ProviderState()
            cleared.throttledUntil = state?.throttledUntil ?? .distantPast
            cleared.nextFetchAt = cleared.throttledUntil
            state = cleared
        }
    }

    /// Fetch whatever is due. `manual` skips the routine interval but still
    /// honors server cooldowns.
    public func refresh(manual: Bool = false, now: Date = Date()) {
        start(manual: manual, now: now)
    }

    /// `refresh`, returning once every fetch under way has landed, including
    /// ones started earlier. For a process that may be suspended as soon as
    /// it returns, like a widget's. Returns whether it started any.
    @discardableResult
    public func refreshAndWait(manual: Bool = false, now: Date = Date()) async -> Bool {
        let started = start(manual: manual, now: now)
        for task in Array(inFlight.values) {
            await task.value
        }
        return started
    }

    /// Starts whatever is due, and returns whether there was any.
    @discardableResult
    private func start(manual: Bool, now: Date) -> Bool {
        let due = providers.filter { isDue($0, manual: manual, now: now) }
        for provider in due {
            lastAttempt[provider.id] = now
            inFlight[provider.id] = Task {
                let result = await provider.fetch()
                // Cleared while fetching: the result is the old session's.
                guard !Task.isCancelled else { return }
                self.apply(result, to: provider)
            }
        }
        if !due.isEmpty { onChange?() }
        return !due.isEmpty
    }

    func isDue(_ provider: any Provider, manual: Bool, now: Date) -> Bool {
        let state = state(provider)
        if inFlight[provider.id] != nil || now < state.throttledUntil { return false }
        if manual { return now.timeIntervalSince(lastAttempt[provider.id] ?? .distantPast) >= Self.manualInterval }
        return now >= state.nextFetchAt
    }

    func apply(_ result: Result<Snapshot, FetchFailure>, to provider: any Provider, now: Date = Date()) {
        inFlight[provider.id] = nil
        update(provider.id) { stored in
            var state = stored ?? ProviderState()
            switch result {
            case .success(let snapshot):
                state.snapshot = snapshot
                state.lastError = nil
                // Refetch early when a window rolls over: past that point the
                // number on screen is known to be wrong. Floored, so a reset
                // that is always moments away can't turn into per-minute polling.
                let rollover = snapshot.expiresAt?.addingTimeInterval(Self.rolloverGrace) ?? .distantFuture
                state.nextFetchAt = max(
                    now.addingTimeInterval(Self.failureBackoff),
                    min(now.addingTimeInterval(Self.refreshInterval), rollover))
            case .failure(let failure):
                state.lastError = failure.message
                if let retryAfter = failure.retryAfter {
                    state.throttledUntil = now.addingTimeInterval(min(retryAfter, Self.maxRetryAfter))
                    state.nextFetchAt = state.throttledUntil
                } else {
                    state.nextFetchAt = now.addingTimeInterval(Self.failureBackoff)
                }
            }
            stored = state
        }
    }

    private func save() {
        guard let cacheFile, let data = try? JSONEncoder().encode(states) else { return }
        // Every time: macOS may purge Caches while we run.
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }
}
