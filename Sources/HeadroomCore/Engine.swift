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

    public let providers: [any Provider]
    public private(set) var states: [String: ProviderState]
    public var onChange: (() -> Void)?

    private let cacheFile: URL?
    private var inFlight: Set<String> = []
    private var lastAttempt: [String: Date] = [:]

    public init(providers: [any Provider], cacheFile: URL?) {
        self.providers = providers
        self.cacheFile = cacheFile
        var states: [String: ProviderState] = [:]
        if let cacheFile, let data = try? Data(contentsOf: cacheFile),
           let saved = try? JSONDecoder().decode([String: ProviderState].self, from: data) {
            states = saved
        }
        self.states = states
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
        for provider in providers where isDue(provider, manual: manual, now: now) {
            inFlight.insert(provider.id)
            lastAttempt[provider.id] = now
            Task {
                let result = await provider.fetch()
                self.apply(result, to: provider)
            }
        }
        if !inFlight.isEmpty { onChange?() }
    }

    func isDue(_ provider: any Provider, manual: Bool, now: Date) -> Bool {
        let state = state(provider)
        if inFlight.contains(provider.id) || now < state.throttledUntil { return false }
        if manual {
            return now.timeIntervalSince(lastAttempt[provider.id] ?? .distantPast) >= Self.manualInterval
        }
        if now >= state.nextFetchAt { return true }
        // A window rolled over: the number on screen is known to be wrong.
        let fetchedAt = state.snapshot?.fetchedAt ?? .distantPast
        return state.snapshot?.limits.contains { limit in
            guard let resetsAt = limit.resetsAt else { return false }
            return resetsAt > fetchedAt && resetsAt.addingTimeInterval(15) <= now
                && now.timeIntervalSince(lastAttempt[provider.id] ?? .distantPast) >= Self.failureBackoff
        } ?? false
    }

    func apply(_ result: Result<Snapshot, FetchFailure>, to provider: any Provider, now: Date = Date()) {
        var state = state(provider)
        switch result {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.lastError = nil
            state.nextFetchAt = now.addingTimeInterval(Self.refreshInterval)
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
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }
}
