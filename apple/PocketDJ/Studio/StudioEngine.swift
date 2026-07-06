import Foundation
import Observation
import AVFoundation        // AVAudioEngine + nodes (iOS · iPad · Mac); AVAudioSession is iOS-only (guarded)
import QuartzCore          // CACurrentMediaTime — the pattern clock's host timebase
import os                  // studiodiag Logger — device-switch/recovery diagnostics

// MARK: - Shared Studio audio constants + voicing (engine ⇄ offline renderer)

/// Constants and pure helpers shared by the LIVE audition graph (`StudioEngine`) and the OFFLINE
/// renderer (`StudioRender`). They live on a plain enum — not on the `@MainActor` engine class —
/// because the renderer runs off the main actor and enum statics are nonisolated by construction.
/// Keeping the FX voicing here is load-bearing: the spec's "Save bakes nothing" contract means the
/// user auditions through the live chain and later plays a BAKED render — the two must sound
/// identical, so there is exactly ONE place that maps a `StudioSampleEdit` onto AU parameters.
enum StudioAudio {
    /// The fixed downstream format (MixEngine's canonical): everything below a normalizer mixer is
    /// wired at 44.1 kHz stereo ONCE and never reconnected, so no per-file load can reconfigure a
    /// live AU's channel count / sample rate (which AVAudioEngine asserts-and-crashes on).
    static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    static let canonicalSampleRate = 44_100.0

    /// Is `format` the canonical processing shape a pattern-row player accepts?
    /// (`scheduleBuffer` with a buffer whose format differs from the player's connection format
    /// raises — so pattern/loop buffers are gated on this before they ever reach a node.)
    static func isCanonical(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == canonicalSampleRate && format.channelCount == 2
            && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
    }

    /// dB → linear multiplier for the pattern row gains (mixer `outputVolume`). Clamped to the
    /// sample-edit gain domain (−60…+12 dB) so a hand-edited document can't drive a mixer to an
    /// absurd multiplier; +12 dB ≈ ×3.98 works on `AVAudioMixerNode` despite the documented 0…1
    /// range (the same >unity trick MixEngine's boost uses, just without a limiter — pattern rows
    /// are short percussive hits, not sustained program material).
    static func gainMultiplier(db: Double) -> Float {
        Float(pow(10.0, min(12, max(-60, db)) / 20.0))
    }

    /// Copy `buffer` into a new buffer of EXACTLY `frames` frames — truncating extra content,
    /// zero-padding a shortfall. The loop-audition seam contract (spec §2): `StudioLoop.frames`
    /// is the authoritative rendered length, and `scheduleBuffer(options: .loops)` loops the
    /// buffer's `frameLength` verbatim, so a decoded CAF a frame long or short (container /
    /// converter rounding) would tick audibly at every seam. Pure + testable. nil on a
    /// non-positive target, a non-float buffer, or allocation failure.
    static func trimmedOrPadded(_ buffer: AVAudioPCMBuffer, to frames: Int64) -> AVAudioPCMBuffer? {
        guard frames > 0, frames <= Int64(UInt32.max) else { return nil }
        if Int64(buffer.frameLength) == frames { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        let copy = Int(min(Int64(buffer.frameLength), frames))
        let pad = Int(frames) - copy
        for c in 0..<Int(buffer.format.channelCount) {
            if copy > 0 { memcpy(dst[c], src[c], copy * MemoryLayout<Float>.size) }
            // Fresh AVAudioPCMBuffer memory is NOT guaranteed zeroed — pad explicitly or the
            // "silence" tail plays whatever was in the allocation.
            if pad > 0 { memset(dst[c] + copy, 0, pad * MemoryLayout<Float>.size) }
        }
        out.frameLength = AVAudioFrameCount(frames)
        return out
    }

    /// Realize a sample's non-destructive edit onto the audition/render AU chain — the ONE
    /// voicing both `StudioEngine` (live) and `StudioRender` (bake) apply, so audition and baked
    /// file always agree. Trim is deliberately NOT here: it is a schedule-window decision
    /// (`scheduleSegment`), not an AU parameter.
    ///   • rate/pitch → timePitch (MixEngine's ranges, mirrored by `StudioSampleEdit.clamped`);
    ///   • gainDb → the EQ's `globalGain` (the MixEngine boost trick: the single band stays
    ///     bypassed, the NODE stays active, so the gain applies with zero coloration);
    ///   • wets → reverb/delay `wetDryMix`, with the whole AU BYPASSED at 0 so a dry sample
    ///     renders bit-clean (and the offline tail-drain isn't chasing an idle reverb's floor).
    /// Delay voicing is a fixed musical slap (0.3 s, 30 % feedback) — the edit exposes only a
    /// wet amount, so the character must be constant or saved renders would drift between builds.
    static func applyEditToChain(_ edit: StudioSampleEdit,
                                 timePitch: AVAudioUnitTimePitch, eq: AVAudioUnitEQ,
                                 reverb: AVAudioUnitReverb, delay: AVAudioUnitDelay) {
        let e = edit.clamped()
        timePitch.rate = Float(e.rate)
        timePitch.pitch = Float(e.pitchSemitones * 100)   // semitones → cents
        eq.globalGain = Float(e.gainDb)
        eq.bands.first?.bypass = true                     // gain carrier only — never a filter
        eq.bypass = false                                 // node active so globalGain applies
        reverb.wetDryMix = Float(e.reverbWet * 100)
        reverb.bypass = e.reverbWet <= 0
        delay.delayTime = 0.3
        delay.feedback = 30
        delay.lowPassCutoff = 15_000
        delay.wetDryMix = Float(e.delayWet * 100)
        delay.bypass = e.delayWet <= 0
    }
}

// MARK: - Pattern clock (TimelineView-sampled, deliberately NOT @Observable)

/// The sequencer's fast step clock. Like `PlayerEngine.PlayerClock`, it is a plain `@MainActor`
/// class with stored vars — NOT `@Observable` — because the step highlight advances 8×/s at
/// 120 BPM and Observation-driven invalidation from a fast clock re-lays-out the surrounding
/// controls and drops in-flight taps (the proven dead-play/pause-button bug). The grid UI samples
/// `currentStep` inside a `TimelineView`, which redraws itself without touching Observation.
@MainActor
final class StudioPatternClock {
    /// `CACurrentMediaTime()` at which step 0 of pass 0 becomes audible (the shared `play(at:)`
    /// host time the engine started every row player on).
    var startedAtHost: Double = 0
    /// The tempo the running pattern was started at (step duration = 60/bpm/4 s).
    var bpm: Double = 120
    /// True only while the pattern is actually rendering (set by the engine on start/stop and
    /// cleared across stalls, so a frozen highlight never keeps marching during silence).
    var running = false

