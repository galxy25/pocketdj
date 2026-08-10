import XCTest
@testable import PocketDJ

/// **FEATURE 6 — don't offer him a record he already has in a different version.**
///
/// Owner, verbatim: *"for collection and new recommendations don't recommend albums and songs we
/// already have but that are a different version (e.g. deluxe or bonus album version, remixes or
/// extended versions)."*
///
/// The cases here are the ones this actually turns on, and every one of them is a real title shape
/// from Apple's catalog rather than a made-up string:
///   · "(Deluxe Edition)" / "(Bonus Track Version)" / "(Expanded Edition)" — the SAME record.
///   · "(Extended Mix)" / "- Radio Edit" — a reworking of a recording he has.
///   · "(Live)" / "(Acoustic)" — a different PERFORMANCE, which is new music and must survive.
///   · a remix credited to the REMIXER — a different artist's record, which must survive.
///   · plain artist+title equality with no version material — deliberately NOT suppressed, so the
///     feature can never fire on a name collision alone.
final class RecVersionIdentityTests: XCTestCase {

    // ========================================================================
    // MARK: - Parsing
    // ========================================================================

    private func parse(_ t: String) -> (base: String, signature: String,
                                        klass: RecVersionIdentity.VersionClass) {
        RecVersionIdentity.parse(t)
    }

    func testAPlainTitleCarriesNoVersionMaterial() {
        let p = parse("Rumours")
        XCTAssertEqual(p.base, "rumours")
        XCTAssertEqual(p.signature, "")
        XCTAssertEqual(p.klass, .standard)
    }

    /// The headline album case. Every one of these is the same record with a different sticker.
    func testEditionLabelsAreCosmeticAndShareTheBaseTitle() {
        for label in ["Rumours (Deluxe Edition)",
                      "Rumours (Super Deluxe Edition)",
                      "Rumours (Bonus Track Version)",
                      "Rumours (Expanded Edition)",
                      "Rumours (Remastered)",
                      "Rumours (2011 Remaster)",
                      "Rumours (35th Anniversary Edition)",
                      "Rumours - 2011 Remaster",
                      "Rumours (Deluxe Edition) [Remastered]"] {
            let p = parse(label)
            XCTAssertEqual(p.base, "rumours", "\(label) should reduce to the same record")
            XCTAssertEqual(p.klass, .cosmetic, "\(label) is packaging, not a new recording")
            XCTAssertFalse(p.signature.isEmpty, "\(label) must still carry version material")
        }
    }

    /// The song case the owner named: remixes and extended versions.
    func testReworkingsAreDerivative() {
        for label in ["Blue Monday (Extended Mix)",
                      "Blue Monday (12\" Version)",
                      "Blue Monday - Radio Edit",
                      "Blue Monday (Club Mix)",
                      "Blue Monday (Hardfloor Remix)",
                      "Blue Monday (Dub)",
                      "Blue Monday - Single"] {
            let p = parse(label)
            XCTAssertEqual(p.base, "blue monday", "\(label) should reduce to the same recording")
            XCTAssertEqual(p.klass, .derivative, "\(label) is a reworking")
        }
    }

    /// The line that keeps this feature from deleting music. A different PERFORMANCE is not a
    /// different edition of the same tape.
    func testPerformancesAreDistinctAndNeverSuppressible() {
        for label in ["Blue Monday (Live)",
                      "Blue Monday (Acoustic)",
                      "Blue Monday (Unplugged)",
                      "Blue Monday (Instrumental)",
                      "Blue Monday (Demo)",
                      "Blue Monday (Karaoke Version)"] {
            XCTAssertEqual(parse(label).klass, .distinct, "\(label) is a different performance")
        }
    }

    /// THE SAFETY PROPERTY. A marker this file has never heard of must fail OPEN — the row is
    /// still offered — because over-suppression deletes music silently and leaves no trace, while
    /// under-suppression costs one thumbs-down.
    func testAnUnrecognisedMarkerFailsOpen() {
        XCTAssertEqual(parse("Red (Taylor's Version)").klass, .distinct)
        XCTAssertEqual(parse("Songs (The Rick Rubin Sessions)").klass, .distinct)
        XCTAssertFalse(RecVersionIdentity.isDifferentVersion(
            candidateTitle: "Red (Taylor's Version)", candidateArtist: "Taylor Swift",
            ownedTitle: "Red", ownedArtist: "Taylor Swift"),
                       "a re-recording is a different recording and stays")
    }

