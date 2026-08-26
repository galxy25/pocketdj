import XCTest
@testable import PocketDJ

/// **ONE RECORDING CAN NEVER APPEAR TWICE IN A RECOMMENDATION LIST.**
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
/// Every test below fails on the pre-fix engine — the duplicate is emitted, or the twin that
/// survives is the one that cannot be streamed. The NEGATIVE cases are just as load-bearing:
/// merging a remix into its original, or two artists' songs that share a title, would delete real
/// music from the feed with no trace.
final class RecRecordingIdentityTests: XCTestCase {

    // ========================================================================
    // MARK: - Fixtures
    // ========================================================================

    private func track(_ id: String, artist: String, title: String, genre: String? = "Soul",
                       year: Int? = 1968, appleMusicId: String? = nil) -> ZoneEngine.Track {
        ZoneEngine.Track(songId: id, artistKey: artist, artistName: artist, genre: genre,
                         year: year, appleMusicId: appleMusicId, title: title)
    }

    /// `IndexSong` is Decodable-only — build via the JSON round-trip (the house pattern).
    private func song(_ id: String, artist: String, name: String,
                      appleMusicId: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": name, "artist": artist, "year": 2000]
        if let appleMusicId { obj["appleMusicId"] = appleMusicId }
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

    func testIdentityUnionsTheIdFormsAndTheText() {
        // A variant id folds onto its base.
        XCTAssertTrue(RecRecordingIdentity.identityKeys(songId: "sng_0123456789ab_clean")
            .contains("sng_0123456789ab"))
        // An ad-hoc capture carries its store id in the NAME; the indexed row carries the same
        // number in a field. Nothing textual relates the two strings.
        let adHoc = Set(RecRecordingIdentity.identityKeys(songId: "amrec_944459436"))
        let indexed = Set(RecRecordingIdentity.identityKeys(songId: "sng_0123456789ab",
                                                            appleMusicId: "944459436"))
        XCTAssertFalse(adHoc.isDisjoint(with: indexed))
        // A placeholder store id is not a join — it would fold a slice of the catalog into one row.
        for junk in ["0", "", "000", "unknown", "12a4"] {
            XCTAssertEqual(RecRecordingIdentity.identityKeys(songId: "sng_0123456789ab",
                                                             appleMusicId: junk),
                           ["sng_0123456789ab"], "\(junk) must not join anything")
        }
    }

    /// A dictionary of "first key wins" would leave A and B in different groups and emit both.
    /// Only a union-find sees that C joins them.
    func testTheCollapseIsTransitiveAcrossDIFFERENTKINDSOfKey() {
        let a = RecRecordingIdentity.Candidate(id: "sng_aaaaaaaaaaaa", keys: ["sng_aaaaaaaaaaaa"],
                                               score: 3)
        let b = RecRecordingIdentity.Candidate(id: "sng_bbbbbbbbbbbb",
                                               keys: ["sng_bbbbbbbbbbbb", "rec:x"], score: 2)
        let c = RecRecordingIdentity.Candidate(id: "sng_cccccccccccc",
                                               keys: ["sng_aaaaaaaaaaaa", "rec:x"], score: 1)
        XCTAssertEqual(RecRecordingIdentity.keepMask([a, b, c]), [true, false, false])
    }

    /// Twins score IDENTICALLY (same artist, genre, year, and — through the timbre alias map —
    /// the same vector), so the survivor is decided by the tiebreaks, and the playable one has to
    /// win. On the reported pair the UNPLAYABLE id sorts first alphabetically.
    func testThePlayableTwinWinsAndTheRestIsDeterministic() {
        let placeholder = RecRecordingIdentity.Candidate(id: "sng_a71062b72c9f", keys: ["rec:fayah"],
                                                         score: 5, playable: false)
        let real = RecRecordingIdentity.Candidate(id: "sng_e3ac16340485", keys: ["rec:fayah"],
                                                  score: 5, playable: true)
        XCTAssertEqual(RecRecordingIdentity.keepMask([placeholder, real]), [false, true],
                       "a placeholder id must never win over a playable twin")
        XCTAssertEqual(RecRecordingIdentity.keepMask([real, placeholder]), [true, false],
                       "…and the answer does not depend on input order")

        // Equally playable ⇒ the highest score, then the lower id. Never the input order.
        let lo = RecRecordingIdentity.Candidate(id: "sng_zzzzzzzzzzzz", keys: ["rec:z"], score: 9)
        let hi = RecRecordingIdentity.Candidate(id: "sng_aaaaaaaaaaaa", keys: ["rec:z"], score: 1)
        XCTAssertEqual(RecRecordingIdentity.keepMask([hi, lo]), [false, true],
                       "the highest-scoring instance survives")
        let tieA = RecRecordingIdentity.Candidate(id: "sng_aaaaaaaaaaaa", keys: ["rec:t"], score: 1)
        let tieB = RecRecordingIdentity.Candidate(id: "sng_bbbbbbbbbbbb", keys: ["rec:t"], score: 1)
        XCTAssertEqual(RecRecordingIdentity.keepMask([tieB, tieA]), [false, true],
                       "a dead tie breaks on the id, so the list is stable between renders")
    }

    // ========================================================================
    // MARK: - Collection suggestions (THE REPORTED SURFACE)
    // ========================================================================

    /// THE HEADLINE, reproduced: two ordinary catalog ids, one recording, one crate.
    func testTwoCatalogRowsForOneRecordingCollapseToOneRow() {
        let tracks = [member,
                      track("sng_b2b93d195abd", artist: "Soul Survivors",
                            title: "Expressway To Your Heart"),
                      track("sng_de45662d7375", artist: "Soul Survivors",
                            title: "Expressway To Your Heart"),
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
                      track("sng_a71062b72c9f", artist: "Rotimi", title: "Fayah (feat. Alpha P)"),
                      track("sng_e3ac16340485", artist: "Rotimi", title: "Fayah (feat. Alpha P)",
                            appleMusicId: "1583155083")]
        let out = suggestions(tracks, members: ["sng_000000000000"])
        XCTAssertTrue(out.contains("sng_e3ac16340485"), "the streamable row survives — got \(out)")
        XCTAssertFalse(out.contains("sng_a71062b72c9f"), "the placeholder twin does not")
    }

    /// The EDITION id form: a clean/explicit rip is a distinct S3 object and so needs its own id.
    /// It is still one recording.
    func testAVariantIdCollapsesOntoItsBaseRow() {
        let tracks = [member,
                      track("sng_0123456789ab", artist: "Soul Survivors", title: "Expressway"),
                      track("sng_0123456789ab_clean", artist: "Soul Survivors",
                            title: "Expressway (Clean)")]
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
                            title: "Expressway To Your Heart", appleMusicId: "944459436")]
        let out = suggestions(tracks, members: ["sng_000000000000"])
        XCTAssertEqual(out.count, 1, "one recording, one row — got \(out)")
        XCTAssertEqual(out, ["sng_111111111111"], "and the indexed, streamable row is the survivor")
    }

    /// **THE NEGATIVE TEST.** Similar titles are not the same recording, and a rec list that
    /// silently deletes the extended mix is a worse bug than the one being fixed.
    func testGenuinelyDifferentSongsAreNEVERMerged() {
        let tracks = [member,
                      track("sng_100000000000", artist: "New Order", title: "Blue Monday"),
                      track("sng_200000000000", artist: "New Order",
                            title: "Blue Monday (Extended Mix)"),
                      track("sng_300000000000", artist: "New Order", title: "Blue Monday (Live)"),
                      track("sng_400000000000", artist: "Artist One", title: "Rewind"),
                      track("sng_500000000000", artist: "Artist Two", title: "Rewind")]
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
                      track("sng_100000000000", artist: "New Order", title: "Blue Monday"),
                      track("sng_200000000000", artist: "New Order",
                            title: "Blue Monday (2019 Remaster)")]
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
                            title: "Expressway To Your Heart"),
                      track("sng_de45662d7375", artist: "Soul Survivors",
                            title: "Expressway To Your Heart"),
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
    private func zoneCatalog() -> [IndexSong] {
        var out = [song("aaa-twin-1", artist: "Twin Band", name: "Twin Tune"),
                   song("aaa-twin-2", artist: "Twin Band", name: "Twin Tune",
                        appleMusicId: "1583155083")]
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
