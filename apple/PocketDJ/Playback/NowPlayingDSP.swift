import Foundation
import Observation
import AVFoundation
import AudioToolbox        // DynamicsProcessor AU parameter ids + AudioUnitSetParameter (compressor)
#if canImport(UIKit)
import UIKit
#endif

/// F4 — a SINGLE-DECK first-party DSP engine that takes over the CURRENTLY PLAYING local track so the
/// Now Playing mix mini-panel can apply tempo / pitch / gain / effects / stems to it in real time.
///
/// It is a fork of `StemPlayer` (host-clock scrubber, generation-guarded schedule completions) built
/// around ONE `MixEngine` deck's DSP chain:
///
///   `AVAudioPlayerNode → inputMixer → AVAudioUnitTimePitch → DynamicsProcessor(comp)
///        → AVAudioUnitEQ(filter + globalGain) → AVAudioUnitReverb → AVAudioUnitDelay(flanger)
///        → mainMixerNode → masterLimiter(PeakLimiter) → output`
///
/// plus 4 stem `AVAudioPlayerNode`s summing into the SAME `inputMixer`, so the stems ride the same
/// tempo / pitch / effect / gain chain as the single file (exactly like `MixEngine`).
///
/// It plays a LOCAL file (a burned or studio track) — normal playback is a single `AVPlayer`
/// with no DSP surface, so `SetlistPlayer` hands the current track's audio off to this engine AT its
/// current position when the user first touches a mix control (`SetlistPlayer.engageMix`) — or, in
/// Mix Mode (np-mix-mode phase 3), a GROWING file: a ripped row's `MixStreamLoader` buffer stream,
/// played while it downloads (`engageStreaming`; the Mix deck's streaming rules, shared through
/// `GrowingFileSchedule`): never scheduled past the downloaded frontier, HELD there ("Buffering…")
/// until there is runway again, appended as bytes land, swapped to the adopted file on completion. The
/// control state is EPHEMERAL — it resets on every track change (`resetControls`), so nothing here is
/// ever persisted. (STEM LOCK — `SetlistPlayer.stemLock`, `StemLock.swift` — re-applies a carried stem
/// set on the next track; the session, not this engine, owns and persists it.)
///
/// Reuses `MixEngine.Effect` / `MixEngine.rateRange` / `.pitchRange` / `.volumeRange` / `.stemNames`
/// so the Mix tab's control components (`DeckSlider` / `EffectButton`) bind straight to it.
@MainActor
@Observable
final class NowPlayingDSP {

    // MARK: Graph nodes (never observed — mutating the node graph must not invalidate the UI)

    // `var`, not `let`: a media-services reset orphans every engine/node in the process, and
    // Apple's contract is to RECREATE them (`rebuildAfterMediaReset`).
    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var player = AVAudioPlayerNode()
    @ObservationIgnored private var inputMixer = AVAudioMixerNode()
    @ObservationIgnored private var timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var comp = AVAudioUnitEffect(audioComponentDescription: NowPlayingDSP.dynamicsDesc)
    @ObservationIgnored private var filter = AVAudioUnitEQ(numberOfBands: 1)
    @ObservationIgnored private var reverb = AVAudioUnitReverb()
    @ObservationIgnored private var flanger = AVAudioUnitDelay()
    @ObservationIgnored private var masterLimiter = AVAudioUnitEffect(audioComponentDescription: NowPlayingDSP.limiterDesc)
    @ObservationIgnored private var stemNodes: [String: AVAudioPlayerNode] = [:]
    @ObservationIgnored private var built = false

    private let burns: BurnStore
    /// Stage 7 seam (wired at app init to `ProfileSourceStore.stemURLs`): a "Pocket DJ" profile
    /// item's 4 app-managed stem URLs (release-less), else nil — lets a profile item's stems drive
    /// the same per-stem DSP as a burned song's.
    @ObservationIgnored var profileStemResolve: ((String) -> [String: URL]?)?

    // MARK: Loaded-file state (non-observed — the schedule geometry, not UI)

    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var sampleRate: Double = 0
    /// The song's slice within the (possibly shared analog album) file.
    @ObservationIgnored private var segStartFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var segEndFrame: AVAudioFramePosition = 0
    /// Held security scopes for a user-folder burned file / stems (released on disengage).
    @ObservationIgnored private var fileRelease: (() -> Void)?
    @ObservationIgnored private var stemFiles: [String: AVAudioFile] = [:] {
        didSet {
            // STEM LOCK: a wired set may be PARTIAL (only the parts a carried stem set needs —
            // see `stemPartsRequired`). Publish which parts are missing so the pads can say so.
            let missing: Set<String> = stemFiles.isEmpty ? [] : Set(MixEngine.stemNames).subtracting(stemFiles.keys)
            if missing != unwiredStemParts { unwiredStemParts = missing }
        }
    }
    @ObservationIgnored private var stemRelease: (() -> Void)?
    /// Bumped on every (re)schedule/stop so a stale completion can't flip state after the fact.
    @ObservationIgnored private var generation = 0

    // MARK: Zero dead air — the stem HANDOVER (the Mix deck's rule, single deck)
    //
    // Switching between the full song and its stems is a HANDOVER, not a stop/start: the outgoing
    // voice keeps playing until the incoming one is wired AND has runway past the playhead, then
    // the two cross over at ONE sample frame under a 60 ms linear crossfade (`cutToStems` /
    // `cutToFullMix`). Asking for stems that aren't on disk records the INTENT (`stemHandover`
    // = `.toStems`, the panel's "Loading stems…") while the full song plays on; they are STREAMED
    // through the shared `MixStreamLoader` (or fetched whole) and taken over once buffered. A
    // fetch that fails, a toggle back, a track change (disengage) simply drops the request.
    // Streaming stems on air that run short of bytes hand back to the full song before they run
    // dry and re-engage once they have runway. `stemIntentGen` guards every async completion;
    // `generation` (above) keeps guarding the END handler — see `setStemMode`.

    /// The pending handover (OBSERVED — drives the panel's spinner). nil = on the voice asked for.
    private var _stemHandover: MixEngine.StemHandover?
    @ObservationIgnored private var stemIntentGen = 0
    /// Whole-file stem fetch (no stem streaming available) — cancelled with the intent.
    @ObservationIgnored private var stemFetchTask: Task<Void, Never>?
    /// The not-on-disk stems this engine is STREAMING (nil once complete / never).
    @ObservationIgnored private var stemStream: MixStreamLoader.StemSet?
    /// While the wired stems are PARTIAL: the song seconds from 0:00 every part can play.
    @ObservationIgnored private var stemFrontier: Double?
    /// How far the stem nodes are scheduled (song seconds) — the append pump's cursor.
    @ObservationIgnored private var stemEndSeconds: Double = 0
    /// Encoder priming at the head of the wired stem files (`StemSync.mp3PrimingFrames`).
    @ObservationIgnored private var stemPrime: AVAudioFramePosition = 0
    /// The streaming stems' byte frontier (seconds) at their last fresh open — the re-open throttle.
    @ObservationIgnored private var stemOpenedBytesSeconds: Double = 0
    /// Song second each voice's CURRENT segment began at (its player clock counts from there).
    @ObservationIgnored private var mainSegStartSeconds: Double = 0
    @ObservationIgnored private var stemSegStartSeconds: Double = 0
    /// Handover crossfade gains (1 = settled).
    @ObservationIgnored private var mainVoiceGain: Float = 1
    @ObservationIgnored private var stemVoiceGain: Float = 1
    @ObservationIgnored private var stemFade: (toStems: Bool, task: Task<Void, Never>)?
    @ObservationIgnored private var stemFadeGen = 0
    /// Watches partial stems on air (underrun hand-back) and a pending handover's runway.
    @ObservationIgnored private var stemMonitor: Task<Void, Never>?
    /// The shared stream loader (the Mix tab's — its stem lane); nil ⇒ stems are fetched whole.
    @ObservationIgnored var streamer: MixStreamLoader? {
        didSet {
            if let id = stemListenerId { oldValue?.removeStemListener(id) }
            stemListenerId = streamer?.addStemListener { [weak self] songId in self?.stemStreamProgressed(songId) }
            if let id = progressListenerId { oldValue?.removeProgressListener(id) }
            progressListenerId = streamer?.addProgressListener { [weak self] songId in self?.mainStreamProgressed(songId) }
        }
    }
    @ObservationIgnored private var stemListenerId: UUID?
    /// Fetch `songId`'s stems WHOLE; returns whether all four are now on disk. nil ⇒
    /// `BurnStore.burnStems`. Test seam.
    @ObservationIgnored var stemFetcher: ((String) async -> Bool)?
    /// TEST SEAM: caps the full song's schedulable audio at this song second, as if it were still
    /// arriving (a complete local file otherwise — the growing-file path below is the real thing).
    /// Clear it with `releaseMainFrontierForTesting`.
    @ObservationIgnored private(set) var mainFrontierForTesting: Double?

    // MARK: Growing file (np-mix-mode phase 3 — the full song plays WHILE it downloads)
    //
    // `engageStreaming` takes a `MixStreamLoader` buffer stream instead of a finished file. Until
    // its header is readable the song is unattached (`file == nil`, provisional catalog duration);
    // from then on `mainFrontierFrame` is the schedulable frontier (bytes → frames at the header's
    // byte rate − the torn-frame margin, `GrowingFileSchedule.frontier`). The full song's voice is
    // NEVER scheduled past it: a start / resume / seek without runway HOLDS (`isBuffering` — the
    // engine keeps running so the session and a locked phone stay alive, the card's cursor
    // freezes); the loader's progress events (`pumpMain`) attach, resume a hold once there is
    // runway, and APPEND the next stretch to the on-air voice from a fresh open (an open sees only
    // the bytes present at open time; chained segments render bit-identical to one). Only a
    // segment that reaches the window's END arms the end handler — a frontier is not the end.
    // Complete: the adopted burn file (under its scope) replaces the partial, and this is an
    // ordinary local file from then on (`onMainStreamFinished`). Dead (`failed`): what arrived is
    // final (`mainTruncated`) — stems on air keep carrying; the full song plays up to its last
    // frame and then hands the row back to the host (`onMainStreamFailed`, the plain stream).

    /// The buffer stream the full song is growing from (nil once complete / dead / never).
    @ObservationIgnored private var mainStream: MixStreamLoader.Stream?
    /// Where the growing file currently lives (its Caches partial, then the adopted burn).
    @ObservationIgnored private var mainURL: URL?
    @ObservationIgnored private var mainStreamWindowMs: Int?
    @ObservationIgnored private var mainBytesPerSecond: Double?
    /// The growing file has no full-length header: it attaches only once complete.
    @ObservationIgnored private var mainHeaderless = false
    /// The schedulable frontier (file frames) while growing — or the FINAL last frame of a dead
    /// stream (`mainTruncated`). nil ⇒ the whole slice is there.
    @ObservationIgnored private var mainFrontierFrame: AVAudioFramePosition?
    /// How far the full song's voice is scheduled (file frames) — the append cursor.
    @ObservationIgnored private var mainScheduledEnd: AVAudioFramePosition = 0
    /// The stream died: `mainFrontierFrame` is its last frame for good.
    @ObservationIgnored private(set) var mainTruncated = false
    /// First audio not yet rendered since `engageStreaming` (fires `onFirstAudio` once).
    @ObservationIgnored private var firstAudioOwed = false
    /// A growing-file engagement has not started rendering yet (the host's start watchdog).
    var awaitingFirstAudio: Bool { firstAudioOwed }
    /// A TRACK START (vs. a mid-song hand-off): the first start needs only the start runway.
    @ObservationIgnored private var startRunwayOwed = false
    @ObservationIgnored private var progressListenerId: UUID?
    /// The full song is still downloading (OBSERVED — the chip / the panel).
    private(set) var isStreamingMain = false
    /// Play intent, but HELD at `pausedAt` waiting for bytes (OBSERVED — "Buffering…").
    private(set) var isBuffering = false
    /// When the current hold began (nil when not holding).
    @ObservationIgnored private(set) var bufferingSince: Date?
    /// Fired once, deferred, when the voices first start after `engageStreaming`.
    @ObservationIgnored var onFirstAudio: (() -> Void)?
    /// The full song must play past the last frame of its DEAD stream (and no stems carry it):
    /// the host takes the row back at this song second (deferred). nil ⇒ the song ends there.
    @ObservationIgnored var onMainStreamFailed: ((Double) -> Void)?
    /// The growing file completed — its final (adopted) location.
    @ObservationIgnored var onMainStreamFinished: ((URL) -> Void)?
    /// A hold began (true) / ended (false).
    @ObservationIgnored var onBufferingChange: ((Bool) -> Void)?

