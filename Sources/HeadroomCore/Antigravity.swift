import Foundation

/// Google's Antigravity usage, from the endpoint behind the Antigravity
/// CLI's /usage. The token comes from `HeadroomBorrow`, which reads the
/// CLI's own.
public struct AntigravityProvider: Sendable {
    public let id = "antigravity"
    public let name = "Antigravity"
    public let glyph = "G"
    public let usageURL: URL? = nil

    /// The host the CLI uses. The production one answers too, but with
    /// numbers that never move.
    package static let endpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    package static let accountEndpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    public init() {}

    /// The Gemini models' limits are only sent to a client that names itself
    /// as a recent enough Antigravity.
    package static func headers(token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "User-Agent": "antigravity/2.24.0 darwin/arm64"]
    }

    /// What the CLI's own account lookup sends.
    package static let accountRequest: [String: Any] = [
        "metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
    ]

    static let windows: [String: (label: String, seconds: Double, kind: Limit.Kind)] = [
        "5h": ("Session", 5 * 3600, .session),
        "weekly": ("Weekly", 7 * 86400, .weekly),
    ]

    /// Groups of models that share a 5-hour and a weekly limit, such as
    /// "Gemini Models" and "Claude and GPT models".
    public static func parse(_ data: Data, now: Date) -> Snapshot? {
        guard let root = Parse.object(data) else { return nil }
        var limits: [Limit] = []
        for case let group as [String: Any] in root["groups"] as? [Any] ?? [] {
            let name = (group["displayName"] as? String ?? "")
                .replacingOccurrences(of: #"\s+models$"#, with: "", options: [.regularExpression, .caseInsensitive])
            var groupLimits: [Limit] = []
            for case let bucket as [String: Any] in group["buckets"] as? [Any] ?? [] {
                guard let remaining = Parse.number(bucket["remainingFraction"]) else { continue }
                let id = bucket["window"] as? String ?? ""
                let window = windows[id]
                let label = [name, window?.label ?? Format.title(id)].filter { !$0.isEmpty }.joined(separator: " ")
                // Gemini's are what the account leads with, and what Stacked
                // shows. The other groups' limits stand apart.
                let isGemini = (bucket["bucketId"] as? String)?.hasPrefix("gemini-") ?? false
                groupLimits.append(Limit(kind: isGemini ? window?.kind ?? .other : .other, label: label, percent: (1 - remaining) * 100, resetsAt: Parse.isoDate(bucket["resetTime"]), windowSeconds: window?.seconds))
            }
            // The session first, as for the other providers.
            limits += groupLimits.sorted { ($0.windowSeconds ?? .infinity) < ($1.windowSeconds ?? .infinity) }
        }
        return limits.isEmpty ? nil : Snapshot(limits: limits, plan: nil, fetchedAt: now)
    }

    /// The Google AI plan, such as "Google AI Pro", from the account lookup.
    /// An account with none is on the free tier.
    package static func parsePlan(_ data: Data) -> String? {
        guard let root = Parse.object(data), root["currentTier"] != nil else { return nil }
        return (root["paidTier"] as? [String: Any])?["name"] as? String ?? "Free"
    }
}
