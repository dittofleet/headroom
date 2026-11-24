import Foundation
import HeadroomCore

// The Antigravity CLI's own token. It lasts an hour, and the CLI renews it
// whenever it runs. Outside Passive mode an expired one is renewed by
// running the CLI, which stores the new token itself.

extension AntigravityProvider {
    /// Where the CLI keeps its token without a keychain: on Linux, and on a
    /// Mac when it couldn't write the keychain item.
    static let tokenFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")

    /// The newest of what the CLI has stored: on a Mac it may have left an
    /// older token in the keychain since it fell back to the file, or the
    /// other way around.
    static func credentials() async -> (token: String, expiresAt: Date?)? {
        var stored = [try? Data(contentsOf: tokenFile)]
        #if os(macOS)
        // Through /usr/bin/security, which is how the CLI writes the item, so
        // its access list already trusts it.
        stored.append(await Subprocess.run("/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]))
        #endif
        return stored.compactMap { $0.flatMap(parseCredentials) }
            .max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    static func isExpired(_ creds: (token: String, expiresAt: Date?)) -> Bool {
        creds.expiresAt.map { $0 <= Date() } ?? false
    }

    /// Where the CLI's installer puts it.
    static let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy")

    /// Its cheapest command that signs in: listing the models renews and
    /// stores the token without spending any quota. Without its log, which
    /// would otherwise gain a file every time.
    static func renew() async {
        _ = await Subprocess.run(executable.path, ["--log-file", "/dev/null", "models"], timeout: 30)
    }

    /// The CLI's JSON, which the keychain item holds as go-keyring's base64.
    static func parseCredentials(_ data: Data) -> (token: String, expiresAt: Date?)? {
        let stored = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        let json = stored.hasPrefix(prefix) ? Data(base64Encoded: String(stored.dropFirst(prefix.count))) : Data(stored.utf8)
        guard let token = json.flatMap(Parse.object)?["token"] as? [String: Any],
              let accessToken = token["access_token"] as? String, !accessToken.isEmpty
        else { return nil }
        return (accessToken, Parse.isoDate(token["expiry"]))
    }
}

extension AntigravityProvider: Provider {
    public func fetch() async -> Result<Snapshot, FetchFailure> {
        guard var creds = await Self.credentials() else {
            return .failure(FetchFailure("Not signed in to the Antigravity CLI"))
        }
        let expired = FetchFailure("Login expired, refreshes when the Antigravity CLI next runs")
        let passive = LoginPreferences.isPassive(id)
        if Self.isExpired(creds), !passive {
            await Self.renew()
            creds = await Self.credentials() ?? creds
        }
        // A guaranteed 401, so not sent.
        if Self.isExpired(creds) {
            return .failure(passive ? expired : FetchFailure("Login expired and `agy` couldn't renew it, run `agy` to sign in again"))
        }
        let token = creds.token
        async let plan = PlanLookup.shared.plan(for: id, token: token) { token in
            guard case .success(let data) = await HTTP.post(Self.accountEndpoint, json: Self.accountRequest, headers: Self.headers(token: token), authHint: "") else { return nil }
            return Self.parsePlan(data)
        }
        let body: Data
        switch await HTTP.post(Self.endpoint, json: [:], headers: Self.headers(token: token), authHint: expired.message) {
        case .success(let data): body = data
        case .failure(let failure): return .failure(failure)
        }
        guard var snapshot = Self.parse(body, now: Date()) else { return .failure(FetchFailure("Unrecognized response")) }
        snapshot.plan = await plan
        return .success(snapshot)
    }
}