    // MARK: Render-clock scrubber (song-relative seconds; NOT observed → position reads don't relayout)
    //
    // Derived from the PLAYING node's render clock (`playerTime.sampleTime`), NOT wall time — exactly
    // like `MixEngine.truePlayhead`. The player renders SOURCE samples at `rate×` wall speed (the
    // downstream time-stretch pulls faster/slower), so `sampleTime / sr` already advances at the true
    // tempo — no rate rebasing needed, and it stays drift-free against what you actually hear. Pure
    // wall-clock would diverge at any tempo ≠ 1× (a pause→resume would seek to the wrong spot and the
    // lock-screen elapsed / durable-session position would be wrong). `pausedAt` is the fallback the
    // getter returns while paused or before the scheduled voice has begun rendering.

    /// The node whose render clock IS the playhead — the single file's `player`, or (in stem mode) the
    /// lead stem node. nil when nothing is scheduled. Not `weak`: every node here is already owned by
    /// `self` (the `player` `let` / the `stemNodes` dictionary), so a plain ref makes no retain cycle.
    @ObservationIgnored private var clockNode: AVAudioPlayerNode?
    /// `clockNode`'s file sample rate (a stem can differ from the main file's).
    @ObservationIgnored private var clockSR: Double = 0
    /// The SONG-relative seconds at which `clockNode`'s CURRENT scheduled segment begins — added back
    /// to `sampleTime / sr` (which resets to 0 on every `scheduleSegment`) to recover song position.
    @ObservationIgnored private var segStartSongSeconds: Double = 0
    @ObservationIgnored private var pausedAt: Double = 0

    // MARK: Ephemeral control state (observed — the panel binds to these)

    private var _rate = 1.0
    private var _pitch = 0.0
    private var _volume = 1.0
    private var _effectOn: [String: Bool] = [:]
    private var _effectStrength: [String: Double] = [:]
    private var _stemMode = false
    private var _stemMuted: Set<String> = []
    private var _stemVol: [String: Double] = [:]

    // MARK: Observed status

    private(set) var isEngaged = false
    private(set) var isPlaying = false
    /// The current song's slice length in seconds (the DSP's own 0…duration coordinate).
    private(set) var duration: Double = 0
    /// The song whose audio this engine currently owns (nil when idle).
    private(set) var loadedSongId: String?
    /// True when the engaged song has burned stems on disk (drives the stem sub-section; a track can
    /// be DSP-able for tempo/pitch/gain/effects yet have NO stems).
    private(set) var stemsAvailable = false
    /// STEM LOCK: stem parts NOT wired while a PARTIAL set is (empty when nothing is wired or all
    /// four are). A part listed here is silent until it lands on disk and joins (`stemPartsLanded`).
    private(set) var unwiredStemParts: Set<String> = []

    // MARK: Stem Lock seams (`SetlistPlayer` drives these — see `SetlistPlayer` "Stem Lock")

    /// The parts a stems request may go on air WITHOUT waiting for the rest — the carried set's
    /// ENABLED (un-muted) parts. nil (the default, and after every engage/disengage) = all four,
    /// i.e. exactly the pre-Stem-Lock behaviour. Only the BURNED-on-disk lane honours it: a set
    /// that has to stream still streams (and waits for) all four parts.
    @ObservationIgnored var stemPartsRequired: Set<String>?
    /// Fired after a USER-facing stem control changed the stem state (`setStemMode` accepted,
    /// `toggleStemMute`, `setStemVolume`) — never by `applyStemMode` / `applyCarriedStemControls`
    /// or an internal drop (a failed stream / an underrun), so the state a Stem Lock carries is
    /// only ever changed by the listener.
    @ObservationIgnored var onUserStemChange: (() -> Void)?
    /// Fired when a handover to the stems COMMITS (`cutToStems`) with the engaged song's id —
    /// the Stem Lock handover-timing line.
    @ObservationIgnored var onStemsOnAir: ((String) -> Void)?

    /// Fired when the engaged song's slice plays to its natural end — `SetlistPlayer` owns this to
    /// auto-advance the set while the DSP owns the audio (the AVPlayer's own end hooks are idle then).
    @ObservationIgnored var onReachedEnd: (() -> Void)?

    init(burns: BurnStore) {
        self.burns = burns
    }

    // MARK: - Read accessors (the panel + tests)

    var rate: Double { _rate }
    var pitch: Double { _pitch }
    var volume: Double { _volume }
    func isEnabled(_ effect: MixEngine.Effect) -> Bool { _effectOn[effect.rawValue] ?? false }
    func strength(_ effect: MixEngine.Effect) -> Double { _effectStrength[effect.rawValue] ?? 0.5 }
    /// Stem mode as the USER asked for it (drives the toggle): on stems or loading them, and not
    /// on the way back to the full song. The voice actually on air is `stemsOnAir`.
    var stemMode: Bool {
        switch _stemHandover {
        case .toStems?: return true
        case .toFullMix?: return false
        case nil: return _stemMode
        }
    }
    /// The stems carry the audio right now (the voice of record).
    var stemsOnAir: Bool { _stemMode }
    /// The pending handover (nil when on the voice the intent asks for). Observable.
    var stemHandover: MixEngine.StemHandover? { _stemHandover }
    /// "Loading stems…": stems asked for, the full song still on air while they arrive.
    var stemsLoading: Bool { _stemHandover == .toStems }
    func isStemMuted(_ name: String) -> Bool { _stemMuted.contains(name) }
    func stemVolume(_ name: String) -> Double { _stemVol[name] ?? 1.0 }
    /// The muted parts (the Stem Lock capture).
    var mutedStems: Set<String> { _stemMuted }
    /// The per-part gains the user moved (the Stem Lock capture).
    var stemVolumes: [String: Double] { _stemVol }

    /// Current song-relative position (seconds), read off the PLAYING node's render clock (drift-free,
    /// rate-scaled; non-observable). Falls back to `pausedAt` while paused or before the scheduled
    /// voice has begun rendering — mirrors `MixEngine.truePlayhead`'s nil→`position` fallback.
    var currentTime: Double {
        if isBuffering { return min(max(0, pausedAt), duration) }   // HELD: the playhead is frozen
        let t = (isPlaying ? (livePlayhead() ?? anchoredPlayhead()) : nil) ?? pausedAt
        return min(max(0, t), duration)
    }

    /// The last live playhead reading paired with its render host time (refreshed by every
    /// `livePlayhead` read, seeded at each start). It carries the playhead through a stretch the
    /// render clock can't: the system STOPPED the engine (route change / interruption) and
    /// `lastRenderTime` is nil — before, `currentTime` fell back to `pausedAt`, the position the
    /// current SEGMENT started at, so a recovery (or a pending stem handover acting meanwhile)
    /// restarted the song minutes back.
    @ObservationIgnored private var playAnchor: (host: UInt64, song: Double)?

