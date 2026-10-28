import Foundation

#if os(Linux)
/// The release's tag, which the release workflow writes in here. A build from
/// source is "dev", which doesn't update itself.
let version = "dev"
#else
/// The app's: the command has no Info.plist of its own.
var version: String {
    // Not argv[0], which is just "headroom" when found through the PATH.
    let plist = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "dev"
}
#endif
