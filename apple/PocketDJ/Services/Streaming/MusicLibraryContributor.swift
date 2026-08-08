import Foundation

// ============================================================================
// MARK: - Provider-neutral library result types (MusicKit-free → unit-testable)
// ============================================================================

/// A flattened Apple Music ALBUM reference, free of any MusicKit type so the
/// recognizer → library flow can be reasoned about (and the action reducer in
/// `AppleMusicRecognition` tested) without the framework linked. The
/// `#if canImport(MusicKit)` provider builds one of these from a `MusicKit.Album`.
struct AppleMusicAlbumRef: Hashable, Identifiable {
    /// Apple Music album store id (`Album.id.rawValue`).
    let storeID: String
    let title: String
    let artist: String
    let year: Int?
    let artworkURL: URL?
    /// `music.apple.com/...` deep link that opens the album in the Music app.
    let url: URL?

    var id: String { storeID }
}

/// The result of resolving a RECOGNIZED track against Apple Music: its catalog
/// identity, whether it is already in the signed-in user's Apple Music **library**,
/// and its album (for deep-linking when present / adding the whole album). The Shazam
/// "Heard it" sheet drives its Apple Music section off this.
struct AppleMusicResolution: Hashable {
    /// Apple Music song store id (the "adam id").
    let songStoreID: String
    let title: String
    let artist: String
    /// True when the catalog song is already in the user's Apple Music library.
    var inLibrary: Bool
    let album: AppleMusicAlbumRef?
    /// `music.apple.com/...` deep link for the SONG — the macOS fallback (where adding to
    /// the library isn't available via MusicKit) opens this so the user can add it there.
    var songURL: URL? = nil
}

// ============================================================================
// MARK: - MusicLibraryContributor seam
// ============================================================================

/// A capability — distinct from `StreamingProvider` (account-link + playback),
/// `StreamingSearch` (free-text browse) and `SongRecognizer` (our-song → provider-track)
/// — that reads + writes the signed-in user's Apple Music **library**. It answers the
/// recognizer flow's two questions:
///   1. "Is the recognized track already in my Apple Music library?" (→ deep-link to
///      its album) and
///   2. "Add this track (and optionally its album) to my library."
///
/// Its own protocol so a future contributor (another subscription service with a
/// writable library) can implement it without being a player, and so the registry can
/// ask `providers.libraryContributors` for whoever can do it right now.
///
/// `@MainActor` to match the rest of the streaming seam; `AnyObject` so the registry can
/// hold `any MusicLibraryContributor` existentials.
@MainActor
protocol MusicLibraryContributor: AnyObject {
    var kind: StreamingProviderKind { get }

    /// True when this contributor can read/write the library right now (account linked
    /// + a subscription that can play catalog content). Distinct from `isAvailable`.
    var canContribute: Bool { get }

    /// True when this platform can actually ADD to the library. `MusicLibrary.add(_:)` is
    /// unavailable on macOS, so the Mac falls back to opening the track in Apple Music.
    var canAddToLibrary: Bool { get }

    /// Resolve a recognized track to its Apple Music catalog identity + library
    /// membership + album. Prefer the `storeID` (Shazam's `appleMusicID`) when present;
    /// fall back to a title/artist search otherwise. Returns nil when nothing matches or
    /// the contributor can't act.
    func resolveForLibrary(storeID: String?, title: String?, artist: String?) async -> AppleMusicResolution?

    /// Add the catalog SONG (by store id) to the user's library. Throws on failure.
    func addSongToLibrary(storeID: String) async throws

    /// Add the catalog ALBUM (by store id) to the user's library. Throws on failure.
    func addAlbumToLibrary(storeID: String) async throws

    /// The album's ordered tracklist, for the synthesized "album not in your index"
    /// screen. Best-effort: returns [] on any failure.
    func albumTracks(albumStoreID: String) async -> [AppleMusicSongRow]

    /// Resolve an ALBUM store id to its catalog reference (title/artist/year/art/URL) —
    /// the "I only have an id" entry point for the album PREVIEW screen, where a Discover
    /// song knows its `albumAppleMusicId` but nothing else about the album. Defaulted to
    /// nil in the extension below so a contributor that can't do it needs no code.
    func album(storeID: String) async -> AppleMusicAlbumRef?
}

extension MusicLibraryContributor {
    /// Default: no id → album lookup. `AppleMusicProvider` overrides it with a real
    /// `MusicCatalogResourceRequest<Album>`.
    func album(storeID: String) async -> AppleMusicAlbumRef? { nil }
}

extension Sequence where Element == any StreamingProvider {
    /// Pull the `MusicLibraryContributor`s out of a provider list.
    /// `providers.libraryContributors` reads better than the raw `compactMap`.
    var libraryContributors: [any MusicLibraryContributor] {
        compactMap { $0 as? (any MusicLibraryContributor) }
    }
}
