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
                            providerSection(provider, now: context.date)
                        }
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

    /// The Mac's Settings submenu, for the widgets: what each provider
    /// leads with, and the two display toggles.
    private func widgetSettings(now: Date) -> some View {
        Section {
            ForEach(model.providers, id: \.id) { provider in
                if model.isSignedIn(provider), let snapshot = model.engine.state(provider).snapshot {
                    Picker(provider.name, selection: leadingLimit(provider, snapshot: snapshot, now: now)) {
                        ForEach(snapshot.limits.map(\.label), id: \.self) { Text($0) }
                        if !snapshot.stackedBehindHeadline(at: now).isEmpty {
                            Text(stackedChoice).tag(stackedChoice)
                        }
                    }
                }
            }
            Toggle("Show Numbers on Lock Screen", isOn: $model.settings.showNumbers)
            Toggle("Show Pace Marker", isOn: $model.settings.showPace)
        } header: {
            Text("Widgets")
        } footer: {
            Text("Each service's limit leads its lock screen bar, the line above the clock, the small widget, and rings set to As in App. Stacked leads with the session and draws the weekly limits lighter behind it.\n\nThe tick on each bar is how far through the window the clock is. A fill past it means you are burning faster than the window refills.")
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
    private func providerSection(_ provider: any Provider, now: Date) -> some View {
        let _ = model.revision
        let state = model.engine.state(provider)
        let signedIn = model.isSignedIn(provider)
        Section {
            if signedIn {
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
                Button("Open \(provider.name) Usage Page") { openURL(provider.usageURL) }
                Button("Sign Out", role: .destructive) { model.signOut(provider) }
            } else {
                Button {
                    Task { await model.signIn(provider) }
                } label: {
                    HStack {
                        Text("Sign In to \(provider.name)")
                        if model.signingIn == provider.id {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.signingIn != nil)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.name)
                if let plan = state.snapshot?.plan {
                    Text(plan).textCase(nil).foregroundStyle(.tertiary)
                }
                Spacer()
                if model.engine.isFetching(provider) {
                    Text("Updating…").textCase(nil)
                } else if signedIn, let snapshot = state.snapshot {
                    Text(Format.age(snapshot.fetchedAt, now: now)).textCase(nil).monospacedDigit()
                }
            }
        } footer: {
            if !signedIn {
                Text("Signs in to a session of the app's own, the same way `\(provider.id) login` does. The session on your Mac is not affected.")
            }
        }
    }
}
