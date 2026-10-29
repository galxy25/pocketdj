import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 0 — play attribution + the new additive event fields.
///
/// The wheel's colour is "the collection the music came from" (§1.5). Before Phase 0 three play
/// paths recorded NO origin: CarPlay source playlists, the menu/toolbar door (`playSongIds`), and
/// Mix Auto-DJ (whose `contextId` is a session, not a crate). These tests pin each fix, plus the
/// write-once / local-only / first-writer-wins rules of the new `motion` and `pocketRun` fields.
@MainActor
final class PlayAttributionTests: XCTestCase {

    // MARK: - Helpers

    private var held: [AnyObject] = []
    override func tearDown() { held = []; super.tearDown() }

    private func tmp(_ stem: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-attr-\(stem)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeServices() async -> (IntentServices, CollectionsStore, AppModel) {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let collections = CollectionsStore(fileURL: tmp("col"))
        collections.app = app
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID())")!)
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        let burns = BurnStore(rips: rips, fileURL: tmp("burns"))
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let services = IntentServices(app: app, settings: settings, collections: collections,
                                      setlistPlayer: sequencer, mix: MixEngine(burns: burns), burns: burns,
                                      studio: StudioStore(fileURL: tmp("studio")), rips: rips,
                                      favorites: FavoritesStore(fileURL: tmp("fav")))
        held.append(app)
        return (services, collections, app)
    }

    private func event(_ song: String, at ms: Double, origin: String? = nil,
                       motion: String? = nil) -> PlayHistoryStore.PlayEvent {
        var e = PlayHistoryStore.PlayEvent(id: UUID(), songId: song, playedAt: ms, source: .playlist,
                                           contextId: "set_now_playing", contextName: "X",
                                           title: nil, artist: nil, originInstallId: origin)
        e.motion = motion
        return e
    }

    // MARK: - Origin stamping

    /// CarPlay ▸ Playlists ▸ an Apple Music source playlist: the play now names that playlist as
    /// its origin (it used to record `set_now_playing` with no origin at all).
    func testCarPlaySourcePlaylistPlayStampsItsOrigin() async {
        let (services, collections, app) = await makeServices()
        app.indexPlaylists = [
            SourcePlaylist(playlist: IndexPlaylist(id: "ip_pot", name: "Potential", songIds: ["sng_1", "sng_2"]),
                           sourceName: "Apple Music")
        ]
        // The app wires the sequencer's origin capture to the collections store (PocketDJApp).
        services.setlistPlayer.originProvider = { [weak collections] in
            collections?.originCollection(forSourceSetlistId: $0)
        }
        let model = CarPlayModel(services: services)
        await model.playPlaylist(id: "src:ip_pot")
        XCTAssertEqual(collections.nowPlayingOriginId, "ip_pot")
        let origin = collections.originCollection(forSourceSetlistId: collections.nowPlayingSetlist()?.id)
        XCTAssertEqual(origin?.kind, .playlist)
        XCTAssertEqual(origin?.id, "ip_pot")
        XCTAssertEqual(services.setlistPlayer.capturedOrigin?.id, "ip_pot",
                       "the sequencer captured the origin the history hook stamps")
        services.setlistPlayer.stop()
    }

    /// The menu/toolbar door forwards `originId`; omitting it keeps the old no-origin behaviour.
    func testPlaySongIdsForwardsOriginId() async throws {
        let (services, collections, _) = await makeServices()
        try await services.playSongIds(["sng_1"], name: "Late Night", source: .playlist, originId: "pkt_late")
        XCTAssertEqual(collections.nowPlayingOriginId, "pkt_late")
        try await services.playSongIds(["sng_2"], name: "Queue", source: .browser)
        XCTAssertNil(collections.nowPlayingOriginId)
        services.setlistPlayer.stop()
    }

