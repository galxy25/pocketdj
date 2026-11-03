import XCTest
@testable import PocketDJ

/// np-mix-mode PHASE 4 — Apple Music rows (the pure + wiring half; the sequencer / DSP hand-off
/// half lives in `NPMixGrowingFileTests`, which owns the real-DSP rig).
///
///  • The plan's `rips` (step 0): OWNER ONLY, the first 2 Apple-Music-only rows past the playing
///    one, never with Mix Mode off / offline / cellular-off; a non-owner never gets one.
///  • Mix Mode stemify: owner only, ripped window rows with no stems, deduped per song id.
///  • The executor: a rip is asked for once per song id (retry only after `ripRetrySeconds`).
///  • The production seam: a non-owner never POSTs /rip; the owner's request is a PLAYBACK rip
///    (the rip-ahead window gate applies).
///  • Provider order: `preferLocalAudio` puts the rip first for an AM-sourced row ONLY when its
///    rip starts without a round trip (presign in hand) — an un-ripped / un-presigned row stays
///    Apple-Music-first (no dead-air regression), and `am:` catalog ids never go rip-first.
///  • The indicator: `.ripping` / `.readyFromAppleMusic` / AM buffering.
@MainActor
final class NPMixAppleMusicTests: XCTestCase {
    private typealias Track = NowPlayingPrefetcher.Track

    override func tearDown() {
        NowPlayingPrefetcher.ripRetrySeconds = 600
        NowPlayingPrefetcher.ripAhead = 2
        RipPostStub.reset()
        super.tearDown()
    }

    private func t(_ id: String, _ source: Track.Source = .ripped, local: Bool = false,
                   fetchable: Bool? = nil, stems: Set<String> = [], remote: Bool = true) -> Track {
        .init(songId: id, audioId: id, title: id, artist: "A", songLocal: local,
              songFetchable: fetchable ?? (source == .ripped),
              stemsLocal: stems, stemsRemote: remote, source: source)
    }

    private func input(current: Track?, upcoming: [Track], mix: Bool = true, owner: Bool = true,
                       net: NowPlayingPrefetcher.Network = .unmetered, window: Int = 3,
                       cellular: NPMixCellularPolicy = .nextSong) -> NowPlayingPrefetchInput {
        NowPlayingPrefetchInput(current: current, upcoming: upcoming, stemLock: StemLockState(),
                                mixMode: NPMixModeState(enabled: mix), network: net, window: window,
                                stemLockWindow: 3, cellular: cellular, isCatalogOwner: owner)
    }

    // MARK: - Plan: rips (step 0)

    func testOwnerRipsTheFirstTwoAppleMusicOnlyRowsAhead() {
        let ups = [t("x", .appleMusicOnly), t("b"), t("y", .appleMusicOnly), t("z", .appleMusicOnly)]
        let p = NowPlayingPrefetcher.plan(input(current: t("a"), upcoming: ups))
        XCTAssertEqual(p.rips, ["x", "y"], "the first two AM-only rows, in play order — never more")
        XCTAssertFalse(p.steps.contains { $0.songId == "x" || $0.songId == "y" }, "nothing to download until they land")
    }

    /// App Store 5.2.3 line: a hybrid / public install NEVER asks for a rip (nor stem separation).
    func testNonOwnerNeverRipsAndNeverStemifies() {
        let ups = [t("x", .appleMusicOnly), t("b", remote: false), t("y", .appleMusicOnly)]
        let p = NowPlayingPrefetcher.plan(input(current: t("a", remote: false), upcoming: ups, owner: false))
        XCTAssertTrue(p.rips.isEmpty)
        XCTAssertTrue(p.stemify.isEmpty)
    }

    func testNoRipsWithMixModeOffOfflineOrCellularOff() {
        let ups = [t("x", .appleMusicOnly), t("y", .appleMusicOnly)]
        XCTAssertTrue(NowPlayingPrefetcher.plan(input(current: t("a"), upcoming: ups, mix: false)).rips.isEmpty)
        XCTAssertTrue(NowPlayingPrefetcher.plan(input(current: t("a"), upcoming: ups, net: .offline)).rips.isEmpty)
        XCTAssertTrue(NowPlayingPrefetcher.plan(input(current: t("a"), upcoming: ups, net: .expensive, cellular: .off)).rips.isEmpty)
    }

