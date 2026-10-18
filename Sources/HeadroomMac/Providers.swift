import Foundation
import HeadroomCore

/// Every provider, in menu order.
public let allProviders: [any Provider] = [ClaudeProvider(), CodexProvider()]

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

    /// CLI credentials are only read, never refreshed and written back.
    /// While they are expired, the numbers wait for the CLI to refresh them.
    public static var passiveMode: Bool {
        get { defaults.bool(forKey: "passiveMode") }
        set { defaults.set(newValue, forKey: "passiveMode") }
    }
}
