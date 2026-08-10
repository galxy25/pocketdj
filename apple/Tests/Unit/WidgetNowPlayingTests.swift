import XCTest
@testable import PocketDJ

/// The app↔widget bridge. The widget process can't read the app's live stores, so the app
/// publishes a `NowPlayingSnapshot` into the shared App Group and the widget's transport
/// buttons route back through `WidgetPlaybackController` (in-process) or the command channel
/// (app quit). These tests cover the codec + the routing without needing a real widget host.
@MainActor
final class WidgetNowPlayingTests: XCTestCase {
    override func tearDown() {
        // Don't leak wired closures across tests.
        WidgetPlaybackController.shared.toggle = nil
        WidgetPlaybackController.shared.next = nil
        WidgetPlaybackController.shared.previous = nil
        WidgetPlaybackController.shared.toggleFavorite = nil
        WidgetPlaybackController.shared.cycleRepeat = nil
        WidgetPlaybackController.shared.toggleShuffle = nil
        super.tearDown()
    }

    // MARK: Snapshot codec

    func testSnapshotRoundTrips() throws {
        let snap = NowPlayingSnapshot(
            isPlaying: true, hasContent: true, title: "Title", artist: "Artist",
            songId: "sng_1", coverVersion: 3,
            upNext: [.init(id: "u1", songId: "sng_2", title: "Two", artist: "A"),
                     .init(id: "u2", songId: "sng_3", title: "Three", artist: "B")])
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        XCTAssertEqual(snap, back)
        XCTAssertEqual(back.upNext.count, 2)
        XCTAssertEqual(back.upNext.first?.title, "Two")
    }

    func testEmptySnapshotIsIdle() {
        XCTAssertFalse(NowPlayingSnapshot.empty.hasContent)
        XCTAssertFalse(NowPlayingSnapshot.empty.isPlaying)
        XCTAssertTrue(NowPlayingSnapshot.empty.upNext.isEmpty)
        XCTAssertFalse(NowPlayingSnapshot.empty.isFavorite)
        XCTAssertNil(NowPlayingSnapshot.empty.appleMusicId)
        XCTAssertEqual(NowPlayingSnapshot.empty.repeatMode, "off")
        XCTAssertFalse(NowPlayingSnapshot.empty.shuffleEnabled)
    }

    func testSnapshotRoundTripsRepeatShuffleFields() throws {
        let snap = NowPlayingSnapshot(
            isPlaying: true, hasContent: true, title: "T", artist: "A",
            songId: "sng_1", coverVersion: 1, upNext: [],
            isFavorite: false, appleMusicId: nil,
            repeatMode: "one", shuffleEnabled: true)
        let back = try JSONDecoder().decode(NowPlayingSnapshot.self,
                                            from: try JSONEncoder().encode(snap))
        XCTAssertEqual(snap, back)
        XCTAssertEqual(back.repeatMode, "one")
        XCTAssertTrue(back.shuffleEnabled)
    }

    /// A blob from an app build that predates repeat/shuffle still decodes (missing → "off"/false),
    /// so a stale snapshot never fail-decodes to `.empty`.
    func testOldFormatBlobWithoutRepeatShuffleDecodes() throws {
        let json = """
        {"isPlaying":true,"hasContent":true,"title":"Old","artist":"B","coverVersion":1,"upNext":[]}
        """
        let snap = try JSONDecoder().decode(NowPlayingSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snap.hasContent)
        XCTAssertEqual(snap.repeatMode, "off")
        XCTAssertFalse(snap.shuffleEnabled)
    }

    func testSnapshotRoundTripsFavoriteFields() throws {
        let snap = NowPlayingSnapshot(
            isPlaying: false, hasContent: true, title: "T", artist: "A",
            songId: "sng_9", coverVersion: 1, upNext: [],
            isFavorite: true, appleMusicId: "am_9")
        let back = try JSONDecoder().decode(NowPlayingSnapshot.self,
                                            from: try JSONEncoder().encode(snap))
        XCTAssertEqual(snap, back)
        XCTAssertTrue(back.isFavorite)
        XCTAssertEqual(back.appleMusicId, "am_9")
    }