    /// The 0…15 step currently sounding, or nil when stopped / still inside the start latency
    /// pre-roll. Sampled — never observed.
    var currentStep: Int? {
        guard running, bpm > 0 else { return nil }
        let elapsed = CACurrentMediaTime() - startedAtHost
        guard elapsed >= 0 else { return nil }             // start latency window — nothing sounds yet
        let stepDur = 60.0 / bpm / 4.0
        return Int(elapsed / stepDur) % StudioPattern.stepCount
    }
}

// MARK: - StudioEngine

/// The Performance tab's audition engine — ONE lazily-built `AVAudioEngine` graph with three
/// duties (spec §4):
///
///   1. **Sample audition** — `player → inputMixer (format normalizer) → timePitch →
///      EQ(globalGain) → reverb → delay → mainMixer`. Everything downstream of `inputMixer` is
///      pinned at canonical 44.1 kHz stereo for life; ONLY the player→inputMixer link is
///      reconnected per load at the file's `processingFormat`, with the player stopped (the
///      MixEngine `loadFile` contract — studio files are guaranteed heterogeneous: mic captures
///      are hardware-format, typically 48 kHz mono). The edit's trim window is honored via
///      `scheduleSegment`; rate/pitch/gain/wets apply LIVE to the AUs (`StudioAudio` voicing).
///   2. **Loop audition** — the rendered `loop-<id>.caf` decoded FULLY to PCM, trimmed/padded to
///      the loop's authoritative `frames`, then `scheduleBuffer(options: .loops)` on a dedicated
///      player → gain → mainMixer at canonical (loops are baked canonical by StudioRender; they
///      never ride the FX chain — their edits are already in the file).
///   3. **Pattern playback** — one player per row (≤ 8, all attached at build so the live graph
///      is never reconfigured), buffers pre-baked by StudioRender, steps scheduled
///      sample-accurately on each player's own timeline with `.interrupts` (classic mono-choke:
///      a retrigger cuts the ringing hit), a 1-bar horizon re-armed by the tick.
///
/// Route-change hardening is the MixEngine contract wholesale: lazy idempotent `ensureEngine()`,
/// `startEngineIfNeeded()` before EVERY `play()`/`play(at:)` (play on a stopped engine is an
/// uncatchable ObjC crash), intent flags separate from node state, iOS interruption park/latch +
/// route-change recovery + media-reset rebuild, a per-INSTANCE `.AVAudioEngineConfigurationChange`
/// observer re-registered after rebuilds, a ~10 Hz tick watchdog retrying `engine.start()` ~1/s,
/// zombie-node re-prime (`pause()+play()`), and `healParkedPlayers` comparing intent vs
/// `node.isPlaying`. Diagnostics flow through the `mixdiag`-style `dlog` into `MixDiag.shared`
/// so a Settings ▸ Debug capture session covers Studio failures for free.
///
/// App-scoped (`@Observable` env object, owned by PocketDJApp) so audition survives navigation.
/// This engine PLAYS ONLY — files are written by `StudioRender`/`StudioMicRecorder` and records
/// by `StudioStore`.
@MainActor
@Observable
final class StudioEngine {

    // MARK: Published state (small + discrete — safe to observe)

    /// The sample loaded into the audition chain (drives the editor's transport state).
    private(set) var loadedSampleId: String?
    /// Sample-audition INTENT — the user pressed play and nothing ended/stopped it. Deliberately
    /// separate from `samplePlayer.isPlaying` (node state): recovery restores INTENT after the
    /// system stops the engine, and the node's claim is untrustworthy across stalls (zombies).
    private(set) var isPlayingSample = false
    /// The loop currently auditioning (nil when loop audition is stopped).
    private(set) var loadedLoopId: String?
    private(set) var isPlayingLoop = false
    /// The pattern whose rows/buffers are loaded onto the row players.
    private(set) var loadedPatternId: String?
    private(set) var isPlayingPattern = false

    /// The sequencer's fast step clock (TimelineView-sampled; see `StudioPatternClock`).
    @ObservationIgnored let patternClock = StudioPatternClock()

    /// The sequencer's hard row cap (spec §4): 8 pre-attached player+gain pairs. Fixed at build
    /// so pattern load/start NEVER attaches/detaches on a live graph (a mid-render graph
    /// reconfiguration pauses player nodes on-device — the tap-install lesson). `nonisolated`
    /// so the off-main StudioRender actor reads the same cap (it's a Sendable constant).
    nonisolated static let maxPatternRows = 8

    // MARK: Graph (all @ObservationIgnored — engine internals must never invalidate SwiftUI)

    @ObservationIgnored private var engine = AVAudioEngine()
    /// Graph-built latch. False on a headless host where `engine.start()` fails (soft-fail: the
    /// tab degrades silent instead of crashing) and after a media reset until the rebuild.
    @ObservationIgnored private var built = false
    @ObservationIgnored private var samplePlayer: AVAudioPlayerNode?
    @ObservationIgnored private var sampleInputMixer: AVAudioMixerNode?
    @ObservationIgnored private var sampleTimePitch: AVAudioUnitTimePitch?
    @ObservationIgnored private var sampleEQ: AVAudioUnitEQ?
    @ObservationIgnored private var sampleReverb: AVAudioUnitReverb?
    @ObservationIgnored private var sampleDelay: AVAudioUnitDelay?
    @ObservationIgnored private var loopPlayer: AVAudioPlayerNode?
    @ObservationIgnored private var loopGain: AVAudioMixerNode?
    @ObservationIgnored private var rowPlayers: [AVAudioPlayerNode] = []
    @ObservationIgnored private var rowGains: [AVAudioMixerNode] = []

    // MARK: Sample-audition state

    @ObservationIgnored private var sampleFile: AVAudioFile?
    /// The loaded sample file's path — the media-reset rebuild reopens from here (the old
    /// `AVAudioFile` object is orphaned with the daemon).
    @ObservationIgnored private var samplePath: String?
    /// Security-scope release for a user-folder sample file — held for the load's lifetime,
    /// released on the next load / unload (releasing early ⇒ silent 0:00, the BurnStore lesson).
    @ObservationIgnored private var sampleRelease: (() -> Void)?
    /// The live edit (clamped). The trim window is read from HERE at schedule time and by the
    /// tick's end-boundary check, so an edit mid-audition takes effect without a reschedule.
    @ObservationIgnored private var sampleEdit = StudioSampleEdit.neutral
    /// `playerTime.sampleTime` resets to 0 at every `scheduleSegment` — this is the additive
    /// base (source seconds at the segment's start) that makes `samplePlayheadSeconds()` a true
    /// source-timeline playhead (MixEngine's `segmentStartSeconds` bookkeeping).
    @ObservationIgnored private var sampleSegmentStartSeconds: Double = 0
    /// Last known source position while paused / not rendering — the playhead fallback, kept
    /// near-truth by the tick's mirror write while playing (positions freeze with the engine).
    @ObservationIgnored private var samplePausedAt: Double = 0
    /// A segment is currently scheduled on the player (play resumes it; false forces a fresh
    /// `scheduleSegment` — after end-of-window, a seek, or a trim change while paused).
    @ObservationIgnored private var sampleScheduled = false
    /// Non-nil while a SLICE pad is auditioning one-shot: the source-seconds out-point the tick
    /// stops at. Independent of the trim window, so slice pads never disturb the editor transport.
    @ObservationIgnored private var sliceEndSec: Double?

    // MARK: Loop-audition state

    /// The decoded, frames-exact loop buffer (kept for the media-reset rebuild + re-prime; the
    /// CAF's security scope is released immediately after decode — nothing reads the file again).
    @ObservationIgnored private var loopBuffer: AVAudioPCMBuffer?

    // MARK: Pattern state

