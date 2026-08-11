import XCTest
@testable import PocketDJ

/// TARGETED AUDIO ANALYSIS — the selection half, as tests.
///
/// Owner, verbatim: *"it doesn't need to do audio analysis on the entire collection, only use v1
/// to get a list of candidates, and then for whatever it thinks are the most novel and most
/// similar to what i have recently listened to (again restricting to only in-catalog items) run
/// audio analysis on them"*.
///
/// Four sentences, four constraints, and each of them is a way this can go quietly wrong:
///  · **v1's candidates and nothing else** — a shortlist that reached past the ranking would put
///    the night's CPU on songs the recommender never intends to offer;
///  · **novel AND similar** — either one alone is a documented failure mode (novel-only analyses
///    noise, similar-only analyses what the metadata already ranks correctly), so the test that
///    matters is that a lopsided input still produces both;
///  · **in-catalog only** — the rule that keeps the job bounded and stops it ripping the world;
///  · **bounded and cumulative** — a night's budget, a per-artist cap, and no re-proposing what
///    the server is already holding.
///
/// The discrimination claim these features exist to make good on was measured against the real
/// catalog rather than asserted here: 96 songs across 12 artist+genre groups, mean pairwise
/// timbre distance 0.205 WITHIN an artist+genre against 0.288 BETWEEN groups (ratio 0.71), with
/// the widest same-artist pair at 0.705 — nearly three times the between-group median. Songs that
/// share an artist and a genre are, in timbre, almost as far apart as songs that share neither.
final class RecAudioShortlistTests: XCTestCase {

    private func candidate(_ id: String, artist: String, genre: String? = "rock",
                           bpm: Double? = nil, camelot: String? = nil) -> RecAudioShortlist.Candidate {
        RecAudioShortlist.Candidate(songId: id, artistKey: RecNovelty.primaryArtistKey(artist),
                                    genre: genre, bpm: bpm, camelot: camelot)
    }

    private func track(_ id: String, _ credit: String, genre: String? = "rock",
                       bpm: Double? = nil, camelot: String? = nil) -> ZoneEngine.Track {
        ZoneEngine.Track(songId: id, artistKey: PuzzleSimilarity.artistKey(credit),
                         artistName: credit, genre: genre, bpm: bpm, camelot: camelot)
    }

    // ========================================================================
    // MARK: - Both criteria, not one
    // ========================================================================

    /// THE CLAIM THE WHOLE DESIGN RESTS ON: a shortlist contains rows chosen for NOVELTY and rows
    /// chosen for SIMILARITY, even when the two rankings disagree completely.
    ///
    /// The input is adversarial on purpose — the most novel songs are the LEAST similar and vice
    /// versa — because that is the only arrangement in which a naive "take the top N of one score"
    /// implementation is distinguishable from the alternating one. With a blended single score the
    /// middle of the list wins and neither end is analysed, which is the outcome that would spend
    /// a night of CPU learning nothing about either extreme.
    func testShortlistDrawsFromBothCriteria() {
        // Familiar artist, dead centre of recent listening.
        let familiarSimilar = (0..<5).map { candidate("sim\($0)", artist: "Known", genre: "rock", bpm: 120) }
        // Never-played artist, nothing like recent listening.
        let novelDistant = (0..<5).map { candidate("nov\($0)", artist: "Stranger\($0)", genre: "jazz", bpm: 60) }

        var inputs = RecAudioShortlist.Inputs()
        inputs.candidates = familiarSimilar + novelDistant
        inputs.recent = RecAudioShortlist.RecentProfile(genreShare: ["rock": 1.0], meanBpm: 120)
        inputs.familiarity = RecNovelty.ArtistFamiliarity(artistPlays: ["known": 500])
        inputs.perNight = 4
        inputs.perArtistCap = 5

        let picked = RecAudioShortlist.select(inputs)
        XCTAssertEqual(picked.count, 4)
        XCTAssertTrue(picked.contains { $0.hasPrefix("nov") }, "no NOVEL row was analysed")
        XCTAssertTrue(picked.contains { $0.hasPrefix("sim") }, "no SIMILAR row was analysed")
        // Strict alternation, novel first.
        XCTAssertTrue(picked[0].hasPrefix("nov"))
        XCTAssertTrue(picked[1].hasPrefix("sim"))
    }

