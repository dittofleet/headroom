import Foundation
import HeadroomCore

/// One sign-in the way the CLIs do it: a listener on localhost, the
/// provider's page, and the code its redirect brings back traded for
/// tokens. Each platform opens the page its own way and says what the
/// redirect gets back.
@MainActor
public final class LoopbackSignIn {
    /// The HTTP response to the redirect, by how it went.
    private let response: (Result<String, FetchFailure>) -> String
    private var listener: RedirectListener?
    private var attempt: OAuthSignIn?
    private var waiting: CheckedContinuation<Result<String, FetchFailure>?, Never>?
    private var cancelled = false

    public init(response: @escaping (Result<String, FetchFailure>) -> String) {
        self.response = response
    }

    /// Nil when cancelled or dismissed. `open` shows the page, and it, or
    /// anything else, can end the wait early with `finish`.
    public func run(_ client: OAuthClient, open: (URL) -> Void) async -> Result<AccountTokens, FetchFailure>? {
        let listener = RedirectListener { [weak self] target in self?.respond(to: target) }
        self.listener = listener
        defer { listener.cancel() }
        let started = await listener.start(on: client.port)
        guard !cancelled else { return nil }
        let port: UInt16
        switch started {
        case .success(let bound): port = bound
        case .failure(let failure): return .failure(failure)
        }
        let attempt = OAuthSignIn(client: client, port: port)
        self.attempt = attempt

        let code = await withCheckedContinuation { continuation in
            waiting = continuation
            open(attempt.authorizeURL)
        }
        switch code {
        case .success(let code):
            let tokens = await attempt.exchange(code)
            return cancelled ? nil : tokens
        case .failure(let failure): return .failure(failure)
        case nil: return nil
        }
    }

    /// Ends the wait for the redirect: with its code, a failure, or nil
    /// when the page was dismissed.
    public func finish(_ result: Result<String, FetchFailure>?) {
        waiting?.resume(returning: result)
        waiting = nil
    }

    /// Stops it at any point, and frees the port for a sign-in started
    /// right after.
    public func cancel() {
        cancelled = true
        listener?.cancel()
        finish(nil)
    }

    /// Nil for anything but this attempt's redirect, such as a favicon.
    private func respond(to target: String) -> String? {
        guard let result = attempt?.code(fromRequestTarget: target) else { return nil }
        finish(result)
        return response(result)
    }
}
