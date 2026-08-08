import Foundation

/// A track returned from a streaming provider's catalog search. Deliberately
/// small and provider-neutral. `providerTrackID` is the raw id the player layer
/// loads (e.g. an Apple Music store id).
struct StreamingTrack: Identifiable, Hashable {
    let id: String                     // namespaced: "<provider>:<rawId>"
    let kind: StreamingProviderKind
    let providerTrackID: String        // raw id the player needs
    let title: String
    let artist: String?
    let artworkURL: URL?
    let durationSeconds: Int?
    /// The album this track belongs to, when the provider hands it over. OPTIONAL with an
    /// inline default so every existing constructor keeps compiling — and so a provider that
    /// only knows song-level metadata simply leaves them nil.
    ///
    /// WHY THEY EXIST: without an album identity a Discover ＋Add lands a catalog song with
    /// `albumId == nil`, and SongDetailView then renders NO album hotlink, NO cover art and
    /// NO "Album" row — the user's "tapping the album does nothing" report. These two fields
    /// are the MusicKit half of that fix (the rip-server `/search` proxy is the other half).
    var albumTitle: String? = nil
    /// Apple Music ALBUM store id (the iTunes `collectionId`).
    var albumStoreID: String? = nil
}

/// Catalog search seam, decoupled from `StreamingProvider` (which is about
/// account-link + playback). A provider may offer search without playback (and
/// vice-versa), so this is its own protocol. `@MainActor` because its conformers are
/// UI-driven, MainActor-isolated providers (AppleMusicProvider).
@MainActor
protocol StreamingSearch {
    var kind: StreamingProviderKind { get }
    /// Whether search is usable right now (e.g. the account is authorized).
    var canSearch: Bool { get }
    func search(_ query: String, limit: Int) async throws -> [StreamingTrack]
    /// ALBUM catalog search — Browse ▸ Discover ▸ Albums. Provider-neutral result
    /// (`AppleMusicAlbumRef`, the same value type the recognizer album flow uses).
    /// Defaulted to `[]` so only providers that actually offer album search implement it.
    func searchAlbums(_ query: String, limit: Int) async throws -> [AppleMusicAlbumRef]
}

extension StreamingSearch {
    /// Default: no album search. Overridden by `AppleMusicProvider`.
    func searchAlbums(_ query: String, limit: Int) async throws -> [AppleMusicAlbumRef] { [] }
}

/// Errors surfaced to the UI so Settings can show an actionable message
/// (re-link, you're rate-limited, …).
enum StreamingError: Error, LocalizedError {
    case notConfigured            // provider not available / not set up
    case notLinked                // account authorization required but absent
    case quotaExceeded            // provider rate/quota limit hit
    case http(Int)
    case decoding
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "This streaming source isn’t available."
        case .notLinked:     return "Sign in to your streaming account in Settings."
        case .quotaExceeded: return "Streaming search quota reached — try again later."
        case .http(let c):   return "Streaming request failed (HTTP \(c))."
        case .decoding:      return "Couldn’t read the streaming response."
        case .network(let e): return e.localizedDescription
        }
    }
}
