import Foundation
import Observation

/// Owns the app's streaming-account providers (currently just Spotify) and routes
/// OAuth redirects + scene-phase lifecycle to them. Injected into the SwiftUI
/// environment like the other stores. This is purely additive — it does NOT touch
/// the URL catalog `SourceConfig`s nor the in-flight native rip playback; a linked
/// streaming account is a SEPARATE kind of source the user opts into in Settings.
@MainActor
@Observable
final class StreamingStore {
    /// Every provider we know about, available or not. The Settings screen renders
    /// one account row per entry; unavailable ones show the developer note.
    let providers: [any StreamingProvider]

    /// Pass `nil` (the default) to build the standard provider set on the main
    /// actor. The providers are `@MainActor`, so they can't be constructed in a
    /// nonisolated default-argument expression — we build them in the body, which
    /// is main-actor-isolated.
    init(providers: [any StreamingProvider]? = nil) {
        self.providers = providers ?? [AppleMusicProvider(), SpotifyProvider(), YouTubeProvider()]
    }

    func provider(_ kind: StreamingProviderKind) -> (any StreamingProvider)? {
        providers.first { $0.kind == kind }
    }

    /// The concrete Apple Music provider (its `resolve(_:)` recognizer is what the
    /// `PlaybackCoordinator`'s Apple Music streaming backend drives). Returns the same
    /// instance held in `providers`, so account-link state stays shared.
    var appleMusicProvider: AppleMusicProvider? {
        providers.compactMap { $0 as? AppleMusicProvider }.first
    }

    /// At least one provider is compiled-in and configured.
    var hasAnyAvailable: Bool { providers.contains { $0.isAvailable } }

    /// Feed an incoming OAuth redirect (from `.onOpenURL`) to whichever provider
    /// claims it. Returns true if handled.
    @discardableResult
    func handleCallback(url: URL) -> Bool {
        for p in providers where p.handleCallback(url: url) { return true }
        return false
    }

    /// Call on `scenePhase` transitions so App Remote connections track app state
    /// (Spotify requires disconnecting when backgrounded, reconnecting on active).
    func onScenePhaseActive() { providers.forEach { $0.reconnectIfNeeded() } }
    func onScenePhaseBackground() { providers.forEach { $0.disconnect() } }
}
