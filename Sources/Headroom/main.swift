import AppKit
import HeadroomCore

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine: Engine
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var menuIsOpen = false
    private var iconRows: [StatusIcon.Row]?
    private var iconBadged = false
    private let updates = UpdateController()

    init(engine: Engine) {
        self.engine = engine
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false

        engine.onChange = { [weak self] in self?.render() }
        updates.onChange = { [weak self] in self?.render() }
        render()
        engine.refresh()
        updates.tick()
        LoginItem.repairIfMoved()

        // One cheap tick a minute: it fetches only what is due, and keeps
        // countdowns and rolled-over windows honest in between.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.refresh()
                self?.updates.tick()
                self?.render()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the network a moment to come back after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                MainActor.assumeIsolated { self?.engine.refresh() }
            }
        }
    }

    // MARK: Rendering

    private func render() {
        let now = Date()
        // Most ticks change nothing; keep the image AppKit already rasterized.
        let rows = StatusIcon.rows(engine: engine, now: now)
        let badged = updates.installed != nil
        if rows != iconRows || badged != iconBadged {
            (iconRows, iconBadged) = (rows, badged)
            statusItem.button?.image = StatusIcon.image(rows: rows, badge: badged)
        }
        statusItem.button?.setAccessibilityLabel(accessibilitySummary(now: now))
        if menuIsOpen { buildMenu(now: now) }
    }

    private func accessibilitySummary(now: Date) -> String {
        engine.providers.map { provider in
            let headline = engine.state(provider).snapshot?.headline(at: now)
            return "\(provider.name) \(headline.map { Format.percent($0.percent(at: now)) } ?? "unknown")"
        }.joined(separator: ", ")
    }

    private func buildMenu(now: Date) {
        menu.removeAllItems()
        for group in menuViews(engine: engine, now: now) {
            for view in group {
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(actionItem("Refresh Now", #selector(refreshNow), key: "r"))
        for (index, provider) in engine.providers.enumerated() {
            let item = actionItem("Open \(provider.name) Usage Page", #selector(openUsagePage(_:)))
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = actionItem("Start at Login", #selector(toggleStartAtLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let about = NSMenuItem(title: ["Headroom \(appVersion)", updates.status].compactMap { $0 }.joined(separator: " · "), action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        if updates.installed != nil {
            menu.addItem(actionItem("Restart to Update", #selector(restartToUpdate)))
        } else if updates.canUpdate {
            menu.addItem(actionItem("Check for Updates", #selector(checkForUpdates)))
        }
        menu.addItem(actionItem("Quit Headroom", #selector(quit), key: "q"))
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        buildMenu(now: Date())
        // Looking is the moment freshness matters; still bounded by the
        // engine's floor and any server cooldown.
        engine.refresh(manual: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    @objc private func refreshNow() {
        engine.refresh(manual: true)
    }

    @objc private func toggleStartAtLogin() {
        try? LoginItem.set(enabled: !LoginItem.isEnabled)
    }

    @objc private func restartToUpdate() {
        updates.restart()
    }

    @objc private func checkForUpdates() {
        updates.check()
    }

    @objc private func openUsagePage(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(engine.providers[sender.tag].usageURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: Entry point

let providers: [any Provider] = [ClaudeProvider(), CodexProvider()]
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print(appVersion)
    exit(0)
}

if let index = arguments.firstIndex(of: "--login-item") {
    // For install.sh and diagnostics: on, off, or (anything else) just report.
    do {
        switch arguments.dropFirst(index + 1).first {
        case "on": try LoginItem.set(enabled: true)
        case "off": try LoginItem.set(enabled: false)
        default: break
        }
        print(LoginItem.isEnabled ? "on" : "off")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("login item: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if arguments.contains("--print") {
    // Diagnostic: one fetch per provider, no cache, no UI.
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        for provider in providers {
            switch await provider.fetch() {
            case .success(let snapshot):
                print("\(provider.name)\(snapshot.plan.map { " (\($0))" } ?? "")")
                for limit in snapshot.limits {
                    print("  \(limit.label): \(Format.percent(limit.percent)) · \(Format.reset(limit.resetsAt, now: Date()))")
                }
            case .failure(let failure):
                print("\(provider.name): \(failure.message)")
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let cacheFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("headroom/state.json")

    if let index = arguments.firstIndex(of: "--render"), let path = arguments.dropFirst(index + 1).first {
        // Diagnostic: draw the icon and menu rows from cached state to a PNG.
        let engine = Engine(providers: providers, cacheFile: cacheFile)
        do {
            try Render.png(engine: engine, to: URL(fileURLWithPath: path), dark: arguments.contains("--dark"), badge: arguments.contains("--badge"))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    // A second copy would double the request rate against a tiny quota.
    if let bundleID = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate(engine: Engine(providers: providers, cacheFile: cacheFile))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
