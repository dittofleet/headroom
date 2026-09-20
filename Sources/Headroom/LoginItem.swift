import Foundation

/// Start at login, as a plain LaunchAgent in ~/Library/LaunchAgents. launchd
/// loads it at login and also brings the app back if it crashes; quitting
/// from the menu is a clean exit, so it stays quit until the next login.
///
/// Deliberately not SMAppService: that ties the registration to the app's
/// code signature, and refuses to register a rebuilt or ad-hoc signed copy.
enum LoginItem {
    static let label = "io.github.dittofleet.headroom"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Takes effect at the next login. Turning it off leaves the running
    /// app alone rather than having launchd kill it mid-session.
    static func set(enabled: Bool) throws {
        guard enabled else {
            if isEnabled { try FileManager.default.removeItem(at: plistURL) }
            return
        }
        guard let program = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            // Lets System Settings list it under the app's name.
            "AssociatedBundleIdentifiers": [label],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    /// The app was moved since it was enabled: point the agent at where it
    /// lives now, or the next login starts nothing.
    static func repairIfMoved() {
        guard isEnabled, let program = Bundle.main.executablePath,
              let job = NSDictionary(contentsOf: plistURL), (job["ProgramArguments"] as? [String])?.first != program
        else { return }
        try? set(enabled: true)
    }
}
