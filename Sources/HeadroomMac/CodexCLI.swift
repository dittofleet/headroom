import Foundation
import HeadroomCore

// The Codex CLI's own token from auth.json, read-only for the same reason as
// Claude Code's.

extension CodexProvider {
    static func parseCredentials(_ data: Data) -> (token: String, accountID: String?)? {
        guard let tokens = Parse.object(data)?["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        return (token, tokens["account_id"] as? String)
    }
}

extension CodexProvider: Provider {
    public func fetch() async -> Result<Snapshot, FetchFailure> {
        guard let data = try? Data(contentsOf: Self.authFile), let creds = Self.parseCredentials(data) else {
            return .failure(FetchFailure("Not signed in to Codex"))
        }
        let result = await HTTP.get(Self.endpoint, headers: Self.headers(token: creds.token, accountID: creds.accountID), authHint: "Login expired, refreshes when Codex next runs")
        return result.flatMap { data in
            Self.parse(data, now: Date()).map { .success($0) } ?? .failure(FetchFailure("Unrecognized response"))
        }
    }

    private static var authFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }
}
