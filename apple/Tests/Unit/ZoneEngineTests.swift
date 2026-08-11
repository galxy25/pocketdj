import XCTest
@testable import PocketDJ

/// In Da Zone (the two-pool play queue) and the per-collection suggestion ranking.
///
/// Every constraint the owner set is a test here, and the ones most likely to rot quietly get an
/// ADVERSARIAL case rather than a happy-path one: the 3-per-artist cap is tested with a single
/// artist owning the entire top of BOTH pools, and the ≥50% rediscovery floor is tested on input
/// where the greedy ranking would otherwise prefer familiar songs everywhere.
///
/// A note on what these tests are guarding against. The engine's failure mode is not "returns
/// nothing" — it is "returns something plausible that quietly violates a rule", e.g. a queue that
/// is 100% recent plays, or one artist's discography, or 45 familiar songs followed by 45
/// rediscoveries. Each of those passes "it returned 90 rows". None of them passes below.
final class ZoneEngineTests: XCTestCase {

    private let day: Double = 86_400_000
    private let now: Double = 1_800_000_000_000

    // ========================================================================
    // MARK: - Fixtures
    // ========================================================================

    /// `IndexSong` is Decodable-only — build via the JSON round-trip (the house pattern, same as
    /// `PuzzleSimilarityTests`).
    private func song(_ id: String, artist: String, year: Int? = nil, bpm: Double? = nil,
                      camelot: String? = nil, keywords: [String]? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id.uppercased(), "artist": artist]
        if let year { obj["year"] = year }
        if let bpm { obj["bpm"] = bpm }
        if let camelot { obj["camelot"] = camelot }
        if let keywords { obj["sentimentKeywords"] = keywords }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    /// `artists` × `perArtist` songs. Ids are `a<i>-t<j>`, so `artistOf` can recover the artist
    /// from an id without a lookup table.
    private func catalog(artists: Int, perArtist: Int, year: Int? = 2000) -> [IndexSong] {
        var out: [IndexSong] = []
        for a in 0..<artists {
            for t in 0..<perArtist {
                out.append(song("a\(a)-t\(t)", artist: "Artist \(a)", year: year))
            }
        }
        return out
    }

