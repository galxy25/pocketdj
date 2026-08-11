import XCTest
@testable import PocketDJ

/// **For You in CarPlay** — the tab that replaced Albums and Artists.
///
/// ── WHAT THIS SUITE CAN AND CANNOT PROVE ─────────────────────────────────────────────────────
/// The CarPlay SURFACE is not headless-testable in this repo: there is no simulated head unit and
/// `CPListTemplate` renders nothing an XCUITest can see. So the feature was written with everything
/// decidable pushed into `CarPlayForYou.swift` (no `CarPlay` import) and `CarPlayScene` left with
/// template plumbing only. This suite covers that model layer — which tiles, in what order, which
/// rows behind each, what a tap plays, and whether the now-playing 👍/👎 pair lights up.
/// What stays UNVERIFIED is the rendering: the tab bar's three tabs, the list items, the action
/// sheet. Those were read, not run.
///
/// Fixture (StubLoader): alb_1 Aria (sng_1 "Neon", sng_2 "Pulse", sng_3 "Drift"),
/// alb_2 Bento (sng_4 "Swing Low", sng_5 "Blue Note"), alb_3 Cobalt (sng_6, sng_7).
@MainActor
final class CarPlayForYouTests: XCTestCase {

    private struct Rig {
        let model: CarPlayModel
        let services: IntentServices
        let collections: CollectionsStore
        let feed: ForYouFeedStore
        let feedback: RecFeedbackStore
        let releases: ReleaseFeedService
    }

    private func tmp(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-cpfy-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The full CarPlay bridge with the recommendation graph attached — including the
    /// `onPlaybackReplaced` hook `PocketDJApp` installs. That hook is not decoration here: it is
    /// what retires the previous rec scope on every `playNow`, so wiring it is what makes
    /// "the scope is stamped AFTER the play, not before" a claim these tests can actually falsify.
    private func makeRig() async -> Rig {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let collections = CollectionsStore(fileURL: tmp("col"))
        collections.app = app
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID())")!)
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        let burns = BurnStore(rips: rips, fileURL: tmp("burns"))
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let services = IntentServices(app: app, settings: settings, collections: collections,
                                      setlistPlayer: sequencer, mix: MixEngine(burns: burns),
                                      burns: burns, studio: StudioStore(fileURL: tmp("studio")),
                                      rips: rips, favorites: FavoritesStore(fileURL: tmp("fav")))
        let feedback = RecFeedbackStore(fileURL: tmp("fb"), identityKey: "test.\(UUID())")
        let feed = ForYouFeedStore(fileURL: tmp("feed"))
        let releases = ReleaseFeedService(transport: nil, fileURL: tmp("rel"))
        services.recFeedback = feedback
        services.forYouFeed = feed
        services.releaseFeed = releases
        collections.onPlaybackReplaced = { [weak feedback] in feedback?.endPlaybackScope() }
        return Rig(model: CarPlayModel(services: services), services: services,
                   collections: collections, feed: feed, feedback: feedback, releases: releases)
    }

    /// A frozen feed with an In Da Zone ranking and (optionally) one crate.
    private func seedFeed(_ rig: Rig, zone: [String], crates: [ForYouFeedSnapshot.Crate] = []) {
        rig.feed.commit(ForYouFeedSnapshot(refreshedAtMs: 1_000, zoneIds: zone, crates: crates))
    }

    // ========================================================================
    // MARK: - The pinned order (the owner's actual requirement)
    // ========================================================================

    /// *"For You (new and recommended pinned up top)"*, and matching the phone. New is row 1,
    /// In Da Zone is row 2, collection tiles follow — and both surfaces get that from the SAME
    /// `ForYouGrid.tiles` call, which is the assertion at the bottom.
    func testTilesPinNewAndZoneFirstAndMatchThePhone() async {
        let rig = await makeRig()
        rig.releases.seedForTesting(ReleaseFeedService.uiFixtureEntries(nowMs: 1_000_000_000_000))
        let pl = rig.collections.createPlaylist("Evening")
        seedFeed(rig, zone: ["sng_1", "sng_2"],
                 crates: [.init(id: pl.id, kind: "playlist", name: "Evening", songIds: ["sng_4"])])

        let rows = rig.model.forYouTiles(nowMs: 1_000_000_000_000)
        XCTAssertEqual(rows.map(\.id), ["new", "zone", "col-\(pl.id)"],
                       "New pinned first, In Da Zone second, collections after")
        XCTAssertTrue(rows.allSatisfy { !$0.isSong }, "tile rows are drill-ins, not songs")

        // THE ANTI-DRIFT ASSERTION. The car does not re-derive the order; it renders the phone's.
        let phone = ForYouGrid.tiles(snapshot: rig.feed.snapshot, collections: rig.collections,
                                     feedback: rig.feedback, releaseFeed: rig.releases,
                                     nowMs: 1_000_000_000_000)
        XCTAssertEqual(rows.map(\.id), phone.map(\.id))
        XCTAssertEqual(rows.map(\.title), phone.map(\.title))
    }