    /// am-match's special case, carried over verbatim: an "(Original Mix)" suffix is the standard
    /// recording, not a reworking of itself. Without it every house record suppresses its own row.
    func testOriginalMixIsTheStandardRecording() {
        XCTAssertEqual(parse("Strings of Life (Original Mix)").klass, .cosmetic)
    }

    /// A credit is not a version — am-match's rule, and it matters because "(feat. …)" is the most
    /// common parenthetical in the catalog by a wide margin.
    func testCreditsAreNotVersionMaterial() {
        let p = parse("Post To Be (feat. Chris Brown & Jhene Aiko)")
        XCTAssertEqual(p.base, "post to be")
        XCTAssertEqual(p.signature, "", "a credit carries no version information")
        XCTAssertEqual(p.klass, .standard)
        XCTAssertFalse(RecVersionIdentity.isDifferentVersion(
            candidateTitle: "Post To Be (feat. Chris Brown)", candidateArtist: "Omarion",
            ownedTitle: "Post To Be", ownedArtist: "Omarion"),
                       "a credit difference is not a different version")
    }

    /// A dash suffix is only taken as version material when EVERY token is classifiable. This is
    /// what stops "- Part Two" and "- Live at Wembley" from being eaten off the title.
    func testAnUnclassifiableDashSuffixStaysInTheTitle() {
        XCTAssertEqual(parse("Shine On You Crazy Diamond - Parts I-V").base,
                       "shine on you crazy diamond parts i v")
        XCTAssertEqual(parse("Song - Live at Wembley").base, "song live at wembley")
    }

    /// **FOUND BY RUNNING THE CLASSIFIER OVER THE REAL 96k CATALOG**, and the single worst thing
    /// it did before the fix: `Ultimate Aaliyah [Disc 1]` and `[Disc 2]` reduced to one bucket of
    /// two "editions", so owning disc 1 would have deleted disc 2 — an hour of different music —
    /// from the feed, silently.
    func testAMultiDiscSetIsNotCollapsedOntoItself() {
        XCTAssertEqual(parse("Ultimate Aaliyah [Disc 2]").klass, .distinct)
        XCTAssertFalse(superseded(("Ultimate Aaliyah [Disc 2]", "Aaliyah"),
                                  owned: ("Ultimate Aaliyah [Disc 1]", "Aaliyah")))
        XCTAssertFalse(superseded(("Ultimate Aaliyah [Disc 2]", "Aaliyah"),
                                  owned: ("Ultimate Aaliyah", "Aaliyah")))
        // Written out, too.
        XCTAssertEqual(parse("Album (Part Two)").klass, .distinct)
        XCTAssertEqual(parse("Album (Vol. 3)").klass, .distinct)
        XCTAssertEqual(parse("Album (Disc II)").klass, .distinct)
    }

    /// …but the part designator has to carry a NUMBER. An unnumbered format label is still just
    /// packaging, or the fix would swallow the case it was added beside.
    func testAnUnnumberedFormatLabelIsStillCosmetic() {
        XCTAssertEqual(parse("Album (CD Edition)").klass, .cosmetic)
        XCTAssertTrue(superseded(("Album (CD Edition)", "A"), owned: ("Album", "A")))
    }

    /// A volume number in the TITLE ITSELF (not in a group) stays part of the base, which is what
    /// keeps "Vol. 1" and "Vol. 2" in different buckets — a real shape on this catalog.
    func testAVolumeInTheTitleIsPartOfTheRecordIdentity() {
        XCTAssertNotEqual(parse("Fan-Tas-Tic, Vol. 2").base, parse("Fan-Tas-Tic, Vol. 1").base)
        XCTAssertTrue(superseded(("Fan-Tas-Tic, Vol. 2 (Radio Edit)", "Slum Village"),
                                 owned: ("Fan-Tas-Tic, Vol. 2", "Slum Village")),
                      "…while the radio edit of that same volume is still a version of it")
    }

    /// Two edition labels in either order are ONE edition.
    func testVersionMaterialIsOrderIndependent() {
        XCTAssertEqual(parse("Album (Deluxe Edition) [Remastered]").signature,
                       parse("Album [Remastered] (Deluxe Edition)").signature)
    }

