import AVFoundation
import XCTest
@testable import PocketDJ

/// STEM LOCK — a Now Playing session carries its stem set (stems on/off, which parts are muted,
/// per-part gains) from track to track, and its download lane pairs the next track's whole song
/// with its stems (whole song first, then vocals → drums → other → bass, then further tracks;
/// muted parts last).
///
///  • The PLAN (`StemLockPrefetcher.plan`) and the EXECUTOR are pure — no audio device.
///  • The carry runs the REAL sequencer + `NowPlayingDSP` over burned WAV songs and the bundled
///    headerless noise stems (`stem-noise-12s`, a Demucs-shaped part) — skipped on a host with
///    no audio device (`NowPlayingDSP.isReady`).
@MainActor
final class StemLockTests: XCTestCase {

    // MARK: - Plan (pure)

    private func track(_ id: String, songLocal: Bool = false, fetchable: Bool = true,
                       stemsLocal: Set<String> = [], remote: Bool = true) -> StemLockPrefetcher.Track {
        .init(songId: id, audioId: id, title: id, artist: "A", songLocal: songLocal, songFetchable: fetchable,
              stemsLocal: stemsLocal, stemsRemote: remote)
    }

    private func carry(muted: [String] = []) -> StemLockState {
        StemLockState(enabled: true, stemsOn: true, muted: muted.sorted(), volumes: [:])
    }

    private func names(_ steps: [StemLockPrefetcher.Step]) -> [String] { steps.map(\.description) }

    /// Levi's order: the next track's WHOLE SONG first (it's what plays at the boundary), then
    /// its stems vocals → drums → other → bass, and only then the further-ahead tracks.
    func testPlanFetchesWholeSongThenStemsInPriorityOrderBeforeFurtherTracks() {
        let plan = StemLockPrefetcher.plan(current: nil, upcoming: [track("n1"), track("n2"), track("n3")],
                                           carry: carry(), network: .unmetered, window: 3)
        XCTAssertEqual(names(plan.steps), [
            "song:n1", "vocals:n1", "drums:n1", "other:n1", "bass:n1",
            "song:n2", "vocals:n2", "drums:n2", "other:n2", "bass:n2",
            "song:n3", "vocals:n3", "drums:n3", "other:n3", "bass:n3",
        ])
        XCTAssertEqual(plan.stemify, [])
    }

    /// Muted parts aren't what the handover waits for: they go LAST (after every track), and Low
    /// Data Mode skips them — and everything past the next track.
    func testMutedPartsGoLastAndLowDataSkipsThem() {
        let up = [track("n1"), track("n2")]
        let plan = StemLockPrefetcher.plan(current: nil, upcoming: up, carry: carry(muted: ["bass", "other"]),
                                           network: .unmetered, window: 3)
        XCTAssertEqual(names(plan.steps), ["song:n1", "vocals:n1", "drums:n1", "song:n2", "vocals:n2", "drums:n2",
                                           "other:n1", "bass:n1", "other:n2", "bass:n2"])
        let low = StemLockPrefetcher.plan(current: nil, upcoming: up, carry: carry(muted: ["bass", "other"]),
                                          network: .constrained, window: 3)
        XCTAssertEqual(names(low.steps), ["song:n1", "vocals:n1", "drums:n1"])
    }

    /// Cellular: the next track only (song + all its stems). Offline: nothing.
    func testCellularPlansTheNextTrackOnlyAndOfflineNothing() {
        let up = [track("n1"), track("n2"), track("n3")]
        let cell = StemLockPrefetcher.plan(current: nil, upcoming: up, carry: carry(), network: .expensive, window: 3)
        XCTAssertEqual(names(cell.steps), ["song:n1", "vocals:n1", "drums:n1", "other:n1", "bass:n1"])
        XCTAssertTrue(StemLockPrefetcher.plan(current: nil, upcoming: up, carry: carry(), network: .offline, window: 3).steps.isEmpty)
    }

