import XCTest
@testable import PocketDJ

/// **NEVER SUGGEST A SONG THAT IS ALREADY IN THAT COLLECTION — UNDER EVERY ID FORM.**
///
/// Owner, verbatim: *"don't recommend songs that are already in that collection for adding to a
/// collection."* The obvious reading of that ("filter out the member ids") is the one that fails,
/// because a recording wears up to three ids here — the catalog `sng_`, the `_clean`/`_explicit`
/// variant, and the `amrec_<storeId>` ad-hoc capture — and a `Set<String>` of members treats them
/// as three different songs.
///
/// So every case below is a MEMBER expressed one way and a CANDIDATE expressed another. They are
/// not paranoia: the same duplicate-identity class already made one track play twice in this app.
final class RecMembershipTests: XCTestCase {

    // ========================================================================
    // MARK: - The identity rule itself
    // ========================================================================

    func testAPlainIdIsItsOwnIdentity() {
        XCTAssertEqual(RecMembership.identityKeys(songId: "sng_0123456789ab"), ["sng_0123456789ab"])
    }

    func testBothEditionsOfARecordingShareOneIdentity() {
        let clean = RecMembership.identityKeys(songId: "sng_0123456789ab_clean")
        let explicit = RecMembership.identityKeys(songId: "sng_0123456789ab_explicit")
        XCTAssertEqual(clean, ["sng_0123456789ab"])
        XCTAssertEqual(explicit, ["sng_0123456789ab"])
    }

    func testAnAdHocCaptureCarriesItsStoreIdAsAKey() {
        XCTAssertEqual(RecMembership.identityKeys(songId: "amrec_944459436"),
                       ["amrec_944459436", "am:944459436"])
    }

    func testACatalogSongsStoreIdIsAKeyToo() {
        // This is what joins the two sides: the catalog row and the ad-hoc capture agree on
        // `am:944459436` while sharing no other character.
        XCTAssertEqual(RecMembership.identityKeys(songId: "sng_0123456789ab",
                                                  appleMusicId: "944459436"),
                       ["sng_0123456789ab", "am:944459436"])
    }

    /// A JOIN KEY THAT MANY ROWS SHARE IS WORSE THAN NO JOIN AT ALL: it would fold a slice of the
    /// catalog into one identity and delete real suggestions. Placeholders must not participate.
    func testPlaceholderStoreIdsDoNotJoin() {
        for junk in ["", "0", "000", "0000", "abc", "12a4", "12"] {
            XCTAssertEqual(RecMembership.identityKeys(songId: "sng_0123456789ab",
                                                      appleMusicId: junk),
                           ["sng_0123456789ab"], "\(junk.isEmpty ? "<empty>" : junk) must not join")
        }
        XCTAssertNil(RecMembership.adHocStoreId("amrec_"))
        XCTAssertNil(RecMembership.adHocStoreId("amrec_not-a-number"))
        XCTAssertNil(RecMembership.adHocStoreId("sng_0123456789ab"))
    }

    func testMembershipMatchesAcrossIdForms() {
        let m = RecMembership(memberIds: ["sng_0123456789ab_clean", "amrec_944459436"])
        XCTAssertTrue(m.contains("sng_0123456789ab"), "the base of a variant member")
        XCTAssertTrue(m.contains("sng_0123456789ab_explicit"), "the sibling edition")
        XCTAssertTrue(m.contains("sng_ffffffffffff", appleMusicId: "944459436"),
                      "a catalog row that IS the ad-hoc capture")
        XCTAssertFalse(m.contains("sng_ffffffffffff"), "an unrelated song is still suggestible")
        XCTAssertFalse(m.contains("sng_ffffffffffff", appleMusicId: "111111111"))
    }

    /// The REVERSE direction of the ad-hoc join: the member is the catalog row, the candidate is
    /// the capture. Needs the caller's lookup, which is why the initializer takes one.
    func testACatalogMemberRecognisesItsOwnAdHocCapture() {
        let m = RecMembership(memberIds: ["sng_0123456789ab"],
                              appleMusicId: { $0 == "sng_0123456789ab" ? "944459436" : nil })
        XCTAssertTrue(m.contains("amrec_944459436"))
    }

