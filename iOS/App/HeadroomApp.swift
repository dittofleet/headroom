import HeadroomAccounts
import HeadroomCore
import SwiftUI
import WidgetKit

@main
struct HeadroomApp: App {
    @StateObject private var model = Self.makeModel()

    private static func makeModel() -> Model {
        #if DEBUG
        if let model = Demo.model() { return model }
        #endif
        return Model(engine: Shared.engine())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                #if DEBUG
                .task { await Demo.run(model) }
                #endif
        }
    }
}

/// The engine, plus the sign-ins the widgets can't do themselves.
@MainActor
final class Model: ObservableObject {
    let engine: Engine
    /// Bumped on every engine change, so views redraw from it.
    @Published private(set) var revision = 0
    @Published private(set) var signingIn: Service?
    @Published var problem: String?
    /// The widgets' settings, which mirror the Mac's. A change redraws them,
    /// which doesn't spend a fetch: what's due is fetched either way.
    @Published var settings = WidgetSettings.current {
        didSet {
            settings.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    /// Who each account is signed in as, by id, kept here rather than
    /// asked of the keychain on every redraw.
    @Published private(set) var emails: [String: String] = [:]
    /// The signed-in accounts, which the engine fetches, and who each is.
    private let accounts: () -> [(provider: any Provider, email: String?)]

    init(engine: Engine, accounts: @escaping () -> [(provider: any Provider, email: String?)] = { Shared.accounts().map { ($0, $0.email) } }) {
        self.engine = engine
        self.accounts = accounts
        engine.onChange = { [weak self] in self?.revision += 1 }
        updateAccounts()
    }

    var providers: [any Provider] { engine.providers }

    var canAddAccount: Bool { providers.count < Shared.maxAccounts }

    /// This service's account ids.
    func ids(of service: Service) -> [String] {
        providers.map(\.id).filter { service.number($0) != nil }
    }

    private func updateAccounts() {
        let accounts = accounts()
        engine.providers = accounts.map(\.provider)
        emails = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in account.email.map { (account.provider.id, $0) } })
    }

    /// Fetches whatever is due, after taking in what the widgets fetched.
    func refresh(manual: Bool) async {
        engine.reload()
        updateAccounts()
        if await engine.refreshAndWait(manual: manual) {
            // A session found dead along the way has been signed out.
            updateAccounts()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Adds an account, or renews one already signed in to as the same
    /// person.
    func signIn(_ service: Service) async {
        guard signingIn == nil else { return }
        signingIn = service
        defer { signingIn = nil }
        let ids = ids(of: service)
        // Another account needs a sign-in page that doesn't already know one.
        switch await SignInFlow().run(service.client, fresh: !ids.isEmpty) {
        case .success(let tokens):
            let id = ids.first { tokens.email != nil && emails[$0] == tokens.email } ?? service.newAccountID(among: ids)
            guard Shared.store.save(tokens, for: id) else {
                problem = "Signed in, but the session could not be saved to the keychain."
                return
            }
            updateAccounts()
            if let account = providers.first(where: { $0.id == id }) { engine.clear(account) }
            await refresh(manual: true)
        case .failure(let failure):
            problem = failure.message
        case nil:
            break
        }
    }

    func signOut(_ provider: any Provider) {
        Shared.store.remove(provider.id)
        engine.clear(provider)
        settings.limits[provider.id] = nil
        updateAccounts()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