    /// When one criterion runs out the other finishes the night, rather than the shortlist
    /// stopping short at half the budget. A night that analyses 20 songs because only 20 were
    /// novel is 20 songs of wasted window.
    func testOneSideExhaustedLetsTheOtherFinish() {
        var inputs = RecAudioShortlist.Inputs()
        inputs.candidates = (0..<6).map { candidate("s\($0)", artist: "Known", genre: "rock", bpm: 120) }
        inputs.recent = RecAudioShortlist.RecentProfile(genreShare: ["rock": 1.0], meanBpm: 120)
        inputs.familiarity = RecNovelty.ArtistFamiliarity(artistPlays: ["known": 500])
        inputs.perNight = 6
        inputs.perArtistCap = 6

        XCTAssertEqual(RecAudioShortlist.select(inputs).count, 6)
    }

    /// A dead recent-listening profile (a fresh install, or a device with no play history) must
    /// leave the shortlist working off novelty alone rather than producing nothing or producing
    /// noise. Every similarity is 0, so the ordering falls through to v1's own.
    func testDeadRecentProfileFallsBackToNovelty() {
        var inputs = RecAudioShortlist.Inputs()
        inputs.candidates = [candidate("a", artist: "Known"), candidate("b", artist: "Stranger")]
        inputs.recent = RecAudioShortlist.RecentProfile()
        inputs.familiarity = RecNovelty.ArtistFamiliarity(artistPlays: ["known": 100])
        inputs.perNight = 2
        let picked = RecAudioShortlist.select(inputs)
        XCTAssertEqual(picked, ["b", "a"], "the never-played artist should lead")
    }

    // ========================================================================
    // MARK: - Bounded, capped, cumulative
    // ========================================================================

    /// The night's budget is a hard ceiling. It is what makes a 107,757-row catalog tractable at
    /// all — the alternative is a 330 CPU-hour sweep of songs that will never be recommended.
    func testRespectsNightlyBudget() {
        var inputs = RecAudioShortlist.Inputs()
        inputs.candidates = (0..<200).map { candidate("s\($0)", artist: "A\($0)") }
        inputs.perNight = 40
        XCTAssertEqual(RecAudioShortlist.select(inputs).count, 40)
    }

    /// A per-artist cap that a collaboration credit can walk around is not a cap — the same bug
    /// `RecNovelty.primaryArtistKey` exists to fix, and it bites here too: without it one artist's
    /// deep cuts can eat an entire night.
    func testPerArtistCapCountsCollaborationsAgainstThePrimaryArtist() {
        var inputs = RecAudioShortlist.Inputs()
        inputs.candidates = [
            candidate("a", artist: "Drake"),
            candidate("b", artist: "Drake & Future"),
            candidate("c", artist: "Drake feat. Rihanna"),
            candidate("d", artist: "Drake x 21 Savage"),
            candidate("e", artist: "Aaliyah"),
        ]
        inputs.perNight = 5
        inputs.perArtistCap = 2
        let picked = RecAudioShortlist.select(inputs)
        XCTAssertEqual(picked.count, 3, "2 Drake-credited rows + Aaliyah")
        XCTAssertTrue(picked.contains("e"))
    }

    /// Successive refreshes must propose NEW songs. The server is already holding what was sent
    /// before, and re-ranking it would spend the night's budget re-queueing work in flight — the
    /// idempotence the refresh protocol rests on, enforced on the client side too so the wire
    /// stays quiet rather than merely the server being tolerant.
    func testSkipsWhatIsAlreadyQueuedOrAnalysed() {
        var inputs = RecAudioShortlist.Inputs()
        inputs.candidates = (0..<5).map { candidate("s\($0)", artist: "A\($0)") }
        inputs.analysedIds = ["s0", "s1"]
        inputs.pendingIds = ["s2"]
        inputs.perNight = 10
        XCTAssertEqual(Set(RecAudioShortlist.select(inputs)), ["s3", "s4"])
    }

