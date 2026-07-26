import XCTest
@testable import PocketDJ

/// Tests for the pure CollectionCatalog count/runtime helpers (Container metadata:
/// total song count + total runtime for playlists, chapters, and pockets).
@MainActor
final class CollectionCatalogTests: XCTestCase {

    // A catalog over the TestData fixture, optionally plus some pockets.
    private func catalog(pockets: [Pocket] = []) throws -> CollectionCatalog {
        let idx = try TestData.index()
        return CollectionCatalog(
            songsById: Dictionary(idx.songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            albumsById: Dictionary(idx.albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            pocketsById: Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    private func seq(_ name: String, _ children: [PlaylistNode]) -> PlaylistNode {
        PlaylistNode(nodeId: "seq_\(name)", kind: .sequence, name: name, children: children)
    }
    private func songNode(_ id: String) -> PlaylistNode { PlaylistNode(nodeId: "n_\(id)", kind: .song, songId: id) }
    private func albumNode(_ id: String) -> PlaylistNode { PlaylistNode(nodeId: "na_\(id)", kind: .album, albumId: id) }
    private func pocketNode(_ id: String) -> PlaylistNode { PlaylistNode(nodeId: "np_\(id)", kind: .pocket, pocketId: id) }
    private func textNode(_ t: String) -> PlaylistNode { PlaylistNode(nodeId: "nt", kind: .text, text: t) }

    // sng_1 222000, sng_2 201000, sng_3 305000 (album alb_1); sng_4 240000, sng_5 263000 (alb_2)

    // MARK: Songs + text

    func testSongNodesCountAndRuntime() throws {
        let cat = try catalog()
        let pl = Playlist(id: "p", name: "P", sequences: [seq("A", [songNode("sng_1"), songNode("sng_2")])], createdAt: 0, updatedAt: 0)
        let s = cat.stats(forPlaylist: pl)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.runtimeMs, 222000 + 201000)
        XCTAssertEqual(s.summary, "2 songs · \(Fmt.longDuration(423000))")
    }

    /// Collection/setlist runtime totals format adaptively (Levi): days+hours, hours+minutes,
    /// else minutes — never a raw pure-minute count.
    func testLongDurationFormatting() {
        XCTAssertEqual(Fmt.longDuration(nil), "–")
        XCTAssertEqual(Fmt.longDuration(0), "–")
        XCTAssertEqual(Fmt.longDuration(423_000), "7m")                    // < 1h, seconds floored
        XCTAssertEqual(Fmt.longDuration(25 * 60_000), "25m")
        XCTAssertEqual(Fmt.longDuration(60 * 60_000), "1h 0m")             // exactly 1 hour
        XCTAssertEqual(Fmt.longDuration(145 * 60_000), "2h 25m")
        XCTAssertEqual(Fmt.longDuration(24 * 60 * 60_000), "1d 0h")        // exactly 1 day
        XCTAssertEqual(Fmt.longDuration((27 * 60 + 3) * 60_000), "1d 3h")  // 1 day 3 hours
    }

    func testTextAndMissingNodesContributeNothing() throws {
        let cat = try catalog()
        let pl = Playlist(id: "p", name: "P", sequences: [seq("A", [
            songNode("sng_1"), textNode("MC break"), songNode("does_not_exist")
        ])], createdAt: 0, updatedAt: 0)
        let s = cat.stats(forPlaylist: pl)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.runtimeMs, 222000)
    }

    // MARK: Albums expand to tracks

    func testAlbumNodeExpandsToTracks() throws {
        let cat = try catalog()
        // alb_1 = sng_1,sng_2,sng_3
        let chap = seq("A", [albumNode("alb_1")])
        let s = cat.stats(forChapter: chap)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.runtimeMs, 222000 + 201000 + 305000)
    }

    // MARK: Pockets resolve (deduped, cycle-guarded)

    func testPocketNodeResolvesDeduped() throws {
        // pocket with own song sng_4 + album alb_1 (sng_1,2,3) → 4 songs.
        let pkt = Pocket(id: "pkt_1", name: "P", songIds: ["sng_4"], albumIds: ["alb_1"])
        let cat = try catalog(pockets: [pkt])
        let chap = seq("A", [pocketNode("pkt_1")])
        let s = cat.stats(forChapter: chap)
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.runtimeMs, 240000 + 222000 + 201000 + 305000)
    }

    func testPocketDedupAcrossChapters() throws {
        // Same pocket referenced in two chapters counts ONCE for the whole playlist.
        let pkt = Pocket(id: "pkt_1", name: "P", songIds: ["sng_1", "sng_2"])
        let cat = try catalog(pockets: [pkt])
        let pl = Playlist(id: "p", name: "P", sequences: [
            seq("A", [pocketNode("pkt_1")]),
            seq("B", [pocketNode("pkt_1")])
        ], createdAt: 0, updatedAt: 0)
        let s = cat.stats(forPlaylist: pl)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.runtimeMs, 222000 + 201000)
    }

    func testNestedPocketCycleGuard() throws {
        // A → B → A (cycle). Resolution must terminate and dedup members.
        let a = Pocket(id: "pkt_a", name: "A", songIds: ["sng_1"], childPocketIds: ["pkt_b"])
        let b = Pocket(id: "pkt_b", name: "B", songIds: ["sng_2"], childPocketIds: ["pkt_a"])
        let cat = try catalog(pockets: [a, b])
        let s = cat.stats(forPocket: "pkt_a")
        XCTAssertEqual(s.count, 2)   // sng_1 + sng_2, A revisit guarded
        XCTAssertEqual(s.runtimeMs, 222000 + 201000)
    }

    func testPocketStatsViaResolve() throws {
        let pkt = Pocket(id: "pkt_1", name: "P", albumIds: ["alb_2"])  // sng_4,sng_5
        let cat = try catalog(pockets: [pkt])
        let s = cat.stats(forPocket: "pkt_1")
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.runtimeMs, 240000 + 263000)
    }

    // MARK: Missing length is treated as 0 ms (a floor, no engine fallback here)

    func testMissingLengthCountsAsZero() throws {
        // Build a catalog with one length-less song.
        let song = IndexSong(id: "sng_x", albumId: nil, artist: "X", name: "No Length",
                             trackNumber: nil, year: nil, sentimentKeywords: nil, explicit: nil,
                             bpm: 120, key: nil, camelot: "8A", length: nil, fileType: nil,
                             lyricsStatus: nil, appleMusicId: nil)
        let cat = CollectionCatalog(songsById: ["sng_x": song], albumsById: [:], pocketsById: [:])
        let chap = seq("A", [songNode("sng_x")])
        let s = cat.stats(forChapter: chap)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.runtimeMs, 0)          // counted, but 0 ms
        XCTAssertEqual(s.summary, "1 song · –")  // Fmt.duration(0) is "–"
    }

    // MARK: Empty container

    func testEmptyPlaylistIsZero() throws {
        let cat = try catalog()
        let pl = Playlist(id: "p", name: "P", sequences: [seq("A", [])], createdAt: 0, updatedAt: 0)
        let s = cat.stats(forPlaylist: pl)
        XCTAssertEqual(s, CollectionCatalog.Stats(count: 0, runtimeMs: 0))
    }
}
