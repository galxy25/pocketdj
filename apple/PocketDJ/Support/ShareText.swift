import Foundation

/// Builds the shareable TEXT BLOCK for a song or album (F3 — Sharing): a headline "Title — Artist"
/// then one line per music service, ready to paste into iMessage / email. Canonical deep-links are
/// used when the catalog has them (Apple Music from the deployed `appleMusicUrl` / `appleMusicId`;
/// Spotify + YouTube from the backfilled `spotifyUrl` / `youtubeUrl`); otherwise a "search for this
/// track" deep-link so the recipient still lands on it today, before the backfill has resolved a
/// canonical URL. Plain text — no markup.
enum ShareText {

    private static func query(_ title: String, _ artist: String) -> String {
        let s = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// Apple Music: canonical URL → `appleMusicId`-derived short link → catalog search.
    private static func appleMusicLine(url: String?, id: String?, kind: String,
                                       title: String, artist: String) -> String {
        if let url, !url.isEmpty { return url }
        if let id, !id.isEmpty { return "https://music.apple.com/\(kind)/\(id)" }
        return "https://music.apple.com/search?term=\(query(title, artist))"
    }
    private static func spotifyLine(url: String?, title: String, artist: String) -> String {
        (url?.isEmpty == false ? url! : "https://open.spotify.com/search/\(query(title, artist))")
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
}
