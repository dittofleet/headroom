import AppKit
import HeadroomAccounts
import HeadroomBorrow
import HeadroomCore
import HeadroomMac
import SwiftUI

/// What the Settings window shows and changes. The preferences stay where
/// they live, and this reads them fresh and redraws the menu bar after a
/// change.
@MainActor
final class SettingsModel: ObservableObject {
    let engine: Engine
    /// Nil when this build has no CLI next to it to link.
    let commandLineTool: CLILink?
    private let onChange: () -> Void

    /// The provider waiting on a browser login.
    @Published private(set) var loggingIn: String?
    private var signIn: LoopbackSignIn?

    init(engine: Engine, commandLineTool: CLILink?, onChange: @escaping () -> Void) {
        self.engine = engine
        self.commandLineTool = commandLineTool
        self.onChange = onChange
    }

    private func changed() {
        objectWillChange.send()
        onChange()
    }

    // MARK: Menu bar

    var showNumbers: Bool {
        get { Preferences.showNumbers }
        set { Preferences.showNumbers = newValue; changed() }
    }

    var showPace: Bool {
        get { Preferences.showPace }
        set { Preferences.showPace = newValue; changed() }
    }

    /// Nil until it has numbers, since the limits differ by account.
    func menuBarChoices(_ provider: MacProvider) -> [String]? {
        engine.state(provider).snapshot?.choices(at: Date())
    }

    /// Without numbers, the choice as saved, or the session it defaults to.
    func menuBarChoice(_ provider: MacProvider) -> Binding<String> {
        Binding {
            let saved = Preferences.menuBarLimits[provider.id]
            return self.engine.state(provider).snapshot?.shownChoice(saved, at: Date()) ?? saved ?? "Session"
        } set: {
            Preferences.menuBarLimits[provider.id] = $0
            self.changed()
        }
    }

    // MARK: Credentials

    func usesCLICredentials(_ provider: MacProvider) -> Binding<Bool> {
        Binding {
            LoginPreferences.usesCLICredentials(provider.id)
        } set: { uses in
            uses ? self.useCLICredentials(provider) : self.manageSeparately(provider)
        }
    }

    var passiveMode: Bool {
        get { LoginPreferences.passiveMode }
        set { LoginPreferences.passiveMode = newValue; changed() }
    }

    func isLoggedIn(_ provider: MacProvider) -> Bool {
        accountStore.contains(provider.id)
    }

    func email(_ provider: MacProvider) -> String? {
        accountStore.email(provider.id)
    }

    /// Discards the separate login: nothing would use it.
    private func useCLICredentials(_ provider: MacProvider) {
        if loggingIn == provider.id { cancelLogIn() }
        guard !LoginPreferences.usesCLICredentials(provider.id) else { return }
        LoginPreferences.setUsesCLICredentials(provider.id, true)
        if !accountStore.remove(provider.id) {
            alert("Couldn't remove Headroom's \(provider.name) login", "It is no longer used, but is still in your keychain.")
        }
        restart(provider)
    }

    /// Logged out until Log In is clicked.
    private func manageSeparately(_ provider: MacProvider) {
        guard LoginPreferences.usesCLICredentials(provider.id) else { return }
        LoginPreferences.setUsesCLICredentials(provider.id, false)
        restart(provider)
    }

    /// Stays on separate credentials, so Headroom doesn't fall back to
    /// the CLI's without being asked.
    func logOut(_ provider: MacProvider) {
        guard accountStore.remove(provider.id) else {
            alert("Couldn't log out of \(provider.name)", "The keychain refused to remove the login.")
            return
        }
        restart(provider)
    }

    /// One login at a time: starting another cancels the one waiting.
    func logIn(_ provider: MacProvider) {
        cancelLogIn()
        let signIn = LoopbackSignIn.browser()
        self.signIn = signIn
        loggingIn = provider.id
        Task {
            let result = await signIn.runInBrowser(provider.own.client)
            // Cancelled, or replaced by another login, at any point.
            guard self.signIn === signIn else { return }
            self.signIn = nil
            loggingIn = nil
            switch result {
            case .success(let tokens):
                guard accountStore.save(tokens, for: provider.id) else {
                    alert("Couldn't save the \(provider.name) login", "Logged in, but the keychain refused it.")
                    return
                }
                restart(provider)
            case .failure(let failure):
                alert("Couldn't log in to \(provider.name)", failure.message)
            case nil:
                break
            }
        }
    }

