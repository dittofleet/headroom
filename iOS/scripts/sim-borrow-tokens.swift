// Lends this Mac's Claude Code and Codex access tokens to Headroom in a
// simulator, so it can be tried with real numbers without signing in.
// Run from the repo root, with a debug build installed on the simulator:
//   swift iOS/scripts/sim-borrow-tokens.swift [device id, default "booted"]
//
// Only access tokens are lent, never refresh tokens: the simulator can't
// renew, so it can't rotate the Mac's sessions out from under the CLIs.
// Once a token expires (Claude's within hours), the simulator shows the
// provider as signed out. Run this again then. The tokens go to a file in the
// app group, which the app moves into its keychain on its next launch and
// deletes. Nothing secret is printed.
import Foundation

let device = CommandLine.arguments.dropFirst().first ?? "booted"
let appID = "io.github.dittofleet.headroom.ios"
let appGroup = "group.io.github.dittofleet.headroom"

func run(_ path: String, _ arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

func object(_ data: Data?) -> [String: Any]? {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

/// The expiry claim of a JWT, in seconds since 1970.
func jwtExpiry(_ token: String) -> Double? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    return (object(Data(base64Encoded: payload))?["exp"] as? NSNumber)?.doubleValue
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sim-borrow-tokens: \(message)\n".utf8))
    exit(1)
}

guard let containerOutput = run("/usr/bin/xcrun", ["simctl", "get_app_container", device, appID, appGroup]),
      let containerPath = String(data: containerOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !containerPath.isEmpty
else { fail("no app group for \(appID) on \(device); install a debug build first") }

var borrowed: [String: [String: Any]] = [:]
var report: [String] = []
let now = Date().timeIntervalSince1970

// Claude Code: the keychain item it scopes by account name, an older
// unscoped one, or the file it falls back to.
let home = FileManager.default.homeDirectoryForCurrentUser
let claudeDocument = run("/usr/bin/security", ["find-generic-password", "-a", NSUserName(), "-s", "Claude Code-credentials", "-w"])
    ?? run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    ?? (try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")))
if let oauth = object(claudeDocument)?["claudeAiOauth"] as? [String: Any],
   let token = oauth["accessToken"] as? String, !token.isEmpty {
    let expiry = (oauth["expiresAt"] as? NSNumber).map { $0.doubleValue / 1000 }
    borrowed["claude"] = [
        "accessToken": token,
        "expiresAt": expiry as Any,
        "scopes": oauth["scopes"] as? [String] ?? [],
        "subscription": oauth["subscriptionType"] as Any,
        "tier": oauth["rateLimitTier"] as Any,
    ].compactMapValues { $0 is NSNull ? nil : $0 }
    report.append("Claude" + (expiry.map { $0 > now ? " (expires in \(Int(($0 - now) / 60)) min)" : " (already expired: run Claude Code, then this again)" } ?? ""))
} else {
    report.append("Claude: no Claude Code sign-in found")
}

// Codex: auth.json in CODEX_HOME or ~/.codex.
let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
if let tokens = object(try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")))?["tokens"] as? [String: Any],
   let token = tokens["access_token"] as? String, !token.isEmpty {
    let expiry = jwtExpiry(token)
    borrowed["codex"] = [
        "accessToken": token,
        "expiresAt": expiry as Any,
        "accountID": tokens["account_id"] as Any,
    ].compactMapValues { $0 is NSNull ? nil : $0 }
    report.append("Codex" + (expiry.map { $0 > now ? " (expires in \(Int(($0 - now) / 3600)) h)" : " (already expired: run Codex, then this again)" } ?? ""))
} else {
    report.append("Codex: no Codex sign-in found")
}

guard !borrowed.isEmpty else { fail(report.joined(separator: "\n")) }
guard let data = try? JSONSerialization.data(withJSONObject: borrowed) else { fail("could not encode tokens") }
let file = URL(fileURLWithPath: containerPath).appendingPathComponent("BorrowedTokens.json")
// Owner-only from the first byte.
guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
    fail("could not write to the app group")
}
print("Lent to the simulator, taken in on the app's next launch:")
report.forEach { print("  \($0)") }
