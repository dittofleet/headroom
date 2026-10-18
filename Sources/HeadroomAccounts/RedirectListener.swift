import Foundation
import HeadroomCore
import Network

/// The listener on localhost that a sign-in's redirect comes back to.
/// Loopback only, so nothing off the device can reach it.
@MainActor
final class RedirectListener {
    private var listener: NWListener?
    /// The HTTP response to a request, by its target, such as
    /// "/callback?code=…&state=…". Nil answers 404, as for a favicon.
    private let respond: (String) -> String?

    init(respond: @escaping (String) -> String?) {
        self.respond = respond
    }

    /// Starts on `port`, or any free one, and returns the port it got.
    func start(on port: UInt16?) async -> Result<UInt16, FetchFailure> {
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

    /// Frees the port now, for a sign-in started right after.
    func cancel() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, received: Data())
    }

    /// Reads until the request line is in, which can take more than one
    /// packet, then answers it.
    private func read(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                let received = received + (data ?? Data())
                let lineEnd = received.range(of: Data("\r\n".utf8))
                if lineEnd == nil, !isComplete, error == nil, received.count < 64 * 1024 {
                    self?.read(connection, received: received)
                    return
                }
                // "GET /callback?code=…&state=… HTTP/1.1"
                let requestLine = String(decoding: received[..<(lineEnd?.lowerBound ?? received.endIndex)], as: UTF8.self)
                let parts = requestLine.split(separator: " ")
                let response = parts.count >= 2 ? self?.respond(String(parts[1])) : nil
                let sent = response ?? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(sent.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
