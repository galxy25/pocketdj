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
/// set on the next track; FX LOCK — `SetlistPlayer.fxLock`, `FXLock.swift` — stamps carried effects
/// as the idle control state, which every engage RAMPS IN (`applyEffectsAtEngage`); the session,
/// not this engine, owns and persists both.)
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
    /// DJ Mode volume LEVELING trim (np-dj-mode §5): `flanger → levelTrim → mainMixerNode`. Its
    /// band is bypassed — only `globalGain` (the leveling dB) acts, so the listener's gain slider
    /// (inputMixer volume + the filter EQ's >100 % boost) sits on top of it. 0 dB = transparent.
    @ObservationIgnored private var levelTrim = AVAudioUnitEQ(numberOfBands: 1)
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
    /// FX LOCK: fired after a USER-facing effect control changed the effects state (`setEffect`,
    /// `setEffectStrength`) — never by `applyCarriedEffects` / `resetControls`, so the effects an
    /// FX Lock carries are only ever changed by the listener.
    @ObservationIgnored var onUserEffectChange: (() -> Void)?
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

    /// DJ Mode automation as the controls show it (see `DJAutomationDisplay`).
    @ObservationIgnored let djDisplay = DJAutomationDisplay()
    /// How often the display is published while automation runs (~16 Hz).
    static var djDisplayInterval: Double = 1.0 / 16
    @ObservationIgnored private var djDisplayTask: Task<Void, Never>?

    /// What the TEMPO control shows: the automated tempo while DJ automation runs, else the
    /// listener's (`rate`). Read-only — `setRate` always sets the listener's.
    var displayRate: Double { djDisplay.active ? djDisplay.rate : _rate }
    /// What the PITCH control shows (see `displayRate`).
    var displayPitch: Double { djDisplay.active ? djDisplay.pitch : _pitch }
    /// What an effect button shows (see `displayRate`).
    func displayEffect(_ effect: MixEngine.Effect) -> (on: Bool, strength: Double) {
        guard djDisplay.active else { return (isEnabled(effect), strength(effect)) }
        let st = djDisplay.effects[effect.rawValue]
        return (st?.on ?? false, st?.strength ?? strength(effect))
    }

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
        return a.song + max(0, dt) * clockRate
    }

    /// The tempo the playhead clock advances at: the TAIL deck's while it carries the current
    /// song (a DJ pre-roll), else the main chain's effective rate (listener × DJ glide).
    var clockRate: Double {
        if let t = tail, clockNode === t.player { return tailEffectiveRate(t) }
        return effectiveRate
    }

    /// The main chain's tempo as rendered: the listener's rate × the DJ glide overlay
    /// (np-dj-mode §3 — the incoming eases from its glide target back to the listener's).
    var effectiveRate: Double {
        min(max(_rate * djRateMul, MixEngine.rateRange.lowerBound), MixEngine.rateRange.upperBound)
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
    var reverbBypassed: Bool { reverb.bypass }
    var flangerWetDryMix: Float { flanger.wetDryMix }
    var flangerBypassed: Bool { flanger.bypass }
    var compressorBypassed: Bool { comp.bypass }
    var filterBandBypassed: Bool { filter.bands.first?.bypass ?? true }
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
        for n in [player, inputMixer, timePitch, comp, filter, reverb, flanger, levelTrim, masterLimiter] as [AVAudioNode] {
            engine.attach(n)
        }
        reverb.loadFactoryPreset(.mediumHall)
        levelTrim.bands.first?.bypass = true
        levelTrim.globalGain = Float(appliedLevelDb)
        // `player → inputMixer` carries the file's real format (set per engage); the mixer converts it
        // to canonical stereo. The chain below is pinned at canonical FOR LIFE, so a mono / 48 kHz /
        // odd file never reconfigures (and crashes) a live AU.
        engine.connect(player, to: inputMixer, format: canonical)
        engine.connect(inputMixer, to: timePitch, format: canonical)
        engine.connect(timePitch, to: comp, format: canonical)
        engine.connect(comp, to: filter, format: canonical)
        engine.connect(filter, to: reverb, format: canonical)
        engine.connect(reverb, to: flanger, format: canonical)
        engine.connect(flanger, to: levelTrim, format: canonical)
        engine.connect(levelTrim, to: engine.mainMixerNode, format: canonical)
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
        guard isEngaged else { return }
        // A DJ transition doesn't survive the engine being stopped behind its back — PAUSED too
        // (the system stop may have flushed both decks' schedules, and ▶'s `djResume` only
        // re-plays them): cut the tail; the current song carries on alone on the main chain,
        // restarted below or by the next ▶ (`startAudio` from the playhead).
        if djReturn != nil { settleDJReturn() }
        if djPhase != .idle { djCut(reason: "engine stopped") }
        guard isPlaying else { return }
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
            if djReturn != nil { settleDJReturn() }
            if djPhase != .idle { djCut(reason: "interruption") }   // the system stopped the engine
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
        flushRetiringTails()
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
        levelTrim = AVAudioUnitEQ(numberOfBands: 1)
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
        if !djEngagingIncoming { endDJRun(reason: "engage") }   // a foreign engage supersedes a transition
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
        applyEffectsAtEngage()

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
        endDJRun(reason: "engage stream")
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
        applyEffectsAtEngage()
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
        let bps = GrowingFileSchedule.bytesPerSecond(totalFrames: f.length, sampleRate: sr, expectedBytes: s.expectedBytes,
                                                     claim: s.isComplete ? .container : GrowingFileSchedule.lengthClaim(of: url))
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
        if djReturn != nil { settleDJReturn() }
        if djPhase != .idle { djCut(reason: "seek") }   // a seek cuts the tail (np-dj-mode §3)
        settleDJEase()
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
        // DJ Mode: skip / stop / a track change cut the tail and forget the arm (np-dj-mode §3).
        endDJRun(reason: "disengage")
        flushRetiringTails()
        disarmDJ()
        setLevel(db: 0, ramp: false)
        resetStemIntent()                       // stale-proofs any fetch/stream/fade (track change)
        cancelEffectRamp()
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
        cancelEffectRamp()
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
        if djReturn != nil { settleDJReturn() }  // …nor a DJ hand-back
        // …nor the DJ handover — landed WITHOUT starting the fade (that would advance the set
        // inside a pause): the conductor starts it once ▶ runs the clock again.
        if let run = djRun, !run.handoverDone { djHandoverLanded(run.id, startFade: false) }
        player.pause()
        for n in stemNodes.values { n.pause() }
        tail?.player.pause()                     // DJ: pause pauses BOTH decks (np-dj-mode §3)
        isPlaying = false
    }

    func resume() {
        guard isEngaged, !isPlaying else { return }
        if djPhase != .idle, tail != nil { djResume(); return }
        startAudio(fromSongSeconds: currentTime >= duration ? 0 : currentTime)
        advanceStemHandover()                    // a pending handover may be ready now it plays
        refreshStemMonitor()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    // MARK: - Controls (copied near-verbatim from MixEngine, single-deck, no record/persist)

    func setRate(_ rate: Double) {
        djListenerTookControl("tempo")
        _rate = min(max(rate, MixEngine.rateRange.lowerBound), MixEngine.rateRange.upperBound)
        applyRate()
        listenerChangedUnderAutomation()
    }

    func setPitch(_ semitones: Double) {
        djListenerTookControl("pitch")
        _pitch = min(max(semitones, MixEngine.pitchRange.lowerBound), MixEngine.pitchRange.upperBound)
        applyPitch()
        listenerChangedUnderAutomation()
    }

    func setVolume(_ v: Double) {
        _volume = min(max(v, MixEngine.volumeRange.lowerBound), MixEngine.volumeRange.upperBound)
        applyVolume()
    }

    func setEffect(_ effect: MixEngine.Effect, enabled: Bool) {
        djListenerTookControl("effect")
        _effectOn[effect.rawValue] = enabled
        effectRampScale[effect.rawValue] = nil   // the listener's hand beats an FX Lock ramp-in
        applyEffect(effect)
        listenerChangedUnderAutomation()
        onUserEffectChange?()
    }

    func setEffectStrength(_ effect: MixEngine.Effect, _ strength: Double) {
        djListenerTookControl("effect")
        _effectStrength[effect.rawValue] = min(max(strength, 0), 1)
        effectRampScale[effect.rawValue] = nil
        applyEffect(effect)
        listenerChangedUnderAutomation()
        onUserEffectChange?()
    }

    // MARK: - FX Lock seams (`SetlistPlayer` drives these — see `FXLock`)

    /// The effects state as the FX Lock carries it: every effect that is ON or whose strength the
    /// listener set (an absent effect is off at the default strength).
    var effectSettings: [String: FXLockState.Setting] {
        var out: [String: FXLockState.Setting] = [:]
        for e in MixEngine.Effect.allCases where isEnabled(e) || _effectStrength[e.rawValue] != nil {
            out[e.rawValue] = .init(on: isEnabled(e), strength: strength(e))
        }
        return out
    }

    /// Stamp a carried effects state as the control state (every effect not listed goes back to
    /// off at the default strength). Never notifies `onUserEffectChange`. Engaged: the newly-on
    /// effects RAMP IN over `fxRampSeconds` (no pop); otherwise the next engage ramps them in.
    func applyCarriedEffects(_ fx: [String: FXLockState.Setting]) {
        let wasOn = Set(MixEngine.Effect.allCases.filter { isEnabled($0) }.map(\.rawValue))
        var on: [String: Bool] = [:]
        var strength: [String: Double] = [:]
        for e in MixEngine.Effect.allCases {
            guard let st = fx[e.rawValue] else { continue }
            if st.on { on[e.rawValue] = true }
            strength[e.rawValue] = min(max(st.strength, 0), 1)
        }
        _effectOn = on
        _effectStrength = strength
        guard built else { return }
        if isEngaged {
            rampInEffects(only: Set(on.keys).subtracting(wasOn))
        } else {
            cancelEffectRamp()
            for e in MixEngine.Effect.allCases { applyEffect(e) }
        }
    }

    /// How long carried effects take to come up from transparent to their set strength (FX Lock).
    static var fxRampSeconds: Double = 0.25
    /// A ramp-in is still moving (tests).
    var effectRampInFlight: Bool { effectRamp != nil }
    @ObservationIgnored private var effectRamp: Task<Void, Never>?
    /// Effect rawValue → the 0…1 share of its strength currently applied while it ramps in.
    @ObservationIgnored private var effectRampScale: [String: Float] = [:]

    /// The graph at an engage: an engage normally starts neutral (all off — no ramp, the old
    /// path); a carried FX Lock state ramps its ON effects in from transparent.
    private func applyEffectsAtEngage() {
        rampInEffects(only: Set(MixEngine.Effect.allCases.filter { isEnabled($0) }.map(\.rawValue)))
    }

    /// Ramp `keys` (ON effects) from strength 0 — wet 0 / threshold 0 dB / cutoff ~18 kHz, i.e.
    /// transparent — to their set strength in `fxRampSteps` main-actor steps; every other effect
    /// is applied as-is. A user change to an effect drops it out of the ramp (`setEffect…`);
    /// `disengage` / `resetControls` cancel it.
    private func rampInEffects(only keys: Set<String>) {
        cancelEffectRamp()
        for k in keys { effectRampScale[k] = 0 }
        for e in MixEngine.Effect.allCases { applyEffect(e) }
        guard !keys.isEmpty, Self.fxRampSeconds > 0 else {
            effectRampScale = [:]
            for e in MixEngine.Effect.allCases { applyEffect(e) }
            return
        }
        let steps = Self.fxRampSteps
        let stepNs = UInt64(max(0.001, Self.fxRampSeconds / Double(steps)) * 1_000_000_000)
        effectRamp = Task { @MainActor [weak self] in
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: stepNs)
                guard let self, !Task.isCancelled else { return }
                let k = Float(i) / Float(steps)
                for key in Array(self.effectRampScale.keys) {
                    self.effectRampScale[key] = k
                    if let e = MixEngine.Effect(rawValue: key) { self.applyEffect(e) }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.effectRampScale = [:]
            self.effectRamp = nil
        }
    }
    static let fxRampSteps = 12

    private func cancelEffectRamp() {
        effectRamp?.cancel()
        effectRamp = nil
        guard !effectRampScale.isEmpty else { return }
        effectRampScale = [:]
        for e in MixEngine.Effect.allCases { applyEffect(e) }   // land every effect at its set value
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
        // Before the advance the outgoing is still the song: hand it back (its stem handover then
        // runs on the main chain once the hand-back lands). After it, the stems are the
        // INCOMING's on the main chain — the fade carries on.
        if djPhase != .idle, djRun?.incomingEngaged != true { djCut(reason: "stems toggled", restart: true) }
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
        // DJ: the tail carries the song (its clock isn't the stems' / main voice's) or a
        // hand-back cross is running — `finishDJReturn` re-runs this once it lands.
        guard !tailCarriesSong, djReturn == nil else { return }
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
           let start = StemSync.sampleStart(clocks: stemVoices() + [inputMixer], lead: StemSync.startLead, rate: effectiveRate),
           let p = StemSync.voicePlayhead(player, sampleRate: sampleRate, segmentStart: mainSegStartSeconds,
                                          rate: effectiveRate, at: start),
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
        let lead = StemSync.startLead * max(1, effectiveRate)
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
           let start = StemSync.sampleStart(clocks: stemVoices() + [inputMixer], lead: StemSync.startLead, rate: effectiveRate),
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
                                              segmentStart: stemSegStartSeconds, rate: effectiveRate, at: start) { return p }
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
        guard let set = stemStream, built, isEngaged, !tailCarriesSong else { return }
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
        guard stemFade == nil, !tailCarriesSong, djReturn == nil else { return }
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
            let claim: GrowingFileSchedule.LengthClaim = s.isComplete ? .container : GrowingFileSchedule.lengthClaim(of: url)
            let bps = GrowingFileSchedule.bytesPerSecond(totalFrames: f.length, sampleRate: sr,
                                                         expectedBytes: s.expectedBytes, claim: claim)
            if bps == nil, !s.isComplete {
                // Too few bytes to find the first frame yet: undecided — sniff again on the next
                // progress event (never marked headerless on a guess).
                if claim == .undetermined { return }
                // HEADERLESS (no Xing/Info/VBRI full-length claim — `GrowingFileSchedule.
                // lengthClaim` — or one implausible at 320 kbps): this open's length is an estimate
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
        // (The mute is set FIRST: a hand-back schedules the stems with it already applied.)
        if djPhase != .idle, djRun?.incomingEngaged != true { djCut(reason: "stem mute", restart: true) }
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
                  let start = StemSync.sampleStart(clocks: stemVoices() + [inputMixer], lead: StemSync.startLead, rate: effectiveRate),
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

    private func applyRate() {
        timePitch.rate = Float(effectiveRate)
        if let t = tail, djPhase == .preRoll { applyTail(t) }   // the tail carries the listener's song
    }
    private func applyPitch() {
        timePitch.pitch = Float(Self.clampPitchCents((_pitch + djPitchAdd) * 100))   // cents
        if let t = tail, djPhase == .preRoll { applyTail(t) }
    }
    private static func clampPitchCents(_ c: Double) -> Double {
        min(max(c, MixEngine.pitchRange.lowerBound * 100), MixEngine.pitchRange.upperBound * 100)
    }

    /// Deck volume: the 0…1 portion on the shared `inputMixer` (applies to the file AND the 4 stems
    /// uniformly), the >unity boost (100…200% → 0…+6 dB) on the EQ `globalGain` downstream; the master
    /// limiter catches the resulting peaks. Mirrors `MixEngine.applyBoost` semantics.
    private func applyVolume() {
        guard built else { return }
        // × the DJ crossfade's incoming gain (1 outside a transition).
        inputMixer.outputVolume = Float(min(_volume, 1.0)) * djMainFade
        filter.globalGain = Float(20 * log10(max(_volume, 1.0)))
        applyStemGains()
        if let t = tail, djPhase == .preRoll { applyTail(t) }
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
        var on = isEnabled(effect)
        // FX Lock ramp-in: the applied share of the strength (1 when settled).
        var s = Float(strength(effect)) * (effectRampScale[effect.rawValue] ?? 1)
        // DJ texture sweep on the incoming (np-dj-mode §3): an effect the listener has OFF is
        // swept by the transition; one they turned on is theirs and left alone.
        if !on, let t = djTexture, t.effect == effect {
            on = true
            s = Float(t.strength)
        }
        Self.applyEffect(effect, on: on, strength: s, comp: comp, filter: filter, reverb: reverb, flanger: flanger)
        if let t = tail, djPhase == .preRoll { applyTail(t) }
    }

    /// Realize one effect's on/strength onto a chain's AUs (the main chain's and the DJ tail's).
    private static func applyEffect(_ effect: MixEngine.Effect, on: Bool, strength s: Float,
                                    comp: AVAudioUnitEffect, filter: AVAudioUnitEQ,
                                    reverb: AVAudioUnitReverb, flanger: AVAudioUnitDelay) {
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
        let start = StemSync.startTogether(voices, clocks: [inputMixer], lead: StemSync.startLead, rate: effectiveRate)
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

    // MARK: - DJ Mode: the TAIL deck + the transition conductor (np-dj-mode §3)
    //
    // Everything the listener touches stays on the ONE main chain. A DJ transition borrows a
    // short-lived second chain — the TAIL deck: `player → mixer(gain × fade) → timePitch → comp →
    // filter(EQ + boost/level globalGain) → reverb → flanger → mainMixerNode` (ahead of the shared
    // PeakLimiter), attached to the SAME engine when the transition starts and detached when its
    // crossfade lands. The tail opens its OWN `AVAudioFile` on the outgoing file (two player nodes
    // never pull from one ExtAudioFile). The timeline:
    //
    //  1. START (pre-roll start, or the fade start when there is no glide). The outgoing song moves
    //     from the main chain onto the tail deck: the same file from the frame the main voice will
    //     be at on a shared future host time (`StemSync.sampleStart` + `voicePlayhead`), started
    //     there, and crossed over a 60 ms linear handover — identical audio through identical
    //     settings, so the cross is inaudible. Then the main voices stop (generation first: their
    //     armed end goes stale). The tail carries the outgoing rate / pitch / effects / level.
    //  2. PRE-ROLL. The tail ramps rate, pitch and the FX texture toward the glide targets
    //     (`AutoTransition.outgoingRamp`); the listener's controls still steer it (same song).
    //  3. FADE START. The host advances (`onDJFadeStart` — card, queue index, DeadAirMeter, the
    //     control reset + FX Lock stamp); the main chain engages the incoming file at its
    //     phase-aligned start (the tail's playhead read AFTER the engage, at the incoming's start
    //     moment), gain 0, rate / pitch pinned to the incoming glide targets (`djRateMul` /
    //     `djPitchAdd` OVER the listener's controls), texture at peak. The equal-power fade runs:
    //     tail out, main in.
    //  4. FADE END. The tail stops; its nodes are detached at once — or, when its reverb /
    //     flanger is wet, after `djTailRingSeconds` so the wash rings out instead of being cut.
    //  5. POST-ROLL. The overlays ease back to the listener's settings (`incomingRamp`).
    //
    // Transport: pause pauses both decks (a pause inside the 60 ms handover lands it but never
    // starts the fade — the conductor does once ▶ runs the clock again); skip / stop
    // (`disengage`) and seek CUT the tail; a stem toggle / mute before the incoming engaged cuts
    // back to the main chain (after it, the stems are the incoming's — the fade carries on); a
    // listener touch on tempo / pitch / effects during the transition ends the glide at once (the
    // listener wins) — the crossfade itself carries on.
    //
    // A cut BEFORE the advance with the song still playing (a stem action in the pre-roll, the
    // host refusing at the fade start) hands the outgoing BACK with the forward handover's
    // machinery mirrored (`djReturn`): the main chain is scheduled at the tail's exact playhead on
    // a shared host time, at the tail's rate / pitch / texture, a 60 ms linear cross, then the
    // tail goes and the glide eases back to the listener's settings (`djEaseSeconds`) — no gap,
    // no click, no snap. A tail that already ran out reports the song's END (the host advances).

    /// The incoming song a DJ transition mixes into (built by the host).
    struct DJIncoming {
        var songId: String
        var url: URL
        /// The song's start within a shared analog album file (nil for a per-song file).
        var startMs: Int?
        var lengthMs: Int?
        /// The incoming file's security scope — the main chain holds it once engaged; a
        /// transition that never gets that far releases it.
        var release: (() -> Void)?
        var beat: AutoTransition.BeatRef
        /// The incoming's leveling gain (dB; 0 = unknown / leveling off).
        var levelDb: Double
    }

    /// One DJ transition, every decision already made by `AutoTransition` (np-dj-mode §2).
    struct DJTransition {
        var plan: AutoTransition.Plan
        /// Glide targets — rate MULTIPLIERS / pitch semitones ADDED on top of the listener's.
        var outRate = 1.0
        var outPitch = 0.0
        var inRate = 1.0
        var inPitch = 0.0
        /// The FX texture swept through the transition (nil = effect sweeps off).
        var texture: (effect: MixEngine.Effect, peak: Double)?
        var outgoingBeat: AutoTransition.BeatRef
        var incoming: DJIncoming
    }

    enum DJPhase: String { case idle, preRoll, fade, postRoll }

    /// Where the transition is (OBSERVED — the panel's "DJ — mixing").
    private(set) var djPhase: DJPhase = .idle
    var djTransitioning: Bool { djPhase != .idle }

    /// FADE START: the host advances onto `songId` (card, queue index, DeadAirMeter, control reset
    /// + FX Lock stamp). Returning false refuses — the outgoing goes back onto the main chain.
    @ObservationIgnored var onDJFadeStart: ((String) -> Bool)?
    /// The incoming is engaged on the main chain (song id, its file, its shared-file start).
    @ObservationIgnored var onDJIncomingEngaged: ((String, URL, Int?) -> Void)?
    /// The incoming file could not be engaged after the host advanced — play it the plain way.
    @ObservationIgnored var onDJIncomingFailed: ((String) -> Void)?
    /// A transition the watch tried to begin was declined here (the reason; the host logs it).
    @ObservationIgnored var onDJDeclined: ((String) -> Void)?
    /// A transition ended (incoming song id or nil before the advance, how: complete / listener / cut).
    @ObservationIgnored var onDJTransitionEnded: ((String?, String) -> Void)?

    /// Conductor tick (seconds) — the fade's step.
    static var djTickSeconds: Double = 0.025
    /// How far out (host seconds) the outgoing → tail handover is scheduled.
    static var djHandoverLead: Double = 0.12
    /// Below this much audio left a transition isn't begun (the song just ends).
    static var djMinSecondsLeft: Double = 0.75
    /// A declined begin is retried this often while in the lead window (the next may land).
    static var djRetrySeconds: Double = 1
    /// A wet (reverb / flanger) tail rings out this long after the fade before it is detached.
    static var djTailRingSeconds: Double = 2
    /// A cut that hands the outgoing back eases the glide overlays to identity over this.
    static var djEaseSeconds: Double = 0.5
    /// A post-advance cut ramps the tail out over this instead of a hard (clicking) stop.
    static var djTailCutFadeSeconds: Double = 0.04

    /// The listener's control state, captured for the tail.
    fileprivate struct ControlState {
        var rate = 1.0
        var pitch = 0.0
        var volume = 1.0
        var effectOn: [String: Bool] = [:]
        var effectStrength: [String: Double] = [:]
    }

    private func liveControls() -> ControlState {
        ControlState(rate: _rate, pitch: _pitch, volume: _volume, effectOn: _effectOn, effectStrength: _effectStrength)
    }

    /// The short-lived second chain (see the MARK above).
    fileprivate final class TailDeck {
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let timePitch = AVAudioUnitTimePitch()
        let comp = AVAudioUnitEffect(audioComponentDescription: NowPlayingDSP.dynamicsDesc)
        let filter = AVAudioUnitEQ(numberOfBands: 1)
        let reverb = AVAudioUnitReverb()
        let flanger = AVAudioUnitDelay()
        /// The tail's OWN open of the outgoing file (never the main chain's instance).
        let file: AVAudioFile
        let sampleRate: Double
        /// The song second its scheduled segment begins at (its render clock counts from there).
        var startSongSeconds = 0.0
        /// The outgoing file's scope, taken over at the fade start.
        var release: (() -> Void)?
        /// The outgoing listener's controls — LIVE during the pre-roll (same song), frozen here
        /// at the fade start (the controls then belong to the incoming).
        var base: ControlState
        var rateMul = 1.0
        var pitchAdd = 0.0
        var texture: (effect: MixEngine.Effect, strength: Double)?
        var handoverGain: Float = 0
        var fadeGain: Float = 1
        /// The outgoing's leveling gain — it carries on toward `levelTarget` at `levelRate`
        /// (dB/s) when a leveling ramp was in flight at the handover.
        var levelDb = 0.0
        var levelTarget = 0.0
        var levelRate = 0.0
        var nodes: [AVAudioNode] { [player, mixer, timePitch, comp, filter, reverb, flanger] }
        /// The reverb / flanger is wet: its wash outlives the dry signal.
        var rings: Bool { !reverb.bypass || !flanger.bypass }

        init(file: AVAudioFile, sampleRate: Double, base: ControlState) {
            self.file = file; self.sampleRate = sampleRate; self.base = base
        }
    }

    private struct DJRun {
        let id: Int
        var spec: DJTransition
        let outgoingSongId: String
        var phaseElapsed = 0.0
        var handoverDone = false
        var glideDropped = false
        var incomingEngaged = false
        /// The main chain's clock before the handover (restored if it's cut before landing).
        var savedClock: (node: AVAudioPlayerNode?, sr: Double, segStart: Double)
    }

    @ObservationIgnored private var tail: TailDeck?
    /// Tails past their job, still attached while they ring out / ramp out (detached by their
    /// own task, or at once by `flushRetiringTails`).
    @ObservationIgnored private var retiringTails: [TailDeck] = []
    @ObservationIgnored private var djRun: DJRun?
    @ObservationIgnored private var djRunSeq = 0
    @ObservationIgnored private var djConductor: Task<Void, Never>?
    @ObservationIgnored private var djHandoverTask: Task<Void, Never>?
    /// The hand-BACK of a cut transition in flight (the tail → main 60 ms cross).
    @ObservationIgnored private var djReturn: (id: Int, task: Task<Void, Never>)?
    /// The glide overlays easing back to identity after a hand-back.
    @ObservationIgnored private var djEase: Task<Void, Never>?
    /// The incoming's glide overlays on the main chain (identity outside a transition).
    @ObservationIgnored private var djRateMul = 1.0
    @ObservationIgnored private var djPitchAdd = 0.0
    @ObservationIgnored private var djTexture: (effect: MixEngine.Effect, strength: Double)?
    /// The crossfade's incoming gain on the main chain (1 outside a transition).
    @ObservationIgnored private var djMainFade: Float = 1
    @ObservationIgnored private var djEngagingIncoming = false
    @ObservationIgnored private var djArm: (lead: Double, begin: () -> DJTransition?)?
    @ObservationIgnored private var djWatch: Task<Void, Never>?
    @ObservationIgnored private var djNextTry: Double = 0

    /// Wall seconds of audio left on the current song at its rendered tempo.
    var djSecondsLeft: Double { max(0, duration - currentTime) / max(0.05, clockRate) }
    var djArmed: Bool { djArm != nil }

    /// The tail deck carries the CURRENT song (the pre-roll, before the advance): the stem
    /// machinery (which reads the clock as the stems' or the main voice's) must stand still.
    private var tailCarriesSong: Bool {
        guard let t = tail else { return false }
        return clockNode === t.player
    }

    // Test seams (tail-deck state; the audio itself is asserted through `captureForTesting`).
    var tailDeckActiveForTesting: Bool { tail != nil }
    var tailGainForTesting: Float? { tail.map { $0.mixer.outputVolume } }
    var tailRateForTesting: Float? { tail.map { $0.timePitch.rate } }
    var tailPlayingForTesting: Bool { tail?.player.isPlaying ?? false }
    var mainFadeGainForTesting: Float { djMainFade }
    /// The in-flight transition's incoming song id (a ⏭ in its pre-roll is a skip INTO it).
    var djIncomingSongId: String? { djRun?.spec.incoming.songId }
    /// The in-flight transition's outgoing tempo target (the fade start pins the tail at it).
    var djOutRate: Double? { djRun?.spec.outRate }
    /// The in-flight transition's plan (a ⏭ hurries / replaces it).
    var djPlanForTesting: AutoTransition.Plan? { djRun?.spec.plan }
    var attachedNodeCountForTesting: Int { engine.attachedNodes.count }
    /// A tail is still attached while it rings / ramps out.
    var retiringTailCountForTesting: Int { retiringTails.count }
    /// The tail → main hand-back of a cut transition is in flight.
    var djReturningForTesting: Bool { djReturn != nil }
    /// The glide overlay on the main chain's tempo (1 = none).
    var djRateOverlayForTesting: Double { djRateMul }
    /// The tail's playhead (song seconds of the OUTGOING song) while it carries it.
    func tailPlayheadForTesting() -> Double? {
        guard let t = tail, let nt = t.player.lastRenderTime, let pt = t.player.playerTime(forNodeTime: nt),
              pt.sampleTime >= 0 else { return nil }
        return t.startSongSeconds + Double(pt.sampleTime) / t.sampleRate
    }

    private static func hostNow() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    // MARK: Automation display (the controls move — np-dj-mode §7)

    /// A listener control moved while automation runs: the display shows the NEW value at once
    /// (the touch already ended the glide) — never the stale automated one for a frame.
    private func listenerChangedUnderAutomation() {
        if djAutomating || djDisplay.active { publishDJDisplay() }
    }

    /// Automation drives what is heard beyond the listener's own controls.
    private var djAutomating: Bool { djRun != nil || djEase != nil || djReturn != nil }

    /// Publish the display NOW from the live state (phase changes, ends, listener touches), and
    /// keep publishing at `djDisplayInterval` while automation runs.
    private func publishDJDisplay() {
        guard djAutomating else {
            djDisplayTask?.cancel(); djDisplayTask = nil
            if djDisplay.active { djDisplay.clear() }
            return
        }
        let heard: (rate: Double, pitch: Double, base: ControlState, texture: (effect: MixEngine.Effect, strength: Double)?)
        var xf = 1.0
        if djPhase == .preRoll, let t = tail {
            // The tail carries the CURRENT song: show the outgoing's automated values.
            heard = (tailEffectiveRate(t), _pitch + t.pitchAdd, liveControls(), t.texture)
            xf = 0
        } else {
            heard = (effectiveRate, _pitch + djPitchAdd, liveControls(), djTexture)
            if djPhase == .fade, let run = djRun {
                xf = min(1, max(0, run.phaseElapsed / max(0.05, run.spec.plan.fadeSeconds)))
            } else if djPhase == .preRoll {
                xf = 0
            }
        }
        var fx: [String: FXLockState.Setting] = [:]
        for e in MixEngine.Effect.allCases {
            if heard.base.effectOn[e.rawValue] == true {
                fx[e.rawValue] = .init(on: true, strength: heard.base.effectStrength[e.rawValue] ?? 0.5)
            } else if let t = heard.texture, t.effect == e {
                fx[e.rawValue] = .init(on: true, strength: t.strength)
            }
        }
        let pitch = min(max(heard.pitch, MixEngine.pitchRange.lowerBound), MixEngine.pitchRange.upperBound)
        djDisplay.publish(active: true, rate: heard.rate, pitch: pitch, effects: fx, crossfade: xf,
                          phase: djRun == nil ? "ease" : djPhase.rawValue)
        guard djDisplayTask == nil else { return }
        djDisplayTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, Self.djDisplayInterval) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard self.djAutomating else {
                    self.djDisplayTask = nil
                    if self.djDisplay.active { self.djDisplay.clear() }
                    return
                }
                self.publishDJDisplay()
            }
        }
    }

    // MARK: Arm (the lead-window watch)

    /// Arm the CURRENT engagement for a DJ transition: once the song has `lead` seconds (or fewer)
    /// left, `begin` is asked for the transition (the host re-validates the next row then — nil
    /// declines) and it starts. A declined attempt is retried every `djRetrySeconds` (the next
    /// row may land meanwhile) until `djMinSecondsLeft`. `disengage` disarms.
    func armDJ(lead: Double, begin: @escaping () -> DJTransition?) {
        djArm = (lead, begin)
        djNextTry = 0
        guard djWatch == nil else { return }
        djWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, self.djArm != nil else { return }
                self.djWatchTick()
            }
        }
    }

    func disarmDJ() {
        djArm = nil
        djWatch?.cancel(); djWatch = nil
    }

    private func djWatchTick() {
        guard let arm = djArm, isEngaged, isPlaying, !isBuffering, djPhase == .idle, djReturn == nil,
              duration > 0 else { return }
        let left = djSecondsLeft
        guard AutoTransition.inLeadWindow(secondsLeft: left, lead: arm.lead), left > Self.djMinSecondsLeft else { return }
        let now = Self.hostNow()
        guard now >= djNextTry else { return }
        djNextTry = now + Self.djRetrySeconds
        guard let spec = arm.begin() else { return }
        if let reason = beginDJTransition(spec) { onDJDeclined?(reason) }
    }

    // MARK: Begin — the outgoing onto the tail

    /// Start `spec` now. Returns nil when it began, else the decline reason (nothing touched; the
    /// song plays on and ends with today's normal advance). The incoming's scope is released on
    /// a decline.
    @discardableResult
    func beginDJTransition(_ spec: DJTransition) -> String? {
        func decline(_ r: String) -> String { spec.incoming.release?(); return r }
        guard djPhase == .idle, djRun == nil, djReturn == nil else { return decline("transition in flight") }
        guard built, isEngaged, isPlaying, !isBuffering, engine.isRunning else { return decline("not playing") }
        guard mainStream == nil, !mainTruncated else { return decline("outgoing not complete to its end") }
        guard let f = file, sampleRate > 0 else { return decline("no file") }
        guard _stemHandover == nil, stemFade == nil else { return decline("stem handover in flight") }
        if _stemMode, !_stemMuted.isEmpty || _stemVol.values.contains(where: { $0 < 0.999 }) {
            return decline("stems-muted")
        }
        // Partial (STREAMING) stems keep handing back / appending on their own clock — on the
        // tail's pre-roll that would start a second copy of the outgoing. Mix on complete stems.
        if _stemMode, stemStream != nil || stemFrontier != nil { return decline("stems streaming") }
        guard let inFile = try? AVAudioFile(forReading: spec.incoming.url), inFile.length > 0 else {
            return decline("incoming unreadable")
        }
        _ = inFile
        // The tail's OWN reader of the outgoing file (the main player may still be pulling from
        // `file` through the 120 ms lead + 60 ms cross).
        guard let tf = try? AVAudioFile(forReading: f.url) else { return decline("outgoing unreadable") }
        // A glide ease left over from a hand-back settles first (its overlays are the main chain's).
        settleDJEase()
        guard let start = StemSync.sampleStart(clocks: [inputMixer], lead: Self.djHandoverLead, rate: effectiveRate) else {
            return decline("no render clock")
        }
        let at: Double? = _stemMode
            ? stemPlayhead(at: start)
            : StemSync.voicePlayhead(player, sampleRate: sampleRate, segmentStart: mainSegStartSeconds,
                                     rate: effectiveRate, at: start)
        guard let pos = at, pos < duration - 0.3 else { return decline("too close to the end") }
        let frame = min(segEndFrame, max(segStartFrame, segStartFrame + AVAudioFramePosition(pos * sampleRate)))
        guard segEndFrame - frame > 0 else { return decline("too close to the end") }

        djRunSeq &+= 1
        let runId = djRunSeq
        let t = TailDeck(file: tf, sampleRate: sampleRate, base: liveControls())
        let canonical = Self.canonicalFormat
        for n in t.nodes { engine.attach(n) }
        t.reverb.loadFactoryPreset(.mediumHall)
        engine.connect(t.player, to: t.mixer, format: tf.processingFormat)
        engine.connect(t.mixer, to: t.timePitch, format: canonical)
        engine.connect(t.timePitch, to: t.comp, format: canonical)
        engine.connect(t.comp, to: t.filter, format: canonical)
        engine.connect(t.filter, to: t.reverb, format: canonical)
        engine.connect(t.reverb, to: t.flanger, format: canonical)
        engine.connect(t.flanger, to: engine.mainMixerNode, fromBus: 0,
                       toBus: engine.mainMixerNode.nextAvailableInputBus, format: canonical)
        t.startSongSeconds = Double(frame - segStartFrame) / sampleRate
        // The outgoing's level as heard now; a leveling ramp in flight carries on on the tail.
        t.levelDb = appliedLevelDb
        t.levelTarget = levelTargetDb
        t.levelRate = levelRamp != nil ? levelRampRateDbPerSecond : 0
        t.handoverGain = 0
        tail = t
        djRun = DJRun(id: runId, spec: spec, outgoingSongId: loadedSongId ?? "",
                      savedClock: (clockNode, clockSR, segStartSongSeconds))
        djPhase = .preRoll
        applyTail(t)
        t.player.scheduleSegment(tf, startingFrame: frame, frameCount: AVAudioFrameCount(segEndFrame - frame),
                                 at: nil) { [weak self] in
            Task { @MainActor in self?.tailReachedEnd(runId) }
        }
        t.player.play(at: AVAudioTime(hostTime: start.hostTime))
        // The playhead rides the tail from the handover moment on.
        clockNode = t.player
        clockSR = sampleRate
        segStartSongSeconds = t.startSongSeconds
        playAnchor = (start.hostTime, t.startSongSeconds)
        djHandoverTask = StemSync.crossfade(
            atHostTime: start.hostTime,
            alive: { [weak self] in self?.djRun?.id == runId && self?.djRun?.handoverDone == false },
            apply: { [weak self] g in
                guard let self, let t = self.tail else { return }
                self.setVoiceGains(main: 1 - g, stems: 1 - g)
                t.handoverGain = g
                self.applyTail(t)
            },
            done: { [weak self] in self?.djHandoverLanded(runId) })
        startDJConductor(runId)
        publishDJDisplay()
        let p = spec.plan
        DJMode.log("transition start song=\(loadedSongId ?? "-") → \(spec.incoming.songId) at=\(String(format: "%.2f", pos))s "
                   + "preroll=\(String(format: "%.1f", p.preRollSeconds))s fade=\(String(format: "%.1f", p.fadeSeconds))s "
                   + "postroll=\(String(format: "%.1f", p.hasPostRoll ? p.postRollSeconds : 0))s "
                   + "rate=\(String(format: "%.3f", spec.outRate))→\(String(format: "%.3f", spec.inRate)) "
                   + "pitch=\(String(format: "%+.2f", spec.outPitch))/\(String(format: "%+.2f", spec.inPitch)) "
                   + "fx=\(spec.texture.map { "\($0.effect.rawValue):\(String(format: "%.2f", $0.peak))" } ?? "none") "
                   + "level=\(String(format: "%+.1f", appliedLevelDb))→\(String(format: "%+.1f", spec.incoming.levelDb))dB")
        return nil
    }

    /// The 60 ms handover landed: the main voices stop (generation first), the tail is the song.
    /// Idempotent (a stale or second landing is a no-op — it would stop the INCOMING). `startFade`
    /// false (a pause landing it early): the fade waits for the conductor, i.e. for ▶.
    private func djHandoverLanded(_ runId: Int, startFade: Bool = true) {
        guard var run = djRun, run.id == runId, !run.handoverDone, let t = tail else { return }
        djHandoverTask?.cancel(); djHandoverTask = nil
        stopVoices(main: true, stems: true)
        setVoiceGains(main: 1, stems: 1)
        t.handoverGain = 1
        applyTail(t)
        run.handoverDone = true
        djRun = run
        if startFade, isPlaying, !run.spec.plan.hasPreRoll { djStartFade() }
    }

    /// The tail ran out (before the fade could start — a short runway): fade now.
    private func tailReachedEnd(_ runId: Int) {
        guard djRun?.id == runId, djPhase == .preRoll else { return }
        if djRun?.handoverDone == true { djStartFade() }
    }

    // MARK: Conductor

    private func startDJConductor(_ runId: Int) {
        djConductor?.cancel()
        djConductor = Task { @MainActor [weak self] in
            var last = Self.hostNow()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.005, Self.djTickSeconds) * 1_000_000_000))
                guard !Task.isCancelled, let self, self.djRun?.id == runId else { return }
                let now = Self.hostNow()
                let dt = now - last
                last = now
                // The clock only runs while the audio does (pause freezes the transition).
                if self.isPlaying { self.djTick(dt) }
            }
        }
    }

    private func djTick(_ dt: Double) {
        guard var run = djRun else { return }
        run.phaseElapsed += dt
        djRun = run
        let plan = run.spec.plan
        let peak = run.spec.texture?.peak ?? 0
        if let t = tail, t.levelRate > 0, abs(t.levelTarget - t.levelDb) > 0.001 {
            let step = t.levelRate * dt
            t.levelDb = t.levelTarget > t.levelDb ? min(t.levelTarget, t.levelDb + step) : max(t.levelTarget, t.levelDb - step)
            if djPhase == .fade { applyTail(t) }   // the pre-roll applies below
        }
        switch djPhase {
        case .idle:
            return
        case .preRoll:
            guard let t = tail else { return }
            let p = plan.hasPreRoll ? min(1, run.phaseElapsed / plan.preRollSeconds) : 1
            if !run.glideDropped {
                let r = AutoTransition.outgoingRamp(p, outRate: run.spec.outRate, outPitch: run.spec.outPitch, fxPeak: peak)
                t.rateMul = r.rate
                t.pitchAdd = r.pitch
                t.texture = run.spec.texture.map { ($0.effect, r.fxStrength) }
            }
            applyTail(t)
            if p >= 1, run.handoverDone { djStartFade() }
        case .fade:
            let p = Float(min(1, run.phaseElapsed / max(0.05, plan.fadeSeconds)))
            let g = AutoTransition.equalPowerGains(progress: p)
            if let t = tail { t.fadeGain = g.outgoing; applyTail(t) }
            djMainFade = g.incoming
            applyVolume()
            if p >= 1 { djEndFade() }
        case .postRoll:
            guard !run.glideDropped else { djFinish(how: "listener"); return }
            let p = min(1, run.phaseElapsed / max(0.05, plan.postRollSeconds))
            let r = AutoTransition.incomingRamp(p, inRate: run.spec.inRate, inPitch: run.spec.inPitch, fxPeak: peak)
            djRateMul = r.rate
            djPitchAdd = r.pitch
            djTexture = run.spec.texture.map { ($0.effect, r.fxStrength) }
            applyRate(); applyPitch()
            for e in MixEngine.Effect.allCases { applyEffect(e) }
            if p >= 1 { djFinish(how: "complete") }
        }
    }

    // MARK: Fade start — the host advances, the incoming engages on the main chain

    private func djStartFade() {
        guard var run = djRun, let t = tail, djPhase == .preRoll, run.handoverDone, isPlaying else { return }
        let tailPos = currentTime                         // fallback only — re-read after the engage
        // Pin the outgoing at its glide target + texture peak, and FREEZE its controls: from here
        // the listener's controls belong to the incoming.
        t.base = liveControls()
        if !run.glideDropped {
            t.rateMul = run.spec.outRate
            t.pitchAdd = run.spec.outPitch
            t.texture = run.spec.texture.map { ($0.effect, $0.peak) }
        }
        djPhase = .fade
        run.phaseElapsed = 0
        djRun = run
        applyTail(t)
        // The incoming starts SILENT at its glide targets (the overlays sit on the listener's).
        djMainFade = 0
        djRateMul = run.glideDropped ? 1 : run.spec.inRate
        djPitchAdd = run.glideDropped ? 0 : run.spec.inPitch
        djTexture = run.glideDropped ? nil : run.spec.texture.map { ($0.effect, $0.peak) }
        let inc = run.spec.incoming
        guard onDJFadeStart?(inc.songId) ?? true else {
            djCut(reason: "host refused the advance", restart: true)
            return
        }
        // The tail keeps the outgoing's scope; the main chain takes the incoming's.
        t.release = fileRelease
        fileRelease = nil
        djEngagingIncoming = true
        engage(url: inc.url, startMs: inc.startMs, lengthMs: inc.lengthMs, atSeconds: 0, songId: inc.songId,
               play: false, release: inc.release)
        djEngagingIncoming = false
        guard isEngaged, loadedSongId == inc.songId, file != nil else {
            // (engage released the incoming's scope.) The host already advanced: it plays the
            // incoming the plain way, which tears this engagement — and the tail — down.
            run.incomingEngaged = true
            djRun = run
            DJMode.log("fade start song=\(inc.songId) — the DSP refused the file → plain start")
            onDJIncomingFailed?(inc.songId)
            return
        }
        run.incomingEngaged = true
        djRun = run
        // The incoming's level lands over a few ms while its gain is still ~0 (the main chain's
        // reverb / flanger may still ring the outgoing's pre-handover audio — never a step).
        setLevel(db: inc.levelDb, ramp: true, seconds: Self.levelFadeStartSeconds)
        applyRate(); applyPitch(); applyVolume()
        for e in MixEngine.Effect.allCases { applyEffect(e) }
        // Beat sync: land the incoming's beat phase on the outgoing's (≤ ½ beat once steady). The
        // tail's playhead is read NOW — after the host advance and the (synchronous) file open —
        // projected to the moment the incoming starts (`StemSync.startLead` out): both positions
        // refer to one instant.
        let lead = StemSync.startLead
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
        let tailAt = StemSync.voicePlayhead(t.player, sampleRate: t.sampleRate, segmentStart: t.startSongSeconds,
                                            rate: tailEffectiveRate(t), atHostTime: startHost)
            ?? (tailPos + lead * tailEffectiveRate(t))
        var offset = AutoTransition.phaseAlignOffset(outgoing: run.spec.outgoingBeat, outgoingPosition: tailAt,
                                                     incoming: inc.beat, incomingPosition: 0)
        // From the song's top a BACKWARD offset can't be taken — the same phase one beat later can.
        if offset < 0, let beat = AutoTransition.beatPhase(inc.beat, at: 0)?.beatSeconds { offset += beat }
        let at = min(max(0, offset), max(0, duration - 0.5))
        startAudio(fromSongSeconds: at)
        DJMode.log("fade start song=\(run.outgoingSongId) → \(inc.songId) incoming@\(String(format: "%.3f", at))s "
                   + "(phase offset \(String(format: "%+.3f", offset))s, outgoing@\(String(format: "%.3f", tailAt))s)")
        publishDJDisplay()
        onDJIncomingEngaged?(inc.songId, inc.url, inc.startMs)
    }

    /// The crossfade landed: the tail goes (a wet one rings out first); the post-roll eases the
    /// incoming back.
    private func djEndFade() {
        guard var run = djRun, djPhase == .fade else { return }
        retireTail(fadeOut: 0, ring: tail?.rings == true ? Self.djTailRingSeconds : 0)
        djMainFade = 1
        applyVolume()
        if run.spec.plan.hasPostRoll, !run.glideDropped {
            djPhase = .postRoll
            run.phaseElapsed = 0
            djRun = run
        } else {
            djFinish(how: "complete")
        }
    }

    /// The transition is over: identity overlays, the conductor stops. A tail still sounding
    /// (a post-advance cut) ramps out over `djTailCutFadeSeconds` — never a hard, clicking stop.
    private func djFinish(how: String) {
        let run = djRun
        djRun = nil
        djConductor?.cancel(); djConductor = nil
        djHandoverTask?.cancel(); djHandoverTask = nil
        if tail != nil { retireTail(fadeOut: Self.djTailCutFadeSeconds, ring: 0) }
        resetDJOverlays()
        djPhase = .idle
        if built {
            applyRate(); applyPitch(); applyVolume()
            for e in MixEngine.Effect.allCases { applyEffect(e) }
        }
        publishDJDisplay()
        if let run { onDJTransitionEnded?(run.incomingEngaged ? run.spec.incoming.songId : nil, how) }
    }

    private func resetDJOverlays() {
        djRateMul = 1
        djPitchAdd = 0
        djTexture = nil
        djMainFade = 1
    }

    // MARK: Transport during a transition

    /// ▶ mid-transition: both decks resume where they paused (the conductor's clock with them —
    /// a fade the pause held back starts on its next tick).
    private func djResume() {
        guard let t = tail else { return }
        if let run = djRun, !run.handoverDone { djHandoverLanded(run.id, startFade: false) }
        configureSession()
        guard startEngineIfNeeded() else { return }
        t.player.play()
        if djPhase != .preRoll {
            if _stemMode { for n in stemVoices() { n.play() } } else { player.play() }
        }
        playAnchor = nil
        isPlaying = true
        refreshStemMonitor()
    }

    /// A listener touch on tempo / pitch / effects mid-transition: the glide ends at once — the
    /// listener wins (np-dj-mode §3). The crossfade itself carries on.
    private func djListenerTookControl(_ what: String) {
        if djEase != nil { settleDJEase() }       // a hand-back's ease: the listener's settings now
        guard var run = djRun, !run.glideDropped else { return }
        run.glideDropped = true
        djRun = run
        DJMode.log("listener took \(what) during \(djPhase.rawValue) — glide ends")
        switch djPhase {
        case .preRoll:
            if let t = tail { t.rateMul = 1; t.pitchAdd = 0; t.texture = nil; applyTail(t) }
        case .fade:
            djRateMul = 1; djPitchAdd = 0; djTexture = nil
            applyRate(); applyPitch()
            for e in MixEngine.Effect.allCases { applyEffect(e) }
        case .postRoll:
            djFinish(how: "listener")
        case .idle:
            break
        }
    }

    /// ⏭ during the PRE-ROLL (np-dj-mode §3 transport): the skip is the advance — drop the rest of
    /// the pre-roll and fade over `fadeSeconds` from now (the 60 ms handover still lands first;
    /// paused, the fade starts on ▶). False when not in a pre-roll.
    @discardableResult
    func djSkipDuringPreRoll(fadeSeconds: Double) -> Bool {
        guard var run = djRun, djPhase == .preRoll else { return false }
        run.spec.plan.preRollSeconds = 0
        run.spec.plan.fadeSeconds = max(AutoTransition.minImmediateFadeSeconds, fadeSeconds)
        djRun = run
        DJMode.log("skip during pre-roll song=\(run.outgoingSongId) → fade \(String(format: "%.1f", fadeSeconds))s now")
        if run.handoverDone { djStartFade() }
        return true
    }

    /// ⏭ while PAUSED in a pre-roll (nothing would sound until ▶): drop the transition — the
    /// outgoing is the song again — so the host's immediate advance can take over.
    func djAbandonForSkip() {
        guard djRun != nil else { return }
        djCut(reason: "skip while paused")
    }

    /// ⏭ during the POST-ROLL: the glide ends at once (the listener wins) so a new skip can mix
    /// out of the song. False when not in a post-roll.
    @discardableResult
    func djEndPostRollForSkip() -> Bool {
        guard djRun != nil, djPhase == .postRoll else { return false }
        DJMode.log("skip during post-roll song=\(loadedSongId ?? "-") — glide ends")
        djFinish(how: "skip")
        return true
    }

    /// CUT the transition now (seek / a stem action / the engine stopped / the host refused).
    /// Before the incoming engaged the outgoing is still the current song: `restart` (the song
    /// keeps playing) hands it BACK seamlessly (`beginDJReturn`); otherwise it goes back at the
    /// tail's playhead for the caller (seek) or the next ▶ to schedule. After the advance: the
    /// tail ramps out and the incoming carries on at full gain.
    private func djCut(reason: String, restart: Bool = false) {
        guard let run = djRun else { return }
        DJMode.log("cut \(reason) phase=\(djPhase.rawValue) song=\(loadedSongId ?? "-")")
        if run.incomingEngaged {
            djFinish(how: "cut")
            return
        }
        let pos = currentTime
        let wasFade = djPhase == .fade
        djHandoverTask?.cancel(); djHandoverTask = nil
        djConductor?.cancel(); djConductor = nil
        run.spec.incoming.release?()
        // The host refused at the fade start after the controls were frozen: they're the song's.
        if wasFade, let b = tail?.base {
            _rate = b.rate; _pitch = b.pitch; _volume = b.volume
            _effectOn = b.effectOn; _effectStrength = b.effectStrength
        }
        if run.handoverDone, restart, isPlaying, beginDJReturn(run, wasFade: wasFade) {
            publishDJDisplay()
            onDJTransitionEnded?(nil, "cut")
            return
        }
        djRun = nil
        let ranOut = run.handoverDone && restart && isPlaying && pos >= duration - 0.05
        retireTail(fadeOut: engine.isRunning ? Self.djTailCutFadeSeconds : 0, ring: 0)
        setVoiceGains(main: 1, stems: 1)
        resetDJOverlays()
        djPhase = .idle
        if built {
            applyRate(); applyPitch(); applyVolume()
            for e in MixEngine.Effect.allCases { applyEffect(e) }
        }
        if !run.handoverDone {
            // The main voices never stopped: they are the song again (the tail just went).
            clockNode = run.savedClock.node
            clockSR = run.savedClock.sr
            segStartSongSeconds = run.savedClock.segStart
            playAnchor = nil
        } else if ranOut {
            // The tail had already played the song out: that IS its end — never a silent,
            // paused-at-the-end deck that never advances.
            clockNode = nil
            reportEndDeferred(true)
        } else {
            clockNode = nil
            pausedAt = pos
            playAnchor = isPlaying ? (mach_absolute_time(), pos) : nil
            if restart, isPlaying {
                isPlaying = false
                startAudio(fromSongSeconds: pos)
            }
        }
        publishDJDisplay()
        onDJTransitionEnded?(nil, "cut")
    }

    /// HAND-BACK (a cut before the advance, the song still playing): schedule the main chain at
    /// the tail's exact playhead on a shared host time, matched to the tail's sound (its rate /
    /// pitch / texture as overlays, the same level), cross 60 ms linearly, release the tail, then
    /// ease the overlays back to the listener's settings. False when it can't (no render clock,
    /// the song is over) — the caller falls back.
    private func beginDJReturn(_ run: DJRun, wasFade: Bool) -> Bool {
        guard let t = tail, built, isEngaged, engine.isRunning, file != nil, sampleRate > 0 else { return false }
        let tailRate = tailEffectiveRate(t)
        if !wasFade { t.base = liveControls() }    // freeze what the tail plays while it hands back
        // The main chain takes the tail's sound: its glide + texture as overlays.
        djRateMul = (t.base.rate * t.rateMul) / max(0.01, _rate)
        djPitchAdd = t.pitchAdd
        djTexture = t.texture
        djMainFade = 1
        djRun = nil
        djPhase = .idle
        applyTail(t)
        applyRate(); applyPitch(); applyVolume()
        for e in MixEngine.Effect.allCases { applyEffect(e) }
        guard let start = StemSync.sampleStart(clocks: [inputMixer], lead: StemSync.startLead, rate: effectiveRate),
              let p = StemSync.voicePlayhead(t.player, sampleRate: t.sampleRate, segmentStart: t.startSongSeconds,
                                             rate: tailRate, atHostTime: start.hostTime),
              p < duration - 0.3 else {
            resetDJOverlays()
            return false
        }
        generation += 1                           // COMMIT: the new main segment owns the end
        setVoiceGains(main: 0, stems: 0)
        let scheduled = _stemMode ? scheduleStems(fromSongSeconds: p) : scheduleMain(fromSongSeconds: p)
        guard scheduled else {
            setVoiceGains(main: 1, stems: 1)
            resetDJOverlays()
            return false
        }
        let voices: [AVAudioPlayerNode] = _stemMode ? stemVoices() : [player]
        for n in voices {
            n.play(at: StemSync.onClock(n, start.when) ? start.when : AVAudioTime(hostTime: start.hostTime))
        }
        pausedAt = p
        playAnchor = (start.hostTime, p)
        let rid = run.id
        let task = StemSync.crossfade(
            atHostTime: start.hostTime,
            alive: { [weak self] in self?.djReturn?.id == rid },
            apply: { [weak self] g in
                guard let self, let t = self.tail else { return }
                self.setVoiceGains(main: g, stems: g)
                t.handoverGain = 1 - g
                self.applyTail(t)
            },
            done: { [weak self] in self?.finishDJReturn(rid) })
        djReturn = (rid, task)
        DJMode.log("hand-back song=\(loadedSongId ?? "-") @\(String(format: "%.2f", p))s (glide eases back over \(Self.djEaseSeconds)s)")
        refreshStemMonitor()
        return true
    }

    /// The hand-back cross landed: the tail goes; the overlays ease to identity.
    private func finishDJReturn(_ rid: Int) {
        guard let r = djReturn, r.id == rid else { return }
        djReturn = nil
        retireTail(fadeOut: 0, ring: tail?.rings == true ? Self.djTailRingSeconds : 0)
        setVoiceGains(main: 1, stems: 1)
        startDJEase()
        advanceStemHandover()                     // a stem toggle made during the cut acts now
        refreshStemMonitor()
    }

    /// Any transport during a hand-back: land it at once (main at full gain, the tail gone).
    private func settleDJReturn() {
        guard let r = djReturn else { return }
        djReturn = nil
        r.task.cancel()
        retireTail(fadeOut: engine.isRunning ? Self.djTailCutFadeSeconds : 0, ring: 0)
        setVoiceGains(main: 1, stems: 1)
        settleDJEase()
    }

    private func startDJEase() {
        djEase?.cancel()
        let from = (rate: djRateMul, pitch: djPitchAdd, texture: djTexture)
        guard abs(from.rate - 1) > 1e-4 || abs(from.pitch) > 1e-4 || from.texture != nil, Self.djEaseSeconds > 0 else {
            settleDJEase()
            return
        }
        djEase = Task { @MainActor [weak self] in
            let steps = max(1, Int((Self.djEaseSeconds / 0.025).rounded()))
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(Self.djEaseSeconds / Double(steps) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                let k = 1 - Double(i) / Double(steps)
                self.djRateMul = 1 + (from.rate - 1) * k
                self.djPitchAdd = from.pitch * k
                self.djTexture = from.texture.map { ($0.effect, $0.strength * k) }
                self.applyRate(); self.applyPitch()
                for e in MixEngine.Effect.allCases { self.applyEffect(e) }
            }
            guard let self, !Task.isCancelled else { return }
            self.djEase = nil
            self.resetDJOverlays()
            self.applyRate(); self.applyPitch()
            for e in MixEngine.Effect.allCases { self.applyEffect(e) }
            self.publishDJDisplay()
        }
        publishDJDisplay()
    }

    /// End a hand-back's ease NOW (identity overlays applied).
    private func settleDJEase() {
        let had = djEase != nil || abs(djRateMul - 1) > 1e-9 || djPitchAdd != 0 || djTexture != nil
        djEase?.cancel(); djEase = nil
        defer { publishDJDisplay() }
        guard had, djPhase == .idle else { return }
        resetDJOverlays()
        if built {
            applyRate(); applyPitch(); applyVolume()
            for e in MixEngine.Effect.allCases { applyEffect(e) }
        }
    }

    /// Drop any transition WITHOUT touching the main voices (disengage / a foreign engage).
    private func endDJRun(reason: String) {
        if djReturn != nil { settleDJReturn() }
        settleDJEase()
        guard djRun != nil || tail != nil else { return }
        let ended = djRun
        if let run = djRun {
            DJMode.log("end \(reason) phase=\(djPhase.rawValue)")
            if !run.incomingEngaged { run.spec.incoming.release?() }
        }
        djRun = nil
        djConductor?.cancel(); djConductor = nil
        djHandoverTask?.cancel(); djHandoverTask = nil
        retireTail(fadeOut: 0, ring: 0)
        setVoiceGains(main: 1, stems: 1)
        resetDJOverlays()
        djPhase = .idle
        publishDJDisplay()
        // The host hears every end (its per-transition state — a pending skip — must not outlive it).
        if let ended { onDJTransitionEnded?(ended.incomingEngaged ? ended.spec.incoming.songId : nil, "end \(reason)") }
    }

    /// Take the tail off the air. `fadeOut`: ramp its gain to 0 first (a sounding tail — a hard
    /// stop clicks); `ring`: leave its (wet) nodes attached that much longer so the reverb /
    /// flanger wash rings out. Both 0 (or the engine stopped) ⇒ detached now. The outgoing's
    /// scope is released as soon as its player stops.
    private func retireTail(fadeOut: Double, ring: Double) {
        guard let t = tail else { return }
        tail = nil
        if clockNode === t.player { clockNode = nil }
        guard built, engine.isRunning, fadeOut > 0 || ring > 0 else { disposeTail(t); return }
        retiringTails.append(t)
        Task { @MainActor [weak self] in
            if fadeOut > 0 {
                let steps = max(1, Int((fadeOut / 0.01).rounded()))
                let from = t.mixer.outputVolume
                for i in 1...steps {
                    try? await Task.sleep(nanoseconds: UInt64(fadeOut / Double(steps) * 1_000_000_000))
                    t.mixer.outputVolume = from * Float(1 - Double(i) / Double(steps))
                }
            }
            t.player.stop()                        // its completion is stale (run gone / checked)
            t.release?(); t.release = nil
            if ring > 0 { try? await Task.sleep(nanoseconds: UInt64(ring * 1_000_000_000)) }
            guard let self, self.retiringTails.contains(where: { $0 === t }) else { return }
            self.disposeTail(t)
        }
    }

    /// Stop + DETACH a tail: outputs disconnected first (the mainMixer bus freed, nothing
    /// auto-re-wired onto it), then the nodes detached, then its scope released.
    private func disposeTail(_ t: TailDeck) {
        retiringTails.removeAll { $0 === t }
        t.player.stop()
        if t.player.engine === engine {
            for n in t.nodes.reversed() { engine.disconnectNodeOutput(n) }
            for n in t.nodes { engine.detach(n) }
        }
        t.release?(); t.release = nil
    }

    /// Detach every ringing / ramping tail now (disengage, a graph rebuild).
    private func flushRetiringTails() {
        for t in retiringTails { disposeTail(t) }
        retiringTails = []
    }

    private func tailEffectiveRate(_ t: TailDeck) -> Double {
        let r = (djPhase == .preRoll ? _rate : t.base.rate) * t.rateMul
        return min(max(r, MixEngine.rateRange.lowerBound), MixEngine.rateRange.upperBound)
    }

    /// Realize the tail's state: the outgoing listener's controls (live in the pre-roll, frozen
    /// after) × the glide / texture overlays × the handover + crossfade gains, + its level.
    private func applyTail(_ t: TailDeck) {
        let c = djPhase == .preRoll ? liveControls() : t.base
        t.timePitch.rate = Float(tailEffectiveRate(t))
        t.timePitch.pitch = Float(Self.clampPitchCents((c.pitch + t.pitchAdd) * 100))
        t.mixer.outputVolume = Float(min(c.volume, 1)) * t.handoverGain * t.fadeGain
        t.filter.globalGain = Float(20 * log10(max(c.volume, 1)) + t.levelDb)
        for e in MixEngine.Effect.allCases {
            var on = c.effectOn[e.rawValue] ?? false
            var s = Float(c.effectStrength[e.rawValue] ?? 0.5)
            if !on, let x = t.texture, x.effect == e { on = true; s = Float(x.strength) }
            Self.applyEffect(e, on: on, strength: s, comp: t.comp, filter: t.filter, reverb: t.reverb, flanger: t.flanger)
        }
    }

    // MARK: - DJ Mode volume LEVELING (np-dj-mode §5)

    /// The leveling gain on the main chain's trim right now (dB), and where it's heading.
    @ObservationIgnored private(set) var appliedLevelDb = 0.0
    @ObservationIgnored private(set) var levelTargetDb = 0.0
    @ObservationIgnored private var levelRamp: Task<Void, Never>?
    /// The running ramp's speed (dB/s) — a tail taking the outgoing mid-ramp carries it on.
    @ObservationIgnored private var levelRampRateDbPerSecond = 0.0
    /// A newly-known gain ramps over this (never a step) — `LoudnessLeveling.rampSeconds`.
    static var levelRampSeconds: Double = LoudnessLeveling.rampSeconds
    /// The incoming's gain lands over this at the fade start (its fade gain is ~0 meanwhile).
    static var levelFadeStartSeconds: Double = 0.15
    /// One ramp step (fine enough that an 18 dB correction never zippers).
    static let levelRampStepSeconds: Double = 0.02
    var levelRampInFlight: Bool { levelRamp != nil }
    var levelTrimGainDb: Float { levelTrim.globalGain }

    /// Set the leveling gain (clamped −12…+6 dB). `ramp`: glide there over `seconds` (default
    /// `levelRampSeconds` — an analysis landing mid-play) in `levelRampStepSeconds` steps;
    /// otherwise it lands at once (a track start, before audio).
    func setLevel(db: Double, ramp: Bool, seconds: Double? = nil) {
        let target = min(max(db, LoudnessLeveling.minGainDb), LoudnessLeveling.maxGainDb)
        levelTargetDb = target
        levelRamp?.cancel(); levelRamp = nil
        levelRampRateDbPerSecond = 0
        let total = seconds ?? Self.levelRampSeconds
        guard ramp, built, isEngaged, abs(target - appliedLevelDb) > 0.01, total > 0 else {
            appliedLevelDb = target
            if built { levelTrim.globalGain = Float(target) }
            return
        }
        let from = appliedLevelDb
        let steps = max(1, Int((total / Self.levelRampStepSeconds).rounded()))
        let stepNs = UInt64(total / Double(steps) * 1_000_000_000)
        levelRampRateDbPerSecond = abs(target - from) / total
        levelRamp = Task { @MainActor [weak self] in
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: stepNs)
                guard let self, !Task.isCancelled else { return }
                let v = from + (target - from) * Double(i) / Double(steps)
                self.appliedLevelDb = v
                self.levelTrim.globalGain = Float(v)
            }
            guard let self, !Task.isCancelled else { return }
            self.levelRamp = nil
            self.levelRampRateDbPerSecond = 0
        }
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