    /// A narrow (cellular) window still looks 2 rows deep for rips — a server capture costs this
    /// device no data — but never beyond the first two AM-only rows.
    func testCellularStillRipsTwoRowsDeepButNotFurther() {
        let ups = [t("x", .appleMusicOnly), t("y", .appleMusicOnly), t("z", .appleMusicOnly)]
        let p = NowPlayingPrefetcher.plan(input(current: t("a"), upcoming: ups, net: .expensive))
        XCTAssertEqual(p.rips, ["x", "y"])
        let p2 = NowPlayingPrefetcher.plan(input(current: t("a"), upcoming: [t("b"), t("c"), t("z", .appleMusicOnly)],
                                                 net: .expensive))
        XCTAssertTrue(p2.rips.isEmpty, "a row 3 deep is outside a cellular rip reach")
    }

    /// The CURRENT row is never a Mix Mode rip (the passive rip already covers an AM start, and a
    /// same-Mac capture of the playing track would interrupt it); local / catalog-only rows never.
    func testCurrentLocalAndCatalogOnlyRowsAreNeverRipped() {
        let ups = [t("l", .appleMusicOnly, local: true), t("c", .catalogOnly), t("x", .appleMusicOnly)]
        let p = NowPlayingPrefetcher.plan(input(current: t("cur", .appleMusicOnly), upcoming: ups))
        XCTAssertEqual(p.rips, ["x"])
    }

    // MARK: - Plan: Mix Mode stemify

    func testOwnerStemifiesRippedWindowRowsWithoutStems() {
        let ups = [t("b", remote: false), t("c"), t("d", stems: Set(StemLock.partPriority), remote: false),
                   t("x", .appleMusicOnly, remote: false), t("e", remote: false)]
        let p = NowPlayingPrefetcher.plan(input(current: t("a", remote: false), upcoming: ups))
        XCTAssertEqual(p.stemify, ["a", "b"], "current + window rows with no stems anywhere; e is past the window, d is complete, x has no audio")
    }

    // MARK: - Executor

    func testApplyAsksForEachRipOnceThenOnlyAfterTheRetryWindow() {
        let pf = NowPlayingPrefetcher()
        var asked: [String] = []
        pf.requestRip = { asked.append($0) }
        let plan = NowPlayingPrefetcher.Plan(steps: [], stemify: [], rips: ["x", "y"])
        pf.apply(plan)
        pf.apply(plan)
        XCTAssertEqual(asked, ["x", "y"], "deduped per song id")
        NowPlayingPrefetcher.ripRetrySeconds = 0
        pf.apply(plan)
        XCTAssertEqual(asked, ["x", "y", "x", "y"], "a row still AM-only after the window may be asked again")
        XCTAssertEqual(pf.ripLog.count, 4)
    }

    // MARK: - Production seam: owner only, a PLAYBACK rip