    /// Genre map giving every one of an artist's songs that artist's own genre.
    private func genrePerArtist(_ songs: [IndexSong]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: songs.map { ($0.id, "g-\($0.artist)") })
    }

    private func artistOf(_ id: String) -> String { String(id.split(separator: "-")[0]) }

    private func zoneTracks(_ songs: [IndexSong], genres: [String: String] = [:]) -> [ZoneEngine.Track] {
        songs.map { ZoneEngine.Track(songId: $0.id, artistKey: $0.artist, artistName: $0.artist,
                                     genre: genres[$0.id]) }
    }

    // ========================================================================
    // MARK: - The owner's hard constraints
    // ========================================================================

    /// THE adversarial cap test the spec calls for: one artist owns the top of BOTH pools.
    ///
    /// Artist 0 has 50 songs; half of them are played constantly (so they dominate the FAMILIAR
    /// ranking) and the other half are dormant songs by that same red-hot artist (so they also
    /// dominate the REDISCOVERY ranking, since artist is `PuzzleSimilarity`'s heaviest term).
    /// A per-pool cap would let artist 0 through SIX times — three per pool. The cap is across
    /// the combined queue, so the answer is three.
    func testThreePerArtistCapHoldsACROSSBothPoolsCombined() {
        var songs = catalog(artists: 20, perArtist: 4)
        for t in 0..<50 { songs.append(song("a0-t\(100 + t)", artist: "Artist 0", year: 2000)) }
        // Artist 0's first 25 extras are red hot; the other 25 are dormant but same-artist.
        let plays = (0..<25).map { ZoneEngine.Play(songId: "a0-t\(100 + $0)", playedAtMs: now - day) }

        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genrePerArtist(songs),
                                    plays: plays, playCount: { _ in 5 },
                                    lastPlayedMs: [:], nowMs: now)

        var perArtist: [String: Int] = [:]
        for id in q.songIds { perArtist[artistOf(id), default: 0] += 1 }
        XCTAssertEqual(perArtist["a0"], 3,
                       "one artist gets 3 TOTAL, not 3 per pool (got \(perArtist["a0"] ?? 0))")
        XCTAssertTrue(perArtist.values.allSatisfy { $0 <= 3 }, "no artist exceeds the cap")
        // And capping must not have shortened the queue: the other 19 artists can still fill it.
        XCTAssertGreaterThanOrEqual(q.count, 30, "capping skips a candidate, it does not truncate")
    }

    func testNeverExceedsNinetySongs() {
        let songs = catalog(artists: 100, perArtist: 5)
        let plays = (0..<100).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genrePerArtist(songs),
                                    plays: plays, playCount: { _ in 1 }, nowMs: now)
        XCTAssertEqual(q.count, 90, "the ceiling is 90")
    }

    func testReachesTheThirtyFloorEvenWithNoHistoryAtAll() {
        // Cold start: no plays ⇒ no taste profile. The queue must still be usable.
        let songs = catalog(artists: 30, perArtist: 5)
        let q = ZoneEngine.inDaZone(songs: songs, plays: [],
                                    playCount: { Int($0.suffix(1)) ?? 0 }, nowMs: now)
        XCTAssertEqual(q.count, 30, "a cold install still gets a full queue")
        // With no recent activity, nothing is "recently played" — so the whole queue is honestly
        // rediscovery, and the floor holds trivially rather than by accident.
        XCTAssertEqual(q.count(.familiar), 0, "no recent plays ⇒ no familiar pool")
    }

    /// The one case where the 30 floor legitimately loses: the cap makes it unreachable.
    func testThePerArtistCapOutranksTheThirtyFloor() {
        let songs = catalog(artists: 3, perArtist: 40)
        let q = ZoneEngine.inDaZone(songs: songs, plays: [], playCount: { _ in 3 }, nowMs: now)
        XCTAssertEqual(q.count, 9, "3 artists × 3 = 9; the cap is non-negotiable, the floor is not")
    }

    /// Queue LENGTH is `maxPerArtist × distinct recent artists`, clamped to 30…90.
    func testQueueLengthTracksTheBreadthOfRecentListening() {
        let songs = catalog(artists: 60, perArtist: 6)
        let genres = genrePerArtist(songs)

        // A narrow binge (4 artists ⇒ 12) clamps UP to the 30 floor.
        let narrow = (0..<4).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }
        XCTAssertEqual(ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: narrow,
                                           playCount: { _ in 1 }, nowMs: now).count, 30)

        // 15 recent artists ⇒ 45, inside the range, so it is used as-is.
        let mid = (0..<15).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }
        XCTAssertEqual(ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: mid,
                                           playCount: { _ in 1 }, nowMs: now).count, 45)

        // 50 recent artists ⇒ 150, clamped DOWN to the 90 ceiling.
        let wide = (0..<50).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }
        XCTAssertEqual(ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: wide,
                                           playCount: { _ in 1 }, nowMs: now).count, 90)
    }

    // ========================================================================
    // MARK: - The blend (the actual feature)
    // ========================================================================

    /// Realistic input: he has been bumping 12 artists this week, and owns a deep back catalogue
    /// by those same artists that he has not touched. At least half the queue must be the latter.
    func testRediscoveryIsAtLeastHalfTheQueueOnRealisticInput() {
        let songs = catalog(artists: 12, perArtist: 40)
        let genres = genrePerArtist(songs)
        // Played t0 and t1 of each artist repeatedly over the last fortnight.
        var plays: [ZoneEngine.Play] = []
        for a in 0..<12 {
            for rep in 0..<6 {
                plays.append(.init(songId: "a\(a)-t0", playedAtMs: now - Double(rep + 1) * day))
                plays.append(.init(songId: "a\(a)-t1", playedAtMs: now - Double(rep + 2) * day))
            }
        }
        // Everything else was last played years ago — genuinely buried.
        var lastPlayed: [String: Double] = [:]
        for s in songs where !s.id.hasSuffix("-t0") && !s.id.hasSuffix("-t1") {
            lastPlayed[s.id] = now - 1500 * day
        }

        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 4 }, lastPlayedMs: lastPlayed, nowMs: now)

        XCTAssertGreaterThanOrEqual(q.rediscoveryShare, 0.5,
            "owner's floor: at least half must be songs he has NOT been playing "
            + "(got \(q.count(.rediscovery))/\(q.count))")
        XCTAssertFalse(q.degradesToFamiliar)
        XCTAssertGreaterThan(q.count(.familiar), 0, "but it is a BLEND — pool A is still present")
    }

    /// The floor must hold at every PREFIX, not just on the finished queue — otherwise a queue
    /// that back-loads its rediscoveries would pass while giving a listener who plays the first
    /// ten songs nothing but replays.
    func testRediscoveryFloorHoldsOnEveryPrefix() {
        let songs = catalog(artists: 15, perArtist: 20)
        let genres = genrePerArtist(songs)
        var plays: [ZoneEngine.Play] = []
        for a in 0..<15 {
            for rep in 0..<4 { plays.append(.init(songId: "a\(a)-t0",
                                                  playedAtMs: now - Double(rep + 1) * day)) }
        }
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 2 }, nowMs: now)

        var seen = 0
        for (i, pick) in q.picks.enumerated() {
            if pick.pool == .rediscovery { seen += 1 }
            XCTAssertGreaterThanOrEqual(Double(seen), 0.5 * Double(i + 1) - 0.0001,
                                        "prefix of length \(i + 1) fell under the floor")
        }
    }

    /// "45 familiar then 45 rediscoveries is not a zone." At the shipped 0.5 floor the queue must
    /// strictly alternate while both pools have material.
    func testTheInterleaveActuallyAlternates() {
        let songs = catalog(artists: 15, perArtist: 20)
        let genres = genrePerArtist(songs)
        var plays: [ZoneEngine.Play] = []
        for a in 0..<15 {
            for rep in 0..<4 { plays.append(.init(songId: "a\(a)-t\(rep)",
                                                  playedAtMs: now - Double(rep + 1) * day)) }
        }
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 2 }, nowMs: now)

        XCTAssertEqual(q.picks.first?.pool, .rediscovery,
                       "leads with rediscovery — that is what makes ⌈n/2⌉ hold at odd lengths")
        // Both pools are deep here, so no two consecutive picks may share a pool.
        for i in 1..<q.picks.count {
            XCTAssertNotEqual(q.picks[i].pool, q.picks[i - 1].pool,
                              "positions \(i - 1)/\(i) are both \(q.picks[i].pool) — not interleaved")
        }
        // Guard against the degenerate way to "alternate": having only one pool.
        XCTAssertGreaterThan(q.count(.familiar), 10)
        XCTAssertGreaterThan(q.count(.rediscovery), 10)
    }

    /// No unplayed neighbours at all ⇒ take MORE familiar rather than return a short queue.
    func testDegradesToFamiliarWhenThereAreNoRediscoveriesLeft() {
        // Every song in the catalog has been played inside the window, so pool B is empty.
        let songs = catalog(artists: 20, perArtist: 5)
        var plays: [ZoneEngine.Play] = []
        for (i, s) in songs.enumerated() {
            plays.append(.init(songId: s.id, playedAtMs: now - Double(i % 40 + 1) * day))
        }
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genrePerArtist(songs),
                                    plays: plays, playCount: { _ in 1 }, nowMs: now)

        XCTAssertEqual(q.count(.rediscovery), 0, "nothing is dormant, so there is nothing to rediscover")
        XCTAssertGreaterThanOrEqual(q.count, 30, "degrades to pool A rather than shipping short")
        XCTAssertTrue(q.degradesToFamiliar, "and says so, rather than pretending it met the floor")
    }

    // ========================================================================
    // MARK: - "Not played recently" really means not played recently
    // ========================================================================

    /// Pool B must never contain something he played inside the window — via EITHER source.
    func testRediscoveryPoolExcludesRecentlyPlayedSongs() {
        let songs = catalog(artists: 10, perArtist: 10)
        let genres = genrePerArtist(songs)
        // In the event log: played 3 days ago.
        let plays = (0..<10).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - 3 * day) }
        // NOT in the event log, but Apple's baseline says it was played 5 days ago. This is the
        // Music.app case: without the baseline it would look dormant and be offered as a
        // "rediscovery" of a song he is actually playing daily.
        var lastPlayed: [String: Double] = [:]
        for a in 0..<10 { lastPlayed["a\(a)-t1"] = now - 5 * day }
        for a in 0..<10 { lastPlayed["a\(a)-t2"] = now - 900 * day }   // genuinely buried

        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 2 }, lastPlayedMs: lastPlayed, nowMs: now)

        let buried = Set(q.picks.filter { $0.pool == .rediscovery }.map(\.songId))
        XCTAssertFalse(buried.isEmpty, "there are dormant songs, so the pool must not be empty")
        for a in 0..<10 {
            XCTAssertFalse(buried.contains("a\(a)-t0"), "an event-log play is not a rediscovery")
            XCTAssertFalse(buried.contains("a\(a)-t1"),
                           "an Apple-baseline play is not a rediscovery either")
        }
        // The invariant itself, over whatever the ranking actually chose: nothing in the
        // rediscovery pool was played inside the window by EITHER source.
        let recentIds = Set(plays.map(\.songId))
        for id in buried {
            XCTAssertFalse(recentIds.contains(id))
            if let lp = lastPlayed[id] {
                XCTAssertGreaterThan(now - lp, 60 * day, "\(id) was played inside the window")
            }
        }
    }

    /// The quiet threshold is a named constant, and the pools are exactly complementary across
    /// it: nothing is in both, and nothing falls in a gap between them.
    func testTheQuietWindowIsTheSameConstantThatBuildsTheProfile() {
        XCTAssertEqual(ZoneEngine.Tuning().rediscoveryQuietDays, 60)

        // Straddle the boundary: 59 days ago is INSIDE the window ⇒ familiar; 61 days ago is
        // outside it ⇒ rediscovery. Both songs share a genre so both clear the admission gate,
        // and `minSongs = 0` keeps the floor from filling the queue with anything else.
        let songs = [song("inside", artist: "A", year: 2000),
                     song("outside", artist: "B", year: 2000)]
        let genres = ["inside": "rock", "outside": "rock"]
        var t = ZoneEngine.Tuning()
        t.minSongs = 0
        let q = ZoneEngine.inDaZone(
            songs: songs, genreBySongId: genres,
            plays: [.init(songId: "inside", playedAtMs: now - 59 * day)],
            playCount: { _ in 1 }, lastPlayedMs: ["outside": now - 61 * day],
            nowMs: now, tuning: t)

        XCTAssertEqual(q.picks.first(where: { $0.songId == "inside" })?.pool, .familiar,
                       "59 days ago is still recent activity")
        XCTAssertEqual(q.picks.first(where: { $0.songId == "outside" })?.pool, .rediscovery,
                       "61 days ago is not")
        // Complementary: every pick is in exactly one pool, and ids never repeat.
        XCTAssertEqual(Set(q.songIds).count, q.count, "no song appears twice")
    }

    /// Dormancy is a GRADIENT, not the boolean gate — that is what discriminates across the 99.5%
    /// of his library that any short cutoff leaves eligible.
    func testAmongEqualMatchesTheLongerBuriedSongWins() {
        // Two dormant songs by the SAME artist with identical metadata and play counts: the only
        // difference is how long ago each was last played.
        let songs = [song("seed", artist: "A", year: 2000),
                     song("recentish", artist: "A", year: 2000),
                     song("ancient", artist: "A", year: 2000)]
        let genres = ["seed": "g", "recentish": "g", "ancient": "g"]
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                    plays: [.init(songId: "seed", playedAtMs: now - 2 * day)],
                                    playCount: { _ in 3 },
                                    lastPlayedMs: ["recentish": now - 100 * day,
                                                   "ancient": now - 3000 * day],
                                    nowMs: now)
        let buried = q.picks.filter { $0.pool == .rediscovery }.map(\.songId)
        XCTAssertEqual(buried.first, "ancient",
                       "equal on every other signal ⇒ the longer-buried one leads (got \(buried))")
    }

    /// A buried FAVOURITE beats a record he has never once played — rediscovery, not discovery.
    func testABuriedFavouriteOutranksANeverPlayedSong() {
        let songs = [song("seed", artist: "A", year: 2000),
                     song("loved", artist: "A", year: 2000),
                     song("never", artist: "A", year: 2000)]
        let genres = ["seed": "g", "loved": "g", "never": "g"]
        let counts = ["loved": 80, "never": 0, "seed": 5]
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                    plays: [.init(songId: "seed", playedAtMs: now - 2 * day)],
                                    playCount: { counts[$0] ?? 0 },
                                    lastPlayedMs: ["loved": now - 1200 * day], nowMs: now)
        let buried = q.picks.filter { $0.pool == .rediscovery }.map(\.songId)
        XCTAssertEqual(buried.first, "loved", "you used to love this beats you never played this")
    }

    func testJustPlayedSongsAreOnCooldownAndNeverReturned() {
        let songs = catalog(artists: 6, perArtist: 6)
        // Played five minutes ago: its artist is red hot, but THAT song is not offered back.
        let plays = [ZoneEngine.Play(songId: "a0-t0", playedAtMs: now - 300_000)]
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genrePerArtist(songs),
                                    plays: plays, playCount: { _ in 1 }, nowMs: now)
        XCTAssertFalse(q.songIds.contains("a0-t0"), "the song still ringing in your ears is out")
        XCTAssertFalse(q.isEmpty, "its siblings are not")
    }

    // ========================================================================
    // MARK: - Similarity: pool B is chosen for RESEMBLANCE, not at random
    // ========================================================================

    func testRediscoveryFavoursTheGenreAndArtistHeHasBeenBumping() {
        let songs = [song("seed", artist: "Hot", year: 1995),
                     song("same-artist", artist: "Hot", year: 1995),
                     song("same-genre", artist: "Other", year: 1995),
                     song("unrelated", artist: "Nope", year: 1995)]
        let genres = ["seed": "rock", "same-artist": "rock", "same-genre": "rock",
                      "unrelated": "polka"]
        var t = ZoneEngine.Tuning()
        t.minSongs = 0      // isolate the ranking from the floor
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                    plays: [.init(songId: "seed", playedAtMs: now - day)],
                                    playCount: { _ in 1 }, nowMs: now, tuning: t)
        let buried = q.picks.filter { $0.pool == .rediscovery }.map(\.songId)
        XCTAssertEqual(buried.first, "same-artist", "artist is the heaviest similarity term")
        XCTAssertTrue(buried.contains("same-genre"), "genre carries it to a different artist")
        XCTAssertFalse(buried.contains("unrelated"),
                       "no shared artist, genre or crate ⇒ not admitted at all")
    }

    /// Pinned from the previous ranking and still true: songs with NO genre must not become
    /// "similar" to each other. A catch-all bucket acting as a similarity signal would make the
    /// single largest slice of the catalog mutually similar — which is why `AppModel.zoneTracks`
    /// maps the "Other" category to nil and no key reaches `genreBySongId` at all.
    func testANilGenreNeverActsAsASharedBucket() {
        let songs = [song("seed", artist: "A", year: 2000), song("other", artist: "B", year: 2000)]
        var t = ZoneEngine.Tuning()
        t.minSongs = 0
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: [:],   // neither has a genre
                                    plays: [.init(songId: "seed", playedAtMs: now - day)],
                                    playCount: { _ in 0 }, nowMs: now, tuning: t)
        XCTAssertFalse(q.songIds.contains("other"), "absent genre is not a similarity signal")
    }

    /// Pinned from the previous ranking: a play beyond the window builds no zone at all.
    func testPlaysOlderThanTheWindowContributeNothing() {
        let songs = [song("a0-t0", artist: "A"), song("a0-t1", artist: "A")]
        var t = ZoneEngine.Tuning()
        t.minSongs = 0      // isolate the profile from the 30-song floor
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: [:],
                                    plays: [.init(songId: "a0-t0", playedAtMs: now - 400 * day)],
                                    playCount: { _ in 0 }, nowMs: now, tuning: t)
        XCTAssertEqual(q.count(.familiar), 0, "a play beyond the window is not recent activity")
    }

    /// The auxiliary signals are a MULTIPLIER on similarity, capped at `1 + auxGain`. A song with
    /// no relationship to the taste profile can never leapfrog a genuine match by being old and
    /// well-played — that is the guarantee that keeps pool B "similar to what you're bumping"
    /// rather than "old stuff you used to like".
    func testAuxiliarySignalsCannotOutrankAGenuinelySimilarSong() {
        let songs = [song("seed", artist: "Hot", year: 1995, bpm: 120, camelot: "8A"),
                     // Same artist AND genre, but never played and tempo/key-mismatched.
                     song("match", artist: "Hot", year: 1995, bpm: 60, camelot: "3B"),
                     // Shares only the GENRE (so it clears the admission gate on its own merits
                     // and the comparison is a real one), but is ancient, heavily played and a
                     // perfect tempo/key fit — every auxiliary signal maxed against it.
                     song("ringer", artist: "Nobody", year: 1930, bpm: 120, camelot: "8A")]
        let genres = ["seed": "rock", "match": "rock", "ringer": "rock"]
        var t = ZoneEngine.Tuning()
        t.minSongs = 0
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                    plays: [.init(songId: "seed", playedAtMs: now - day)],
                                    playCount: { $0 == "ringer" ? 5000 : 1 },
                                    lastPlayedMs: ["ringer": now - 6000 * day,
                                                   "match": now - 400 * day],
                                    nowMs: now, tuning: t)
        let buried = q.picks.filter { $0.pool == .rediscovery }.map(\.songId)
        XCTAssertEqual(buried.first, "match",
                       "similarity dominates; aux is a ≤1.6× nudge, not an override")
    }

    // ========================================================================
    // MARK: - Musical metadata (bpm + camelot)
    // ========================================================================

    /// The wheel itself lives in `SimilarityFamilies` — ONE implementation, which is why this file
    /// exercises it through the shape the zone actually builds rather than through a second copy.
    /// The exhaustive adjacency + de-saturation cases are in `SimilarityFamiliesTests`.
    func testMusicalProfileIsBuiltFromTheSeedAndFollowsTheWheel() {
        let songs = [musicSong("m1", bpm: 120, camelot: "8A"),
                     musicSong("m2", bpm: 122, camelot: "8A"),
                     musicSong("m3", bpm: nil, camelot: nil)]
        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let p = ZoneEngine.musicalProfile(seedWeight: ["m1": 1, "m2": 1, "m3": 1], songsById: byId)
        XCTAssertFalse(p.isEmpty)

        XCTAssertEqual(SimilarityFamilies.camelotAffinity("8A", p), 1.0, "exact match")
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("8B", p), 0.75, "relative major/minor")
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("9A", p), 0.6, "one step up")
        XCTAssertEqual(SimilarityFamilies.camelotAffinity("2A", p), 0.0, "not a neighbour")
        XCTAssertGreaterThan(SimilarityFamilies.bpmAffinity(121, p), 0.8, "on tempo")
        XCTAssertGreaterThan(SimilarityFamilies.bpmAffinity(60, p), 0.8, "half time is the same pulse")

        // A seed with no tempo/key at all speaks nothing, rather than speaking zero.
        let silent = ZoneEngine.musicalProfile(seedWeight: ["m3": 1], songsById: byId)
        XCTAssertTrue(silent.isEmpty)
    }

    /// Absent metadata is IMPUTED at the round's measured mean, never scored zero (which would
    /// punish the ~90% of the catalog the audio indexer has not reached) and never dropped from
    /// the denominator (which would reward it). `rawMusicalFit` is the "we don't know" signal that
    /// keeps those two cases distinguishable.
    func testMissingMusicalMetadataIsImputedNotScoredZero() {
        let songs = [musicSong("m1", bpm: 120, camelot: "8A")]
        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let p = ZoneEngine.musicalProfile(seedWeight: ["m1": 1], songsById: byId)

        XCTAssertNil(SimilarityFamilies.rawMusicalFit(bpm: nil, camelot: nil, profile: p),
                     "a song with neither field is unmeasurable, not unfit")
        XCTAssertNil(SimilarityFamilies.rawMusicalFit(bpm: 120, camelot: "8A",
                                                      profile: SimilarityFamilies.MusicalProfile()),
                     "a profile that knows nothing contributes nothing")

        let cal = SimilarityFamilies.MusicalCalibration(neutral: 0.3, observations: 100)
        let exact = SimilarityFamilies.musicalFit(bpm: 120, camelot: "8A", profile: p, calibration: cal)
        let far = SimilarityFamilies.musicalFit(bpm: 200, camelot: "2A", profile: p, calibration: cal)
        let unknown = SimilarityFamilies.musicalFit(bpm: nil, camelot: nil, profile: p, calibration: cal)
        XCTAssertGreaterThan(exact, far, "on-tempo and in-key beats neither")
        XCTAssertGreaterThan(exact, unknown, "and beats an unknown one")
        XCTAssertGreaterThan(unknown, far, "…but unknown is not treated as WRONG")
        XCTAssertEqual(unknown, 0.3, accuracy: 1e-9, "no evidence ⇒ exactly the round's mean")
    }

    private func musicSong(_ id: String, bpm: Double?, camelot: String?) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id, "artist": "A"]
        if let bpm { obj["bpm"] = bpm }
        if let camelot { obj["camelot"] = camelot }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    // ========================================================================
    // MARK: - Determinism + degenerate input
    // ========================================================================

    func testOutputIsDeterministic() {
        let songs = catalog(artists: 20, perArtist: 4)
        let genres = genrePerArtist(songs)
        let plays = (0..<20).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }
        let a = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 2 }, nowMs: now)
        let b = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 2 }, nowMs: now)
        XCTAssertEqual(a, b, "ties break on song id, so the tile is stable between renders")
    }

    func testEmptyCatalogIsHandled() {
        XCTAssertTrue(ZoneEngine.inDaZone(songs: [], plays: [], playCount: { _ in 0 },
                                          nowMs: now).isEmpty)
    }

    func testAPlayOfASongThatIsNotInTheCatalogIsIgnored() {
        // An ad-hoc rip / another source's id space must not build a phantom taste profile.
        let songs = catalog(artists: 10, perArtist: 5)
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genrePerArtist(songs),
                                    plays: [.init(songId: "not-in-catalog", playedAtMs: now - day)],
                                    playCount: { _ in 1 }, nowMs: now)
        XCTAssertEqual(q.count(.familiar), 0, "an unresolvable play is not a familiar song")
        XCTAssertGreaterThanOrEqual(q.count, 30, "and the queue still fills")
    }

    func testFutureDatedPlaysAreClampedNotDropped() {
        // Clock skew / a log restored from a device running ahead. The play still counts.
        let songs = catalog(artists: 10, perArtist: 5)
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genrePerArtist(songs),
                                    plays: [.init(songId: "a0-t0", playedAtMs: now + 2 * day)],
                                    playCount: { _ in 1 }, nowMs: now)
        XCTAssertFalse(q.songIds.contains("a0-t0"), "a future stamp is inside the cooldown")
        XCTAssertGreaterThan(q.count, 0)
    }

    // ========================================================================
    // MARK: - Cost
    // ========================================================================

    /// A REGRESSION GUARD, not a benchmark. `inDaZone` runs on the For You path, and this project
    /// has already paid once for a full-catalog derivation sitting near a render (Browse search).
    /// The bound is deliberately loose — it is here to catch someone accidentally making this
    /// quadratic or moving the expensive scorer in front of the admission gate, not to police
    /// milliseconds on a shared CI machine.
    ///
    /// Shape matches the owner's real library: ~96k songs, ~9k artists, 12 genre categories,
    /// 2,000 recent play events (`PlayHistoryStore.recentPlaysForZone`'s cap).
    func testRankingTheFullCatalogStaysCheap() throws {
        var songs: [IndexSong] = []
        songs.reserveCapacity(96_000)
        for a in 0..<9_000 {
            for t in 0..<11 where songs.count < 96_000 {
                songs.append(song("a\(a)-t\(t)", artist: "Artist \(a)",
                                  year: 1960 + (a % 60), bpm: Double(70 + a % 90),
                                  camelot: "\(a % 12 + 1)\(a % 2 == 0 ? "A" : "B")"))
            }
        }
        let genres = Dictionary(uniqueKeysWithValues:
            songs.map { ($0.id, "g\(abs($0.artist.hashValue) % 12)") })
        var plays: [ZoneEngine.Play] = []
        for i in 0..<2_000 {
            plays.append(.init(songId: "a\(i % 300)-t\(i % 11)",
                               playedAtMs: now - Double(i % 45) * day))
        }
        var lastPlayed: [String: Double] = [:]
        for (i, s) in songs.enumerated() where i % 2 == 0 {
            lastPlayed[s.id] = now - Double(200 + i % 3000) * day
        }

        let t0 = Date()
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 3 }, lastPlayedMs: lastPlayed, nowMs: now)
        let elapsed = Date().timeIntervalSince(t0)

        XCTAssertGreaterThanOrEqual(q.count, 30)
        XCTAssertLessThanOrEqual(q.count, 90)
        XCTAssertGreaterThanOrEqual(q.rediscoveryShare, 0.5)
        XCTAssertLessThan(elapsed, 5.0,
                          "full-catalog ranking took \(String(format: "%.3f", elapsed))s")
        print("PDJ-PERF inDaZone over \(songs.count) songs: "
              + "\(String(format: "%.3f", elapsed))s → \(q.count) songs, "
              + "\(q.count(.rediscovery)) buried")
    }

    /// The shortlist has to actually BIND, or the "constant, not proportional to library size"
    /// claim is untested. Tightening the cap must not change the queue's shape — same bounds,
    /// same floor — because the cap only ever discards candidates that were never going to win.
    func testShortlistCapBoundsTheWorkWithoutChangingTheQueuesShape() {
        let songs = catalog(artists: 400, perArtist: 20)          // 8,000 songs, one genre bucket
        let genres = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, "one-big-genre") })
        let plays = (0..<40).map { ZoneEngine.Play(songId: "a\($0)-t0", playedAtMs: now - day) }

        var tight = ZoneEngine.Tuning()
        tight.shortlistCap = 500                                   // deliberately binding (of 8k)
        let capped = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                         playCount: { _ in 2 }, nowMs: now, tuning: tight)
        let uncapped = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                           playCount: { _ in 2 }, nowMs: now)

        for q in [capped, uncapped] {
            XCTAssertGreaterThanOrEqual(q.count, 30)
            XCTAssertLessThanOrEqual(q.count, 90)
            XCTAssertGreaterThanOrEqual(q.rediscoveryShare, 0.5)
            var perArtist: [String: Int] = [:]
            for id in q.songIds { perArtist[artistOf(id), default: 0] += 1 }
            XCTAssertTrue(perArtist.values.allSatisfy { $0 <= 3 })
        }
    }

    // ========================================================================
    // MARK: - The PuzzleSimilarity generalization it depends on
    // ========================================================================

    /// The new `memberWeights:` parameter must default to today's exact behaviour — that is what
    /// makes it safe to add to a scorer Gem Collector already ships.
    func testWeightedProfileDefaultsToUniformAndIsIdenticalToTheUnweightedOne() {
        let songs = [song("s1", artist: "A", year: 1990), song("s2", artist: "B", year: 2010)]
        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let plain = PuzzleSimilarity.profile(targetMemberIds: [["s1", "s2"]], songsById: byId,
                                             genreBySongId: [:], otherCollections: [], plays: [])
        let explicitOnes = PuzzleSimilarity.profile(targetMemberIds: [["s1", "s2"]], songsById: byId,
                                                    genreBySongId: [:], otherCollections: [],
                                                    plays: [], memberWeights: ["s1": 1, "s2": 1])
        XCTAssertEqual(plain.artistShare, explicitOnes.artistShare)
        XCTAssertEqual(plain.yearMean, explicitOnes.yearMean)
        XCTAssertEqual(plain.availableWeight, explicitOnes.availableWeight)
    }

    /// And a weight actually has to MOVE the profile, or the zone's recency weighting is a no-op.
    func testMemberWeightsShiftTheProfileTowardTheHeavierMember() {
        let songs = [song("s1", artist: "A", year: 1990), song("s2", artist: "B", year: 2010)]
        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let leaning = PuzzleSimilarity.profile(targetMemberIds: [["s1", "s2"]], songsById: byId,
                                               genreBySongId: [:], otherCollections: [], plays: [],
                                               memberWeights: ["s1": 9, "s2": 1])
        XCTAssertEqual(leaning.yearMean!, 1992, accuracy: 0.001,
                       "weighted mean, not the 2000 midpoint")
        XCTAssertEqual(leaning.artistShare["a"]!, 0.9, accuracy: 0.001)
        XCTAssertEqual(leaning.artistShare["b"]!, 0.1, accuracy: 0.001)
    }

    // ========================================================================
    // MARK: - Collection suggestions (unchanged API — a different job entirely)
    // ========================================================================

    func testSuggestionsNeverIncludeExistingMembers() {
        let tracks = zoneTracks(catalog(artists: 3, perArtist: 6))
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
        let tracks = zoneTracks(catalog(artists: 10, perArtist: 20))
        let out = ZoneEngine.suggestions(memberSongIds: ["a0-t0", "a1-t0"], tracks: tracks,
                                         playCount: { _ in 1 }, limit: 25)
        var perArtist: [String: Int] = [:]
        for id in out { perArtist[artistOf(id), default: 0] += 1 }
        XCTAssertTrue(perArtist.values.allSatisfy { $0 <= 3 }, "cap holds for collections too")
        XCTAssertLessThanOrEqual(out.count, 25)
    }

    // ========================================================================
    // MARK: - The owner's 50% newcomer floor (incumbent-artist cap)
    // ========================================================================

    /// Same-genre tracks under distinct artists — the floor tests need admission (genre) held
    /// constant while artist membership varies.
    private func fTrack(_ id: String, _ artist: String, genre: String = "rock") -> ZoneEngine.Track {
        ZoneEngine.Track(songId: id, artistKey: artist.lowercased(), artistName: artist, genre: genre)
    }

    func testIncumbentArtistRowsAreCappedAtHalfTheList() {
        // Members by Alpha + Beta; six incumbent candidates OUTSCORE four newcomers (the artist
        // term), so today's walk would fill a 6-row list entirely with incumbents. The floor
        // seats ⌊6·0.5⌋ = 3 and pulls the newcomers up in their own order.
        var tracks = [fTrack("m-a", "Alpha"), fTrack("m-b", "Beta")]
        for i in 0..<3 { tracks.append(fTrack("ia-\(i)", "Alpha")) }
        for i in 0..<3 { tracks.append(fTrack("ib-\(i)", "Beta")) }
        for a in ["Gamma", "Delta", "Epsilon", "Zeta"] { tracks.append(fTrack("n-\(a)", a)) }
        let out = ZoneEngine.suggestions(memberSongIds: ["m-a", "m-b"], tracks: tracks,
                                         playCount: { _ in 0 }, limit: 6)
        XCTAssertEqual(out.count, 6, "the floor may reorder a list, never shorten it")
        XCTAssertEqual(out.filter { $0.hasPrefix("i") }.count, 3,
                       "at most ⌊n·0.5⌋ incumbent-artist rows (got \(out))")
        XCTAssertEqual(out.filter { $0.hasPrefix("n-") }.count, 3,
                       "newcomer artists take the other half — collection-expanding")
    }

    func testOddCountsRoundInTheNewcomersFavor() {
        var tracks = [fTrack("m-a", "Alpha"), fTrack("m-b", "Beta")]
        for i in 0..<3 { tracks.append(fTrack("ia-\(i)", "Alpha")) }
        for i in 0..<3 { tracks.append(fTrack("ib-\(i)", "Beta")) }
        for a in ["Gamma", "Delta", "Epsilon", "Zeta"] { tracks.append(fTrack("n-\(a)", a)) }
        let out = ZoneEngine.suggestions(memberSongIds: ["m-a", "m-b"], tracks: tracks,
                                         playCount: { _ in 0 }, limit: 5)
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.filter { $0.hasPrefix("i") }.count, 2,
                       "a 5-row list seats ⌊2.5⌋ = 2 incumbents — the odd slot goes to a newcomer")
    }

    func testTheFloorFailsOpenWhenTheCatalogHasOnlyIncumbents() {
        // A tiny catalog where every candidate is by the member's artist: the newcomer pool is
        // genuinely dry, so the floor must fill from incumbents rather than starve the tile.
        var tracks = [fTrack("m-a", "Alpha")]
        for i in 0..<3 { tracks.append(fTrack("ia-\(i)", "Alpha")) }
        let out = ZoneEngine.suggestions(memberSongIds: ["m-a"], tracks: tracks,
                                         playCount: { _ in 0 })
        XCTAssertEqual(out.count, 3, "the floor is a target, never a hole (got \(out))")
    }

    func testACollectionAlreadyUnderTheCapIsUndisturbed() {
        // One incumbent row in six is already under 50%: the composed list must be byte-identical
        // to the floor switched off (share 1) — the cap never disturbs a compliant tile.
        var tracks = [fTrack("m-a", "Alpha"), fTrack("ia-0", "Alpha")]
        for a in ["Gamma", "Delta", "Epsilon", "Zeta", "Eta"] { tracks.append(fTrack("n-\(a)", a)) }
        var off = ZoneEngine.Tuning()
        off.suggestionIncumbentMaxShare = 1.0
        let composed = ZoneEngine.suggestions(memberSongIds: ["m-a"], tracks: tracks,
                                              playCount: { _ in 0 })
        let uncapped = ZoneEngine.suggestions(memberSongIds: ["m-a"], tracks: tracks,
                                              playCount: { _ in 0 }, tuning: off)
        XCTAssertEqual(composed, uncapped)
        XCTAssertEqual(composed.count, 6)
    }

    func testACollabCreditCountsAsIncumbentThroughTheSplit() {
        // The crate holds plain Drake; "Drake & Future" candidates share ONE credit ⇒ INCUMBENT,
        // though their raw artist key never equals the member's (the known raw-string trap). All
        // candidates tie on score (genre only), so today's order is id-ascending — the floor
        // defers df-3 for the newcomer and refills it at the tail, which can only happen if the
        // collab was recognised as incumbent.
        let tracks = [fTrack("m-d", "Drake"),
                      fTrack("df-1", "Drake & Future"), fTrack("df-2", "Drake & Future"),
                      fTrack("df-3", "Drake & Future"), fTrack("nz-1", "Zeta")]
        let out = ZoneEngine.suggestions(memberSongIds: ["m-d"], tracks: tracks,
                                         playCount: { _ in 0 }, limit: 4)
        XCTAssertEqual(out, ["df-1", "df-2", "nz-1", "df-3"])
    }

    func testASoloCandidateIsIncumbentForACrateFiledUnderTheCollabCredit() {
        // The other direction: the crate's one member is filed under the five-name Dinner Party
        // credit, and plain "Terrace Martin" rows count as incumbent against it.
        let dp = "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington"
        let tracks = [fTrack("m-dp", dp),
                      fTrack("tm-1", "Terrace Martin"), fTrack("tm-2", "Terrace Martin"),
                      fTrack("tm-3", "Terrace Martin"), fTrack("z-1", "Zeta")]
        let out = ZoneEngine.suggestions(memberSongIds: ["m-dp"], tracks: tracks,
                                         playCount: { _ in 0 }, limit: 4)
        XCTAssertEqual(out, ["tm-1", "tm-2", "z-1", "tm-3"])
    }

    func testWhyStringsSpeakTheFloorsLanguage() {
        // The caption uses the SAME credit-identity incumbent test as the composition (play
        // counts all zero, so the novelty captions stay out of the way).
        let dp = "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington"
        let tracks = [fTrack("m-dp", dp), fTrack("tm-1", "Terrace Martin")]
        let rows = ZoneEngine.suggestionsExplained(memberSongIds: ["m-dp"], tracks: tracks,
                                                   playCount: { _ in 0 })
        XCTAssertEqual(rows.first?.why, "An artist already in here",
                       "a shared credit is incumbent in the caption exactly as in the composition")
    }

    func testANewcomerRowSaysSoWhenNothingStrongerExists() {
        // Admitted through the 👍 profile (an accepted jazz row by the same new artist), so
        // neither the member-genre caption nor the era caption can claim the row — the newcomer
        // fallback speaks, above only the generic "Fits this collection".
        let tracks = [fTrack("m-a", "Alpha", genre: "rock"),
                      fTrack("liked", "New Guy", genre: "jazz"),
                      fTrack("cand", "New Guy", genre: "jazz")]
        let rows = ZoneEngine.suggestionsExplained(
            memberSongIds: ["m-a"], tracks: tracks, playCount: { _ in 0 },
            feedback: .init(accepted: ["liked": 1.0]))
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.songId, $0.why) })
        XCTAssertEqual(byId["cand"], "New artist for this crate")
    }

    func testAnEmptyCollectionGetsNoSuggestions() {
        let tracks = zoneTracks(catalog(artists: 5, perArtist: 5))
        XCTAssertTrue(ZoneEngine.suggestions(memberSongIds: [], tracks: tracks,
                                             playCount: { _ in 1 }).isEmpty,
                      "no members ⇒ no profile ⇒ no arbitrary suggestions")
    }

    func testACollectionOfUnknownIdsGetsNoSuggestions() {
        // Members that resolve to nothing in the catalog (another source's id space) build no
        // profile, so the engine must decline rather than emit its most-played songs.
        let tracks = zoneTracks(catalog(artists: 5, perArtist: 5))
        XCTAssertTrue(ZoneEngine.suggestions(memberSongIds: ["nope-1", "nope-2"], tracks: tracks,
                                             playCount: { _ in 1 }).isEmpty)
    }

    // ========================================================================
    // MARK: - The collection's ERA (owner: "factor in year range … along with genre")
    // ========================================================================

    /// A track with an explicit genre + year — the era tests need both axes under control.
    private func track(_ id: String, artist: String, genre: String?, year: Int?) -> ZoneEngine.Track {
        ZoneEngine.Track(songId: id, artistKey: artist.lowercased(), artistName: artist,
                         genre: genre, year: year)
    }

    /// A same-genre crate whose members are the 808 pocket's real founding-core years (1987–1994
    /// → window 1985–1996), plus three same-genre candidates the genre term cannot separate: one
    /// inside the era, one 26 years outside it, one undated. Distinct artists throughout, so the
    /// artist family cannot separate them either — the era term has to, or fail open trying.
    private func eraCrate() -> (members: [String], tracks: [ZoneEngine.Track]) {
        let members = [track("m-1987", artist: "Keith Sweat", genre: "soul", year: 1987),
                       track("m-1988", artist: "Luther Vandross", genre: "soul", year: 1988),
                       track("m-1990", artist: "Tony Toni Tone", genre: "soul", year: 1990),
                       track("m-1992", artist: "SWV", genre: "soul", year: 1992),
                       track("m-1994", artist: "Outkast", genre: "soul", year: 1994)]
        let candidates = [track("c-inside", artist: "Jodeci", genre: "soul", year: 1992),
                          track("c-outside", artist: "Talii", genre: "soul", year: 2022),
                          track("c-undated", artist: "Zhane", genre: "soul", year: nil)]
        return (members.map { $0.songId }, members + candidates)
    }

    func testSuggestionsPreferTheCollectionsEraWithinTheSameGenre() {
        let (members, tracks) = eraCrate()
        let out = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                         playCount: { _ in 0 })
        XCTAssertTrue(out.contains("c-inside") && out.contains("c-outside"))
        XCTAssertLessThan(out.firstIndex(of: "c-inside")!, out.firstIndex(of: "c-outside")!,
                          "1992 belongs to the 1985–1996 crate; 2022 does not — era separates "
                          + "what genre cannot")
    }

    func testAnUndatedCandidateIsImputedNotBuriedBySuggestions() {
        let (members, tracks) = eraCrate()
        let out = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                         playCount: { _ in 0 })
        // FAIL OPEN: the undated candidate scores the era term at the round neutral (the
        // measured fallback here — the pool is far below `minObservationsForRoundNeutral`), so it
        // sits between a true era match and a 26-years-outside miss. Zeroing it would have ranked
        // it WITH the miss, for a missing tag rather than a bad fit.
        XCTAssertLessThan(out.firstIndex(of: "c-undated")!, out.firstIndex(of: "c-outside")!,
                          "undated ≠ buried")
        XCTAssertLessThan(out.firstIndex(of: "c-inside")!, out.firstIndex(of: "c-undated")!,
                          "the neutral is a mean, not a reward — real fit still wins")
    }

    func testAnUndatedCollectionDropsTheEraTermAndRenormalizes() {
        // No member carries a year ⇒ no window ⇒ `termWeights(hasYear: false)` redistributes the
        // era weight over the live axes. A candidate's own year must then be unable to help or
        // hurt: with every other axis identical, the two candidates tie and the deterministic id
        // tiebreak decides — the year 1955 vs 2022 never enters the score.
        let members = [track("m-a", artist: "A", genre: "rock", year: nil),
                       track("m-b", artist: "B", genre: "rock", year: nil)]
        let tracks = members + [track("c-1955", artist: "C", genre: "rock", year: 1955),
                                track("c-2022", artist: "D", genre: "rock", year: 2022)]
        let out = ZoneEngine.suggestions(memberSongIds: members.map { $0.songId }, tracks: tracks,
                                         playCount: { _ in 0 })
        XCTAssertEqual(out, ["c-1955", "c-2022"],
                       "score tie broken by id order — an undated crate has no era to score on")
    }

    // ========================================================================
    // MARK: - The collection's SOUND (audio-similarity v2)
    // ========================================================================
    //
    // Same fixture doctrine as the era section: one genre, one year, distinct artists — so
    // neither genre, era nor artist can separate the candidates, and the timbre term has to,
    // or fail open trying. Sound A is "punchy, busy, dark"; the mismatch flips every axis.

    private func tvec(_ base: Double, _ overrides: [String: Double] = [:],
                      shift: Double = 0) -> SimilarityFamilies.TimbreVector {
        Dictionary(uniqueKeysWithValues: SimilarityFamilies.timbreAxes.map { axis in
            (axis, min(1, max(0, (overrides[axis] ?? base) + shift)))
        })
    }
    private func soundA(_ shift: Double = 0) -> SimilarityFamilies.TimbreVector {
        tvec(0.2, ["punch": 0.9, "busy": 0.8], shift: shift)
    }
    private func soundAFlipped() -> SimilarityFamilies.TimbreVector {
        tvec(0.8, ["punch": 0.1, "busy": 0.2])
    }

    /// A same-genre, same-year crate whose five members carry tight sound-A vectors, plus three
    /// candidates: one that sounds like the crate, one that sounds like its opposite, one never
    /// analysed.
    ///
    /// THE IDS ARE ADVERSARIAL ON PURPOSE: ties break on the id, and the sound-alike candidate
    /// carries the LAST id of the three ("c-z…"). If the timbre term silently dies, the id
    /// tiebreak puts it LAST and every ordering assertion below fails loudly — a fixture whose
    /// ids happen to sort the "right" way would let a sabotaged term pass.
    private func timbreCrate() -> (members: [String], tracks: [ZoneEngine.Track],
                                   timbre: [String: SimilarityFamilies.TimbreVector]) {
        let names = ["Keith Sweat", "Luther Vandross", "Tony Toni Tone", "SWV", "Outkast"]
        let members = names.enumerated().map { i, artist in
            track("m-\(i)", artist: artist, genre: "soul", year: 1990)
        }
        let candidates = [track("c-z-alike", artist: "Guy", genre: "soul", year: 1990),
                          track("c-u-unlike", artist: "Sade", genre: "soul", year: 1990),
                          track("c-m-novector", artist: "Zhane", genre: "soul", year: 1990)]
        var timbre: [String: SimilarityFamilies.TimbreVector] = [:]
        for (i, m) in members.enumerated() { timbre[m.songId] = soundA(Double(i - 2) * 0.005) }
        timbre["c-z-alike"] = soundA(0.004)
        timbre["c-u-unlike"] = soundAFlipped()
        return (members.map { $0.songId }, members + candidates, timbre)
    }

    func testSuggestionsPreferTheCollectionsSoundWithinTheSameGenre() {
        let (members, tracks, timbre) = timbreCrate()
        let out = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                         playCount: { _ in 0 }, timbre: timbre)
        XCTAssertTrue(out.contains("c-z-alike") && out.contains("c-u-unlike"))
        XCTAssertLessThan(out.firstIndex(of: "c-z-alike")!, out.firstIndex(of: "c-u-unlike")!,
                          "same genre, same era, artists all foreign — the SOUND is the only "
                          + "separator (and the id tiebreak points the other way)")
    }

    func testAnUnanalysedCandidateIsImputedNotBuriedBySuggestions() {
        let (members, tracks, timbre) = timbreCrate()
        let out = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                         playCount: { _ in 0 }, timbre: timbre)
        // FAIL OPEN — the fairness rule this feature was deferred over: a candidate with no
        // vector rides the round-neutral multiplier, between a true sound match and a true
        // mismatch. Zeroing it would rank 86% of the real catalog below every analysed row.
        XCTAssertLessThan(out.firstIndex(of: "c-m-novector")!, out.firstIndex(of: "c-u-unlike")!,
                          "no vector must not sink below a genuinely bad fit")
        XCTAssertLessThan(out.firstIndex(of: "c-z-alike")!, out.firstIndex(of: "c-m-novector")!,
                          "the neutral is a mean, not a reward — a real fit still wins "
                          + "(and the id tiebreak points the other way)")
    }

    func testAnUnanalysedCollectionDropsTheTimbreTermEntirely() {
        // Members carry NO vectors ⇒ no profile ⇒ the multiplier never runs — even though two
        // CANDIDATES are analysed. The ranking must be byte-identical to the pre-v2 call:
        // candidate vectors alone must not smuggle the term in (that asymmetry would be the
        // incomparable-ranking bug this term was deferred to avoid).
        let (members, tracks, timbre) = timbreCrate()
        let candidatesOnly = timbre.filter { $0.key.hasPrefix("c-") }
        let with = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                          playCount: { _ in 0 }, timbre: candidatesOnly)
        let without = ZoneEngine.suggestions(memberSongIds: members, tracks: tracks,
                                             playCount: { _ in 0 })
        XCTAssertEqual(with, without, "an unearnable term leaves the round entirely")
    }

    func testARejectedSoundSeparatesTwinsTheCrateOtherwiseCannot() {
        // Two candidates the SAME distance from the crate's centroid, opposite directions; the
        // owner 👎'd an analysed song that sounds exactly like one of them. Genre-level rejection
        // penalties hit both twins identically (same genre), so any separation is the timbre
        // negative profile — the "👎 can carry I don't like this kind of sound" half of F10.
        // The twin NEAR the rejected sound carries the FIRST id, so the id tiebreak alone would
        // keep it on top: only the negative profile can demote it.
        let (members, tracks, timbre) = timbreCrate()
        var allTracks = tracks
        allTracks.append(track("c-a-nearRej", artist: "Jodeci", genre: "soul", year: 1990))
        allTracks.append(track("c-b-farRej", artist: "Zapp", genre: "soul", year: 1990))
        allTracks.append(track("rejected", artist: "H-Town", genre: "soul", year: 1990))
        var allTimbre = timbre
        allTimbre["c-a-nearRej"] = soundA(0.06)
        allTimbre["c-b-farRej"] = soundA(-0.06)
        allTimbre["rejected"] = soundA(0.06)

        let clean = ZoneEngine.suggestions(memberSongIds: members, tracks: allTracks,
                                           playCount: { _ in 0 }, timbre: allTimbre)
        XCTAssertLessThan(clean.firstIndex(of: "c-a-nearRej")!, clean.firstIndex(of: "c-b-farRej")!,
                          "without the verdict the twins tie exactly and the id tiebreak decides")

        let feedback = ZoneEngine.Feedback(rejected: ["rejected": 1.0])
        let out = ZoneEngine.suggestions(memberSongIds: members, tracks: allTracks,
                                         playCount: { _ in 0 }, feedback: feedback,
                                         timbre: allTimbre)
        XCTAssertLessThan(out.firstIndex(of: "c-b-farRej")!, out.firstIndex(of: "c-a-nearRej")!,
                          "the twin that sounds like the 👎 drops below the one that does not — "
                          + "the verdict flips an order the tiebreak had the other way")
    }

    func testInDaZoneLiftsTheSoundAlikeRediscovery() {
        // Recent plays are five sound-A songs; two dormant same-genre candidates by foreign
        // artists differ only in sound. The sound-alike carries the LATER id ("cand-z…"), so the
        // id tiebreak alone would rank it BELOW its twin: only a live timbre term can put it
        // first — and stripping the corpus must restore the tiebreak order exactly (pre-v2).
        var songs: [IndexSong] = []
        var genres: [String: String] = [:]
        var timbre: [String: SimilarityFamilies.TimbreVector] = [:]
        for i in 0..<5 {
            let s = song("seed-\(i)", artist: "Seed \(i)", year: 1990)
            songs.append(s)
            genres[s.id] = "soul"
            timbre[s.id] = soundA(Double(i - 2) * 0.005)
        }
        let alike = song("cand-z-alike", artist: "Guy", year: 1990)
        let unlike = song("cand-a-unlike", artist: "Sade", year: 1990)
        songs.append(alike); songs.append(unlike)
        genres[alike.id] = "soul"; genres[unlike.id] = "soul"
        timbre[alike.id] = soundA(0.004)
        timbre[unlike.id] = soundAFlipped()
        let plays = (0..<5).map { ZoneEngine.Play(songId: "seed-\($0)", playedAtMs: now - 3 * day) }

        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                    playCount: { _ in 0 }, timbre: timbre, nowMs: now)
        let ids = q.songIds
        XCTAssertTrue(ids.contains("cand-z-alike") && ids.contains("cand-a-unlike"),
                      "both admitted — the term reorders, it never filters")
        XCTAssertLessThan(ids.firstIndex(of: "cand-z-alike")!, ids.firstIndex(of: "cand-a-unlike")!,
                          "the rediscovery that SOUNDS like the zone comes first, against the tiebreak")

        let flat = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres, plays: plays,
                                       playCount: { _ in 0 }, nowMs: now)
        XCTAssertLessThan(flat.songIds.firstIndex(of: "cand-a-unlike")!,
                          flat.songIds.firstIndex(of: "cand-z-alike")!,
                          "with no corpus the queue is pre-v2: the twins tie and the id tiebreak decides")
    }

    func testSuggestionsExplainedNamesTheCrateSound() {
        let (members, tracks, timbre) = timbreCrate()
        let out = ZoneEngine.suggestionsExplained(memberSongIds: members, tracks: tracks,
                                                  playCount: { _ in 0 }, timbre: timbre)
        let alike = out.first { $0.songId == "c-z-alike" }
        XCTAssertEqual(alike?.why, "Sounds like this crate: punchy, busy, clean",
                       "the reason names the crate's sound in the adjective table's words")
        let unlike = out.first { $0.songId == "c-u-unlike" }
        XCTAssertNotEqual(unlike?.why.hasPrefix("Sounds like"), true,
                          "a mismatched sound must not carry the reason")
        let noVector = out.first { $0.songId == "c-m-novector" }
        XCTAssertNotEqual(noVector?.why.hasPrefix("Sounds like"), true,
                          "an imputed fit never claims a sound nothing measured")
    }
}
