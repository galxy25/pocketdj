import XCTest
@testable import PocketDJ

/// Feature 3 — Setlist PLAY ALL. `SetlistPlayer` sequences a setlist's tracks in order,
/// choosing the SOURCE per track: a BURNT local file (`BurnStore.localURL`) is played
/// directly through the shared `PlayerEngine`; otherwise the track STREAMS via the
/// `PlaybackCoordinator` (cached rip → S3 mp3 here). It AUTO-ADVANCES on the engine's
/// `onTrackEnded` hook and SKIPS an unplayable track (coordinator error) immediately.
///
/// These tests use the real (final) `PlayerEngine` / `PlaybackCoordinator` /
/// `RipServerPlaybackProvider` wired to a `RipsStore` whose manifest + `URLProtocol` stub
/// make the rip path resolve deterministically offline, plus a real `BurnStore` that has
/// actually burned a file (so `localURL` returns it). `sourceOfSong` is left at its nil
/// default, so the coordinator only ever uses the rip-server provider — no Apple Music
/// authorization is involved. The engine's natural end is simulated by invoking its public
/// `onTrackEnded` hook (the same callback `.AVPlayerItemDidPlayToEndTime` fires).
@MainActor
final class SetlistPlayerTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    // MARK: Fixtures

    private func makeRips(serverURL: String = "") -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SetlistStubURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL
        settings.ripToken = ""
        rips.settings = settings
        return rips
    }

    private func makeBurns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-setlistburn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    private func makeCoordinator(rips: RipsStore, player: PlayerEngine) -> PlaybackCoordinator {
        let am = AppleMusicPlaybackProvider(provider: AppleMusicProvider())
        return PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: am)
        // sourceOfSong defaults to { _ in nil } → Apple Music is never first → rip-only.
    }

    private func cleanBurnedFiles(_ names: [String]) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    /// Actually burn `songId` so `BurnStore.localURL(forSong:)` returns a real on-disk file.
    private func burn(_ rips: RipsStore, _ burns: BurnStore, songId: String) async {
        rips.setManifest([songId: .init(key: "rips/\(songId).mp3", source: "digital")])
        SetlistStubURLProtocol.body = Data("BURNT-MP3".utf8)
        _ = await burns.burn([(id: songId, title: songId, artist: "A")])
        XCTAssertNotNil(burns.localURL(forSong: songId), "precondition: \(songId) is burned")
    }

    /// Poll the main actor until `predicate` holds or a short timeout elapses — used to await
    /// `SetlistPlayer`'s fire-and-forget `Task { await playCurrent() }` (no awaitable handle).
    private func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms
        }
        XCTFail("timed out waiting: \(message)")
    }

    // MARK: Empty list is a no-op

    func testPlayEmptyIsNoOp() {
        let rips = makeRips(); let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([])
        XCTAssertFalse(seq.isRunning)
        XCTAssertTrue(seq.queue.isEmpty)
    }

    // MARK: Burnt local file WINS over streaming

    /// A track with a burnt local file plays that file directly through the `PlayerEngine`
    /// (nowPlaying.url == the burnt file, NOT live) and never engages the coordinator
    /// (activeBackend stays nil — the streaming path was not taken).
    func testPicksBurntLocalFileOverStreaming() async {
        cleanBurnedFiles(["sng_b.mp3", "sng_b.txt"])
        // Server configured so streaming WOULD work — proving the burnt file is preferred.
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_b")
        let local = burns.localURL(forSong: "sng_b")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "sng_b", title: "Burned", artist: "A")])

        await waitUntil("burnt file becomes now-playing") { rips.nowPlaying?.songId == "sng_b" }
        XCTAssertTrue(seq.isRunning)
        XCTAssertEqual(rips.nowPlaying?.url, local, "the BURNT local file is played, not a stream")
        XCTAssertEqual(rips.nowPlaying?.live, false)
        XCTAssertNil(coord.activeBackend, "the coordinator/stream path was NOT engaged")
        seq.stop()
        cleanBurnedFiles(["sng_b.mp3", "sng_b.txt"])
    }

    // MARK: Streams via the coordinator when there's no burnt file

    /// A track with NO burnt file but a cached rip streams via the coordinator: the rip
    /// provider wins (activeBackend == .ripServer), no error is surfaced, and now-playing is
    /// the cached S3 mp3 (not live).
    func testStreamsViaCoordinatorWhenNoBurntFile() async {
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        // Cached (in the manifest) but NOT burned → the coordinator resolves the S3 mp3.
        rips.setManifest(["sng_s": .init(key: "rips/sng_s.mp3", source: "digital")])
        XCTAssertNil(burns.localURL(forSong: "sng_s"), "precondition: not burned")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "sng_s", title: "Streamed", artist: "A")])

        await waitUntil("coordinator backend becomes active") { coord.activeBackend == .ripServer }
        XCTAssertNil(coord.lastErrorMessage, "a resolvable stream surfaces no error")
        XCTAssertEqual(rips.nowPlaying?.songId, "sng_s")
        XCTAssertEqual(rips.nowPlaying?.url.absoluteString, "https://rips.test/rips/sng_s.mp3")
        XCTAssertEqual(rips.nowPlaying?.live, false)
        seq.stop()
    }

    // MARK: AUTO-ADVANCE on the engine's natural end

    /// When the current (burnt) track ends, the engine's `onTrackEnded` hook fires and the
    /// sequencer advances to the next queued track.
    func testAutoAdvancesOnTrackEnded() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_1")
        await burn(rips, burns, songId: "sng_2")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_1", title: "One", artist: "A"),
            .init(id: "sng_2", title: "Two", artist: "A"),
        ])

        await waitUntil("track 0 playing") { rips.nowPlaying?.songId == "sng_1" }
        XCTAssertEqual(seq.index, 0)

        // Simulate the finite item playing to its natural end (the same callback
        // .AVPlayerItemDidPlayToEndTime invokes). The sequencer must advance to track 1.
        player.onTrackEnded?()
        await waitUntil("auto-advanced to track 1") { rips.nowPlaying?.songId == "sng_2" }
        XCTAssertEqual(seq.index, 1)
        XCTAssertTrue(seq.isRunning)

        // Ending the LAST track stops the sequence cleanly.
        player.onTrackEnded?()
        await waitUntil("sequence stops at the end") { !seq.isRunning }
        XCTAssertNil(rips.nowPlaying, "now-playing cleared when the set finishes")
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt", "sng_2.mp3", "sng_2.txt"])
    }

    // MARK: SKIP an unplayable track

    /// An unplayable track (no burnt file, not cached, no rip server → the coordinator
    /// surfaces an error and no end event will ever fire) is SKIPPED immediately, so the
    /// next (playable, burnt) track plays without manual intervention.
    func testSkipsUnplayableTrackAndPlaysNext() async {
        cleanBurnedFiles(["sng_ok.mp3", "sng_ok.txt"])
        // No rip server → an un-burned, un-cached track can't be streamed (rips.play throws).
        let rips = makeRips(serverURL: "")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        // Burn ONLY the second track; the first is unplayable.
        await burn(rips, burns, songId: "sng_ok")
        // burn() set the manifest to just sng_ok; sng_dead is neither burned nor cached.
        XCTAssertNil(burns.localURL(forSong: "sng_dead"))
        XCTAssertNil(rips.cachedURL("sng_dead"))

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([
            .init(id: "sng_dead", title: "Dead", artist: "A"),
            .init(id: "sng_ok", title: "OK", artist: "A"),
        ])

        // The dead track is skipped; the burnt track becomes now-playing at index 1.
        await waitUntil("skipped to the playable burnt track") { rips.nowPlaying?.songId == "sng_ok" }
        XCTAssertEqual(seq.index, 1, "advanced past the unplayable track")
        XCTAssertEqual(rips.nowPlaying?.url, burns.localURL(forSong: "sng_ok"))
        XCTAssertTrue(seq.isRunning)
        seq.stop()
        cleanBurnedFiles(["sng_ok.mp3", "sng_ok.txt"])
    }

    // MARK: stop() tears down and resets

    func testStopResetsSequenceAndNowPlaying() async {
        cleanBurnedFiles(["sng_z.mp3", "sng_z.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        await burn(rips, burns, songId: "sng_z")

        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        seq.play([.init(id: "sng_z", title: "Z", artist: "A")])
        await waitUntil("playing") { rips.nowPlaying?.songId == "sng_z" }

        seq.stop()
        XCTAssertFalse(seq.isRunning)
        XCTAssertTrue(seq.queue.isEmpty)
        XCTAssertEqual(seq.index, 0)
        XCTAssertNil(rips.nowPlaying, "now-playing cleared on stop")
        cleanBurnedFiles(["sng_z.mp3", "sng_z.txt"])
    }
}

/// Minimal `URLProtocol` serving HTTP 200 + a fixed body (the durable mp3 bytes for the
/// burn download, and any rip-server fetch in these tests resolves to a cached S3 mp3 that
/// is never actually loaded by AVPlayer in a headless unit run).
private final class SetlistStubURLProtocol: URLProtocol {
    static var body = Data("MP3-DATA".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
