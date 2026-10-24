import Foundation
import HeadroomAccounts
import HeadroomCore

/// What the app and its widgets share: one app group, holding the cache
/// and the renewal locks, and doubling as the keychain group for tokens.
enum Shared {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "HeadroomAppGroup") as? String ?? "group.io.github.dittofleet.headroom"

    static let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)

    static let store = AccountStore(accessGroup: appGroup, lockDirectory: container?.appendingPathComponent("Locks"))

    /// Accounts in all, as many as the widgets have room for.
    static let maxAccounts = 4

    static var cacheFile: URL? {
        container?.appendingPathComponent("state.json")
    }

    static let defaults = UserDefaults(suiteName: appGroup) ?? .standard

    @MainActor
    static func engine() -> Engine {
        Engine(providers: accounts(), cacheFile: cacheFile)
    }

    /// Every signed-in account, by service and then number.
    static func accounts() -> [Account] {
        let stored = store.accounts()
        return Service.allCases.flatMap { service in
            let numbered = stored.compactMap { item in service.number(item.id).map { ($0, item.email) } }.sorted { $0.0 < $1.0 }
            return numbered.map { Account(service: service, number: $0.0, of: numbered.count, email: $0.1) }
        }
    }

    /// Widgets refresh far less often than the Mac app does, so numbers this
    /// old are normal there. Past this, they are dimmed.
    static let staleAfter: TimeInterval = 90 * 60
}

/// A service the phone signs in to, with any number of accounts.
enum Service: String, CaseIterable, Sendable {
    case claude, codex

    /// The session stored as `id`.
    func provider(_ id: String) -> any AccountProvider {
        switch self {
        case .claude: ClaudeAccountProvider(store: Shared.store, id: id)
        case .codex: CodexAccountProvider(store: Shared.store, id: id)
        }
    }

    var name: String { provider(rawValue).name }
    var client: OAuthClient { provider(rawValue).client }

    /// The id of account `number`, as "claude-2".
    func id(_ number: Int) -> String {
        "\(rawValue)-\(number)"
    }

    /// The number in an account id of this service, as 2 in "claude-2".
    func number(_ id: String) -> Int? {
        id.hasPrefix("\(rawValue)-") ? Int(id.dropFirst(rawValue.count + 1)) : nil
    }

    /// Where the next account goes: the lowest number free.
    func newAccountID(among ids: [String]) -> String {
        let taken = Set(ids.compactMap(number))
        return id((1...).first { !taken.contains($0) }!)
    }
}

/// One signed-in account. Numbered beside other accounts of its service,
/// as "Claude 2" and "C2", and plain "Claude" when it is the only one.
struct Account: Provider {
    let name: String
    let glyph: String
    let email: String?
    private let base: any AccountProvider

    init(service: Service, number: Int, of count: Int, email: String? = nil) {
        base = service.provider(service.id(number))
        name = count > 1 ? "\(base.name) \(number)" : base.name
        glyph = count > 1 ? "\(base.glyph)\(number)" : base.glyph
        self.email = email
    }

    var id: String { base.id }
    var usageURL: URL { base.usageURL }

    func fetch() async -> Result<Snapshot, FetchFailure> {
        await base.fetch()
    }
}

/// The Mac app's settings, applied to the widgets.
struct WidgetSettings: Equatable {
    /// The pace tick on each bar.
    var showPace = true
    /// The percentages beside the lock screen bars, as the Mac's beside its
    /// menu bar ones.
    var showNumbers = true
    /// By account id: the label of the limit it leads with, or
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
