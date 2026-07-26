import XCTest
@testable import PocketDJ

/// F3 Sharing — the share-text block: headline "Title — Artist" then one line per service, using a
/// canonical deep-link when the catalog has one and a "search for this track" link otherwise.
final class ShareTextTests: XCTestCase {

    private func song(_ json: String) throws -> IndexSong {
        try JSONDecoder().decode(IndexSong.self, from: Data(json.utf8))
    }

    func testCanonicalWhereResolvedSearchFallbackOtherwise() throws {
        // appleMusicId present (→ id-derived AM link), spotifyUrl resolved (canonical), no youtubeUrl.
        let s = try song(#"{"id":"sng_1","artist":"M83","name":"Midnight City","appleMusicId":"123","spotifyUrl":"https://open.spotify.com/track/abc"}"#)
        let text = ShareText.forSong(s)
        XCTAssertTrue(text.hasPrefix("Midnight City — M83"))
        XCTAssertTrue(text.contains("Apple Music: https://music.apple.com/song/123"))
        XCTAssertTrue(text.contains("Spotify: https://open.spotify.com/track/abc"))   // canonical
        XCTAssertTrue(text.contains("YouTube: https://music.youtube.com/search?q="))  // search fallback
    }

    func testAppleMusicUrlPreferredOverIdAndAllFallbacksWhenBare() throws {
        let s = try song(#"{"id":"sng_2","artist":"Aria","name":"Pulse","appleMusicUrl":"https://music.apple.com/song/999"}"#)
        let text = ShareText.forSong(s)
        XCTAssertTrue(text.contains("Apple Music: https://music.apple.com/song/999"))  // stamped url wins
        XCTAssertTrue(text.contains("Spotify: https://open.spotify.com/search/results/"))  // fallback
        XCTAssertTrue(text.contains("YouTube: https://music.youtube.com/search?q="))    // fallback
    }

    func testBareTitleArtistIsAllSearchLinks() {
        let text = ShareText.forTitleArtist(title: "Untitled", artist: "Nobody")
        XCTAssertTrue(text.hasPrefix("Untitled — Nobody"))
        XCTAssertTrue(text.contains("music.apple.com/search?term="))
        XCTAssertTrue(text.contains("open.spotify.com/search/results/"))
        XCTAssertTrue(text.contains("music.youtube.com/search?q="))
    }

    func testSpotifySearchQueryIsPathSafe() {
        // A "/" or a stray double-space in the title must NOT split Spotify's /search/results/<q>
        // path (that's what left the search box empty) — the query segment is percent-encoded.
        let text = ShareText.forTitleArtist(title: "A/B  Remix", artist: "DJ")
        guard let line = text.split(separator: "\n").first(where: { $0.contains("open.spotify.com") }) else {
            return XCTFail("no spotify line")
        }
        let q = line.components(separatedBy: "/search/results/").last ?? ""
        XCTAssertFalse(q.contains("/"), "a slash in the title must be percent-encoded, got: \(q)")
        XCTAssertFalse(q.contains("  "), "a double space must collapse to one")
        XCTAssertTrue(q.contains("%2F"), "slash should encode to %2F, got: \(q)")
    }

    func testMultipleSongsBlankLineSeparated() throws {
        let a = try song(#"{"id":"a","artist":"A","name":"One"}"#)
        let b = try song(#"{"id":"b","artist":"B","name":"Two"}"#)
        let text = ShareText.forSongs([a, b])
        XCTAssertTrue(text.contains("One — A"))
        XCTAssertTrue(text.contains("Two — B"))
        XCTAssertTrue(text.contains("\n\n"))   // blocks separated by a blank line
    }

    /// The per-service resolvers shared by the share block AND the CSV tracklist export: a direct link
    /// when we have one, else a per-service SEARCH link — never blank. (CSV export fallback, Levi.)
    func testResolversPreferDirectLinkElseSearch() {
        // Direct/canonical link always wins.
        XCTAssertEqual(ShareText.spotifyURL(url: "https://open.spotify.com/track/x", title: "T", artist: "A"),
                       "https://open.spotify.com/track/x")
        XCTAssertEqual(ShareText.youtubeURL(url: "https://music.youtube.com/watch?v=x", title: "T", artist: "A"),
                       "https://music.youtube.com/watch?v=x")
        XCTAssertEqual(ShareText.appleMusicURL(url: "https://music.apple.com/song/9", id: "1", kind: "song",
                                               title: "T", artist: "A"),
                       "https://music.apple.com/song/9")
        // Apple Music with no url but an id → id-derived short link.
        XCTAssertEqual(ShareText.appleMusicURL(url: nil, id: "123", kind: "song", title: "T", artist: "A"),
                       "https://music.apple.com/song/123")
        // Nothing indexed (nil / empty) → search links, so an export cell is never blank.
        XCTAssertTrue(ShareText.spotifyURL(url: nil, title: "T", artist: "A")
            .hasPrefix("https://open.spotify.com/search/results/"))
        XCTAssertTrue(ShareText.youtubeURL(url: "", title: "T", artist: "A")
            .contains("music.youtube.com/search?q="))
        XCTAssertTrue(ShareText.appleMusicURL(url: nil, id: nil, kind: "song", title: "T", artist: "A")
            .contains("music.apple.com/search?term="))
    }
}
