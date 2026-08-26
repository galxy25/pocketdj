import XCTest
@testable import PocketDJ

/// **ONE RECORDING CAN NEVER APPEAR TWICE IN A RECOMMENDATION LIST — AND TWO RECORDINGS CAN NEVER
/// BE FUSED INTO ONE.**
///
/// The bug, verbatim from the report: in the "Showers" crate's suggestion list *"Expressway To
/// Your Heart" — Soul Survivors* appeared on TWO ADJACENT ROWS, and the two rows carried
/// DIFFERENT feedback state (one filled 👍, one not) — proof they were two distinct rows with
/// distinct ids naming one recording, not a view repeating one item. *"Fayah (feat. Alpha P)" —
/// Rotimi* did the same thing four rows down.
///
/// The engine had always de-duplicated candidate-vs-MEMBER (`RecMembership`, `RecVersionIndex`)
/// and NEVER candidate-vs-candidate. These tests are the other question, asked at every surface
/// that can produce a list: the collection tiles, In Da Zone on device, In Da Zone shaped from the
/// cloud, and the read-time membership filter.
///
/// The NEGATIVE cases are the more important half and they are drawn from REAL ROWS OF THE
/// OWNER'S CATALOG (`public/apple-music-index.json`, 96,383 rows), because the false merges are
/// not hypothetical: 321 Apple Music store ids in that file are shared by rows the title matcher
/// says are different recordings, and 366 duplicate groups hold rows whose durations differ by
/// more than 15 seconds. A merge that deletes the instrumental, the dub remix or the Unplugged
/// take is a worse bug than the one being fixed — it removes music from the feed and leaves no
/// trace — so every one of those shapes has a test with its real ids, titles and lengths in it.
final class RecRecordingIdentityTests: XCTestCase {

    // ========================================================================
    // MARK: - Fixtures
    // ========================================================================

    private func track(_ id: String, artist: String, title: String, genre: String? = "Soul",
                       year: Int? = 1968, appleMusicId: String? = nil,
                       lengthMs: Int? = nil) -> ZoneEngine.Track {
        ZoneEngine.Track(songId: id, artistKey: artist, artistName: artist, genre: genre,
                         year: year, appleMusicId: appleMusicId, title: title, lengthMs: lengthMs)
    }

