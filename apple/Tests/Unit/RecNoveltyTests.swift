import XCTest
@testable import PocketDJ

/// THE NOVELTY REBALANCE — the owner's report, as tests.
///
/// > "It is biasing too much on play count so each tile is recommending multiple Drake songs.
/// >  Value novelty over similarity both to add diversity and because that will make the signal
/// >  from thumbs up and thumbs down have or build a second reliable signal source apart from
/// >  pure play count."
///
/// The second half of that sentence is the part these tests are really about. While the ranking is
/// dominated by play count, a 👍 is nearly REDUNDANT — the engine already read what he plays, so
/// the tile proposes what he plays and the thumbs-up confirms a number it had in hand. Measured on
/// his real catalog before this change, **99.1% of the rows a collection tile picked had play
/// history, against a 52.2% base rate**. Feedback only carries information when the engine
/// proposes something it is genuinely unsure about, and that is what a novelty term buys.
///
/// The four claims worth pinning, and the reason each has an adversarial rather than a happy-path
/// case: the cap cannot be walked around by a credit string; novelty CAN beat familiarity;
/// novelty CANNOT beat similarity; and the 47.8% of the library with no play data is neither
/// buried nor promoted wholesale.
final class RecNoveltyTests: XCTestCase {

    private let day: Double = 86_400_000
    private let now: Double = 1_800_000_000_000

    private func song(_ id: String, artist: String, year: Int? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id.uppercased(), "artist": artist]
        if let year { obj["year"] = year }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func track(_ id: String, _ credit: String, genre: String? = "g", year: Int? = 2000)
        -> ZoneEngine.Track {
        ZoneEngine.Track(songId: id, artistKey: PuzzleSimilarity.artistKey(credit),
                         artistName: credit, genre: genre, year: year)
    }

    // ========================================================================
    // MARK: - The cap key
    // ========================================================================

    /// A cap that a credit string can walk around is not a cap; it is a suggestion. Measured over
    /// 40 real collection tiles before this fix: Drake held 25 rows under his own name plus 7 more
    /// through collaborations — 32 rows under a cap of 3 per tile — while Future picked up 8 rows
    /// of which 7 were invisible to his own budget.
    func testPrimaryArtistKeyCollapsesCollaborationCredits() {
        let drake = RecNovelty.primaryArtistKey("Drake")
        for credit in ["Drake & Future", "Drake feat. Future", "Drake ft Lil Wayne",
                       "Drake, Future", "Drake x Future", "Drake / Future",
                       "Drake with Sampha", "DRAKE", "Drake vs. Nobody"] {
            XCTAssertEqual(RecNovelty.primaryArtistKey(credit), drake,
                           "\"\(credit)\" must spend Drake's budget")
        }
        XCTAssertEqual(RecNovelty.primaryArtistKey("DJ Khaled Featuring Drake"), "dj khaled",
                       "the budget belongs to the BILLED artist, not the guest")
    }

    /// The false positives, which matter because the failure directions are not symmetric: two
    /// artists colliding into one bucket makes the cap STRICTER (a tile loses a row it could have
    /// had), while one artist escaping is the defect being fixed. These are the collisions common
    /// enough to be worth a hand-written guard.
    func testPrimaryArtistKeyDoesNotSplitNamesThatMerelyLookLikeLists() {
        XCTAssertEqual(RecNovelty.primaryArtistKey("Tyler, The Creator"), "tyler, the creator",
                       "a list item never begins with \"the\" — this is one artist")
        XCTAssertEqual(RecNovelty.primaryArtistKey("Xavier Rudd"), "xavier rudd",
                       "\"x\" is a separator only with its own word boundary")
        XCTAssertEqual(RecNovelty.primaryArtistKey("Fetty Wap"), "fetty wap",
                       "\"with\" must not match the middle of a word")
        XCTAssertEqual(RecNovelty.primaryArtistKey("Withered Hand"), "withered hand")
        // Agrees with the similarity normalizer on the cases that carry no separator at all.
        XCTAssertEqual(RecNovelty.primaryArtistKey("The Beatles"),
                       PuzzleSimilarity.artistKey("The Beatles"))
    }

