import AppKit
import HeadroomCore

/// Keeps the installed app current: checks a few times a day, installs what
/// it finds, and relaunches into it. Only release builds update themselves;
/// a copy built from source has no signing team to hold an update to, and
/// is updated the way it was installed.
@MainActor
final class UpdateController {
    static let checkInterval: TimeInterval = 6 * 3600
    private static let lastCheckKey = "lastUpdateCheck"
    /// `defaults write io.github.dittofleet.headroom autoUpdate -bool false`
    private static let enabledKey = "autoUpdate"

    private let current: Version?
    private let updater: Updater?
    private let appURL = Bundle.main.bundleURL
    private var busy = false
    private var installed: Version?

    /// Shown in the menu next to the version.
    private(set) var status: String?
    var onChange: (() -> Void)?
    /// A relaunch under an open menu would yank it away.
    var canRelaunch: () -> Bool = { true }

    init() {
        current = Version(appVersion)
        if let bundleID = Bundle.main.bundleIdentifier, current != nil, appURL.pathExtension == "app",
           let trust = Updater.ownTeamID().flatMap(Updater.Trust.team) {
            updater = .github(repo: "dittofleet/headroom", asset: "Headroom.zip", bundleID: bundleID, trust: trust)
        } else {
            updater = nil
        }
    }

    var canUpdate: Bool { updater != nil }

    /// Called every minute; does something a few times a day.
    func tick(now: Date = Date()) {
        if installed != nil { return relaunchWhenIdle() }
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        // A clock set backwards must not postpone the next check forever.
        if now.timeIntervalSince(last) >= Self.checkInterval || last > now { check() }
    }

    func check() {
        guard let updater, let current, !busy, installed == nil else { return }
        busy = true
        // Recorded up front: a failing check waits its turn like any other.
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        set(status: "Checking for updates…")
        Task {
            do {
                let latest = try await updater.latest()
                if latest > current {
                    set(status: "Installing \(latest)…")
                    try await updater.install(latest, over: appURL)
                    installed = latest
                    set(status: "Restarting into \(latest)…")
                    relaunchWhenIdle()
                } else {
                    set(status: "Up to date")
                }
            } catch {
                set(status: "Update failed: \((error as? UpdateError)?.description ?? error.localizedDescription)")
            }
            busy = false
        }
    }

    private func set(status: String) {
        self.status = status
        onChange?()
    }

    func relaunchWhenIdle() {
        guard installed != nil, canRelaunch() else { return }
        let process = Process()
        if let label = Bundle.main.bundleIdentifier, ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label {
            // Started by our LaunchAgent: have launchd restart the job, so
            // the new copy stays under its care.
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        } else {
            // Started by hand: reopen once this copy is gone, since a second
            // instance refuses to run beside the first.
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"", "sh", "\(getpid())", appURL.path]
        }
        guard (try? process.run()) != nil else { return }
        // kickstart kills us itself; otherwise leave so the waiter can reopen.
        if process.executableURL?.lastPathComponent == "sh" { NSApp.terminate(nil) }
    }
}
