import Foundation

/// Builds a UNIVERSAL tracklist CSV — the portable columns any tool / spreadsheet understands:
/// `#, Title, Artist, Album, Year, Genre`. PocketDJ-specific metadata (bpm, key, song id, segment
/// timing, provenance…) is deliberately OMITTED — that's what the full-fidelity PocketDJ (`.pocketdj`)
/// export is for. Pure + reusable across playlist / pocket / setlist / session exports.
enum TracklistCSV {

    /// One export row — the universal fields. `#` (play position) is added by `data`.
    struct Row {
        var title: String
        var artist: String
        var album: String
        var year: Int?
        var genre: String
        /// F3 Sharing: per-service links — a direct/canonical link when matched, else a "search for this
        /// track" link (the row builder fills these via the shared `ShareText` resolvers, so an export
        /// never carries a blank cell). Default "" only for the rare row built without a catalog song.
        var appleMusicUrl: String = ""
        var spotifyUrl: String = ""
        var youtubeUrl: String = ""
    }

    static let header = ["#", "Title", "Artist", "Album", "Year", "Genre", "Apple Music", "Spotify", "YouTube"]

    /// UTF-8 CSV bytes: 1-indexed `#` column, CRLF line endings + a trailing CRLF.
    static func data(rows: [Row]) -> Data {
        var lines = [header.joined(separator: ",")]
        for (i, r) in rows.enumerated() {
            let cells = ["\(i + 1)", r.title, r.artist, r.album, r.year.map(String.init) ?? "", r.genre,
                         r.appleMusicUrl, r.spotifyUrl, r.youtubeUrl]
            lines.append(cells.map(cell).joined(separator: ","))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// CSV cell escaping: quote if it contains a comma / quote / newline, doubling any inner quotes.
    private static func cell(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