    /// `historyContext` / `originCollection` resolve a catalog source playlist id and the reserved
    /// Favorites id directly (the defensive fallbacks).
    func testHistoryContextResolvesSourcePlaylistAndFavoritesIds() async {
        let (_, collections, app) = await makeServices()
        app.indexPlaylists = [
            SourcePlaylist(playlist: IndexPlaylist(id: "pl_pot", name: "Potential", songIds: ["sng_1"]),
                           sourceName: "Apple Music")
        ]
        let ctx = collections.historyContext(forSourceSetlistId: "pl_pot")
        XCTAssertEqual(ctx.source, .playlist)
        XCTAssertEqual(ctx.name, "Potential")
        XCTAssertEqual(collections.originCollection(forSourceSetlistId: "pl_pot")?.id, "pl_pot")
        let fav = collections.historyContext(forSourceSetlistId: PocketWheelIds.favorites)
        XCTAssertEqual(fav.source, .playlist)
        XCTAssertEqual(fav.name, "Favorite songs")
        XCTAssertEqual(collections.originCollection(forSourceSetlistId: PocketWheelIds.favorites)?.id, "fav_songs")
        XCTAssertNil(collections.originCollection(forSourceSetlistId: "pl_unknown"))
    }

    func testMixSourceCollectionId() {
        XCTAssertEqual(MixSource.pocket("pkt_1").collectionId, "pkt_1")
        XCTAssertEqual(MixSource.playlist("pls_1").collectionId, "pls_1")
        XCTAssertEqual(MixSource.setlist("set_1").collectionId, "set_1")
    }

    /// A pre-wheel Auto-DJ snapshot row (no `originCollectionId` key) still decodes.
    func testAutoRowDecodesWithoutOrigin() throws {
        let json = #"{"track":{"songId":"s1","title":"T","artist":"A"},"durationMs":1000,"sourceLabel":"Warmup"}"#
        let row = try JSONDecoder().decode(MixDeckSessionStore.AutoRow.self, from: Data(json.utf8))
        XCTAssertNil(row.originCollectionId)
        XCTAssertEqual(row.sourceLabel, "Warmup")
    }

    // MARK: - New event fields

    /// An event written before the wheel decodes with both fields nil; garbage in them reads nil
    /// instead of dropping the play.
    func testOldAndMalformedEventsDecodeWithNilWheelFields() throws {
        let old = #"{"id":"6F1C3C8E-6F0B-4A0E-9E0A-7B9C2D1E0F11","songId":"s1","playedAt":1000,"source":"playlist"}"#
        let e = try JSONDecoder().decode(PlayHistoryStore.PlayEvent.self, from: Data(old.utf8))
        XCTAssertNil(e.motion)
        XCTAssertNil(e.pocketRun)
        let bad = #"{"id":"6F1C3C8E-6F0B-4A0E-9E0A-7B9C2D1E0F12","songId":"s1","playedAt":1000,"source":"pocket","motion":42,"pocketRun":"nope"}"#
        let b = try JSONDecoder().decode(PlayHistoryStore.PlayEvent.self, from: Data(bad.utf8))
        XCTAssertNil(b.motion)
        XCTAssertNil(b.pocketRun)
        XCTAssertEqual(b.songId, "s1", "the play itself survives")
    }

    func testWheelFieldsRoundTrip() throws {
        var e = event("s1", at: 5)
        e.motion = MotionToken.running
        let run = UUID()
        e.pocketRun = PocketRunTag(runId: run, momentKey: "h08|d2|carPlay", rowCollectionId: "pl_pot", slot: 3)
        let back = try JSONDecoder().decode(PlayHistoryStore.PlayEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.motion, "running")
        XCTAssertEqual(back.pocketRun, e.pocketRun)
    }