    // ========================================================================
    // MARK: - The predicate
    // ========================================================================

    private func superseded(_ candidate: (String, String), owned: (String, String)) -> Bool {
        RecVersionIdentity.isDifferentVersion(candidateTitle: candidate.0, candidateArtist: candidate.1,
                                              ownedTitle: owned.0, ownedArtist: owned.1)
    }

    func testDeluxeEditionOfAnOwnedAlbumIsSuppressed() {
        XCTAssertTrue(superseded(("Rumours (Deluxe Edition)", "Fleetwood Mac"),
                                 owned: ("Rumours", "Fleetwood Mac")))
        // …and the mirror: he owns the deluxe, the standard is offered. Still the same record.
        XCTAssertTrue(superseded(("Rumours", "Fleetwood Mac"),
                                 owned: ("Rumours (Deluxe Edition)", "Fleetwood Mac")))
    }

    func testBonusTrackVersionIsSuppressed() {
        XCTAssertTrue(superseded(("Views (Bonus Track Version)", "Drake"),
                                 owned: ("Views", "Drake")))
    }

    func testExtendedAndRemixCutsOfAnOwnedSongAreSuppressed() {
        XCTAssertTrue(superseded(("Blue Monday (Extended Mix)", "New Order"),
                                 owned: ("Blue Monday", "New Order")))
        XCTAssertTrue(superseded(("Blue Monday (Hardfloor Remix)", "New Order"),
                                 owned: ("Blue Monday", "New Order")))
        XCTAssertTrue(superseded(("Blue Monday - Radio Edit", "New Order"),
                                 owned: ("Blue Monday (Extended Mix)", "New Order")),
                      "two reworkings of one recording are still one recording")
    }

    /// **THE CASE THAT MUST NOT BE SUPPRESSED.** A remix released under the REMIXER's own name is
    /// that artist's record, and killing it would hide exactly the kind of thing this feed exists
    /// to surface.
    func testARemixCreditedToADifferentArtistIsNotSuppressed() {
        XCTAssertFalse(superseded(("Blue Monday (Hardfloor Remix)", "Hardfloor"),
                                  owned: ("Blue Monday", "New Order")))
    }

    /// A cover by someone else is likewise a different record.
    func testACoverByADifferentArtistIsNotSuppressed() {
        XCTAssertFalse(superseded(("Blue Monday", "Orgy"), owned: ("Blue Monday", "New Order")))
    }

    /// A live or acoustic cut is a different performance, in EITHER direction.
    func testAPerformanceIsNotSuppressedInEitherDirection() {
        XCTAssertFalse(superseded(("Blue Monday (Live)", "New Order"),
                                  owned: ("Blue Monday", "New Order")))
        XCTAssertFalse(superseded(("Blue Monday", "New Order"),
                                  owned: ("Blue Monday (Live)", "New Order")),
                       "owning the live take is no reason to withhold the record")
    }

    /// **NEVER ON ARTIST + TITLE ALONE.** With no version material on either side there is no
    /// version relationship to act on — that is `RecMembership`'s question (by id), not this one.
    func testIdenticalArtistAndTitleWithNoVersionMaterialIsNotSuppressed() {
        XCTAssertFalse(superseded(("Intro", "Some Artist"), owned: ("Intro", "Some Artist")))
        XCTAssertFalse(superseded(("Rumours (Deluxe Edition)", "Fleetwood Mac"),
                                  owned: ("Rumours (Deluxe Edition)", "Fleetwood Mac")),
                       "the same edition twice is the same version, not a different one")
    }

    /// Different songs never collide, whatever their markers say.
    func testDifferentRecordsAreUntouched() {
        XCTAssertFalse(superseded(("Tusk (Deluxe Edition)", "Fleetwood Mac"),
                                  owned: ("Rumours", "Fleetwood Mac")))
    }

    /// The artist key has to be loose enough to survive a credit difference, or a deluxe edition
    /// escapes through "(feat. …)".
    func testArtistKeyIgnoresCreditsAndLeadingThe() {
        XCTAssertEqual(RecVersionIdentity.artistKey("The Beatles"), "beatles")
        XCTAssertEqual(RecVersionIdentity.artistKey("Sade feat. Sweetback"),
                       RecVersionIdentity.artistKey("Sade"))
        XCTAssertEqual(RecVersionIdentity.artistKey("Simon & Garfunkel"),
                       RecVersionIdentity.artistKey("Simon and Garfunkel"))
    }

