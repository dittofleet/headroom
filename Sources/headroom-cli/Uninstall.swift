#if os(Linux)
import Foundation
import HeadroomCore

/// `headroom uninstall`: lists what goes and asks first, unless `yes`.
/// The binary goes last, so a failure leaves a tool to retry with.
enum Uninstall {
    static func run(yes: Bool) {
        guard Version(version) != nil else { fail("cannot uninstall a dev build") }
        guard let binary = SelfUpdate.binary else { fail("cannot find the running binary") }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var items = [
            ("Numbers", Engine.defaultCacheFile?.deletingLastPathComponent()),
            ("Data", SelfUpdate.dataDirectory),
            // Foundation's on Linux, made for any URLSession, even one that caches nothing.
            ("Cache", caches.appendingPathComponent("org.swift.foundation.URLCache/headroom")),
        ]
            .compactMap { label, url in url.map { (label, $0) } }
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }
        items.append(("Binary", binary))

        print("This will remove:")
        for (label, url) in [items.last!] + items.dropLast() {
            print("  - \((label + ":").padding(toLength: 9, withPad: " ", startingAt: 0))\(url.path)")
        }
        print("\nClaude Code's and Codex's logins are left as they are.\n")

        if !yes {
            guard isatty(STDIN_FILENO) == 1 else { fail("refusing to uninstall non-interactively without --yes") }
            print("Proceed? [y/N]: ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                print("Aborted.")
                return
            }
        }

        var removed: [String] = []
        for (label, url) in items {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if !removed.isEmpty { printError("Removed before failure: \(removed.joined(separator: ", "))") }
                fail("failed to remove \(label.lowercased()) (\(url.path)): \(error.localizedDescription)")
            }
            removed.append(label.lowercased())
        }
        print("Uninstalled headroom.")
    }
}
#endif