    /// `IndexSong` is Decodable-only — build via the JSON round-trip (the house pattern).
    private func song(_ id: String, artist: String, name: String,
                      appleMusicId: String? = nil, lengthMs: Int? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": name, "artist": artist, "year": 2000]
        if let appleMusicId { obj["appleMusicId"] = appleMusicId }
        if let lengthMs { obj["length"] = lengthMs }
        return try! JSONDecoder().decode(IndexSong.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func suggestions(_ tracks: [ZoneEngine.Track],
                             members: [String]) -> [String] {
        ZoneEngine.suggestions(memberSongIds: members, tracks: tracks, playCount: { _ in 0 })
    }

    /// The crate every case below is drawn against: one member, so the candidates are admitted on
    /// genre (and, where the artist matches, on artist too).
    private var member: ZoneEngine.Track {
        track("sng_000000000000", artist: "Member Band", title: "Member Tune")
    }

    private func identity(_ id: String, appleMusicId: String? = nil, title: String? = nil,
                          artist: String = "Some Band",
                          lengthMs: Int? = nil) -> RecRecordingIdentity.Identity {
        RecRecordingIdentity.identity(
            songId: id, appleMusicId: appleMusicId,
            version: title.flatMap { RecVersionIdentity.key(title: $0, artist: artist) },
            lengthMs: lengthMs)
    }

    // ========================================================================
    // MARK: - The identity itself
    // ========================================================================

    func testTheRecordingKeyDropsCosmeticEditionMaterialAndCredits() {
        func key(_ title: String, _ artist: String) -> String? {
            RecRecordingIdentity.recordingKey(RecVersionIdentity.key(title: title, artist: artist))
        }
        let plain = key("Fayah", "Rotimi")
        XCTAssertNotNil(plain)
        XCTAssertEqual(key("Fayah (feat. Alpha P)", "Rotimi"), plain,
                       "a feat. credit is a CREDIT, not a different recording")
        XCTAssertEqual(key("FAYAH  (Remastered)", "rotimi"), plain,
                       "case, spacing and a packaging label are all cosmetic")
        XCTAssertEqual(key("Fayah (2019 Remaster) [Deluxe Edition]", "Rotimi"), plain,
                       "stacked edition labels are one record with two stickers")
    }

    /// THE NEGATIVE HALF. Anything that changes the RECORDING keeps its own identity.
    func testTheRecordingKeyKeepsRecordingAlteringMaterialApart() {
        func key(_ title: String, _ artist: String) -> String? {
            RecRecordingIdentity.recordingKey(RecVersionIdentity.key(title: title, artist: artist))
        }
        let plain = key("Blue Monday", "New Order")
        XCTAssertNotNil(plain)
        XCTAssertNotEqual(key("Blue Monday (Extended Mix)", "New Order"), plain, "a reworking")
        XCTAssertNotEqual(key("Blue Monday (Live)", "New Order"), plain, "a performance")
        XCTAssertNotEqual(key("Blue Monday (Radio Edit)", "New Order"), plain, "an edit")
        XCTAssertNotEqual(key("Blue Monday", "Orgy"), plain, "another artist's record entirely")
        XCTAssertEqual(key("Blue Monday (Live)", "New Order"), key("Blue Monday [live]", "New Order"),
                       "…but two catalog rows of the SAME live take are still one recording")
    }

    func testIdentityCarriesTheIdFormsTheTextAndTheCorroborator() {
        // A variant id folds onto its base — the STRONG key, which fuses on sight.
        XCTAssertEqual(identity("sng_0123456789ab_clean").baseId, "sng_0123456789ab")
        // An ad-hoc capture carries its store id in the NAME; the indexed row carries the same
        // number in a field. Nothing textual relates the two strings.
        let adHoc = Set(identity("amrec_944459436").storeKeys)
        let indexed = Set(identity("sng_0123456789ab", appleMusicId: "944459436").storeKeys)
        XCTAssertFalse(adHoc.isEmpty)
        XCTAssertFalse(adHoc.isDisjoint(with: indexed))
        // A placeholder store id is not a join — it would fold a slice of the catalog into one row.
        for junk in ["0", "", "000", "unknown", "12a4"] {
            XCTAssertEqual(identity("sng_0123456789ab", appleMusicId: junk).storeKeys, [],
                           "\(junk) must not join anything")
        }
        // A length of 0 is "unknown", never "zero seconds" — it must not corroborate anything.
        XCTAssertNil(identity("sng_0123456789ab", lengthMs: 0).lengthMs)
        XCTAssertEqual(identity("sng_0123456789ab", lengthMs: 187_105).lengthMs, 187_105)
    }

    /// A dictionary of "first key wins" would leave A and B in different groups and emit both.
    /// Only a union-find sees that C joins them.
    func testTheCollapseIsTransitiveAcrossDIFFERENTKINDSOfKey() {
        let a = RecRecordingIdentity.Candidate(
            id: "sng_aaaaaaaaaaaa",
            identity: .init(baseId: "sng_aaaaaaaaaaaa"), score: 3)
        let b = RecRecordingIdentity.Candidate(
            id: "sng_bbbbbbbbbbbb",
            identity: .init(baseId: "sng_bbbbbbbbbbbb", recordingKey: "rec:x"), score: 2)
        let c = RecRecordingIdentity.Candidate(
            id: "sng_aaaaaaaaaaaa_clean",
            identity: .init(baseId: "sng_aaaaaaaaaaaa", recordingKey: "rec:x"), score: 1)
        XCTAssertEqual(RecRecordingIdentity.keepMask([a, b, c]), [true, false, false])
    }

    /// Twins score IDENTICALLY (same artist, genre, year, and — through the timbre alias map —
    /// the same vector), so the survivor is decided by the tiebreaks, and the playable one has to
    /// win. On the reported pair the UNPLAYABLE id sorts first alphabetically.
    func testThePlayableTwinWinsAndTheRestIsDeterministic() {
        func twin(_ id: String, playable: Bool, score: Double = 5,
                  tier: Int = 0) -> RecRecordingIdentity.Candidate {
            RecRecordingIdentity.Candidate(id: id, identity: .init(baseId: id, recordingKey: "rec:fayah"),
                                           tier: tier, score: score, playable: playable)
        }
        let placeholder = twin("sng_a71062b72c9f", playable: false)
        let real = twin("sng_e3ac16340485", playable: true)
        XCTAssertEqual(RecRecordingIdentity.keepMask([placeholder, real]), [false, true],
                       "a placeholder id must never win over a playable twin")
        XCTAssertEqual(RecRecordingIdentity.keepMask([real, placeholder]), [true, false],
                       "…and the answer does not depend on input order")
        // The retired twin is the one with NO play history, so the dormancy term can score it
        // higher. Playability still decides inside a pool.
        XCTAssertEqual(RecRecordingIdentity.keepMask([twin("sng_a71062b72c9f", playable: false, score: 9),
                                                      twin("sng_e3ac16340485", playable: true, score: 5)]),
                       [false, true], "a higher score cannot rescue a row that cannot be streamed")

        // Equally playable ⇒ the highest score, then the lower id. Never the input order.
        let lo = RecRecordingIdentity.Candidate(id: "sng_zzzzzzzzzzzz",
                                                identity: .init(baseId: "sng_zzzzzzzzzzzz",
                                                                recordingKey: "rec:z"), score: 9)
        let hi = RecRecordingIdentity.Candidate(id: "sng_aaaaaaaaaaaa",
                                                identity: .init(baseId: "sng_aaaaaaaaaaaa",
                                                                recordingKey: "rec:z"), score: 1)
        XCTAssertEqual(RecRecordingIdentity.keepMask([hi, lo]), [false, true],
                       "the highest-scoring instance survives")
        let tieA = RecRecordingIdentity.Candidate(id: "sng_aaaaaaaaaaaa",
                                                  identity: .init(baseId: "sng_aaaaaaaaaaaa",
                                                                  recordingKey: "rec:t"), score: 1)
        let tieB = RecRecordingIdentity.Candidate(id: "sng_bbbbbbbbbbbb",
                                                  identity: .init(baseId: "sng_bbbbbbbbbbbb",
                                                                  recordingKey: "rec:t"), score: 1)
        XCTAssertEqual(RecRecordingIdentity.keepMask([tieB, tieA]), [false, true],
                       "a dead tie breaks on the id, so the list is stable between renders")
    }

    /// **THE POOL OUTRANKS EVERYTHING.** A song he has actually been playing lands in In Da Zone's
    /// FAMILIAR pool; its catalog twin can be sitting in the last-resort FALLBACK pool, which is
    /// ranked on `auxOnly` alone. Letting the fallback row win would delete the played row and
    /// then render the survivor with the "Buried" badge — for a song he played yesterday.
    func testTheHIGHERPOOLWinsBeforePlayabilityOrScore() {
        let familiarLocalRip = RecRecordingIdentity.Candidate(
            id: "sng_ffffffffffff", identity: .init(baseId: "sng_ffffffffffff", recordingKey: "rec:p"),
            tier: 2, score: 0.1, playable: false)
        let fallbackStreamable = RecRecordingIdentity.Candidate(
            id: "sng_000000000001", identity: .init(baseId: "sng_000000000001", recordingKey: "rec:p"),
            tier: 0, score: 99, playable: true)
        XCTAssertEqual(RecRecordingIdentity.keepMask([familiarLocalRip, fallbackStreamable]),
                       [true, false],
                       "the pool decides first — a familiar row is not replaced by a fallback twin")
    }

    // ========================================================================
    // MARK: - THE CORROBORATORS (the false-merge guards)
    // ========================================================================

    /// **A SHARED STORE ID IS NOT PROOF OF ONE RECORDING.** `IndexSong.appleMusicId` is RESOLVED
    /// through the iTunes Search API, so two library rows genuinely land on one catalog id — 321
    /// such ids on the owner's real catalog, 711 rows. Every row below is his, verbatim.
    func testAStoreIdSharedByTWODifferentRecordingsNeverFusesThem() {
        func mask(_ rows: [(id: String, title: String, artist: String, ms: Int)],
                  store: String) -> [Bool] {
            RecRecordingIdentity.keepMask(rows.map {
                RecRecordingIdentity.Candidate(
                    id: $0.id,
                    identity: identity($0.id, appleMusicId: store, title: $0.title,
                                       artist: $0.artist, lengthMs: $0.ms),
                    playable: true)
            })
        }
        // am 1514890553 — the instrumental would have been deleted.
        XCTAssertEqual(mask([("sng_toro1", "Minors", "Toro y Moi", 182_520),
                             ("sng_toro2", "Minors (Instrumental)", "Toro y Moi", 185_703)],
                            store: "1514890553"),
                       [true, true], "an instrumental cut is its own recording")
        // am 1709423956 — the dub remix would have been deleted.
        XCTAssertEqual(mask([("sng_tour1", "I Can't Keep Up (feat. Will Heard)", "Tourist", 271_273),
                             ("sng_tour2", "I Can't Keep up - Dub Remix (feat. Will Heard)",
                              "Tourist", 285_692)],
                            store: "1709423956"),
                       [true, true], "a dub remix is its own recording")
        // am 1488014200 — two ENTIRELY DIFFERENT SONGS resolved onto one store id.
        XCTAssertEqual(mask([("sng_bf1", "Soon Az I Get Home", "Brent Faiyaz", 94_737),
                             ("sng_bf2", "Home", "Brent Faiyaz", 111_031)],
                            store: "1488014200"),
                       [true, true], "different titles are different songs, store id or not")
    }

    /// …but the store id still does the job it was written for: the `amrec_` capture and the
    /// indexed row that supersedes it share nothing but a number, and neither contradicts the
    /// other.
    func testAStoreIdStillFusesTheAdHocCaptureOntoTheIndexedRow() {
        // The capture carries no `appleMusicId` FIELD (its store id is in the id itself), so the
        // ranking cannot call it streamable — which is why the indexed row wins the tiebreak.
        let capture = RecRecordingIdentity.Candidate(
            id: "amrec_944459436", identity: identity("amrec_944459436"), playable: false)
        let indexed = RecRecordingIdentity.Candidate(
            id: "sng_111111111111",
            identity: identity("sng_111111111111", appleMusicId: "944459436",
                               title: "Expressway To Your Heart", artist: "Soul Survivors",
                               lengthMs: 140_044),
            playable: true)
        XCTAssertEqual(RecRecordingIdentity.keepMask([capture, indexed]), [false, true],
                       "one recording, one row — and the indexed row is the survivor")
    }

    /// **AN UNLABELLED LIVE TAKE IS NOT THE STUDIO CUT.** The recording key only protects a
    /// version marker that is actually PRINTED, and live albums routinely print none — so
    /// `MTV Unplugged: Jay-Z` collides with `The Blueprint` on artist + title alone. The lengths
    /// are what tell them apart, and both rows are real ones of his.
    func testAnUnlabelledLiveTakeIsNotFusedIntoTheStudioCut() {
        let tracks = [member,
                      track("sng_ddddddddddd1", artist: "JAY-Z", title: "Takeover",
                            appleMusicId: "1440933875", lengthMs: 313_000),
                      track("sng_ddddddddddd2", artist: "JAY-Z", title: "Takeover",
                            appleMusicId: "1444018732", lengthMs: 297_000),
                      // Daft Punk "Aerodynamic": 3:29 on Discovery, 6:10 on Daft Club.
                      track("sng_ddddddddddd3", artist: "Daft Punk", title: "Aerodynamic",
                            lengthMs: 209_371),
                      track("sng_ddddddddddd4", artist: "Daft Punk", title: "Aerodynamic",
                            lengthMs: 370_024)]
        let out = Set(suggestions(tracks, members: ["sng_000000000000"]))
        for id in ["sng_ddddddddddd1", "sng_ddddddddddd2", "sng_ddddddddddd3", "sng_ddddddddddd4"] {
            XCTAssertTrue(out.contains(id),
                          "\(id) is a different performance and must survive — got \(out)")
        }
    }

    /// The other side of the same rule: master-to-master drift is NOT a different recording, and a
    /// missing length is not evidence of anything. Both reported pairs land here — 140044 vs
    /// 140044 ms and 187105 vs 187104 ms.
    func testATinyLengthDifferenceStillCollapses() {
        func pair(_ a: Int?, _ b: Int?) -> [Bool] {
            RecRecordingIdentity.keepMask([
                RecRecordingIdentity.Candidate(
                    id: "sng_aaaaaaaaaaaa",
                    identity: identity("sng_aaaaaaaaaaaa", title: "Expressway To Your Heart",
                                       artist: "Soul Survivors", lengthMs: a)),
                RecRecordingIdentity.Candidate(
                    id: "sng_bbbbbbbbbbbb",
                    identity: identity("sng_bbbbbbbbbbbb", title: "Expressway To Your Heart",
                                       artist: "Soul Survivors", lengthMs: b))])
        }
        XCTAssertEqual(pair(140_044, 140_044), [true, false], "the reported pair, to the millisecond")
        XCTAssertEqual(pair(187_105, 187_104), [true, false], "…and the other one")
        XCTAssertEqual(pair(251_400, 255_875), [true, false],
                       "4.5 s apart is one recording, two masters (Lou Reed, his catalog)")
        XCTAssertEqual(pair(140_044, nil), [true, false], "an unknown length blocks nothing")
        XCTAssertEqual(pair(nil, nil), [true, false], "…and neither does two of them")
        XCTAssertEqual(pair(313_000, 297_000), [true, true], "16 s apart is two performances")
    }

    /// A refused fusion may not be walked around through a third row: the group carries the whole
    /// range of lengths it has absorbed, and the next candidate is tested against that range.
    func testARefusedFusionCannotBeReachedTransitively() {
        func row(_ id: String, _ ms: Int) -> RecRecordingIdentity.Candidate {
            RecRecordingIdentity.Candidate(
                id: id, identity: identity(id, title: "Takeover", artist: "JAY-Z", lengthMs: ms))
        }
        // 297 s and 300 s fuse; 313 s is inside 5 s of neither once they have.
        XCTAssertEqual(RecRecordingIdentity.keepMask([row("sng_1", 297_000), row("sng_2", 300_000),
                                                      row("sng_3", 313_000)]),
                       [true, false, true])
    }

    // ========================================================================
    // MARK: - Collection suggestions (THE REPORTED SURFACE)
    // ========================================================================

    /// THE HEADLINE, reproduced: two ordinary catalog ids, one recording, one crate. Both rows are
    /// his, including their (identical) lengths.
    func testTwoCatalogRowsForOneRecordingCollapseToOneRow() {
        let tracks = [member,
                      track("sng_b2b93d195abd", artist: "Soul Survivors",
                            title: "Expressway To Your Heart", lengthMs: 140_044),
                      track("sng_de45662d7375", artist: "Soul Survivors",
                            title: "Expressway To Your Heart", lengthMs: 140_044),
                      track("sng_ccccccccccc1", artist: "Other Band", title: "Something Else")]
        let out = suggestions(tracks, members: ["sng_000000000000"])
        XCTAssertEqual(out.filter { $0.hasPrefix("sng_b2b") || $0.hasPrefix("sng_de4") }.count, 1,
                       "one recording, one row — got \(out)")
        XCTAssertTrue(out.contains("sng_ccccccccccc1"), "and the slot budget is unharmed")
    }

    /// The reported pair's OTHER half: the twins differ only in that one of them was never
    /// resolved to an Apple Music store id. That row cannot be streamed, and it sorts FIRST.
    func testThePlayableTwinIsTheOneThatSurvivesTheCollapse() {
        let tracks = [member,
                      track("sng_a71062b72c9f", artist: "Rotimi", title: "Fayah (feat. Alpha P)",
                            lengthMs: 187_104),
                      track("sng_e3ac16340485", artist: "Rotimi", title: "Fayah (feat. Alpha P)",
                            appleMusicId: "1583155083", lengthMs: 187_105)]
        let out = suggestions(tracks, members: ["sng_000000000000"])
        XCTAssertTrue(out.contains("sng_e3ac16340485"), "the streamable row survives — got \(out)")
        XCTAssertFalse(out.contains("sng_a71062b72c9f"), "the placeholder twin does not")
    }

    /// The EDITION id form: a clean/explicit rip is a distinct S3 object and so needs its own id.
    /// It is still one recording — and it is the STRONG key, so it fuses with no corroboration
    /// (the two rows can carry different lengths and different titles).
    func testAVariantIdCollapsesOntoItsBaseRow() {
        let tracks = [member,
                      track("sng_0123456789ab", artist: "Soul Survivors", title: "Expressway",
                            lengthMs: 140_044),
                      track("sng_0123456789ab_clean", artist: "Soul Survivors",
                            title: "Expressway (Clean)", lengthMs: 139_500)]
        let out = suggestions(tracks, members: ["sng_000000000000"])
        XCTAssertEqual(out.filter { $0.hasPrefix("sng_0123456789ab") }.count, 1,
                       "the variant and its base are one recording — got \(out)")
    }

    /// The DISCOVER id form: an `amrec_` capture and the indexed row that supersedes it share
    /// nothing but a number, and here they do not even share a title.
    func testAnAdHocDiscoverTwinCollapsesOntoTheIndexedRow() {
        let tracks = [member,
                      track("amrec_944459436", artist: "Soul Survivors", title: "Expressway"),
                      track("sng_111111111111", artist: "Soul Survivors",
                            title: "Expressway To Your Heart", appleMusicId: "944459436",
                            lengthMs: 140_044)]
        let out = suggestions(tracks, members: ["sng_000000000000"])
        XCTAssertEqual(out.count, 1, "one recording, one row — got \(out)")
        XCTAssertEqual(out, ["sng_111111111111"], "and the indexed, streamable row is the survivor")
    }

    /// **THE NEGATIVE TEST.** Similar titles are not the same recording, and a rec list that
    /// silently deletes the extended mix is a worse bug than the one being fixed.
    ///
    /// Every row here carries the SAME Apple Music store id, which is not a contrivance: it is the
    /// shape of 321 store ids on the owner's real catalog, and it is exactly how a collapse that
    /// trusted the store id blindly deleted three of these five rows.
    func testGenuinelyDifferentSongsAreNEVERMerged() {
        let store = "1514890553"
        let tracks = [member,
                      track("sng_100000000000", artist: "New Order", title: "Blue Monday",
                            appleMusicId: store, lengthMs: 448_000),
                      track("sng_200000000000", artist: "New Order",
                            title: "Blue Monday (Extended Mix)", appleMusicId: store,
                            lengthMs: 449_000),
                      track("sng_300000000000", artist: "New Order", title: "Blue Monday (Live)",
                            appleMusicId: store, lengthMs: 447_500),
                      track("sng_400000000000", artist: "Artist One", title: "Rewind",
                            appleMusicId: store, lengthMs: 200_000),
                      track("sng_500000000000", artist: "Artist Two", title: "Rewind",
                            appleMusicId: store, lengthMs: 200_000)]
        let out = Set(suggestions(tracks, members: ["sng_000000000000"]))
        for id in ["sng_100000000000", "sng_200000000000", "sng_300000000000",
                   "sng_400000000000", "sng_500000000000"] {
            XCTAssertTrue(out.contains(id), "\(id) is its own recording and must survive — got \(out)")
        }
    }

    /// The documented behaviour change beyond exact duplicates, pinned so it cannot drift: a
    /// remaster is the same recording in different packaging, and the crate shows it once.
    func testACosmeticReissueIsTheSameRecording() {
        let tracks = [member,
                      track("sng_100000000000", artist: "New Order", title: "Blue Monday",
                            lengthMs: 448_000),
                      track("sng_200000000000", artist: "New Order",
                            title: "Blue Monday (2019 Remaster)", lengthMs: 448_400)]
        XCTAssertEqual(suggestions(tracks, members: ["sng_000000000000"]).count, 1)
    }

    // ========================================================================
    // MARK: - "Already in this collection", under ANY id
    // ========================================================================

    /// The SECOND defect: the exclusion compared ids and editions, so a song owned under id A was
    /// still offered under id B. `RecVersionIndex.supersedes` is honest about refusing this pair —
    /// the two signatures are EQUAL, so it is not "a different version" — which is exactly why the
    /// ownership question needs the recording key too.
    func testASongOwnedUnderOneIdIsNotSuggestedUnderAnother() {
        let tracks = [track("sng_b2b93d195abd", artist: "Soul Survivors",
                            title: "Expressway To Your Heart", lengthMs: 140_044),
                      track("sng_de45662d7375", artist: "Soul Survivors",
                            title: "Expressway To Your Heart", lengthMs: 140_044),
                      track("sng_ccccccccccc1", artist: "Other Band", title: "Something Else")]
        let out = suggestions(tracks, members: ["sng_b2b93d195abd"])
        XCTAssertFalse(out.contains("sng_de45662d7375"),
                       "the crate already holds this recording — got \(out)")
        XCTAssertEqual(out, ["sng_ccccccccccc1"], "and the genuinely new song is still offered")
    }

    /// The READ-TIME half of the same rule (`RecMembership.excluding`, which every tile and every
    /// opened list calls). Membership moves on every add, including the adds made FROM these very
    /// lists, so the build-time filter is necessary and not sufficient.
    func testTheReadTimeMembershipFilterCatchesTheOtherId() {
        let owned = ("Expressway To Your Heart", "Soul Survivors")
        let m = RecMembership(memberIds: ["sng_b2b93d195abd"], titleArtist: { _ in owned })
        let text: [String: (title: String, artist: String)] = [
            "sng_de45662d7375": owned,
            "sng_cccccccccccc": ("Something Else", "Other Band"),
        ]
        XCTAssertEqual(m.excluding(["sng_de45662d7375", "sng_cccccccccccc"],
                                   titleArtist: { text[$0] }),
                       ["sng_cccccccccccc"])
    }

    // ========================================================================
    // MARK: - In Da Zone (device + cloud)
    // ========================================================================

    /// The zone's pools are separate lists, and a twin can land in a DIFFERENT pool from its
    /// sibling — so the collapse has to run across all of them at once.
    private func zoneCatalog(twinLengths: (Int, Int)? = nil) -> [IndexSong] {
        var out = [song("aaa-twin-1", artist: "Twin Band", name: "Twin Tune",
                        lengthMs: twinLengths?.0),
                   song("aaa-twin-2", artist: "Twin Band", name: "Twin Tune",
                        appleMusicId: "1583155083", lengthMs: twinLengths?.1)]
        for a in 0..<12 {
            for t in 0..<3 { out.append(song("b\(a)-t\(t)", artist: "Artist \(a)", name: "B\(a) T\(t)")) }
        }
        return out
    }

    func testInDaZoneEmitsOneRecordingOnce() {
        let songs = zoneCatalog()
        let q = ZoneEngine.inDaZone(songs: songs, plays: [], playCount: { _ in 0 },
                                    nowMs: 1_800_000_000_000)
        let twins = q.songIds.filter { $0.hasPrefix("aaa-twin") }
        XCTAssertEqual(twins, ["aaa-twin-2"],
                       "one recording, one row — and the streamable id is the one kept")
    }

    /// …and the zone applies the same corroborator the collection surface does: two rows of one
    /// artist+title that run four minutes apart are two recordings, and BOTH belong in the queue.
    func testInDaZoneKeepsTwoRecordingsThatMerelyShareATitle() {
        let songs = zoneCatalog(twinLengths: (209_371, 370_024))
        let q = ZoneEngine.inDaZone(songs: songs, plays: [], playCount: { _ in 0 },
                                    nowMs: 1_800_000_000_000)
        XCTAssertEqual(Set(q.songIds.filter { $0.hasPrefix("aaa-twin") }),
                       ["aaa-twin-1", "aaa-twin-2"], "got \(q.songIds)")
    }

    /// A SERVER LIST MUST NEVER BYPASS CLIENT FILTERING. The Lambda dedups on its own ids and
    /// cannot know that two of them name one recording in this install's catalog.
    func testACloudRankingIsCollapsedToo() {
        let songs = zoneCatalog()
        let q = ZoneEngine.shapeCloudRanking(songIds: songs.map(\.id), songs: songs,
                                             nowMs: 1_800_000_000_000)
        XCTAssertEqual(q.songIds.filter { $0.hasPrefix("aaa-twin") }, ["aaa-twin-2"])
    }
}

// ============================================================================
// MARK: - The poisoned cache
// ============================================================================

/// The lists are FROZEN and only recomputed on an explicit Refresh, so a correct engine is not
/// enough: the owner's cached feed was built by the old one and holds 81 duplicate rows across 54
/// crates. A snapshot from an older schema has to be retired, or the reported bug is still on
/// screen after the fix ships.
@MainActor
final class ForYouFeedSchemaGateTests: XCTestCase {

    private func write(_ schemaVersion: Int, to url: URL) {
        let json = """
        {"schemaVersion":\(schemaVersion),"refreshedAtMs":1700000000000,
         "zoneIds":["z1","z2"],"zoneBuriedIds":[],"crates":[]}
        """
        try! Data(json.utf8).write(to: url)
    }

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-foryou-schema-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAFeedFrozenByTheDuplicateEmittingEngineIsRetired() {
        let url = tempURL()
        write(1, to: url)
        let store = ForYouFeedStore(fileURL: url)
        XCTAssertFalse(store.snapshot.hasResult,
                       "an older-schema feed is NO CACHE, so the cold-cache branch rebuilds it")
        XCTAssertEqual(store.snapshot.zoneIds, [])
    }

    func testACurrentFeedStillLoadsFromDisk() {
        let url = tempURL()
        write(forYouFeedSchemaVersion, to: url)
        let store = ForYouFeedStore(fileURL: url)
        XCTAssertTrue(store.snapshot.hasResult)
        XCTAssertEqual(store.snapshot.zoneIds, ["z1", "z2"])
    }

    /// A peer still running the old engine must not push its duplicate-bearing ranking onto a
    /// device that has already been fixed — the sync is last-writer-wins over refresh recency, and
    /// "more recent" would otherwise beat "correct".
    func testAnOlderSchemaDocumentIsNotAcceptedFromCloudSync() {
        let url = tempURL()
        write(forYouFeedSchemaVersion, to: url)
        let store = ForYouFeedStore(fileURL: url)
        let stale = """
        {"schemaVersion":1,"refreshedAtMs":1900000000000,"zoneIds":["peer"],
         "zoneBuriedIds":[],"crates":[]}
        """
        store.applyPulledPayload(Data(stale.utf8))
        XCTAssertFalse(store.reloadFromDisk(), "a newer-but-older-schema peer document is refused")
        XCTAssertEqual(store.snapshot.zoneIds, ["z1", "z2"])
    }
}
