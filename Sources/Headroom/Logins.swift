import AppKit
import HeadroomAccounts
import HeadroomCore
import HeadroomMac

/// Every provider, in menu order, fetched with the credentials Settings
/// picks for it.
let appProviders: [MacProvider] = [
    MacProvider(borrowed: ClaudeProvider(), cli: "Claude Code CLI", refreshesCLICredentials: true, own: ClaudeAccountProvider(store: accountStore)),
    MacProvider(borrowed: CodexProvider(), cli: "Codex CLI", refreshesCLICredentials: false, own: CodexAccountProvider(store: accountStore)),
]

/// Headroom's own logins, for a provider not using its CLI's credentials.
let accountStore = AccountStore(accessGroup: nil, lockDirectory: Engine.defaultCacheFile?.deletingLastPathComponent())

/// A provider's usage with its CLI's credentials, or with a login of
/// Headroom's own.
struct MacProvider: Provider {
    let borrowed: any Provider
    let cli: String
    /// Whether expired CLI credentials are refreshed, outside Passive mode.
    let refreshesCLICredentials: Bool
    let own: any AccountProvider

    var id: String { borrowed.id }
    var name: String { borrowed.name }
    var glyph: String { borrowed.glyph }
    var usageURL: URL { borrowed.usageURL }

    func fetch() async -> Result<Snapshot, FetchFailure> {
        LoginPreferences.usesCLICredentials(id) ? await borrowed.fetch() : await own.fetch()
    }
}

extension LoopbackSignIn {
    /// Long enough to log in, short enough not to keep Codex's one port
    /// from `codex login` all day.
    private static let timeout: TimeInterval = 5 * 60

    /// Logs Headroom in on its own, the way `claude login` and `codex
    /// login` do: the provider's page in the default browser.
    static func browser() -> LoopbackSignIn {
        LoopbackSignIn { result in
            let message = if case .success = result { "You can close this tab and go back to Headroom." } else { "Headroom couldn't log in. You can close this tab." }
            let page = "<!doctype html><meta charset=utf-8><title>Headroom</title><body style=\"font: 15px -apple-system; text-align: center; margin-top: 20vh\">\(message)"
            return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
        }
    }

    func runInBrowser(_ client: OAuthClient) async -> Result<AccountTokens, FetchFailure>? {
        await run(client) { url in
            if !NSWorkspace.shared.open(url) {
                finish(.failure(FetchFailure("Could not open the sign-in page")))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(.failure(FetchFailure("Sign-in timed out"))) }
            }
        }
    }
}