    /// ADVERSARIAL: one artist owns the entire top of the ranking, wearing a different credit
    /// string on every row. This is the exact shape that defeated the shipped cap.
    func testTheCapHoldsWhenOneArtistOwnsTheWholeTopOfTheRanking() {
        let credits = ["Drake", "Drake & Future", "Drake feat. 21 Savage", "Drake, Rihanna",
                       "Drake x Lil Baby", "Drake ft. Travis Scott", "Drake / PartyNextDoor",
                       "Drake with Sampha", "DRAKE", "Drake feat. Nobody",
                       "Drake & Someone Else", "Drake feat. Anyone"]
        var tracks = [track("m0", "Drake")]
        for (i, c) in credits.enumerated() { tracks.append(track("s\(i)", c)) }
        // …and he has played every single one of them into the ground.
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { id in id == "m0" ? 0 : 500 }, limit: 25)
        XCTAssertEqual(out.count, 3,
                       "one artist gets at most 3 rows however many credit strings they wear "
                       + "(got \(out))")
    }

    /// The cap is a property of the OUTPUT, so no change to the score can defeat it. Driven by
    /// making the ranking maximally hostile: the capped artist holds every one of the top scores.
    func testTheCapIsAppliedAfterTheSortAndCannotBeOutrankedIntoSubmission() {
        var tracks = [track("m0", "Solo Act")]
        for i in 0..<40 { tracks.append(track("hot\(i)", "Solo Act")) }
        for i in 0..<40 { tracks.append(track("other\(i)", "Other \(i)")) }
        var t = ZoneEngine.Tuning()
        t.maxPerArtist = 3
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { $0.hasPrefix("hot") ? 5_000 : 0 },
                                         limit: 25, tuning: t)
        let hot = out.filter { $0.hasPrefix("hot") }.count
        XCTAssertLessThanOrEqual(hot, 3, "the artist that wins every head-to-head still gets 3")
        XCTAssertEqual(out.count, 25, "and the tile is still full — the cap SKIPS, it never stops")
    }

    // ========================================================================
    // MARK: - Novelty beats familiarity…
    // ========================================================================

    /// The head-to-head the owner's instruction is about: two songs identical on every SIMILARITY
    /// field, differing only in artist and in play history.
    func testANeverPlayedSongOutranksAHeavilyPlayedOneAtComparableSimilarity() {
        let tracks = [track("m0", "Seed Artist"),
                      track("worn", "Worn Out"),
                      track("fresh", "Never Heard")]
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { $0 == "worn" ? 400 : 0 }, limit: 25)
        XCTAssertEqual(out.first, "fresh",
                       "equal similarity ⇒ the artist he has never reached for leads (got \(out))")
    }

    /// FEEDBACK HEADROOM, stated as the number the argument turns on. On a candidate pool at the
    /// library's own base rate, the tile must stop selecting almost exclusively for play history —
    /// otherwise a 👍 is only ever confirming what the ranking already read.
    func testTheTileNoLongerSelectsAlmostExclusivelyForPlayHistory() {
        // 60 candidates, half of them played, all equally similar to the member.
        var tracks = [track("m0", "Seed Artist")]
        var counts: [String: Int] = [:]
        for i in 0..<30 {
            tracks.append(track("played\(i)", "Played Artist \(i)"))
            counts["played\(i)"] = 100 + i
            tracks.append(track("unplayed\(i)", "Unplayed Artist \(i)"))
        }
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { counts[$0] ?? 0 }, limit: 25)
        let neverPlayed = out.filter { $0.hasPrefix("unplayed") }.count
        XCTAssertGreaterThanOrEqual(
            neverPlayed, out.count / 2,
            "the pool is 50/50 played, so a tile that is not biased on play count should be too "
            + "(got \(neverPlayed)/\(out.count)) — this is the headroom a 👍 now carries "
            + "information about")
    }

    // ========================================================================
    // MARK: - …but novelty is NOT randomness
    // ========================================================================

    /// The boundary, as a theorem rather than a hope: SIMILARITY GATES, NOVELTY REORDERS. Because
    /// the aux mix is a bounded MULTIPLIER on similarity rather than an addend, a candidate can
    /// never outrank one whose similarity is more than `1 + suggestionAuxGain` times its own.
    ///
    /// A novel-but-irrelevant suggestion is worse than a familiar one, and an ADDED novelty term
    /// has no such bound — at the bottom of the admitted similarity range a flat +0.20 is a
    /// multi-fold swing. That is how "novelty" becomes "noise", and it is what this shape rules
    /// out structurally.
    func testAMaximallyNovelSongCannotOutrankAGenuinelyBetterMatch() {
        // `far` shares only the genre; `near` shares the artist AND the era. Nothing about `far`
        // is familiar and everything about `near` is.
        let tracks = [
            ZoneEngine.Track(songId: "m0", artistKey: "seed", artistName: "Seed", genre: "g",
                             year: 2000),
            ZoneEngine.Track(songId: "near", artistKey: "seed", artistName: "Seed", genre: "g",
                             year: 2000),
            ZoneEngine.Track(songId: "far", artistKey: "nobody", artistName: "Nobody", genre: "g",
                             year: 1930),
        ]
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { $0 == "near" ? 5_000 : 0 }, limit: 25)
        XCTAssertEqual(out.first, "near",
                       "similarity still decides the tier — novelty only reorders inside it "
                       + "(got \(out))")
    }

    /// The admission rule is untouched: novelty cannot admit a song that shares no artist and no
    /// genre with the collection. Novelty reorders the eligible; it does not widen eligibility.
    func testNoveltyCannotAdmitASongTheSimilarityGateRejected() {
        let tracks = [track("m0", "Seed Artist", genre: "rock"),
                      track("related", "Other", genre: "rock"),
                      track("unrelated", "Nobody At All", genre: "polka")]
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { _ in 0 }, limit: 25)
        XCTAssertTrue(out.contains("related"))
        XCTAssertFalse(out.contains("unrelated"),
                       "no shared artist or genre ⇒ not admitted, however novel")
    }

    // ========================================================================
    // MARK: - The renormalization rule
    // ========================================================================

    /// 47.8% of the owner's real catalog has NO play data. A novelty axis that scored those rows
    /// 1.0 by default would promote half the library for a missing field; one that scored them 0
    /// would bury it. Artist novelty avoids both because it is an artist AGGREGATE — a deep cut by
    /// an artist he wears out is FAMILIAR even though that song has never been played.
    ///
    /// Measured over the real candidate pools the two distributions overlap heavily rather than
    /// partitioning: never-played rows mean 0.679 (p10 0.34), played rows mean 0.523 (p10 0.29).
    func testArtistNoveltyIsAnAggregateSoAnUnplayedDeepCutIsStillFamiliar() {
        let fam = RecNovelty.artistFamiliarity([
            (artistKey: "huge", plays: 500),      // one heavily-played song…
            (artistKey: "huge", plays: 0),        // …and an unplayed deep cut by the same artist
            (artistKey: "ignored", plays: 1),
        ])
        XCTAssertTrue(fam.isLive)
        XCTAssertLessThan(fam.novelty("huge"), 0.05,
                          "the ARTIST is known, so the unplayed deep cut is not a discovery")
        XCTAssertGreaterThan(fam.novelty("ignored"), 0.85,
                             "one play does not make an artist familiar")
        XCTAssertEqual(fam.novelty("never seen"), 1.0, accuracy: 1e-9,
                       "an artist with no plays at all is the strongest form of the signal")
    }

    /// A DEVICE WITH NO PLAY DATA AT ALL. The axis reports dead and leaves the denominator, so the
    /// ranking is byte-identical to the pure-similarity one — not a uniform 1.0 for every row,
    /// which would be a silent no-op today and a silent bias the moment a second aux term arrives.
    func testWithNoPlayDataAnywhereTheNoveltyAxisIsDeadRatherThanUniform() {
        let dead = RecNovelty.artistFamiliarity([(artistKey: "a", plays: 0)])
        XCTAssertFalse(dead.isLive)
        XCTAssertEqual(dead.novelty("a"), 0, "dead ⇒ 0, so it cannot lift anything")
        XCTAssertEqual(RecNovelty.aux(novelty: 1, familiarity: 0, noveltyWeight: 0.75,
                                      familiarityWeight: 0.25, isLive: false), 0,
                       "no live signal ⇒ aux 0 ⇒ the multiplier is exactly 1")

        // …and end to end: the tile ranks purely on similarity, with the same rows in the same
        // order the engine produced before novelty existed.
        var tracks = [track("m0", "Seed")]
        for i in 0..<20 { tracks.append(track("s\(i)", "Artist \(i)")) }
        let noPlays = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                             playCount: { _ in 0 }, limit: 25)
        var t = ZoneEngine.Tuning()
        t.suggestionAuxGain = 0            // the aux mix switched off entirely
        let similarityOnly = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                                    playCount: { _ in 0 }, limit: 25, tuning: t)
        XCTAssertEqual(noPlays, similarityOnly,
                       "with nothing to measure, the rebalance is a no-op rather than a shuffle")
    }

    // ========================================================================
    // MARK: - In Da Zone keeps its rediscovery semantics
    // ========================================================================

    /// The novelty term is safe to add to the rediscovery pool BECAUSE it is artist-level: it is
    /// constant across a discography, so it cannot reorder two songs by one artist. "You used to
    /// love this beats you never played this" is a deliberate feature of that pool, and it
    /// survives exactly — which is what this pins from the other side.
    func testInDaZoneRediscoveryStillPrefersTheBuriedFavouriteWithinAnArtist() {
        let songs = [song("seed", artist: "A", year: 2000),
                     song("loved", artist: "A", year: 2000),
                     song("never", artist: "A", year: 2000)]
        let genres = ["seed": "g", "loved": "g", "never": "g"]
        let counts = ["loved": 80, "never": 0, "seed": 5]
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                    plays: [.init(songId: "seed", playedAtMs: now - 2 * day)],
                                    playCount: { counts[$0] ?? 0 },
                                    lastPlayedMs: ["loved": now - 1_200 * day], nowMs: now)
        let buried = q.picks.filter { $0.pool == .rediscovery }.map(\.songId)
        XCTAssertEqual(buried.first, "loved",
                       "artist novelty is identical for both, so it cannot decide this pair")
    }

    /// …and ACROSS artists it does decide — which is the half that fixes the zone's reach, and the
    /// half that shows artist novelty is not the song's play count under another name.
    ///
    /// ── WHY THE TWO CANDIDATES HAVE THE SAME PLAY COUNT ──────────────────────────────────────
    /// This is the whole point of the axis, so the fixture makes it the only variable. `known` and
    /// `unknown` have been played the same number of times, so the song-level familiarity term is
    /// IDENTICAL for both and cannot decide anything. What differs is the artist behind them: one
    /// is a discography he has worn out, the other has this one record and nothing else. A
    /// song-level novelty term — which is algebraically just `−playCount` — is blind to that
    /// distinction by construction. This one is not.
    ///
    /// It also has to beat `known`'s heavily-played SIBLINGS, whose song familiarity is maximal:
    /// the artist term is strong enough to outweigh a full-strength play count on a different row.
    func testInDaZoneRediscoveryReachesPastTheArtistHeAlreadyWearsOut() {
        var songs = [song("seed", artist: "Hot", year: 2000)]
        var genres = ["seed": "g"]
        var counts = ["seed": 50]
        songs.append(song("known", artist: "Big Catalog", year: 2000))
        songs.append(song("unknown", artist: "One Record", year: 2000))
        genres["known"] = "g"; genres["unknown"] = "g"
        counts["known"] = 10; counts["unknown"] = 10        // …the SAME song-level play count
        // What makes "Big Catalog" familiar is the rest of his shelf, not this record.
        for i in 0..<5 {
            songs.append(song("big\(i)", artist: "Big Catalog", year: 2000))
            genres["big\(i)"] = "g"
            counts["big\(i)"] = 500
        }
        var t = ZoneEngine.Tuning()
        t.minSongs = 0
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                    plays: [.init(songId: "seed", playedAtMs: now - 2 * day)],
                                    playCount: { counts[$0] ?? 0 },
                                    lastPlayedMs: [:], nowMs: now, tuning: t)
        let buried = q.picks.filter { $0.pool == .rediscovery }.map(\.songId)
        XCTAssertEqual(buried.first, "unknown",
                       "equal plays, equal dormancy, equal similarity ⇒ the unworn artist leads "
                       + "(got \(buried))")

        // …and with the novelty term switched off, the ARTIST is invisible and the ranking falls
        // back to raw play count — which is exactly the behaviour the owner reported.
        var off = t
        off.auxNoveltyWeight = 0
        let before = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                         plays: [.init(songId: "seed", playedAtMs: now - 2 * day)],
                                         playCount: { counts[$0] ?? 0 },
                                         lastPlayedMs: [:], nowMs: now, tuning: off)
        let buriedBefore = before.picks.filter { $0.pool == .rediscovery }.map(\.songId)
        XCTAssertTrue(buriedBefore.first?.hasPrefix("big") == true,
                      "without it the worn-out artist's most-played row leads (got \(buriedBefore))")
    }

    /// The bounded band survives the extra aux term: it is a renormalized mean of 0…1 signals, so
    /// `aux ≤ 1` and the multiplier stays inside `1 + auxGain` however many signals join.
    func testTheAuxMixStaysWithinItsBandWhateverTheInputs() {
        for n in stride(from: 0.0, through: 1.0, by: 0.25) {
            for f in stride(from: 0.0, through: 1.0, by: 0.25) {
                let aux = RecNovelty.aux(novelty: n, familiarity: f, noveltyWeight: 0.75,
                                         familiarityWeight: 0.25, isLive: true)
                XCTAssertGreaterThanOrEqual(aux, 0)
                XCTAssertLessThanOrEqual(aux, 1, "aux is a mean of 0…1 signals, so it is 0…1")
            }
        }
    }

    // ========================================================================
    // MARK: - Explainability
    // ========================================================================

    /// A novelty term that cannot be read off the row is indistinguishable from the engine being
    /// random. The reason is a pure function of the same inputs the ranking used, so it can never
    /// disagree with the score that produced it.
    func testEverySuggestionCarriesAReadableReasonAndNoveltyLeadsWhenItIsWhy() {
        let tracks = [track("m0", "Seed Artist"),
                      track("same", "Seed Artist"),
                      track("fresh", "Never Heard")]
        let rows = ZoneEngine.suggestionsExplained(memberSongIds: ["m0"], tracks: tracks,
                                                   playCount: { $0 == "same" ? 400 : 0 })
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { !$0.why.isEmpty }, "every row explains itself")
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.songId, $0.why) })
        XCTAssertEqual(byId["fresh"], "An artist you've never played")
        XCTAssertEqual(byId["same"], "An artist already in here")
        XCTAssertEqual(rows.map(\.songId),
                       ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                              playCount: { $0 == "same" ? 400 : 0 }),
                       "the explained ranking IS the ranking, not a second opinion")
    }
}
