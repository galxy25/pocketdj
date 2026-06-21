import Foundation
import Observation

/// A streaming music account that PocketDJ can link to (Spotify, and later
/// Apple Music subscription, Tidal, …). Unlike a `SourceConfig` — a plain index
/// URL we fetch — a streaming provider is an *account link*: the user logs in via
/// OAuth, we connect our app to their account, and playback is delegated to the
/// provider's app/SDK. This is an ADDITIONAL source kind, orthogonal to the URL
/// catalog sources and to the in-flight native rip playback.
///
/// The protocol is deliberately tiny and SDK-agnostic so the concrete Spotify
/// implementation can live behind `#if canImport(SpotifyiOS)` and a no-op stub
/// can stand in when the SDK / credentials are absent (the app still compiles and
/// ships; the streaming row simply reports `.unavailable`).
public enum StreamingProviderKind: String, Codable, Hashable, CaseIterable {
    case spotify
    case youTube
    case appleMusic

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .youTube: return "YouTube"
        case .appleMusic: return "Apple Music"
        }
    }

    /// SF Symbol used in Settings beside the account row.
    var symbol: String {
        switch self {
        case .spotify: return "music.note"
        case .youTube: return "play.rectangle.fill"
        case .appleMusic: return "music.note.list"
        }
    }
}

/// Coarse connection state surfaced to the UI.
public enum StreamingConnectionState: Equatable {
    /// SDK not compiled in, or no client credentials configured. The row shows a
    /// disabled "Spotify SDK not bundled" note instead of a Log-in button.
    case unavailable(reason: String)
    /// SDK present + configured, but the user has not linked their account.
    case loggedOut
    /// OAuth in flight (handing off to the Spotify app, awaiting the redirect).
    case authorizing
    /// Account linked, access token held, but App Remote not currently connected.
    case linked(account: String?)
    /// App Remote connected — ready to issue play/pause.
    case connected(account: String?)
    /// A user-presentable failure (e.g. Premium required, Spotify not installed).
    case failed(message: String)

    var isLinked: Bool {
        switch self {
        case .linked, .connected: return true
        default: return false
        }
    }
}

/// What every streaming provider must implement. Methods are `@MainActor` because
/// they drive UI state and (for Spotify) must touch UIKit on the main thread.
@MainActor
public protocol StreamingProvider: AnyObject {
    var kind: StreamingProviderKind { get }
    /// Observed by the UI (Observation). Concrete types are `@Observable`.
    var state: StreamingConnectionState { get }

    /// True only when the SDK is compiled in AND client credentials exist. When
    /// false the provider is a no-op stub and Settings shows the developer note.
    var isAvailable: Bool { get }

    /// Begin the OAuth/account-link flow. For Spotify this hands off to the
    /// installed Spotify app (or App Store) and returns immediately; completion
    /// arrives via `handleCallback(url:)`.
    func login()

    /// Sever the link and forget the token.
    func logout()

    /// Feed the OAuth redirect back in (called from `.onOpenURL`). Returns true if
    /// the URL belonged to this provider.
    @discardableResult
    func handleCallback(url: URL) -> Bool

    /// Re-establish the App Remote connection (call on `scenePhase == .active`).
    func reconnectIfNeeded()
    /// Tear the App Remote down (call on background/resign-active).
    func disconnect()

    /// Resolve a play request. `uri` is a provider-native URI
    /// (`spotify:track:…`); pass nil to resume the last track.
    func play(uri: String?)
    func pause()
    func resume()
}
