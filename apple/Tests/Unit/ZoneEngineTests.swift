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

    func testCamelotAffinityFollowsTheWheel() {
        XCTAssertEqual(ZoneEngine.camelotAffinity("8A", to: ["8A"]), 1.0, "exact match")
        XCTAssertEqual(ZoneEngine.camelotAffinity("8B", to: ["8A"]), 0.75, "relative major/minor")
        XCTAssertEqual(ZoneEngine.camelotAffinity("9A", to: ["8A"]), 0.6, "one step up")
        XCTAssertEqual(ZoneEngine.camelotAffinity("7A", to: ["8A"]), 0.6, "one step down")
        XCTAssertEqual(ZoneEngine.camelotAffinity("2A", to: ["8A"]), 0.0, "not a neighbour")
        // The wheel wraps: 12 → 1 is one step, not eleven.
        XCTAssertEqual(ZoneEngine.camelotAffinity("1A", to: ["12A"]), 0.6, "wraps at 12")
        XCTAssertEqual(ZoneEngine.camelotAffinity("12A", to: ["1A"]), 0.6, "wraps the other way")
        // Junk in, zero out — never a crash and never a false neighbour.
        XCTAssertEqual(ZoneEngine.camelotAffinity(nil, to: ["8A"]), 0)
        XCTAssertEqual(ZoneEngine.camelotAffinity("banana", to: ["8A"]), 0)
        XCTAssertEqual(ZoneEngine.camelotAffinity("13A", to: ["8A"]), 0, "off the wheel")
        XCTAssertEqual(ZoneEngine.camelotAffinity("8A", to: []), 0, "empty profile says nothing")
    }

    /// Absent metadata must DROP OUT rather than score zero — scoring it zero would
    /// systematically punish the unanalysed part of the catalog for missing a field.
    func testMissingMusicalMetadataDropsTheTermInsteadOfScoringItZero() {
        let p = ZoneEngine.MusicalProfile(bpmMean: 120, bpmSigma: 10, camelots: ["8A"])
        XCTAssertNil(ZoneEngine.musicalFit(bpm: nil, camelot: nil, profile: p),
                     "a song with neither field is unmeasurable, not unfit")
        // A profile that knows nothing likewise contributes nothing.
        XCTAssertNil(ZoneEngine.musicalFit(bpm: 120, camelot: "8A",
                                           profile: ZoneEngine.MusicalProfile()))
        let exact = ZoneEngine.musicalFit(bpm: 120, camelot: "8A", profile: p)
        let far = ZoneEngine.musicalFit(bpm: 200, camelot: "2A", profile: p)
        XCTAssertNotNil(exact); XCTAssertNotNil(far)
        XCTAssertGreaterThan(exact!, far!, "on-tempo and in-key beats neither")
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
}
