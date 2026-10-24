import HeadroomCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: Model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            // Every second, for the ages and countdowns.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollViewReader { proxy in
                    List {
                        ForEach(model.providers, id: \.id) { provider in
                            accountSection(provider, now: context.date)
                        }
                        signInSection
                        widgetSettings(now: context.date)
                            .id("settings")
                    }
                    #if DEBUG
                    .task {
                        guard Demo.showsSettings else { return }
                        // Once the list has laid out, or there is nothing to scroll to.
                        try? await Task.sleep(for: .seconds(1))
                        proxy.scrollTo("settings", anchor: .top)
                    }
                    #endif
                }
            }
            .navigationTitle("Headroom")
            .refreshable { await model.refresh(manual: true) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await model.refresh(manual: false) } }
        }
        .alert("Sign-in failed", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    /// The Mac's display settings, for the widgets: what each account
    /// leads with, and the two toggles.
    private func widgetSettings(now: Date) -> some View {
        Section {
            ForEach(model.providers, id: \.id) { provider in
                if let snapshot = model.engine.state(provider).snapshot {
                    Picker(provider.name, selection: leadingLimit(provider, snapshot: snapshot, now: now)) {
                        ForEach(snapshot.choices(at: now), id: \.self) { Text($0) }
                    }
                }
            }
            Toggle("Show Numbers on Lock Screen", isOn: $model.settings.showNumbers)
            Toggle("Show Pace Marker", isOn: $model.settings.showPace)
        } header: {
            Text("Widgets")
        } footer: {
            Text("Each account's limit leads its lock screen bar, the line above the clock, the small widget, and rings set to As in App. Stacked leads with the session and puts the fullest weekly limit under it.\n\nThe tick on each bar is how far through the window the clock is. A fill past it means you are burning faster than the window refills.")
        }
    }

    /// The choice showing now, as in the Mac's menu bar settings.
    private func leadingLimit(_ provider: any Provider, snapshot: Snapshot, now: Date) -> Binding<String> {
        Binding {
            snapshot.shownChoice(model.settings.limits[provider.id], at: now) ?? ""
        } set: { label in
            model.settings.limits[provider.id] = label
        }
    }

    @ViewBuilder
    private func accountSection(_ provider: any Provider, now: Date) -> some View {
        let _ = model.revision
        let state = model.engine.state(provider)
        Section {
            let dimmed = state.snapshot?.isStale(at: now, after: Shared.staleAfter) ?? true
            ForEach(Array((state.snapshot?.limits ?? []).enumerated()), id: \.offset) { _, limit in
                LimitRow(limit: limit, now: now, dimmed: dimmed, showPace: model.settings.showPace)
                    .padding(.vertical, 2)
            }
            if let notice = state.notice(at: now) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("Open Usage Page") { openURL(provider.usageURL) }
            Button("Sign Out", role: .destructive) { model.signOut(provider) }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.name)
                if let plan = state.snapshot?.plan {
                    Text(plan).textCase(nil).foregroundStyle(.tertiary)
                }
                Spacer()
                if model.engine.isFetching(provider) {
                    Text("Updating…").textCase(nil)
                } else if let snapshot = state.snapshot {
                    Text(Format.age(snapshot.fetchedAt, now: now)).textCase(nil).monospacedDigit()
                }
            }
        } footer: {
            if let email = model.emails[provider.id] {
                Text(email)
            }
        }
    }

    /// A sign-in per service, then another account while there is room.
    @ViewBuilder
    private var signInSection: some View {
        if model.canAddAccount {
            Section {
                ForEach(Service.allCases, id: \.self) { service in
                    let signedIn = !model.ids(of: service).isEmpty
                    Button {
                        Task { await model.signIn(service) }
                    } label: {
                        HStack {
                            Text(signedIn ? "Add \(service.name) Account" : "Sign In to \(service.name)")
                            if model.signingIn == service {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.signingIn != nil)
                }
            } footer: {
                Text("Signs in to a session of the app's own, the same way `claude login` and `codex login` do. The sessions on your Mac are not affected.")
            }
        }
    }
}