    /// `stampMotion` is write-once and never tags a peer's play.
    func testStampMotionIsWriteOnceAndLocalOnly() {
        let store = PlayHistoryStore(fileURL: tmp("hist"))
        let mine = event("s1", at: 1_000, origin: store.installId)
        let peer = event("s2", at: 2_000, origin: "peer-install")
        let settled = event("s3", at: 3_000, origin: store.installId, motion: MotionToken.walking)
        store.replaceAll([mine, peer, settled])
        let rev = store.revision
        store.stampMotion([mine.id: MotionToken.running, peer.id: MotionToken.running, settled.id: MotionToken.running])
        XCTAssertEqual(store.events.first { $0.id == mine.id }?.motion, "running")
        XCTAssertNil(store.events.first { $0.id == peer.id }?.motion, "a peer's play is never tagged here")
        XCTAssertEqual(store.events.first { $0.id == settled.id }?.motion, "walking", "write-once")
        XCTAssertGreaterThan(store.revision, rev)
        // A no-op stamp doesn't bump the revision.
        let rev2 = store.revision
        store.stampMotion([mine.id: MotionToken.walking])
        XCTAssertEqual(store.revision, rev2)
        XCTAssertEqual(store.events.first { $0.id == mine.id }?.motion, "running")
        // Persisted.
        let reread = PlayHistoryStore(fileURL: store.syncFileURL)
        XCTAssertEqual(reread.events.first { $0.id == mine.id }?.motion, "running")
    }

    func testStampPocketRunIsWriteOnce() {
        let store = PlayHistoryStore(fileURL: tmp("hist-run"))
        let e = event("s1", at: 1_000, origin: store.installId)
        store.replaceAll([e])
        let a = PocketRunTag(runId: UUID(), momentKey: "h08|d2|carPlay", rowCollectionId: nil, slot: 1)
        let b = PocketRunTag(runId: UUID(), momentKey: "h09|d2|carPlay", rowCollectionId: nil, slot: 2)
        store.stampPocketRun(eventId: e.id, tag: a)
        store.stampPocketRun(eventId: e.id, tag: b)
        XCTAssertEqual(store.events.first?.pocketRun, a)
    }

    /// The union merge: motion / pocketRun are first-writer-wins (ours if set, else the peer's),
    /// and a doc missing them is republished.
    func testReloadFromDiskMergesWheelFields() throws {
        let url = tmp("hist-merge")
        let store = PlayHistoryStore(fileURL: url)
        let shared = event("s1", at: 1_000, origin: store.installId)
        let ourOwn = event("s2", at: 2_000, origin: store.installId, motion: MotionToken.walking)
        store.replaceAll([shared, ourOwn])

        var theirsShared = shared
        theirsShared.motion = MotionToken.running
        theirsShared.pocketRun = PocketRunTag(runId: UUID(), momentKey: "h08|d2|carPlay", rowCollectionId: nil, slot: 1)
        var theirsOwn = ourOwn
        theirsOwn.motion = MotionToken.cycling          // ours already set → ours wins
        let peerDoc = PlayHistoryStore.Document(installId: "peer", events: [theirsShared, theirsOwn])
        try JSONEncoder().encode(peerDoc).write(to: url)

        store.reloadFromDisk()
        XCTAssertEqual(store.events.first { $0.id == shared.id }?.motion, "running")
        XCTAssertNotNil(store.events.first { $0.id == shared.id }?.pocketRun)
        XCTAssertEqual(store.events.first { $0.id == ourOwn.id }?.motion, "walking", "first writer wins")
    }

    // MARK: - Mode derivation + clock (shared value types)

