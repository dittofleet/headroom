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
    @Published private(set) var signingIn: String?
    @Published var problem: String?
    /// The widgets' settings, which mirror the Mac's. A change redraws them,
    /// which doesn't spend a fetch: what's due is fetched either way.
    @Published var settings = WidgetSettings.current {
        didSet {
            settings.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    /// Provider ids with a session, kept here rather than asked of the
    /// keychain on every redraw.
    @Published private(set) var signedIn: Set<String> = []
    private let hasSession: (any Provider) -> Bool

    init(engine: Engine, hasSession: @escaping (any Provider) -> Bool = Shared.isSignedIn) {
        self.engine = engine
        self.hasSession = hasSession
        engine.onChange = { [weak self] in self?.revision += 1 }
        updateSignedIn()
    }

    var providers: [any Provider] { engine.providers }

    func isSignedIn(_ provider: any Provider) -> Bool {
        signedIn.contains(provider.id)
    }

    private func updateSignedIn() {
        signedIn = Set(providers.filter(hasSession).map(\.id))
    }

    /// Fetches whatever is due, after taking in what the widgets fetched.
    func refresh(manual: Bool) async {
        engine.reload()
        updateSignedIn()
        if await engine.refreshAndWait(manual: manual) {
            // A session found dead along the way has been signed out.
            updateSignedIn()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func signIn(_ provider: any Provider) async {
        guard let client = (provider as? any AccountProvider)?.client, signingIn == nil else { return }
        signingIn = provider.id
        defer { signingIn = nil }
        switch await SignInFlow().run(client) {
        case .success(let tokens):
            guard Shared.store.save(tokens, for: client.id) else {
                problem = "Signed in, but the session could not be saved to the keychain."
                return
            }
            engine.clear(provider)
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
        updateSignedIn()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