    func testNoMembersFiltersNothing() {
        let m = RecMembership(memberIds: [])
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.excluding(["a", "b"]), ["a", "b"])
    }

    /// The READ-TIME half, in one line: the frozen list minus whoever has since been filed, in
    /// order. Order matters — this runs over a RANKING.
    func testExcludingKeepsOrderAndDropsOnlyMembers() {
        let m = RecMembership(memberIds: ["sng_0123456789ab_clean"])
        XCTAssertEqual(m.excluding(["sng_aaaaaaaaaaaa", "sng_0123456789ab", "sng_bbbbbbbbbbbb"]),
                       ["sng_aaaaaaaaaaaa", "sng_bbbbbbbbbbbb"])
    }

    // ========================================================================
    // MARK: - …and the guarantee where it is actually spent: the tile ranking
    // ========================================================================

    /// Two songs by the artist already in the crate, one of which IS the member wearing a
    /// different id. Both would otherwise score identically and both would be offered.
    private func pair(memberId: String, candidateId: String,
                      candidateAppleMusicId: String? = nil) -> [ZoneEngine.Track] {
        [ZoneEngine.Track(songId: memberId, artistKey: "artist0", artistName: "A0", genre: "rock"),
         ZoneEngine.Track(songId: candidateId, artistKey: "artist0", artistName: "A0",
                          genre: "rock", appleMusicId: candidateAppleMusicId),
         ZoneEngine.Track(songId: "sng_cccccccccccc", artistKey: "artist0", artistName: "A0",
                          genre: "rock")]
    }

    func testTheBaseOfAVariantMemberIsNeverSuggested() {
        let tracks = pair(memberId: "sng_0123456789ab_clean", candidateId: "sng_0123456789ab")
        let out = ZoneEngine.suggestions(memberSongIds: ["sng_0123456789ab_clean"],
                                         tracks: tracks, playCount: { _ in 1 })
        XCTAssertFalse(out.contains("sng_0123456789ab"),
                       "the clean rip is in the crate; the base recording is the same song")
        XCTAssertEqual(out, ["sng_cccccccccccc"], "the genuinely-absent song still gets the slot")
    }

    func testTheVariantOfAPlainMemberIsNeverSuggested() {
        let tracks = pair(memberId: "sng_0123456789ab", candidateId: "sng_0123456789ab_explicit")
        let out = ZoneEngine.suggestions(memberSongIds: ["sng_0123456789ab"],
                                         tracks: tracks, playCount: { _ in 1 })
        XCTAssertFalse(out.contains("sng_0123456789ab_explicit"))
        XCTAssertEqual(out, ["sng_cccccccccccc"])
    }

    /// THE CASE A STRING SET CANNOT SEE. The listener added the song through Discover before the
    /// indexer had ever seen it, so it sits in the crate as `amrec_944459436`; the nightly index
    /// later minted `sng_…` for the same recording, and the tile would offer it straight back.
    func testTheCatalogTwinOfAnAdHocMemberIsNeverSuggested() {
        let tracks = pair(memberId: "amrec_944459436", candidateId: "sng_0123456789ab",
                          candidateAppleMusicId: "944459436")
        let out = ZoneEngine.suggestions(memberSongIds: ["amrec_944459436"],
                                         tracks: tracks, playCount: { _ in 1 })
        XCTAssertFalse(out.contains("sng_0123456789ab"),
                       "same recording, two id spaces — still already in the collection")
        XCTAssertEqual(out, ["sng_cccccccccccc"])
    }

    /// The mirror image, and the reason the store id is validated: a DIFFERENT song that happens
    /// to carry a store id must still be offered.
    func testADifferentSongWithItsOwnStoreIdIsStillSuggested() {
        let tracks = pair(memberId: "amrec_944459436", candidateId: "sng_0123456789ab",
                          candidateAppleMusicId: "111222333")
        let out = ZoneEngine.suggestions(memberSongIds: ["amrec_944459436"],
                                         tracks: tracks, playCount: { _ in 1 })
        XCTAssertTrue(out.contains("sng_0123456789ab"))
    }

    /// The plain case has to keep working exactly as it did — this is the guarantee the shipped
    /// ranking already made, and the identity rule is an ADDITION to it, not a replacement.
    func testAnExactMemberIsStillNeverSuggested() {
        let tracks = pair(memberId: "sng_0123456789ab", candidateId: "sng_dddddddddddd")
        let out = ZoneEngine.suggestions(memberSongIds: ["sng_0123456789ab"],
                                         tracks: tracks, playCount: { _ in 1 })
        XCTAssertFalse(out.contains("sng_0123456789ab"))
        XCTAssertEqual(Set(out), ["sng_dddddddddddd", "sng_cccccccccccc"])
    }

    /// `suggestionsExplained` renders the SAME ranking with a reason attached, so the guarantee
    /// has to hold there too — it is a separate entry point, and a filter that only guards one of
    /// two doors is not a filter.
    func testTheExplainedRankingObeysTheSameRule() {
        let tracks = pair(memberId: "amrec_944459436", candidateId: "sng_0123456789ab",
                          candidateAppleMusicId: "944459436")
        let rows = ZoneEngine.suggestionsExplained(memberSongIds: ["amrec_944459436"],
                                                   tracks: tracks, playCount: { _ in 1 })
        XCTAssertFalse(rows.contains { $0.songId == "sng_0123456789ab" })
    }
}

/// **THE READ-TIME HALF**, driven through the real store.
///
/// The build-time filter above is necessary and NOT sufficient, and that is the whole reason this
/// second class exists. The suggestion lists are FROZEN — the owner's rule is that For You only
/// re-ranks on an explicit Refresh — while membership moves on every add, including the adds made
/// from those very lists. So a filter applied only when the ranking is built is already wrong by
/// the time he acts on it: the tile goes on counting a song he just filed, and goes on offering it
/// after a relaunch, until the next scheduled refresh.
///
/// Everything here therefore goes through `CollectionsStore.suggestionsExcludingMembers`, which is
/// what both the tile card (`ForYouTilesView.deriveTiles`) and the opened list
/// (`ForYouSongListView.build`) call — including the memo, whose invalidation is the part most
/// likely to be quietly wrong.
@MainActor
final class RecMembershipReadTimeTests: XCTestCase {