    // ========================================================================
    // MARK: - The index
    // ========================================================================

    func testTheIndexIgnoresPerformancesItOwns() {
        let live = RecVersionIdentity.key(title: "Blue Monday (Live)", artist: "New Order")!
        let index = RecVersionIndex(owned: [live])
        XCTAssertTrue(index.isEmpty, "a live take is not grounds to suppress anything")
        XCTAssertFalse(index.supersedes(title: "Blue Monday (Extended Mix)", artist: "New Order"))
    }

    func testAnEmptyIndexSuppressesNothing() {
        XCTAssertFalse(RecVersionIndex.empty.supersedes(title: "Rumours (Deluxe Edition)",
                                                        artist: "Fleetwood Mac"))
    }
}

// ============================================================================
// MARK: - The collection tiles (build time)
// ============================================================================

/// The guarantee where it is spent: `ZoneEngine.suggestions`, which is what fills every collection
/// tile. All three tracks score identically here, so anything that disappears did so because of the
/// version filter and nothing else.
final class RecVersionSuggestionTests: XCTestCase {

    private func track(_ id: String, _ title: String, _ artist: String = "New Order") -> ZoneEngine.Track {
        ZoneEngine.Track(songId: id, artistKey: "neworder", artistName: artist,
                         genre: "electronic", title: title)
    }

    /// The crate holds the standard cut; the catalog also has the extended mix and a genuinely
    /// different song. Only the different song may be offered.
    func testAnExtendedMixOfAMemberIsNeverSuggested() {
        let tracks = [track("sng_member", "Blue Monday"),
                      track("sng_extended", "Blue Monday (Extended Mix)"),
                      track("sng_other", "Temptation")]
        let out = ZoneEngine.suggestions(memberSongIds: ["sng_member"], tracks: tracks,
                                         playCount: { _ in 1 })
        XCTAssertEqual(out, ["sng_other"],
                       "the extended mix is a different version of what is already in the crate")
    }

    func testADeluxeEditionOfAMemberIsNeverSuggested() {
        let tracks = [track("sng_member", "Power, Corruption & Lies"),
                      track("sng_deluxe", "Power, Corruption & Lies (Deluxe Edition)"),
                      track("sng_other", "Temptation")]
        let out = ZoneEngine.suggestions(memberSongIds: ["sng_member"], tracks: tracks,
                                         playCount: { _ in 1 })
        XCTAssertEqual(out, ["sng_other"])
    }

    /// The live cut survives — the owner asked about editions and reworkings, not performances.
    func testALiveCutOfAMemberIsStillSuggested() {
        let tracks = [track("sng_member", "Blue Monday"),
                      track("sng_live", "Blue Monday (Live)"),
                      track("sng_other", "Temptation")]
        let out = ZoneEngine.suggestions(memberSongIds: ["sng_member"], tracks: tracks,
                                         playCount: { _ in 1 })
        XCTAssertEqual(Set(out), ["sng_live", "sng_other"])
    }

    /// A remix under the remixer's own name is a different artist's record and keeps its slot.
    func testARemixByADifferentArtistIsStillSuggested() {
        let tracks = [ZoneEngine.Track(songId: "sng_member", artistKey: "neworder",
                                       artistName: "New Order", genre: "electronic",
                                       title: "Blue Monday"),
                      ZoneEngine.Track(songId: "sng_remix", artistKey: "neworder",
                                       artistName: "Hardfloor", genre: "electronic",
                                       title: "Blue Monday (Hardfloor Remix)")]
        let out = ZoneEngine.suggestions(memberSongIds: ["sng_member"], tracks: tracks,
                                         playCount: { _ in 1 })
        XCTAssertEqual(out, ["sng_remix"])
    }

    /// The keys derived ONCE for a whole refresh must produce the identical ranking to deriving
    /// them per crate. `ForYouFeedBuilder` takes the shared path and every other caller takes the
    /// per-call one, so a divergence here would mean the tile and the screen behind it disagree.
    func testSharedVersionKeysRankIdenticallyToPerCallDerivation() {
        let tracks = [track("sng_member", "Blue Monday"),
                      track("sng_extended", "Blue Monday (Extended Mix)"),
                      track("sng_other", "Temptation")]
        let shared = ZoneEngine.versionKeys(tracks)
        XCTAssertEqual(shared.count, 3)
        XCTAssertEqual(ZoneEngine.suggestions(memberSongIds: ["sng_member"], tracks: tracks,
                                              playCount: { _ in 1 }, versions: shared),
                       ZoneEngine.suggestions(memberSongIds: ["sng_member"], tracks: tracks,
                                              playCount: { _ in 1 }))
    }