    /// The two pinned tiles exist even with nothing behind them, and say WHY rather than showing a
    /// bare 0 — a car is the worst place to be handed an unexplained empty row.
    func testPinnedTilesSurviveAColdFeedAndExplainThemselves() async {
        let rig = await makeRig()
        let rows = rig.model.forYouTiles()
        XCTAssertEqual(rows.map(\.id), ["new", "zone"])
        XCTAssertEqual(rows[1].subtitle, "Play a few songs to build your zone",
                       "at zero the explanation wins — no \"0 songs · \" prefix")
        XCTAssertFalse(CarPlayModel.coldFeedNote.isEmpty,
                       "and the tab itself has a line for a feed that has never been built")
    }

    /// The count on a car row must describe what is behind it. New's phone badge is out-now PLUS
    /// pre-orders; the car lists out-now ONLY (a pre-order has no audio, and every row in a car has
    /// to be playable), so the car's number is the smaller one.
    func testNewRowCountsOnlyWhatItCanActuallyPlay() async {
        let rig = await makeRig()
        let now = 1_000_000_000_000.0
        rig.releases.seedForTesting(ReleaseFeedService.uiFixtureEntries(nowMs: now))  // 2 out now + 1 pre-order

        let phoneNewTile = ForYouGrid.tiles(snapshot: rig.feed.snapshot, collections: rig.collections,
                                            feedback: rig.feedback, releaseFeed: rig.releases,
                                            nowMs: now).first
        XCTAssertEqual(phoneNewTile?.count, 3, "the phone badge counts the pre-order too")

        let row = rig.model.forYouTiles(nowMs: now).first
        XCTAssertTrue(row?.subtitle?.hasPrefix("2 releases · ") == true,
                      "the car counts the two it can play — got \(row?.subtitle ?? "nil")")
        let rows = rig.model.forYouRows(tileId: "new", nowMs: now)
        XCTAssertEqual(rows.count, 2, "…and lists exactly those two")
        XCTAssertEqual(rows.map(\.id), ["rel:9000000001", "rel:9000000002"])
        XCTAssertEqual(rows.first?.title, "Second Side")
        XCTAssertEqual(rows.first?.subtitle, "The Test Pressing")
        XCTAssertTrue(rows.allSatisfy { !$0.isSong },
                      "a release is NOT a catalog song — it has no id to add to a pocket")
        XCTAssertTrue(rig.model.isReleaseTile("new"))
        XCTAssertFalse(rig.model.isReleaseTile("zone"))
    }

    // ========================================================================
    // MARK: - Rows behind a tile
    // ========================================================================

    /// In Da Zone's rows are the frozen ranking, resolved to catalog songs in order.
    func testZoneRowsAreTheFrozenRankingResolved() async {
        let rig = await makeRig()
        seedFeed(rig, zone: ["sng_1", "sng_4", "not_a_song"])
        let rows = rig.model.forYouRows(tileId: "zone")
        XCTAssertEqual(rows.map(\.id), ["sng_1", "sng_4"], "unresolvable ids are dropped, order kept")
        XCTAssertEqual(rows.map(\.title), ["Neon", "Swing Low"])
        XCTAssertEqual(rows.first?.artworkAlbumId, "alb_1")
        XCTAssertTrue(rows.allSatisfy(\.isSong))
        XCTAssertTrue(rig.model.forYouRows(tileId: "col-nope").isEmpty, "unknown tile ⇒ no rows")
    }