    /// A blob written by an OLD app build that predates `isFavorite` / `appleMusicId` MUST still
    /// decode (missing keys tolerated) — otherwise a stale snapshot fails to `.empty` and the
    /// widget flashes "Nothing playing" until the updated app republishes.
    func testOldFormatBlobWithoutNewKeysDecodes() throws {
        let json = """
        {"isPlaying":true,"hasContent":true,"title":"Old","artist":"Build","coverVersion":2,"upNext":[]}
        """
        let snap = try JSONDecoder().decode(NowPlayingSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snap.hasContent)                 // decoded, not fail-decoded to .empty
        XCTAssertEqual(snap.title, "Old")
        XCTAssertFalse(snap.isFavorite)                // missing → false
        XCTAssertNil(snap.appleMusicId)                // missing → nil
        XCTAssertNil(snap.songId)                      // absent optional → nil
    }

    // MARK: In-process transport routing (widget button → live playback)

    func testTransportIntentsRouteToController() async throws {
        var toggled = 0, nexted = 0, prevved = 0
        WidgetPlaybackController.shared.toggle = { toggled += 1 }
        WidgetPlaybackController.shared.next = { nexted += 1 }
        WidgetPlaybackController.shared.previous = { prevved += 1 }

        _ = try await NowPlayingToggleIntent().perform()
        _ = try await NowPlayingNextIntent().perform()
        _ = try await NowPlayingPreviousIntent().perform()

        XCTAssertEqual(toggled, 1, "toggle intent hit the toggle closure")
        XCTAssertEqual(nexted, 1, "next intent hit the next closure")
        XCTAssertEqual(prevved, 1, "previous intent hit the previous closure")
    }

    func testFavoriteIntentRoutesToController() async throws {
        var favorited = 0
        WidgetPlaybackController.shared.toggleFavorite = { favorited += 1 }
        _ = try await NowPlayingFavoriteIntent().perform()
        XCTAssertEqual(favorited, 1, "favorite intent hit the toggleFavorite closure")
    }

    func testRepeatShuffleIntentsRouteToController() async throws {
        var repeats = 0, shuffles = 0
        WidgetPlaybackController.shared.cycleRepeat = { repeats += 1 }
        WidgetPlaybackController.shared.toggleShuffle = { shuffles += 1 }
        _ = try await NowPlayingRepeatIntent().perform()
        _ = try await NowPlayingShuffleIntent().perform()
        XCTAssertEqual(repeats, 1, "repeat intent hit the cycleRepeat closure")
        XCTAssertEqual(shuffles, 1, "shuffle intent hit the toggleShuffle closure")
    }

    /// When no in-process handler is wired (app quit), the intent must NOT crash — it silently
    /// falls back to the command channel (which no-ops if the App Group is unavailable in-sim).
    func testTransportIntentWithoutControllerDoesNotCrash() async throws {
        WidgetPlaybackController.shared.toggle = nil
        _ = try await NowPlayingToggleIntent().perform()   // fallback path — must not throw/crash
    }

    // MARK: Command channel (only when the shared App Group is reachable)

