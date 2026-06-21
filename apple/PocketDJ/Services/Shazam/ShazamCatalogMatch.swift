import Foundation

// ============================================================================
// MARK: - Provider-neutral recognition result (ShazamKit-free → unit-testable)
// ============================================================================

/// The handful of fields we need off a Shazam hit, with NO ShazamKit type so the
/// matching logic can be tested without the framework. The `#if canImport(ShazamKit)`
/// bridge in `ShazamRecognizer` builds one of these from an `SHMediaItem`.
struct ShazamHitInfo: Hashable {
    let title: String?
    let artist: String?
    let artworkURL: URL?
    /// Apple Music store id, when Shazam returns one — the bridge a connected
    /// `AppleMusicProvider` (`SongRecognizer`) uses to resolve a playable track.
    let appleMusicID: String?
}

/// Where a Shazam recognition landed against OUR catalog.
enum ShazamMatch: Equatable {
    /// The recognized track maps to a song already in the catalog → deep-link
    /// straight into `SongDetailView`.
    case inCatalog(song: IndexSong, info: ShazamHitInfo)
    /// Recognized, but not in our catalog. The `info` (esp. `appleMusicID`) can
    /// still feed the streaming `SongRecognizer` bridge to offer playback.
    case notInCatalog(info: ShazamHitInfo)
}

// ============================================================================
// MARK: - Matcher (pure: catalog rows + a hit → a match)
// ============================================================================

/// Resolves a Shazam hit to a catalog song by **normalized** title + artist, so
/// store-edition noise ("Café (Remastered 2011)" vs "Cafe") doesn't block a match.
/// Pure and synchronous; the async mic/recognition lives in `ShazamRecognizer`.
enum ShazamCatalogMatch {

    /// Normalize a title/artist for comparison:
    ///   • lowercase, fold diacritics ("Café" → "cafe"),
    ///   • drop parenthetical / bracketed tails ("(feat. X)", "[Remastered]"),
    ///   • drop a trailing " - remastered / live / mono …" dash clause,
    ///   • strip remaining punctuation, collapse whitespace.
    static func norm(_ raw: String) -> String {
        var s = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                            locale: Locale(identifier: "en_US"))
        // Remove (…) and […] tails.
        s = s.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        // Drop a trailing " - <edition clause>" (remaster/remastered/live/mono/…).
        s = s.replacingOccurrences(
            of: "\\s-\\s.*(remaster|remastered|live|mono|stereo|version|edit|mix|deluxe|anniversary).*$",
            with: " ", options: [.regularExpression, .caseInsensitive])
        // Strip non-alphanumeric (keep spaces), collapse whitespace.
        s = s.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Resolve a hit against a song list. A match requires the normalized titles to
    /// be equal AND the normalized artists to be compatible (one contains the
    /// other — Shazam's "Artist" vs our "Artist feat. Y"). First catalog hit wins.
    static func resolve(_ info: ShazamHitInfo, in songs: [IndexSong]) -> ShazamMatch {
        guard let title = info.title.map(norm), !title.isEmpty else {
            return .notInCatalog(info: info)
        }
        let artist = info.artist.map(norm)
        let hit = songs.first { song in
            guard norm(song.name) == title else { return false }
            guard let a = artist, !a.isEmpty else { return true } // no artist to disambiguate
            let sa = norm(song.artist)
            return sa == a || sa.contains(a) || a.contains(sa)
        }
        if let hit { return .inCatalog(song: hit, info: info) }
        return .notInCatalog(info: info)
    }
}
