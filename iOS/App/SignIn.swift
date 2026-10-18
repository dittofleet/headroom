import AuthenticationServices
import HeadroomAccounts
import HeadroomCore
import UIKit

/// Signs in the way the CLIs do: the provider's page in a browser sheet,
/// which redirects to a listener on localhost. The sheet is part of the
/// app while it is up, so the app is in front to answer.
@MainActor
final class SignInFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Where the listener sends the sheet once it has the code, which is
    /// what closes the sheet.
    private static let callbackScheme = "headroom"

    private var session: ASWebAuthenticationSession?

    /// Nil when the sheet was dismissed before signing in.
    func run(_ client: OAuthClient) async -> Result<AccountTokens, FetchFailure>? {
        defer { session?.cancel() }
        let signIn = LoopbackSignIn { _ in
            "HTTP/1.1 302 Found\r\nLocation: \(Self.callbackScheme)://signed-in\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        return await signIn.run(client) { url in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(Self.callbackScheme)) { _, error in
                MainActor.assumeIsolated {
                    // The listener has normally answered by the time the
                    // sheet follows its redirect here.
                    signIn.finish(error == nil ? .failure(FetchFailure("Sign-in did not return a code")) : nil)
                }
            }
            // Shares Safari's cookies, so being signed in there already
            // leaves only the consent page.
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                signIn.finish(.failure(FetchFailure("Could not open the sign-in page")))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
