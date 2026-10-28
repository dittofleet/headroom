#if os(Linux)
import Foundation
import HeadroomCore

// The command keeps itself current the way every dittofleet CLI does (see
// go-cli-kit): `headroom update`, and after a command, at most once a day,
// a check that installs a newer release. Only on Linux: on a Mac the
// command is part of the app, which updates itself.

enum SelfUpdate {
    #if arch(arm64)
    static let asset = "headroom-linux-arm64"
    #else
    static let asset = "headroom-linux-x64"
    #endif

    /// ~/.local/share/headroom, for what isn't the usage numbers.
    static let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("headroom")

    static var binary: URL? { Bundle.main.executableURL?.resolvingSymlinksInPath() }

    /// `headroom update`.
    static func run() async {
        guard let current = Version(version) else {
            fail("cannot update a dev build. Either run from source, or install the released binary.")
        }
        print("Checking for updates...")
        do {
            let latest = try await Releases.github.latest()
            // Only ever forward: if the latest release is older than this
            // build, because a release was pulled, staying put beats a
            // silent downgrade.
            guard current < latest else {
                print("Already at latest version: \(current)")
                return
            }
            print("Downloading \(latest)...")
            try await install(latest, timeout: 5 * 60)
            print("Updated \(current) -> \(latest)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// After a command: at most once a day, asks for a newer release and
    /// installs it, saying so on stderr, or how to update if that fails.
    /// Never fails the command. Skipped for a dev build, in CI, with
    /// HEADROOM_NO_UPDATE_CHECK set, and when stderr is not a terminal, so
    /// agents and scripts never wait on it.
    static func checkDaily(now: Date = Date()) async {
        let environment = ProcessInfo.processInfo.environment
        guard let current = Version(version), environment["CI"] == nil, environment["HEADROOM_NO_UPDATE_CHECK"] == nil,
              isatty(STDERR_FILENO) == 1
        else { return }

        let saved = Check.load()
        // Newer than this binary only when installing it failed before.
        var latest = saved.flatMap { Version($0.latestVersion) }
        if saved.map({ now.timeIntervalSince($0.lastCheck) >= 24 * 60 * 60 }) ?? true {
            let fetched = try? await Releases.github.latest(timeout: 2)
            // Recorded even when offline, so an unreachable network costs
            // one timeout a day rather than one on every command. A release
            // found before is then only hinted: a download would time out too.
            latest = fetched ?? latest
            Check(lastCheck: now, latestVersion: (latest ?? current).description).save()
            // Short, as the user is waiting on a command that has finished.
            if let fetched, current < fetched, (try? await install(fetched, timeout: 30)) != nil {
                printError("\nUpdated headroom \(current) -> \(fetched)")
                return
            }
        }
        if let latest, current < latest {
            printError("\nheadroom \(latest) is available (current: \(current)). Run `headroom update` to install.")
        }
    }

    /// Puts `release` over the running binary.
    static func install(_ release: Version, timeout: TimeInterval) async throws {
        guard let binary else { throw UpdateError("Cannot find the running binary") }
        let download = try await Releases.github.download(asset, of: release, timeout: timeout)
        // An error page or a truncated transfer, not a build.
        guard download.count > 1_000_000 else { throw UpdateError("Download is an implausible \(download.count) bytes") }
        // Next to the binary, so the swap is a rename, and under a name of
        // its own, so two updates at once can't write into the same file.
        let staged = binary.deletingLastPathComponent().appendingPathComponent(".headroom-update-\(getpid())")
        guard FileManager.default.createFile(atPath: staged.path, contents: download, attributes: [.posixPermissions: 0o755]) else {
            throw UpdateError("Couldn't write to \(staged.deletingLastPathComponent().path)")
        }
        guard rename(staged.path, binary.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError("Couldn't replace \(binary.path): \(reason)")
        }
    }

    /// The last check's result.
    private struct Check: Codable {
        var lastCheck: Date
        var latestVersion: String

        static let file = dataDirectory.appendingPathComponent("update-check.json")

        static func load() -> Check? {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Check.self, from: $0) }
        }

        func save() {
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
        }
    }
}
#endif
