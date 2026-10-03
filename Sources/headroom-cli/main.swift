import Foundation
import HeadroomCore

// Shipped inside Headroom.app and linked onto the PATH as `headroom`. It
// only reads what the running app last saved: fetching from here would
// spend the same small quota the app depends on.

let usage = """
    usage: headroom claude|codex [--json]

    Prints your usage limits for one provider as Headroom last saw them.
    Headroom refreshes every 5 minutes while it runs; this never fetches.

      --json     machine-readable output, for agents and scripts
      --version  print the version
    """

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("headroom: \(message)\n".utf8))
    exit(code)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

if arguments.contains("--version") {
    // The CLI has no Info.plist of its own; it shares the app's.
    let plist = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    let info = NSDictionary(contentsOf: plist)
    print(info?["CFBundleShortVersionString"] as? String ?? "dev")
    exit(0)
}

let providers: [any Provider] = [ClaudeProvider(), CodexProvider()]
let names = arguments.filter { !$0.hasPrefix("-") }
if let unknown = arguments.first(where: { $0.hasPrefix("-") && $0 != "--json" }) {
    fail("unknown option \(unknown)\n\n\(usage)", code: 2)
}
guard names.count == 1, let provider = providers.first(where: { $0.id == names[0] }) else {
    fail(names.isEmpty ? "which provider?\n\n\(usage)" : "unknown provider \(names.joined(separator: " "))\n\n\(usage)", code: 2)
}

guard let cacheFile = Engine.defaultCacheFile, FileManager.default.fileExists(atPath: cacheFile.path) else {
    fail("no usage numbers yet. Open Headroom, which saves them for this command.")
}

MainActor.assumeIsolated {
    let engine = Engine(providers: providers, cacheFile: cacheFile)
    let now = Date()
    let report = UsageReport(engine.state(provider), now: now)
    print(arguments.contains("--json") ? report.json() : report.text(name: provider.name, now: now))
}
