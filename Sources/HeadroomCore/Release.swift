import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A release version, vX.Y.Z. The release workflow only tags that shape, so
/// anything else is not a version.
public struct Version: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init?(_ string: String) {
        let parts = string.drop { $0 == "v" }.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        (major, minor, patch) = (Int(parts[0])!, Int(parts[1])!, Int(parts[2])!)
    }

    public static func < (a: Version, b: Version) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "v\(major).\(minor).\(patch)" }
}

public struct UpdateError: Error, CustomStringConvertible, Sendable {
    public let description: String
    package init(_ description: String) { self.description = description }
}

/// headroom's releases on GitHub, which the app and the Linux command both
/// update themselves from.
public struct Releases: Sendable {
    var latestURL: URL
    var assetURL: @Sendable (Version, String) -> URL

    public static let github = Releases(repo: "dittofleet/headroom")

    init(repo: String) {
        latestURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        assetURL = { URL(string: "https://github.com/\(repo)/releases/download/\($0)/\($1)")! }
    }

    /// For tests, which publish to files.
    package init(latestURL: URL, assetURL: @escaping @Sendable (Version, String) -> URL) {
        self.latestURL = latestURL
        self.assetURL = assetURL
    }

    // Separate from the providers' session: release assets redirect to a
    // CDN, and nothing here carries a token.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 5 * 60
        return URLSession(configuration: config)
    }()

    /// `timeout` is how long it may go without hearing back.
    public func latest(timeout: TimeInterval = 30) async throws -> Version {
        var request = URLRequest(url: latestURL, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try await Self.fetch(request, what: "checking for updates")
        guard let tag = Parse.object(data)?["tag_name"] as? String, let version = Version(tag) else {
            throw UpdateError("Latest release has no vX.Y.Z tag")
        }
        return version
    }

    public func download(_ asset: String, of version: Version, timeout: TimeInterval = 30) async throws -> Data {
        try await Self.fetch(URLRequest(url: assetURL(version, asset), timeoutInterval: timeout), what: "downloading \(version)")
    }

    private static func fetch(_ request: URLRequest, what: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("HTTP \(http.statusCode) \(what)")
        }
        return data
    }
}