    /// Lock OFF, or locked carrying "stems off": no speculative stem (or song) fetch at all.
    func testLockOffOrStemsOffPlansNothing() {
        let up = [track("n1")]
        XCTAssertEqual(StemLockPrefetcher.plan(current: nil, upcoming: up, carry: StemLockState(), network: .unmetered, window: 3),
                       .init())
        let stemsOff = StemLockState(enabled: true, stemsOn: false)
        XCTAssertEqual(StemLockPrefetcher.plan(current: nil, upcoming: up, carry: stemsOff, network: .unmetered, window: 3),
                       .init())
    }

    /// What's already on the device is skipped; a track whose song can't be made local is
    /// skipped whole (its stems could never play); the next track with NO stems gets one cloud
    /// separation request.
    func testPlanSkipsLocalAudioUnfetchableTracksAndRequestsStemifyForTheNext() {
        let plan = StemLockPrefetcher.plan(current: nil, upcoming: [
            track("n1", remote: false),                                         // no stems anywhere
            track("n2", songLocal: true, stemsLocal: ["vocals", "drums"]),
            track("n3", fetchable: false),                                      // Apple-Music-only
        ], carry: carry(), network: .unmetered, window: 3)
        XCTAssertEqual(plan.stemify, ["n1"])
        XCTAssertEqual(names(plan.steps), ["song:n1", "other:n2", "bass:n2"])
    }

    /// The PLAYING track's missing parts (a partial set on air) lead: enabled ones first; its
    /// muted ones still go last.
    func testCurrentPartialSetsMissingEnabledPartsLead() {
        let plan = StemLockPrefetcher.plan(current: track("cur", songLocal: true, stemsLocal: ["vocals"]),
                                           upcoming: [track("n1")], carry: carry(muted: ["bass"]),
                                           network: .unmetered, window: 3)
        XCTAssertEqual(names(plan.steps), ["drums:cur", "other:cur", "song:n1", "vocals:n1", "drums:n1",
                                           "other:n1", "bass:cur", "bass:n1"])
    }

    // MARK: - Executor (pure)

    /// One fetch at a time in plan order; a re-plan that still wants the in-flight step keeps it
    /// (no restart), one that doesn't cancels it; a song with no stems is stemified ONCE.
    func testExecutorRunsInOrderKeepsWantedInFlightAndDedupesStemify() async {
        let pf = StemLockPrefetcher()
        var gates: [String: CheckedContinuation<Bool, Never>] = [:]
        var stemified: [String] = []
        pf.fetchSong = { step in await withCheckedContinuation { gates[step.description] = $0 } }
        pf.fetchStemPart = { id, part in await withCheckedContinuation { gates["\(part):\(id)"] = $0 } }
        pf.requestStemify = { stemified.append($0) }

        let p1 = StemLockPrefetcher.plan(current: nil, upcoming: [track("a"), track("b", remote: false)],
                                         carry: carry(muted: ["other", "bass"]), network: .unmetered, window: 3)
        pf.apply(p1)
        await waitUntil("song:a in flight") { gates["song:a"] != nil }
        XCTAssertEqual(pf.inFlight?.description, "song:a")
        pf.apply(p1)                                            // same plan again: no restart, no 2nd stemify
        XCTAssertEqual(pf.startedLog.count, 1, "the wanted in-flight step is kept")
        XCTAssertEqual(stemified, [], "a has stems")
        gates["song:a"]?.resume(returning: true)
        await waitUntil("vocals:a in flight") { gates["vocals:a"] != nil }
        gates["vocals:a"]?.resume(returning: true)
        await waitUntil("drums:a in flight") { gates["drums:a"] != nil }

        // A skip moves on: `a` is now playing and has nothing missing; `b` (no stems) is next.
        let p2 = StemLockPrefetcher.plan(current: nil, upcoming: [track("b", remote: false)],
                                         carry: carry(muted: ["other", "bass"]), network: .unmetered, window: 3)
        pf.apply(p2)
        XCTAssertEqual(stemified, ["b"])
        pf.apply(p2)
        XCTAssertEqual(stemified, ["b"], "deduped per song id")
        await waitUntil("song:b in flight (drums:a cancelled)") { gates["song:b"] != nil }
        XCTAssertEqual(names(pf.startedLog), ["song:a", "vocals:a", "drums:a", "song:b"])
        gates["drums:a"]?.resume(returning: false)              // the cancelled fetch's late landing
        gates["song:b"]?.resume(returning: true)
        await waitUntil("idle") { pf.isIdle }
        XCTAssertEqual(names(pf.startedLog), ["song:a", "vocals:a", "drums:a", "song:b"])
    }