    private func ripStore() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RipPostStub.self]
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = "https://server.test"
        settings.ripToken = ""
        rips.settings = settings
        return rips
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    func testLiveLaneNeverPostsARipForANonOwner() async throws {
        let rips = ripStore()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let streamer = MixStreamLoader(rips: rips, burns: burns, configuration: .ephemeral)
        var owner = false
        let pf = NowPlayingPrefetcher.live(streamer: streamer, burns: burns, rips: rips, isCatalogOwner: { owner })
        pf.requestRip("sng_public")                  // refused synchronously: not the owner
        owner = true
        pf.requestRip("sng_owner")
        await waitUntil("the owner's rip is POSTed") { RipPostStub.posted.contains("sng_owner") }
        XCTAssertFalse(RipPostStub.posted.contains("sng_public"), "a non-owner never POSTs /rip")
    }

    /// The owner's Mix Mode rip is a PLAYBACK rip: the session's rip-ahead window gate applies (a
    /// row the playhead has left / beyond the next 10 is never requested).
    func testOwnerRipGoesThroughThePlaybackRipGate() async throws {
        let rips = ripStore()
        rips.playbackRipGate = { $0 != "sng_outside" }
        await NowPlayingPrefetcher.requestOwnerPlaybackRip("sng_outside", rips: rips)
        await NowPlayingPrefetcher.requestOwnerPlaybackRip("sng_inside", rips: rips)
        XCTAssertEqual(RipPostStub.posted, ["sng_inside"])
    }

    // MARK: - Provider order (preferLocalAudio)

    private func coordinator(_ rips: RipsStore) -> PlaybackCoordinator {
        let c = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: PlayerEngine()),
                                    appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        c.appleMusicReadyOverrideForTests = true
        c.sourceOfSong = { _ in Config.appleMusicSourceName }
        return c
    }

    func testPreferLocalPutsTheRipFirstOnlyWhenItStartsWithoutARoundTrip() {
        let rips = ripStore()
        rips.setManifest(["sng_r": .init(key: "rips/sng_r.mp3", source: "digital")])
        let c = coordinator(rips)
        let ripped = IndexSong.minimal(id: "sng_r", name: "R", artist: "A")
        let unripped = IndexSong.minimal(id: "sng_u", name: "U", artist: "A")
        // Ripped but no presign in hand: the rip still owes a round trip — Apple Music first.
        XCTAssertEqual(c.providers(for: ripped, preferLocalAudio: true).map(\.backend), [.appleMusic, .ripServer])
        rips.seedPrefetchedURLForTesting("sng_r", URL(string: "https://s3.test/rips/sng_r.mp3?sig=x")!)
        XCTAssertEqual(c.providers(for: ripped, preferLocalAudio: true).map(\.backend), [.ripServer, .appleMusic],
                       "instant rip ⇒ rip first, Apple Music right behind it as the fallback")
        XCTAssertEqual(c.providers(for: ripped).map(\.backend), [.appleMusic, .ripServer], "Mix Mode off: unchanged")
        XCTAssertEqual(c.providers(for: unripped, preferLocalAudio: true).map(\.backend), [.appleMusic, .ripServer],
                       "an un-ripped row stays Apple-Music-first (no dead-air regression)")
        XCTAssertFalse(c.streamsAppleMusicFirst(id: "sng_r", title: "R", artist: "A", variant: nil, preferLocalAudio: true))
        XCTAssertTrue(c.streamsAppleMusicFirst(id: "sng_r", title: "R", artist: "A", variant: nil))
    }

    func testPreferLocalNeverMovesACatalogOnlyIdOffAppleMusic() {
        let rips = ripStore()
        let id = "am:1799999999"
        rips.setManifest([id: .init(key: "rips/x.mp3", source: "digital")])
        rips.seedPrefetchedURLForTesting(id, URL(string: "https://s3.test/rips/x.mp3?sig=x")!)
        let c = coordinator(rips)
        c.sourceOfSong = { _ in nil }
        XCTAssertEqual(c.providers(for: IndexSong.minimal(id: id, name: "N", artist: "A"), preferLocalAudio: true).first?.backend,
                       .appleMusic)
    }

    func testPreferLocalNeedsAppleMusicReadyAndAnAppleMusicSource() {
        let rips = ripStore()
        rips.setManifest(["sng_v": .init(key: "rips/sng_v.mp3", source: "digital")])
        rips.seedPrefetchedURLForTesting("sng_v", URL(string: "https://s3.test/rips/sng_v.mp3?sig=x")!)
        let c = coordinator(rips)
        c.sourceOfSong = { _ in "My Vinyl" }
        XCTAssertEqual(c.providers(for: IndexSong.minimal(id: "sng_v", name: "V", artist: "A"), preferLocalAudio: true).map(\.backend),
                       [.ripServer], "a non-AM row's order is untouched")
    }

    // MARK: - Indicator

    private func ind(_ mut: (inout NPMixMode.IndicatorInput) -> Void) -> NPMixMode.Indicator {
        var i = NPMixMode.IndicatorInput(enabled: true, running: true, held: false, mixTabLive: false,
                                         engaged: false, stemsLoading: false, mixable: false,
                                         onAppleMusic: true, live: false, offline: false, ripped: false,
                                         deviceMode: false, bufferFraction: nil, buffering: false,
                                         failed: false, storageFull: false)
        mut(&i)
        return NPMixMode.indicator(i)
    }

    func testAppleMusicIndicatorStates() {
        XCTAssertEqual(ind { _ in }, .unavailable("Apple Music only"), "public user / nothing in flight")
        XCTAssertEqual(ind { $0.ripping = true }, .ripping, "owner: the rip server is capturing it")
        XCTAssertEqual(ind { $0.ripped = true; $0.buffering = true; $0.bufferFraction = 0.3 }, .buffering(0.3),
                       "a ripped AM row's local copy is downloading — it finishes on AM meanwhile")
        XCTAssertEqual(ind { $0.mixable = true }, .readyFromAppleMusic)
        XCTAssertTrue(NPMixMode.Indicator.readyFromAppleMusic.controlsLive)
        XCTAssertEqual(NPMixMode.Indicator.readyFromAppleMusic.chipText, "Ready — tap a control to switch to the local copy")
        XCTAssertEqual(NPMixMode.Indicator.ripping.chipText, "Ripping — mixable next play")
        XCTAssertFalse(NPMixMode.Indicator.ripping.controlsLive)
        XCTAssertEqual(ind { $0.onAppleMusic = false; $0.ripped = true; $0.mixable = true }, .ready, "non-AM unchanged")
        // A ripped AM row is never "Apple Music only" — it says why its copy isn't local yet.
        XCTAssertEqual(ind { $0.ripped = true }, .buffering(nil), "ripped + allowed: the lane takes it")
        XCTAssertEqual(ind { $0.ripped = true; $0.failed = true }, .unavailable("Download failed"))
        XCTAssertEqual(ind { $0.ripped = true; $0.cellularOff = true }, .unavailable("Cellular — buffering off"))
        XCTAssertEqual(ind { $0.ripping = true; $0.rippingEdition = "explicit" }, .rippingEdition("explicit"))
        XCTAssertEqual(NPMixMode.Indicator.rippingEdition("clean").chipText, "Ripping clean edition — mixable next play")
        XCTAssertFalse(NPMixMode.Indicator.rippingEdition("clean").controlsLive)
    }

    /// Stray MusicKit ▶ while the DSP owns the audio (e.g. after an AM hand-off): resume the DSP,
    /// never restart the row from 0:00 over it.
    func testStrayReclaimResumesTheDSPWhenEngaged() {
        XCTAssertEqual(SetlistPlayer.strayReclaimAction(isRunning: true, isHeld: false, appleMusicActive: false,
                                                        engineHasLocalItem: false, startPending: false,
                                                        dspEngaged: true), .resumeDSP)
        XCTAssertEqual(SetlistPlayer.strayReclaimAction(isRunning: true, isHeld: false, appleMusicActive: false,
                                                        engineHasLocalItem: false, startPending: false), .startCurrent)
    }
}

/// Records every `POST /rip` songId; answers queued.
private final class RipPostStub: URLProtocol {
    nonisolated(unsafe) static var posted: [String] = []
    private static let lock = NSLock()
    static func reset() { lock.lock(); posted = []; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var body = Data(#"{"phase":"ready"}"#.utf8)
        if url.path.hasSuffix("/rip"), request.httpMethod == "POST" {
            let data = request.httpBody ?? request.httpBodyStream.map { Self.read($0) } ?? Data()
            let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["songId"] as? String ?? "?"
            Self.lock.lock(); Self.posted.append(id); Self.lock.unlock()
            body = Data(#"{"jobId":"j-\#(id)","songId":"\#(id)","phase":"queued"}"#.utf8)
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ s: InputStream) -> Data {
        s.open(); defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}
