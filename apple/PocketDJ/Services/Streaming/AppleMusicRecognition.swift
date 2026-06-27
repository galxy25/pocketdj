import Foundation

// ============================================================================
// MARK: - Pure recognition → Apple Music action reducer (no MusicKit, no UI)
// ============================================================================

/// What the Shazam "Heard it" sheet's Apple Music section should offer, derived purely
/// from (availability · link state · resolution · whether the album is in our index).
/// Pure + value-typed so the branch logic is unit-testable without MusicKit or SwiftUI.
enum AppleMusicRecognitionAction: Equatable {
    /// Apple Music isn't compiled-in / enabled in this build → show nothing.
    case unavailable
    /// Available, but the account isn't linked (or has no playback subscription) →
    /// offer to connect.
    case connect
    /// A resolve is in flight → show a spinner.
    case checking
    /// Resolved but matched nothing in the Apple Music catalog → nothing to do.
    case notFound
    /// In the user's library AND the album is in OUR index → deep-link in-app.
    case openIndexAlbum(albumID: String)
    /// In the user's library but the album is NOT in our index → the synthesized
    /// "recognized album" screen (which itself offers ＋ add-to-library).
    case openRecognizedAlbum(AppleMusicAlbumRef)
    /// In the library, but no album resolved → purely informational ("In your library").
    case inLibrary
    /// Not in the library AND this platform can't add (macOS) → open it in Apple Music
    /// so the user can add it there.
    case openInMusicApp(URL)
    /// Not in the library → offer ＋ (add to library + burn to device).
    case addToLibrary(storeID: String, title: String, artist: String)
}

/// Pure helpers for the recognizer → Apple Music library flow.
enum AppleMusicRecognition {

    /// Decide the section's action. `indexAlbumID` is the id of the catalog album that
    /// matches the resolved Apple Music album (nil when not in our index) — the caller
    /// computes it via `indexAlbum(matching:in:)` so this stays a pure scalar reducer.
    static func action(available: Bool,
                       canContribute: Bool,
                       canAdd: Bool,
                       resolving: Bool,
                       resolution: AppleMusicResolution?,
                       indexAlbumID: String?) -> AppleMusicRecognitionAction {
        guard available else { return .unavailable }
        guard canContribute else { return .connect }
        if resolving { return .checking }
        guard let r = resolution else { return .notFound }
        if r.inLibrary {
            if let id = indexAlbumID { return .openIndexAlbum(albumID: id) }
            if let album = r.album { return .openRecognizedAlbum(album) }
            return .inLibrary
        }
        if canAdd { return .addToLibrary(storeID: r.songStoreID, title: r.title, artist: r.artist) }
        if let url = r.songURL { return .openInMusicApp(url) }
        return .notFound
    }

    /// Find the catalog album that matches a resolved Apple Music album, by NORMALIZED
    /// title + compatible artist (reusing `ShazamCatalogMatch.norm`, so store-edition
    /// noise like "(Deluxe)" / "Café" doesn't block a match). First catalog hit wins;
    /// nil when the album isn't in our index.
    static func indexAlbum(matching ref: AppleMusicAlbumRef, in albums: [IndexAlbum]) -> IndexAlbum? {
        let title = ShazamCatalogMatch.norm(ref.title)
        guard !title.isEmpty else { return nil }
        let artist = ShazamCatalogMatch.norm(ref.artist)
        return albums.first { album in
            guard ShazamCatalogMatch.norm(album.name) == title else { return false }
            guard !artist.isEmpty else { return true }
            let aa = ShazamCatalogMatch.norm(album.artist)
            return aa == artist || aa.contains(artist) || artist.contains(aa)
        }
    }

    /// The stable PocketDJ song id used to RIP + BURN a recognized track: the existing
    /// catalog song's id when the track is already indexed (so the burn associates with
    /// it), else a colon-free synthetic `amrec_<storeID>` (a bare `am:<storeID>` would
    /// put a colon in the S3 key / on-disk filename). Pure so it's testable.
    static func burnSongID(catalogSongID: String?, storeID: String) -> String {
        if let id = catalogSongID, !id.isEmpty { return id }
        return "amrec_\(storeID)"
    }

    /// Find an already-indexed catalog song for a recognized Apple Music track: by our
    /// namespaced `am:<storeID>` id, by the `appleMusicId` the indexer stamped, else by
    /// normalized title + compatible artist. nil when the track isn't in our catalog.
    static func indexSong(storeID: String, title: String?, artist: String?,
                          in songs: [IndexSong]) -> IndexSong? {
        let namespaced = AppleMusicCatalog.namespacedSongID(storeID)
        if let hit = songs.first(where: { $0.id == namespaced || $0.appleMusicId == storeID }) {
            return hit
        }
        guard let title, case let nt = ShazamCatalogMatch.norm(title), !nt.isEmpty else { return nil }
        let na = artist.map(ShazamCatalogMatch.norm)
        return songs.first { song in
            guard ShazamCatalogMatch.norm(song.name) == nt else { return false }
            guard let na, !na.isEmpty else { return true }
            let sa = ShazamCatalogMatch.norm(song.artist)
            return sa == na || sa.contains(na) || na.contains(sa)
        }
    }
}