    /// A projection with NO titles behaves exactly as it did before this feature existed — the
    /// property that keeps every other fixture in this suite honest.
    func testATitlelessProjectionIsUnaffected() {
        let tracks = [ZoneEngine.Track(songId: "sng_member", artistKey: "neworder",
                                       artistName: "New Order", genre: "electronic"),
                      ZoneEngine.Track(songId: "sng_extended", artistKey: "neworder",
                                       artistName: "New Order", genre: "electronic")]
        let out = ZoneEngine.suggestions(memberSongIds: ["sng_member"], tracks: tracks,
                                         playCount: { _ in 1 })
        XCTAssertEqual(out, ["sng_extended"])
    }
}

// ============================================================================
// MARK: - The collection tiles (read time)
// ============================================================================

/// The frozen half. For You only re-ranks on an explicit Refresh, so a list can name the deluxe
/// edition of a record he added ten seconds ago from that very tile. Driven through the real store,
/// including its `membershipRevision` memo — the part most likely to be quietly wrong.
@MainActor
final class RecVersionReadTimeTests: XCTestCase {

    private struct EditionsLoader: CatalogLoading {
        func loadIndex() async throws -> IndexJSON {
            try JSONDecoder().decode(IndexJSON.self, from: Data(Self.json.utf8))
        }

        static let json = """
        {
          "manifest": { "sourceName": "Editions", "counts": { "albums": 1, "songs": 4 } },
          "albums": [
            { "id": "alb_e", "artist": "New Order", "name": "Substance", "genre": "Electronic",
              "year": 1987, "country": "UK",
              "trackList": ["sng_std", "sng_ext", "sng_live", "sng_other"], "fileType": "mp3" }
          ],
          "songs": [
            { "id": "sng_std", "albumId": "alb_e", "artist": "New Order", "name": "Blue Monday",
              "trackNumber": 1, "year": 1983, "length": 450000 },
            { "id": "sng_ext", "albumId": "alb_e", "artist": "New Order",
              "name": "Blue Monday (Extended Mix)", "trackNumber": 2, "year": 1983, "length": 460000 },
            { "id": "sng_live", "albumId": "alb_e", "artist": "New Order",
              "name": "Blue Monday (Live)", "trackNumber": 3, "year": 1983, "length": 470000 },
            { "id": "sng_other", "albumId": "alb_e", "artist": "New Order", "name": "Temptation",
              "trackNumber": 4, "year": 1982, "length": 520000 }
          ]
        }
        """
    }

    /// `CollectionsStore.app` is WEAK — the model has to be kept alive by the caller or every
    /// lookup silently resolves against an empty catalog.
    private func makeStore() async -> (CollectionsStore, AppModel) {
        let app = AppModel(loader: EditionsLoader())
        await app.loadIfNeeded()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-recver-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app
        return (collections, app)
    }

    /// THE HEADLINE. The frozen list offers the extended mix; he has since filed the standard cut.
    func testAnExtendedMixIsDroppedAtReadTimeOnceTheStandardCutIsAMember() async {
        let (collections, app) = await makeStore()
        let pl = collections.createPlaylist("Crate")
        let frozen = ["sng_ext", "sng_live", "sng_other"]

        XCTAssertEqual(collections.suggestionsExcludingMembers(frozen, ofCollection: pl.id), frozen,
                       "an empty crate filters nothing")
        collections.addSong("sng_std", toPlaylist: pl.id)
        XCTAssertEqual(collections.suggestionsExcludingMembers(frozen, ofCollection: pl.id),
                       ["sng_live", "sng_other"],
                       "the extended mix goes immediately — no Refresh in between — and the live cut stays")
        withExtendedLifetime(app) {}
    }

