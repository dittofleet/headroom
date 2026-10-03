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
        (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode([String: ProviderState].self, from: $0) } ?? [:]
    }

    public let providers: [any Provider]
    private var states: [String: ProviderState]
    public var onChange: (() -> Void)?

    private let cacheFile: URL?
    private var inFlight: Set<String> = []
    /// In memory only: the manual floor is about this process's behavior,
    /// and a relaunch should not inherit it.
    private var lastAttempt: [String: Date] = [:]

    public init(providers: [any Provider], cacheFile: URL?) {
        self.providers = providers
        self.cacheFile = cacheFile
        states = cacheFile.map(Self.savedStates) ?? [:]
    }

    public func state(_ provider: any Provider) -> ProviderState {
        states[provider.id] ?? ProviderState()
    }

    public func isFetching(_ provider: any Provider) -> Bool {
        inFlight.contains(provider.id)
    }

    /// Fetch whatever is due. `manual` skips the routine interval but still
    /// honors server cooldowns.
    public func refresh(manual: Bool = false, now: Date = Date()) {
        var started = false
        for provider in providers where isDue(provider, manual: manual, now: now) {
            started = true
            inFlight.insert(provider.id)
            lastAttempt[provider.id] = now
            Task {
                let result = await provider.fetch()
                self.apply(result, to: provider)
            }
        }
        if started { onChange?() }
    }

    func isDue(_ provider: any Provider, manual: Bool, now: Date) -> Bool {
        let state = state(provider)
        if inFlight.contains(provider.id) || now < state.throttledUntil { return false }
        if manual { return now.timeIntervalSince(lastAttempt[provider.id] ?? .distantPast) >= Self.manualInterval }
        return now >= state.nextFetchAt
    }

    func apply(_ result: Result<Snapshot, FetchFailure>, to provider: any Provider, now: Date = Date()) {
        var state = state(provider)
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
        states[provider.id] = state
        inFlight.remove(provider.id)
        save()
        onChange?()
    }

    private func save() {
        guard let cacheFile, let data = try? JSONEncoder().encode(states) else { return }
        // Every time: macOS may purge Caches while we run.
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }
}
