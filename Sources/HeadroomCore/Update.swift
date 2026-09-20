import Foundation
import Security

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
    init(_ description: String) { self.description = description }
}

/// Finds the latest release and swaps it over the installed app.
///
/// This app reads auth tokens, so an update is held to a higher bar than
/// "whatever the download URL returned": it must be signed by the same
/// Developer ID team as the running app, notarized, carry our bundle id,
/// and be exactly the version asked for.
public struct Updater: Sendable {
    /// What a downloaded app must prove before it may replace this one.
    public struct Trust: Sendable {
        let requirement: String?

        /// Signed by this Developer ID team and notarized by Apple.
        public static func team(_ teamID: String) -> Trust? {
            // The id is spliced into a requirement string; team ids are
            // exactly ten alphanumerics, so refuse anything else.
            guard teamID.count == 10, teamID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return Trust(requirement: "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and notarized")
        }

        /// No signature check. Internal, so only tests can ask for it.
        static let unverified = Trust(requirement: nil)
    }

    var latestURL: URL
    var assetURL: @Sendable (Version) -> URL
    var bundleID: String
    var trust: Trust

    public static func github(repo: String, asset: String, bundleID: String, trust: Trust) -> Updater {
        Updater(
            latestURL: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
            assetURL: { URL(string: "https://github.com/\(repo)/releases/download/\($0)/\(asset)")! },
            bundleID: bundleID,
            trust: trust
        )
    }

    // Separate from the providers' session: release assets redirect to a
    // CDN, and nothing here carries a token.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 5 * 60
        return URLSession(configuration: config)
    }()

    public func latest() async throws -> Version {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("HTTP \(http.statusCode) checking for updates")
        }
        guard let tag = Parse.object(data)?["tag_name"] as? String, let version = Version(tag) else {
            throw UpdateError("Latest release has no vX.Y.Z tag")
        }
        return version
    }

    /// Download `version`, prove it is ours, and move it over `appURL`. The
    /// running process keeps executing the old binary until it relaunches.
    public func install(_ version: Version, over appURL: URL) async throws {
        let files = FileManager.default
        // Staged on the app's own volume, so the final swap is a rename.
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        defer { try? files.removeItem(at: staging) }

        let (downloaded, response) = try await Self.session.download(from: assetURL(version))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("HTTP \(http.statusCode) downloading \(version)")
        }
        let zip = staging.appendingPathComponent("update.zip")
        try files.moveItem(at: downloaded, to: zip)
        // An error page or a truncated transfer, not a build.
        let size = (try files.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        guard size > 20_000, size < 50_000_000 else { throw UpdateError("Download is an implausible \(size) bytes") }

        let unpacked = staging.appendingPathComponent("unpacked")
        guard await Subprocess.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 60) != nil else {
            throw UpdateError("Could not unpack the download")
        }
        let newApp = unpacked.appendingPathComponent(appURL.lastPathComponent)
        try verify(newApp, is: version)

        _ = try files.replaceItemAt(appURL, withItemAt: newApp)
    }

    func verify(_ app: URL, is version: Version) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError("Download is not an app")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError("Download is a different app")
        }
        // Also what stops a downgrade: the caller only asks for newer
        // versions, and the bundle has to be the one it asked for.
        guard (info["CFBundleShortVersionString"] as? String).flatMap(Version.init) == version else {
            throw UpdateError("Download is not \(version)")
        }
        if let requirement = trust.requirement { try Self.checkSignature(of: app, satisfies: requirement) }
    }

    static func checkSignature(of app: URL, satisfies requirement: String) throws {
        var code: SecStaticCode?
        var required: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess, let required
        else { throw UpdateError("Could not read the download's signature") }

        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, required)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw UpdateError("Download failed signature check: \(reason)")
        }
    }

    /// The Developer ID team that signed the running app, or nil for an
    /// ad-hoc (built from source) copy.
    public static func ownTeamID() -> String? {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
