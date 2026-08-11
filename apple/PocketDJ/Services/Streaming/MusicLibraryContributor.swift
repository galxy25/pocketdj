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
// MARK: - Apple Music library-write OUTCOME (MusicKit-free → unit-testable)
// ============================================================================

/// The TRUTHFUL result of the Apple Music LIBRARY-WRITE half of a Discover "＋ Add".
///
/// BUG (Levi, device, 2026-08-07): four New-tile album adds each logged
/// "Added … to your library" while none of them ever reached his Apple Music library.
/// The write was a `try? await library.addAlbumToLibrary(...)` behind an
/// `if let library, library.canAddToLibrary` — a skipped gate and a swallowed throw were
/// both recorded as success, because nothing recorded the write's outcome at all.
///
/// This type is that record. Every discover-add flow now computes one and stamps it on
/// the provisional entry AND the `.catalogAdd` History event, so "Added to your library"
/// is only ever asserted for a write that RETURNED **and was then found by the
/// library-membership probe** — MusicKit's `add()` returning without throwing is not the
/// same thing as the item being in the library.
enum AppleMusicLibraryWriteOutcome: Equatable {
    /// The write returned AND the post-write membership probe found the item.
    case confirmed
    /// The write returned but the probe could NOT find the item — treated as NOT a
    /// success anywhere the outcome is reported (History, error text, retry gate).
    case unconfirmed
    /// The write threw (auth loss mid-flight, catalog resolve, network, Apple-side).
    case failed(reason: String)
    /// The write was never attempted: no contributor, macOS (`canAddToLibrary` false
    /// by platform), or an unauthorized MusicKit session.
    case skipped(reason: String)

    var isConfirmed: Bool { self == .confirmed }

    /// The token persisted on provisional entries + activity events. `confirmedToken`
    /// for a proven write; otherwise a human-readable annotation ("Apple Music write
    /// failed: …" / "… skipped: …" / "… unconfirmed …") rendered verbatim by History.
    var storageToken: String { annotation ?? Self.confirmedToken }

    /// nil for `.confirmed` (no qualifier owed), else the History-facing annotation.
    var annotation: String? {
        switch self {
        case .confirmed:
            return nil
        case .unconfirmed:
            return "Apple Music write unconfirmed — not visible in your library yet"
        case let .failed(reason):
            return "Apple Music write failed: \(reason)"
        case let .skipped(reason):
            return "Apple Music write skipped: \(reason)"
        }
    }

    /// The persisted marker for a PROVEN write. A nil stored token means the entry
    /// predates outcome tracking (legacy) — treated as NOT proven, so the retry
    /// affordance stays reachable for exactly the adds this bug silently dropped.
    static let confirmedToken = "confirmed"

    /// Whether a stored token proves the Apple Music write landed. nil (legacy entry,
    /// recorded before outcomes existed) is NOT proof — those are the four albums.
    static func provenByToken(_ token: String?) -> Bool { token == confirmedToken }
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
    /// Returns whether the POST-WRITE membership probe actually FOUND the song in the
    /// library — `MusicLibrary.add` returning without throwing is not the same thing
    /// (the Levi four-albums bug). `@discardableResult` keeps the recognizer/detail
    /// call sites (which surface only the throw) compiling unchanged.
    @discardableResult
    func addSongToLibrary(storeID: String) async throws -> Bool

    /// Add the catalog ALBUM (by store id) to the user's library. Throws on failure.
    /// Returns the post-write membership confirmation, exactly like the song variant.
    @discardableResult
    func addAlbumToLibrary(storeID: String) async throws -> Bool

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
