import Foundation
import Testing
@testable import HeadroomCore

@Test func versionsParseAndOrder() throws {
    #expect(Version("v1.2.3")?.description == "v1.2.3")
    #expect(Version("1.2.3") == Version("v1.2.3"))
    for bad in ["", "dev", "v1.2", "v1.2.3.4", "v1.2.x", "v1..3", "v-1.2.3", "v1.2.3-beta", "v１.2.3", "v1.2.99999999999999999999"] {
        #expect(Version(bad) == nil, "\(bad)")
    }
    let (a, b, c) = try (#require(Version("v0.9.9")), #require(Version("v0.10.0")), #require(Version("v1.0.0")))
    #expect(a < b && b < c && !(b < a))
}

@Test func trustOnlyAcceptsRealTeamIDs() {
    #expect(Updater.Trust.team("ABCDE12345") != nil)
    for bad in ["", "short", "ABCDE12345X", "ABCDE1234\"", "ABCDE 2345", "\" or true"] {
        #expect(Updater.Trust.team(bad) == nil, "\(bad)")
    }
}

/// A fake release: an app bundle zipped the way the workflow zips it, plus
/// the API document that points at it.
private struct FakeRelease {
    let root: URL
    let installed: URL

    init(installedVersion: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-test-\(UUID().uuidString)")
        installed = root.appendingPathComponent("Applications/Headroom.app")
        try Self.writeApp(at: installed, bundleID: "test.headroom", version: installedVersion, payload: "old")
    }

    static func writeApp(at url: URL, bundleID: String, version: String, payload: String) throws {
        let macos = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        // Padded past the updater's "this is not a build" floor.
        try Data((payload + String(repeating: "\0", count: 100_000)).utf8).write(to: macos.appendingPathComponent("Headroom"))
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        try info.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    /// Publishes a zip whose bundle claims `bundleVersion`, under `tag`.
    func publish(tag: String, bundleVersion: String, bundleID: String = "test.headroom") async throws -> Updater {
        let build = root.appendingPathComponent("build-\(tag)/Headroom.app")
        try Self.writeApp(at: build, bundleID: bundleID, version: bundleVersion, payload: "new-\(tag)")
        let zip = root.appendingPathComponent("\(tag).zip")
        // Random bytes would not compress below the size floor; zeros do,
        // so store uncompressed the way the floor expects a real build.
        _ = await Subprocess.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--zlibCompressionLevel", "0", build.path, zip.path])
        let latest = root.appendingPathComponent("latest.json")
        try Data(#"{"tag_name": "\#(tag)"}"#.utf8).write(to: latest)
        return Updater(latestURL: latest, assetURL: { [root] in root.appendingPathComponent("\($0).zip") }, bundleID: "test.headroom", trust: .unverified)
    }

    var payload: String {
        let data = (try? Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/Headroom"))) ?? Data()
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func installsANewerRelease() async throws {
    let release = try FakeRelease(installedVersion: "0.1.0")
    defer { release.cleanUp() }
    let updater = try await release.publish(tag: "v0.2.0", bundleVersion: "0.2.0")

    let latest = try await updater.latest()
    #expect(latest == Version("v0.2.0"))
    try await updater.install(latest, over: release.installed)
    #expect(release.payload == "new-v0.2.0")
    let info = NSDictionary(contentsOf: release.installed.appendingPathComponent("Contents/Info.plist"))
    #expect(info?["CFBundleShortVersionString"] as? String == "0.2.0")
}

@Test func refusesADownloadThatIsNotWhatWasAskedFor() async throws {
    let release = try FakeRelease(installedVersion: "0.1.0")
    defer { release.cleanUp() }

    // Tagged as new, but the bundle inside is an old build: a downgrade.
    var updater = try await release.publish(tag: "v0.3.0", bundleVersion: "0.0.1")
    await #expect(throws: UpdateError.self) { try await updater.install(#require(Version("v0.3.0")), over: release.installed) }

    // Right version, wrong app.
    updater = try await release.publish(tag: "v0.4.0", bundleVersion: "0.4.0", bundleID: "com.evil.app")
    await #expect(throws: UpdateError.self) { try await updater.install(#require(Version("v0.4.0")), over: release.installed) }

    // Not a zip at all.
    try Data(repeating: 7, count: 60_000).write(to: release.root.appendingPathComponent("v0.5.0.zip"))
    await #expect(throws: UpdateError.self) { try await updater.install(#require(Version("v0.5.0")), over: release.installed) }

    // An error page instead of a build.
    try Data("Not Found".utf8).write(to: release.root.appendingPathComponent("v0.6.0.zip"))
    await #expect(throws: UpdateError.self) { try await updater.install(#require(Version("v0.6.0")), over: release.installed) }

    #expect(release.payload == "old")
}

@Test func refusesAnUnsignedBuildWhenATeamIsRequired() async throws {
    let release = try FakeRelease(installedVersion: "0.1.0")
    defer { release.cleanUp() }
    var updater = try await release.publish(tag: "v0.2.0", bundleVersion: "0.2.0")
    updater.trust = try #require(Updater.Trust.team("ABCDE12345"))

    await #expect(throws: UpdateError.self) { try await updater.install(#require(Version("v0.2.0")), over: release.installed) }
    #expect(release.payload == "old")
}

@Test func signatureRequirementAcceptsARealNotarizedApp() throws {
    // Proves the requirement string means what it says, against whatever
    // Developer ID app this machine happens to have. Skipped when none.
    let apps = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? []
    for app in apps where app.pathExtension == "app" {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              let trust = Updater.Trust.team(team), let requirement = trust.requirement,
              (try? Updater.checkSignature(of: app, satisfies: requirement)) != nil
        else { continue }
        // Same app, someone else's team: must fail.
        let other = try #require(Updater.Trust.team(team == "ABCDE12345" ? "ZZZZZ99999" : "ABCDE12345")?.requirement)
        #expect(throws: UpdateError.self) { try Updater.checkSignature(of: app, satisfies: other) }
        return
    }
    print("no notarized Developer ID app in /Applications; signature acceptance not exercised")
}