// MARK: - DJ Mode automation DISPLAY (np-dj-mode §7 "the controls move")

/// What the Now Playing controls SHOW while a DJ transition automates tempo / pitch / effects —
/// the Mix tab's moving sliders, read-only. Published at ~16 Hz by `NowPlayingDSP` (never per
/// audio buffer), only while automation runs; `active` false ⇒ the controls show the listener's
/// own values. NOTHING here is ever written back as the listener's settings (the DSP's `rate` /
/// `pitch` / effects, the FX Lock carry, the session snapshot and Settings never read it).
@MainActor
@Observable
final class DJAutomationDisplay {
    /// Automation is driving the controls right now (a transition, or a hand-back's ease).
    private(set) var active = false
    /// The tempo the listener HEARS on the song the controls show (pre-roll: the outgoing on the
    /// tail; from the fade start: the incoming).
    private(set) var rate = 1.0
    /// Semitones heard (listener's + the glide's).
    private(set) var pitch = 0.0
    /// Effect rawValue → on / strength as heard (the listener's own, or the transition's sweep on
    /// an effect the listener has off). Absent ⇒ off.
    private(set) var effects: [String: FXLockState.Setting] = [:]
    /// The crossfade, 0 = all outgoing … 1 = all incoming (0 through the pre-roll, 1 after the fade).
    private(set) var crossfade = 0.0
    /// The transition's phase name (`idle` / `preRoll` / `fade` / `postRoll`; `ease` on a hand-back).
    private(set) var phase = "idle"

    /// Publish (assigning only what changed, so the views redraw only when a value moved).
    func publish(active: Bool, rate: Double, pitch: Double, effects: [String: FXLockState.Setting],
                 crossfade: Double, phase: String) {
        if self.active != active { self.active = active }
        // Below what a control can show — no redraw for float noise.
        if abs(self.rate - rate) > 0.0005 { self.rate = rate }
        if abs(self.pitch - pitch) > 0.005 { self.pitch = pitch }
        if self.effects != effects { self.effects = effects }
        if abs(self.crossfade - crossfade) > 0.005 || (crossfade == 0 || crossfade == 1) && self.crossfade != crossfade {
            self.crossfade = crossfade
        }
        if self.phase != phase { self.phase = phase }
    }

    func clear() {
        publish(active: false, rate: 1, pitch: 0, effects: [:], crossfade: 0, phase: "idle")
    }
}
