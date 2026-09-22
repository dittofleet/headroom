import Foundation

/// Claude subscription usage, from the endpoint behind Claude Code's /usage.
/// Auth is Claude Code's own OAuth token. Once it has expired we renew it the
/// way Claude Code would, and store the result back where Claude Code keeps
/// it, so the two keep sharing one session instead of logging each other out.
public struct ClaudeProvider: Provider {
    public let id = "claude"
    public let name = "Claude"
    public let glyph = "C"
    public let usageURL = URL(string: "https://claude.ai/settings/usage")!

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let signInAdvice = "sign in again with `claude login`"

    public init() {}

    public func fetch() async -> Result<Snapshot, FetchFailure> {
        guard var creds = await Self.credentials() else {
            return .failure(FetchFailure("Not signed in to Claude Code"))
        }
        // An expired token is a guaranteed 401 that would still spend the
        // endpoint's small request quota, so it is not sent.
        var result = creds.isLive(at: Date())
            ? await Self.usage(creds)
            : .failure(FetchFailure("Token expired", status: 401))
        if case .failure(let failure) = result, failure.status == 401 {
            switch await TokenRenewer.shared.renew(creds) {
            case .success(let fresh): creds = fresh
            case .failure(let failure): return .failure(failure)
            }
            result = await Self.usage(creds)
        }
        return result.flatMap { data in
            guard var snapshot = Self.parse(data, now: Date()) else {
                return .failure(FetchFailure("Unrecognized response"))
            }
            snapshot.plan = creds.plan
            return .success(snapshot)
        }
    }

