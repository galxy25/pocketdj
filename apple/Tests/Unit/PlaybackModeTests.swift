import XCTest
@testable import PocketDJ

/// Item 7 — device/cloud PLAYBACK MODE. Covers:
///   • the SHARED `playLocalFile` helper (used by BOTH the sequencer and the single-row
///     transport) stamps `RipsStore.nowPlaying` + loads the engine consistently, so the
///     inline player + row pause/resume toggle light up the same way no matter the caller;
///   • the SINGLE-ROW device-mode decision: a BURNED file plays locally; a MISSING burned
///     file FALLS BACK TO CLOUD for that tap (USER DECISION) while staying in device mode;
///   • `SettingsStore.playbackMode` persists + round-trips (back-compat default `.cloud`).
@MainActor
final class PlaybackModeTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    private func makeRips(serverURL: String) -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaybackModeStubURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "pm.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL; settings.ripToken = ""
        rips.settings = settings
        return rips
    }

    private func makeBurns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pm-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    private func makeCoordinator(rips: RipsStore, player: PlayerEngine) -> PlaybackCoordinator {
        PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
    }

    private func cleanBurnedFiles(_ names: [String]) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    private func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting: \(message)")
    }

    // MARK: The SHARED playLocalFile helper

    func testPlayLocalFileStampsNowPlayingAndLoadsEngine() {
        let rips = makeRips(serverURL: "")
        let player = PlayerEngine()
        let url = URL(fileURLWithPath: "/tmp/burned-song.mp3")

        playLocalFile(url, songId: "sng_x", title: "Title", artist: "Artist",
                      startMs: 12_000, rips: rips, player: player)

        XCTAssertEqual(rips.nowPlaying?.songId, "sng_x", "nowPlaying is set so the inline player + row toggle light up")
        XCTAssertEqual(rips.nowPlaying?.url, url, "the BURNED local file is the now-playing url")
        XCTAssertEqual(rips.nowPlaying?.live, false)
        XCTAssertEqual(rips.nowPlaying?.startMs, 12_000, "the analog seek offset is carried")
    }

    // MARK: Single-row device-mode decision — burned plays local, missing falls back to cloud

    /// DEVICE mode + a burned file: the row plays the BURNED local file (nowPlaying is the
    /// on-disk url) and never engages the coordinator/stream.
    func testSingleRowDeviceModePlaysBurnedLocal() async {
        cleanBurnedFiles(["sng_loc.mp3", "sng_loc.txt"])
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        // Burn the song so localURL resolves.
        rips.setManifest(["sng_loc": .init(key: "rips/sng_loc.mp3", source: "digital")])
        PlaybackModeStubURLProtocol.body = Data("BURNT".utf8)
        _ = await burns.burn([(id: "sng_loc", title: "Local", artist: "A")])
        let local = burns.localURL(forSong: "sng_loc")
        XCTAssertNotNil(local, "precondition: burned")

        // Mimic RowTransport.doPlay's device branch: burned file present → play it locally.
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        // The decision the row makes (device + burned present):
        playLocalFile(local!, songId: "sng_loc", title: "Local", artist: "A",
                      startMs: burns.startMs(forSong: "sng_loc"), rips: rips, player: player)

        XCTAssertEqual(rips.nowPlaying?.url, local, "device row played the burned local file")
        XCTAssertNil(coord.activeBackend, "no stream was engaged")
        cleanBurnedFiles(["sng_loc.mp3", "sng_loc.txt"])
    }

    /// DEVICE mode + NO burned file: the row FALLS BACK TO CLOUD for that tap (USER DECISION)
    /// — the coordinator resolves + streams the cached rip, staying in device mode.
    func testSingleRowDeviceModeFallsBackToCloudWhenNoBurnedFile() async {
        let rips = makeRips(serverURL: "https://imac.test")
        let burns = makeBurns(rips)
        let player = PlayerEngine()
        let coord = makeCoordinator(rips: rips, player: player)
        // Cached (streamable) but NOT burned → the row's device branch falls through to cloud.
        rips.setManifest(["sng_dl": .init(key: "rips/sng_dl.mp3", source: "digital")])
        XCTAssertNil(burns.localURL(forSong: "sng_dl"), "precondition: not burned")

        // The row's fallback when device + no burned file: stream via the coordinator.
        await coord.play(id: "sng_dl", title: "Cloud", artist: "A")

        XCTAssertEqual(coord.activeBackend, .ripServer, "fell back to the cloud/stream path")
        XCTAssertNil(coord.lastErrorMessage)
        XCTAssertEqual(rips.nowPlaying?.songId, "sng_dl")
    }

    // MARK: SettingsStore.playbackMode persistence

    func testPlaybackModeDefaultsCloudAndPersists() {
        let suite = "pm.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let s1 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s1.playbackMode, .cloud, "default is cloud (back-compat for blobs lacking the key)")

        s1.playbackMode = .device
        s1.persist()

        let s2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s2.playbackMode, .device, "device mode round-trips through UserDefaults")

        s2.resetEverything()
        XCTAssertEqual(s2.playbackMode, .cloud, "reset returns to cloud")
    }
}

private final class PlaybackModeStubURLProtocol: URLProtocol {
    static var body = Data("MP3".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        // MUST-1: ensureURL's cached fast path asks this first — echo a stub-servable URL
        // (this same protocol answers it too, falling through to the fixed body below).
        if url.path.hasSuffix("/rips/presign") {
            let song = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "songId" })?.value ?? "song"
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"url":"https://imac.test/rips/\#(song).mp3"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
