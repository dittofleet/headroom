import Foundation
import HeadroomBorrow
import HeadroomCore
import Security

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

    var releases: Releases
    var asset: String
    var bundleID: String
    var trust: Trust

    public static func github(asset: String, bundleID: String, trust: Trust) -> Updater {
        Updater(releases: .github, asset: asset, bundleID: bundleID, trust: trust)
    }

    public func latest() async throws -> Version {
        try await releases.latest()
    }

    /// Download `version`, prove it is ours, and move it over `appURL`. The
    /// running process keeps executing the old binary until it relaunches.
    public func install(_ version: Version, over appURL: URL) async throws {
        let files = FileManager.default
        // Staged on the app's own volume, so the final swap is a rename.
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        defer { try? files.removeItem(at: staging) }

        let download = try await releases.download(asset, of: version)
        // An error page or a truncated transfer, not a build.
        let size = download.count
        guard size > 20_000, size < 50_000_000 else { throw UpdateError("Download is an implausible \(size) bytes") }
        let zip = staging.appendingPathComponent("update.zip")
        try download.write(to: zip)

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