    /// Per-row step toggles for the loaded pattern (≤ 8 rows, engine's own copy — the store's
    /// document can mutate underneath; a running pattern plays what was loaded).
    @ObservationIgnored private var patternSteps: [[Bool]] = []
    /// Row index → pre-baked canonical PCM buffer. Rows absent here (deleted target, silent row,
    /// bad format) are simply never scheduled — skipped, never a throw (spec §2).
    @ObservationIgnored private var patternBuffers: [Int: AVAudioPCMBuffer] = [:]
    @ObservationIgnored private var patternBpm: Double = 120
    /// Number of 1-bar passes whose steps are already scheduled. The tick keeps this one pass
    /// ahead of the audible pass (the spec's 1-bar scheduling horizon).
    @ObservationIgnored private var armedThroughPass = 0
    /// `play(at:)` pre-roll so all row players start on ONE shared host time (StemPlayer's
    /// sample-sync start), far enough out that scheduling completes before it arrives.
    private static let patternStartLatency = 0.1

    // MARK: Recovery machinery (the MixEngine hardening stack)

    #if os(iOS)
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaResetObserver: NSObjectProtocol?
    /// Interruption `.began` parked a live audition, so `.ended` may auto-resume it. LATCHED —
    /// `.began` can be delivered twice over Bluetooth/CarPlay and must never erase the pairing
    /// record. While parked the watchdog does NOT retry (restarting mid-call is wrong); an
    /// explicit user transport call wipes the park (the user took control).
    @ObservationIgnored private var interruptionParked = false
    /// What `.began` itself silenced — `.ended` resumes ONLY these (never a stale pause memory,
    /// never a loaded-but-never-played item).
    @ObservationIgnored private var parkedSample = false
    @ObservationIgnored private var parkedLoop = false
    @ObservationIgnored private var parkedPattern = false
    #endif
    /// `.AVAudioEngineConfigurationChange` observer — registered PER ENGINE INSTANCE (the
    /// notification's object is the engine), so the media-reset rebuild re-registers it.
    @ObservationIgnored private var configChangeObserver: NSObjectProtocol?
    /// The engine was seen down (or reconfigured) while something was live. The next RENDERING
    /// tick re-primes: a node that played through an engine stop can come back as a ZOMBIE
    /// (isPlaying true, renders silence) that only `pause()+play()` revives.
    @ObservationIgnored private var engineDownWhileLive = false
    /// Rate-limits the watchdog's `engine.start()` retries to ~1/s.
    @ObservationIgnored private var lastEngineRecoveryAttempt: Date?
    /// The ~10 Hz tick — watchdog + sample end-boundary + pattern horizon re-arm. Runs only
    /// while something intends to play (idle Studio costs nothing).
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastTickAt: Date?
    @ObservationIgnored private var lastDiagHeartbeat: Date?
    @ObservationIgnored private var lastRenderingDiag: Bool?

    /// Studio diagnostics ride the SAME subsystem as MixEngine's mixdiag (one `log stream`
    /// predicate captures both) under their own category, and every line also lands in
    /// `MixDiag.shared` so the Settings ▸ Debug capture/export panel covers this engine too.
    @ObservationIgnored private static let diag = Logger(subsystem: "com.levi.pocketdj", category: "studiodiag")
    private func dlog(_ s: String) {
        Self.diag.info("\(s, privacy: .public)")
        MixDiag.shared.append("studio " + s)   // no-op unless a Debug capture session is running
    }

    /// Any duty currently intending to sound (arbiter/tick/watchdog gate).
    private var anyIntentPlaying: Bool { isPlayingSample || isPlayingLoop || isPlayingPattern }

    // MARK: - Pure step math (nonisolated — unit-tested without an engine)

    /// One 16th-note step in FRAMES at `sampleRate` (step duration = 60/bpm/4 s — one bar of
    /// 16ths in 4/4, spec §4). Non-positive inputs fall back to the schema's 120 BPM / canonical
    /// rate defaults (mirroring `StudioPattern.barMs`) so a degraded document can't divide by 0.
    nonisolated static func stepFrames(bpm: Double, sampleRate: Double) -> AVAudioFramePosition {
        let b = bpm > 0 ? bpm : 120
        let sr = sampleRate > 0 ? sampleRate : StudioAudio.canonicalSampleRate
        return AVAudioFramePosition((sr * 60.0 / b / 4.0).rounded())
    }

    /// The sample-accurate player-timeline time of step `index`, `index` steps after `anchor`
    /// (step 0 of pass 0 — the moment the row players started). Integer-frame arithmetic on the
    /// shared step size, so step N is bit-identical however many passes have elapsed.
    nonisolated static func stepTime(anchor: AVAudioTime, index: Int, bpm: Double, sampleRate: Double) -> AVAudioTime {
        let sr = sampleRate > 0 ? sampleRate : StudioAudio.canonicalSampleRate
        let frames = stepFrames(bpm: bpm, sampleRate: sr)
        return AVAudioTime(sampleTime: anchor.sampleTime + AVAudioFramePosition(index) * frames, atRate: sr)
    }

    // MARK: - Lifecycle

    /// Build the graph ON FIRST USE and start the engine. Idempotent. Soft-fails on a headless
    /// host (no audio device): `built` stays false and every transport call no-ops silently.
    func ensureEngine() {
        guard !built else { return }
        #if os(iOS)
        activateAudioSession()
        registerInterruptionHandling()
        registerRouteChangeHandling()
        registerMediaResetHandling()
        #endif
        let canonical = StudioAudio.canonicalFormat

        // Sample-audition chain. player→inputMixer starts at canonical as a placeholder; each
        // load reconnects ONLY that link at the file's real format (the mixer normalizes into
        // the pinned chain — a mono/48 kHz mic capture never reconfigures a live AU).
        let player = AVAudioPlayerNode()
        let inputMixer = AVAudioMixerNode()
        let tp = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let rv = AVAudioUnitReverb()
        let dl = AVAudioUnitDelay()
        rv.loadFactoryPreset(.mediumHall)   // the Studio reverb voicing (matches StudioRender's bake)
        for n in [player, inputMixer, tp, eq, rv, dl] as [AVAudioNode] { engine.attach(n) }
        engine.connect(player, to: inputMixer, format: canonical)
        engine.connect(inputMixer, to: tp, format: canonical)
        engine.connect(tp, to: eq, format: canonical)
        engine.connect(eq, to: rv, format: canonical)
        engine.connect(rv, to: dl, format: canonical)
        engine.connect(dl, to: engine.mainMixerNode, format: canonical)
        samplePlayer = player; sampleInputMixer = inputMixer; sampleTimePitch = tp
        sampleEQ = eq; sampleReverb = rv; sampleDelay = dl

        // Loop-audition voice: baked CAFs are already canonical — no normalizer, no FX (their
        // edits are in the file); a dedicated gain keeps the loop's bus independent.
        let lp = AVAudioPlayerNode(); let lg = AVAudioMixerNode()
        engine.attach(lp); engine.attach(lg)
        engine.connect(lp, to: lg, format: canonical)
        engine.connect(lg, to: engine.mainMixerNode, format: canonical)
        loopPlayer = lp; loopGain = lg

        // The 8 sequencer voices — pre-attached for life (see `maxPatternRows`). Plain
        // player → gain → mainMixer: buffers are pre-baked with edits, so the scheduled path
        // carries NO live AU latency and step timing is exactly the schedule (spec §4).
        var rps: [AVAudioPlayerNode] = []; var rgs: [AVAudioMixerNode] = []
        for _ in 0..<Self.maxPatternRows {
            let p = AVAudioPlayerNode(); let g = AVAudioMixerNode()
            engine.attach(p); engine.attach(g)
            engine.connect(p, to: g, format: canonical)
            engine.connect(g, to: engine.mainMixerNode, format: canonical)
            rps.append(p); rgs.append(g)
        }
        rowPlayers = rps; rowGains = rgs

        engine.prepare()
        do { try engine.start() } catch {
            dlog("ensureEngine: start FAILED (headless?) — degrading silent")
            return
        }
        built = true
        registerConfigChangeHandling()   // per-instance: system stops the engine on a route-format change
        // Re-push whatever the UI already set before the graph existed.
        StudioAudio.applyEditToChain(sampleEdit, timePitch: tp, eq: eq, reverb: rv, delay: dl)
        dlog("ensureEngine: graph built, out=\(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate))Hz")
    }

