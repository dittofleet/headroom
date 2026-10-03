import Foundation
import HeadroomAccounts
import HeadroomCore

/// What the app and its widgets share: one app group, holding the cache
/// and the renewal locks, and doubling as the keychain group for tokens.
enum Shared {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "HeadroomAppGroup") as? String ?? "group.io.github.dittofleet.headroom"

    static let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)

    static let store = AccountStore(accessGroup: appGroup, lockDirectory: container?.appendingPathComponent("Locks"))

    static let providers: [any AccountProvider] = [ClaudeAccountProvider(store: store), CodexAccountProvider(store: store)]

    static var cacheFile: URL? {
        container?.appendingPathComponent("state.json")
    }

    static let defaults = UserDefaults(suiteName: appGroup) ?? .standard

    @MainActor
    static func engine() -> Engine {
        Engine(providers: providers, cacheFile: cacheFile)
    }

    static func isSignedIn(_ provider: any Provider) -> Bool {
        store.contains(provider.id)
    }

    /// Widgets refresh far less often than the Mac app does, so numbers this
    /// old are normal there. Past this, they are dimmed.
    static let staleAfter: TimeInterval = 90 * 60
}

/// The Mac app's settings, applied to the widgets.
struct WidgetSettings: Equatable {
    /// The pace tick on each bar.
    var showPace = true
    /// The percentages beside the lock screen bars, as the Mac's beside its
    /// menu bar ones.
    var showNumbers = true
    /// By provider id: the label of the limit it leads with, or
    /// `stackedChoice`. Without one, it leads with its session, as in the
    /// Mac menu bar.
    var limits: [String: String] = [:]

    static var current: WidgetSettings {
        let defaults = Shared.defaults
        return WidgetSettings(
            showPace: defaults.object(forKey: "showPace") as? Bool ?? true,
            showNumbers: defaults.object(forKey: "showNumbers") as? Bool ?? true,
            limits: defaults.dictionary(forKey: "widgetLimits") as? [String: String] ?? [:]
        )
    }

    func save() {
        let defaults = Shared.defaults
        defaults.set(showPace, forKey: "showPace")
        defaults.set(showNumbers, forKey: "showNumbers")
        defaults.set(limits, forKey: "widgetLimits")
    }
}