    /// `playAnchor` projected to now at the deck's rate (never behind the anchor — inside a start
    /// lead it reads the start position).
    private func anchoredPlayhead() -> Double? {
        guard let a = playAnchor else { return nil }
        let dt = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: a.host)
        return a.song + max(0, dt) * _rate
    }

    /// The live render-clock playhead (song-relative seconds), or nil when the clock node isn't
    /// rendering yet (just scheduled / inside the +60 ms start lead / no audio device). `sampleTime` is
    /// in the node's own sample rate and resets to 0 each `scheduleSegment`, so add back
    /// `segStartSongSeconds`; the time-stretch rate is already baked into how fast it advances, so a
    /// plain divide by the file rate yields SOURCE seconds at any tempo (the `MixEngine.truePlayhead`
    /// contract). A negative `sampleTime` (the node is scheduled but hasn't reached its start host time)
    /// reads as nil so the getter stays on `pausedAt` until real rendering begins.
    private func livePlayhead() -> Double? {
        guard let node = clockNode, clockSR > 0,
              let nodeTime = node.lastRenderTime,
              let pt = node.playerTime(forNodeTime: nodeTime),
              pt.sampleTime >= 0 else { return nil }
        let t = segStartSongSeconds + Double(pt.sampleTime) / clockSR
        if nodeTime.isHostTimeValid { playAnchor = (nodeTime.hostTime, t) }
        return t
    }

    /// True once the audio graph built + started (false on a headless host with no audio device —
    /// tests skip on it, exactly like `MixEngine.isReady`).
    var isReady: Bool { built }

    // Graph-snapshot seams (tests assert the control reached the live AU without pulling audio).
    var timePitchRate: Float { timePitch.rate }
    var timePitchPitchCents: Float { timePitch.pitch }
    var eqGlobalGain: Float { filter.globalGain }
    var reverbWetDryMix: Float { reverb.wetDryMix }
    func stemNodeVolume(_ name: String) -> Float? { stemNodes[name]?.volume }

    // Handover / alignment seams (tests listen to real samples — see `captureForTesting`).
    func mainNodePlayingForTesting() -> Bool { player.isPlaying }
    func stemNodesPlayingForTesting() -> Bool { stemNodes.values.contains { $0.isPlaying } }
    func stemFadeInFlightForTesting() -> Bool { stemFade != nil }
    func stemFetchPendingForTesting() -> Bool { stemFetchTask != nil }
    func stemEndSecondsForTesting() -> Double { stemEndSeconds }
    func stemFrontierForTesting() -> Double? { stemFrontier }
    func stemPrimeFramesForTesting() -> AVAudioFramePosition { stemPrime }
    func isStreamingStemsForTesting() -> Bool { stemStream != nil }
    /// The render frame each WIRED stem node started on (`StemSync.startFrame`) — one value
    /// when they started together.
    func stemStartFramesForTesting() -> [AVAudioFramePosition?] {
        MixEngine.stemNames.compactMap { stemFiles[$0] != nil ? stemNodes[$0] : nil }.map { StemSync.startFrame(of: $0) }
    }
    func setMainFrontierForTesting(_ seconds: Double) { mainFrontierForTesting = seconds }
    /// The growing full song's schedulable frontier / scheduled end (song seconds); nil = whole.
    func mainFrontierSecondsForTesting() -> Double? { mainFrontierSeconds }
    func mainScheduledEndSecondsForTesting() -> Double {
        sampleRate > 0 ? Double(mainScheduledEnd - segStartFrame) / sampleRate : 0
    }
    func firstAudioOwedForTesting() -> Bool { firstAudioOwed }
    var isAttachedForTesting: Bool { file != nil }
    func releaseMainFrontierForTesting() {
        mainFrontierForTesting = nil
        advanceStemHandover()
    }
    @ObservationIgnored private let capture = MixDeckCapture()
    @ObservationIgnored private var captureTapped = false
    /// TEST SEAM: the raw post-stem-merge signal (the `inputMixer`: full song + stems, pre-FX,
    /// channel 0) at sample resolution. The tap is installed on first use only — production never
    /// pays for it.
    func captureForTesting() -> MixDeckCapture {
        if built, !captureTapped {
            captureTapped = true
            let cap = capture
            inputMixer.installTap(onBus: 0, bufferSize: 1024, format: inputMixer.outputFormat(forBus: 0)) { buffer, _ in
                cap.append(buffer)
            }
        }
        return capture
    }

    // MARK: - Build (once, lazily)

    private func build() {
        guard !built else { return }
        let canonical = Self.canonicalFormat
        for n in [player, inputMixer, timePitch, comp, filter, reverb, flanger, masterLimiter] as [AVAudioNode] {
            engine.attach(n)
        }
        reverb.loadFactoryPreset(.mediumHall)
        // `player → inputMixer` carries the file's real format (set per engage); the mixer converts it
        // to canonical stereo. The chain below is pinned at canonical FOR LIFE, so a mono / 48 kHz /
        // odd file never reconfigures (and crashes) a live AU.
        engine.connect(player, to: inputMixer, format: canonical)
        engine.connect(inputMixer, to: timePitch, format: canonical)
        engine.connect(timePitch, to: comp, format: canonical)
        engine.connect(comp, to: filter, format: canonical)
        engine.connect(filter, to: reverb, format: canonical)
        engine.connect(reverb, to: flanger, format: canonical)
        engine.connect(flanger, to: engine.mainMixerNode, format: canonical)
        // Master PEAK LIMITER between the mixer and the device — the >unity gain boost (up to +6 dB on
        // the EQ globalGain) plus the compressor's makeup gain can sum past 0 dBFS; the limiter catches
        // those peaks. Transparent below threshold.
        engine.connect(engine.mainMixerNode, to: masterLimiter, format: canonical)
        engine.connect(masterLimiter, to: engine.outputNode, format: canonical)
        // Four stem nodes summing into the SAME inputMixer → they ride the deck's tempo/pitch/effects/
        // gain for free. Idle (canonical) until stem mode wires real files at each file's format.
        var nodes: [String: AVAudioPlayerNode] = [:]
        for name in MixEngine.stemNames {
            let sn = AVAudioPlayerNode()
            engine.attach(sn)
            engine.connect(sn, to: inputMixer, format: canonical)
            nodes[name] = sn
        }
        stemNodes = nodes
        engine.prepare()
        // Soft-fail: no audio device (a headless CI / unit-test host) leaves the graph unbuilt and
        // `isReady` false — the panel simply won't engage rather than crashing.
        do { try engine.start() } catch { return }
        built = true
        registerEngineStopHandling()
    }

    // MARK: - The system stopping the engine (route change / interruption)
    //
    // An I/O configuration change (headphones ⇄ speaker ⇄ Bluetooth, a sample-rate flip) or an
    // interruption (a call) STOPS this engine behind our back: `isPlaying` stayed true over dead
    // air until the user tapped ⏸ ▶ twice — and both that resume and any stem handover acting
    // meanwhile restarted from `pausedAt`, the CURRENT SEGMENT's start (now `playAnchor`).

    @ObservationIgnored private var configChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    /// `.began` paused a PLAYING song — `.ended` (`.shouldResume`) resumes only that.
    @ObservationIgnored private var interruptedWhilePlaying = false

    private func registerEngineStopHandling() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEngineConfigurationChange() }
        }
        #if canImport(UIKit) && !os(macOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let info = note.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
            MainActor.assumeIsolated { self?.handleInterruption(began: type == .began, shouldResume: shouldResume) }
        }
        #endif
    }

    /// The engine was stopped + reconfigured: restart the song AT its playhead (the graph is
    /// pinned at the canonical format, so nothing needs re-wiring). A stem handover in flight
    /// lands first; a pending one re-checks once the voices are back.
    private func handleEngineConfigurationChange() {
        guard isEngaged, isPlaying else { return }
        if isBuffering { _ = startEngineIfNeeded(); return }   // nothing scheduled: just keep the engine up
        let pos = currentTime
        NPLog.trace("npdsp engine config change @\(String(format: "%.2f", pos))s — restarting")
        settleStemFade()
        guard pos < duration - 0.05 else { reportEndDeferred(true); return }   // `resume` would restart at 0:00
        isPlaying = false
        pausedAt = pos
        resume()
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            if isPlaying { interruptedWhilePlaying = true; pause() }
        } else {
            guard interruptedWhilePlaying, shouldResume, isEngaged, !isPlaying else {
                interruptedWhilePlaying = false
                return
            }
            interruptedWhilePlaying = false
            resume()
        }
    }

    /// MEDIA SERVICES RESET (np-mix-mode §4.4): mediaserverd restarted, so this graph is orphaned —
    /// re-engaging it would "play" into nothing (dead air on every later track of a Stem Lock
    /// session, which engages at each start). Drop any engagement and RECREATE the engine + every
    /// node; the next `engage` builds the fresh graph lazily. The caller (`SetlistPlayer`) has
    /// already put the track back on the AVPlayer. Controls are kept (they re-apply on build).
    func rebuildAfterMediaReset() {
        if isEngaged { _ = disengage() }
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o); interruptionObserver = nil }
        if captureTapped { inputMixer.removeTap(onBus: 0); captureTapped = false }
        if engine.isRunning { engine.stop() }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        inputMixer = AVAudioMixerNode()
        timePitch = AVAudioUnitTimePitch()
        comp = AVAudioUnitEffect(audioComponentDescription: Self.dynamicsDesc)
        filter = AVAudioUnitEQ(numberOfBands: 1)
        reverb = AVAudioUnitReverb()
        flanger = AVAudioUnitDelay()
        masterLimiter = AVAudioUnitEffect(audioComponentDescription: Self.limiterDesc)
        stemNodes = [:]
        built = false
        mediaResetRebuilds += 1
        NPLog.trace("npdsp media services reset → graph recreated (rebuilds on next engage)")
    }
    /// Graph recreations after a media-services reset (diagnostics + tests).
    @ObservationIgnored private(set) var mediaResetRebuilds = 0

    /// TEST SEAM: the system stops the engine (`stopOnly`), and then — unless `stopOnly` — posts
    /// its configuration change.
    func simulateEngineStopForTesting(stopOnly: Bool = false) {
        engine.stop()
        if !stopOnly { handleEngineConfigurationChange() }
    }
    func simulateInterruptionForTesting(began: Bool, shouldResume: Bool = true) {
        if began { engine.stop() }
        handleInterruption(began: began, shouldResume: shouldResume)
    }

    // MARK: - Engage / disengage (the AVPlayer → DSP hand-off, driven by SetlistPlayer)

    /// Take over `url` (a local burned/studio file) AT the current playback position. `startMs` is the
    /// song's start within a shared analog album mp3 (nil for a per-song file); `lengthMs` bounds the
    /// song's slice inside that shared file; `atSeconds` is the SONG-RELATIVE position to resume from
    /// (i.e. `AVPlayer.currentTime − startMs/1000`). `play` starts audio immediately (the AVPlayer was
    /// playing). Opening the file is synchronous on the main actor — the same as `MixEngine.loadFile` /
    /// `StemPlayer.load`; a very large analog side could hitch here (see the header note).
    func engage(url: URL, startMs: Int?, lengthMs: Int?, atSeconds: Double, songId: String?,
                play: Bool, release: (() -> Void)? = nil) {
        build()
        guard built else { release?(); return }
        guard let f = try? AVAudioFile(forReading: url) else { release?(); return }   // unreadable / corrupt
        let sr = f.processingFormat.sampleRate
        let total = f.length
        let segStart = min(max(0, AVAudioFramePosition((Double(startMs ?? 0) / 1000.0) * sr)), total)
        let available = total - segStart
        let windowed = lengthMs.map { AVAudioFramePosition((Double($0) / 1000.0) * sr) }
        let count = windowed.map { min(available, max(0, $0)) } ?? available
        guard count > 0 else { release?(); return }   // over-length startMs / empty file — refuse the swap

        resetStemIntent()                              // a prior engage's stems/request/stream go
        _stemMode = false
        stemPartsRequired = nil                        // a Stem Lock carry re-states it per track
        fileRelease?()                                 // release a prior engage's scope
        fileRelease = release
        resetMainStream()                              // a complete file: no growing state
        file = f
        sampleRate = sr
        segStartFrame = segStart
        segEndFrame = segStart + count
        duration = Double(count) / sr
        loadedSongId = songId
        stemsAvailable = songId.map { stemsObtainable($0) } ?? false
        isEngaged = true

        // Bind the varying `player → inputMixer` link to the file's real format (only that link).
        engine.connect(player, to: inputMixer, format: f.processingFormat)
        applyRate(); applyPitch(); applyVolume()
        for e in MixEngine.Effect.allCases { applyEffect(e) }

        let pos = min(max(0, atSeconds), duration)
        pausedAt = pos
        isPlaying = false
        if play { startAudio(fromSongSeconds: pos) }
    }

    /// GROWING FILE (np-mix-mode phase 3): take over a ripped row from its `MixStreamLoader`
    /// buffer stream — the song plays WHILE it downloads, so its controls are live from the first
    /// second. `atSeconds` is song-relative (a restore-resume / a mid-song hand-off); `play`
    /// starts audio at once when there is runway there and otherwise HOLDS ("Buffering…") until
    /// the bytes arrive. `atTrackStart`: a fresh track needs only the start runway (2 s); a
    /// mid-song hand-off the resume runway (4 s). `requireRunway` (the hand-off from a plain
    /// player that is still sounding): refuse — touching NOTHING — unless the stream can play at
    /// `atSeconds` right now, so the caller never trades sound for a hold. Returns false when it
    /// refused (no audio device, a dead stream, a file AVAudioFile can't decode by its extension,
    /// no runway under `requireRunway`).
    @discardableResult
    func engageStreaming(_ s: MixStreamLoader.Stream, lengthMs: Int?, atSeconds: Double, songId: String?,
                         play: Bool, atTrackStart: Bool = true, requireRunway: Bool = false) -> Bool {
        build()
        guard built, !s.failed else { return false }
        // The AVAudioFile-decodes-by-EXTENSION trap: a growing file under a neutral name would open
        // as nothing (or noise) — refuse; the caller plays the row its plain way.
        let url = s.isComplete ? (s.finalURL ?? s.fileURL) : s.fileURL
        guard GrowingFileSchedule.decodableByExtension(url) else {
            NPLog.trace("npdsp stream \(s.songId) refused — \(url.lastPathComponent) is not decodable by its extension")
            return false
        }
        if requireRunway, !Self.streamCanPlay(s, url: url, windowMs: lengthMs, at: atSeconds,
                                               runway: GrowingFileSchedule.resumeRunway) {
            return false
        }
        resetStemIntent()
        _stemMode = false
        stemPartsRequired = nil
        fileRelease?(); fileRelease = nil
        resetMainStream()
        file = nil
        sampleRate = 0
        segStartFrame = 0
        segEndFrame = 0
        mainStream = s
        mainURL = url
        isStreamingMain = true
        mainStreamWindowMs = lengthMs
        duration = Double(lengthMs ?? Self.fallbackDurationMs) / 1000   // provisional until the header
        loadedSongId = songId
        stemsAvailable = songId.map { stemsObtainable($0) } ?? false
        isEngaged = true
        firstAudioOwed = true
        startRunwayOwed = atTrackStart
        applyRate(); applyPitch(); applyVolume()
        for e in MixEngine.Effect.allCases { applyEffect(e) }
        pausedAt = max(0, atSeconds)
        isPlaying = false
        playAnchor = nil
        pumpMain()                                     // attach now if the header is already there
        NPLog.trace("npdsp engage STREAM \(s.songId) at=\(String(format: "%.2f", pausedAt))s play=\(play) attached=\(file != nil)")
        if play { startAudio(fromSongSeconds: pausedAt) }   // plays with runway, else HOLDS
        return true
    }

    /// Catalog length fallback for a stream whose header isn't readable yet (the Mix deck's).
    static let fallbackDurationMs = 180_000

    /// Could `s` play from `at` (song seconds) with `runway` RIGHT NOW? Opens the partial file
    /// once; mutates nothing (the `requireRunway` probe).
    private static func streamCanPlay(_ s: MixStreamLoader.Stream, url: URL, windowMs: Int?, at: Double,
                                      runway: Double) -> Bool {
        guard s.resolved, s.bytesReceived > 0 || s.isComplete, let f = try? AVAudioFile(forReading: url) else { return false }
        let sr = f.processingFormat.sampleRate
        let w = GrowingFileSchedule.window(fileLength: f.length, sampleRate: sr,
                                           startMs: s.isCut ? nil : s.startMs, windowMs: s.isCut ? nil : windowMs)
        guard sr > 0, w.count > 0 else { return false }
        let fullEnd = w.start + w.count
        let pos = w.start + AVAudioFramePosition(max(0, at) * sr)
        guard pos < fullEnd else { return false }
        let bps = GrowingFileSchedule.bytesPerSecond(totalFrames: f.length, sampleRate: sr, expectedBytes: s.expectedBytes)
        let frontier = GrowingFileSchedule.frontier(bytes: s.bytesReceived, complete: s.isComplete, bytesPerSecond: bps,
                                                    sampleRate: sr, start: w.start, fullEnd: fullEnd)
        return GrowingFileSchedule.canStart(position: pos, frontier: frontier, fullEnd: fullEnd,
                                            complete: s.isComplete, runway: runway, sampleRate: sr)
    }

    /// Forget every growing-file fact (the stream itself keeps downloading — every stream
    /// completes, and the finished file is adopted as a burn).
    private func resetMainStream() {
        mainStream = nil
        mainURL = nil
        mainStreamWindowMs = nil
        mainBytesPerSecond = nil
        mainHeaderless = false
        mainFrontierFrame = nil
        mainScheduledEnd = 0
        mainTruncated = false
        firstAudioOwed = false
        startRunwayOwed = false
        if isStreamingMain { isStreamingMain = false }
        if isBuffering { isBuffering = false }
        bufferingSince = nil
    }

    /// Seek the engaged song to `t` (song seconds) — the card / CarPlay scrubber and the inline
    /// row scrubber route here while the DSP owns the audio. Playing: rescheduled from the target
    /// (on the stems or the full song, whichever the intent asks and can carry it); a target past
    /// a growing file's frontier HOLDS there and resumes once the bytes arrive (never from the
    /// frontier, never from 0:00). Paused: the target is where ▶ resumes.
    func seek(toSongSeconds t: Double) {
        guard isEngaged else { return }
        let target = min(max(0, t), max(0, duration - 0.05))
        settleStemFade()
        if isPlaying {
            startAudio(fromSongSeconds: target)
            advanceStemHandover()
            refreshStemMonitor()
        } else {
            pausedAt = target
            playAnchor = nil
        }
        NPLog.trace("npdsp seek → \(String(format: "%.2f", target))s playing=\(isPlaying) holding=\(isBuffering)")
    }

    /// Hand the audio back: stop everything, release scopes, and RETURN the current SONG-RELATIVE
    /// position (seconds) so the caller can reload the AVPlayer there (`startMs + position`). Does NOT
    /// reset the control state — `resetControls()` is the separate ephemeral clear.
    @discardableResult
    func disengage() -> Double {
        let pos = currentTime
        resetStemIntent()                       // stale-proofs any fetch/stream/fade (track change)
        stopVoices(main: true, stems: true)
        if engine.isRunning { engine.stop() }   // idle the graph so the AVPlayer owns audio alone
        interruptedWhilePlaying = false
        playAnchor = nil
        file = nil
        resetMainStream()
        _stemMode = false
        fileRelease?(); fileRelease = nil
        isPlaying = false
        isEngaged = false
        loadedSongId = nil
        stemsAvailable = false
        stemPartsRequired = nil
        pausedAt = 0
        duration = 0
        clockNode = nil
        clockSR = 0
        segStartSongSeconds = 0
        return pos
    }

    /// Reset EVERY control to neutral (rate 1, pitch 0, gain 100%, effects off, effect strengths 0.5,
    /// stems off + un-muted). Ephemeral in-memory clear — no persistence. Applies to the live graph
    /// when built so a re-engage starts truly neutral.
    func resetControls() {
        _rate = 1.0
        _pitch = 0.0
        _volume = 1.0
        _effectOn = [:]
        _effectStrength = [:]
        _stemMode = false
        _stemHandover = nil
        _stemMuted = []
        _stemVol = [:]
        guard built else { return }
        applyRate(); applyPitch(); applyVolume()
        for e in MixEngine.Effect.allCases { applyEffect(e) }
    }

    // MARK: - Transport (the home-deck ⏯ / lock-screen commands route here while engaged)

    func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime
        if isBuffering { setBuffering(false) }   // a held playhead just becomes a paused one
        settleStemFade()                         // never park a half-faded handover
        player.pause()
        for n in stemNodes.values { n.pause() }
        isPlaying = false
    }

    func resume() {
        guard isEngaged, !isPlaying else { return }
        startAudio(fromSongSeconds: currentTime >= duration ? 0 : currentTime)
        advanceStemHandover()                    // a pending handover may be ready now it plays
        refreshStemMonitor()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    // MARK: - Controls (copied near-verbatim from MixEngine, single-deck, no record/persist)

    func setRate(_ rate: Double) {
        _rate = min(max(rate, MixEngine.rateRange.lowerBound), MixEngine.rateRange.upperBound)
        applyRate()
    }

    func setPitch(_ semitones: Double) {
        _pitch = min(max(semitones, MixEngine.pitchRange.lowerBound), MixEngine.pitchRange.upperBound)
        applyPitch()
    }

    func setVolume(_ v: Double) {
        _volume = min(max(v, MixEngine.volumeRange.lowerBound), MixEngine.volumeRange.upperBound)
        applyVolume()
    }

    func setEffect(_ effect: MixEngine.Effect, enabled: Bool) {
        _effectOn[effect.rawValue] = enabled
        applyEffect(effect)
    }

    func setEffectStrength(_ effect: MixEngine.Effect, _ strength: Double) {
        _effectStrength[effect.rawValue] = min(max(strength, 0), 1)
        applyEffect(effect)
    }

    /// Ask for the stems (on) or the full song (off). Records INTENT; the audio follows under the
    /// ZERO-DEAD-AIR rule (see the handover MARK above): stems on disk switch at once on a paused
    /// track and cross over at the playhead on a playing one; stems NOT on disk are streamed (or
    /// fetched) while the full song plays on — "Loading stems…" — and taken over once buffered.
    /// Off waits the same way for the full song's runway. Returns FALSE (touching nothing) only
    /// when the track has no stems ANYWHERE — not on disk, not in the catalog — so the panel can
    /// degrade the stem sub-section while tempo/pitch/gain/effects keep working. Ephemeral like
    /// every control here — nothing is persisted.
    ///
    /// GENERATION DISCIPLINE (the stems-toggle-skips-the-song regression): `AVAudioPlayerNode.stop()`
    /// FIRES the flushed segment's completion handler, so every stop must be preceded by a
    /// `generation` bump — at the COMMIT point (`cutToStems` / `cutToFullMix`), not the top of the
    /// function — or the flushed completion passes `handleReachedEnd`'s staleness guard, fakes a
    /// natural end, and `SetlistPlayer` advances the set mid-song. A top-of-function bump is just as
    /// wrong the other way: the refusal / still-pending paths leave the main file playing with an
    /// end handler whose generation no longer matches, so the track would play out and never
    /// auto-advance. Pending requests therefore never touch `generation` at all. On the ON commit
    /// the bump precedes scheduling the stems (they capture the new generation) and the main file
    /// keeps sounding until they verifiably scheduled ("schedule stems, verify, THEN stop main;
    /// re-arm main on failure").
    @discardableResult
    func setStemMode(_ on: Bool) -> Bool {
        let ok = applyStemMode(on)
        if ok { onUserStemChange?() }
        return ok
    }

    /// `setStemMode` minus the user-change notification — the Stem Lock's carry-forward.
    @discardableResult
    func applyStemMode(_ on: Bool) -> Bool {
        guard isEngaged, built, let songId = loadedSongId else { return false }
        stemIntentGen &+= 1                      // any in-flight fetch for the old intent is stale
        stemFetchTask?.cancel(); stemFetchTask = nil
        if on {
            if _stemMode {
                _stemHandover = nil              // on its way back to the full song? stay on stems
                refreshStemMonitor()
                return true
            }
            if stemFiles.isEmpty || (stemFrontier != nil && stemStream == nil), !wireStems() {
                guard stemsObtainable(songId) else { return false }   // refused — nothing touched
                _stemHandover = .toStems
                if stemStream == nil { requestStemSource(songId) }
                advanceStemHandover()
                refreshStemMonitor()
                return true
            }
            _stemHandover = .toStems
            advanceStemHandover()
        } else {
            if !_stemMode {
                dropPendingStems()               // never got onto stems: the full song carries on
            } else {
                _stemHandover = .toFullMix
                advanceStemHandover()
            }
        }
        refreshStemMonitor()
        return true
    }

    // MARK: - Stem handover (zero dead air)

    /// Stems for `songId` exist somewhere: on disk (burned / profile), already streaming, or in
    /// the catalog (streamable / fetchable).
    private func stemsObtainable(_ songId: String) -> Bool {
        burns.stemsBurned(forSong: songId)
            || (ProfileSourceStore.isProfileSongId(songId) && profileStemResolve?(songId) != nil)
            || streamer?.stemSet(for: songId).map { !$0.failed } == true
            || burns.stemsRemote(forSong: songId)
    }

    /// Find the stems for a `.toStems` request that aren't on disk: stream them through the shared
    /// loader (its stem lane; parts are wired once their first frames land), else fetch them
    /// whole behind `stemIntentGen` — a completion for a superseded request (toggled off, a new
    /// track, disengaged) never claims anything.
    private func requestStemSource(_ songId: String) {
        if let streamer, streamer.canStreamStems(songId),
           let set = streamer.openStems(songId, owner: MixStreamLoader.nowPlayingStemOwner) {
            stemStream = set
            pumpStems()
            return
        }
        let gen = stemIntentGen
        let fetch: (String) async -> Bool = stemFetcher ?? { [burns] id in
            // `.incidental`: a Now Playing control touch is not an explicit download — it neither
            // pins a buffered song nor makes these stems temporary (np-mix-mode §3.3).
            guard let got = await burns.burnStems(forSong: id, origin: .incidental) else { return false }
            got.release?()                       // `wireStems` re-acquires (and holds) its own scope
            return true
        }
        stemFetchTask = Task { @MainActor [weak self] in
            let ok = await fetch(songId)
            guard let self, !Task.isCancelled, self.stemIntentGen == gen, self.isEngaged,
                  self.loadedSongId == songId, self._stemHandover == .toStems else { return }
            self.stemFetchTask = nil
            if ok, self.wireStems() {
                self.advanceStemHandover()
            } else {
                NPLog.trace("npdsp stems unavailable \(songId) — full song stays")
                self.dropPendingStems()
            }
            self.refreshStemMonitor()
        }
    }

    /// The single decision point: does the pending handover have what it needs NOW? Called on
    /// every event that can change the answer (the request, a stem stream pump, a fetch landing,
    /// resume, the monitor). Idempotent; never stops a voice that has no successor with runway.
    private func advanceStemHandover() {
        // A crossfade in flight finishes first (its landing re-runs this): superseding it early
        // would stop its outgoing voice before the incoming one renders — up to a start lead of
        // dead air. Rapid toggles therefore just move the intent; at most one fade runs at a time.
        guard let h = _stemHandover, isEngaged, built, stemFade == nil else { return }
        let pos = currentTime
        switch h {
        case .toStems:
            guard !stemFiles.isEmpty else { return }             // still streaming its first frames / fetching
            if stemFrontier == nil, !isPlaying { cutToStems(); return }   // complete stems, silent: just switch
            guard StemSync.handoverReady(runway: stemFrontierOrEnd() - pos, complete: stemFrontier == nil,
                                         songLeft: duration - pos) else {
                // Complete stems that can't cover the playhead never will: the full song plays on.
                if stemFrontier == nil, stemStream == nil { dropPendingStems() }
                return
            }
            cutToStems()
        case .toFullMix:
            if mainTruncated {
                // The full song's stream DIED: it can't carry the rest of the song any more — the
                // stems stay on air (the Mix deck's `mainTruncated` rule).
                NPLog.trace("npdsp full song truncated — stems stay")
                _stemHandover = nil
                return
            }
            let mf = mainFrontierSeconds
            if mf == nil, pos >= duration - 0.05 {
                cutToFullMix()                    // the slice is over — reports the end (see there)
                return
            }
            let mainEnd = min(duration, mf ?? duration)
            guard StemSync.handoverReady(runway: mainEnd - pos, complete: mf == nil,
                                         songLeft: duration - pos) else { return }
            cutToFullMix()
            releaseStemStream()                   // done with these stems: stop downloading them
        }
    }

    /// Where the full song's playable audio ends while it is still arriving / was cut short
    /// (song seconds; the test seam caps it too). nil ⇒ the whole slice.
    private var mainFrontierSeconds: Double? {
        var f = mainFrontierForTesting
        if mainStream != nil || mainTruncated {
            let reach = (file != nil && sampleRate > 0)
                ? Double((mainFrontierFrame ?? segStartFrame) - segStartFrame) / sampleRate : 0
            f = min(f ?? .infinity, reach)
        }
        return f
    }

    /// The full song is still ARRIVING (or not attached yet) and can't carry `pos` with `runway`.
    /// A complete / plain file — or a dead stream, whose audio is final — never needs bytes.
    private func mainNeedsBytes(at pos: Double, runway: Double) -> Bool {
        guard mainStream != nil else { return false }
        guard file != nil, sampleRate > 0, let fr = mainFrontierFrame else { return true }
        let posFrame = segStartFrame + AVAudioFramePosition(max(0, pos) * sampleRate)
        return !GrowingFileSchedule.canStart(position: posFrame, frontier: fr, fullEnd: segEndFrame,
                                             complete: false, runway: runway, sampleRate: sampleRate)
    }

    /// The full song's stream is DEAD and has no audio left at `pos` (or never had any).
    private func mainRanDry(at pos: Double) -> Bool {
        guard mainTruncated else { return false }
        guard file != nil, sampleRate > 0, let fr = mainFrontierFrame else { return true }
        let posFrame = segStartFrame + AVAudioFramePosition(max(0, pos) * sampleRate)
        return posFrame >= fr - AVAudioFramePosition(GrowingFileSchedule.underrunLead * sampleRate)
    }

    /// The runway a held full song needs before it may start at the playhead.
    private var mainRunwayNeeded: Double {
        startRunwayOwed ? GrowingFileSchedule.startRunway : GrowingFileSchedule.resumeRunway
    }

    /// Where the wired stems' playable audio ends (song seconds).
    private func stemFrontierOrEnd() -> Double {
        if let f = stemFrontier { return f }
        return stemFiles.values.map { StemSync.songSeconds($0, prime: stemPrime) }.min() ?? 0
    }

    /// Is the full song AUDIBLY rendering right now (not just armed inside its start lead)?
    private var mainRendering: Bool {
        guard isPlaying, engine.isRunning, !_stemMode, player.isPlaying, clockNode === player else { return false }
        return livePlayhead() != nil
    }

    private var stemsRendering: Bool {
        guard isPlaying, engine.isRunning, _stemMode, let c = clockNode, c !== player, c.isPlaying else { return false }
        return livePlayhead() != nil
    }

    /// FULL SONG → STEMS at the playhead. Audibly playing: the stems are scheduled from the main
    /// voice's exact source position at a moment ~60 ms out, started there on ONE sample frame at
    /// gain 0, and the two cross linearly; only then is the main file stopped (its completion is
    /// stale by then — the commit bumped `generation`). Paused / not yet rendering: an outright
    /// switch (the old path — nothing audible to protect).
    private func cutToStems() {
        settleStemFade()
        let pos = currentTime
        if mainRendering,
           let start = StemSync.sampleStart(clocks: stemVoices() + [inputMixer], lead: StemSync.startLead, rate: _rate),
           let p = StemSync.voicePlayhead(player, sampleRate: sampleRate, segmentStart: mainSegStartSeconds,
                                          rate: _rate, at: start),
           stemsCanSchedule(from: p) {
            // COMMIT: the main file's armed end goes stale; the stems capture the new generation.
            generation += 1
            setVoiceGains(main: 1, stems: 0)
            guard scheduleStems(fromSongSeconds: p) else {   // (pre-checked — defensive)
                // Re-arm the main file at the new generation (a brief restart beats an end that
                // would never fire).
                setVoiceGains(main: 1, stems: 1)
                rearmMain(at: pos, play: true)
                dropPendingStems()
                return
            }
            let voices = stemVoices()
            let when = voices.allSatisfy({ StemSync.sharesTimeline($0, start.when) })
                ? start.when : AVAudioTime(hostTime: start.hostTime)
            for n in voices { n.play(at: when) }
            _stemMode = true
            _stemHandover = nil
            pausedAt = p
            playAnchor = (start.hostTime, p)
            runStemFade(toStems: true, atHostTime: start.hostTime)
        } else {
            let from = stemFrontier == nil ? min(pos, maxStemSeconds()) : pos
            guard stemsCanSchedule(from: from) else { dropPendingStems(); return }
            let was = isPlaying
            generation += 1                       // COMMIT (bump precedes scheduling the stems)
            guard scheduleStems(fromSongSeconds: from) else {
                // Zero-length stems: re-arm the main file AT THE NEW generation, or its natural end
                // would be swallowed forever (play out, never advance).
                rearmMain(at: pos, play: was)
                dropPendingStems()
                return
            }
            player.stop()                         // stale completion → generation mismatch → ignored
            _stemMode = true
            _stemHandover = nil
            applyStemGains()
            if was { startScheduled(stemMode: true, fromSongSeconds: from) } else { pausedAt = pos }
        }
        NPLog.trace("npdsp → stems @\(String(format: "%.2f", pos))s")
        if _stemMode, let id = loadedSongId { onStemsOnAir?(id) }
        refreshStemMonitor()
    }

    /// STEMS → FULL SONG at the playhead — `cutToStems` mirrored. Nothing schedulable (at/past the
    /// slice end): the track IS over — reported like a natural end, DEFERRED so `onReachedEnd`
    /// (which tears this engine down via `SetlistPlayer.handleDSPEnded` → `disengage`) never
    /// re-enters mid-call.
    private func cutToFullMix() {
        settleStemFade()
        let pos = currentTime
        let was = isPlaying
        // (The runway covers the crossfade's start lead at this tempo: the full song is scheduled
        // from the stems' playhead ~60 ms of HOST time out — past a frontier closer than that,
        // `scheduleMain` would find nothing and fake the song's end.)
        let lead = StemSync.startLead * max(1, _rate)
        let dry = mainRanDry(at: pos + lead)
        if mainNeedsBytes(at: pos, runway: 0.1 + lead) || dry {
            // The full song can't carry the playhead: still arriving (HOLD there — the pump
            // resumes it with runway) or its stream died before reaching it (the host takes the
            // row back). Never a "natural end" mid-song.
            stopVoices(main: false, stems: true)
            _stemMode = false
            _stemHandover = nil
            if !was { pausedAt = pos }
            else if dry { mainRanOut(at: pos) }
            else { holdMain(at: pos) }
            NPLog.trace("npdsp → full song @\(String(format: "%.2f", pos))s — \(isBuffering ? "held for bytes" : "unavailable")")
            refreshStemMonitor()
            return
        }
        if stemsRendering,
           let start = StemSync.sampleStart(clocks: stemVoices() + [inputMixer], lead: StemSync.startLead, rate: _rate),
           let p = stemPlayhead(at: start), p < duration - 0.05 {
            generation += 1                       // COMMIT: the lead stem's armed end goes stale
            guard scheduleMain(fromSongSeconds: p) else { reportEndDeferred(was); return }
            mainVoiceGain = 0
            player.volume = 0
            player.play(at: StemSync.onClock(player, start.when) ? start.when : AVAudioTime(hostTime: start.hostTime))
            _stemMode = false
            _stemHandover = nil
            pausedAt = p
            playAnchor = (start.hostTime, p)
            runStemFade(toStems: false, atHostTime: start.hostTime)
        } else {
            stopVoices(main: false, stems: true)  // invalidate the lead stem's armed end, then flush
            _stemMode = false
            _stemHandover = nil
            guard scheduleMain(fromSongSeconds: pos) else { reportEndDeferred(was); return }
            if was { startScheduled(stemMode: false, fromSongSeconds: pos) } else { pausedAt = pos }
        }
        NPLog.trace("npdsp → full song @\(String(format: "%.2f", pos))s")
        refreshStemMonitor()
    }

    /// The track is over (nothing schedulable at the playhead): coherent stopped state + ONE end.
    private func reportEndDeferred(_ was: Bool) {
        stopVoices(main: true, stems: true)
        _stemMode = false
        _stemHandover = nil
        isPlaying = false
        pausedAt = duration
        if was { Task { @MainActor [weak self] in self?.onReachedEnd?() } }
    }

    /// The stems' source position at the handover moment (all four share one start frame).
    private func stemPlayhead(at start: StemSync.Start) -> Double? {
        for name in MixEngine.stemNames {
            guard let n = stemNodes[name], n.isPlaying, let f = stemFiles[name] else { continue }
            if let p = StemSync.voicePlayhead(n, sampleRate: f.processingFormat.sampleRate,
                                              segmentStart: stemSegStartSeconds, rate: _rate, at: start) { return p }
        }
        return nil
    }

    /// The wired stem nodes, canonical order (vocals first — the lead/clock stem).
    private func stemVoices() -> [AVAudioPlayerNode] {
        MixEngine.stemNames.compactMap { stemFiles[$0] != nil ? stemNodes[$0] : nil }
    }

    /// Would `scheduleStems(fromSongSeconds:)` schedule anything from `sec`? Pure.
    private func stemsCanSchedule(from sec: Double) -> Bool {
        if let f = stemFrontier, sec >= f { return false }
        return stemFiles.values.contains { f in
            f.length - StemSync.frame(f, prime: stemPrime, atSeconds: sec) > 0
        }
    }

    /// Step the handover crossfade (`StemSync.crossfade`); landing it stops the outgoing voice.
    private func runStemFade(toStems: Bool, atHostTime t: UInt64) {
        stemFadeGen &+= 1
        let gen = stemFadeGen
        let task = StemSync.crossfade(atHostTime: t,
            alive: { [weak self] in self?.stemFadeGen == gen },
            apply: { [weak self] g in self?.setVoiceGains(main: toStems ? 1 - g : g, stems: toStems ? g : 1 - g) },
            done: { [weak self] in
                self?.settleStemFade()
                self?.advanceStemHandover()       // the intent may have moved while it faded
                self?.refreshStemMonitor()
            })
        stemFade = (toStems, task)
    }

    /// Land an in-flight crossfade NOW: the outgoing voice stops (its completion already stale —
    /// the cut bumped `generation`), both gains return to 1. Every path that stops, re-schedules
    /// or pauses the voices calls this first. No-op when nothing is fading. An intent that moved
    /// during the fade (`advanceStemHandover` defers to it) is re-checked once the caller's
    /// transport action has finished — a fade cut short by a PAUSE must not strand it ("Loading
    /// full mix…" on a paused song, with no monitor running to finish it).
    private func settleStemFade() {
        guard let f = stemFade else { return }
        stemFade = nil
        stemFadeGen &+= 1
        f.task.cancel()
        if f.toStems { player.stop() } else { for n in stemNodes.values { n.stop() } }
        setVoiceGains(main: 1, stems: 1)
        if _stemHandover != nil {
            let intent = stemIntentGen
            Task { @MainActor [weak self] in
                guard let self, self.stemIntentGen == intent else { return }
                self.advanceStemHandover()
                self.refreshStemMonitor()
            }
        }
    }

    private func setVoiceGains(main: Float, stems: Float) {
        mainVoiceGain = main
        player.volume = main
        stemVoiceGain = stems
        applyStemGains()
    }

    /// Drop a `.toStems` request (failed, superseded, toggled off): unwire stems that never went on
    /// air and stop streaming them. The full song never stopped.
    private func dropPendingStems() {
        _stemHandover = nil
        stemFetchTask?.cancel(); stemFetchTask = nil
        // (Mid-fade the stems may still be the outgoing voice — leave them to the fade.)
        if !_stemMode, stemFade == nil { unwireStems() }
        refreshStemMonitor()
    }

    /// Stop streaming the stems (unless the set already finished — it's adopted as burned stems).
    /// What arrived stays wired (`stemFrontier` keeps bounding it) until unwired.
    private func releaseStemStream() {
        guard let set = stemStream else { return }
        stemStream = nil
        if !set.isComplete { streamer?.cancelStems(set.songId, owner: MixStreamLoader.nowPlayingStemOwner) }
    }

    /// Forget the stem INTENT entirely (track change / disengage / re-engage): stale-proof any
    /// fetch, land any fade, drop the request, unwire.
    private func resetStemIntent() {
        stemIntentGen &+= 1
        stemFetchTask?.cancel(); stemFetchTask = nil
        _stemHandover = nil
        settleStemFade()
        unwireStems()
        stemMonitor?.cancel(); stemMonitor = nil
        mainFrontierForTesting = nil
    }

    // MARK: Stem streaming (stems played while they download)

    /// The loader's stem fan-in.
    private func stemStreamProgressed(_ songId: String) {
        guard stemStream?.songId == songId else { return }
        pumpStems()
    }

    /// Extend the STREAMING stems to the new frontier: wire the four parts once each has a
    /// decodable frame, append the next stretch to all four nodes in lockstep while they're on
    /// air (same seconds on every part ⇒ still sample-locked), and let a pending handover re-check
    /// its runway. A failed set: a pending request drops; stems on air hand back to the full song.
    private func pumpStems() {
        guard let set = stemStream, built, isEngaged else { return }
        if set.failed {
            stemStream = nil                      // the leftover frontier keeps bounding what's scheduled
            NPLog.trace("npdsp stem stream failed \(set.songId)")
            if !_stemMode {
                dropPendingStems()
            } else {
                _stemHandover = .toFullMix
                advanceStemHandover()
            }
            return
        }
        let fallback = CollectionMixDownloader.bytesPerPlaybackSecond
        let onAir = _stemMode
        // RE-OPEN THROTTLE (the Mix pump's): an open sees only the bytes present, and four parts
        // each report ~4×/s — re-open once the slowest part moved a real step past the last open
        // (on air: a whole append chunk past the scheduled end).
        if !set.isComplete, !stemFiles.isEmpty {
            let byBytes = StemSync.bytesSeconds(set, songSeconds: duration, fallbackBytesPerSecond: fallback)
            guard byBytes >= stemOpenedBytesSeconds + 0.5 else { return }
            if onAir {
                guard byBytes - stemEndSeconds >= MixEngine.stemAppendChunk(runway: stemEndSeconds - currentTime) else { return }
            }
        }
        guard let src = StemSync.partURLs(set, adopted: { [burns] in burns.localStemURLs(forSong: $0) }) else { return }
        let prime = stemFiles.isEmpty
            ? (src.urls[MixEngine.stemNames[0]].map { StemSync.mp3PrimingFrames(ofFileAt: $0) } ?? 0) : stemPrime
        guard let opened = StemSync.openStreamingParts(set, urls: src.urls, prime: prime, songSeconds: duration,
                                                       fallbackBytesPerSecond: fallback),
              opened.files.count == MixEngine.stemNames.count else { src.scope?(); return }
        if stemFiles.isEmpty {
            guard opened.frontier > 0.05, wireStemFiles(opened.files, release: src.scope) else { src.scope?(); return }
        } else {
            if onAir, opened.frontier > stemEndSeconds + 0.01 {
                appendStems(opened.files, from: stemEndSeconds, to: opened.frontier, final: set.isComplete)
            }
            // ALWAYS hold the newest opens: `stemFrontier` must never run ahead of the files.
            stemFiles = opened.files
            if let scope = src.scope { stemRelease?(); stemRelease = scope }
        }
        stemOpenedBytesSeconds = StemSync.bytesSeconds(set, songSeconds: duration, fallbackBytesPerSecond: fallback)
        stemFrontier = opened.frontier
        if set.isComplete {                       // ordinary complete stems from here on
            stemStream = nil
            stemFrontier = nil
            stemOpenedBytesSeconds = 0
        }
        advanceStemHandover()
        refreshStemMonitor()
    }

    /// Append `[from, to)` song seconds to every on-air stem node (lockstep). `final`: the parts
    /// are complete — this stretch runs to their end, so the lead's completion is the song's END
    /// (armed at the current generation).
    private func appendStems(_ files: [String: AVAudioFile], from: Double, to: Double, final: Bool) {
        let gen = generation
        let lead = MixEngine.stemNames[0]
        var reached = Double.infinity
        for (name, f) in files {
            guard let node = stemNodes[name] else { continue }
            let a = StemSync.frame(f, prime: stemPrime, atSeconds: from)
            let b = final ? f.length : StemSync.frame(f, prime: stemPrime, atSeconds: to)
            reached = min(reached, Double(max(a, b) - stemPrime) / f.processingFormat.sampleRate)
            guard b > a else { continue }
            let isEnd = final && name == lead
            let handler: AVAudioNodeCompletionHandler? = isEnd ? endHandler(gen) : nil
            node.scheduleSegment(f, startingFrame: a, frameCount: AVAudioFrameCount(b - a), at: nil, completionHandler: handler)
        }
        if reached.isFinite { stemEndSeconds = reached }
    }

    /// Keep an eye on what only TIME changes: partial stems on air closing on their frontier
    /// (hand back to the full song while they still have audio — keeping the request so they
    /// re-engage with runway), and a pending handover whose readiness depends on the playhead.
    /// Runs only while there's something to watch.
    private func refreshStemMonitor() {
        if !monitorNeeded { stemMonitor?.cancel(); stemMonitor = nil; return }
        guard stemMonitor == nil else { return }
        stemMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                self.stemMonitorTick()
                if self.stemMonitor == nil { return }
            }
        }
    }

    /// Something only TIME changes needs watching: partial stems on air, a pending handover, or
    /// a growing / cut-short full song on air closing on the end of what it could schedule.
    private var monitorNeeded: Bool {
        guard isEngaged, isPlaying else { return false }
        return (_stemMode && stemFrontier != nil) || _stemHandover != nil || mainWatchNeeded
    }
    private var mainWatchNeeded: Bool {
        isEngaged && isPlaying && !isBuffering && !_stemMode && (mainStream != nil || mainTruncated)
    }

    private func stemMonitorTick() {
        guard isEngaged, isPlaying else { stemMonitor?.cancel(); stemMonitor = nil; return }
        guard stemFade == nil else { return }
        if mainWatchNeeded { mainUnderrunCheck() }
        guard isEngaged, isPlaying else { stemMonitor?.cancel(); stemMonitor = nil; return }
        let pos = currentTime
        if _stemMode, stemFrontier != nil, stemEndSeconds < duration - 0.05,
           pos >= stemEndSeconds - StemSync.underrunLead {
            if stemStream != nil { pumpStems() }  // bytes that landed since the last open may cover it
            if _stemMode, stemFade == nil, stemFrontier != nil, stemEndSeconds < duration - 0.05,
               pos >= stemEndSeconds - StemSync.underrunLead {
                let wantStems = stemStream != nil && _stemHandover != .toFullMix
                NPLog.trace("npdsp stem underrun @\(String(format: "%.2f", pos))s → full song")
                cutToFullMix()
                if wantStems { _stemHandover = .toStems }   // intent stands; re-engage with runway
            }
        } else if _stemHandover != nil {
            advanceStemHandover()
        }
        if !monitorNeeded { stemMonitor?.cancel(); stemMonitor = nil }
    }

    // MARK: Growing file — pump, hold, append, finish, failure

    /// The full song on air reached the end of what it could schedule while more is still to
    /// come: bytes that landed since may extend it; otherwise HOLD right there (a dead stream
    /// with nothing more hands the row back instead).
    private func mainUnderrunCheck() {
        guard sampleRate > 0, file != nil else { return }
        func scheduledEndSeconds() -> Double { Double(mainScheduledEnd - segStartFrame) / sampleRate }
        let pos = currentTime
        guard GrowingFileSchedule.underrun(position: pos, scheduledEnd: scheduledEndSeconds(), duration: duration) else { return }
        if mainStream != nil { pumpMain() }
        guard mainWatchNeeded else { return }
        let end = scheduledEndSeconds()
        guard GrowingFileSchedule.underrun(position: pos, scheduledEnd: end, duration: duration) else { return }
        let at = min(pos, end)
        if mainStream != nil {
            NPLog.trace("npdsp underrun @\(String(format: "%.2f", at))s → hold (frontier \(String(format: "%.2f", mainFrontierSeconds ?? -1))s)")
            DiagLog.shared.telemetry("npmix", "dsp underrun at \(String(format: "%.1f", at))s → hold")
            holdMain(at: at)
            advanceStemHandover()                 // stems waiting with runway? they carry the song instead
        } else {
            mainRanOut(at: at)
        }
    }

    /// HOLD the full song at `pos`: nothing scheduled, the playhead frozen, play intent kept. The
    /// ENGINE keeps running (the audio session — and a locked phone — stay alive through the
    /// wait); the pump resumes it once the frontier gives it runway.
    private func holdMain(at pos: Double) {
        stopVoices(main: true, stems: false)      // generation first: the flushed segment is stale
        pausedAt = min(max(0, pos), duration)
        playAnchor = nil
        isPlaying = true
        if !isBuffering { setBuffering(true) }
        configureSession()
        _ = startEngineIfNeeded()
        refreshStemMonitor()
    }

    private func setBuffering(_ on: Bool) {
        isBuffering = on
        bufferingSince = on ? Date() : nil
        onBufferingChange?(on)
    }

    /// The full song's stream is DEAD and the playhead reached its last frame (or it never had
    /// one): with a host, hand the row back at this second (the plain stream carries on);
    /// standalone, the bytes we have ARE the song — it ends here.
    private func mainRanOut(at pos: Double) {
        stopVoices(main: true, stems: false)
        let p = min(max(0, pos), duration)
        pausedAt = p
        playAnchor = nil
        isPlaying = false
        if isBuffering { setBuffering(false) }
        refreshStemMonitor()
        NPLog.trace("npdsp full song ran dry @\(String(format: "%.2f", p))s (stream dead) → \(onMainStreamFailed != nil ? "host" : "end")")
        if let cb = onMainStreamFailed {
            Task { @MainActor in cb(p) }
        } else {
            pausedAt = duration
            Task { @MainActor [weak self] in self?.onReachedEnd?() }
        }
    }

    /// The loader's song fan-in.
    private func mainStreamProgressed(_ songId: String) {
        guard let s = mainStream, s.songId == songId else { return }
        pumpMain()
    }

    /// Extend the growing full song to the new byte frontier: attach on the first readable
    /// header, resume a HELD playhead once it has runway, append the next stretch to the voice on
    /// air, and become an ordinary file on completion. Idempotent; every progress event lands here.
    private func pumpMain() {
        guard let s = mainStream, built, isEngaged else { return }
        if s.failed { handleMainStreamFailure(); return }
        guard s.resolved, s.bytesReceived > 0 || s.isComplete else { return }
        let url = s.isComplete ? (s.finalURL ?? s.fileURL) : s.fileURL
        // An ADOPTED file lives in the burn folder now: read it under that folder's scope (a
        // user-picked folder is security-scoped), held like any engaged file's.
        if s.isComplete, s.adopted, url != mainURL, let h = burns.localURLForPlayback(forSong: s.songId) {
            if h.url.standardizedFileURL == url.standardizedFileURL {
                fileRelease?(); fileRelease = h.release
            } else {
                h.release?()
            }
        }
        mainURL = url
        if file == nil {
            // FIRST ATTACH — the header (and its full-length claim) is readable now. A file
            // already found HEADERLESS waits for completion without re-opening on every event.
            if mainHeaderless, !s.isComplete { return }
            guard let f = try? AVAudioFile(forReading: url) else {
                if s.isComplete { handleMainStreamFailure(); }
                return
            }
            let sr = f.processingFormat.sampleRate
            let w = GrowingFileSchedule.window(fileLength: f.length, sampleRate: sr,
                                               startMs: s.isCut ? nil : s.startMs,
                                               windowMs: s.isCut ? nil : mainStreamWindowMs)
            guard sr > 0, w.count > 0 else {
                if s.isComplete { handleMainStreamFailure() }   // complete with nothing in the window
                return
            }
            let bps = GrowingFileSchedule.bytesPerSecond(totalFrames: f.length, sampleRate: sr,
                                                         expectedBytes: s.expectedBytes)
            if bps == nil, !s.isComplete {
                // HEADERLESS (no Xing/Info full-length claim): this open's length is an estimate
                // from the bytes present — never the song's window (attached here, the completed
                // song would "end" where the partial did). Hold, unattached, until complete.
                if !mainHeaderless {
                    mainHeaderless = true
                    NPLog.trace("npdsp stream \(s.songId) headerless — holds until complete")
                }
                return
            }
            engine.connect(player, to: inputMixer, format: f.processingFormat)
            file = f
            sampleRate = sr
            segStartFrame = w.start
            segEndFrame = w.start + w.count
            duration = Double(w.count) / sr                 // the real window replaces the catalog guess
            mainBytesPerSecond = bps
            mainFrontierFrame = w.start
            mainScheduledEnd = w.start
            if pausedAt > duration { pausedAt = duration }
            NPLog.trace("npdsp stream attach \(s.songId) dur=\(String(format: "%.1f", duration))s bps=\(Int(mainBytesPerSecond ?? 0))")
        }
        guard mainStream != nil, sampleRate > 0 else { return }
        let frontier = GrowingFileSchedule.frontier(bytes: s.bytesReceived, complete: s.isComplete,
                                                    bytesPerSecond: mainBytesPerSecond, sampleRate: sampleRate,
                                                    start: segStartFrame, fullEnd: segEndFrame)
        mainFrontierFrame = max(mainFrontierFrame ?? segStartFrame, frontier)   // never backwards
        if s.isComplete {
            finishMainStream(s, url: url)                  // (gives a voice on air its last stretch)
        } else if !isBuffering, isPlaying, !_stemMode, clockNode === player, mainScheduledEnd > segStartFrame {
            let playFrame = segStartFrame + AVAudioFramePosition(currentTime * sampleRate)
            if GrowingFileSchedule.shouldAppend(scheduledEnd: mainScheduledEnd, frontier: frontier, playFrame: playFrame,
                                                sampleRate: sampleRate, complete: false),
               let f = try? AVAudioFile(forReading: url) {
                appendMain(f, to: frontier)
            }
        }
        if isBuffering, isPlaying, !_stemMode, !mainNeedsBytes(at: pausedAt, runway: mainRunwayNeeded) {
            let reach = Double((mainFrontierFrame ?? segEndFrame) - segStartFrame) / sampleRate - pausedAt
            NPLog.trace("npdsp \(firstAudioOwed ? "start" : "resume") \(s.songId) @\(String(format: "%.2f", pausedAt))s runway=\(String(format: "%.1f", reach))s")
            startAudio(fromSongSeconds: pausedAt)
        }
        if _stemHandover != nil { advanceStemHandover() }   // the full song's runway grew
    }

    /// Append `[mainScheduledEnd, to)` to the full song's voice on air. A stretch that reaches the
    /// window's end carries the END handler (armed at the current generation).
    private func appendMain(_ f: AVAudioFile, to frontier: AVAudioFramePosition) {
        let to = min(frontier, segEndFrame)
        guard to > mainScheduledEnd else { return }
        let handler: AVAudioNodeCompletionHandler? = to >= segEndFrame ? endHandler(generation) : nil
        player.scheduleSegment(f, startingFrame: mainScheduledEnd, frameCount: AVAudioFrameCount(to - mainScheduledEnd),
                               at: nil, completionHandler: handler)
        file = f
        mainScheduledEnd = to
    }

    /// The download finished: the whole window is there — an ordinary local file from now on.
    private func finishMainStream(_ s: MixStreamLoader.Stream, url: URL) {
        // The voice on air gets the last stretch (with the end) before the stream bookkeeping goes.
        if isPlaying, !isBuffering, !_stemMode, clockNode === player, mainScheduledEnd > segStartFrame,
           mainScheduledEnd < segEndFrame, let f = try? AVAudioFile(forReading: url) {
            appendMain(f, to: segEndFrame)
        }
        if let f = try? AVAudioFile(forReading: url) { file = f }   // later schedules read the final file
        mainStream = nil
        mainFrontierFrame = nil
        isStreamingMain = false
        NPLog.trace("npdsp stream complete \(s.songId) → \(s.adopted ? "adopted burn" : "local file")")
        refreshStemMonitor()
        onMainStreamFinished?(url)
    }

    /// The stream died for good. What arrived is FINAL (`mainTruncated`): stems on air keep
    /// carrying the song (a "back to the full song" request is dropped); a full song on air plays
    /// up to its last frame and then hands the row back (`mainRanOut`, via the monitor); a held
    /// one hands it back now; a paused one when ▶ asks for audio it doesn't have.
    private func handleMainStreamFailure() {
        guard let s = mainStream else { return }
        mainStream = nil
        isStreamingMain = false
        mainTruncated = true
        DiagLog.shared.log("error", "npdsp stream \(s.songId) failed — \(file == nil ? "before audio" : "truncated at \(String(format: "%.1f", mainFrontierSeconds ?? 0))s")")
        if _stemMode {
            if _stemHandover == .toFullMix { _stemHandover = nil }
            refreshStemMonitor()
            return
        }
        // The voice on air gets whatever stretch it hadn't scheduled yet — it's all there is.
        if isPlaying, !isBuffering, clockNode === player, let fr = mainFrontierFrame, fr > mainScheduledEnd,
           mainScheduledEnd > segStartFrame, let url = mainURL, let f = try? AVAudioFile(forReading: url) {
            appendMain(f, to: fr)
        }
        if isPlaying, isBuffering { mainRanOut(at: pausedAt); return }
        refreshStemMonitor()
    }

    func toggleStemMute(_ name: String) {
        if _stemMuted.contains(name) { _stemMuted.remove(name) } else { _stemMuted.insert(name) }
        applyStemGains()
        onUserStemChange?()
    }

    func setStemVolume(_ name: String, _ v: Double) {
        _stemVol[name] = min(max(v, 0), 1)
        applyStemGains()
        onUserStemChange?()
    }

    /// STEM LOCK: state the carried per-part mutes + gains (no user-change notification). Applied
    /// BEFORE the stems are asked for, so they come up at the carried mix.
    func applyCarriedStemControls(muted: Set<String>, volumes: [String: Double]) {
        _stemMuted = muted.intersection(MixEngine.stemNames)
        _stemVol = volumes.filter { MixEngine.stemNames.contains($0.key) }.mapValues { min(max($0, 0), 1) }
        applyStemGains()
    }

    // MARK: Stem Lock — partial sets + late-landing parts

    /// Would a set holding `parts` satisfy the current request? All four without a lock carry;
    /// with one, every REQUIRED part (and at least one part — the lead/clock).
    private func stemSetAcceptable(_ parts: Set<String>) -> Bool {
        guard let req = stemPartsRequired else { return parts.count == MixEngine.stemNames.count }
        return !parts.isEmpty && req.isSubset(of: parts)
    }

    /// A stem part of `songId` landed on disk (the Stem Lock prefetcher burns them one at a
    /// time). While a PARTIAL burned set is wired for that song, the new part JOINS: on air it is
    /// scheduled from the stems' exact playhead and started on one sample frame against the
    /// rendering group (silent if the carried set mutes it — gains apply at once); otherwise it
    /// is simply wired and rides the next schedule. Never touches `generation`: the joining node
    /// had nothing scheduled, so its stop flushes no completion, and the lead's armed end stays
    /// valid. A part whose format would need a reconnect on the running graph is left out
    /// (Demucs parts share one format — not seen in practice).
    func stemPartsLanded(_ songId: String, attempt: Int = 0) {
        guard built, isEngaged, loadedSongId == songId, !stemFiles.isEmpty, stemFrontier == nil,
              stemStream == nil, stemFiles.count < MixEngine.stemNames.count else { return }
        guard stemFade == nil else { retryJoin(songId, attempt); return }
        guard let got = burns.localStemPartURLs(forSong: songId) else { return }
        var fresh: [String: AVAudioFile] = [:]
        for (name, url) in got.urls where stemFiles[name] == nil {
            guard let node = stemNodes[name], let f = try? AVAudioFile(forReading: url) else { continue }
            guard node.outputFormat(forBus: 0) == f.processingFormat else {
                NPLog.trace("npdsp stem part \(name) can't join: format \(f.processingFormat) ≠ node \(node.outputFormat(forBus: 0))")
                continue
            }
            fresh[name] = f
        }
        guard !fresh.isEmpty else { got.release?(); return }
        if _stemMode, isPlaying {
            guard stemsRendering,
                  let start = StemSync.sampleStart(clocks: stemVoices() + [inputMixer], lead: StemSync.startLead, rate: _rate),
                  let p = stemPlayhead(at: start) else {
                got.release?(); retryJoin(songId, attempt); return
            }
            for (name, f) in fresh {
                guard let node = stemNodes[name] else { continue }
                let a = StemSync.frame(f, prime: stemPrime, atSeconds: p)
                guard f.length - a > 0 else { continue }
                node.stop()                       // idle node: nothing armed, nothing flushed
                node.scheduleSegment(f, startingFrame: a, frameCount: AVAudioFrameCount(f.length - a), at: nil,
                                     completionHandler: nil)
                node.play(at: StemSync.sharesTimeline(node, start.when) ? start.when : AVAudioTime(hostTime: start.hostTime))
            }
        }
        let held = stemRelease
        stemRelease = { held?(); got.release?() }
        stemFiles.merge(fresh) { old, _ in old }
        applyStemGains()
        NPLog.trace("npdsp stem parts joined \(fresh.keys.sorted()) → \(stemFiles.count)/4")
    }

    private func retryJoin(_ songId: String, _ attempt: Int) {
        guard attempt < 20 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.stemPartsLanded(songId, attempt: attempt + 1)
        }
    }

    // MARK: - Graph apply

    private func applyRate() { timePitch.rate = Float(_rate) }
    private func applyPitch() { timePitch.pitch = Float(_pitch * 100) }   // cents

    /// Deck volume: the 0…1 portion on the shared `inputMixer` (applies to the file AND the 4 stems
    /// uniformly), the >unity boost (100…200% → 0…+6 dB) on the EQ `globalGain` downstream; the master
    /// limiter catches the resulting peaks. Mirrors `MixEngine.applyBoost` semantics.
    private func applyVolume() {
        guard built else { return }
        inputMixer.outputVolume = Float(min(_volume, 1.0))
        filter.globalGain = Float(20 * log10(max(_volume, 1.0)))
        applyStemGains()
    }

    private func applyStemGains() {
        guard built else { return }
        for (name, node) in stemNodes {
            // × the handover crossfade gain (1 when settled).
            node.volume = _stemMuted.contains(name) ? 0 : Float(_stemVol[name] ?? 1.0) * stemVoiceGain
        }
    }

    /// Realize an effect's enabled-state + strength onto its AU — copied from `MixEngine.applyEffect`.
    private func applyEffect(_ effect: MixEngine.Effect) {
        guard built else { return }
        let on = isEnabled(effect)
        let s = Float(strength(effect))
        switch effect {
        case .reverb:
            reverb.wetDryMix = s * 100; reverb.bypass = !on
        case .filter:
            guard let band = filter.bands.first else { return }
            band.filterType = .resonantLowPass
            band.frequency = Float(18_000 * pow(250.0 / 18_000.0, Double(s)))   // ~18 kHz → ~250 Hz
            band.bandwidth = 0.5
            band.bypass = !on
            // The EQ NODE stays active — its globalGain carries the >unity volume boost even when the
            // filter EFFECT is off (transparent passthrough at unity + filter-off).
            filter.bypass = false
        case .flanger:
            flanger.delayTime = 0.004
            flanger.feedback = s * 60
            flanger.wetDryMix = s * 50
            flanger.lowPassCutoff = 15_000
            flanger.bypass = !on
        case .compressor:
            AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_Threshold,
                                  kAudioUnitScope_Global, 0, AudioUnitParameterValue(-30 * s), 0)
            AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_OverallGain,
                                  kAudioUnitScope_Global, 0, AudioUnitParameterValue(15 * s), 0)
            comp.bypass = !on
        }
    }

    // MARK: - Scheduling / start

    /// Stop + (re)schedule the single file from a song-relative position; returns false if nothing is
    /// schedulable (at/past the slice end).
    @discardableResult
    private func scheduleMain(fromSongSeconds pos: Double) -> Bool {
        // A GROWING file is re-opened for every schedule (an open sees only the bytes present
        // when it was made) and bounded by its frontier.
        if mainStream != nil, let url = mainURL, let fresh = try? AVAudioFile(forReading: url) { file = fresh }
        guard let f = file, sampleRate > 0 else { return false }
        player.stop()
        let playableEnd = min(segEndFrame, mainFrontierFrame ?? segEndFrame)
        let frame = min(max(segStartFrame, segStartFrame + AVAudioFramePosition(pos * sampleRate)), playableEnd)
        let count = playableEnd - frame
        guard count > 0 else { return false }
        mainScheduledEnd = playableEnd
        // The single file's render clock is the playhead: this segment begins at song-second
        // (frame − segStartFrame)/sr (≈ the clamped `pos`).
        clockNode = player
        clockSR = sampleRate
        segStartSongSeconds = Double(frame - segStartFrame) / sampleRate
        mainSegStartSeconds = segStartSongSeconds
        let gen = generation
        // Only a segment that reaches the window's END is the song's end — a frontier isn't.
        let handler: AVAudioNodeCompletionHandler? = playableEnd >= segEndFrame ? endHandler(gen) : nil
        player.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(count), at: nil,
                               completionHandler: handler)
        return true
    }

    /// Re-arm the full song at `pos` after a refused handover (a brief restart beats an end that
    /// would never fire) — or HOLD there when a growing file can't carry it yet.
    private func rearmMain(at pos: Double, play: Bool) {
        if scheduleMain(fromSongSeconds: pos) {
            if play { startScheduled(stemMode: false, fromSongSeconds: pos) }
        } else if play, mainNeedsBytes(at: pos, runway: 0) {
            holdMain(at: pos)
        }
    }

    /// Stop + (re)schedule the 4 stems from a song-relative position (past the encoder priming)
    /// up to their playable end — the frontier while they're still streaming. Only a segment that
    /// runs to the parts' real end arms the lead's END handler (a streaming segment's end is just
    /// the frontier; the monitor hands back to the full song before it). Returns whether anything
    /// scheduled.
    @discardableResult
    private func scheduleStems(fromSongSeconds pos: Double) -> Bool {
        guard !stemFiles.isEmpty else { return false }
        let gen = generation
        let lead = stemFiles["vocals"] != nil ? "vocals" : stemFiles.keys.sorted().first
        let from = max(0, pos)
        var any = false
        var reached = Double.infinity
        var chosenClock: (node: AVAudioPlayerNode, sr: Double)?
        for (name, f) in stemFiles {
            guard let node = stemNodes[name] else { continue }
            node.stop()
            let sr = f.processingFormat.sampleRate
            let startFrame = StemSync.frame(f, prime: stemPrime, atSeconds: from)
            let endFrame = stemFrontier.map { StemSync.frame(f, prime: stemPrime, atSeconds: $0) } ?? f.length
            reached = min(reached, sr > 0 ? Double(max(startFrame, endFrame) - stemPrime) / sr : from)
            let count = endFrame - startFrame
            guard count > 0 else { continue }
            let isLeadEnd = (name == lead) && stemFrontier == nil
            let handler: AVAudioNodeCompletionHandler? = isLeadEnd ? endHandler(gen) : nil
            node.scheduleSegment(f, startingFrame: startFrame, frameCount: AVAudioFrameCount(count), at: nil, completionHandler: handler)
            any = true
            // Playhead clock: prefer the LEAD stem (which also owns the end handler); fall back to the
            // first scheduled stem if the lead had nothing to schedule at this position.
            if name == lead || chosenClock == nil { chosenClock = (node, sr) }
        }
        if any, let c = chosenClock {
            clockNode = c.node; clockSR = c.sr; segStartSongSeconds = from
            stemSegStartSeconds = from
            stemEndSeconds = reached.isFinite ? reached : from
        }
        return any
    }

    /// Schedule + start playback from a song-relative position (single file OR stems). Partial
    /// (streaming) stems that can't carry this spot hand the deck to the full song, keeping the
    /// request pending so they re-engage once they have runway.
    private func startAudio(fromSongSeconds pos: Double) {
        guard built, isEngaged else { return }
        settleStemFade()
        if _stemMode, let f = stemFrontier,
           !StemSync.handoverReady(runway: f - pos, complete: false, songLeft: duration - pos) {
            stopVoices(main: false, stems: true)
            _stemMode = false
            if _stemHandover != .toFullMix, stemStream != nil { _stemHandover = .toStems } else { _stemHandover = nil }
        }
        if !_stemMode {
            // GROWING FILE: never schedule past the frontier — HOLD at `pos` until the bytes give
            // it runway (a pending stems handover may carry the deck meanwhile); a dead stream
            // with nothing left here hands the row back.
            if mainNeedsBytes(at: pos, runway: mainRunwayNeeded) {
                holdMain(at: pos)
                advanceStemHandover()
                return
            }
            if mainRanDry(at: pos) { mainRanOut(at: pos); return }
        }
        generation += 1
        let scheduled: Bool = _stemMode ? scheduleStems(fromSongSeconds: stemFrontier == nil ? min(pos, maxStemSeconds()) : pos)
                                        : scheduleMain(fromSongSeconds: pos)
        guard scheduled else { isPlaying = false; pausedAt = min(max(0, pos), duration); return }
        startScheduled(stemMode: _stemMode, fromSongSeconds: pos)
    }

    /// Start the already-scheduled voices on ONE sample frame (`StemSync.startTogether` — a
    /// shared HOST time lands the four stems a few samples apart: a comb-filtered flam).
    private func startScheduled(stemMode: Bool, fromSongSeconds pos: Double) {
        configureSession()
        guard startEngineIfNeeded() else { isPlaying = false; pausedAt = min(max(0, pos), duration); return }
        applyStemGains()
        let voices: [AVAudioPlayerNode] = stemMode ? stemVoices() : [player]
        guard !voices.isEmpty else { isPlaying = false; pausedAt = min(max(0, pos), duration); return }
        // The voices sit upstream of the time-stretch: their timeline runs at the deck's rate.
        let start = StemSync.startTogether(voices, clocks: [inputMixer], lead: StemSync.startLead, rate: _rate)
        playAnchor = (start.hostTime, pos)
        // No `playStartHost` rebase: `currentTime` now rides the node render clock (rate-scaled,
        // drift-free). `pausedAt` seeds the pre-render fallback at the segment's start position.
        pausedAt = pos
        isPlaying = true
        if isBuffering { setBuffering(false) }
        if firstAudioOwed {
            firstAudioOwed = false
            startRunwayOwed = false
            let cb = onFirstAudio
            Task { @MainActor in cb?() }          // deferred: never re-enter the caller mid-start
        }
        refreshStemMonitor()
    }

    /// A completion that reports the natural end IF `gen` is still current when it lands.
    private func endHandler(_ gen: Int) -> AVAudioNodeCompletionHandler {
        { [weak self] in _ = Task { @MainActor in self?.handleReachedEnd(gen) } }
    }

    private func handleReachedEnd(_ gen: Int) {
        guard gen == generation, isPlaying else { return }   // ignore a stale (reseeked/stopped) completion
        isPlaying = false
        pausedAt = duration
        onReachedEnd?()
    }

    /// The ONE sanctioned way to stop scheduled voices outside a reschedule: bump `generation`
    /// FIRST, then stop. `AVAudioPlayerNode.stop()` flushes the armed segment AND fires its
    /// completion handler, so a stop without the bump lets that callback pass `handleReachedEnd`'s
    /// staleness guard and fake a natural end (`setStemMode` once forgot exactly this, and toggling
    /// stems mid-song skipped to the next track). Route any future stop site through here — the
    /// sanctioned exceptions are the handover COMMITS (`cutToStems` / `cutToFullMix`), which bump
    /// BEFORE scheduling the incoming voice (so it captures the new generation) and only then stop
    /// the outgoing one — immediately, or when the crossfade lands (`settleStemFade`).
    private func stopVoices(main: Bool, stems: Bool) {
        generation += 1
        if main { player.stop() }
        if stems { for n in stemNodes.values { n.stop() } }
    }

    /// Open the 4 burned stem files and wire them (`wireStemFiles`). Holds the burn-folder scope.
    /// False when the track isn't stem-burned locally / a file won't open.
    private func wireStems() -> Bool {
        guard built, let songId = loadedSongId else { return false }
        // Stem source: a "Pocket DJ" profile item's app-managed stems (no security scope), else the
        // burned set (scoped). Everything downstream is source-agnostic; profile just feeds release=nil.
        let urls: [String: URL]
        let release: (() -> Void)?
        if ProfileSourceStore.isProfileSongId(songId), let u = profileStemResolve?(songId) {
            urls = u; release = nil
        } else if stemPartsRequired == nil, let r = burns.localStemURLs(forSong: songId) {
            urls = r.urls; release = r.release
        } else if stemPartsRequired != nil, let r = burns.localStemPartURLs(forSong: songId) {
            urls = r.urls; release = r.release    // Stem Lock: a partial set may do
        } else {
            return false
        }
        var opened: [String: AVAudioFile] = [:]
        for (name, url) in urls {
            if let f = try? AVAudioFile(forReading: url) { opened[name] = f }
        }
        guard stemSetAcceptable(Set(opened.keys)), wireStemFiles(opened, release: release) else {
            release?(); return false
        }
        releaseStemStream()                       // complete files on disk supersede a stem stream
        stemFrontier = nil
        stemOpenedBytesSeconds = 0
        return true
    }

    /// Reconnect each stem node at its file's format (only on a real format change — a reconnect
    /// on the running graph lands asynchronously, and a node re-wired in the same turn it starts
    /// can come up out of step with its siblings) and hold the files + scope + the set's priming.
    private func wireStemFiles(_ opened: [String: AVAudioFile], release: (() -> Void)?) -> Bool {
        guard built, opened.count == MixEngine.stemNames.count || stemSetAcceptable(Set(opened.keys)) else { return false }
        for (name, f) in opened {
            guard let node = stemNodes[name] else { continue }
            node.stop()
            if node.outputFormat(forBus: 0) != f.processingFormat {
                engine.connect(node, to: inputMixer, format: f.processingFormat)
            }
        }
        stemRelease?(); stemRelease = release
        stemFiles = opened
        stemPrime = StemSync.setPrimingFrames(opened, order: MixEngine.stemNames)
        return true
    }

    /// Tear the stem wiring down: stop the nodes (callers have bumped `generation` or have no
    /// stem end armed), drop files, stop any stem stream, release the scope.
    private func unwireStems() {
        settleStemFade()                          // never leave the full song at a half-faded gain
        if _stemMode { stopVoices(main: false, stems: true) } else { for n in stemNodes.values { n.stop() } }
        stemFiles = [:]
        releaseStemStream()
        stemFrontier = nil
        stemEndSeconds = 0
        stemPrime = 0
        stemOpenedBytesSeconds = 0
        stemRelease?(); stemRelease = nil
    }

    /// The longest song-relative position at which `scheduleStems` still gets real audio.
    private func maxStemSeconds() -> Double {
        guard !stemFiles.isEmpty else { return 0 }
        let m = stemFiles.values.map { StemSync.songSeconds($0, prime: stemPrime) }.min() ?? 0
        return max(0, m - 0.05)
    }

    private func startEngineIfNeeded() -> Bool {
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return engine.isRunning
    }

    private func configureSession() {
        #if canImport(UIKit) && !os(macOS)
        // Studio mic capture holds the shared session at .playAndRecord — re-arming .playback here
        // would tear down the recorder's live input tap mid-take. Playback works fine under
        // .playAndRecord, so skip (the PlayerEngine / StemPlayer / MixEngine guard).
        guard !AudioSessionPolicy.micCaptureActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* best-effort */ }
        #endif
    }

    // MARK: - Component descriptions + canonical format (local copies of MixEngine's privates)

    private static let dynamicsDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)

    private static let limiterDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)

    private static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
}
