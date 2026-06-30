import Foundation
import Observation

/// A streaming music account that PocketDJ can link to (currently Apple Music; the
/// protocol leaves room for others later). Unlike a `SourceConfig` — a plain index
/// URL we fetch — a streaming provider is an *account link*: the user authorizes
/// their account and playback is delegated to the provider's app/SDK. This is an
/// ADDITIONAL source kind, orthogonal to the URL catalog sources and the native rip
/// playback.
///
/// The protocol is deliberately tiny and SDK-agnostic so a provider can live behind
/// a capability check and a no-op stub can stand in when its SDK / credentials are
/// absent (the app still compiles and ships; the streaming row reports `.unavailable`).
public enum StreamingProviderKind: String, Codable, Hashable, CaseIterable {
    case appleMusic

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        }
    }

    /// SF Symbol used in Settings beside the account row.
    var symbol: String {
        switch self {
        case .appleMusic: return "music.note.list"
        }
    }
}

/// Coarse connection state surfaced to the UI.
public enum StreamingConnectionState: Equatable {
    /// SDK not compiled in, or not configured. The row shows a disabled
    /// "not available" note instead of a Log-in button.
    case unavailable(reason: String)
    /// Available + configured, but the user has not linked their account.
    case loggedOut
    /// Authorization in flight (handing off to the provider, awaiting the result).
    case authorizing
    /// Account linked / authorized, but the remote session isn't currently connected.
    case linked(account: String?)
    /// Connected — ready to issue play/pause.
    case connected(account: String?)
    /// A user-presentable failure (e.g. an account or the provider's app is required).
    case failed(message: String)

    var isLinked: Bool {
        switch self {
        case .linked, .connected: return true
        default: return false
        }
    }
}

/// What every streaming provider must implement. Methods are `@MainActor` because
/// they drive UI state and (for some providers) must touch UIKit on the main thread.
@MainActor
public protocol StreamingProvider: AnyObject {
    var kind: StreamingProviderKind { get }
    /// Observed by the UI (Observation). Concrete types are `@Observable`.
    var state: StreamingConnectionState { get }

    /// True only when the SDK is compiled in AND client credentials exist. When
    /// false the provider is a no-op stub and Settings shows the developer note.
    var isAvailable: Bool { get }

    /// Begin the account-link/authorization flow. For an OAuth provider this hands
    /// off to its app (or the App Store) and returns immediately; completion arrives
    /// via `handleCallback(url:)`.
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

    /// Resolve a play request. `uri` is a provider-native id/URI; pass nil to resume
    /// the last track.
    func play(uri: String?)
    func pause()
    func resume()
}