    func testCommandChannelRoundTripsWhenGroupAvailable() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        _ = WidgetCommandChannel.drain(now: Date().timeIntervalSince1970)   // start clean
        WidgetCommandChannel.send(.next)
        // Fresh command drains once; a second drain is empty.
        XCTAssertEqual(WidgetCommandChannel.drain(now: Date().timeIntervalSince1970).map(\.command),
                       [.next])
        XCTAssertTrue(WidgetCommandChannel.drain(now: Date().timeIntervalSince1970).isEmpty)
    }

    func testCommandChannelDropsStaleCommand() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        _ = WidgetCommandChannel.drain(now: Date().timeIntervalSince1970)
        WidgetCommandChannel.send(.toggle)
        // A drain far in the future exceeds maxAge → the stale command is discarded, so a cold
        // launch long after the tap does not jolt playback.
        XCTAssertTrue(WidgetCommandChannel.drain(now: Date().timeIntervalSince1970 + 120).isEmpty)
    }

    func testCommandChannelFavoriteRoundTrips() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        _ = WidgetCommandChannel.drain(now: Date().timeIntervalSince1970)
        WidgetCommandChannel.send(.favorite)
        XCTAssertEqual(WidgetCommandChannel.drain(now: Date().timeIntervalSince1970).map(\.command),
                       [.favorite])
        XCTAssertTrue(WidgetCommandChannel.drain(now: Date().timeIntervalSince1970).isEmpty)
    }

    // MARK: The tuning loop's cold path (app quit → widget process → App Group → next wake)

    /// A SECOND TAP MUST NOT ERASE THE FIRST.
    ///
    /// The channel used to be one slot: `send` overwrote it, so thumbs-down followed by ⏭ lost the
    /// thumbs-down. For a transport command that is survivable — the listener sees nothing happen
    /// and taps again. For a LEARNING signal it is not: the glyph filled, the listener believes the
    /// engine heard them, and it never did.
    func testTheChannelIsAQueueSoOneTapCannotEraseAnother() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        let now = Date().timeIntervalSince1970
        _ = WidgetCommandChannel.drain(now: now)

        WidgetCommandChannel.sendVerdict(songId: "s1", scope: "zone", verdict: "rejected", now: now)
        WidgetCommandChannel.send(.next, now: now)
        WidgetCommandChannel.sendVerdict(songId: "s2", scope: "zone", verdict: "accepted", now: now)

        let drained = WidgetCommandChannel.drain(now: now)
        XCTAssertEqual(drained.count, 3, "all three survived, in order")
        XCTAssertEqual(drained[0].songId, "s1")
        XCTAssertEqual(drained[0].verdict, "rejected")
        XCTAssertEqual(drained[1].command, .next)
        XCTAssertEqual(drained[2].songId, "s2")
        XCTAssertTrue(WidgetCommandChannel.drain(now: now).isEmpty, "drain clears")
    }

    /// A VERDICT NAMES ITS OWN TARGET AND NEVER GOES STALE.
    ///
    /// Two defects in one test. Applying a queued verdict to "whatever is playing at drain time"
    /// files it against the WRONG SONG — and after a cold launch the app cannot even resolve which
    /// tile the track came from, so it used to be dropped outright. And a 30-second expiry loses a
    /// judgement tapped on the lock screen just before the phone went into a pocket.
    func testAQueuedVerdictCarriesItsSongAndScopeAndDoesNotExpire() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        let tapped = Date().timeIntervalSince1970
        _ = WidgetCommandChannel.drain(now: tapped)

        WidgetCommandChannel.sendVerdict(songId: "the-song", scope: "pkt_house",
                                         verdict: "rejected", now: tapped)
        // Drained an HOUR later, long past the transport max age.
        let drained = WidgetCommandChannel.drain(now: tapped + 3600)
        XCTAssertEqual(drained.count, 1, "a learning signal is never discarded for being old")
        XCTAssertEqual(drained[0].kind, WidgetCommandChannel.verdictKind)
        XCTAssertEqual(drained[0].songId, "the-song", "…and it still names the song it was about")
        XCTAssertEqual(drained[0].scope, "pkt_house", "…and the list it belongs to")
        XCTAssertEqual(drained[0].at, tapped, accuracy: 0.001,
                       "the TAP time rides along, so latest-wins merges resolve correctly")
    }

    /// A verdict with no scope is refused at the door — there is no honest list to file it against,
    /// and inventing one would file it against a tile the listener never opened.
    func testAVerdictWithNoScopeIsNotQueued() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        let now = Date().timeIntervalSince1970
        _ = WidgetCommandChannel.drain(now: now)
        WidgetCommandChannel.sendVerdict(songId: "s", scope: "", verdict: "rejected", now: now)
        WidgetCommandChannel.sendVerdict(songId: "", scope: "zone", verdict: "rejected", now: now)
        XCTAssertTrue(WidgetCommandChannel.drain(now: now).isEmpty)
    }

    // MARK: WidgetSync ♥ wiring (widget button → favorites store → snapshot)

    private struct SyncHarness {
        let sync: WidgetSync
        let seq: SetlistPlayer
        let favorites: FavoritesStore
    }

    /// Build a real `WidgetSync` over an offline sequencer + an isolated `FavoritesStore`, with an
    /// Apple-Music-id resolver that maps `"a" → "am_a"` (everything else local-only). Mirrors
    /// `NowPlayingQueueTests.makeSequencer`.
    private func makeSyncHarness() -> SyncHarness {
        let config = URLSessionConfiguration.ephemeral
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: config))
        let burnURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-wsync-burns-\(UUID().uuidString).json")
        let favURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-wsync-fav-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: burnURL)
            try? FileManager.default.removeItem(at: favURL)
        }
        let burns = BurnStore(rips: rips, fileURL: burnURL)
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let favorites = FavoritesStore(fileURL: favURL)
        let sync = WidgetSync(setlist: seq, player: player, rips: rips, coordinator: coord,
                              artCandidates: { _ in [] }, favorites: favorites,
                              appleMusicId: { $0 == "a" ? "am_a" : nil })
        return SyncHarness(sync: sync, seq: seq, favorites: favorites)
    }

    private func item(_ id: String) -> SetlistPlayer.Item { .init(id: id, title: id.uppercased(), artist: "A") }

    /// The widget's ♥ closure flips the CURRENT track's favorite in the store, carrying the
    /// resolved Apple Music id — the single call `FavoritesStore.toggle` needs for the push.
    func testWidgetToggleFavoriteFlipsCurrentTrack() {
        let h = makeSyncHarness()
        h.seq.play([item("a"), item("b")], sourceSetlistId: "set_1")   // current = "a"
        XCTAssertFalse(h.favorites.isFavorite("a"))

        WidgetPlaybackController.shared.toggleFavorite?()               // the widget ♥ tap
        XCTAssertTrue(h.favorites.isFavorite("a"))
        XCTAssertEqual(h.favorites.entry("a")?.appleMusicId, "am_a")    // resolver captured

        WidgetPlaybackController.shared.toggleFavorite?()               // tap again un-favorites
        XCTAssertFalse(h.favorites.isFavorite("a"))
        h.seq.stop()
    }

    /// App-was-quit path: with no live deck restored yet, the ♥ falls back to the snapshot the
    /// widget was actually showing (persisted in the App Group) — including its Apple Music id —
    /// instead of silently dropping the tap.
    func testWidgetToggleFavoriteFallsBackToSnapshotWhenQuit() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group unavailable in this run")
        let h = makeSyncHarness()                      // seq idle, rips/AM empty ⇒ currentBase().songId == nil
        var snap = NowPlayingSnapshot.empty
        snap.title = "Z"; snap.songId = "z"; snap.appleMusicId = "am_z"
        NowPlayingShared.write(snap)                   // what the widget last displayed
        defer { NowPlayingShared.write(.empty) }

        XCTAssertFalse(h.favorites.isFavorite("z"))
        WidgetPlaybackController.shared.toggleFavorite?()               // resolver returns nil for "z" ⇒ uses snapshot id
        XCTAssertTrue(h.favorites.isFavorite("z"))
        XCTAssertEqual(h.favorites.entry("z")?.appleMusicId, "am_z")   // snapshot's catalog id carried through
        h.seq.stop()
    }

    /// With the current track already favorited, a fresh `WidgetSync` publishes a snapshot whose
    /// `isFavorite`/`appleMusicId` reflect the store (its `init` publishes synchronously).
    func testPublishReflectsFavoriteState() throws {
        try XCTSkipIf(NowPlayingShared.defaults == nil, "App Group not provisioned in this run")
        let h = makeSyncHarness()
        h.seq.play([item("a"), item("b")], sourceSetlistId: "set_1")   // current = "a"
        h.favorites.toggle("a", appleMusicId: "am_a")

        // A second WidgetSync over the SAME (now-favorited) state writes the snapshot in init.
        _ = WidgetSync(setlist: h.seq, player: PlayerEngine(), rips: RipsStore(),
                       coordinator: PlaybackCoordinator(
                        ripProvider: RipServerPlaybackProvider(rips: RipsStore(), player: PlayerEngine()),
                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider())),
                       artCandidates: { _ in [] }, favorites: h.favorites,
                       appleMusicId: { $0 == "a" ? "am_a" : nil })
        let snap = NowPlayingShared.read()
        XCTAssertTrue(snap.isFavorite)
        XCTAssertEqual(snap.appleMusicId, "am_a")
        h.seq.stop()
    }
}
