import Foundation

enum HTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Requests carry a bearer token, and URLSession would replay it to
    /// wherever a redirect points. Neither endpoint redirects, so refuse:
    /// the 3xx then surfaces as an ordinary HTTP failure.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// GET returning the body on 200, or a failure that carries the server's
    /// retry-after when it sent one. `authHint` is the message for a 401 or
    /// 403.
    static func get(_ url: URL, headers: [String: String], authHint: String) async -> Result<Data, FetchFailure> {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return await send(request, authHint: authHint)
    }

    /// POST a JSON body, with the same outcomes as `get`.
    static func post(_ url: URL, json: [String: Any], authHint: String) async -> Result<Data, FetchFailure> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        return await send(request, authHint: authHint)
    }

    private static func send(_ request: URLRequest, authHint: String) async -> Result<Data, FetchFailure> {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure(FetchFailure("Offline")) }
        let status = http.statusCode
        switch status {
        case 200:
            return .success(data)
        case 401, 403:
            return .failure(FetchFailure(authHint, status: status))
        default:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            let what = status == 429 ? "Rate limited" : "HTTP \(status)"
            return .failure(FetchFailure(what, retryAfter: retryAfter.flatMap { $0 > 0 ? $0 : nil }, status: status))
        }
    }
}

enum Parse {
    private static let iso = ISO8601DateFormatter()

    /// ISO 8601 with any number of fractional digits, which
    /// ISO8601DateFormatter does not reliably accept.
    static func isoDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: trimmed)
    }

    static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func number(_ value: Any?) -> Double? {
        // NSNumber also wraps JSON booleans; a bool is never a percentage.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
