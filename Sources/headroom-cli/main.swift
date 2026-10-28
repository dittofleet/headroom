import Foundation
import HeadroomCore
import HeadroomBorrow

// On a Mac, shipped inside Headroom.app and linked onto the PATH as
// `headroom`. It only reads what the running app last saved: fetching from
// here would spend the same small quota the app depends on.
//
// On Linux there is no app, so it fetches itself, on the app's schedule:
// only when the saved numbers are due, and once for all the calls waiting.
// It is also installed and updated on its own, like any dittofleet CLI.

let providerIDs = allProviders.map(\.id).joined(separator: "|")

#if os(Linux)
let usage = """
    usage: headroom \(providerIDs) [--json]
           headroom update
           headroom uninstall [--yes]

    Prints your usage limits for one provider.
    Fetches them when the saved ones are over 5 minutes old.

      --json     machine-readable output, for agents and scripts
      --version  print the version
    """
#else
let usage = """
    usage: headroom \(providerIDs) [--json]

    Prints your usage limits for one provider as Headroom last saw them.
    Headroom refreshes every 5 minutes while it runs. This never fetches.

      --json     machine-readable output, for agents and scripts
      --version  print the version
    """
#endif

let arguments = Array(CommandLine.arguments.dropFirst())

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    printError("headroom: \(message)")
    exit(code)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

if arguments.contains("--version") {
    print(version)
    exit(0)
}

#if os(Linux)
switch arguments.first {
case "update":
    await SelfUpdate.run()
    exit(0)
case "uninstall":
    Uninstall.run(yes: arguments.contains("--yes"))
    exit(0)
case "postinstall":
    // Run by the shared dittofleet install script. There is nothing to set up.
    exit(0)
default:
    break
}
#endif

let names = arguments.filter { !$0.hasPrefix("-") }
if let unknown = arguments.first(where: { $0.hasPrefix("-") && $0 != "--json" }) {
    fail("unknown option \(unknown)\n\n\(usage)", code: 2)
}
guard names.count == 1, let provider = allProviders.first(where: { $0.id == names[0] }) else {
    fail(names.isEmpty ? "which provider?\n\n\(usage)" : "unknown provider \(names.joined(separator: " "))\n\n\(usage)", code: 2)
}

guard let cacheFile = Engine.defaultCacheFile else { fail("no cache folder") }
#if os(Linux)
let lock = cacheFile.deletingLastPathComponent().appendingPathComponent("fetch.lock")
await Engine(providers: [provider], cacheFile: cacheFile).refreshAndWait(lockedBy: lock)
#else
guard FileManager.default.fileExists(atPath: cacheFile.path) else {
    fail("no usage numbers yet. Open Headroom, which saves them for this command.")
}
#endif

let now = Date()
let report = UsageReport(Engine.savedStates(at: cacheFile)[provider.id] ?? ProviderState(), now: now)
print(arguments.contains("--json") ? report.json() : report.text(name: provider.name, now: now))
#if os(Linux)
await SelfUpdate.checkDaily()
#endif