    private static func usage(_ creds: Credentials) async -> Result<Data, FetchFailure> {
        await HTTP.get(
            endpoint,
            headers: [
                "Authorization": "Bearer \(creds.token)",
                "anthropic-beta": "oauth-2025-04-20",
                "Content-Type": "application/json",
            ],
            authHint: "Token rejected, \(signInAdvice)"
        )
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

    struct Credentials: Sendable {
        /// Claude Code scopes its keychain item by account name. An unscoped
        /// lookup is kept for older entries, and a renewal goes back to
        /// whichever the token came from.
        enum Source: Sendable { case keychain(account: String?), file(URL) }

        var token: String
        var refreshToken: String?
        var scopes: [String]
        var expiresAt: Date?
        var plan: String?
        /// The whole stored document and where it lives, so a renewed token
        /// goes back among everything else Claude Code keeps there.
        var document: Data
        var source: Source

        func isLive(at now: Date) -> Bool {
            (expiresAt ?? .distantFuture) > now
        }
    }

    static func parseCredentials(_ data: Data, source: Credentials.Source) -> Credentials? {
        guard let oauth = Parse.object(data)?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = Parse.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(
            token: token,
            refreshToken: (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            scopes: oauth["scopes"] as? [String] ?? [],
            expiresAt: expiresAt,
            plan: (oauth["subscriptionType"] as? String)?.capitalized,
            document: data,
            source: source
        )
    }

    static let keychainService = "Claude Code-credentials"
    static let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    static let sources: [Credentials.Source] = [
        .keychain(account: NSUserName()), .keychain(account: nil), .file(configDirectory.appendingPathComponent(".credentials.json")),
    ]

    /// Stops at the first source with a live token, so the usual case is a
    /// single subprocess. An expired one is kept only to renew or report.
    static func credentials() async -> Credentials? {
        let now = Date()
        var expired: Credentials?
        for source in sources {
            guard let creds = await read(source) else { continue }
            if creds.isLive(at: now) { return creds }
            expired = expired ?? creds
        }
        return expired
    }

    static func read(_ source: Credentials.Source) async -> Credentials? {
        let data: Data?
        switch source {
        case .file(let url):
            data = try? Data(contentsOf: url)
        case .keychain(let account):
            // Through /usr/bin/security rather than the Security framework:
            // the item's ACL already trusts that binary (it is how Claude
            // Code itself reads it), while our own binary would raise a
            // password prompt again after every rebuild.
            let scope = account.map { ["-a", $0] } ?? []
            data = await Subprocess.run("/usr/bin/security", ["find-generic-password"] + scope + ["-s", keychainService, "-w"])
        }
        return data.flatMap { parseCredentials($0, source: source) }
    }

    // MARK: Renewal

    struct Renewal: Equatable {
        var token: String
        /// Absent when the server kept the old one.
        var refreshToken: String?
        var expiresAt: Date
        /// Absent when the server did not say.
        var refreshTokenExpiresAt: Date?
        var scopes: [String]
    }

    static func parseRenewal(_ data: Data, now: Date) -> Renewal? {
        guard let root = Parse.object(data),
              let token = root["access_token"] as? String, !token.isEmpty,
              let expiresIn = Parse.number(root["expires_in"])
        else { return nil }
        let refresh = root["refresh_token"] as? String
        let scope = root["scope"] as? String ?? ""
        return Renewal(
            token: token,
            refreshToken: refresh.flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: now.addingTimeInterval(expiresIn),
            refreshTokenExpiresAt: Parse.number(root["refresh_token_expires_in"]).map { now.addingTimeInterval($0) },
            scopes: scope.split(separator: " ").map(String.init)
        )
    }

    /// The stored document with the renewed token in place of the old one.
    /// Everything else in it is kept as is, in the same shape Claude Code
    /// writes: the keys it reads back are `accessToken`, `refreshToken`,
    /// the expiries in milliseconds, and `scopes`.
    static func renewedDocument(_ document: Data, with renewal: Renewal) -> Data? {
        guard var root = Parse.object(document), var oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        oauth["accessToken"] = renewal.token
        if let refreshToken = renewal.refreshToken { oauth["refreshToken"] = refreshToken }
        oauth["expiresAt"] = Int64(renewal.expiresAt.timeIntervalSince1970 * 1000)
        if let refreshExpiry = renewal.refreshTokenExpiresAt {
            oauth["refreshTokenExpiresAt"] = Int64(refreshExpiry.timeIntervalSince1970 * 1000)
        }
        if !renewal.scopes.isEmpty { oauth["scopes"] = renewal.scopes }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// Renews an expired Claude Code token, one at a time and never while
/// Claude Code itself is doing the same.
actor TokenRenewer {
    static let shared = TokenRenewer()

    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's own OAuth client: the refresh token was issued to it.
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Claude Code takes this directory as a lock around its own refresh and
    /// treats one older than a minute as abandoned. We do the same.
    private static let lock = ClaudeProvider.configDirectory.appendingPathComponent(".oauth_refresh.lock")
    private static let lockStaleAfter: TimeInterval = 60

    /// Refresh tokens the server has already rejected. Asking again only
    /// gets the same answer, and it stays that way until a new sign-in.
    private var dead: Set<String> = []
    /// The access token from the last renewal.
    private var lastIssued: String?

    func renew(_ creds: ClaudeProvider.Credentials) async -> Result<ClaudeProvider.Credentials, FetchFailure> {
        let signedOut = FetchFailure("Session expired, \(ClaudeProvider.signInAdvice)")
        guard let refreshToken = creds.refreshToken, !dead.contains(refreshToken) else {
            return .failure(signedOut)
        }
        // A live token the server rejects has been revoked, or the clock is
        // off. One renewal settles which. Renewing again for the token that
        // renewal produced would not help, and would rotate the refresh
        // token on every poll.
        if creds.isLive(at: Date()), creds.token == lastIssued {
            return .failure(FetchFailure("Token rejected, \(ClaudeProvider.signInAdvice)"))
        }
        // The unscoped keychain lookup is only for reading an older entry.
        // A renewal could not be written back to it as the same item.
        if case .keychain(account: nil) = creds.source {
            return .failure(FetchFailure("Token expired, refreshes when Claude Code next runs"))
        }
        guard Self.takeLock() else {
            return .failure(FetchFailure("Token expired, Claude Code is renewing it"))
        }
        defer { try? FileManager.default.removeItem(at: Self.lock) }

        // Claude Code may have renewed since we read, in which case the
        // stored token is already a different, live one.
        if let current = await ClaudeProvider.read(creds.source), current.token != creds.token, current.isLive(at: Date()) {
            return .success(current)
        }

        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientID]
        if !creds.scopes.isEmpty { body["scope"] = creds.scopes.joined(separator: " ") }
        let now = Date()
        let data: Data
        switch await HTTP.post(Self.tokenURL, json: body, authHint: signedOut.message) {
        case .success(let body):
            data = body
        case .failure(let failure) where failure.status == 401 || Self.isInvalidGrant(failure):
            dead.insert(refreshToken)
            return .failure(signedOut)
        case .failure(let failure):
            return .failure(FetchFailure("Token renewal failed, \(failure.message.lowercased())", retryAfter: failure.retryAfter))
        }
        guard let renewal = ClaudeProvider.parseRenewal(data, now: now),
              let document = ClaudeProvider.renewedDocument(creds.document, with: renewal)
        else {
            return .failure(FetchFailure("Token renewal failed, unrecognized response"))
        }

        // From here the old token may already be revoked, so the write is
        // what keeps Claude Code signed in. Report loudly if it fails.
        guard await Self.store(document, to: creds.source),
              let renewed = ClaudeProvider.parseCredentials(document, source: creds.source)
        else {
            return .failure(FetchFailure("Renewed token could not be saved, \(ClaudeProvider.signInAdvice)"))
        }
        lastIssued = renewed.token
        return .success(renewed)
    }

    /// The refresh token itself is gone: revoked, superseded, or expired. Any
    /// other 400 is about the request and not the session.
    private static func isInvalidGrant(_ failure: FetchFailure) -> Bool {
        failure.status == 400 && failure.body.flatMap(Parse.object).map { $0["error"] as? String == "invalid_grant" } ?? false
    }

    private static func takeLock() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        func create() -> Bool { (try? fm.createDirectory(at: lock, withIntermediateDirectories: false)) != nil }
        if create() { return true }
        let modified = (try? fm.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date) ?? .distantPast
        guard Date().timeIntervalSince(modified) > lockStaleAfter else { return false }
        try? fm.removeItem(at: lock)
        return create()
    }

    private static func store(_ document: Data, to source: ClaudeProvider.Credentials.Source) async -> Bool {
        switch source {
        case .file(let url):
            // Owner-only from the first byte, as Claude Code writes it.
            return FileManager.default.createFile(atPath: url.path, contents: document, attributes: [.posixPermissions: 0o600])
        case .keychain(let account):
            // The same command Claude Code runs, fed over stdin so the token
            // never shows in the process list. `-U` updates the existing
            // item in place, keeping the access list that lets
            // /usr/bin/security read it without a prompt.
            let hex = document.map { String(format: "%02x", $0) }.joined()
            let scope = account.map { "-a \"\($0)\" " } ?? ""
            let command = "add-generic-password -U \(scope)-s \"\(ClaudeProvider.keychainService)\" -X \"\(hex)\"\n"
            return await Subprocess.run("/usr/bin/security", ["-i"], input: Data(command.utf8)) != nil
        }
    }
}

enum Subprocess {
    /// stdout of a short-lived command, or nil on failure or timeout.
    /// `input`, when given, is written to its stdin and then closed.
    static func run(_ path: String, _ args: [String], input: Data? = nil, timeout: TimeInterval = 5) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                if let stdin, let input {
                    // On its own queue, so a child that talks before it has
                    // read everything cannot deadlock against us.
                    DispatchQueue.global(qos: .utility).async {
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                    }
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
