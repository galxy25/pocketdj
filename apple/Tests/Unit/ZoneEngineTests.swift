import XCTest
@testable import PocketDJ

/// The In Da Zone / collection-suggestion ranking. Every constraint the owner set is a test here:
/// ≤3 songs per artist, 30–90 songs, driven by RECENT activity.
final class ZoneEngineTests: XCTestCase {

    private let day: Double = 86_400_000
    private let now: Double = 1_800_000_000_000

    /// n tracks per artist across `artists`, genre `g<i>` per artist.
    private func catalog(artists: Int, perArtist: Int, genrePerArtist: Bool = true) -> [ZoneEngine.Track] {
        var out: [ZoneEngine.Track] = []
        for a in 0..<artists {
            for t in 0..<perArtist {
                out.append(ZoneEngine.Track(songId: "a\(a)-t\(t)",
                                            artistKey: "artist\(a)",
                                            artistName: "Artist \(a)",
                                            genre: genrePerArtist ? "g\(a)" : nil))
            }
        }
        return out
    }

    // MARK: - The owner's hard constraints

    func testNeverReturnsMoreThanThreeSongsByOneArtist() {
        // One artist, 50 tracks, played constantly — the cap is the only thing that can bound it.
        let tracks = catalog(artists: 1, perArtist: 50)
        let plays = (0..<20).map { ZoneEngine.Play(songId: "a0-t\($0)", playedAtMs: now - 10 * day) }
        let out = ZoneEngine.inDaZone(tracks: tracks, plays: plays,
                                      playCount: { _ in 5 }, nowMs: now)
        XCTAssertEqual(out.count, 3, "one artist can contribute at most 3 songs")
    }

