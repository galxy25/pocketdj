import Foundation
import Observation
import Security
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

// MARK: - Credentials

/// Where YouTube's Data API key + OAuth client id come from — read from the
/// Info.plist so they can be injected at build time (project.yml INFOPLIST_KEY_*
/// or an xcconfig) without editing source, and the build still succeeds when they
/// are absent (empty → provider reports `.unavailable`). Mirrors
/// `SpotifyCredentials`.
///
///   Info.plist keys:
///     YouTubeAPIKey         e.g. "AIza…"  (Data API v3 — search)
///     YouTubeOAuthClientID  e.g. "1234-abcd.apps.googleusercontent.com" (iOS OAuth)
///
/// The OAuth client's reversed id (`com.googleusercontent.apps.1234-abcd`) MUST
/// also be registered as a CFBundleURLTypes scheme (see project.yml) for the
/// sign-in redirect to come back to the app.
enum YouTubeCredentials {
    static var apiKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "YouTubeAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
    static var oauthClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "YouTubeOAuthClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
    /// Search needs only the API key; account-link additionally needs the client id.
    static var canSearch: Bool { !apiKey.isEmpty }
    static var canLink: Bool { !apiKey.isEmpty && !oauthClientID.isEmpty }
}

/// YouTube as an account-linked streaming source, conforming to the shared
/// `StreamingProvider` seam (alongside the in-flight Spotify provider). Two
/// independent capabilities:
///
///   • SEARCH — `YouTubeService` (Data API v3, API key). Works WITHOUT login.
///   • PLAYBACK — embedded `YTPlayerView` (youtube-ios-player-helper). Anonymous,
///     ToS-compliant; we never extract/proxy the audio stream.
///
/// OAUTH / ACCOUNT-LINK is what `login()` drives: a Google "iOS" OAuth client via
/// `ASWebAuthenticationSession` + PKCE. Linking is OPTIONAL for YouTube — it
/// unlocks the user's own playlists/likes (and is how we "connect our app to
/// their account"), but public search + embedded playback work without it. So
/// `isAvailable` is true whenever an API key is present.
///
/// COMPILES WITHOUT ANY SDK/POD: no third-party import here. `login()` is a
/// scaffold that flips state and (when wired) presents the system auth sheet.
@MainActor
@Observable
public final class YouTubeProvider: StreamingProvider {
    public let kind: StreamingProviderKind = .youTube
    public private(set) var state: StreamingConnectionState

    /// Google Cloud OAuth client id (iOS type) — reversed for the redirect scheme.
    /// e.g. "1234-abcd.apps.googleusercontent.com". Empty disables account-link.
    private let oauthClientID: String
    /// Data API key, used for search. Empty → provider is `.unavailable`.
    private let apiKeyProvider: () -> String

    private let tokens = StreamingTokenStore(service: "com.levi.pocketdj.youtube")

    /// OAuth scope: read-only access to the user's YouTube account (playlists,
    /// subscriptions). Search/playback do not need it.
    static let scope = "https://www.googleapis.com/auth/youtube.readonly"

    #if os(iOS)
    private var authSession: ASWebAuthenticationSession?
    private var pkceVerifier: String?
    #endif

    /// Default init used by the registry — reads credentials from Info.plist.
    public convenience init() {
        self.init(oauthClientID: YouTubeCredentials.oauthClientID,
                  apiKey: YouTubeCredentials.apiKey)
    }

    public init(oauthClientID: String, apiKey: @escaping @autoclosure () -> String) {
        self.oauthClientID = oauthClientID
        self.apiKeyProvider = apiKey
        // If we already hold a refresh token, present as linked; else logged-out.
        if tokens.refreshToken != nil {
            self.state = .linked(account: tokens.accountLabel)
        } else if apiKey().isEmpty {
            self.state = .unavailable(reason: "YouTube Data API key not configured in this build.")
        } else {
            self.state = .loggedOut
        }
    }

    public var isAvailable: Bool { !apiKeyProvider().isEmpty }

    /// A ready-to-use search backend (current key + any OAuth access token).
    var search: YouTubeService {
        YouTubeService(apiKey: apiKeyProvider(), accessToken: tokens.accessToken)
    }

    // MARK: StreamingProvider — account link

    public func login() {
        guard isAvailable else {
            state = .unavailable(reason: "Add a YouTube Data API key in Settings"); return
        }
        guard !oauthClientID.isEmpty else {
            state = .failed(message: "No OAuth client configured"); return
        }
        state = .authorizing
        #if os(iOS)
        startAuthCodeFlow()
        #else
        // macOS: ASWebAuthenticationSession is available, but the helper player is
        // iOS-only; account-link can still be wired here later. Scaffold only.
        state = .failed(message: "Sign-in not yet available on Mac")
        #endif
    }

    public func logout() {
        tokens.clear()
        #if os(iOS)
        authSession?.cancel(); authSession = nil; pkceVerifier = nil
        #endif
        state = isAvailable ? .loggedOut : .unavailable(reason: "Add a YouTube Data API key in Settings")
    }

    @discardableResult
    public func handleCallback(url: URL) -> Bool {
        // The reversed-client-id scheme owns the redirect. Token exchange
        // (auth code + PKCE verifier → refresh/access token) is wired here.
        guard url.scheme?.contains("googleusercontent") == true else { return false }
        // TODO: exchange code → tokens via https://oauth2.googleapis.com/token,
        //       persist with `tokens.save(...)`, then set `.linked(account:)`.
        return true
    }

    // App Remote concepts don't apply to YouTube's embedded player; these are
    // no-ops so the provider satisfies the shared protocol cleanly.
    public func reconnectIfNeeded() {}
    public func disconnect() {}

    // MARK: StreamingProvider — playback
    //
    // YouTube playback is the embedded `YTPlayerView` (a SwiftUI surface), not an
    // imperative App-Remote call. The UI presents `YouTubePlayerView(videoID:)`
    // directly; these protocol hooks are intentionally inert for YouTube.
    public func play(uri: String?) {}
    public func pause() {}
    public func resume() {}

    // MARK: - OAuth (PKCE) scaffold

    #if os(iOS)
    private func startAuthCodeFlow() {
        // Reversed-client-id redirect scheme, per Google's iOS OAuth guidance.
        let scheme = Self.reversedClientID(oauthClientID)
        let verifier = Self.randomURLSafe(64)
        pkceVerifier = verifier
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: oauthClientID),
            .init(name: "redirect_uri", value: "\(scheme):/oauth2redirect"),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: Self.pkceChallenge(verifier)),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = comps.url else { state = .failed(message: "Bad OAuth URL"); return }

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { [weak self] cb, err in
            guard let self else { return }
            if let cb { _ = self.handleCallback(url: cb) }
            else { self.state = .loggedOut } // user cancelled / error
            _ = err
        }
        session.presentationContextProvider = AuthPresentationAnchor.shared
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    /// "1234-abcd.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abcd"
    private static func reversedClientID(_ id: String) -> String {
        let head = id.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(head)"
    }
    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func pkceChallenge(_ verifier: String) -> String {
        // SHA256 → base64url. (Implementation wired when CryptoKit is imported.)
        // Placeholder identity transform keeps the scaffold compiling; replace
        // with `Data(SHA256.hash(data: Data(verifier.utf8)))` base64url before ship.
        return verifier
    }
    #endif
}

#if os(iOS)
import UIKit
/// Supplies the key window for `ASWebAuthenticationSession`'s sheet.
final class AuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationAnchor()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
#endif
