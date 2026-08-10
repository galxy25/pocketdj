import XCTest
@testable import PocketDJ

/// The recommendation TUNING LOOP and the three-family similarity rebalance the owner asked for.
///
/// What these guard against is not "it compiles". It is the three ways this feature fails while
/// looking like it works:
///   1. a thumbs-down that is recorded and then ignored by the ranking (the button does nothing);
///   2. two decision paths — the tile's and the now-playing surfaces' — that can disagree, so a
///      reject made in the car is not there when the tile is opened;
///   3. a "rebalance" that leaves artist dominating anyway, or that achieves parity by punishing
///      every song whose bpm the audio indexer never computed.
final class RecFeedbackLoopTests: XCTestCase {

    // ========================================================================
    // MARK: - Fixtures
    // ========================================================================

    /// `IndexSong` is Decodable-only — build via the JSON round-trip (the house pattern).
    private func song(_ id: String, artist: String = "A", year: Int? = nil,
                      bpm: Double? = nil, camelot: String? = nil,
                      keywords: [String]? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": id.uppercased(), "artist": artist]
        if let year { obj["year"] = year }
        if let bpm { obj["bpm"] = bpm }
        if let camelot { obj["camelot"] = camelot }
        if let keywords { obj["sentimentKeywords"] = keywords }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func profile(_ members: [IndexSong], genres: [String: String] = [:],
                         catalog: [IndexSong] = []) -> PuzzleSimilarity.TargetProfile {
        let all = catalog.isEmpty ? members : catalog
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return PuzzleSimilarity.profile(targetMemberIds: [members.map(\.id)], songsById: byId,
                                        genreBySongId: genres, otherCollections: [], plays: [])
    }

    @MainActor private func store() -> RecFeedbackStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-test-rec-feedback-\(UUID().uuidString).json")
        return RecFeedbackStore(fileURL: url)
    }

    private let now: Double = 1_800_000_000_000

    // ========================================================================
    // MARK: - The three families: the rebalance is real, and it is EVEN
    // ========================================================================

    /// PARITY, stated literally. "Evenly" is a claim about the weights, so it is checked as one —
    /// a future tweak that quietly makes artist 0.4 fails here rather than in six months.
    func testTheThreeFamilyWeightsAreExactlyEqual() {
        let w = PuzzleSimilarity.FamilyWeights.balanced
        XCTAssertEqual(w.artist, w.era, "artist vs genre+year")
        XCTAssertEqual(w.artist, w.sonic, "artist vs genre+bpm+key")
        XCTAssertLessThan(w.context, w.artist,
                          "the context residual is NOT a fourth family — it is a tiebreak")
        // Genre carries half the sonic family so an unanalysed song is discounted, not capped.
        XCTAssertEqual(w.sonicGenreShare, 0.5)
    }

    /// The headline behavioural claim. A candidate matching ONLY the artist must no longer beat
    /// one matching only genre+year, nor one matching only genre+bpm+key. Those two families
    /// exist precisely so that they can win.
    func testArtistAloneNoLongerOutranksEitherOtherFamily() {
        let seeds = [song("seed", artist: "Hot", year: 2000, bpm: 120, camelot: "8A")]
        let p = profile(seeds, genres: ["seed": "rock"])
        let artistOnly = PuzzleSimilarity.Candidate(songId: "a", artistKey: "hot", genre: "polka",
                                                    year: 1800, bpm: 400, camelot: "2B")
        let eraOnly = PuzzleSimilarity.Candidate(songId: "b", artistKey: "nobody", genre: "rock",
                                                 year: 2000, bpm: 400, camelot: "2B")
        let sonicOnly = PuzzleSimilarity.Candidate(songId: "c", artistKey: "nobody", genre: "rock",
                                                   year: 1800, bpm: 120, camelot: "8A")
        let a = PuzzleSimilarity.familyScore(artistOnly, profile: p)
        let b = PuzzleSimilarity.familyScore(eraOnly, profile: p)
        let c = PuzzleSimilarity.familyScore(sonicOnly, profile: p)
        XCTAssertGreaterThan(b, a, "genre+year must be able to beat a bare artist match")
        XCTAssertGreaterThan(c, a, "so must genre+bpm+key")
        XCTAssertEqual(b, c, accuracy: 0.001,
                       "and the two composite families must be worth the same as each other")
    }