    /// A 👎 given ANYWHERE — the phone, the widget, this car — takes the row out of what the car
    /// offers and out of the count above it, together. `RecFeedbackStore` is the one copy of a
    /// verdict, so there is nothing to synchronise: the next read is already right.
    func testThumbsDownRemovesTheRowAndTheCountTogether() async {
        let rig = await makeRig()
        seedFeed(rig, zone: ["sng_1", "sng_2", "sng_3"])
        XCTAssertEqual(rig.model.forYouRows(tileId: "zone").count, 3)
        XCTAssertEqual(rig.model.forYouTiles()[1].subtitle?.hasPrefix("3 songs · "), true)

        rig.feedback.record(songId: "sng_2", scope: "zone", verdict: .rejected, surface: .carPlay)

        XCTAssertEqual(rig.model.forYouRows(tileId: "zone").map(\.id), ["sng_1", "sng_3"])
        XCTAssertEqual(rig.model.forYouTiles()[1].subtitle?.hasPrefix("2 songs · "), true,
                       "the row and the number move together — a card cannot promise 3 and open on 2")
    }

    /// A collection tile offers only what is NOT already in the collection. Adding a suggestion —
    /// which is exactly what a 👍 does — must take it off the car's list on the next read, without
    /// waiting for the next refresh.
    func testCollectionTileDropsSuggestionsAlreadyAdded() async {
        let rig = await makeRig()
        let pl = rig.collections.createPlaylist("Evening")
        rig.collections.addSong("sng_1", toPlaylist: pl.id)
        seedFeed(rig, zone: [],
                 crates: [.init(id: pl.id, kind: "playlist", name: "Evening",
                                songIds: ["sng_4", "sng_5"])])
        let tileId = "col-\(pl.id)"
        XCTAssertEqual(rig.model.forYouRows(tileId: tileId).map(\.id), ["sng_4", "sng_5"])

        rig.collections.addSong("sng_4", toPlaylist: pl.id)

        XCTAssertEqual(rig.model.forYouRows(tileId: tileId).map(\.id), ["sng_5"],
                       "a suggestion he has already filed is no longer a suggestion")
    }

    /// Switching recommendations off for a collection takes its tile out of the car too — the flag
    /// is read at derivation, so it does not wait for a refresh.
    func testCollectionWithRecommendationsOffHasNoTile() async {
        let rig = await makeRig()
        let pl = rig.collections.createPlaylist("Comfort Zone")
        seedFeed(rig, zone: [],
                 crates: [.init(id: pl.id, kind: "playlist", name: "Comfort Zone", songIds: ["sng_4"])])
        XCTAssertEqual(rig.model.forYouTiles().map(\.id), ["new", "zone", "col-\(pl.id)"])

        rig.collections.setRecommendationsEnabled(false, forCollection: pl.id)

        XCTAssertEqual(rig.model.forYouTiles().map(\.id), ["new", "zone"])
    }

    // ========================================================================
    // MARK: - Playing from the car
    // ========================================================================

    /// ▶ Play all on a tile starts the shared sequencer with exactly the rows the tile listed…
    /// **and stamps the recommendation scope**, which is what makes the 👍/👎 pair on the CarPlay
    /// Now Playing card appear at all. Until this feature the car could not START a rec queue, so
    /// those buttons only ever showed for a set begun on the phone.
    func testPlayTileStartsTheQueueAndLightsTheThumbs() async {
        let rig = await makeRig()
        seedFeed(rig, zone: ["sng_1", "sng_2"])
        XCTAssertFalse(rig.model.isRecQueue(), "nothing playing ⇒ no thumbs")

        let ok = await rig.model.playForYouTile("zone")

        XCTAssertTrue(ok)
        XCTAssertEqual(rig.services.setlistPlayer.queue.map(\.id), ["sng_1", "sng_2"])
        // THE ORDERING PROOF: `playNow` fires `onPlaybackReplaced` → `endPlaybackScope`. A stamp
        // made before the play would have been wiped by it and this would be false.
        XCTAssertTrue(rig.model.isRecQueue(), "the car's own queue is a recommendation")
        XCTAssertNil(rig.model.currentFeedback(), "…with no verdict yet")

        rig.model.recordCurrentFeedback(.rejected)
        XCTAssertEqual(rig.model.currentFeedback(), .rejected)
        XCTAssertEqual(rig.feedback.verdict(songId: "sng_1", scope: "zone"), .rejected,
                       "filed against the TILE it is playing from")
        XCTAssertEqual(rig.services.setlistPlayer.currentSongId, "sng_1",
                       "a 👎 is a statement about the recommendation — it must NOT skip")
        rig.services.setlistPlayer.stop()
    }

