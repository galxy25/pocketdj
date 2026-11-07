import XCTest
@testable import PocketDJ

/// The shared vinyl-side layout (`AlbumFileTimeline`) + the boundary-edit derivation
/// (`SegmentOverrides.derive`) that re-times album playback from the waveform editor.
@MainActor
final class AlbumFileTimelineTests: XCTestCase {
    private let manifest: [String: RipsStore.ManifestEntry] = [
        "s2": .init(key: "rips/alb.mp3", source: "analog", startMs: 200_000),
        "s1": .init(key: "rips/alb.mp3", source: "analog", startMs: 1_500),
        "s3": .init(key: "rips/alb.mp3", source: "analog", startMs: 410_000),
        "other": .init(key: "rips/alb2.mp3", source: "analog", startMs: 0),
        "dig": .init(key: "rips/dig.mp3", source: "digital"),
    ]

    func testSegmentsSortedAndScopedToOneFile() {
        let tl = AlbumFileTimeline.forSong("s3", manifest: manifest)
        XCTAssertEqual(tl?.segments.map(\.songId), ["s1", "s2", "s3"])
        XCTAssertNil(AlbumFileTimeline.forSong("dig", manifest: manifest), "a per-song digital rip has no side")
        XCTAssertNil(AlbumFileTimeline.forSong("missing", manifest: manifest))
    }

    func testEachSongEndsWhereTheNextStartsAndTheLastRunsToTheFileEnd() {
        let tl = AlbumFileTimeline.forSong("s1", manifest: manifest)!
        XCTAssertEqual(tl.endMs(of: "s1"), 200_000)
        XCTAssertEqual(tl.endMs(of: "s2"), 410_000)
        XCTAssertNil(tl.endMs(of: "s3"), "the last song plays to the natural end of the file")
        XCTAssertEqual(tl.next(after: "s1")?.songId, "s2")
        XCTAssertNil(tl.next(after: "s3"))
    }

    func testPositionMapsToItsSong() {
        let tl = AlbumFileTimeline.forSong("s1", manifest: manifest)!
        XCTAssertEqual(tl.segment(atMs: 0)?.songId, "s1", "the lead-in groove belongs to the first song")
        XCTAssertEqual(tl.segment(atMs: 199_999)?.songId, "s1")
        XCTAssertEqual(tl.segment(atMs: 200_000)?.songId, "s2")
        XCTAssertEqual(tl.segment(atMs: 9_999_999)?.songId, "s3")
    }

    func testOverridesMoveStartsAndTheLastEnd() {
        let ov = SegmentOverrides.Snapshot(startMs: ["s2": 190_000], endMs: ["s3": 600_000])
        let tl = AlbumFileTimeline.forSong("s1", manifest: manifest, layout: ov)!
        XCTAssertEqual(tl.endMs(of: "s1"), 190_000, "the edited start of s2 ends s1")
        XCTAssertEqual(tl.segment(for: "s2")?.startMs, 190_000)
        XCTAssertEqual(tl.endMs(of: "s3"), 600_000, "the edited end of the side")
    }

    /// A detected end (which runs early on a quiet fade) gets the fade grace, capped at the next
    /// song's start; the last song stops at its detected end + grace instead of playing the
    /// run-out groove to the end of the file.
    func testDetectedEndsGetTheFadeGraceCappedAtTheNextStart() {
        let layout = SegmentOverrides.Snapshot(detectedEndMs: ["s1": 150_000, "s2": 400_000, "s3": 500_000])
        let tl = AlbumFileTimeline.forSong("s1", manifest: manifest, layout: layout)!
        XCTAssertEqual(tl.endMs(of: "s1"), 165_000, "detected end + 15 s grace (the gap after is skipped)")
        XCTAssertEqual(tl.endMs(of: "s2"), 410_000, "grace never runs into the next song")
        XCTAssertEqual(tl.endMs(of: "s3"), 515_000, "the last song stops before the run-out")
        // A user edit is exact (no grace).
        let edited = SegmentOverrides.Snapshot(endMs: ["s1": 170_000], detectedEndMs: ["s1": 150_000])
        XCTAssertEqual(AlbumFileTimeline.forSong("s1", manifest: manifest, layout: edited)?.endMs(of: "s1"), 170_000)
    }

    /// A stale manifest entry still pointing at the side under a song id the album no longer
    /// has must not end a real song early.
    func testNonMembersAreDroppedFromTheSide() {
        var m = manifest
        m["stale"] = .init(key: "rips/alb.mp3", source: "analog", startMs: 100_000)
        let layout = SegmentOverrides.Snapshot(albumOfSong: ["s1": "alb", "s2": "alb", "s3": "alb"],
                                               albumTracks: ["alb": ["s1", "s2", "s3"]])
        XCTAssertEqual(AlbumFileTimeline.forSong("s1", manifest: m, layout: layout)?.endMs(of: "s1"), 200_000)
        XCTAssertEqual(AlbumFileTimeline.forSong("s1", manifest: m)?.endMs(of: "s1"), 100_000,
                       "(without membership the stale entry would cut s1 at 1:40)")
    }

    func testDeriveMapsSegmentDeltasOntoTrackOrder() {
        let album = IndexAlbum(id: "alb", artist: "A", name: "N", coverArt: nil, coverArtSources: nil,
                               genre: nil, year: nil, country: nil, trackList: ["s1", "s2", "s3"],
                               fileType: nil,
                               audioTracks: [
                                .init(trackNumber: 1, startMs: 1_500, endMs: 199_000, durationMs: nil, bpm: nil, key: nil, camelot: nil, keyStrength: nil),
                                .init(trackNumber: 2, startMs: 200_000, endMs: 409_000, durationMs: nil, bpm: nil, key: nil, camelot: nil, keyStrength: nil),
                                .init(trackNumber: 3, startMs: 410_000, endMs: 590_000, durationMs: nil, bpm: nil, key: nil, camelot: nil, keyStrength: nil),
                               ],
                               audioDurationSec: 600, appleMusicId: nil)
        var edit = AlbumEdit()
        edit.audioTracks = [AudioTrackEdit(trackNumber: 2, startMs: 195_000),
                            AudioTrackEdit(trackNumber: 3, endMs: 598_000)]
        let snap = SegmentOverrides.derive(albumEdits: ["alb": edit], rawAlbum: { $0 == "alb" ? album : nil },
                                           orderedSongIds: { $0 == "alb" ? album.trackList : [] })
        XCTAssertEqual(snap.startMs, ["s2": 195_000])
        XCTAssertEqual(snap.endMs, ["s3": 598_000])

        // The effective albums contribute detected ends + membership.
        let withLayout = SegmentOverrides.derive(albumEdits: [:], rawAlbum: { _ in nil }, orderedSongIds: { _ in [] },
                                                 effectiveAlbums: [album])
        XCTAssertEqual(withLayout.detectedEndMs, ["s1": 199_000, "s2": 409_000, "s3": 590_000])
        XCTAssertEqual(withLayout.albumOfSong["s2"], "alb")

        // A track list that doesn't pair 1:1 with the segments is never guessed at.
        let skipped = SegmentOverrides.derive(albumEdits: ["alb": edit], rawAlbum: { _ in album },
                                              orderedSongIds: { _ in ["s1", "s2"] })
        XCTAssertEqual(skipped, .init())
    }
}