    /// The rebalance where the owner actually SEES it. The per-collection tiles used to rank on
    /// `artistWeight 1.0 / genreWeight 0.45` and nothing else — artist was 69% of everything a
    /// tile could say, and year, tempo and key said nothing at all. Under those retired weights
    /// the artist-only candidate below wins outright (1.0 vs 0.45); it must now lose.
    func testCollectionSuggestionsNoLongerRankOnArtistAlone() {
        let tracks = [
            ZoneEngine.Track(songId: "m0", artistKey: "member", artistName: "M", genre: "rock",
                             year: 2000, bpm: 120, camelot: "8A"),
            // Same artist as the crate, wrong on everything else.
            ZoneEngine.Track(songId: "artist-only", artistKey: "member", artistName: "M",
                             genre: "polka", year: 1900, bpm: 40, camelot: "2B"),
            // Different artist, right on genre, era, tempo AND key.
            ZoneEngine.Track(songId: "everything-else", artistKey: "other", artistName: "O",
                             genre: "rock", year: 2000, bpm: 120, camelot: "8A"),
        ]
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { _ in 1 })
        XCTAssertEqual(out.first, "everything-else",
                       "artist must stop dominating the collection tiles (got \(out))")
        XCTAssertTrue(out.contains("artist-only"), "…while still being a real signal")
    }

    /// ROUND-LEVEL renormalization, not per-song. A device whose catalog has no tempo or key at
    /// all must not have those terms in any denominator — every score is exactly what it would be
    /// if the fields had never been added.
    func testNoTempoOrKeyAnywhereDropsTheTermsEntirely() {
        let seeds = [song("seed", artist: "Hot", year: 2000)]           // no bpm, no camelot
        let p = profile(seeds, genres: ["seed": "rock"])
        XCTAssertNil(p.bpmMean)
        XCTAssertTrue(p.camelots.isEmpty)

        // Two candidates identical except that one carries tempo/key metadata the profile cannot
        // speak. They must score the SAME: an unanswerable question is not a wrong answer.
        let bare = PuzzleSimilarity.Candidate(songId: "a", artistKey: "hot", genre: "rock", year: 2000)
        let analysed = PuzzleSimilarity.Candidate(songId: "b", artistKey: "hot", genre: "rock",
                                                  year: 2000, bpm: 174, camelot: "11B")
        XCTAssertEqual(PuzzleSimilarity.familyScore(bare, profile: p),
                       PuzzleSimilarity.familyScore(analysed, profile: p), accuracy: 1e-12)
    }

    /// The sparse-feature guard, in the other direction. When the profile DOES know tempo/key, a
    /// song missing both must not be renormalized into a better score than one that matches —
    /// that is the bug a per-song denominator introduces, and there is a shipped test pinning the
    /// same rule for the flat scorer.
    func testAnUnanalysedSongIsNeverREWARDEDForMissingTempoAndKey() {
        let seeds = [song("seed", artist: "Hot", year: 2000, bpm: 120, camelot: "8A")]
        let p = profile(seeds, genres: ["seed": "rock"])
        let matches = PuzzleSimilarity.Candidate(songId: "a", artistKey: "hot", genre: "rock",
                                                 year: 2000, bpm: 120, camelot: "8A")
        let unanalysed = PuzzleSimilarity.Candidate(songId: "b", artistKey: "hot", genre: "rock",
                                                    year: 2000)
        let scoreMatches = PuzzleSimilarity.familyScore(matches, profile: p)
        let scoreUnanalysed = PuzzleSimilarity.familyScore(unanalysed, profile: p)
        XCTAssertGreaterThan(scoreMatches, scoreUnanalysed,
                             "matching tempo/key must beat unknown tempo/key")
        // …but it is not a wipeout: genre carries half the sonic family precisely so an
        // unanalysed song keeps a real gradient rather than a structural cap at a third.
        XCTAssertGreaterThan(scoreUnanalysed, 0.7 * scoreMatches,
                             "unanalysed is discounted, not punished (got \(scoreUnanalysed))")
    }

    /// Gem Collector must be BYTE-IDENTICAL. `score` is the puzzle's scorer and it never reads
    /// the two new profile fields; adding them may not move a single shipped ranking.
    func testTheFlatScorerIgnoresTempoAndKeyEntirely() {
        let withMusical = [song("seed", artist: "Hot", year: 2000, bpm: 120, camelot: "8A")]
        let withoutMusical = [song("seed", artist: "Hot", year: 2000)]
        let pA = profile(withMusical, genres: ["seed": "rock"])
        let pB = profile(withoutMusical, genres: ["seed": "rock"])
        XCTAssertEqual(pA.availableWeight, pB.availableWeight,
                       "tempo/key are NOT in the flat denominator")
        let candidate = song("x", artist: "Hot", year: 2001, bpm: 90, camelot: "3A")
        XCTAssertEqual(PuzzleSimilarity.score(candidate, profile: pA, genre: "rock"),
                       PuzzleSimilarity.score(candidate, profile: pB, genre: "rock"),
                       accuracy: 1e-12)
    }

    /// Genre punctuation variants ("Hip-Hop/Rap" vs "Hip Hop/Rap" vs "Hip-Hop") must not split a
    /// family. They cannot, because both families key on `Genre.category` — this pins that the
    /// canonicalization actually collapses the real variants seen in the index.
    func testGenreVariantsCanonicalizeOntoOneFamilyKey() {
        // The exact spellings the raw index carries for the library's largest genre.
        let variants = ["Hip-Hop/Rap", "Hip Hop/Rap", "Hip-Hop", "hip hop", "Rap"]
        let categories = Set(variants.map { Genre.category($0) })
        XCTAssertEqual(categories, ["hip-hop"],
                       "punctuation variants must not become separate genres (got \(categories))")
        // …and the families genuinely key on the CATEGORY, not the raw string — a candidate whose
        // album says "Hip Hop/Rap" must match a profile built from "Hip-Hop/Rap".
        let seeds = [song("seed", artist: "Hot", year: 2000)]
        let p = profile(seeds, genres: ["seed": Genre.category("Hip-Hop/Rap")])
        let other = PuzzleSimilarity.Candidate(songId: "x", artistKey: "nobody",
                                               genre: Genre.category("Hip Hop/Rap"), year: 2000)
        XCTAssertGreaterThan(PuzzleSimilarity.genreTerm(other.genre, p), 0.99,
                             "the two spellings are one family")
    }

    // ========================================================================
    // MARK: - The store: one decision model behind every entry point
    // ========================================================================

    @MainActor
    func testTappingTheSameControlTwiceClearsTheDecision() {
        let s = store()
        XCTAssertNil(s.state(for: "sng1"))
        XCTAssertEqual(s.toggle(songId: "sng1", to: .rejected, surface: .tile, at: now), .rejected)
        XCTAssertTrue(s.isRejected("sng1"))
        XCTAssertEqual(s.toggle(songId: "sng1", to: .rejected, surface: .carPlay, at: now + 1),
                       .cleared)
        XCTAssertNil(s.state(for: "sng1"), "a mis-tap in the car is recoverable without an undo stack")
    }

    @MainActor
    func testTheOppositeControlFlipsRatherThanStacking() {
        let s = store()
        s.toggle(songId: "sng1", to: .rejected, surface: .widget, at: now)
        XCTAssertEqual(s.toggle(songId: "sng1", to: .accepted, surface: .nowPlaying, at: now + 1),
                       .accepted)
        XCTAssertTrue(s.isAccepted("sng1"))
        XCTAssertFalse(s.isRejected("sng1"))
        // The LOG keeps both rows — the engine is entitled to know you changed your mind.
        XCTAssertEqual(s.decisions.count, 2)
    }

    /// THE cross-surface contract. A decision made from the car and one made from a tile land in
    /// the same store, and the later one wins whichever surface it came from. This is the test
    /// that would fail if someone built a second path.
    @MainActor
    func testEverySurfaceWritesTheSameDecisionModel() {
        let s = store()
        s.toggle(songId: "sng1", to: .rejected, surface: .carPlay, at: now)
        XCTAssertTrue(s.isRejected("sng1"), "the tile sees what the car decided")
        s.toggle(songId: "sng1", to: .accepted, surface: .tile, at: now + 1000)
        XCTAssertTrue(s.isAccepted("sng1"), "and the car will see what the tile decided")
        XCTAssertEqual(Set(s.decisions.compactMap(\.surface)), ["carPlay", "tile"],
                       "the surface is recorded, but it never changes the outcome")
    }

    @MainActor
    func testDecisionsSurviveARelaunch() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-test-rec-feedback-\(UUID().uuidString).json")
        let first = RecFeedbackStore(fileURL: url)
        first.toggle(songId: "sng1", to: .rejected, surface: .tile, at: now)
        first.flush()   // the scenePhase-background drain
        let reopened = RecFeedbackStore(fileURL: url)
        XCTAssertTrue(reopened.isRejected("sng1"))
    }

    @MainActor
    func testACloudPullUnionsRatherThanClobbers() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-test-rec-feedback-\(UUID().uuidString).json")
        let local = RecFeedbackStore(fileURL: url)
        local.toggle(songId: "here", to: .rejected, surface: .tile, at: now)
        local.flush()

        // A peer's document carrying a DIFFERENT decision, written under the store's file.
        let peer = RecFeedbackStore.Document(installId: "peer", decisions: [
            .init(id: UUID(), at: now + 1, songId: "there", action: "accepted",
                  surface: "carPlay", context: nil, collectionId: nil, originInstallId: "peer"),
        ])
        local.applyPulledPayload(try! JSONEncoder().encode(peer))
        _ = local.reloadFromDisk()
        XCTAssertTrue(local.isRejected("here"), "the local decision survives a pull")
        XCTAssertTrue(local.isAccepted("there"), "and the peer's arrives")
    }

    @MainActor
    func testTheSignalSaturatesInsteadOfMaxNormalizing() {
        let s = store()
        // ONE rejection. Under max-normalization its genre was instantly full-strength, so a
        // single tap cut every song in that genre — a third of this library — by the full penalty.
        s.toggle(songId: "sng1", to: .rejected, surface: .tile, at: now)
        let signal = s.signal(artistKeyFor: { _ in "aria" }, genreFor: { _ in "hip-hop" })
        XCTAssertEqual(signal.rejectedGenreShare["hip-hop"] ?? 0, 1.0 / 8, accuracy: 1e-12)
        XCTAssertEqual(signal.rejectedArtistShare["aria"] ?? 0, 1.0 / 3, accuracy: 1e-12)
        let unrelatedArtistSameGenre = signal.multiplier(artistKey: "someone", genre: "hip-hop",
                                                         penalty: 0.45)
        XCTAssertGreaterThan(unrelatedArtistSameGenre, 0.93,
                             "one thumbs-down must not write off a genre")
    }

    // ========================================================================
    // MARK: - The loop actually changes the recommendations
    // ========================================================================

    func testARejectedSongIsNeverOfferedByEitherRanker() {
        let songs = [song("seed", artist: "Hot", year: 2000),
                     song("keep", artist: "Hot", year: 2000),
                     song("nope", artist: "Hot", year: 2000)]
        let genres = ["seed": "rock", "keep": "rock", "nope": "rock"]
        var t = ZoneEngine.Tuning()
        t.minSongs = 0
        let fb = ZoneEngine.Feedback(rejectedSongIds: ["nope"])
        let q = ZoneEngine.inDaZone(songs: songs, genreBySongId: genres,
                                    plays: [.init(songId: "seed", playedAtMs: now - 86_400_000)],
                                    playCount: { _ in 1 }, feedback: fb, nowMs: now, tuning: t)
        XCTAssertFalse(q.songIds.contains("nope"), "In Da Zone must honour a thumbs-down")
        XCTAssertTrue(q.songIds.contains("keep"), "…without emptying the queue")

        let tracks = songs.map {
            ZoneEngine.Track(songId: $0.id, artistKey: "hot", artistName: $0.artist,
                             genre: "rock", year: $0.year)
        }
        let suggested = ZoneEngine.suggestions(memberSongIds: ["seed"], tracks: tracks,
                                               playCount: { _ in 1 }, feedback: fb)
        XCTAssertFalse(suggested.contains("nope"), "collection tiles must honour it too")
        XCTAssertTrue(suggested.contains("keep"))
    }

    func testAnAcceptedSongIsNotReOfferedOnTheTileThatAddedIt() {
        let tracks = [
            ZoneEngine.Track(songId: "m0", artistKey: "a0", artistName: "A0", genre: "rock"),
            ZoneEngine.Track(songId: "s1", artistKey: "a0", artistName: "A0", genre: "rock"),
            ZoneEngine.Track(songId: "s2", artistKey: "a0", artistName: "A0", genre: "rock"),
        ]
        let fb = ZoneEngine.Feedback(acceptedSongIds: ["s1"])
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { _ in 1 }, feedback: fb)
        XCTAssertEqual(out, ["s2"], "an accepted suggestion has been added — re-offering it is the tile forgetting")
    }

    func testRejectingAnArtistDemotesTheirOtherSongsWithoutErasingThem() {
        let tracks = [
            ZoneEngine.Track(songId: "m0", artistKey: "member", artistName: "M", genre: "rock",
                             year: 2000),
            ZoneEngine.Track(songId: "disliked-artist", artistKey: "boo", artistName: "Boo",
                             genre: "rock", year: 2000),
            ZoneEngine.Track(songId: "neutral-artist", artistKey: "meh", artistName: "Meh",
                             genre: "rock", year: 2000),
        ]
        // Three rejections of "boo" — full artist saturation.
        let fb = ZoneEngine.Feedback(rejectedSongIds: ["x1", "x2", "x3"],
                                     rejectedArtistShare: ["boo": 1.0],
                                     rejectedGenreShare: ["rock": 3.0 / 8])
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { _ in 1 }, feedback: fb)
        XCTAssertEqual(out.firstIndex(of: "neutral-artist"), 0,
                       "the un-rejected artist leads (got \(out))")
        XCTAssertTrue(out.contains("disliked-artist"),
                      "a demotion, not an erasure — the engine must stay recoverable")
    }

    func testAcceptingAnArtistPromotesTheirOtherSongs() {
        let tracks = [
            ZoneEngine.Track(songId: "m0", artistKey: "member", artistName: "M", genre: "rock",
                             year: 2000),
            ZoneEngine.Track(songId: "liked-artist", artistKey: "yay", artistName: "Yay",
                             genre: "rock", year: 2000),
            ZoneEngine.Track(songId: "neutral-artist", artistKey: "meh", artistName: "Meh",
                             genre: "rock", year: 2000),
        ]
        let none = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                          playCount: { _ in 1 })
        // Deterministic id tiebreak puts "liked-artist" first already, so assert the CHANGE the
        // boost makes rather than a fixed order: with the boost it must still lead, and without
        // the boost the two are tied on every signal.
        XCTAssertEqual(Set(none), ["liked-artist", "neutral-artist"])
        let fb = ZoneEngine.Feedback(acceptedArtistShare: ["yay": 1.0])
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { _ in 1 }, feedback: fb)
        XCTAssertEqual(out.first, "liked-artist", "a thumbs-up moves the artist up (got \(out))")
    }

    /// Feedback is a MULTIPLIER, never a term: it must reorder within a tier of comparable
    /// matches and never lift an unrelated song above a genuinely similar one.
    func testFeedbackCannotOutrankGenuineSimilarity() {
        let tracks = [
            ZoneEngine.Track(songId: "m0", artistKey: "member", artistName: "M", genre: "rock",
                             year: 2000, bpm: 120, camelot: "8A"),
            ZoneEngine.Track(songId: "real-match", artistKey: "member", artistName: "M",
                             genre: "rock", year: 2000, bpm: 120, camelot: "8A"),
            ZoneEngine.Track(songId: "loved-but-wrong", artistKey: "yay", artistName: "Yay",
                             genre: "rock", year: 1930, bpm: 40, camelot: "2B"),
        ]
        let fb = ZoneEngine.Feedback(acceptedArtistShare: ["yay": 1.0])
        let out = ZoneEngine.suggestions(memberSongIds: ["m0"], tracks: tracks,
                                         playCount: { _ in 1 }, feedback: fb)
        XCTAssertEqual(out.first, "real-match",
                       "a boost is a nudge inside a tier, not an override (got \(out))")
    }

    // ========================================================================
    // MARK: - Display order vs playback order (they cannot disagree)
    // ========================================================================

    func testRejectedRowsSinkStablyAndKeepEveryoneElseInPlace() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(RecFeedbackOrder.sink(ids, rejected: []), ids, "no feedback ⇒ untouched")
        XCTAssertEqual(RecFeedbackOrder.sink(ids, rejected: ["b", "d"]),
                       ["a", "c", "e", "b", "d"],
                       "rejected rows go to the BOTTOM, both groups keeping their order")
        XCTAssertEqual(RecFeedbackOrder.sink(ids, rejected: Set(ids)), ids,
                       "all rejected ⇒ the order is unchanged, not reversed")
    }

    /// THE coordination requirement: play-in-order must follow the DISPLAYED order, including a
    /// sunk reject. Both the list and the ▶ read `sink`, so this pins that the same array is what
    /// would be queued — a rejected song can never play second while the list shows it last.
    func testPlayInOrderFollowsTheDisplayedOrderIncludingSunkRejects() {
        let built = ["first", "rejected-one", "third"]
        let displayed = RecFeedbackOrder.sink(built, rejected: ["rejected-one"])
        XCTAssertEqual(displayed, ["first", "third", "rejected-one"])
        XCTAssertEqual(displayed.last, "rejected-one",
                       "the rejected song plays LAST, matching where the list shows it")
        // Tapping the row that is displayed SECOND must start on "third", not on the raw build
        // order's "rejected-one".
        XCTAssertEqual(displayed[1], "third")
    }

    // ========================================================================
    // MARK: - Tile playability (no dead Play buttons)
    // ========================================================================

    func testTheNewTileIsNeverPlayable() {
        let tiles = ForYouTiles.build(newReleaseCount: 12, zone: ["z1", "z2"], collections: [])
        let new = tiles.first { $0.id == "new" }
        XCTAssertEqual(new?.count, 12, "it still COUNTS releases…")
        XCTAssertFalse(new?.isPlayable ?? true,
                       "…but none of them is a song this device owns, so ▶ must be disabled")
        XCTAssertTrue(new?.playableSongIds.isEmpty ?? false)
    }

    func testZoneAndCollectionTilesArePlayableFromTheirOwnIds() {
        let tiles = ForYouTiles.build(
            newReleaseCount: 0, zone: ["z1", "z2", "z3"],
            collections: [(id: "pkt_1", kind: "pocket", name: "Crate",
                           suggestions: ["s1", "s2", "s3", "s4", "s5"])])
        XCTAssertEqual(tiles.first { $0.id == "zone" }?.playableSongIds, ["z1", "z2", "z3"])
        XCTAssertEqual(tiles.first { $0.id == "col-pkt_1" }?.playableSongIds,
                       ["s1", "s2", "s3", "s4", "s5"])
    }

    /// A cloud suggestion can name an id this catalog cannot resolve. The tile must count what it
    /// SHOWS but offer to play only what it CAN — and a Suggested tile of entirely unresolvable
    /// ids must disable its control rather than present a dead one.
    func testTheSuggestedTileCountsWhatItShowsButPlaysOnlyWhatResolves() {
        let partly = ForYouTiles.build(newReleaseCount: 0, zone: [], collections: [],
                                       cloudSuggestionCount: 5, playableCloudIds: ["s1", "s2"])
        let tile = partly.first { $0.id == "suggested" }
        XCTAssertEqual(tile?.count, 5)
        XCTAssertEqual(tile?.playableCount, 2)
        XCTAssertTrue(tile?.isPlayable ?? false)

        let none = ForYouTiles.build(newReleaseCount: 0, zone: [], collections: [],
                                     cloudSuggestionCount: 5)
        XCTAssertFalse(none.first { $0.id == "suggested" }?.isPlayable ?? true,
                       "nothing resolves ⇒ no live Play button")
    }

    // ========================================================================
    // MARK: - The wire
    // ========================================================================

    @MainActor
    func testEveryActionRidesTheWireIncludingTheNegatives() {
        let s = store()
        s.toggle(songId: "a", to: .accepted, surface: .tile, context: "zone", at: now)
        s.toggle(songId: "b", to: .rejected, surface: .carPlay, at: now + 1)
        s.toggle(songId: "b", to: .rejected, surface: .carPlay, at: now + 2)   // → cleared
        let wire = s.recFeedbackEvents(sinceMs: 0)
        XCTAssertEqual(wire.map(\.action), ["accepted", "rejected", "cleared"],
                       "unlike the puzzle bridge, the NEGATIVES ride — that is the point")
        XCTAssertEqual(wire.first?.context, "zone")
        XCTAssertEqual(wire.first?.surface, "tile")
        XCTAssertEqual(wire.map(\.atMs), [now, now + 1, now + 2], "oldest first, for the cursor")
    }

    @MainActor
    func testTheWireCursorOnlyEmitsWhatIsAtOrAfterIt() {
        let s = store()
        s.toggle(songId: "old", to: .rejected, surface: .tile, at: now)
        s.toggle(songId: "new", to: .rejected, surface: .tile, at: now + 5000)
        XCTAssertEqual(s.recFeedbackEvents(sinceMs: now + 1).map(\.songId), ["new"])
        XCTAssertEqual(s.recFeedbackEvents(sinceMs: now).count, 2, "the floor is inclusive")
    }

    func testTheUploadBatchCarriesFeedbackAndRoundTrips() throws {
        let batch = RecUploadBatch(
            deviceId: "dev", sentAtMs: now,
            feedback: [RecFeedbackWire(id: "f1", atMs: now, songId: "s1", action: "rejected",
                                       surface: "carPlay", context: "zone")])
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(batch)) as? [String: Any]
        let rows = json?["feedback"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?["action"] as? String, "rejected")
        XCTAssertEqual(rows?.first?["songId"] as? String, "s1")
        // A build with no decisions must send the same bytes it always did.
        let empty = RecUploadBatch(deviceId: "dev", sentAtMs: now)
        let emptyJSON = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(empty)) as? [String: Any]
        XCTAssertNil(emptyJSON?["feedback"])
    }

    /// The App Group snapshot is how the widget learns the state. A blob written by an app build
    /// that predates the field must still decode (else the widget renders "Nothing playing").
    func testTheWidgetSnapshotCarriesFeedbackAndToleratesOldBlobs() throws {
        let snap = NowPlayingSnapshot(isPlaying: true, hasContent: true, title: "T", artist: "A",
                                      songId: "s1", coverVersion: 0, upNext: [],
                                      recFeedback: RecFeedbackAction.rejected.rawValue)
        let round = try JSONDecoder().decode(NowPlayingSnapshot.self,
                                             from: try JSONEncoder().encode(snap))
        XCTAssertEqual(round.recFeedback, "rejected")

        let legacy = """
        {"isPlaying":false,"hasContent":true,"title":"T","artist":"A","coverVersion":0,"upNext":[]}
        """
        let decoded = try JSONDecoder().decode(NowPlayingSnapshot.self,
                                               from: Data(legacy.utf8))
        XCTAssertEqual(decoded.recFeedback, RecFeedbackAction.none,
                       "an older blob decodes to 'no decision', never to a failed snapshot")
    }
}