    // MARK: - Snapshot (pure)

    /// The lock + its carried set ride the durable session: a snapshot round-trips them and a
    /// restore re-adopts them; a pre-Stem-Lock snapshot (no key) restores unlocked.
    func testLockRestoresFromTheSessionSnapshot() throws {
        let lock = StemLockState(enabled: true, stemsOn: true, muted: ["bass"], volumes: ["drums": 0.5])
        let snap = PlaybackSessionStore.Snapshot(
            sessionId: "pses_x", source: .init(kind: "playlist", id: "p", name: "P"),
            queue: [.init(songId: "s1", title: "S1", artist: "A", lengthMs: nil, repeatCount: nil)],
            index: 0, positionMs: 1_000, isPlaying: true, stemLock: lock, updatedAt: 0)
        let decoded = try JSONDecoder().decode(PlaybackSessionStore.Snapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(decoded.stemLock, lock)

        let r = makeSeq()
        r.seq.restore(from: decoded)
        XCTAssertEqual(r.seq.stemLock, lock, "the restored session is still locked, carrying its set")
        XCTAssertEqual(r.seq.stemLockIndicator, .idle, "held deck: nothing applied until ▶")

        var old = decoded; old.stemLock = nil
        let r2 = makeSeq()
        r2.seq.restore(from: old)
        XCTAssertFalse(r2.seq.stemLock.enabled)
    }

    // MARK: - Carry (real sequencer + DSP)

    private struct Rig {
        let rips: RipsStore; let burns: BurnStore; let player: PlayerEngine
        let seq: SetlistPlayer; let dsp: NowPlayingDSP; let burnDir: URL
    }

    private func makeSeq() -> Rig {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let burns = try! MixBurnFixture.burnStore(ids: [], rips: rips)
        return wire(rips, burns)
    }

    override func setUp() {
        super.setUp()
        NPLog.mirror = { print("TRACE", $0) }
    }

    override func tearDown() {
        NPLog.mirror = nil
        super.tearDown()
    }

    private func wire(_ rips: RipsStore, _ burns: BurnStore) -> Rig {
        let player = PlayerEngine()
        let coord = PlaybackCoordinator(ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
                                        appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coord)
        let dsp = NowPlayingDSP(burns: burns)
        seq.dsp = dsp
        addTeardownBlock { @MainActor in seq.stop(); dsp.disengage() }
        return Rig(rips: rips, burns: burns, player: player, seq: seq, dsp: dsp, burnDir: burns.appBurnsDirOverride!)
    }

    /// `burned`: songs on the device (12 s WAV bodies). `remote`: the catalog lists stems for them.
    /// `stemsOnDisk`: song → the stem parts already burned (the bundled noise stem).
    private func rig(burned: [String], remote: Set<String>, stemsOnDisk: [String: [String]] = [:],
                     manifestOnly: [String] = []) throws -> Rig {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        var m: [String: RipsStore.ManifestEntry] = [:]
        for id in burned + manifestOnly {
            m[id] = .init(key: "rips/\(id).mp3", source: "digital",
                          stems: remote.contains(id) ? .init(vocals: "stems/\(id)/vocals.mp3", drums: "stems/\(id)/drums.mp3",
                                                              bass: "stems/\(id)/bass.mp3", other: "stems/\(id)/other.mp3") : nil)
        }
        rips.setManifest(m)
        let lengths = Dictionary(uniqueKeysWithValues: burned.map { ($0, 12.0) })
        let burns = try MixBurnFixture.burnStore(ids: burned, rips: rips, lengths: lengths)
        let r = wire(rips, burns)
        for (id, parts) in stemsOnDisk { try writeStems(r, id, parts) }
        return r
    }

    private func writeStems(_ r: Rig, _ id: String, _ parts: [String]) throws {
        let data = try StemAudioProbe.bundled("stem-noise-12s", in: Self.self)
        for p in parts { try data.write(to: r.burnDir.appendingPathComponent("stem-\(id)-\(p).mp3")) }
    }

    private func item(_ id: String) -> SetlistPlayer.Item { .init(id: id, title: id, artist: "A") }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        await StemAudioProbe.wait(timeout: timeout, until: predicate)
        XCTAssertTrue(predicate(), "timed out waiting: \(message)")
    }