    func testModePrecedence() {
        let trip = ListeningContextTag.trip("trp_1", origin: "plc_a", destination: "plc_b")
        // CarPlay beats everything, even running + a trip + Mix.
        XCTAssertEqual(PocketMode.derive(source: .mix, carPlay: true, motion: "running", context: trip), .carPlay)
        XCTAssertEqual(PocketMode.derive(source: .mix, carPlay: false, motion: "running", context: trip), .running)
        XCTAssertEqual(PocketMode.derive(source: .playlist, carPlay: nil, motion: "walking", context: nil), .walking)
        XCTAssertEqual(PocketMode.derive(source: .mix, carPlay: nil, motion: nil, context: trip), .trip)
        XCTAssertEqual(PocketMode.derive(source: .playlist, carPlay: nil, motion: "automotive", context: nil), .trip)
        XCTAssertEqual(PocketMode.derive(source: .playlist, carPlay: nil, motion: "cycling", context: nil), .trip,
                       "cycling folds into Trip (W6)")
        XCTAssertEqual(PocketMode.derive(source: .mix, carPlay: nil, motion: "stationary", context: nil), .mix)
        XCTAssertEqual(PocketMode.derive(source: .browser, carPlay: nil, motion: nil, context: nil), .browse)
        XCTAssertEqual(PocketMode.derive(source: .album, carPlay: nil, motion: nil, context: nil), .browse)
        XCTAssertEqual(PocketMode.derive(source: .artist, carPlay: nil, motion: nil, context: nil), .browse)
        XCTAssertEqual(PocketMode.derive(source: .pocket, carPlay: nil, motion: nil, context: .none), .collection)
        XCTAssertEqual(PocketMode.derive(source: .setlist, carPlay: false, motion: nil, context: nil), .collection)
        XCTAssertNil(PocketMode.derive(source: .game, carPlay: true, motion: "running", context: nil), "games excluded")
        XCTAssertEqual(PocketMode.collection.label, "Home")
    }

    func testMomentKeyTokenRoundTrip() {
        let k = PocketMomentKey(hour: 8, dow: 2, mode: .carPlay)
        XCTAssertEqual(k.token, "h08|d2|carPlay")
        XCTAssertEqual(PocketMomentKey(token: k.token), k)
        XCTAssertNil(PocketMomentKey(token: "h25|d2|carPlay"))
        XCTAssertNil(PocketMomentKey(token: "garbage"))
        XCTAssertEqual(k.shortLabel, "Tue 8 AM · CarPlay")
        XCTAssertEqual(PocketMomentKey.hourLabel(0), "12 AM")
        XCTAssertEqual(PocketMomentKey.hourLabel(12), "12 PM")
        XCTAssertEqual(PocketMomentKey.hourLabel(23), "11 PM")
    }

    func testClockLocalHourAndISOWeekday() {
        // 2026-10-27T15:30:00Z is a Tuesday. At UTC−7 that is 08:30 Tuesday.
        let ms = 1_793_115_000_000.0
        let utc = PocketClock.local(atMs: ms, tzOffsetMin: 0)
        XCTAssertEqual(utc.hour, 15)
        XCTAssertEqual(utc.dow, 2)
        let pdt = PocketClock.local(atMs: ms, tzOffsetMin: -420)
        XCTAssertEqual(pdt.hour, 8)
        XCTAssertEqual(pdt.dow, 2)
        XCTAssertEqual(pdt.fractionalHour, 8.5, accuracy: 1e-9)
        // Crossing midnight backwards changes the weekday: 03:00Z Tue at UTC−7 = 20:00 Monday.
        let lateMon = PocketClock.local(atMs: ms - 12.5 * 3_600_000, tzOffsetMin: -420)
        XCTAssertEqual(lateMon.hour, 20)
        XCTAssertEqual(lateMon.dow, 1)
        XCTAssertEqual(PocketClock.local(atMs: 0, tzOffsetMin: 0).dow, 4, "1970-01-01 was a Thursday")
    }

    func testRunTagRoundTrip() {
        let id = UUID()
        XCTAssertEqual(PocketWheelIds.runId(fromTag: PocketWheelIds.runTag(id)), id)
        XCTAssertNil(PocketWheelIds.runId(fromTag: "itp_\(id.uuidString)"))
        XCTAssertNil(PocketWheelIds.runId(fromTag: nil))
    }
}
