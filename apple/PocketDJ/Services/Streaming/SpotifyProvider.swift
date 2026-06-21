import Foundation
import Observation

// MARK: - Credentials

/// Where the Spotify client id / redirect URI come from. They are NOT secrets we
/// must hide (the iOS SDK uses the implicit/App-Remote flow — there is no client
/// *secret* on device), but they ARE per-developer: each developer registers
/// their own app in the Spotify dashboard. We read them from the Info.plist so
/// the values can be injected at build time (xcconfig / project.yml) without
/// editing source, and the build still succeeds when they are absent (empty →
/// provider reports `.unavailable`).
///
///   Info.plist keys (injected via project.yml INFOPLIST_KEY_* or an xcconfig):
///     SpotifyClientID      e.g. "0123456789abcdef0123456789abcdef"
///     SpotifyRedirectURL   e.g. "pocketdj://spotify-login-callback"
///
/// The redirect URL's *scheme* (here `pocketdj`) MUST also appear in
/// CFBundleURLTypes (see project.yml) and be registered verbatim as a Redirect
/// URI in the Spotify dashboard.
enum SpotifyCredentials {
    static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
    static var redirectURL: URL? {
        guard let s = (Bundle.main.object(forInfoDictionaryKey: "SpotifyRedirectURL") as? String)?
            .trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return URL(string: s)
    }
    /// Configured == both a non-empty client id and a parseable redirect URL.
    static var isConfigured: Bool { !clientID.isEmpty && redirectURL != nil }
}

// ============================================================================
// MARK: - Real implementation (only when the SDK is linked)
// ============================================================================
#if canImport(SpotifyiOS)
import SpotifyiOS
import UIKit

/// Spotify provider backed by the official iOS SDK (`SPTSessionManager` for OAuth,
/// `SPTAppRemote` for connect/play). Requires:
///   • the `SpotifyiOS` SDK linked (SPM / xcframework),
///   • client id + redirect URI in Info.plist,
///   • the Spotify app installed and a **Premium** account for on-demand play.
@MainActor
@Observable
final class SpotifyProvider: NSObject, StreamingProvider {
    let kind: StreamingProviderKind = .spotify
    private(set) var state: StreamingConnectionState
    var isAvailable: Bool { SpotifyCredentials.isConfigured }

    /// App-Remote scopes we request. App-Remote control (play/pause/skip) needs
    /// `app-remote-control`; `user-read-playback-state` lets us read now-playing.
    private let scopes: SPTScope = [.appRemoteControl, .userReadPlaybackState]

    private lazy var configuration: SPTConfiguration? = {
        guard let redirect = SpotifyCredentials.redirectURL,
              !SpotifyCredentials.clientID.isEmpty else { return nil }
        return SPTConfiguration(clientID: SpotifyCredentials.clientID, redirectURL: redirect)
    }()

    private lazy var sessionManager: SPTSessionManager? = {
        guard let configuration else { return nil }
        return SPTSessionManager(configuration: configuration, delegate: self)
    }()

    private lazy var appRemote: SPTAppRemote? = {
        guard let configuration else { return nil }
        let remote = SPTAppRemote(configuration: configuration, logLevel: .info)
        remote.delegate = self
        return remote
    }()

    /// Pending URI to play once the App Remote connects (Spotify connects lazily
    /// on the first `authorizeAndPlayURI`).
    private var pendingPlayURI: String?

    override init() {
        state = SpotifyCredentials.isConfigured
            ? .loggedOut
            : .unavailable(reason: "Spotify client id / redirect URI not configured.")
        super.init()
    }

    // MARK: Login / logout

    func login() {
        guard isAvailable, let sessionManager else {
            state = .unavailable(reason: "Spotify is not configured in this build.")
            return
        }
        state = .authorizing
        // Hands off to the Spotify app for auth (falls back to a web flow / App
        // Store if Spotify isn't installed). Result arrives in the delegate.
        sessionManager.initiateSession(with: scopes, options: .default, campaign: nil)
    }