    func cancelLogIn() {
        signIn?.cancel()
        signIn = nil
        loggingIn = nil
    }

    /// The numbers on screen belonged to the credentials just replaced.
    /// Fetches only that provider: the others' numbers still stand.
    private func restart(_ provider: MacProvider) {
        engine.clear(provider)
        engine.refresh()
        changed()
    }

    // MARK: General

    var startAtLogin: Bool {
        get { LoginItem.isEnabled }
        set {
            do { try LoginItem.set(enabled: newValue) } catch { LoginItem.openSystemSettings() }
            changed()
        }
    }

    func installCommandLineTool() {
        guard let commandLineTool else { return }
        let path = (commandLineTool.link.path as NSString).abbreviatingWithTildeInPath
        let replacing = commandLineTool.state == .foreign
        if replacing {
            guard alert("Replace \(path)?", "It already exists and doesn't point at this copy of Headroom.", buttons: ["Replace", "Cancel"]) == .alertFirstButtonReturn else { return }
        }
        do {
            try commandLineTool.install(replacing: replacing)
            let folder = (commandLineTool.link.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            alert("Installed the headroom command", "It is linked at \(path). If your shell can't find it, add \(folder) to your PATH.")
        } catch {
            alert("Couldn't install the command line tool", error.localizedDescription)
        }
        changed()
    }

    func uninstallCommandLineTool() {
        do { try commandLineTool?.uninstall() } catch {
            alert("Couldn't uninstall the command line tool", error.localizedDescription)
        }
        changed()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            ForEach(appProviders, id: \.id) { provider in
                Section(provider.name) {
                    ProviderSettings(model: model, provider: provider)
                }
            }
            Section("General") {
                Toggle("Show numbers in menu bar", isOn: $model.showNumbers)
                Toggle("Show pace marker", isOn: $model.showPace)
                Toggle("Start at login", isOn: $model.startAtLogin)
                if let tool = model.commandLineTool {
                    LabeledContent {
                        switch tool.state {
                        case .installed: Button("Uninstall") { model.uninstallCommandLineTool() }
                        case .stale: Button("Repair") { model.installCommandLineTool() }
                        case .missing, .foreign: Button("Install") { model.installCommandLineTool() }
                        }
                    } label: {
                        Text("Command line tool")
                        Text("`headroom` prints the numbers for agents and scripts")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

private struct ProviderSettings: View {
    @ObservedObject var model: SettingsModel
    let provider: MacProvider

    var body: some View {
        let usesCLI = model.usesCLICredentials(provider)
        Picker("Credentials", selection: usesCLI) {
            Text("Use \(provider.cli) credentials").tag(true)
            Text("Manage credentials separately").tag(false)
        }
        .pickerStyle(.radioGroup)

        if model.loggingIn == provider.id {
            LabeledContent {
                Button("Cancel") { model.cancelLogIn() }
            } label: {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser login")
                }
            }
        } else if usesCLI.wrappedValue {
            if provider.refreshesCLICredentials {
                Toggle(isOn: $model.passiveMode) {
                    Text("Passive mode")
                    Text("Never refresh \(provider.cli) credentials. While they're expired, the numbers wait for \(provider.cli) to refresh them.")
                }
            }
        } else if model.isLoggedIn(provider) {
            LabeledContent {
                Button("Log Out") { model.logOut(provider) }
            } label: {
                Text("Logged in")
                if let email = model.email(provider) { Text(email) }
            }
        } else {
            LabeledContent {
                Button("Log In…") { model.logIn(provider) }
            } label: {
                Text("Logged out")
            }
        }

        let choices = model.menuBarChoices(provider)
        let choice = model.menuBarChoice(provider)
        Picker("Show in menu bar", selection: choice) {
            ForEach(choices ?? [choice.wrappedValue], id: \.self) { Text($0) }
        }
        .disabled(choices == nil)
    }
}

/// A menu bar app has no window to hang this on, so it comes forward first.
@MainActor
@discardableResult
func alert(_ message: String, _ detail: String, buttons: [String] = []) -> NSApplication.ModalResponse {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    buttons.forEach { alert.addButton(withTitle: $0) }
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal()
}

/// The app has no main menu to give ⌘W to, so the window takes it itself.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" else {
            return super.performKeyEquivalent(with: event)
        }
        performClose(nil)
        return true
    }
}