    /// Shuffle plays the same set, not a different one.
    func testShuffleTilePlaysTheSameSongs() async {
        let rig = await makeRig()
        seedFeed(rig, zone: ["sng_1", "sng_2", "sng_3"])
        let ok = await rig.model.playForYouTile("zone", shuffle: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(Set(rig.services.setlistPlayer.queue.map(\.id)), ["sng_1", "sng_2", "sng_3"])
        rig.services.setlistPlayer.stop()
    }

    /// A tile with nothing live in it plays nothing and SAYS so (`false`), rather than leaving a
    /// tap that quietly did nothing.
    func testEmptyTileReportsFailureInsteadOfSilence() async {
        let rig = await makeRig()
        seedFeed(rig, zone: [])
        let ok = await rig.model.playForYouTile("zone")
        XCTAssertFalse(ok)
        XCTAssertFalse(rig.services.setlistPlayer.isRunning)
        let ghost = await rig.model.playForYouTile("col-ghost")
        XCTAssertFalse(ghost, "unknown tile ⇒ false")
    }

    /// Tapping a row plays FROM THERE ONWARD — the "play from here" any music list does. A
    /// one-track queue would end and leave the car silent.
    func testRowTapPlaysFromThatRowOnward() async {
        let rig = await makeRig()
        seedFeed(rig, zone: ["sng_1", "sng_2", "sng_3"])

        let ok = await rig.model.playForYouRow("sng_2", inTile: "zone")

        XCTAssertTrue(ok)
        XCTAssertEqual(rig.services.setlistPlayer.queue.map(\.id), ["sng_2", "sng_3"])
        XCTAssertTrue(rig.model.isRecQueue(), "still a recommendation — the thumbs stay available")
        let stray = await rig.model.playForYouRow("sng_9", inTile: "zone")
        XCTAssertFalse(stray, "a row that is not in the tile is a no-op, not a wrong queue")
        rig.services.setlistPlayer.stop()
    }

    /// A 👎 row cannot be played out from underneath the filter: it is not in the list, so
    /// "play from here" cannot start there.
    func testRejectedRowIsNotPlayable() async {
        let rig = await makeRig()
        seedFeed(rig, zone: ["sng_1", "sng_2"])
        rig.feedback.record(songId: "sng_2", scope: "zone", verdict: .rejected, surface: .tile)
        let ok = await rig.model.playForYouRow("sng_2", inTile: "zone")
        XCTAssertFalse(ok)
        XCTAssertFalse(rig.services.setlistPlayer.isRunning)
    }

    /// New goes down the OTHER door — `ReleaseStreaming`, not `playSongIds` — because its tracks
    /// are records the owner does not own and `CollectionsStore.playNow` drops every id the catalog
    /// cannot resolve. That door bypasses `playSongIds`' onboarding guard, so it carries its own:
    /// a device that has not finished setup starts no audio from the car.
    func testNewIsVetoedBeforeSetupIsFinished() async {
        let rig = await makeRig()
        rig.releases.seedForTesting(ReleaseFeedService.uiFixtureEntries(nowMs: 1_000_000_000_000))
        rig.services.onboardingIncomplete = { true }

        let ok = await rig.model.playForYouTile("new", nowMs: 1_000_000_000_000)

        XCTAssertFalse(ok)
        XCTAssertFalse(rig.services.setlistPlayer.isRunning,
                       "no queue is materialised on a device that hasn't been set up")
        let row = await rig.model.playForYouRow("rel:9000000001", inTile: "new")
        XCTAssertFalse(row)
    }

    /// A malformed release row id cannot be mistaken for a song id and sent down the catalog path.
    func testBlankReleaseIdIsNotTreatedAsASongId() async {
        let rig = await makeRig()
        seedFeed(rig, zone: ["sng_1"])
        let ok = await rig.model.playForYouRow("rel:", inTile: "zone")
        XCTAssertFalse(ok)
        XCTAssertFalse(rig.services.setlistPlayer.isRunning)
    }
}
