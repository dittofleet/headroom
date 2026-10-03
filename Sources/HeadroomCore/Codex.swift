import Foundation

/// ChatGPT plan usage for Codex, from the endpoint behind Codex's /status.
/// On the Mac, auth is the Codex CLI's own token from auth.json, read-only
/// for the same reason as Claude's. Elsewhere it is a session of our own:
/// see `CodexAccountProvider`.
public struct CodexProvider {
    public let id = "codex"
    public let name = "Codex"
    public let glyph = "X"
    public let usageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init() {}

    static func headers(token: String, accountID: String?) -> [String: String] {
        var headers = ["Authorization": "Bearer \(token)", "User-Agent": "headroom"]
        if let accountID { headers["chatgpt-account-id"] = accountID }
        return headers
    }

    static func parseCredentials(_ data: Data) -> (token: String, accountID: String?)? {
        guard let tokens = Parse.object(data)?["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        return (token, tokens["account_id"] as? String)
    }

    public static func parse(_ data: Data, now: Date) -> Snapshot? {
        guard let root = Parse.object(data) else { return nil }
        var limits: [Limit] = []

        func add(_ rateLimit: Any?, prefix: String?) {
            guard let rateLimit = rateLimit as? [String: Any] else { return }
            for key in ["primary_window", "secondary_window"] {
                guard let window = rateLimit[key] as? [String: Any],
                      let percent = Parse.number(window["used_percent"])
                else { continue }
                let seconds = Parse.number(window["limit_window_seconds"])
                var (kind, label) = describe(seconds)
                if let prefix {
                    label = "\(prefix) \(label)"
                    kind = .other
                }
                limits.append(Limit(kind: kind, label: label, percent: percent, resetsAt: Parse.epochDate(window["reset_at"]), windowSeconds: seconds))
            }
        }

        add(root["rate_limit"], prefix: nil)
        add(root["code_review_rate_limit"], prefix: "Code review")
        for case let extra as [String: Any] in root["additional_rate_limits"] as? [Any] ?? [] {
            let name = extra["limit_name"] as? String ?? extra["metered_feature"] as? String ?? "Other"
            add(extra["rate_limit"], prefix: name)
        }

        guard !limits.isEmpty else { return nil }
        return Snapshot(limits: limits, plan: planName(root["plan_type"] as? String), fetchedAt: now)
    }

    /// ChatGPT's plan ids are internal names, several to a product.
    static func planName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        switch id {
        case "unknown": return nil
        case "free_workspace": return "Free"
        case "prolite": return "Pro Lite"
        case "self_serve_business_usage_based": return "Business"
        case "self_serve_business_prolite": return "Business Pro Lite"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based": return "Enterprise"
        case "education": return "Edu"
        default: return Format.title(id)
        }
    }

    private static func describe(_ seconds: Double?) -> (Limit.Kind, String) {
        guard let seconds else { return (.other, "Limit") }
        if seconds <= 6 * 3600 { return (.session, "Session") }
        if seconds >= 6 * 86400, seconds <= 8 * 86400 { return (.weekly, "Weekly") }
        let days = seconds / 86400
        return (.other, days >= 1 ? "\(Int(days.rounded()))-day" : "\(Int((seconds / 3600).rounded()))-hour")
    }
}

#if os(macOS)
extension CodexProvider: Provider {
    public func fetch() async -> Result<Snapshot, FetchFailure> {
        guard let data = try? Data(contentsOf: Self.authFile), let creds = Self.parseCredentials(data) else {
            return .failure(FetchFailure("Not signed in to Codex"))
        }
        let result = await HTTP.get(Self.endpoint, headers: Self.headers(token: creds.token, accountID: creds.accountID), authHint: "Login expired, refreshes when Codex next runs")
        return result.flatMap { data in
            Self.parse(data, now: Date()).map { .success($0) } ?? .failure(FetchFailure("Unrecognized response"))
        }
    }

    private static var authFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }
}
#endif
