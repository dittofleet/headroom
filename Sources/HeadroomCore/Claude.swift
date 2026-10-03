import Foundation

/// Claude subscription usage, from the endpoint behind Claude Code's /usage.
/// The token comes from `HeadroomMac`, which borrows Claude Code's own, or
/// from `HeadroomAccounts`, which signs in a session of our own.
public struct ClaudeProvider: Sendable {
    public let id = "claude"
    public let name = "Claude"
    public let glyph = "C"
    public let usageURL = URL(string: "https://claude.ai/settings/usage")!

    package static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}
    package static func oauthHeaders(token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]
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
                limits.append(Limit(kind: .weekly, label: "\(label.isEmpty ? "Scoped" : label) Weekly", percent: percent, resetsAt: resetsAt, windowSeconds: weeklyWindow))
            default:
                let window: Double? = (entry["group"] as? String) == "weekly" ? weeklyWindow : nil
                limits.append(Limit(kind: .other, label: Format.title(kind), percent: percent, resetsAt: resetsAt, windowSeconds: window))
            }
        }

        // Older response shape, kept in case `limits` goes away.
        if limits.isEmpty {
            let legacy: [(String, Limit.Kind, String, Double)] = [
                ("five_hour", .session, "Session", sessionWindow),
                ("seven_day", .weekly, "Weekly", weeklyWindow),
                ("seven_day_opus", .weekly, "Opus Weekly", weeklyWindow),
                ("seven_day_sonnet", .weekly, "Sonnet Weekly", weeklyWindow),
            ]
            for (key, kind, label, window) in legacy {
                guard let entry = root[key] as? [String: Any], let percent = Parse.number(entry["utilization"]) else { continue }
                limits.append(Limit(kind: kind, label: label, percent: percent, resetsAt: Parse.isoDate(entry["resets_at"]), windowSeconds: window))
            }
        }

        return limits.isEmpty ? nil : Snapshot(limits: limits, plan: nil, fetchedAt: now)
    }

    // MARK: Plan

    /// Max comes in sizes, and a Team seat can be a premium one. The rate
    /// limit tier is what tells them apart.
    public static func planName(_ subscription: String?, tier: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        switch (subscription, tier) {
        case ("max", let tier?):
            // "default_claude_max_20x" is "Max 20x".
            let size = tier.split(separator: "_").last ?? ""
            return size.count > 1 && size.hasSuffix("x") && size.dropLast().allSatisfy(\.isNumber) ? "Max \(size)" : "Max"
        case ("team", "default_claude_max_5x"): return "Team Premium"
        default: return Format.title(subscription)
        }
    }

    /// The plan from the account profile. The one stored with the token is
    /// only as new as Claude Code's last sign-in or renewal, so it can still
    /// name the plan from before an upgrade.
    static func parseProfile(_ data: Data) -> String? {
        // "claude_max" is what the stored credentials call "max". Other
        // organization types are API ones, with no plan to show.
        guard let organization = Parse.object(data)?["organization"] as? [String: Any],
              let type = organization["organization_type"] as? String, type.hasPrefix("claude_")
        else { return nil }
        return planName(String(type.dropFirst("claude_".count)), tier: organization["rate_limit_tier"] as? String)
    }

    // MARK: Renewal

    package struct Renewal: Equatable {
        package var token: String
        /// Absent when the server kept the old one.
        package var refreshToken: String?
        package var expiresAt: Date
        /// Absent when the server did not say.
        package var refreshTokenExpiresAt: Date?
        package var scopes: [String]
    }

    package static func parseRenewal(_ data: Data, now: Date) -> Renewal? {
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
}

/// Asks for the account's plan when the token changes and otherwise at most
/// hourly: plans rarely change, and every poll already costs a request.
package actor PlanLookup {
    package static let shared = PlanLookup()

    package static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let askAgainAfter: TimeInterval = 3600
    private static let retryAfter: TimeInterval = 10 * 60

    /// The last answer. It stands until a newer one arrives, since a new
    /// token is far more often a renewal than another account.
    private var plan: String?
    private var askedWith: String?
    private var nextAsk = Date.distantPast
    private var asking = false

    /// Nil until the profile has answered, in which case the stored plan is
    /// the best there is.
    package func plan(token: String, scopes: [String]) async -> String? {
        // A token without the profile scope would only be refused.
        guard scopes.isEmpty || scopes.contains("user:profile") else { return nil }
        guard !asking, token != askedWith || Date() >= nextAsk else { return plan }
        asking = true
        defer { asking = false }
        askedWith = token
        let response = await HTTP.get(Self.endpoint, headers: ClaudeProvider.oauthHeaders(token: token), authHint: "Token rejected")
        if case .success(let data) = response, let answer = ClaudeProvider.parseProfile(data) {
            plan = answer
            nextAsk = Date().addingTimeInterval(Self.askAgainAfter)
        } else {
            nextAsk = Date().addingTimeInterval(Self.retryAfter)
        }
        return plan
    }
}
