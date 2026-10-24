#if DEBUG
import HeadroomAccounts
import HeadroomCore
import SwiftUI
import WidgetKit

/// Ways to try the app without signing in, in debug builds only.
///
/// - `-demo`: the app signed in to an account of each service, showing
///   `UsageEntry.sample()`. `-accounts <n>` makes that up to four.
/// - `-renderWidgets`: also draws the home and lock screens with every
///   widget to PNGs in the app's Documents/Renders, from the sample with
///   `-demo` and from live numbers without.
/// - In a simulator, tokens lent by iOS/scripts/sim-borrow-tokens.swift
///   are taken in at launch.
/// - `-signIn <service>`: starts a sign-in to "claude" or "codex" at launch.
/// - `-showSettings`: scrolls down to the widget settings.
enum Demo {
    private static let arguments = ProcessInfo.processInfo.arguments

    static let isOn = arguments.contains("-demo")
    static let rendersWidgets = arguments.contains("-renderWidgets")
    static let showsSettings = arguments.contains("-showSettings")
    static let signIn = value(after: "-signIn").flatMap(Service.init)
    static let accounts = value(after: "-accounts").flatMap { Int($0) } ?? 2

    private static func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.dropFirst($0 + 1).first }
    }

    private struct SampleProvider: Provider {
        let id: String
        let name: String
        let glyph: String
        let usageURL = URL(string: "https://example.com")!
        let snapshot: Snapshot

        func fetch() async -> Result<Snapshot, FetchFailure> {
            var fresh = snapshot
            fresh.fetchedAt = Date().addingTimeInterval(-42)
            return .success(fresh)
        }
    }

    /// The app's model for these modes, or nil to run as usual.
    @MainActor
    static func model() -> Model? {
        if isOn {
            let providers = UsageEntry.sample(accounts: accounts).rows.compactMap { row in
                row.snapshot.map { SampleProvider(id: row.id, name: row.name, glyph: row.glyph, snapshot: $0) }
            }
            let emails = ["claude-1": "me@example.com", "claude-2": "me@work.example", "codex-1": "me@example.com", "codex-2": "me@work.example"]
            return Model(engine: Engine(providers: providers, cacheFile: nil), accounts: { providers.map { ($0, emails[$0.id]) } })
        }
        #if targetEnvironment(simulator)
        let borrowed = takeBorrowedTokens()
        guard !borrowed.isEmpty else { return nil }
        let engine = Shared.engine()
        // New tokens make the cached numbers another session's.
        for provider in engine.providers where borrowed.contains(provider.id) {
            engine.clear(provider)
        }
        return Model(engine: engine)
        #else
        return nil
        #endif
    }

    /// What the launch arguments ask for once the app is up.
    @MainActor
    static func run(_ model: Model) async {
        if rendersWidgets { await renderWidgets(model: model) }
        if let signIn { await model.signIn(signIn) }
    }

    // MARK: Borrowed tokens

    #if targetEnvironment(simulator)
    /// Moves tokens the script left in the app group into the keychain, as
    /// each service's first account. They come without refresh tokens, so
    /// nothing here can renew the Mac's sessions, and the file is deleted
    /// once read. Returns the accounts that got new tokens.
    static func takeBorrowedTokens() -> Set<String> {
        guard let file = Shared.container?.appendingPathComponent("BorrowedTokens.json"),
              let data = try? Data(contentsOf: file)
        else { return [] }
        try? FileManager.default.removeItem(at: file)
        guard let lent = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return [] }
        var taken: Set<String> = []
        for (id, fields) in lent {
            guard let token = fields["accessToken"] as? String else { continue }
            let tokens = AccountTokens(
                accessToken: token,
                expiresAt: (fields["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                scopes: fields["scopes"] as? [String] ?? [],
                accountID: fields["accountID"] as? String,
                plan: ClaudeProvider.planName(fields["subscription"] as? String, tier: fields["tier"] as? String)
            )
            guard let account = Service(rawValue: id)?.id(1) else { continue }
            if Shared.store.save(tokens, for: account) { taken.insert(account) }
        }
        return taken
    }
    #endif

    // MARK: Widget renders

    /// Point sizes on a 6.3" iPhone.
    private static let small = CGSize(width: 170, height: 170)
    private static let medium = CGSize(width: 364, height: 170)
    private static let large = CGSize(width: 364, height: 382)
    private static let rectangular = CGSize(width: 172, height: 76)
    private static let circular = CGSize(width: 76, height: 76)

    @MainActor
    static func renderWidgets(model: Model) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("Renders")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entry: UsageEntry
        if isOn {
            entry = .sample(accounts: accounts)
            entry.rows = entry.rows.map { row in
                var row = row
                row.snapshot?.fetchedAt = entry.date.addingTimeInterval(-6 * 60)
                return row
            }
        } else {
            await model.refresh(manual: false)
            let rows = model.providers.map { UsageEntry.Row($0, model.engine.state($0)) }
            entry = UsageEntry(date: Date(), rows: rows, settings: model.settings)
        }
        write(homeScreen(entry, dark: false), to: folder.appendingPathComponent("home-light.png"))
        write(homeScreen(entry, dark: true), to: folder.appendingPathComponent("home-dark.png"))
        write(lockScreen(entry), to: folder.appendingPathComponent("lock.png"))
        if isOn {
            var other = entry
            other.settings = WidgetSettings(showNumbers: false, limits: ["claude-1": "Fable Weekly", "codex-1": "Weekly"])
            write(lockScreen(other), to: folder.appendingPathComponent("lock-alt.png"))
        }
    }

    /// The rings on a lock screen render: the first account as in the app,
    /// and the last one's weekly limit.
    private static func rings(_ entry: UsageEntry) -> [(row: UsageEntry.Row, limit: LimitChoice)] {
        guard let first = entry.rows.first, let last = entry.rows.last else { return [] }
        return [(first, .asInApp), (last, .weekly)]
    }

    /// What a lock screen render was drawn with.
    private static func caption(_ entry: UsageEntry) -> String {
        let leads = entry.rows.map { "\($0.name): \(entry.settings.limits[$0.id] ?? "Session")" }
        let rings = rings(entry).map { "\($0.row.name) \($0.limit == .asInApp ? "As in App" : "Weekly")" }
        return (leads + ["numbers \(entry.settings.showNumbers ? "on" : "off")"]).joined(separator: ", ")
            + "\nRings: " + rings.joined(separator: ", ")
    }

    @MainActor
    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        try? renderer.uiImage?.pngData()?.write(to: url)
    }

    private static func card(_ content: some View, _ size: CGSize, dark: Bool) -> some View {
        content
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(dark ? Color(white: 0.11) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, dark ? .dark : .light)
    }

    private static func label(_ text: String, dark: Bool) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(dark ? .white : .black).opacity(0.8)
    }

    private static func homeScreen(_ entry: UsageEntry, dark: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 6) {
                    card(UsageView(entry: entry, familyOverride: .systemSmall), small, dark: dark)
                    label("Usage (Small)", dark: dark)
                }
                VStack(spacing: 6) {
                    card(UsageView(entry: UsageEntry(date: entry.date, rows: [], settings: entry.settings), familyOverride: .systemSmall), small, dark: dark)
                    label("Before signing in", dark: dark)
                }
            }
            card(UsageView(entry: entry, familyOverride: .systemMedium), medium, dark: dark)
            label("Usage (Medium)", dark: dark)
            card(UsageView(entry: entry, familyOverride: .systemLarge), large, dark: dark)
            label("Usage (Large)", dark: dark)
        }
        .padding(19)
        .padding(.vertical, 20)
        .background(
            LinearGradient(colors: dark ? [Color(red: 0.1, green: 0.12, blue: 0.25), .black] : [Color(red: 0.55, green: 0.75, blue: 0.95), Color(red: 0.95, green: 0.8, blue: 0.7)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    /// Lock screen widgets draw in the system's monochrome style, which this
    /// approximates with white on a dark wallpaper.
    private static func lockScreen(_ entry: UsageEntry) -> some View {
        VStack(spacing: 4) {
            UsageView(entry: entry, familyOverride: .accessoryInline)
                .font(.subheadline.weight(.semibold))
            Text("9:41")
                .font(.system(size: 96, weight: .semibold, design: .rounded))
            HStack(spacing: 12) {
                UsageView(entry: entry, familyOverride: .accessoryRectangular)
                    .frame(width: rectangular.width, height: rectangular.height)
                ForEach(rings(entry), id: \.row.id) { ring in
                    GaugeFace(entry: entry, accountID: ring.row.id, limit: ring.limit)
                        .frame(width: circular.width, height: circular.height)
                }
            }
            .padding(.top, 8)
            Text(caption(entry))
                .font(.caption2)
                .multilineTextAlignment(.center)
                .opacity(0.6)
                .padding(.top, 16)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .grayscale(1)
        .environment(\.colorScheme, .dark)
        .frame(width: 402)
        .padding(.vertical, 60)
        .background(LinearGradient(colors: [Color(red: 0.15, green: 0.2, blue: 0.35), Color(red: 0.05, green: 0.05, blue: 0.1)], startPoint: .top, endPoint: .bottom))
    }
}
#endif