    /// A catalog where one recording is a CITIZEN TWICE: `amrec_944459436` (the Discover capture,
    /// injected into the catalog by `AppModel.withDiscoverAdds` exactly as it is here) and
    /// `sng_0123456789ab` (the indexed row the nightly crawl resolved to the same store id).
    private struct TwinLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON {
            try JSONDecoder().decode(IndexJSON.self, from: Data(Self.json.utf8))
        }

        /// Declared HERE, not on the enclosing class: that class is `@MainActor`, so a static on
        /// it is main-actor isolated and this `nonisolated` loader cannot read it (a warning
        /// today, an error under the Swift 6 language mode).
        static let json = """
        {
          "manifest": { "sourceName": "Twin Crate", "counts": { "albums": 1, "songs": 3 } },
          "albums": [
            { "id": "alb_t", "artist": "Twinner", "name": "Twins", "genre": "Electronic",
              "year": 2020, "country": "US",
              "trackList": ["amrec_944459436", "sng_0123456789ab", "sng_ffffffffffff"],
              "fileType": "mp3" }
          ],
          "songs": [
            { "id": "amrec_944459436", "albumId": "alb_t", "artist": "Twinner", "name": "Twin",
              "trackNumber": 1, "year": 2020, "length": 200000 },
            { "id": "sng_0123456789ab", "albumId": "alb_t", "artist": "Twinner", "name": "Twin",
              "trackNumber": 2, "year": 2020, "length": 200000, "appleMusicId": "944459436" },
            { "id": "sng_ffffffffffff", "albumId": "alb_t", "artist": "Freeman", "name": "Free",
              "trackNumber": 3, "year": 2020, "length": 180000 }
          ]
        }
        """
    }

    /// `CollectionsStore.app` is a WEAK ref, so the caller has to keep the `AppModel` alive —
    /// returned rather than dropped, or every membership lookup silently resolves against an empty
    /// catalog and each assertion below passes/fails for the wrong reason.
    private func makeStore() async -> (CollectionsStore, AppModel) {
        let app = AppModel(loader: TwinLoader())
        await app.loadIfNeeded()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-recmem-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app
        return (collections, app)
    }

    /// THE HEADLINE. The crate holds the song under its ad-hoc capture id; the frozen list offers
    /// the indexed twin. Nothing textual connects the two — only the store id does.
    func testTheIndexedTwinOfAnAdHocMemberIsDroppedAtReadTime() async {
        let (collections, app) = await makeStore()
        let pl = collections.createPlaylist("Crate")
        collections.addSong("amrec_944459436", toPlaylist: pl.id)
        XCTAssertEqual(collections.playableIdsForAnyCollection(pl.id), ["amrec_944459436"],
                       "the ad-hoc capture is a catalog citizen, so it resolves as a member")

        let frozen = ["sng_0123456789ab", "sng_ffffffffffff"]
        XCTAssertEqual(collections.suggestionsExcludingMembers(frozen, ofCollection: pl.id),
                       ["sng_ffffffffffff"],
                       "the twin is already in the crate; the other song is still an offer")
        withExtendedLifetime(app) {}
    }

    /// THE STALENESS THE MEMO COULD REINTRODUCE. A second add must be visible to the very next
    /// read — that is the entire point of filtering here instead of at build time, and a memo
    /// keyed on the wrong thing would silently give back yesterday's answer.
    func testAnAddIsVisibleToTheNEXTReadWithNoRefresh() async {
        let (collections, app) = await makeStore()
        let pl = collections.createPlaylist("Crate")
        let frozen = ["sng_0123456789ab", "sng_ffffffffffff"]

        XCTAssertEqual(collections.suggestionsExcludingMembers(frozen, ofCollection: pl.id), frozen,
                       "an empty crate filters nothing")
        collections.addSong("sng_ffffffffffff", toPlaylist: pl.id)
        XCTAssertEqual(collections.suggestionsExcludingMembers(frozen, ofCollection: pl.id),
                       ["sng_0123456789ab"], "the add lands immediately — no Refresh in between")
        collections.addSong("amrec_944459436", toPlaylist: pl.id)
        XCTAssertEqual(collections.suggestionsExcludingMembers(frozen, ofCollection: pl.id), [],
                       "…and so does the second one, twin id and all")
        withExtendedLifetime(app) {}
    }

    /// A tile for a collection that has since been deleted must not start filtering against
    /// nothing-in-particular, and must not trap.
    func testAnUnknownCollectionFiltersNothing() async {
        let (collections, app) = await makeStore()
        XCTAssertEqual(collections.suggestionsExcludingMembers(["sng_ffffffffffff"],
                                                               ofCollection: "pls_gone"),
                       ["sng_ffffffffffff"])
        withExtendedLifetime(app) {}
    }
}