    /// Start the engine if it isn't running — REPORTING failure instead of swallowing it. Every
    /// transport path checks this before `play()`/`play(at:)`: play on a stopped engine raises an
    /// UNCATCHABLE ObjC exception (the headphones→speaker route-change crash). A failed start
    /// means "stay parked": intent stays set and the tick watchdog + observers bring the audio
    /// back the moment the engine can run again.
    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        guard built else { return false }
        if engine.isRunning { return true }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        do { try engine.start() } catch { return false }
        return engine.isRunning
    }

    func teardown() {
        tickTask?.cancel(); tickTask = nil
        stopPattern()
        stopLoop()
        stopSample()
        unloadSample()
        if built { engine.stop() }
        #if os(iOS)
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o); interruptionObserver = nil }
        if let o = routeChangeObserver { NotificationCenter.default.removeObserver(o); routeChangeObserver = nil }
        if let o = mediaResetObserver { NotificationCenter.default.removeObserver(o); mediaResetObserver = nil }
        #endif
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
    }

    // MARK: Test seams (tests can't post as the shared session / the private engine instance)

    func stopEngineForTesting() { engine.stop() }
    var engineIsRunningForTesting: Bool { engine.isRunning }
    /// Drive the route/config-change observer path directly.
    func simulateEngineRecoveryForTesting() { recoverFromEngineStop() }
    /// Park the sample player NODE while leaving intent playing (the macOS device-switch state).
    func parkSamplePlayerForTesting() { samplePlayer?.pause() }
    func samplePlayerIsPlayingForTesting() -> Bool { samplePlayer?.isPlaying ?? false }

    // MARK: - Sample audition

    /// Load a sample into the audition chain. `url` is the RAW sample file (edits are
    /// non-destructive — they live on the chain, not in the file); `release` is a held
    /// security-scope closure for user-folder files (nil for app storage). Replaces any prior
    /// load, releasing ITS scope. On an unreadable file the release is dropped immediately and
    /// the current load is left untouched (never leak a scope — the MixEngine loadFile contract).
    func loadSample(_ sample: StudioSample, url: URL, release: (() -> Void)? = nil) {
        ensureEngine()
        guard built, let player = samplePlayer, let mixer = sampleInputMixer else { release?(); return }
        guard let file = try? AVAudioFile(forReading: url) else {
            release?()
            dlog("loadSample: unreadable \(url.lastPathComponent)")
            return
        }
        // The ONE per-load reconnection, with the player STOPPED: the mixer normalizes this
        // file's real format into the canonical chain (a live AU must never see a format change).
        player.stop()
        isPlayingSample = false
        engine.connect(player, to: mixer, format: file.processingFormat)
        sampleRelease?()                  // previous file's scope — hold the new one
        sampleRelease = release
        sampleFile = file
        samplePath = url.path
        sampleScheduled = false
        loadedSampleId = sample.id
        sampleEdit = sample.edit.clamped()
        if let tp = sampleTimePitch, let eq = sampleEQ, let rv = sampleReverb, let dl = sampleDelay {
            StudioAudio.applyEditToChain(sampleEdit, timePitch: tp, eq: eq, reverb: rv, delay: dl)
        }
        samplePausedAt = sampleWindowSeconds()?.start ?? 0
        maybeResignArbiter()
        dlog("loadSample \(sample.id) sr=\(Int(file.processingFormat.sampleRate)) ch=\(file.processingFormat.channelCount) len=\(file.length)")
    }

    /// Drop the loaded sample + its security scope (editor closed). Stops audition first.
    func unloadSample() {
        samplePlayer?.stop()
        isPlayingSample = false
        sampleScheduled = false
        sliceEndSec = nil
        sampleFile = nil
        samplePath = nil
        loadedSampleId = nil
        sampleRelease?(); sampleRelease = nil
        maybeResignArbiter()
    }

    /// Start/resume sample audition from the paused position (window start after load/end).
    /// Sets INTENT even when the engine can't run right now (mid route change) — the watchdog
    /// restores it; only the uncatchable dead-engine `play()` is skipped.
    func playSample() {
        guard sampleFile != nil else { return }
        ensureEngine()
        sliceEndSec = nil                 // normal transport plays the trim window, not a slice pad
        clearInterruptionPark()
        if !sampleScheduled {
            guard scheduleSampleWindow(from: samplePausedAt) else { return }   // zero-frame window — refuse
        }
        if startEngineIfNeeded() { samplePlayer?.play() }
        isPlayingSample = true
        NowPlayingArbiter.shared.claim(self)
        dlog("ui: playSample run=\(engine.isRunning ? 1 : 0) from=\(String(format: "%.2f", samplePausedAt))")
        startTickIfNeeded()
    }

    /// Pause, keeping the schedule (play resumes exactly here).
    func pauseSample() {
        guard isPlayingSample else { return }
        samplePausedAt = samplePlayheadSeconds()
        samplePlayer?.pause()
        isPlayingSample = false
        sliceEndSec = nil
        clearInterruptionPark()
        maybeResignArbiter()
        dlog("ui: pauseSample at=\(String(format: "%.2f", samplePausedAt))")
    }

    /// Stop and rewind to the trim window's start.
    func stopSample() {
        samplePlayer?.stop()
        sampleScheduled = false
        sliceEndSec = nil
        samplePausedAt = sampleWindowSeconds()?.start ?? 0
        if isPlayingSample { dlog("ui: stopSample") }
        isPlayingSample = false
        clearInterruptionPark()
        maybeResignArbiter()
    }

    /// One-shot audition of a SLICE window `[startMs, endMs)` on the ALREADY-LOADED sample (the
    /// editor loads the raw file). Self-contained: schedules the segment directly and stops at the
    /// out-point via the tick's `sliceEndSec` check — it never reads/writes the trim window, so
    /// tapping pads doesn't disturb the editor's own transport. Reuses the one `samplePlayer` + FX
    /// chain (monophonic, like loop/sample audition). A zero-frame window is refused (crash guard).
    func playSlice(startMs: Int, endMs: Int) {
        ensureEngine()
        guard built, let f = sampleFile, let player = samplePlayer else { return }
        let sr = f.processingFormat.sampleRate
        guard sr > 0, endMs > startMs else { return }
        let durSec = Double(f.length) / sr
        let from = min(max(0, Double(startMs) / 1000), durSec)
        let to = min(max(from, Double(endMs) / 1000), durSec)
        let startFrame = AVAudioFramePosition((from * sr).rounded())
        let endFrame = AVAudioFramePosition((to * sr).rounded())
        let count = endFrame - startFrame
        guard count > 0 else { return }                 // zero-frame schedule = uncatchable crash
        clearInterruptionPark()
        player.stop()
        player.scheduleSegment(f, startingFrame: startFrame, frameCount: AVAudioFrameCount(count),
                               at: nil, completionHandler: nil)
        sampleSegmentStartSeconds = from
        samplePausedAt = from
        sampleScheduled = true
        sliceEndSec = to
        if startEngineIfNeeded() { player.play() }
        isPlayingSample = true
        NowPlayingArbiter.shared.claim(self)
        startTickIfNeeded()
    }

    /// Seek within the sample's source timeline (clamped into the trim window). While playing
    /// this stops + reschedules + replays inside one main-actor turn (the tick can't interleave).
    func seekSample(toSeconds t: Double) {
        guard sampleFile != nil else { return }
        let wasPlaying = isPlayingSample
        samplePlayer?.stop()
        sampleScheduled = false
        sliceEndSec = nil
        samplePausedAt = t
        guard wasPlaying else { return }
        if scheduleSampleWindow(from: t), startEngineIfNeeded() {
            samplePlayer?.play()
        }
        // Intent stays playing either way — a failed start is the watchdog's to fix.
    }

    /// Apply a (possibly mid-slider) edit LIVE: rate/pitch/gain/wets hit the AUs immediately;
    /// the trim window is a schedule decision, so a trim change takes effect at the next
    /// (re)schedule — and the tick's end-boundary check reads the live window, so tightening
    /// the out-point mid-audition still ends playback at the new mark.
    func applyEdit(_ edit: StudioSampleEdit) {
        let e = edit.clamped()
        let trimChanged = e.trimStartMs != sampleEdit.trimStartMs || e.trimEndMs != sampleEdit.trimEndMs
        sampleEdit = e
        if built, let tp = sampleTimePitch, let eq = sampleEQ, let rv = sampleReverb, let dl = sampleDelay {
            StudioAudio.applyEditToChain(e, timePitch: tp, eq: eq, reverb: rv, delay: dl)
        }
        if trimChanged, !isPlayingSample { sampleScheduled = false }   // next play uses the new window
    }

    /// The TRUE audition playhead in the sample's SOURCE seconds — the region editor's in/out
    /// marks and the cue-at-playhead reads. Read from the player's render clock
    /// (`playerTime.sampleTime` is in the file's own rate and resets each `scheduleSegment`, so
    /// `sampleSegmentStartSeconds` is added back); falls back to the paused/mirrored position
    /// while not rendering. Sampled by a TimelineView — deliberately not observable state.
    func samplePlayheadSeconds() -> Double {
        if let player = samplePlayer, player.isPlaying,
           let nodeTime = player.lastRenderTime,
           let pt = player.playerTime(forNodeTime: nodeTime),
           let sr = sampleFile?.processingFormat.sampleRate, sr > 0 {
            return sampleSegmentStartSeconds + Double(pt.sampleTime) / sr
        }
        return samplePausedAt
    }

    /// The current trim window in source seconds (`trimEndMs == 0` ⇒ end of file). nil when no
    /// sample is loaded. The region editor draws its handles from this.
    func sampleWindowSeconds() -> (start: Double, end: Double)? {
        guard let f = sampleFile else { return nil }
        let sr = f.processingFormat.sampleRate
        guard sr > 0 else { return nil }
        let durSec = Double(f.length) / sr
        let start = min(max(0, Double(sampleEdit.trimStartMs) / 1000), durSec)
        let end = sampleEdit.trimEndMs > 0 ? min(Double(sampleEdit.trimEndMs) / 1000, durSec) : durSec
        return (start, max(start, end))
    }

    /// Schedule the trim window from `startSec` (clamped into the window), player stopped first.
    /// A zero-frame window is REFUSED — scheduling it is an uncatchable crash (spec §4).
    @discardableResult
    private func scheduleSampleWindow(from startSec: Double) -> Bool {
        guard built, let f = sampleFile, let player = samplePlayer,
              let w = sampleWindowSeconds() else { return false }
        let sr = f.processingFormat.sampleRate
        let from = min(max(startSec, w.start), w.end)
        let startFrame = min(AVAudioFramePosition((from * sr).rounded()), f.length)
        let endFrame = min(AVAudioFramePosition((w.end * sr).rounded()), f.length)
        let count = endFrame - startFrame
        guard count > 0 else {
            dlog("scheduleSampleWindow REFUSED: zero-frame window [\(w.start)–\(w.end)] from=\(from)")
            return false
        }
        player.stop()
        player.scheduleSegment(f, startingFrame: startFrame, frameCount: AVAudioFrameCount(count),
                               at: nil, completionHandler: nil)
        sampleSegmentStartSeconds = from
        samplePausedAt = from
        sampleScheduled = true
        return true
    }

    /// Tick duty: end the audition at the trim window's out-point. The player node does NOT stop
    /// itself when a segment runs dry (`isPlaying` stays true, rendering silence), so the render
    /// clock is the only truthful end signal. Also mirrors the playhead into `samplePausedAt`
    /// each pass, so the fallback read stays near-truth across a stall (positions freeze with
    /// the engine — never advanced by wall clock).
    private func checkSampleEndBoundary() {
        guard isPlayingSample else { return }
        let ph = samplePlayheadSeconds()
        // Slice pad one-shot: stop at the pad's out-point, then hand transport back to the trim
        // window (sliceEndSec cleared) — the editor's next play reschedules from the window start.
        if let end = sliceEndSec {
            samplePausedAt = min(ph, end)
            guard ph >= end - 0.01 else { return }
            samplePlayer?.stop()
            sampleScheduled = false
            sliceEndSec = nil
            samplePausedAt = sampleWindowSeconds()?.start ?? 0
            isPlayingSample = false
            maybeResignArbiter()
            return
        }
        guard let w = sampleWindowSeconds() else { return }
        samplePausedAt = min(max(ph, w.start), w.end)
        guard ph >= w.end - 0.01 else { return }
        dlog("sample audition ended at \(String(format: "%.2f", ph))")
        samplePlayer?.stop()
        sampleScheduled = false
        samplePausedAt = w.start
        isPlayingSample = false
        maybeResignArbiter()
    }

    // MARK: - Loop audition

    /// Audition a rendered loop: decode the CAF FULLY to PCM, trim/pad to the loop's
    /// authoritative `frames` (ms-derived counts round differently per rate — a ±1-frame seam
    /// ticks audibly), then `scheduleBuffer(options: .loops)` on the dedicated loop player.
    /// The file is fully read before this returns, so `release` (a user-folder security scope)
    /// is dropped immediately after decode — nothing ever reads the file again.
    func playLoop(_ loop: StudioLoop, url: URL, release: (() -> Void)? = nil) {
        ensureEngine()
        guard built, let player = loopPlayer else { release?(); return }
        guard loop.frames > 0 else {
            release?()
            dlog("playLoop REFUSED \(loop.id): zero frames")   // zero-frame schedule = crash
            return
        }
        guard let decoded = try? StudioRender.decodeFileSync(url: url) else {
            release?()
            dlog("playLoop: unreadable \(url.lastPathComponent)")
            return
        }
        release?()   // fully decoded — the scope can drop NOW
        guard let buf = StudioAudio.trimmedOrPadded(decoded, to: loop.frames) else {
            dlog("playLoop: trim/pad failed \(loop.id)")
            return
        }
        clearInterruptionPark()
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        loopBuffer = buf
        loadedLoopId = loop.id
        if startEngineIfNeeded() { player.play() }
        isPlayingLoop = true
        NowPlayingArbiter.shared.claim(self)
        dlog("ui: playLoop \(loop.id) frames=\(loop.frames) run=\(engine.isRunning ? 1 : 0)")
        startTickIfNeeded()
    }

    /// Stop the loop audition (play/stop only — loops have no pause position).
    func stopLoop() {
        loopPlayer?.stop()
        if isPlayingLoop { dlog("ui: stopLoop") }
        isPlayingLoop = false
        loadedLoopId = nil
        loopBuffer = nil
        clearInterruptionPark()
        maybeResignArbiter()
    }

    // MARK: - Pattern playback (16-step sequencer)

    /// Load a pattern's rows onto the sequencer voices. `buffers` maps ROW INDEX → the row's
    /// pre-baked canonical PCM (rendered by StudioRender with the target's edits baked — the
    /// caller resolves/renders; rows whose target is gone simply have no buffer here and are
    /// skipped, never a throw). Rows beyond `maxPatternRows` are dropped with a log. Swaps only
    /// while stopped (a running pattern is stopped first) — the attach set is fixed, so this
    /// never touches the live graph.
    func loadPattern(_ pattern: StudioPattern, buffers: [Int: AVAudioPCMBuffer]) {
        ensureEngine()
        if isPlayingPattern { stopPattern() }
        let rows = Array(pattern.rows.prefix(Self.maxPatternRows))
        if pattern.rows.count > Self.maxPatternRows {
            dlog("loadPattern \(pattern.id): rows capped at \(Self.maxPatternRows) (had \(pattern.rows.count))")
        }
        patternSteps = rows.map(\.steps)
        patternBpm = pattern.bpm > 0 ? pattern.bpm : 120
        patternBuffers = [:]
        for (i, row) in rows.enumerated() {
            guard let buf = buffers[i] else { continue }             // missing target — skipped
            guard buf.frameLength > 0 else {                          // zero-frame schedule = crash
                dlog("loadPattern: row \(i) empty buffer skipped")
                continue
            }
            guard StudioAudio.isCanonical(buf.format) else {          // format-mismatched schedule raises
                dlog("loadPattern: row \(i) non-canonical buffer skipped (\(Int(buf.format.sampleRate))Hz/\(buf.format.channelCount)ch)")
                continue
            }
            patternBuffers[i] = buf
            if rowGains.indices.contains(i) {
                rowGains[i].outputVolume = StudioAudio.gainMultiplier(db: row.gainDb)
            }
        }
        loadedPatternId = pattern.id
        dlog("loadPattern \(pattern.id) bpm=\(patternBpm) rows=\(rows.count) sounding=\(patternBuffers.count)")
    }

    /// Any loaded row that would actually sound (has a buffer AND at least one on-step)?
    /// A pattern with zero sounding content REFUSES to play (spec §2 — the view shows the
    /// inline notice; the engine just declines, because an all-silent "run" would burn the
    /// tick + arbiter for nothing).
    var patternHasContent: Bool {
        patternBuffers.contains { row, _ in
            patternSteps.indices.contains(row) && patternSteps[row].contains(true)
        }
    }

    /// Start the loaded pattern from the top of the bar. Steps are scheduled sample-accurately
    /// on each row player's own timeline (all started at ONE shared host time, so their
    /// timelines coincide); the tick keeps a 1-bar horizon armed.
    func startPattern() {
        guard loadedPatternId != nil else { return }
        guard patternHasContent else {
            dlog("startPattern REFUSED: no sounding steps with buffers")
            return
        }
        ensureEngine()
        clearInterruptionPark()
        isPlayingPattern = true          // INTENT first — a failed start below is the watchdog's to fix
        NowPlayingArbiter.shared.claim(self)
        if startEngineIfNeeded() { restartPatternFromTop() }
        dlog("ui: startPattern run=\(engine.isRunning ? 1 : 0)")
        startTickIfNeeded()
    }

    /// Stop the pattern (rows keep their buffers — start replays from the top).
    func stopPattern() {
        for p in rowPlayers { p.stop() }
        if isPlayingPattern { dlog("ui: stopPattern") }
        isPlayingPattern = false
        patternClock.running = false
        clearInterruptionPark()
        maybeResignArbiter()
    }

    /// Live row-gain tweak while a pattern plays (mixer volume — no schedule impact).
    func setPatternRowGain(row: Int, gainDb: Double) {
        guard rowGains.indices.contains(row) else { return }
        rowGains[row].outputVolume = StudioAudio.gainMultiplier(db: gainDb)
    }

    /// (Re)anchor and start the pattern: schedule passes 0+1, start every used row player at one
    /// shared host time, and re-base the UI step clock. Also the RECOVERY restart — after an
    /// engine outage the host clock has drifted from the frozen player timelines, so unlike the
    /// sample/loop voices (pause()+play() re-prime) the only truthful pattern resume is from the
    /// top of a bar. Caller must ensure the engine is RUNNING (play(at:) on a dead engine traps).
    private func restartPatternFromTop() {
        guard built, engine.isRunning, patternHasContent else { return }
        for p in rowPlayers { p.stop() }   // stop() resets each player's sample timeline to 0
        armedThroughPass = 0
        armPass(0)
        armPass(1)
        armedThroughPass = 2
        let when = AVAudioTime(hostTime: mach_absolute_time()
            + AVAudioTime.hostTime(forSeconds: Self.patternStartLatency))
        for (row, _) in patternBuffers { rowPlayers[row].play(at: when) }
        patternClock.startedAtHost = CACurrentMediaTime() + Self.patternStartLatency
        patternClock.bpm = patternBpm
        patternClock.running = true
        dlog("pattern (re)start bpm=\(patternBpm) rows=\(patternBuffers.count)")
    }

    /// Schedule one 1-bar pass of steps. Times are on each row player's OWN timeline (sample
    /// time 0 = the shared start), `.interrupts` = the classic mono-choke: a retrigger cuts the
    /// ringing previous hit on that row (spec §4).
    private func armPass(_ pass: Int) {
        let sr = StudioAudio.canonicalSampleRate
        for (row, buf) in patternBuffers {
            guard patternSteps.indices.contains(row), rowPlayers.indices.contains(row) else { continue }
            let steps = patternSteps[row]
            let player = rowPlayers[row]
            for col in steps.indices where steps[col] {
                let at = Self.stepTime(anchor: AVAudioTime(sampleTime: 0, atRate: sr),
                                       index: pass * StudioPattern.stepCount + col,
                                       bpm: patternBpm, sampleRate: sr)
                player.scheduleBuffer(buf, at: at, options: .interrupts)
            }
        }
    }

    /// Tick duty: keep the schedule one full bar ahead of the audible pass (the 1-bar horizon).
    /// Host-clock based — the passes are armed a bar early, so millisecond host/render drift is
    /// irrelevant; the sample-accurate truth is the step times themselves.
    private func armPatternPassesIfNeeded() {
        guard isPlayingPattern, patternClock.running else { return }
        let stepF = Self.stepFrames(bpm: patternBpm, sampleRate: StudioAudio.canonicalSampleRate)
        let barSec = Double(stepF) * Double(StudioPattern.stepCount) / StudioAudio.canonicalSampleRate
        guard barSec > 0 else { return }
        let elapsed = CACurrentMediaTime() - patternClock.startedAtHost
        guard elapsed >= 0 else { return }
        let currentPass = Int(elapsed / barSec)
        while armedThroughPass <= currentPass + 1 {
            armPass(armedThroughPass)
            armedThroughPass += 1
        }
    }

    // MARK: - Arbiter

    /// Resign the system Now Playing claim once nothing is audible, so the Mix/standalone
    /// players can reclaim their card immediately (the NowPlayingArbiter contract: whoever last
    /// STARTED audio owns it; claim on play, resign when silent).
    private func maybeResignArbiter() {
        guard !anyIntentPlaying else { return }
        NowPlayingArbiter.shared.resign(self)
    }

    // MARK: - Tick (watchdog + end boundary + pattern horizon)

    private func startTickIfNeeded() {
        guard tickTask == nil else { return }
        lastTickAt = Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)   // ~10 Hz
                if Task.isCancelled { break }
                guard let self, self.tickFire() else { break }
            }
        }
    }

    /// One watchdog pass; returns false (→ stop ticking) when fully idle. Playheads here are
    /// READ from the render clock, never advanced by wall time — so the classic teleport hazard
    /// can't occur; the 0.5 s dt clamp survives as the suspension detector (a long gap means the
    /// app slept or the engine stalled, worth a diagnostic line).
    private func tickFire() -> Bool {
        let now = Date()
        let dt = min(lastTickAt.map { now.timeIntervalSince($0) } ?? 0, 0.5)
        if dt >= 0.5 { dlog("tick resumed after suspension/stall gap") }
        lastTickAt = now
        let rendering = built && engine.isRunning
        if lastRenderingDiag != rendering {
            dlog("render \(lastRenderingDiag.map(String.init) ?? "nil")→\(rendering)")
            lastRenderingDiag = rendering
        }
        diagHeartbeat(rendering: rendering)
        if rendering {
            if engineDownWhileLive {     // …re-prime: zombie nodes survive a bare play()
                engineDownWhileLive = false
                dlog("re-prime after engine comeback")
                resumeIntents()
            }
            healParkedPlayers()          // macOS device switch: engine renders on, nodes parked
            checkSampleEndBoundary()
            armPatternPassesIfNeeded()
        } else if anyIntentPlaying {
            // WATCHDOG: the system stopped the engine (route change / missed interruption-.ended
            // / config change) while something intends to play — bring it back (~1 try/s).
            engineDownWhileLive = true
            recoverFromEngineStop()
        }
        if !anyIntentPlaying { tickTask = nil; return false }
        return true
    }

    /// One studiodiag line per second while anything plays — the layer-by-layer liveness picture
    /// (engine vs node vs intent) that lets a silent field failure show exactly which layer died.
    private func diagHeartbeat(rendering: Bool) {
        let now = Date()
        guard lastDiagHeartbeat.map({ now.timeIntervalSince($0) >= 1 }) ?? true else { return }
        lastDiagHeartbeat = now
        let smpNode = (samplePlayer?.isPlaying ?? false) ? 1 : 0
        let loopNode = (loopPlayer?.isPlaying ?? false) ? 1 : 0
        let rowsOn = rowPlayers.filter(\.isPlaying).count
        dlog("hb render=\(rendering ? 1 : 0) run=\(engine.isRunning ? 1 : 0)"
             + " smp=(\(isPlayingSample ? 1 : 0),\(smpNode),\(String(format: "%.1f", samplePausedAt)))"
             + " loop=(\(isPlayingLoop ? 1 : 0),\(loopNode))"
             + " ptn=(\(isPlayingPattern ? 1 : 0),rows=\(rowsOn),pass=\(armedThroughPass),step=\(patternClock.currentStep ?? -1))"
             + " out=\(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate))Hz")
    }

    // MARK: - Recovery

    /// Bring a system-stopped engine back and resume what intent says should play. Called from
    /// the route/config-change observers and the tick watchdog; safe any time (no-ops when the
    /// engine runs or nothing wants audio). A failed start stays parked and the tick keeps
    /// retrying about once a second.
    private func recoverFromEngineStop() {
        guard built else { return }
        #if os(iOS)
        // Interruption-parked: intents were silenced by `.began` — restarting mid-interruption
        // is wrong (and `.ended` may never come; an explicit user play is the manual way out).
        guard !interruptionParked else {
            dlog("recover: interruption-parked — no restart")
            return
        }
        #endif
        // Engine survived (or auto-recovered — macOS does this on some device switches) but the
        // player nodes may have been parked by the reconfigure. Re-kick them.
        if engine.isRunning { healParkedPlayers(); return }
        guard anyIntentPlaying else { return }
        if let last = lastEngineRecoveryAttempt, Date().timeIntervalSince(last) < 0.9 { return }
        lastEngineRecoveryAttempt = Date()
        let ok = startEngineIfNeeded()
        dlog("recover: engine.start → \(ok ? "OK" : "FAILED")")
        guard ok else { return }
        resumeIntents()
        engineDownWhileLive = false      // re-primed here; the tick needn't do it again
    }

    /// Resume every duty whose INTENT is playing — the shared tail of engine recovery.
    ///
    /// RE-PRIME, don't just play: a node that was playing when the system stopped the engine can
    /// come back as a ZOMBIE — `isPlaying` true, schedule intact, rendering pure silence (the
    /// macOS AirPods 44.1↔48 kHz switch); a bare `play()` no-ops on it, `pause()+play()` revives
    /// it in place. The PATTERN is the exception: its host-anchored step horizon drifted during
    /// the outage, so it restarts from the top of a bar (see `restartPatternFromTop`).
    private func resumeIntents() {
        if isPlayingSample, let p = samplePlayer {
            if !sampleScheduled { _ = scheduleSampleWindow(from: samplePausedAt) }
            if p.isPlaying { p.pause() }
            p.play()
        }
        if isPlayingLoop, let p = loopPlayer {
            if p.isPlaying { p.pause() }
            p.play()
        }
        if isPlayingPattern { restartPatternFromTop() }
    }

    /// A macOS output-device switch can leave the ENGINE rendering while player nodes were
    /// silently parked by the reconfigure — everything looks alive, renders silence. Intent is
    /// the truth: re-kick any intent-playing voice whose node isn't actually playing. Safe every
    /// tick — a no-op in every legitimate state (every deliberate pause/stop clears intent first,
    /// and seek stops+replays inside one main-actor turn the tick can't interleave). Callers
    /// must ensure the engine is RUNNING.
    private func healParkedPlayers() {
        if isPlayingSample, let p = samplePlayer, !p.isPlaying {
            dlog("heal: re-kick sample player")
            p.play()
        }
        if isPlayingLoop, let p = loopPlayer, !p.isPlaying {
            dlog("heal: re-kick loop player")
            p.play()
        }
        if isPlayingPattern, patternClock.running,
           patternBuffers.keys.contains(where: { rowPlayers.indices.contains($0) && !rowPlayers[$0].isPlaying }) {
            dlog("heal: pattern row parked — restart from top")
            restartPatternFromTop()
        }
    }

    // MARK: - iOS session + observers

    #if os(iOS)
    private func activateAudioSession() {
        do {
            // Coexistence rule (spec §4): while the studio mic recorder holds `.playAndRecord`
            // for a live input tap, NO playback path may re-arm `.playback` — `setCategory` is
            // itself a route-changing operation and would tear the input route out from under
            // the tap mid-take. Playback still works fine under `.playAndRecord`.
            if !AudioSessionPolicy.micCaptureActive {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            }
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* non-fatal */ }
    }

    /// Interruption park/latch (the MixEngine doctrine):
    /// `.began` — the system already stopped the engine; remember EXACTLY what was audible
    /// (latched: `.began` can arrive twice over Bluetooth/CarPlay and must never erase the
    /// record) and silence the intents so the UI reads paused and the watchdog doesn't fight
    /// the interruption. `.ended` — resume only what `.began` itself parked, and only when iOS
    /// says `.shouldResume`; Apple documents `.ended` is NOT guaranteed, which is why an
    /// explicit user play also clears the park (`clearInterruptionPark`).
    private func registerInterruptionHandling() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.built,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    // LATCH (|=, never =): a duplicate .began over the already-parked engine
                    // must not erase the pairing record.
                    if self.isPlayingSample { self.parkedSample = true }
                    if self.isPlayingLoop { self.parkedLoop = true }
                    if self.isPlayingPattern { self.parkedPattern = true }
                    if self.parkedSample || self.parkedLoop || self.parkedPattern {
                        self.interruptionParked = true
                    }
                    if self.isPlayingSample { self.samplePausedAt = self.samplePlayheadSeconds() }
                    self.isPlayingSample = false
                    self.isPlayingLoop = false
                    self.isPlayingPattern = false
                    self.patternClock.running = false
                    self.maybeResignArbiter()
                    self.dlog("interruption BEGAN parked=(\(self.parkedSample ? 1 : 0),\(self.parkedLoop ? 1 : 0),\(self.parkedPattern ? 1 : 0))")
                case .ended:
                    let shouldResume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
                    self.dlog("interruption ENDED resume=\(shouldResume ? 1 : 0) parked=\(self.interruptionParked ? 1 : 0)")
                    guard shouldResume, self.interruptionParked else { return }
                    self.interruptionParked = false
                    // Resume ONLY what .began silenced — and only what is still loaded.
                    if self.parkedSample, self.sampleFile != nil { self.isPlayingSample = true }
                    if self.parkedLoop, self.loopBuffer != nil { self.isPlayingLoop = true }
                    if self.parkedPattern, self.patternHasContent { self.isPlayingPattern = true }
                    self.parkedSample = false; self.parkedLoop = false; self.parkedPattern = false
                    guard self.anyIntentPlaying else { return }
                    NowPlayingArbiter.shared.claim(self)
                    self.recoverFromEngineStop()
                    self.startTickIfNeeded()
                @unknown default:
                    break
                }
            }
        }
    }

    /// A route CHANGE (headphones ⇄ speaker ⇄ Bluetooth) can stop the engine WITHOUT any
    /// interruption — the original crash scenario. Recover immediately instead of waiting for
    /// the tick. `recoverFromEngineStop` no-ops when the engine kept running.
    private func registerRouteChangeHandling() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromEngineStop() }
        }
    }

    /// mediaserverd crashed: every node/engine/AVAudioFile in this process is orphaned and must
    /// be RECREATED (Apple's contract) — else `built` stays true forever and the tab is dead
    /// until relaunch.
    private func registerMediaResetHandling() {
        guard mediaResetObserver == nil else { return }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterMediaReset() }
        }
    }

    /// Rebuild the whole graph after a media-services reset. FILE IN-FLIGHT WORK FIRST is the
    /// doctrine — this engine has none (renders are offline in StudioRender, mic capture lives
    /// in StudioMicRecorder), so the ordering obligation is trivially met; then recreate the
    /// engine + graph + per-instance observer and reopen the sample file from its stored path.
    /// Everything comes back LOADED-BUT-STOPPED (MixEngine's "loaded-but-paused" policy):
    /// restarting audio after a daemon crash is the user's call.
    private func rebuildAfterMediaReset() {
        guard built else { return }
        dlog("MEDIA RESET: rebuilding studio graph")
        tickTask?.cancel(); tickTask = nil
        isPlayingSample = false
        isPlayingLoop = false
        isPlayingPattern = false
        patternClock.running = false
        interruptionParked = false
        parkedSample = false; parkedLoop = false; parkedPattern = false
        maybeResignArbiter()
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
        engine.stop()
        engine = AVAudioEngine()          // the orphaned graph is unusable — recreate everything
        built = false
        engineDownWhileLive = false
        sampleFile = nil
        sampleScheduled = false
        ensureEngine()                    // fresh graph; re-registers the config-change observer
        // Reopen the sample from its stored path — the old AVAudioFile is orphaned with the
        // daemon. Paused at the window start; the security scope (`sampleRelease`) is still held.
        if built, let path = samplePath, let player = samplePlayer, let mixer = sampleInputMixer,
           let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
            sampleFile = f
            engine.connect(player, to: mixer, format: f.processingFormat)
            samplePausedAt = sampleWindowSeconds()?.start ?? 0
        }
        // Loop/pattern buffers are plain process memory (they survive the daemon) and re-arm on
        // the fresh nodes the next time the user plays them.
    }
    #endif

    /// The system stopped + uninitialized the engine because its I/O configuration changed (the
    /// headphones→speaker sample-rate flip). All internal connections are pinned at canonical,
    /// so no re-wiring is needed — the failure mode is that NOBODY restarts the engine. Register
    /// against THIS engine instance; the media-reset rebuild re-registers on the new instance.
    private func registerConfigChangeHandling() {
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o) }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dlog("CONFIG CHANGE: run=\(self.engine.isRunning ? 1 : 0)"
                          + " out=\(Int(self.engine.outputNode.outputFormat(forBus: 0).sampleRate))Hz")
                // A config change means the engine WAS stopped/reconfigured — even if it already
                // restarted between ticks, playing nodes may be zombies.
                self.engineDownWhileLive = true
                self.recoverFromEngineStop()
            }
        }
    }

    /// Explicit user transport supersedes an interruption park: whatever the user just did IS
    /// the new truth, so the pairing record is wiped (a later stray `.ended` then resumes
    /// nothing). No-op outside iOS / outside a park.
    private func clearInterruptionPark() {
        #if os(iOS)
        interruptionParked = false
        parkedSample = false
        parkedLoop = false
        parkedPattern = false
        #endif
    }
}