    /// The mirror: he files the extended mix, and the standard cut of the same recording drops.
    func testTheStandardCutIsDroppedOnceAReworkingIsAMember() async {
        let (collections, app) = await makeStore()
        let pl = collections.createPlaylist("Crate")
        collections.addSong("sng_ext", toPlaylist: pl.id)
        XCTAssertEqual(collections.suggestionsExcludingMembers(["sng_std", "sng_other"],
                                                               ofCollection: pl.id),
                       ["sng_other"])
        withExtendedLifetime(app) {}
    }

    /// Owning the LIVE take is not grounds to withhold the studio recording.
    func testOwningALivePerformanceSuppressesNothing() async {
        let (collections, app) = await makeStore()
        let pl = collections.createPlaylist("Crate")
        collections.addSong("sng_live", toPlaylist: pl.id)
        XCTAssertEqual(collections.suggestionsExcludingMembers(["sng_std", "sng_ext", "sng_other"],
                                                               ofCollection: pl.id),
                       ["sng_std", "sng_ext", "sng_other"])
        withExtendedLifetime(app) {}
    }
}

// ============================================================================
// MARK: - The New tile
// ============================================================================

/// The other surface the owner named. A Deluxe reissue is a NEW album in Apple's catalog with a NEW
/// store id, so the existing ownership probe answers "that's new" — correctly by its own
/// definition, and uselessly.
final class ReleaseFeedVersionTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-relver-\(UUID().uuidString).json")
    }

    @MainActor
    private func service(_ entries: [ArtistReleaseEntry]) -> ReleaseFeedService {
        let url = tempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let svc = ReleaseFeedService(transport: nil, fileURL: url)
        svc.seedForTesting(entries)
        return svc
    }

    @MainActor
    func testADeluxeReissueOfAnOwnedAlbumIsNotOfferedAsNew() {
        let now: Double = 1_700_000_000_000
        let day: Double = 86_400_000
        let svc = service([
            ArtistReleaseEntry(artistId: 1, artistName: "Fleetwood Mac", checkedAtMs: now,
                               releaseId: "1000", releaseName: "Rumours (Deluxe Edition)",
                               releaseAtMs: now - day),
            ArtistReleaseEntry(artistId: 2, artistName: "New Order", checkedAtMs: now,
                               releaseId: "2000", releaseName: "Music Complete",
                               releaseAtMs: now - 2 * day),
        ])
        // The store-id probe cannot see it: the reissue has its own adam id.
        svc.ownsRelease = { _ in false }
        XCTAssertEqual(svc.feed(nowMs: now).count, 2, "…which is exactly the bug")

        let owned = RecVersionIndex(owned: [RecVersionIdentity.key(title: "Rumours",
                                                                   artist: "Fleetwood Mac")!])
        svc.ownsReleaseVersion = { _, artist, title in owned.supersedes(title: title, artist: artist) }
        XCTAssertEqual(svc.feed(nowMs: now).map(\.entry.artistId), [2],
                       "the reissue goes; the record he does not have stays")
    }

    /// A live album by an artist whose studio record he owns is genuinely new.
    @MainActor
    func testALiveAlbumIsStillOffered() {
        let now: Double = 1_700_000_000_000
        let svc = service([
            ArtistReleaseEntry(artistId: 1, artistName: "Fleetwood Mac", checkedAtMs: now,
                               releaseId: "1000", releaseName: "Rumours (Live)",
                               releaseAtMs: now - 86_400_000),
        ])
        let owned = RecVersionIndex(owned: [RecVersionIdentity.key(title: "Rumours",
                                                                   artist: "Fleetwood Mac")!])
        svc.ownsReleaseVersion = { _, artist, title in owned.supersedes(title: title, artist: artist) }
        XCTAssertEqual(svc.feed(nowMs: now).count, 1)
    }

    /// An UNSET probe means "own nothing" — the same honest cold-launch default `ownsRelease`
    /// takes, so a catalog that has not finished loading cannot empty the tile.
    @MainActor
    func testUnsetVersionProbeSuppressesNothing() {
        let now: Double = 1_700_000_000_000
        let svc = service([
            ArtistReleaseEntry(artistId: 1, artistName: "Fleetwood Mac", checkedAtMs: now,
                               releaseId: "1000", releaseName: "Rumours (Deluxe Edition)",
                               releaseAtMs: now - 86_400_000),
        ])
        XCTAssertNil(svc.ownsReleaseVersion)
        XCTAssertEqual(svc.feed(nowMs: now).count, 1)
    }
}