    func logout() {
        appRemote?.disconnect()
        appRemote?.connectionParameters.accessToken = nil
        state = .loggedOut
    }

    @discardableResult
    func handleCallback(url: URL) -> Bool {
        guard let redirect = SpotifyCredentials.redirectURL,
              url.scheme == redirect.scheme else { return false }
        sessionManager?.application(UIApplication.shared, open: url, options: [:])
        return true
    }

    // MARK: App Remote lifecycle

    func reconnectIfNeeded() {
        guard let appRemote, appRemote.connectionParameters.accessToken != nil,
              !appRemote.isConnected else { return }
        appRemote.connect()
    }

    func disconnect() {
        guard let appRemote, appRemote.isConnected else { return }
        appRemote.disconnect()
    }

    // MARK: Playback

    func play(uri: String?) {
        guard let appRemote else { return }
        let target = uri ?? ""    // "" resumes the user's last context
        if appRemote.isConnected {
            appRemote.playerAPI?.play(target, callback: handleAPIError)
        } else {
            // Not yet connected: authorizeAndPlayURI both (re)auths and plays,
            // launching the Spotify app if needed.
            pendingPlayURI = target
            appRemote.authorizeAndPlayURI(target)
        }
    }

    func pause() { appRemote?.playerAPI?.pause(handleAPIError) }
    func resume() { appRemote?.playerAPI?.resume(handleAPIError) }

    private func handleAPIError(_ result: Any?, _ error: Error?) {
        if let error { state = .failed(message: error.localizedDescription) }
    }
}

// MARK: SPTSessionManagerDelegate

extension SpotifyProvider: SPTSessionManagerDelegate {
    func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        appRemote?.connectionParameters.accessToken = session.accessToken
        state = .linked(account: nil)
        appRemote?.connect()
    }

    func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        state = .failed(message: friendly(error))
    }

    func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        appRemote?.connectionParameters.accessToken = session.accessToken
    }

    /// Map common failures to actionable copy. Premium is required for on-demand
    /// App-Remote playback; surface that explicitly.
    private func friendly(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("premium") {
            return "A Spotify Premium account is required to control playback."
        }
        if msg.contains("not installed") || msg.contains("app store") {
            return "Install the Spotify app, then log in again."
        }
        return error.localizedDescription
    }
}

// MARK: SPTAppRemoteDelegate

extension SpotifyProvider: SPTAppRemoteDelegate {
    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        state = .connected(account: nil)
        if let uri = pendingPlayURI {
            pendingPlayURI = nil
            appRemote.playerAPI?.play(uri, callback: handleAPIError)
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        // Keep the link (token still valid) but drop to `.linked`.
        if case .connected(let acct) = state { state = .linked(account: acct) }
        if let error { state = .failed(message: error.localizedDescription) }
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        state = .failed(message: error?.localizedDescription ?? "Could not connect to Spotify.")
    }
}

#else
// ============================================================================
// MARK: - Stub (SDK absent — keeps the app compiling + shippable)
// ============================================================================

/// No-op Spotify provider used whenever `SpotifyiOS` is NOT linked. It conforms to
/// the same protocol so the rest of the app (Settings UI, the registry) is
/// SDK-agnostic; every entry point is a safe no-op and the state is permanently
/// `.unavailable`, which the UI renders as a developer note rather than a button.
@MainActor
@Observable
final class SpotifyProvider: StreamingProvider {
    let kind: StreamingProviderKind = .spotify
    private(set) var state: StreamingConnectionState =
        .unavailable(reason: "Spotify SDK not bundled in this build.")
    var isAvailable: Bool { false }

    init() {}

    func login() {}
    func logout() {}
    @discardableResult func handleCallback(url: URL) -> Bool { false }
    func reconnectIfNeeded() {}
    func disconnect() {}
    func play(uri: String?) {}
    func pause() {}
    func resume() {}
}
#endif