    /// Deterministic for a fixed input: the same ranking twice must produce the same shortlist, or
    /// two refreshes in a minute queue two different nights' work for the same evidence.
    func testDeterministic() {
        var inputs = RecAudioShortlist.Inputs()
        inputs.candidates = (0..<30).map {
            candidate("s\($0)", artist: "A\($0 % 7)", genre: $0.isMultiple(of: 2) ? "rock" : "jazz",
                      bpm: Double(90 + $0))
        }
        inputs.recent = RecAudioShortlist.RecentProfile(genreShare: ["rock": 0.8, "jazz": 0.2], meanBpm: 100)
        inputs.familiarity = RecNovelty.ArtistFamiliarity(artistPlays: ["a0": 300, "a1": 40])
        inputs.perNight = 12
        XCTAssertEqual(RecAudioShortlist.select(inputs), RecAudioShortlist.select(inputs))
    }

    // ========================================================================
    // MARK: - Similarity
    // ========================================================================

    /// The tempo term is renormalized over LIVE axes, so a profile that knows only tempo scores on
    /// tempo alone — it must not be deflated by the two dead axes into a number that novelty then
    /// dominates by construction. Only 10.6% of this catalog carries a tempo, so "the axis is
    /// dead" is the common case rather than the exotic one.
    func testSimilarityRenormalizesOverLiveAxesOnly() {
        let p = RecAudioShortlist.RecentProfile(meanBpm: 120)
        XCTAssertEqual(RecAudioShortlist.similarity(candidate("x", artist: "A", genre: nil, bpm: 120), p),
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(RecAudioShortlist.similarity(candidate("y", artist: "A", genre: nil, bpm: 200), p),
                       0.0, accuracy: 0.0001)
    }

    /// A harmonic neighbour is most of a match, not none of one — the relationship the mix decks
    /// already call compatible, so the two halves of the app cannot disagree about it.
    func testCamelotNeighbourScoresBelowAnExactMatch() {
        let p = RecAudioShortlist.RecentProfile(camelotCodes: ["8A"])
        let exact = RecAudioShortlist.similarity(candidate("a", artist: "A", genre: nil, camelot: "8A"), p)
        let near = RecAudioShortlist.similarity(candidate("b", artist: "A", genre: nil, camelot: "9A"), p)
        let far = RecAudioShortlist.similarity(candidate("c", artist: "A", genre: nil, camelot: "3B"), p)
        XCTAssertEqual(exact, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(near, far)
        XCTAssertLessThan(near, exact)
        XCTAssertEqual(far, 0.0, accuracy: 0.0001)
        XCTAssertTrue(RecAudioShortlist.camelotAdjacent("12A", "1A"), "the wheel wraps")
        XCTAssertTrue(RecAudioShortlist.camelotAdjacent("8A", "8B"), "relative major/minor")
        XCTAssertFalse(RecAudioShortlist.camelotAdjacent("8A", "junk"))
    }

    /// Genre share is read RELATIVE to the listener's top genre. Absolute shares in a 14-bucket
    /// distribution sit near 0.2 even for a favourite, which would leave the axis permanently
    /// mute next to a novelty term that reaches 1.0.
    func testGenreShareIsRelativeToTheTopGenre() {
        let p = RecAudioShortlist.RecentProfile(genreShare: ["rock": 0.3, "jazz": 0.15])
        let top = RecAudioShortlist.similarity(candidate("a", artist: "A", genre: "rock"), p)
        let half = RecAudioShortlist.similarity(candidate("b", artist: "A", genre: "jazz"), p)
        let none = RecAudioShortlist.similarity(candidate("c", artist: "A", genre: "polka"), p)
        XCTAssertEqual(top, 1.0, accuracy: 0.0001)
        XCTAssertEqual(half, 0.5, accuracy: 0.0001)
        XCTAssertEqual(none, 0.0, accuracy: 0.0001)
    }

    /// The profile folder must not let rows with missing fields vote on axes they say nothing
    /// about. A song with no tempo dragging the mean toward 0 is the bug that would make the
    /// tempo term describe COVERAGE rather than taste.
    func testRecentProfileIgnoresMissingFields() {
        let p = RecAudioShortlist.RecentProfile(recent: [
            candidate("a", artist: "A", genre: "rock", bpm: 100, camelot: "8A"),
            candidate("b", artist: "B", genre: nil, bpm: nil, camelot: nil),
            candidate("c", artist: "C", genre: "rock", bpm: 140, camelot: nil),
        ])
        XCTAssertEqual(p.meanBpm ?? 0, 120, accuracy: 0.0001, "the tempo-less row must not vote")
        XCTAssertEqual(p.genreShare["rock"] ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(p.camelotCodes, ["8A"])
        XCTAssertTrue(p.isLive)
        XCTAssertFalse(RecAudioShortlist.RecentProfile(recent: []).isLive)
    }

    // ========================================================================
    // MARK: - The bridge from the ranking
    // ========================================================================

    /// IN-CATALOG ONLY, and structurally rather than by filter: the shortlist is built by looking
    /// each suggested id up in `inputs.tracks`, so an id the catalog cannot resolve simply has no
    /// row to contribute. This is what makes "do not rip or analyse anything unowned" a property
    /// of the pipeline instead of a rule someone has to remember.
    func testShortlistDropsIdsThisCatalogCannotResolve() {
        var inputs = ForYouFeedInputs()
        inputs.tracks = [track("owned", "Artist A"), track("owned2", "Artist B")]
        let snap = ForYouFeedSnapshot(refreshedAtMs: 1, zoneIds: ["owned", "ghost", "owned2"])
        let ids = ForYouFeedBuilder.audioShortlist(snap, inputs: inputs)
        XCTAssertEqual(Set(ids), ["owned", "owned2"])
        XCTAssertFalse(ids.contains("ghost"))
    }

    /// The candidates are v1's OWN answer — the zone plus every crate's suggestions, deduped.
    /// A song can headline the zone and be suggested for three crates; it needs analysing once.
    func testShortlistTakesZoneAndCratesAndDedupes() {
        var inputs = ForYouFeedInputs()
        inputs.tracks = (0..<4).map { track("s\($0)", "Artist \($0)") }
        let snap = ForYouFeedSnapshot(
            refreshedAtMs: 1,
            zoneIds: ["s0", "s1"],
            crates: [.init(id: "c1", kind: "playlist", name: "C", songIds: ["s1", "s2"]),
                     .init(id: "c2", kind: "pocket", name: "D", songIds: ["s3"])])
        let ids = ForYouFeedBuilder.audioShortlist(snap, inputs: inputs)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(Set(ids), ["s0", "s1", "s2", "s3"])
    }

    /// An empty catalog produces an empty shortlist rather than a list of ids nothing can open —
    /// the same "never act on a transient empty state" rule `ForYouFeedStore.refresh` follows.
    func testShortlistEmptyWithoutTracks() {
        XCTAssertTrue(ForYouFeedBuilder.audioShortlist(
            ForYouFeedSnapshot(refreshedAtMs: 1, zoneIds: ["a"]), inputs: ForYouFeedInputs()).isEmpty)
    }

    /// The recent-listening profile comes from the SAME play window the zone was ranked against,
    /// so "similar to what I have recently listened to" means the same thing here as on the tile.
    func testShortlistPrefersTheRecentlyPlayedShapeAmongEqualNovelty() {
        var inputs = ForYouFeedInputs()
        inputs.tracks = [track("recent", "R"), track("near", "N", genre: "rock", bpm: 122),
                         track("far", "F", genre: "polka", bpm: 60)]
        inputs.plays = [ZoneEngine.Play(songId: "recent", playedAtMs: 1)]
        // `recent` itself carries the shape the profile is folded from.
        inputs.tracks[0] = track("recent", "R", genre: "rock", bpm: 120)
        let snap = ForYouFeedSnapshot(refreshedAtMs: 1, zoneIds: ["far", "near"])
        let ids = ForYouFeedBuilder.audioShortlist(snap, inputs: inputs, perNight: 1)
        XCTAssertEqual(ids, ["far"], "with no play counts every artist is equally novel, so v1 order leads")

        let two = ForYouFeedBuilder.audioShortlist(snap, inputs: inputs, perNight: 2)
        XCTAssertEqual(Set(two), ["far", "near"])
        XCTAssertEqual(two[1], "near", "the similar slot must pick the row nearest recent listening")
    }
}
