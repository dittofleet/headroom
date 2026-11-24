import Foundation
import HeadroomCore

/// Every provider, in menu order.
public let allProviders: [any Provider] = [ClaudeProvider(), CodexProvider(), AntigravityProvider()]

/// Whose credentials each provider is fetched with, and how much Headroom
/// may do with Claude Code's.
public enum LoginPreferences {
    private static let defaults = UserDefaults.standard

    public static func usesCLICredentials(_ id: String) -> Bool {
        !ownLogins.contains(id)
    }

    public static func setUsesCLICredentials(_ id: String, _ uses: Bool) {
        if uses { ownLogins.remove(id) } else { ownLogins.insert(id) }
    }

    /// The providers using a login of Headroom's own.
    private static var ownLogins: Set<String> {
        get { Set(defaults.stringArray(forKey: "ownLogins") ?? []) }
        set { defaults.set(Array(newValue), forKey: "ownLogins") }
    }

    /// The CLI's credentials are only read, never refreshed. While they are
    /// expired, the numbers wait for the CLI to refresh them.
    public static func isPassive(_ id: String) -> Bool {
        !refreshing.contains(id)
    }

    public static func setPassive(_ id: String, _ passive: Bool) {
        if passive { refreshing.remove(id) } else { refreshing.insert(id) }
    }

    /// The providers whose CLI credentials Headroom refreshes.
    private static var refreshing: Set<String> {
        get { Set(defaults.stringArray(forKey: "refreshesCLICredentials") ?? []) }
        set { defaults.set(Array(newValue), forKey: "refreshesCLICredentials") }
    }
}
