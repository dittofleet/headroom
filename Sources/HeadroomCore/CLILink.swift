import Foundation

/// The `headroom` command: a link in the user's bin folder to the CLI inside
/// the app. A link rather than a copy, so the app's updates carry it along.
///
/// Installed and removed only from Settings. The one thing launch does is
/// repair a link the user installed that points at another copy of the app,
/// such as one that has since moved.
public struct CLILink: Sendable {
    public enum State: Sendable, Equatable {
        case missing
        case installed
        /// Ours, but pointing at another copy of the app.
        case stale
        /// Something at the path that Headroom didn't put there.
        case foreign
    }

    public struct Failure: LocalizedError {
        public var errorDescription: String?
    }

    public static let binaryName = "headroom-cli"

    /// The CLI this copy of the app ships.
    public let binary: URL
    public let link: URL

    public init(binary: URL, binDir: URL) {
        self.binary = binary
        self.link = binDir.appendingPathComponent("headroom")
    }

    /// The XDG spec's place for user executables, which it gives no
    /// variable of its own; XDG_BIN_HOME is the common override.
    public static var userBinDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_BIN_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    public var state: State {
        let files = FileManager.default
        // attributesOfItem doesn't follow links, so a link to a deleted copy
        // of the app still counts as there.
        guard let type = (try? files.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType else { return .missing }
        guard type == .typeSymbolicLink, let target = try? files.destinationOfSymbolicLink(atPath: link.path) else { return .foreign }
        if target == binary.path { return .installed }
        return URL(fileURLWithPath: target).lastPathComponent == Self.binaryName ? .stale : .foreign
    }

    /// `replacing` is the user's consent to take over a foreign file.
    public func install(replacing: Bool = false) throws {
        if state == .foreign && !replacing {
            throw Failure(errorDescription: "\(link.path) already exists and wasn't created by Headroom.")
        }
        // Gatekeeper runs a quarantined app from a random read-only path
        // that goes away with it, so a link there would break at once.
        if binary.path.contains("/AppTranslocation/") {
            throw Failure(errorDescription: "macOS is running Headroom from a temporary location. Move it to Applications, open it again, and retry.")
        }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Linked under a temporary name and renamed over the old one, so a
        // shell never finds the command missing halfway through.
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".headroom.\(getpid())")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: binary.path)
        guard rename(temporary.path, link.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw Failure(errorDescription: "Couldn't link \(link.path): \(reason).")
        }
    }

    /// Removes the link only if it is Headroom's.
    public func uninstall() throws {
        guard state == .installed || state == .stale else { return }
        try FileManager.default.removeItem(at: link)
    }

    /// Consent was given when the link was installed, so this is silent.
    public func repairIfStale() {
        if state == .stale { try? install() }
    }
}
