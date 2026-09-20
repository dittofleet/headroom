import Foundation

/// Claude subscription usage, from the endpoint behind Claude Code's /usage.
/// Auth is Claude Code's own OAuth token. We only ever read it: refreshing it
/// ourselves would rotate the refresh token out from under Claude Code.
public struct ClaudeProvider: Provider {
    public let id = "claude"
    public let name = "Claude"
    public let glyph = "C"
    public let usageURL = URL(string: "https://claude.ai/settings/usage")!

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let authAdvice = "refreshes when Claude Code next runs"

    public init() {}

    public func fetch() async -> Result<Snapshot, FetchFailure> {
        guard let creds = await Self.credentials() else {
            return .failure(FetchFailure("Not signed in to Claude Code"))
        }
        // An expired token is a guaranteed 401 that still spends the
        // endpoint's small request quota.
        if !creds.isLive(at: Date()) {
            return .failure(FetchFailure("Token expired, \(Self.authAdvice)"))
        }
        let result = await HTTP.get(
            Self.endpoint,
            headers: [
                "Authorization": "Bearer \(creds.token)",
                "anthropic-beta": "oauth-2025-04-20",
                "Content-Type": "application/json",
            ],
            authHint: "Token rejected, \(Self.authAdvice)"
        )
        return result.flatMap { data in
            guard var snapshot = Self.parse(data, now: Date()) else {
                return .failure(FetchFailure("Unrecognized response"))
            }
            snapshot.plan = creds.plan
            return .success(snapshot)
        }
    }

    // MARK: Parsing

    static let sessionWindow: Double = 5 * 3600
    static let weeklyWindow: Double = 7 * 86400

    public static func parse(_ data: Data, now: Date) -> Snapshot? {
        guard let root = Parse.object(data) else { return nil }
        var limits: [Limit] = []

        // `limits` is what the /usage screen renders, including model-scoped
        // weekly caps that have no top-level key.
        for case let entry as [String: Any] in root["limits"] as? [Any] ?? [] {
            guard let kind = entry["kind"] as? String, let percent = Parse.number(entry["percent"]) else { continue }
            let resetsAt = Parse.isoDate(entry["resets_at"])
            switch kind {
            case "session":
                limits.append(Limit(kind: .session, label: "Session", percent: percent, resetsAt: resetsAt, windowSeconds: sessionWindow))
            case "weekly_all":
                limits.append(Limit(kind: .weekly, label: "Weekly", percent: percent, resetsAt: resetsAt, windowSeconds: weeklyWindow))
            case "weekly_scoped":
                let scope = entry["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                let surface = scope?["surface"] as? String
                let label = [model, surface].compactMap { $0 }.joined(separator: " ")
                limits.append(Limit(kind: .weekly, label: "Weekly · \(label.isEmpty ? "scoped" : label)", percent: percent, resetsAt: resetsAt, windowSeconds: weeklyWindow))
            default:
                let window: Double? = (entry["group"] as? String) == "weekly" ? weeklyWindow : nil
                limits.append(Limit(kind: .other, label: kind.replacingOccurrences(of: "_", with: " ").capitalized, percent: percent, resetsAt: resetsAt, windowSeconds: window))
            }
        }

        // Older response shape, kept in case `limits` goes away.
        if limits.isEmpty {
            let legacy: [(String, Limit.Kind, String, Double)] = [
                ("five_hour", .session, "Session", sessionWindow),
                ("seven_day", .weekly, "Weekly", weeklyWindow),
                ("seven_day_opus", .weekly, "Weekly · Opus", weeklyWindow),
                ("seven_day_sonnet", .weekly, "Weekly · Sonnet", weeklyWindow),
            ]
            for (key, kind, label, window) in legacy {
                guard let entry = root[key] as? [String: Any], let percent = Parse.number(entry["utilization"]) else { continue }
                limits.append(Limit(kind: kind, label: label, percent: percent, resetsAt: Parse.isoDate(entry["resets_at"]), windowSeconds: window))
            }
        }

        return limits.isEmpty ? nil : Snapshot(limits: limits, plan: nil, fetchedAt: now)
    }

    // MARK: Credentials

    struct Credentials {
        var token: String
        var expiresAt: Date?
        var plan: String?

        func isLive(at now: Date) -> Bool {
            (expiresAt ?? .distantFuture) > now
        }
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let oauth = Parse.object(data)?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = Parse.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(token: token, expiresAt: expiresAt, plan: (oauth["subscriptionType"] as? String)?.capitalized)
    }

    private static func credentials() async -> Credentials? {
        // Read the keychain through /usr/bin/security rather than the
        // Security framework: the item's ACL already trusts that binary (it
        // is how Claude Code itself reads it), while our own binary would
        // raise a password prompt again after every rebuild.
        //
        // Claude Code scopes its entry by account name; an unscoped lookup
        // can surface an older orphaned entry whose token no longer refreshes.
        //
        // Stop at the first source with a live token, so the usual case is a
        // single subprocess. An expired one is kept only to report it.
        let now = Date()
        var expired: Credentials?
        func live(_ data: Data?) -> Credentials? {
            guard let creds = data.flatMap(parseCredentials) else { return nil }
            if creds.isLive(at: now) { return creds }
            expired = expired ?? creds
            return nil
        }
        for scope in [["-a", NSUserName()], []] {
            let args = ["find-generic-password"] + scope + ["-s", "Claude Code-credentials", "-w"]
            if let creds = live(await Subprocess.run("/usr/bin/security", args)) { return creds }
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return live(try? Data(contentsOf: file)) ?? expired
    }
}

enum Subprocess {
    /// stdout of a short-lived command, or nil on failure or timeout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
