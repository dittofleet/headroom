import Foundation

/// A lock between processes that is a directory, created atomically, rather
/// than an flock: iOS kills a suspended process that holds a file lock in a
/// shared container, and a renewal can be suspended mid-request. Claude Code
/// locks its own renewals the same way.
package enum DirectoryLock {
    /// A lock older than this was left by a process that died holding it.
    package static let staleAfter: TimeInterval = 60

    package static func take(_ lock: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        func create() -> Bool { (try? fm.createDirectory(at: lock, withIntermediateDirectories: false)) != nil }
        if create() { return true }
        let modified = (try? fm.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date) ?? .distantPast
        guard Date().timeIntervalSince(modified) > staleAfter else { return false }
        try? fm.removeItem(at: lock)
        return create()
    }

    package static func release(_ lock: URL) {
        try? FileManager.default.removeItem(at: lock)
    }
}