    func testCapAppliesPerArtistNotGlobally() {
        let tracks = catalog(artists: 40, perArtist: 10)
        let plays = (0..<40).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }
        let out = ZoneEngine.inDaZone(tracks: tracks, plays: plays,
                                      playCount: { _ in 1 }, nowMs: now)
        var perArtist: [String: Int] = [:]
        for id in out { perArtist[String(id.split(separator: "-")[0]), default: 0] += 1 }
        XCTAssertTrue(perArtist.values.allSatisfy { $0 <= 3 }, "every artist under the cap")
        XCTAssertGreaterThan(out.count, 3, "many artists ⇒ many songs")
    }

    func testNeverExceedsNinetySongs() {
        // 100 artists × 5 tracks all in the zone = 300 eligible under the per-artist cap.
        let tracks = catalog(artists: 100, perArtist: 5)
        let plays = (0..<100).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }
        let out = ZoneEngine.inDaZone(tracks: tracks, plays: plays,
                                      playCount: { _ in 1 }, nowMs: now)
        XCTAssertEqual(out.count, 90, "the ceiling is 90")
    }

    func testReachesThirtySongsEvenWithNoHistoryAtAll() {
        // Cold start: no plays ⇒ no zone. The fill pass is what keeps the tile useful.
        let tracks = catalog(artists: 30, perArtist: 5)
        let out = ZoneEngine.inDaZone(tracks: tracks, plays: [],
                                      playCount: { Int($0.suffix(1)) ?? 0 }, nowMs: now)
        XCTAssertEqual(out.count, 30, "fills to the floor from most-played")
    }

    func testFillPassStillHonorsThePerArtistCap() {
        // Only 3 artists exist, so the floor of 30 CANNOT be met without breaking the cap.
        // The cap must win: 3 artists × 3 = 9.
        let tracks = catalog(artists: 3, perArtist: 40)
        let out = ZoneEngine.inDaZone(tracks: tracks, plays: [],
                                      playCount: { _ in 3 }, nowMs: now)
        XCTAssertEqual(out.count, 9, "the cap outranks the 30-song floor")
    }

    // MARK: - "Based off your RECENT activity"

    func testRecentArtistOutranksAnEquallyPlayedOlderOne() {
        let tracks = catalog(artists: 2, perArtist: 3)
        let plays = [ZoneEngine.Play(songId: "a0-t0", playedAtMs: now - day),      // yesterday
                     ZoneEngine.Play(songId: "a1-t0", playedAtMs: now - 40 * day)] // 40 days ago
        let out = ZoneEngine.inDaZone(tracks: tracks, plays: plays,
                                      playCount: { _ in 1 }, nowMs: now)
        XCTAssertTrue(out.first?.hasPrefix("a0") == true,
                      "the recently-played artist leads; got \(out.prefix(3))")
    }

    func testPlaysOlderThanTheLookbackContributeNothing() {
        let tracks = catalog(artists: 1, perArtist: 5)
        let ancient = [ZoneEngine.Play(songId: "a0-t0", playedAtMs: now - 400 * day)]
        var tuning = ZoneEngine.Tuning()
        tuning.minSongs = 0     // isolate the zone from the fill pass
        let out = ZoneEngine.inDaZone(tracks: tracks, plays: ancient,
                                      playCount: { _ in 0 }, nowMs: now, tuning: tuning)
        XCTAssertTrue(out.isEmpty, "a play beyond the lookback builds no zone")
    }

    func testJustPlayedSongsAreOnCooldown() {
        let tracks = catalog(artists: 1, perArtist: 5)
        // Played a0-t0 five minutes ago: its artist is red hot, but THAT song is excluded.
        let plays = [ZoneEngine.Play(songId: "a0-t0", playedAtMs: now - 300_000)]
        let out = ZoneEngine.inDaZone(tracks: tracks, plays: plays,
                                      playCount: { _ in 1 }, nowMs: now)
        XCTAssertFalse(out.contains("a0-t0"), "the song you just heard is not offered back")
        XCTAssertFalse(out.isEmpty, "its siblings still are")
    }

    func testGenreCarriesAffinityToADifferentArtist() {
        // Two artists sharing genre "rock"; only artist0 has been played. artist1 should still
        // appear, via genre alone.
        let tracks = [
            ZoneEngine.Track(songId: "s0", artistKey: "artist0", artistName: "A0", genre: "rock"),
            ZoneEngine.Track(songId: "s1", artistKey: "artist1", artistName: "A1", genre: "rock"),
            ZoneEngine.Track(songId: "s2", artistKey: "artist2", artistName: "A2", genre: "polka"),
        ]
        var tuning = ZoneEngine.Tuning()
        tuning.minSongs = 0
        let out = ZoneEngine.inDaZone(tracks: tracks,
                                      plays: [ZoneEngine.Play(songId: "s0", playedAtMs: now - day)],
                                      playCount: { _ in 0 }, nowMs: now, tuning: tuning)
        XCTAssertTrue(out.contains("s1"), "same genre ⇒ in the zone")
        XCTAssertFalse(out.contains("s2"), "unrelated genre ⇒ out of the zone")
    }

    func testANilGenreNeverActsAsASharedBucket() {
        // Songs with no genre must not become "similar" to each other — that is what mapping the
        // catch-all category to nil in AppModel.zoneTracks is defending.
        let tracks = [
            ZoneEngine.Track(songId: "s0", artistKey: "artist0", artistName: "A0", genre: nil),
            ZoneEngine.Track(songId: "s1", artistKey: "artist1", artistName: "A1", genre: nil),
        ]
        var tuning = ZoneEngine.Tuning()
        tuning.minSongs = 0
        let out = ZoneEngine.inDaZone(tracks: tracks,
                                      plays: [ZoneEngine.Play(songId: "s0", playedAtMs: now - day)],
                                      playCount: { _ in 0 }, nowMs: now, tuning: tuning)
        XCTAssertFalse(out.contains("s1"), "nil genre is not a similarity signal")
    }

    func testOutputIsDeterministic() {
        let tracks = catalog(artists: 20, perArtist: 4)
        let plays = (0..<20).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }
        let a = ZoneEngine.inDaZone(tracks: tracks, plays: plays, playCount: { _ in 2 }, nowMs: now)
        let b = ZoneEngine.inDaZone(tracks: tracks, plays: plays, playCount: { _ in 2 }, nowMs: now)
        XCTAssertEqual(a, b, "ties break on song id, so the tile is stable between renders")
    }

    func testEmptyCatalogIsHandled() {
        XCTAssertTrue(ZoneEngine.inDaZone(tracks: [], plays: [], playCount: { _ in 0 },
                                          nowMs: now).isEmpty)
    }

    // MARK: - Collection suggestions

    func testSuggestionsNeverIncludeExistingMembers() {
        let tracks = catalog(artists: 3, perArtist: 6)
        let members = ["a0-t0", "a0-t1", "a1-t0"]
        let out = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                         playCount: { _ in 1 })
        XCTAssertFalse(out.contains(where: members.contains), "never re-suggests what is in it")
    }

    func testSuggestionsMatchTheCollectionsArtistsAndGenres() {
        let tracks = [
            ZoneEngine.Track(songId: "m0", artistKey: "artist0", artistName: "A0", genre: "rock"),
            ZoneEngine.Track(songId: "s1", artistKey: "artist0", artistName: "A0", genre: "rock"),
            ZoneEngine.Track(songId: "s2", artistKey: "artist9", artistName: "A9", genre: "polka"),
        ]
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { _ in 0 })
        XCTAssertEqual(out, ["s1"], "only the artist/genre match is offered")
    }

    func testSuggestionsRespectThePerArtistCapAndTheLimit() {
        let tracks = catalog(artists: 10, perArtist: 20)
        let out = ZoneEngine.suggestions(memberSongIds: ["a0-t0", "a1-t0"], tracks: tracks,
                                         playCount: { _ in 1 }, limit: 25)
        var perArtist: [String: Int] = [:]
        for id in out { perArtist[String(id.split(separator: "-")[0]), default: 0] += 1 }
        XCTAssertTrue(perArtist.values.allSatisfy { $0 <= 3 }, "cap holds for collections too")
        XCTAssertLessThanOrEqual(out.count, 25)
    }

    func testAnEmptyCollectionGetsNoSuggestions() {
        let tracks = catalog(artists: 5, perArtist: 5)
        XCTAssertTrue(ZoneEngine.suggestions(memberSongIds: [], tracks: tracks,
                                             playCount: { _ in 1 }).isEmpty,
                      "no members ⇒ no profile ⇒ no arbitrary suggestions")
    }

    func testACollectionOfUnknownIdsGetsNoSuggestions() {
        // Members that resolve to nothing in the catalog (another source's id space) build no
        // profile, so the engine must decline rather than emit its most-played songs.
        let tracks = catalog(artists: 5, perArtist: 5)
        XCTAssertTrue(ZoneEngine.suggestions(memberSongIds: ["nope-1", "nope-2"], tracks: tracks,
                                             playCount: { _ in 1 }).isEmpty)
    }
}
