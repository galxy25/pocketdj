import Foundation

/// A track returned from a streaming provider's catalog search. Deliberately
/// small and provider-neutral; the player layer is separate (see
/// `YouTubePlayerView`). `providerTrackID` is what the player loads — a YouTube
/// videoId for the YouTube provider, a `spotify:track:…` URI for Spotify.
struct StreamingTrack: Identifiable, Hashable {
    let id: String                     // namespaced: "youtube:<videoId>"
    let kind: StreamingProviderKind
    let providerTrackID: String        // raw id the player needs (e.g. videoId)
    let title: String
    let artist: String?                // channelTitle for YouTube
    let artworkURL: URL?
    let durationSeconds: Int?          // nil unless a videos.list lookup was done
}

/// Catalog search seam, decoupled from `StreamingProvider` (which is about
/// account-link + playback). YouTube searches via the Data API; Spotify would
/// search via the Web API. A provider may offer search without playback (and
/// vice-versa), so this is its own protocol. `@MainActor` because its conformers are
/// UI-driven, MainActor-isolated providers (AppleMusicProvider, YouTubeService).
@MainActor
protocol StreamingSearch {
    var kind: StreamingProviderKind { get }
    /// Whether search is usable right now (e.g. an API key is present).
    var canSearch: Bool { get }
    func search(_ query: String, limit: Int) async throws -> [StreamingTrack]
}

/// Errors surfaced to the UI so Settings can show an actionable message
/// (re-link, add key, you're rate-limited, …).
enum StreamingError: Error, LocalizedError {
    case notConfigured            // no API key
    case notLinked                // OAuth required but no session
    case quotaExceeded            // Data API daily quota hit (HTTP 403 quota)
    case http(Int)
    case decoding
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add a YouTube Data API key in Settings."
        case .notLinked:     return "Sign in to YouTube to use this source."
        case .quotaExceeded: return "YouTube search quota for today is used up."
        case .http(let c):   return "YouTube request failed (HTTP \(c))."
        case .decoding:      return "Couldn’t read the YouTube response."
        case .network(let e): return e.localizedDescription
        }
    }
}
