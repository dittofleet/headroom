import AuthenticationServices
import HeadroomCore
import Network
import UIKit

/// Signs in the way the CLIs do: the provider's page in a browser sheet,
/// which redirects to a listener on localhost. The sheet is part of the
/// app while it is up, so the app is in front to answer.
@MainActor
final class SignInFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Where the listener sends the sheet once it has the code, which is
    /// what closes the sheet.
    private static let callbackScheme = "headroom"

    private var listener: NWListener?
    private var session: ASWebAuthenticationSession?
    private var attempt: OAuthSignIn?
    private var waiting: CheckedContinuation<Result<String, FetchFailure>?, Never>?

    /// Nil when the sheet was dismissed before signing in.
    func run(_ client: OAuthClient) async -> Result<AccountTokens, FetchFailure>? {
        defer {
            listener?.cancel()
            session?.cancel()
        }
        let port: UInt16
        switch await listen(on: client.port) {
        case .success(let bound): port = bound
        case .failure(let failure): return .failure(failure)
        }
        let attempt = OAuthSignIn(client: client, port: port)
        self.attempt = attempt

        let code = await withCheckedContinuation { continuation in
            waiting = continuation
            let session = ASWebAuthenticationSession(url: attempt.authorizeURL, callback: .customScheme(Self.callbackScheme)) { [weak self] _, error in
                MainActor.assumeIsolated {
                    // The listener has normally answered by the time the
                    // sheet follows its redirect here.
                    self?.finish(error == nil ? .failure(FetchFailure("Sign-in did not return a code")) : nil)
                }
            }
            // Shares Safari's cookies, so being signed in there already
            // leaves only the consent page.
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                finish(.failure(FetchFailure("Could not open the sign-in page")))
            }
        }
        switch code {
        case .success(let code): return await attempt.exchange(code)
        case .failure(let failure): return .failure(failure)
        case nil: return nil
        }
    }

    private func finish(_ result: Result<String, FetchFailure>?) {
        waiting?.resume(returning: result)
        waiting = nil
    }

    /// Starts the redirect listener, on `port` or any free one, and returns
    /// the port it got. Loopback only, so nothing off the phone can reach it.
    private func listen(on port: UInt16?) async -> Result<UInt16, FetchFailure> {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any) else {
            return .failure(FetchFailure("Could not listen for the sign-in redirect"))
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection) }
        }
        return await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port.map { .success($0.rawValue) } ?? .failure(FetchFailure("No port to listen on")))
                // Waiting is for a port it can't have yet, which for a
                // sign-in under way is as good as failed.
                case .failed, .cancelled, .waiting:
                    listener.stateUpdateHandler = nil
                    let busy = port.map { "Port \($0) is busy, so the sign-in redirect can't be received" }
                    continuation.resume(returning: .failure(FetchFailure(busy ?? "Could not listen for the sign-in redirect")))
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    /// Answers one request: the redirect with the code, or anything else
    /// the browser asks for while it is there.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                // "GET /callback?code=…&state=… HTTP/1.1"
                let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let parts = requestLine.split(separator: " ")
                let result = parts.count >= 2 ? self?.attempt?.code(fromRequestTarget: String(parts[1])) : nil
                let response: String
                if let result {
                    response = "HTTP/1.1 302 Found\r\nLocation: \(Self.callbackScheme)://signed-in\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    self?.finish(result)
                } else {
                    response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