    /// Start the set, engage the DSP on track 0 and put its stems on air (burned stems).
    private func startOnStems(_ r: Rig, _ ids: [String]) async throws {
        r.seq.play(ids.map(item))
        await waitUntil("\(ids[0]) playing") { r.rips.nowPlaying?.songId == ids[0] }
        r.seq.engageMix()
        try XCTSkipUnless(r.dsp.isReady, "no audio device on this test host")
        XCTAssertTrue(r.seq.mixEngaged)
        if !r.dsp.isPlaying { r.dsp.resume() }
        XCTAssertTrue(r.dsp.setStemMode(true), "precondition: track 0 has stems")
        await waitUntil("track 0 on stems") { r.dsp.stemsOnAir }
    }

    /// LOCK ON: the set on air when the track changes — stems on, bass muted, drums at half —
    /// is what the next track comes up with.
    func testLockedStemSetCarriesToTheNextTrack() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["c1", "c2"], remote: ["c1", "c2"], stemsOnDisk: ["c1": all, "c2": all])
        try await startOnStems(r, ["c1", "c2"])
        r.dsp.toggleStemMute("bass")
        r.dsp.setStemVolume("drums", 0.5)
        r.seq.setStemLock(true)
        XCTAssertEqual(r.seq.stemLock, StemLockState(enabled: true, stemsOn: true, muted: ["bass"], volumes: ["drums": 0.5]))

        r.seq.skipNext()
        await waitUntil("c2 on its carried stems") {
            r.rips.nowPlaying?.songId == "c2" && r.dsp.loadedSongId == "c2" && r.dsp.stemsOnAir
        }
        XCTAssertTrue(r.seq.mixEngaged)
        XCTAssertTrue(r.dsp.isPlaying)
        XCTAssertTrue(r.dsp.isStemMuted("bass"), "the carried mute")
        XCTAssertFalse(r.dsp.isStemMuted("vocals"))
        XCTAssertEqual(r.dsp.stemVolume("drums"), 0.5, accuracy: 1e-9, "the carried gain")
        XCTAssertEqual(r.dsp.stemNodeVolume("bass"), 0)
        XCTAssertEqual(r.seq.stemLockIndicator, .active)
        XCTAssertTrue(r.seq.stemLock.enabled, "the lock stays on")
    }

    /// A change MID-TRACK is what carries (not the state the lock was turned on with).
    func testMidTrackChangeUpdatesTheCarriedSet() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["m1", "m2"], remote: ["m1", "m2"], stemsOnDisk: ["m1": all, "m2": all])
        try await startOnStems(r, ["m1", "m2"])
        r.seq.setStemLock(true)
        XCTAssertEqual(r.seq.stemLock.muted, [])
        r.dsp.toggleStemMute("vocals")                       // an instrumental from here on
        r.dsp.toggleStemMute("drums")
        XCTAssertEqual(r.seq.stemLock.muted, ["drums", "vocals"])
        r.dsp.toggleStemMute("drums")                        // …changed my mind about the drums
        XCTAssertEqual(r.seq.stemLock.muted, ["vocals"])

        r.seq.skipNext()
        await waitUntil("m2 on stems") { r.dsp.loadedSongId == "m2" && r.dsp.stemsOnAir }
        XCTAssertTrue(r.dsp.isStemMuted("vocals"))
        XCTAssertFalse(r.dsp.isStemMuted("drums"))
    }

    /// Turning stems OFF while locked carries "stems off": the next track plays the plain full
    /// mix (no DSP engagement at all) and the lock stays on.
    func testStemsOffCarriesForward() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["o1", "o2"], remote: ["o1", "o2"], stemsOnDisk: ["o1": all, "o2": all])
        try await startOnStems(r, ["o1", "o2"])
        r.seq.setStemLock(true)
        XCTAssertTrue(r.dsp.setStemMode(false))
        XCTAssertFalse(r.seq.stemLock.stemsOn, "stems off is what carries now")

        r.seq.skipNext()
        await waitUntil("o2 playing") { r.rips.nowPlaying?.songId == "o2" }
        XCTAssertFalse(r.seq.mixEngaged, "stems off: the plain AVPlayer path, exactly as unlocked")
        XCTAssertTrue(r.seq.stemLock.enabled)
        XCTAssertEqual(r.seq.stemLockIndicator, .idle)
    }

    /// A next track WITHOUT stems plays the full mix under the "unavailable" indicator — and the
    /// lock carries on to the track after it, which comes up on stems again.
    func testTrackWithoutStemsPlaysFullMixAndTheLockPersists() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["u1", "u2", "u3"], remote: ["u1", "u3"], stemsOnDisk: ["u1": all, "u3": all])
        try await startOnStems(r, ["u1", "u2", "u3"])
        r.dsp.toggleStemMute("other")
        r.seq.setStemLock(true)

        r.seq.skipNext()
        await waitUntil("u2 playing, flagged unavailable") {
            r.rips.nowPlaying?.songId == "u2" && r.seq.stemLockIndicator == .unavailable
        }
        XCTAssertFalse(r.dsp.stemsOnAir, "no stems: the full mix plays")
        await waitUntil("u2's full mix audibly playing") { r.dsp.loadedSongId == "u2" && r.dsp.currentTime > 0.3 }
        XCTAssertEqual(r.seq.stemLock, StemLockState(enabled: true, stemsOn: true, muted: ["other"]),
                       "a track that can't do stems never overwrites the carried set")

        r.seq.skipNext()
        await waitUntil("u3 back on the carried stems") { r.dsp.loadedSongId == "u3" && r.dsp.stemsOnAir }
        XCTAssertTrue(r.dsp.isStemMuted("other"))
        XCTAssertEqual(r.seq.stemLockIndicator, .active)
    }

    /// ZERO DEAD AIR: the next track's stems aren't on the device yet. It starts on the FULL MIX
    /// from its first second (no wait), "Loading stems…", and hands over to the carried set once
    /// the stems land — the DSP's output never goes silent across the wait or the handover.
    func testLockedTrackStartsOnFullMixThenHandsOverWithoutDeadAir() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["z1", "z2"], remote: ["z1", "z2"], stemsOnDisk: ["z1": all])
        var release: CheckedContinuation<Bool, Never>?
        r.dsp.stemFetcher = { _ in await withCheckedContinuation { release = $0 } }
        try await startOnStems(r, ["z1", "z2"])
        r.dsp.toggleStemMute("bass")
        r.seq.setStemLock(true)

        r.seq.skipNext()
        await waitUntil("z2 engaged on the full mix") { r.dsp.loadedSongId == "z2" && r.dsp.isPlaying }
        XCTAssertLessThan(r.dsp.currentTime, 1.5, "z2 starts at its top — no silent wait for stems")
        // (Past the ordinary 60 ms start lead every DSP start has, before listening.)
        await waitUntil("z2's full mix rendering") { r.dsp.currentTime > 0.2 }
        XCTAssertTrue(r.dsp.stemsLoading, "Loading stems…")
        XCTAssertFalse(r.dsp.stemsOnAir)
        XCTAssertEqual(r.seq.stemLockIndicator, .loading)
        XCTAssertTrue(r.dsp.mainNodePlayingForTesting(), "the full mix is on air meanwhile")
        let cap = r.dsp.captureForTesting()
        cap.start()
        await StemAudioProbe.capture(cap, atLeast: 0.5)

        try writeStems(r, "z2", all)                        // the stems land
        await waitUntil("fetch requested") { release != nil }
        release?.resume(returning: true)
        await waitUntil("carried stems on air") { r.dsp.stemsOnAir }
        await waitUntil("crossfade landed") { !r.dsp.stemFadeInFlightForTesting() }
        await StemAudioProbe.capture(cap, atLeast: 0.5)
        let y = cap.stop()
        XCTAssertLessThan(StemAudioProbe.longestSilence(y), 88, "no dead air across the wait + handover (≤2 ms)")
        XCTAssertTrue(r.dsp.isStemMuted("bass"), "the handover brought up the CARRIED set")
        XCTAssertFalse(r.dsp.mainNodePlayingForTesting())
        XCTAssertEqual(r.seq.index, 1, "no fake end, no skip")
        XCTAssertEqual(r.seq.stemLockIndicator, .active)
    }

    /// The switch waits only for the ENABLED parts: with bass muted and not yet downloaded, the
    /// next track goes on air with three parts; bass joins (silently, sample-aligned) when the
    /// prefetcher lands it — and an un-mute then sounds it.
    func testHandoverWaitsOnlyForEnabledPartsAndLateMutedPartJoins() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["e1", "e2"], remote: ["e1", "e2"],
                        stemsOnDisk: ["e1": all, "e2": ["vocals", "drums", "other"]])
        let pf = StemLockPrefetcher()
        var bassGate: CheckedContinuation<Bool, Never>?
        pf.fetchStemPart = { [r] id, part in
            if part == "bass" { return await withCheckedContinuation { bassGate = $0 } }
            try? self.writeStems(r, id, [part])
            return true
        }
        r.seq.stemLockPrefetcher = pf
        try await startOnStems(r, ["e1", "e2"])
        r.dsp.toggleStemMute("bass")
        r.seq.setStemLock(true)
        await waitUntil("bass:e2 requested (muted parts last)") { bassGate != nil }

        r.seq.skipNext()
        await waitUntil("e2 on air with its enabled parts") { r.dsp.loadedSongId == "e2" && r.dsp.stemsOnAir }
        XCTAssertEqual(r.dsp.unwiredStemParts, ["bass"], "on air WITHOUT the muted part")
        XCTAssertTrue(r.dsp.isStemMuted("bass"))

        try writeStems(r, "e2", ["bass"])
        bassGate?.resume(returning: true)
        await waitUntil("bass joined") { r.dsp.unwiredStemParts.isEmpty }
        XCTAssertTrue(r.dsp.stemsOnAir)
        r.dsp.toggleStemMute("bass")
        XCTAssertEqual(r.dsp.stemNodeVolume("bass") ?? 0, 1, accuracy: 1e-6, "un-muted: it sounds")
        XCTAssertEqual(r.seq.stemLock.muted, [], "…and the un-mute is what carries now")
        XCTAssertEqual(r.seq.index, 1)
    }

    /// The download lane through the sequencer: locked with bass muted, the upcoming tracks' whole
    /// songs + stems are fetched one at a time in the documented order.
    func testSequencerPrefetchOrderWithTheLockOn() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["p0"], remote: ["p0", "p1", "p2", "p3"], stemsOnDisk: ["p0": all],
                        manifestOnly: ["p1", "p2", "p3"])
        let pf = StemLockPrefetcher()
        pf.fetchSong = { _ in true }
        pf.fetchStemPart = { _, _ in true }
        r.seq.stemLockPrefetcher = pf
        r.seq.stemLockSongFetchable = { _ in true }
        try await startOnStems(r, ["p0", "p1", "p2", "p3"])
        r.dsp.toggleStemMute("bass")
        r.seq.setStemLock(true)
        await waitUntil("the lane drained") { pf.startedLog.count >= 15 && pf.isIdle }
        XCTAssertEqual(names(pf.startedLog), [
            "song:p1", "vocals:p1", "drums:p1", "other:p1",
            "song:p2", "vocals:p2", "drums:p2", "other:p2",
            "song:p3", "vocals:p3", "drums:p3", "other:p3",
            "bass:p1", "bass:p2", "bass:p3",
        ])
    }

    /// LOCK OFF — exactly the old behaviour: stems reset on the track change, and nothing is
    /// fetched speculatively.
    func testLockOffResetsStemsEachTrackAndFetchesNothing() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["f1", "f2"], remote: ["f1", "f2"], stemsOnDisk: ["f1": all])
        let pf = StemLockPrefetcher()
        pf.fetchSong = { _ in true }
        pf.fetchStemPart = { _, _ in true }
        var stemified = 0
        pf.requestStemify = { _ in stemified += 1 }
        r.seq.stemLockPrefetcher = pf
        r.seq.stemLockSongFetchable = { _ in true }
        try await startOnStems(r, ["f1", "f2"])
        r.dsp.toggleStemMute("vocals")

        r.seq.skipNext()
        await waitUntil("f2 playing") { r.rips.nowPlaying?.songId == "f2" }
        XCTAssertFalse(r.seq.mixEngaged, "unlocked: the track change tore the DSP down")
        XCTAssertFalse(r.dsp.stemMode)
        XCTAssertFalse(r.dsp.isStemMuted("vocals"), "controls reset (ephemeral)")
        XCTAssertEqual(r.seq.stemLockIndicator, .off)
        XCTAssertTrue(pf.startedLog.isEmpty, "no speculative fetch with the lock off")
        XCTAssertEqual(stemified, 0)
        XCTAssertTrue(r.burns.stemPartsBurned(forSong: "f2").isEmpty)
    }

    /// The lock persists in the durable snapshot (and survives a relaunch restore — the first ▶
    /// re-applies it); a NEW session (a fresh `play`) and `stop()` clear it.
    func testLockPersistsInTheSnapshotAndANewSessionClearsIt() async throws {
        let all = MixEngine.stemNames
        let r = try rig(burned: ["s1", "s2"], remote: ["s1", "s2"], stemsOnDisk: ["s1": all, "s2": all])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-stemlock-session-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = PlaybackSessionStore(fileURL: url)
        r.seq.sessionStore = store
        try await startOnStems(r, ["s1", "s2"])
        r.dsp.toggleStemMute("drums")
        r.seq.setStemLock(true)
        r.seq.flushSessionSnapshotNow()
        store.flush()
        let snap = try XCTUnwrap(store.load())
        XCTAssertEqual(snap.stemLock, StemLockState(enabled: true, stemsOn: true, muted: ["drums"]))

        // Relaunch: a fresh sequencer restores the held session, ▶ re-applies the carried set.
        let r2 = wire(r.rips, r.burns)
        r.seq.stop()
        r2.seq.restore(from: snap)
        XCTAssertEqual(r2.seq.stemLock, snap.stemLock)
        r2.seq.resumeFromHold()
        await waitUntil("restored track on the carried stems") { r2.dsp.loadedSongId == "s1" && r2.dsp.stemsOnAir }
        XCTAssertTrue(r2.dsp.isStemMuted("drums"))

        // A new session — a fresh play — starts unlocked; its snapshot carries no lock.
        r2.seq.play([item("s2")])
        XCTAssertFalse(r2.seq.stemLock.enabled)
        await waitUntil("s2 playing") { r2.rips.nowPlaying?.songId == "s2" }
        XCTAssertFalse(r2.seq.mixEngaged, "no carried stems in the new session")
        r2.seq.setStemLock(true)
        XCTAssertTrue(r2.seq.stemLock.enabled)
        r2.seq.stop()
        XCTAssertFalse(r2.seq.stemLock.enabled, "stop ends the session — and its lock")
    }
}
