import Foundation

/// Builds the shareable TEXT BLOCK for a song or album (F3 — Sharing): a headline "Title — Artist"
/// then one line per music service, ready to paste into iMessage / email. Canonical deep-links are
/// used when the catalog has them (Apple Music from the deployed `appleMusicUrl` / `appleMusicId`;
/// Spotify + YouTube from the backfilled `spotifyUrl` / `youtubeUrl`); otherwise a "search for this
/// track" deep-link so the recipient still lands on it today, before the backfill has resolved a
/// canonical URL. Plain text — no markup.
enum ShareText {

    private static func query(_ title: String, _ artist: String) -> String {
        // Collapse any run of whitespace to a single space — a stray double-space leaves Spotify's
        // /search/<q> showing an empty box — then percent-encode for a PATH segment: allow only
        // unreserved characters so a "/" / "?" / "#" in a title can't split the path (space → %20).
        // Also safe for the ?q= / ?term= query-param URLs (Apple Music / YouTube).
        let raw = "\(artist) \(title)".split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let allowed = CharacterSet(charactersIn: "-._~").union(.alphanumerics)
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// Apple Music: canonical URL → `appleMusicId`-derived short link → catalog search.
    private static func appleMusicLine(url: String?, id: String?, kind: String,
                                       title: String, artist: String) -> String {
        if let url, !url.isEmpty { return url }
        if let id, !id.isEmpty { return "https://music.apple.com/\(kind)/\(id)" }
        return "https://music.apple.com/search?term=\(query(title, artist))"
    }
    private static func spotifyLine(url: String?, title: String, artist: String) -> String {
        (url?.isEmpty == false ? url! : "https://open.spotify.com/search/results/\(query(title, artist))")
    }
    private static func youtubeLine(url: String?, title: String, artist: String) -> String {
        (url?.isEmpty == false ? url! : "https://music.youtube.com/search?q=\(query(title, artist))")
    }

    static func forSong(_ s: IndexSong) -> String {
        [
            "\(s.name) — \(s.artist)",
            "Apple Music: \(appleMusicLine(url: s.appleMusicUrl, id: s.appleMusicId, kind: "song", title: s.name, artist: s.artist))",
            "Spotify: \(spotifyLine(url: s.spotifyUrl, title: s.name, artist: s.artist))",
            "YouTube: \(youtubeLine(url: s.youtubeUrl, title: s.name, artist: s.artist))",
        ].joined(separator: "\n")
    }

    static func forAlbum(_ a: IndexAlbum) -> String {
        [
            "\(a.name) — \(a.artist)",
            "Apple Music: \(appleMusicLine(url: a.appleMusicUrl, id: a.appleMusicId, kind: "album", title: a.name, artist: a.artist))",
            "Spotify: \(spotifyLine(url: a.spotifyUrl, title: a.name, artist: a.artist))",
            "YouTube: \(youtubeLine(url: a.youtubeUrl, title: a.name, artist: a.artist))",
        ].joined(separator: "\n")
    }

    /// Several songs (History multi-select share) — one block each, blank-line separated.
    static func forSongs(_ songs: [IndexSong]) -> String {
        songs.map(forSong).joined(separator: "\n\n")
    }

    /// Share block for a bare title/artist — a now-playing track that isn't in the catalog (an
    /// ad-hoc rip / studio item), so there are no stored ids: search links for all three services.
    static func forTitleArtist(title: String, artist: String) -> String {
        [
            "\(title) — \(artist)",
            "Apple Music: https://music.apple.com/search?term=\(query(title, artist))",
            "Spotify: \(spotifyLine(url: nil, title: title, artist: artist))",
            "YouTube: \(youtubeLine(url: nil, title: title, artist: artist))",
        ].joined(separator: "\n")
    }
}
