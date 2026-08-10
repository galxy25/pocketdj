import Foundation
import Observation
import AVFoundation       // AVAudioEngine + AVAudioUnitSampler; AVAudioSession is iOS-only (guarded)
import AudioToolbox       // kAUSampler_DefaultMelodicBankMSB / kAUSampler_DefaultBankLSB
import CoreMIDI           // wired/USB MIDI input (v1 scope: no network/BLE session creation)
import os                 // mixdiag Logger — recovery/take diagnostics ride the shared subsystem

// MARK: - Parsed MIDI voice message (pure, testable)

/// The two channel-voice messages the instrument cares about, decoded from a MIDI 1.0 UMP word.
enum MIDIVoice: Equatable {
    case noteOn(note: UInt8, velocity: UInt8)
    case noteOff(note: UInt8)
}

// MARK: - Realtime bridge (CoreMIDI thread ↔ sampler AU)

/// The receive-block's view of the engine. CoreMIDI delivers on ITS OWN thread and the reviewed
/// defect this design closes is per-note main-actor hops (jitter + reordering corrupt the event
/// log the score is quantized from — spec §4). So the block talks to the sampler DIRECTLY on the
/// CoreMIDI thread through this bridge: the AU enqueues MIDI events safely from any thread, and
/// `engineReady` (a plain aligned Bool — the MixTapPulse contract: a torn read costs at most one
/// note during a load, harmless) gates access so the 32 MB bank parse is never poked mid-load.
final class InstrumentRealtimeBridge: @unchecked Sendable {
    /// True only while a sound bank is fully loaded into a LIVE graph. Written on the main
    /// actor, read on the CoreMIDI thread before every sampler call.
    var engineReady = false
    /// The sampler node, reachable off-main by design (spec §4's "nonisolated(unsafe) sampler
    /// ref"). Set/cleared on the main actor around load/rebuild; only read under `engineReady`.
    var sampler: AVAudioUnitSampler?
}

// MARK: - Event log (NSLock-protected; owned by the recorder)

/// The take recorder's note-event log + the key-highlight mirror. Every producer — the CoreMIDI
/// receive block (its own thread) AND the on-screen keys (main actor) — funnels through here, so
/// takes sound and record identically regardless of input device (spec §4's shared path).
///
/// Threading: one `NSLock` around all mutable state. The MIDI thread does a short
/// lock-append-unlock per note (no allocation-heavy work, no actor hops); the UI reads
/// highlights via a COALESCED 30 Hz dirty-flag drain — never per-note publishing.
final class InstrumentEventLog: @unchecked Sendable {
    private let lock = NSLock()
    /// Recording gate — PRE-LATCHED by `startTake` before beat 1 exists in the future, so the
    /// MIDI thread only ever READS it; the beat-1 cutoff itself is the packet timestamp compared
    /// against `beat1Host` (host-time precise), never a main-actor timer flipping a flag late.
    private var armed = false
    /// Host time of beat 1 = end of count-in — the anchor `onMs`/`offMs` are measured from
    /// (spec §2/§4: the same anchor ScoreQuantizer and the MIDI export use).
    private var beat1Host: UInt64 = 0
    private var events: [StudioNoteEvent] = []
    /// Notes currently sounding within an armed take (note → onset). Completed into an event by
    /// the matching note-off; anything still open when the take stops is closed at the stop time.
    private var pending: [Int: (onMs: Int, velocity: Int)] = [:]
    /// Keys currently held (recording or not) — the key-highlight source.
    private var active: Set<Int> = []
    private var highlightsDirty = false

    // Always-on LIVE capture (spec §7 "one editable staff") — independent of the take `armed`
    // gate: every note is logged so a free-play staff fills as you play. Anchored at the FIRST
    // note (no count-in). Completed notes only (a held note appears on release), drained coalesced.
    private var liveEvents: [StudioNoteEvent] = []
    private var livePending: [Int: (onMs: Int, velocity: Int)] = [:]
    private var liveAnchor: UInt64?
    private var liveDirty = false

    /// Arm recording. Called BEFORE beat 1 (during the count-in): notes sound immediately but
    /// only packets stamped at/after `beat1HostTime` enter the log — a warm-up note during the
    /// count-in is heard, not recorded.
    func arm(beat1HostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        armed = true
        beat1Host = beat1HostTime
        events = []
        pending = [:]
    }

    /// Disarm + close every still-sounding note at `endHostTime`, returning the take's events
    /// sorted by onset (the order `StudioTake.events` persists and the quantizer expects).
    func disarmAndFinish(atHostTime endHostTime: UInt64) -> [StudioNoteEvent] {
        lock.lock(); defer { lock.unlock() }
        armed = false
        let endMs = msFromBeat1(endHostTime)
        for (note, p) in pending {
            events.append(StudioNoteEvent(onMs: p.onMs, offMs: max(p.onMs, endMs),
                                          note: note, velocity: p.velocity))
        }
        pending = [:]
        return events.sorted { $0.onMs < $1.onMs }
    }

    /// Record a note-on (any thread). Always feeds the highlight mirror; enters the log only
    /// when armed AND at/after beat 1. A re-trigger with no off (stuck/overlapping MIDI) closes
    /// the previous sounding at the new onset so events never overlap per note.
    func noteOn(note: Int, velocity: Int, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        active.insert(note)
        highlightsDirty = true
        guard armed else { return }
        let ms = msFromBeat1(hostTime)
        guard ms >= 0 else { return }          // count-in: audible, not recorded
        if let prev = pending.removeValue(forKey: note) {
            events.append(StudioNoteEvent(onMs: prev.onMs, offMs: max(prev.onMs, ms),
                                          note: note, velocity: prev.velocity))
        }
        pending[note] = (ms, velocity)
    }

    /// Record a note-off (any thread). An off with no armed onset (released after stop, or a
    /// note that STARTED during the count-in) only updates the highlight mirror.
    func noteOff(note: Int, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        active.remove(note)
        highlightsDirty = true
        guard armed, let p = pending.removeValue(forKey: note) else { return }
        let ms = max(p.onMs, msFromBeat1(hostTime))
        events.append(StudioNoteEvent(onMs: p.onMs, offMs: ms, note: note, velocity: p.velocity))
    }

    /// The 30 Hz coalesced drain: the current held-key set iff it changed since the last drain,
    /// else nil (the pump publishes nothing — zero main-actor churn while idle).
    func drainHighlightsIfDirty() -> Set<Int>? {
        lock.lock(); defer { lock.unlock() }
        guard highlightsDirty else { return nil }
        highlightsDirty = false
        return active
    }

    /// Events recorded so far (diagnostics/heartbeat only).
    var recordedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count + pending.count
    }

    /// Live note-on (any thread) — ALWAYS captured, independent of the take `armed` gate AND of
    /// whether the sampler made a sound (the caller invokes this BEFORE the audible-only guard, so
    /// a free-play staff fills even with no instrument loaded). Anchored at the first note; a
    /// re-trigger with no off closes the prior sounding at the new onset.
    func liveOn(note: Int, velocity: Int, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if liveAnchor == nil { liveAnchor = hostTime }
        let ms = max(0, msFrom(liveAnchor!, hostTime))
        if let prev = livePending.removeValue(forKey: note) {
            liveEvents.append(StudioNoteEvent(onMs: prev.onMs, offMs: max(prev.onMs, ms),
                                              note: note, velocity: prev.velocity))
        }
        livePending[note] = (ms, velocity)
        liveDirty = true
    }

    /// Live note-off — closes the note into the live stream (completed events only).
    func liveOff(note: Int, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let lp = livePending.removeValue(forKey: note), let anchor = liveAnchor else { return }
        liveEvents.append(StudioNoteEvent(onMs: lp.onMs, offMs: max(lp.onMs, msFrom(anchor, hostTime)),
                                          note: note, velocity: lp.velocity))
        liveDirty = true
    }

    /// Coalesced drain of the LIVE (free-play) stream — completed notes, onset-sorted, iff it
    /// changed since the last drain. nil when unchanged (the pump publishes nothing while idle).
    func snapshotLiveIfDirty() -> [StudioNoteEvent]? {
        lock.lock(); defer { lock.unlock() }
        guard liveDirty else { return nil }
        liveDirty = false
        return liveEvents.sorted { $0.onMs < $1.onMs }
    }

    /// Replace the live stream (score editing on the live staff). Keeps the anchor + any held
    /// notes, so notes played AFTER an edit still land on the same time base.
    func setLive(_ newEvents: [StudioNoteEvent]) {
        lock.lock(); defer { lock.unlock() }
        liveEvents = newEvents
        liveDirty = true
    }

    /// Reset the live stream (new session / after "Save as take").
    func clearLive() {
        lock.lock(); defer { lock.unlock() }
        liveEvents = []
        livePending = [:]
        liveAnchor = nil
        liveDirty = true
    }

    /// ms from beat 1 for a packet host time — negative during the count-in. Both operands go
    /// through `AVAudioTime.seconds(forHostTime:)` (mach timebase) and subtract as Doubles so
    /// pre-beat-1 stamps can't underflow the UInt64 domain.
    private func msFromBeat1(_ hostTime: UInt64) -> Int {
        msFrom(beat1Host, hostTime)
    }

    /// ms between two host times (mach timebase), subtracted as Doubles so a stamp before the
    /// anchor can't underflow the UInt64 domain.
    private func msFrom(_ anchor: UInt64, _ hostTime: UInt64) -> Int {
        let sec = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: anchor)
        return Int((sec * 1000).rounded())
    }
}

// MARK: - Engine

/// The virtual-instrument engine (spec §4): `AVAudioUnitSampler → instrumentMix (permanent
/// flag-gated take tap) → mainMixer`, with the metronome click joining at `mainMixer`
/// DOWNSTREAM of the tap so it is never recorded into a take. Plays seven GM instruments out of
/// downloaded SoundFont banks (`InstrumentPackStore`), records takes (audio via a
/// `MixTapSink`-style realtime AAC writer into the app-managed takes root + a host-time-stamped
/// note-event log anchored at beat 1), and replays a take's events back through the sampler so
/// the score and the sound always agree (spec §7).
///
/// Hardening follows the MixEngine route-change contract: lazy idempotent `ensureEngine()`,
/// `startEngineIfNeeded()` before every `play(at:)`, intent flags separate from node state, iOS
/// interruption/route-change/media-reset observers + a per-INSTANCE config-change observer
/// re-registered after rebuild, a ~10 Hz watchdog retrying `engine.start()` ~1/s, and MixDiag
/// diagnostics. One deliberate divergence, DAW-style: an engine outage MID-TAKE files the
/// partial take instead of resuming — resuming would splice desynced audio under intact events
/// (the tap's content clock freezes while host-time marches on), which silently corrupts the
/// artifact the score is built from. "File in-flight work FIRST" is the doctrine either way.
@MainActor
@Observable
final class InstrumentEngine {

    // MARK: Published state (the Instruments tab renders off these)

    /// Engine graph built + started at least once (false on headless CI — silent degraded tab).
    private(set) var isReady = false
    /// A sound bank is parsing (32 MB — runs OFF the main actor; the keys UI shows a spinner
    /// and the realtime bridge is gated closed for the duration).
    private(set) var isLoadingInstrument = false
    /// The instrument currently loaded into the sampler (nil until the first successful load).
    private(set) var currentInstrument: InstrumentKey?
    /// A take session is live (INTENT — includes the count-in; survives transient engine state).
    private(set) var isRecordingTake = false
    /// Inside the count-in bar (click audible, events/audio not yet recorded).
    private(set) var isCountingIn = false
    /// A recorded take's events are being replayed through the sampler.
    private(set) var isReplaying = false
    /// Currently-held keys (MIDI + on-screen), coalesced at ~30 Hz — the ONLY note-driven UI
    /// state, and it's pump-published, never per-note (spec §4's threading rule).
    private(set) var pressedNotes: Set<Int> = []
    /// The always-on LIVE (free-play) note stream, coalesced at ~30 Hz — the live editable staff
    /// renders this. Completed notes only; edits round-trip through `setLiveEvents`.
    private(set) var liveEvents: [StudioNoteEvent] = []
    /// Display names of connected wired/USB MIDI sources (refreshed on CoreMIDI setup changes).
    private(set) var midiSourceNames: [String] = []
    /// The in-flight take's file name — `StudioStore.activeTakeFileName` wires to this so
    /// delete-all can never sweep the file the writer holds open (spec §3).
    private(set) var activeTakeFileName: String?

    /// Everything the VIEW needs to file a finished take via `StudioStore.addTake` (spec §4:
    /// the engine records, the store persists — the view is the seam between them).
    struct TakeResult {
        let takeId: String
        let fileName: String
        let durationMs: Int
        let events: [StudioNoteEvent]
        let bpm: Double
        let instrument: InstrumentKey
    }

    /// Fired when the engine had to end a take ITSELF (engine outage, interruption, media reset,
    /// writer death) — wired by the app to file the partial through `StudioStore.addTake`, the
    /// MixRecorder auto-file doctrine (a crash-adjacent take is data, never silently dropped).
    @ObservationIgnored var onTakeAutoStopped: ((TakeResult) -> Void)?

    // MARK: Internals (all @ObservationIgnored — none of this drives SwiftUI directly)

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var built = false
    @ObservationIgnored private var sampler: AVAudioUnitSampler?
    /// The tap host: sampler output, UPSTREAM of the click join, so takes never contain the
    /// metronome (spec §4's tap placement — closes a reviewed defect).
    @ObservationIgnored private var instrumentMix: AVAudioMixerNode?
    @ObservationIgnored private var clickPlayer: AVAudioPlayerNode?
    /// The realtime AAC take writer — the SAME sink type as the Mix recording tap (fragmented
    /// m4a, deep-copy off the render thread, latched permanent failure). Installed ONCE per
    /// graph build and gated by begin/end flags, never by tap install/removal (which would
    /// reconfigure the live graph).
    @ObservationIgnored private let takeSink = MixTapSink()
    @ObservationIgnored private let rt = InstrumentRealtimeBridge()
    @ObservationIgnored private let eventLog = InstrumentEventLog()
    /// The bank behind `currentInstrument` — the media-reset rebuild reloads from this path
    /// (the AU's loaded preset is orphaned with the daemon, exactly like open AVAudioFiles).
    @ObservationIgnored private var loadedBankURL: URL?

    // Take session (intent + anchors).
    @ObservationIgnored private var takeId = ""
    @ObservationIgnored private var takeURL: URL?
    @ObservationIgnored private var takeBpm: Double = 120
    @ObservationIgnored private var takeClickEnabled = false
    @ObservationIgnored private var takeInstrument: InstrumentKey?
    /// Host time of beat 1 (end of count-in) — the click realign + event log anchor.
    @ObservationIgnored private var takeBeat1Host: UInt64 = 0
    /// The bar-loop click buffer for the take's BPM (kept for realign after recovery).
    @ObservationIgnored private var clickBuffer: AVAudioPCMBuffer?
    /// Invalidates the count-in's deferred writer-begin task when the take ends first.
    @ObservationIgnored private var takeGeneration = 0

    // Replay session.
    @ObservationIgnored private var replayGeneration = 0
    @ObservationIgnored private var replayActiveNotes: Set<Int> = []
    /// Host-clock anchor of the running replay's beat 1 (nil = not replaying), and where the LAST
    /// replay was parked when it stopped. Deliberately `@ObservationIgnored`: the score's playhead
    /// polls this from a `TimelineView` tick, and observable per-tick state would re-run the score
    /// body — quantize + paginate — ten times a second.
    @ObservationIgnored private var replayAnchor: ContinuousClock.Instant?
    @ObservationIgnored private var replayFrozenMs: Int?
    /// WHOSE take the replay clock currently describes — live or frozen. There is exactly ONE
    /// replay clock in this engine, so without an owner a position parked by replaying take A is
    /// indistinguishable from take B's, and B's score would both SHOW it and (fatally, now that
    /// cursors persist) WRITE it into B's remembered position. Set together with `replayFrozenMs`
    /// / `replayAnchor`; nil whenever the clock is nil. `@ObservationIgnored` for the same reason
    /// the anchor is: it is read from a `TimelineView` tick.
    @ObservationIgnored private var replayOwner: String?

    // Watchdog + recovery (the MixEngine tickFire shape).
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var lastTickAt: Date?
    @ObservationIgnored private var lastEngineRecoveryAttempt: Date?
    /// The engine was seen down (or reconfigured) while something was live — the next rendering
    /// tick re-primes (a zombie click node survives a bare `play()`; see `realignClick`).
    @ObservationIgnored private var engineDownWhileLive = false
    @ObservationIgnored private var lastDiagHeartbeat: Date?

    #if os(iOS)
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaResetObserver: NSObjectProtocol?
    /// Interruption `.began` actually parked live audio — LATCHED (never assigned false by a
    /// duplicate `.began`, which Bluetooth/CarPlay re-send) so `.ended` resumes only what the
    /// interruption itself silenced (the MixEngine pairing-record lesson).
    @ObservationIgnored private var interruptionParked = false
    #endif
    /// Per-ENGINE-INSTANCE `.AVAudioEngineConfigurationChange` observer — must be re-registered
    /// after a media-reset rebuild because the notification's object is the (new) engine.
    @ObservationIgnored private var configChangeObserver: NSObjectProtocol?

    // CoreMIDI (independent of the audio engine — survives media-reset rebuilds).
    @ObservationIgnored private var midiClient = MIDIClientRef()
    @ObservationIgnored private var midiPort = MIDIPortRef()

    /// Same diagnostics pipe as MixEngine: os_log always (subsystem com.levi.pocketdj /
    /// category mixdiag), plus the Settings ▸ Debug capture buffer while a session runs.
    @ObservationIgnored private static let diag = Logger(subsystem: "com.levi.pocketdj",
                                                         category: "mixdiag")
    private func dlog(_ s: String) {
        Self.diag.info("\(s, privacy: .public)")
        MixDiag.shared.append(s)
    }

    /// Everything downstream of the sampler is pinned at canonical 44.1 kHz stereo for life —
    /// the MixEngine format-pinning doctrine (a live AU seeing a format reconfig asserts).
    nonisolated static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100,
                                                           channels: 2)!
    /// Headroom between "now" and the click's `play(at:)` anchor so the start time is always
    /// schedulable (a past anchor starts immediately and skews the count-in).
    nonisolated static let clickStartLead: Double = 0.25

    // MARK: - Lifecycle

    /// Build the graph ON FIRST USE and start the engine. Idempotent; soft-fails on a headless
    /// host (no audio device) leaving `isReady` false — a degraded silent tab, never a crash.
    func ensureEngine() {
        guard !built else { return }
        // The coalesced drain publishes highlights + the live staff — both audio-INDEPENDENT, so it
        // must run even if `engine.start()` below fails (no audio device). Idempotent.
        startHighlightPump()
        #if os(iOS)
        activateAudioSession()
        registerInterruptionHandling()
        registerRouteChangeHandling()
        registerMediaResetHandling()
        #endif
        let canonical = Self.canonicalFormat
        let smp = AVAudioUnitSampler()
        let mix = AVAudioMixerNode()
        let click = AVAudioPlayerNode()
        engine.attach(smp)
        engine.attach(mix)
        engine.attach(click)
        // sampler → instrumentMix → mainMixer, all canonical. The take tap lives on
        // instrumentMix; the click joins at mainMixer DOWNSTREAM of it (never recorded).
        engine.connect(smp, to: mix, format: canonical)
        engine.connect(mix, to: engine.mainMixerNode, format: canonical)
        engine.connect(click, to: engine.mainMixerNode, format: canonical)
        engine.prepare()
        do { try engine.start() } catch {
            dlog("instr: engine.start failed at build — degraded (no audio device?)")
            return
        }
        built = true
        isReady = true
        sampler = smp
        instrumentMix = mix
        clickPlayer = click
        // The realtime bridge sees the sampler now, but stays CLOSED until a bank is loaded —
        // startNote against an empty/parsing sampler is at best silence, at worst a mid-parse poke.
        rt.sampler = smp
        rt.engineReady = false
        // Permanent take tap — installed ONCE here, gated by MixTapSink.begin/end flags.
        // Installing/removing taps mid-playback reconfigures the live graph (pauses nodes
        // on-device) — the MixEngine recording-tap lesson.
        let sink = takeSink
        mix.installTap(onBus: 0, bufferSize: 4096, format: mix.outputFormat(forBus: 0)) { buffer, _ in
            sink.write(buffer)   // one flag check while idle; deep-copy + async encode while recording
        }
        // Writer death (disk full) → auto-stop + FILE the partial take (fragments to this point
        // are durable). One-shot per take; the sink re-arms on the next begin.
        takeSink.onWriterFailure = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecordingTake else { return }
                self.autoStopTake(reason: "writer failure")
            }
        }
        registerConfigChangeHandling()
        setupMIDIIfNeeded()
        startWatchdog()
        dlog("instr: engine built + started")
    }

    func prepare() { ensureEngine() }

    /// Tear down (tests / deliberate shutdown — the app-scoped instance lives forever).
    func teardown() {
        if isRecordingTake { autoStopTake(reason: "teardown") }
        stopReplay()
        watchdogTask?.cancel(); watchdogTask = nil
        highlightTask?.cancel(); highlightTask = nil
        if built { engine.stop() }
        rt.engineReady = false
        #if os(iOS)
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o); interruptionObserver = nil }
        if let o = routeChangeObserver { NotificationCenter.default.removeObserver(o); routeChangeObserver = nil }
        if let o = mediaResetObserver { NotificationCenter.default.removeObserver(o); mediaResetObserver = nil }
        #endif
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
        if midiClient != 0 { MIDIClientDispose(midiClient); midiClient = 0; midiPort = 0 }
    }

    // TEST SEAMS — dead-engine transport tests (the route-change hardening contract). The
    // system stops the engine out from under the app; tests reproduce that state here.
    func stopEngineForTesting() { engine.stop() }
    var engineIsRunningForTesting: Bool { engine.isRunning }
    /// Drive the route/config-change observer path directly (tests can't post as the session).
    func simulateEngineRecoveryForTesting() { recoverFromEngineStop() }
    var clickNodeIsPlayingForTesting: Bool { clickPlayer?.isPlaying ?? false }

    /// Start the engine if it isn't running — REPORTING failure instead of swallowing it.
    /// Every path that makes a node `play(at:)` must check this first: play on a stopped engine
    /// raises an UNCATCHABLE ObjC exception (the shipped headphones→speaker crash).
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

    // MARK: - Instrument (SoundFont) loading

    /// Load a downloaded bank into the sampler for `key`. The 32 MB SoundFont parse runs OFF the
    /// main actor (a synchronous load froze the UI for seconds — the reviewed defect; spec §4),
    /// with `isLoadingInstrument` published for the spinner and the realtime bridge gated closed
    /// so the CoreMIDI thread can't poke the AU mid-parse. Returns success.
    @discardableResult
    func loadInstrument(_ key: InstrumentKey, bankURL: URL) async -> Bool {
        ensureEngine()
        guard built, sampler != nil else { return false }
        guard !isLoadingInstrument else { return false }   // one parse at a time
        guard !isRecordingTake else { return false }       // switching banks mid-take is nonsense
        isLoadingInstrument = true
        rt.engineReady = false
        let program = key.gmProgram
        // Background parse touching ONLY the sampler node, reached through the @unchecked-
        // Sendable bridge (the spec's nonisolated sampler ref). Safe: the AU loads presets from
        // any thread as long as nothing else talks to it — which the closed `engineReady`
        // gate guarantees for the parse's duration.
        let bridge = rt
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let smp = bridge.sampler else { cont.resume(returning: false); return }
                do {
                    try smp.loadSoundBankInstrument(
                        at: bankURL, program: program,
                        bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                        bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                    cont.resume(returning: true)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
        if ok {
            currentInstrument = key
            loadedBankURL = bankURL
            rt.engineReady = true
        }
        isLoadingInstrument = false
        dlog("instr: load \(key.rawValue) (program \(program)) → \(ok ? "OK" : "FAILED")")
        return ok
    }

    // MARK: - On-screen keys (main actor; same event-log path as MIDI — spec §4)

    /// Sound + log a key press from the UI keyboard. Shares the exact pipeline the CoreMIDI
    /// block uses (sampler + event log + highlight mirror) so a take records identically from
    /// either input.
    func noteOn(_ note: Int, velocity: Int = 96) {
        ensureEngine()
        #if os(iOS)
        interruptionParked = false     // an explicit key press is a user resume
        #endif
        _ = startEngineIfNeeded()      // wake a system-stopped engine before making sound
        let n = UInt8(clamping: max(0, min(127, note)))
        let v = UInt8(clamping: max(1, min(127, velocity)))
        // Live staff capture is UNCONDITIONAL (fills even with no instrument loaded) — before the
        // audible guard, and separate from the take log so it never desyncs a take's audio.
        eventLog.liveOn(note: Int(n), velocity: Int(v), hostTime: mach_absolute_time())
        guard rt.engineReady, let smp = sampler else { return }
        smp.startNote(n, withVelocity: v, onChannel: 0)
        eventLog.noteOn(note: Int(n), velocity: Int(v), hostTime: mach_absolute_time())
        NowPlayingArbiter.shared.claim(self)   // audible → own the card slot (no card written)
    }

    func noteOff(_ note: Int) {
        let n = UInt8(clamping: max(0, min(127, note)))
        eventLog.liveOff(note: Int(n), hostTime: mach_absolute_time())   // unconditional live close
        guard rt.engineReady, let smp = sampler else { return }
        smp.stopNote(n, onChannel: 0)
        eventLog.noteOff(note: Int(n), hostTime: mach_absolute_time())
    }

    // MARK: - Take recording (click + count-in; audio + events anchored at beat 1)

    /// Begin a take: (optionally) one bar of count-in click, then beat 1 — where the event log's
    /// clock starts AND the AAC writer begins, so audio, events, score, and MIDI export all share
    /// one anchor (spec §4/§7). The event gate is PRE-LATCHED here with the beat-1 host time; the
    /// CoreMIDI thread compares packet timestamps against it, so the count-in cutoff is
    /// host-time-precise, not a main-actor timer race. Returns false when the engine can't run
    /// or no instrument is loaded.
    @discardableResult
    func startTake(bpm: Double, click: Bool, countIn: Bool) -> Bool {
        ensureEngine()
        guard built, !isRecordingTake, !isLoadingInstrument,
              let instrument = currentInstrument, rt.engineReady else { return false }
        guard startEngineIfNeeded() else { return false }
        guard let dir = try? StudioFolders.appRoot(.takes) else { return false }   // ALWAYS app-managed (spec §3)

        let b: Double = (bpm.isFinite && bpm > 0) ? min(300, max(40, bpm)) : 120
        let id = StudioFactory.newTakeId()
        let fileName = StudioFolders.fileName(.takes, id: id)
        let url = dir.appendingPathComponent(fileName)

        // Anchor math in host time: click starts at `startSec` (small schedulable lead), beat 1
        // lands one count-in bar later. Everything else derives from `takeBeat1Host`.
        let nowSec = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let startSec = nowSec + Self.clickStartLead
        let countSec = countIn ? Self.barSeconds(bpm: b) : 0   // 1-bar count-in (spec §4)
        let beat1Sec = startSec + countSec
        takeBeat1Host = AVAudioTime.hostTime(forSeconds: beat1Sec)

        takeId = id
        takeURL = url
        takeBpm = b
        takeClickEnabled = click
        takeInstrument = instrument
        activeTakeFileName = fileName
        isRecordingTake = true
        isCountingIn = countSec > 0
        takeGeneration &+= 1
        let gen = takeGeneration

        // PRE-LATCH the recording gate (spec §4): armed now, cutoff enforced by timestamp.
        eventLog.arm(beat1HostTime: takeBeat1Host)

        if click {
            clickBuffer = Self.makeClickBarBuffer(bpm: b, format: Self.canonicalFormat)
            if let clickPlayer, let buf = clickBuffer {
                // Bar loop scheduled once with .loops and started at the count-in's first tick —
                // the metronome then free-runs phase-locked to the beat-1 anchor.
                clickPlayer.stop()
                clickPlayer.scheduleBuffer(buf, at: nil, options: [.loops])
                clickPlayer.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: startSec)))
            }
        }

        // The WRITER begins AT beat 1 (count-in bars are click-only — never in the take audio,
        // spec §4). Buffer-granularity slop (~90 ms tap buffers) is accepted by design; the
        // sample-precise truth is the event log. Generation-guarded: a stop/auto-stop during
        // the count-in cancels this arm.
        let sink = takeSink
        let fmt = Self.canonicalFormat
        Task { @MainActor [weak self] in
            let waitSec = max(0, beat1Sec - AVAudioTime.seconds(forHostTime: mach_absolute_time()))
            try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
            guard let self, self.takeGeneration == gen, self.isRecordingTake else { return }
            self.isCountingIn = false
            if !sink.begin(url: url, sampleRate: fmt.sampleRate, channels: fmt.channelCount) {
                self.autoStopTake(reason: "writer begin failed")
            }
        }
        NowPlayingArbiter.shared.claim(self)
        dlog("instr: take START \(id) bpm=\(Int(b)) click=\(click ? 1 : 0) countIn=\(countIn ? 1 : 0)")
        return true
    }

    /// End the take: close open notes at NOW, finalize the writer (fragments are durable even if
    /// finalize is interrupted), and hand back what the VIEW files via `StudioStore.addTake`.
    /// Stopping DURING the count-in is a cancel (nothing was recorded, no file was begun) → nil.
    func stopTake() -> TakeResult? {
        guard isRecordingTake else { return nil }
        takeGeneration &+= 1                    // cancels a pending count-in writer arm
        let wasCountingIn = isCountingIn
        isRecordingTake = false
        isCountingIn = false
        clickPlayer?.stop()
        clickBuffer = nil
        let events = eventLog.disarmAndFinish(atHostTime: mach_absolute_time())
        // Duration = the writer's CONTENT clock (media seconds actually appended), not wall
        // time — an engine stall mid-take must not inflate the take's length.
        let durationMs = Int((takeSink.appendedSeconds * 1000).rounded())
        takeSink.end()
        let fileName = activeTakeFileName ?? ""
        activeTakeFileName = nil
        takeURL = nil
        NowPlayingArbiter.shared.resign(self)
        if wasCountingIn {
            dlog("instr: take \(takeId) cancelled during count-in")
            return nil
        }
        dlog("instr: take STOP \(takeId) — \(durationMs) ms, \(events.count) events")
        return TakeResult(takeId: takeId, fileName: fileName, durationMs: durationMs,
                          events: events, bpm: takeBpm, instrument: takeInstrument ?? .piano)
    }

    /// The writer's content clock (seconds of take audio actually appended) — deliberately NOT
    /// observable; a recording HUD samples it from a TimelineView (fast clocks must never drive
    /// Observation invalidation — the dead play/pause-button lesson).
    var takeContentSeconds: Double { takeSink.appendedSeconds }

    /// Engine-initiated take end (outage/interruption/reset/writer death): stop, then FILE the
    /// partial via the wired callback — never silently dropped (MixRecorder doctrine).
    private func autoStopTake(reason: String) {
        dlog("instr: take auto-stop — \(reason)")
        if let result = stopTake() { onTakeAutoStopped?(result) }
    }

    // MARK: - Replay (score playback — events back through the sampler, spec §7)

    /// Replay a take's raw events through the sampler (the score view's ▶). A scheduling loop
    /// on the continuous clock is "sample-accurate enough" per spec; `replayGeneration` is the
    /// cancellation latch (bumped by `stopReplay`, a new replay, or recovery). The take's
    /// instrument should already be loaded — replay proceeds on whatever IS loaded (logged) so
    /// a missing bank degrades to the wrong timbre, never a dead button.
    ///
    /// `fromMs` starts the replay PART-WAY IN — the score's tap-to-seek, and Replay resuming from
    /// where the cursor was left. The action list is CHASED to that point (`replayActions(events:
    /// from:)`): notes already sounding there are struck at the seek instant, so what you hear
    /// matches the note the score paints as sounding. The clock anchor is back-dated by the same
    /// amount, so `replayPositionMs()` reports the seeked time immediately and the cursor lands
    /// where the tap did rather than snapping to 0 first.
    ///
    /// `forTake` names WHOSE clock this replay is, so another instrumental's open score neither
    /// shows nor persists this one's position (see `replayOwner`). nil = an anonymous replay, which
    /// no score screen will claim.
    func replayTake(events: [StudioNoteEvent], instrument: InstrumentKey, fromMs: Int = 0,
                    forTake takeId: String? = nil) {
        ensureEngine()
        guard built, rt.engineReady, !isLoadingInstrument, sampler != nil else { return }
        if let cur = currentInstrument, cur != instrument {
            dlog("instr: replay wants \(instrument.rawValue) but \(cur.rawValue) is loaded")
        }
        stopReplay()
        guard startEngineIfNeeded() else { return }
        // Clamp before any clock math: a seek derived from a wild layout must degrade, never trap.
        let from = max(0, min(fromMs, Self.maxReplayMs))
        let actions = Self.replayActions(events: events, from: from)
        guard !actions.isEmpty else {
            // Seeked past the last note: nothing left to play, so just park the cursor there (the
            // "last played" emphasis holds) instead of silently doing nothing.
            if from > 0 { parkReplayPosition(atMs: from, forTake: takeId) } else { replayOwner = takeId }
            return
        }
        replayOwner = takeId
        isReplaying = true
        NowPlayingArbiter.shared.claim(self)
        replayGeneration &+= 1
        let gen = replayGeneration
        dlog("instr: replay START — \(events.count) events\(from > 0 ? " from \(from) ms" : "")")
        // ONE anchor for both the scheduling loop's sleeps and the score's playhead, so the cursor
        // and the sampler can never disagree about where in the take we are. Back-dated by `from`,
        // which is what makes the loop's absolute `start + a.ms` sleeps stay correct after a seek.
        let start = ContinuousClock.now - .milliseconds(from)
        replayAnchor = start
        replayFrozenMs = from
        Task { @MainActor [weak self] in
            for a in actions {
                try? await Task.sleep(until: start + .milliseconds(a.ms), clock: .continuous)
                guard let self, self.replayGeneration == gen else { return }   // cancelled
                guard self.rt.engineReady, let smp = self.sampler else { continue }
                let n = UInt8(clamping: max(0, min(127, a.note)))
                if a.on {
                    smp.startNote(n, withVelocity: UInt8(clamping: max(1, min(127, a.velocity))),
                                  onChannel: 0)
                    self.replayActiveNotes.insert(a.note)
                    self.eventLog.noteOn(note: a.note, velocity: a.velocity,
                                         hostTime: mach_absolute_time())   // highlights follow replay
                } else {
                    smp.stopNote(n, onChannel: 0)
                    self.replayActiveNotes.remove(a.note)
                    self.eventLog.noteOff(note: a.note, hostTime: mach_absolute_time())
                }
            }
            guard let self, self.replayGeneration == gen else { return }
            self.isReplaying = false
            self.replayActiveNotes = []
            self.freezeReplayPosition()
            NowPlayingArbiter.shared.resign(self)
            self.dlog("instr: replay END")
        }
    }

    /// Cancel a replay: bump the generation (the loop exits at its next wake) and silence
    /// anything still sounding NOW (per-note stops + CC 123 all-notes-off belt-and-braces).
    func stopReplay() {
        replayGeneration &+= 1
        guard isReplaying else { return }
        isReplaying = false
        freezeReplayPosition()
        if rt.engineReady, let smp = sampler {
            for n in replayActiveNotes {
                smp.stopNote(UInt8(clamping: max(0, min(127, n))), onChannel: 0)
                eventLog.noteOff(note: n, hostTime: mach_absolute_time())
            }
            smp.sendController(123, withValue: 0, onChannel: 0)
        }
        replayActiveNotes = []
        NowPlayingArbiter.shared.resign(self)
    }

    // MARK: Replay position (the saved instrumental's score cursor)

    /// Ceiling for any externally supplied replay time (24 h — far past any instrumental). Every
    /// seek/park clamps to it BEFORE the clock math (the StaffChordView `Int.min` lesson).
    nonisolated static let maxReplayMs = 86_400_000

    /// Milliseconds since the replay's beat 1 — LIVE while replaying, else FROZEN where the last
    /// replay stopped or ended. nil = nothing has been replayed yet, which the score reads as
    /// "nothing played": cursor at the start, no highlight.
    ///
    /// A METHOD over `@ObservationIgnored` storage on purpose (see `replayAnchor`): the score's
    /// playhead calls it from a `TimelineView` tick.
    func replayPositionMs() -> Int? {
        guard let anchor = replayAnchor else { return replayFrozenMs }
        let c = (ContinuousClock.now - anchor).components
        let secs = Double(c.seconds) + Double(c.attoseconds) / 1e18
        // Clamp BEFORE the Int conversion — a wild clock delta must degrade, never trap (the
        // StaffChordView Int.min lesson). 24 h is far past any instrumental.
        guard secs.isFinite else { return replayFrozenMs }
        return Int((min(max(secs, 0), 86_400) * 1000).rounded())
    }

    /// The replay clock read THROUGH its owner: the position only when the clock describes THIS
    /// take, nil otherwise. The score screen reads this rather than the bare `replayPositionMs()`,
    /// so one instrumental's replay can neither animate nor persist itself onto another's score.
    func replayPositionMs(forTake takeId: String) -> Int? {
        guard replayOwner == takeId else { return nil }
        return replayPositionMs()
    }

    /// Does the engine's one replay clock (live or frozen) belong to this take? The gate on every
    /// WRITE the score screen makes: remembering a cursor, stopping "its" replay, clearing it.
    func replayClockBelongs(to takeId: String) -> Bool { replayOwner == takeId }

    /// Park the replay cursor where it stands. The score then keeps showing the LAST note that
    /// sounded (the "current playing OR last played" contract) instead of snapping back to neutral.
    private func freezeReplayPosition() {
        replayFrozenMs = replayPositionMs()
        replayAnchor = nil
    }

    /// Park the replay cursor at an explicit score-clock ms — a tap-to-seek while stopped, or the
    /// per-take position restored when a score opens (`StudioStore.scoreCursorMs`). `nil` parks
    /// NOTHING, i.e. "nothing played": cursor at the start, no highlight.
    ///
    /// Never disturbs a LIVE replay: while one is running the cursor belongs to the sampler's own
    /// anchor, and a restore/seek must go through `replayTake(fromMs:)` so sound and cursor move
    /// together.
    /// `forTake` claims the clock for that take (nil ms parks NOTHING, so the clock has no owner).
    /// A park is refused mid-replay, so it can never steal the running take's clock.
    func parkReplayPosition(atMs ms: Int?, forTake takeId: String? = nil) {
        guard replayAnchor == nil else { return }
        replayFrozenMs = ms.map { max(0, min($0, Self.maxReplayMs)) }
        replayOwner = replayFrozenMs == nil ? nil : takeId
    }

    /// Forget a PARKED cursor so the next score opens showing "nothing played". Scoped to the
    /// OWNER: a screen may only clear the clock it put there, never one another instrumental's
    /// replay is using. Never disturbs a LIVE replay (open the score mid-replay and the cursor
    /// keeps running).
    func resetReplayPosition(forTake takeId: String) {
        guard replayOwner == takeId else { return }
        parkReplayPosition(atMs: nil)
    }

    /// Flatten note events into a time-ordered on/off action list. Offs sort BEFORE ons at the
    /// same instant so a retriggered note (off/on at one timestamp) re-strikes instead of being
    /// swallowed. Pure + testable.
    nonisolated static func replayActions(events: [StudioNoteEvent])
        -> [(ms: Int, on: Bool, note: Int, velocity: Int)] {
        var actions: [(ms: Int, on: Bool, note: Int, velocity: Int)] = []
        for e in events {
            let on = max(0, e.onMs)
            actions.append((on, true, e.note, e.velocity))
            actions.append((max(on, e.offMs), false, e.note, e.velocity))
        }
        return actions.sorted(by: actionOrder)
    }

    /// The action list for a replay that STARTS at `from` — a tap-to-seek, or Replay resuming from
    /// the parked cursor.
    ///
    /// Everything before the seek point is dropped, EXCEPT that a note which started earlier and is
    /// still sounding at `from` is struck AT `from` (MIDI "chase"). Without the chase the score
    /// paints that note as the current, SOUNDING note — the state playing there naturally would be
    /// in — over silence, and then sends it a note-off it was never given a note-on for. Pure +
    /// testable; `InstrumentTests.testASeekChasesNotesAlreadySounding` pins both halves.
    nonisolated static func replayActions(events: [StudioNoteEvent], from: Int)
        -> [(ms: Int, on: Bool, note: Int, velocity: Int)] {
        guard from > 0 else { return replayActions(events: events) }
        var actions = replayActions(events: events).filter { $0.ms >= from }
        for e in events where max(0, e.onMs) < from && max(max(0, e.onMs), e.offMs) > from {
            actions.append((from, true, e.note, e.velocity))
        }
        return actions.sorted(by: actionOrder)
    }

    /// Time order, with offs BEFORE ons at the same instant so a retriggered note (off/on at one
    /// timestamp) re-strikes instead of being swallowed. One comparator, both builders.
    private nonisolated static func actionOrder(_ a: (ms: Int, on: Bool, note: Int, velocity: Int),
                                                _ b: (ms: Int, on: Bool, note: Int, velocity: Int))
        -> Bool {
        if a.ms != b.ms { return a.ms < b.ms }
        return !a.on && b.on
    }

    // MARK: - Click synthesis + timing math (nonisolated pure — unit-testable)

    /// One 4/4 bar in seconds at `bpm` (guarding non-positive input like `StudioPattern.barMs`).
    nonisolated static func barSeconds(bpm: Double) -> Double {
        let b = (bpm.isFinite && bpm > 0) ? bpm : 120
        return 240.0 / b
    }

    /// The next bar boundary at/after `nowSec + lead`, measured on the beat-1 grid — where a
    /// healed/re-primed click restarts so the metronome stays phase-locked to the take's anchor
    /// (a bare `pause()+play()` would resume with the parked gap folded into the bar phase).
    /// Works during the count-in too (boundaries before beat 1 are just negative bar indices).
    nonisolated static func nextBarAnchor(nowSec: Double, beat1Sec: Double, barSec: Double,
                                          lead: Double = 0.05) -> Double {
        guard barSec > 0 else { return nowSec + lead }
        let n = ceil((nowSec + lead - beat1Sec) / barSec)
        return beat1Sec + n * barSec
    }

    /// Synthesize ONE bar of metronome at `bpm`: four short decaying sine ticks — beat 1 at a
    /// higher pitch (the bar tick) than beats 2–4 (spec §4's two pitches). Scheduled with
    /// `.loops`, so the buffer length IS the bar length (rounding drift ≈ ½ frame/bar — inaudible
    /// over any take). Buffer memory is zeroed explicitly (AVAudioPCMBuffer doesn't guarantee it).
    nonisolated static func makeClickBarBuffer(bpm: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let b = (bpm.isFinite && bpm > 0) ? min(300, max(40, bpm)) : 120
        let sr = format.sampleRate
        let beatFrames = Int((60.0 / b * sr).rounded())
        let total = beatFrames * 4
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(total)) else { return nil }
        buf.frameLength = AVAudioFrameCount(total)
        let channels = Int(format.channelCount)
        guard let data = buf.floatChannelData else { return nil }
        for ch in 0..<channels { memset(data[ch], 0, total * MemoryLayout<Float>.size) }
        let tickLen = min(beatFrames, Int(0.03 * sr))          // 30 ms tick
        for beat in 0..<4 {
            let freq = beat == 0 ? 1600.0 : 1000.0             // bar tick vs beat tick
            let start = beat * beatFrames
            for i in 0..<tickLen {
                let env = exp(-5.0 * Double(i) / Double(tickLen))   // fast exponential decay
                let v = Float(sin(2 * .pi * freq * Double(i) / sr) * env * 0.5)
                for ch in 0..<channels { data[ch][start + i] = v }
            }
        }
        return buf
    }

    /// Restart the click loop phase-locked to the take's beat-1 anchor (recovery/heal path).
    /// stop() + fresh schedule + play(at: next bar) is a STRONGER re-prime than pause()+play():
    /// it revives a zombie node AND restores bar phase, which no resume-in-place can.
    private func realignClick() {
        guard isRecordingTake, takeClickEnabled,
              let click = clickPlayer, let buf = clickBuffer else { return }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let beat1 = AVAudioTime.seconds(forHostTime: takeBeat1Host)
        let target = Self.nextBarAnchor(nowSec: now, beat1Sec: beat1,
                                        barSec: Self.barSeconds(bpm: takeBpm))
        click.stop()
        click.scheduleBuffer(buf, at: nil, options: [.loops])
        click.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: target)))
    }

    // MARK: - Watchdog (~10 Hz; the MixEngine tickFire shape)

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        lastTickAt = Date()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)   // ~10 Hz
                if Task.isCancelled { break }
                guard let self else { break }
                self.watchdogFire()
            }
        }
    }

    /// The safety net Apple's notifications don't guarantee (`.ended` may never arrive; macOS
    /// posts nothing): notice a system-stopped engine, file in-flight work, retry ~1/s.
    private func watchdogFire() {
        let now = Date()
        // dt clamp per the shared contract: a suspension must never be mistaken for elapsed
        // audible time by anything derived from tick deltas (heartbeat cadence here — the take
        // clock is the sink's CONTENT clock and the event clock is host-time, both immune).
        _ = min(lastTickAt.map { now.timeIntervalSince($0) } ?? 0, 0.5)
        lastTickAt = now
        guard built else { return }
        if engine.isRunning {
            if engineDownWhileLive {
                // Engine came back via ANY path (watchdog, observer, macOS itself) — re-prime:
                // nodes that lived through the stop can be zombies a bare play() no-ops on.
                engineDownWhileLive = false
                dlog("instr: re-prime after engine comeback")
                realignClick()
            }
            healParkedClick()   // macOS device switch: engine renders on, player node parked
        } else if isRecordingTake || isReplaying {
            engineDownWhileLive = true
            recoverFromEngineStop()
        } else {
            // Idle keys-ready state: keep the engine alive so a wired keystroke is never
            // silently dead — but never fight an interruption park (phone call).
            #if os(iOS)
            guard !interruptionParked else { return }
            #endif
            if lastEngineRecoveryAttempt.map({ now.timeIntervalSince($0) >= 0.9 }) ?? true {
                lastEngineRecoveryAttempt = now
                if startEngineIfNeeded() { dlog("instr: idle engine restarted") }
            }
        }
        diagHeartbeat()
    }

    /// One mixdiag line per second while anything is live — the liveness picture for a silent
    /// field failure (engine vs click node vs writer vs event flow).
    private func diagHeartbeat() {
        guard isRecordingTake || isReplaying else { return }
        let now = Date()
        guard lastDiagHeartbeat.map({ now.timeIntervalSince($0) >= 1 }) ?? true else { return }
        lastDiagHeartbeat = now
        dlog("instr hb run=\(engine.isRunning ? 1 : 0) rec=\(isRecordingTake ? 1 : 0)"
             + " countIn=\(isCountingIn ? 1 : 0) replay=\(isReplaying ? 1 : 0)"
             + " click=\((clickPlayer?.isPlaying ?? false) ? 1 : 0)"
             + " sink=\(String(format: "%.1f", takeSink.appendedSeconds))s"
             + " events=\(eventLog.recordedCount)")
    }

    /// The macOS device-switch case: engine renders while the reconfigure silently parked the
    /// click node — intent (`isRecordingTake && takeClickEnabled`) vs `node.isPlaying` is the
    /// truth. Realigns rather than blindly `play()`s so the bar phase survives.
    private func healParkedClick() {
        guard isRecordingTake, takeClickEnabled,
              let click = clickPlayer, !click.isPlaying else { return }
        dlog("instr: heal — realign parked click")
        realignClick()
    }

    /// Bring a system-stopped engine back. In-flight work is FILED FIRST (the doctrine): a take
    /// that lost its render path must not resume — audio missed a gap the host-time event clock
    /// didn't, and splicing them desyncs the artifact — so the partial is auto-filed instead.
    private func recoverFromEngineStop() {
        guard built else { return }
        if engine.isRunning { healParkedClick(); return }
        if isRecordingTake { autoStopTake(reason: "engine stopped") }
        if isReplaying { stopReplay() }
        #if os(iOS)
        guard !interruptionParked else {
            dlog("instr: recover — parked (interruption), waiting for .ended/user")
            return
        }
        #endif
        if let last = lastEngineRecoveryAttempt, Date().timeIntervalSince(last) < 0.9 { return }
        lastEngineRecoveryAttempt = Date()
        let ok = startEngineIfNeeded()
        dlog("instr: recover engine.start → \(ok ? "OK" : "FAILED")")
        if ok { engineDownWhileLive = false }
    }

    // MARK: - Session + observers (iOS) / per-instance config change (both platforms)

    #if os(iOS)
    private func activateAudioSession() {
        // Spec §4 session-coexistence rule: while StudioMicRecorder holds .playAndRecord for a
        // live take, no playback engine may downgrade the category — an instrument load mid-take
        // would tear down the input route under the mic tap.
        guard !AudioSessionPolicy.micCaptureActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* non-fatal — the watchdog keeps retrying start */ }
    }

    /// Interruption (call/Siri): `.began` may arrive TWICE (Bluetooth/CarPlay re-send) — the
    /// park is LATCHED, never assigned, so a duplicate can't erase the pairing record. In-flight
    /// take/replay are ended + filed immediately (see `recoverFromEngineStop`'s WHY). `.ended`
    /// is NOT guaranteed by Apple — the watchdog + user actions are the real resume paths.
    private func registerInterruptionHandling() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.built,
                      let info = note.userInfo,
                      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    if self.engine.isRunning || self.isRecordingTake || self.isReplaying {
                        self.interruptionParked = true   // LATCH
                    }
                    self.dlog("instr: interruption BEGAN (parked=\(self.interruptionParked ? 1 : 0))")
                    if self.isRecordingTake { self.autoStopTake(reason: "interruption") }
                    if self.isReplaying { self.stopReplay() }
                case .ended:
                    let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
                    self.dlog("instr: interruption ENDED resume=\(shouldResume ? 1 : 0)")
                    guard shouldResume, self.interruptionParked else { return }
                    self.interruptionParked = false
                    _ = self.startEngineIfNeeded()   // live keys come back; the filed take stays filed
                @unknown default:
                    break
                }
            }
        }
    }

    /// A route change (headphones ⇄ speaker ⇄ Bluetooth) can stop the engine WITHOUT any
    /// interruption — recover immediately instead of waiting up to a watchdog tick.
    private func registerRouteChangeHandling() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromEngineStop() }
        }
    }

    /// mediaserverd crashed: EVERY node/tap/engine in this process is orphaned (Apple's
    /// contract) — without a rebuild, `built` stays true forever and the tab is dead until
    /// relaunch.
    private func registerMediaResetHandling() {
        guard mediaResetObserver == nil else { return }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterMediaReset() }
        }
    }

    /// Rebuild after a media-services reset. FILE the in-flight take FIRST (the AAC writer is
    /// not CoreAudio-backed — it can still finalize its fragments), then recreate the engine +
    /// graph + per-instance observer, and RELOAD the sound bank from its stored path off-main
    /// (the AU's loaded preset died with the daemon — the "reopen files" step of the contract).
    private func rebuildAfterMediaReset() {
        guard built else { return }
        dlog("instr: MEDIA RESET — rebuilding")
        if isRecordingTake { autoStopTake(reason: "media services reset") }
        stopReplay()
        rt.engineReady = false
        rt.sampler = nil
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
        engine.stop()
        engine = AVAudioEngine()          // the orphaned graph is unusable — recreate everything
        built = false
        isReady = false
        sampler = nil
        instrumentMix = nil
        clickPlayer = nil
        ensureEngine()                    // fresh graph + tap + re-registered config observer
        if let key = currentInstrument, let url = loadedBankURL {
            Task { @MainActor [weak self] in
                _ = await self?.loadInstrument(key, bankURL: url)   // off-main reparse, spinner shown
            }
        }
    }
    #endif

    /// The system stopped + uninitialized the engine because its I/O configuration changed (the
    /// headphones→speaker sample-rate flip). Registered PER ENGINE INSTANCE (the notification's
    /// object is the engine) and re-registered after every rebuild.
    private func registerConfigChangeHandling() {
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o) }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dlog("instr: CONFIG CHANGE run=\(self.engine.isRunning ? 1 : 0)"
                          + " out=\(Int(self.engine.outputNode.outputFormat(forBus: 0).sampleRate))Hz")
                // The engine WAS stopped/reconfigured — even if already restarted between ticks,
                // a surviving click node may be a zombie; the next rendering tick re-primes.
                self.engineDownWhileLive = true
                self.recoverFromEngineStop()
            }
        }
    }

    // MARK: - CoreMIDI (wired/USB + on-screen keys ONLY — v1 scope, spec §4)

    /// Create the client + a MIDI-1.0-protocol input port and connect every source. Deliberately
    /// creates NO network session and touches NO Bluetooth (out of scope; new entitlements).
    /// The client outlives audio-engine rebuilds — MIDI is independent of the render graph.
    private func setupMIDIIfNeeded() {
        guard midiClient == 0 else { return }
        var client = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("PocketDJ Instruments" as CFString, &client) { [weak self] notice in
            // CoreMIDI's own thread. Setup changes are RARE (device plug/unplug) — one hop each,
            // never per-event.
            if notice.pointee.messageID == .msgSetupChanged {
                Task { @MainActor [weak self] in self?.connectAllMIDISources() }
            }
        }
        guard status == noErr else {
            dlog("instr: MIDIClientCreate failed (\(status))")
            return
        }
        midiClient = client
        // The receive block runs ON THE COREMIDI THREAD by design (spec §4, load-bearing): the
        // sampler is driven directly there via the realtime bridge, and events land in the
        // NSLock'd log. It captures ONLY the two @unchecked-Sendable bridges — no self, no
        // actor hops, no per-note Tasks (hop jitter reorders the event log the score quantizes).
        let log = eventLog
        let bridge = rt
        var port = MIDIPortRef()
        let ps = MIDIInputPortCreateWithProtocol(client, "PocketDJ Input" as CFString, ._1_0,
                                                 &port) { eventList, _ in
            InstrumentEngine.handleMIDIEventList(eventList, log: log, rt: bridge)
        }
        guard ps == noErr else {
            dlog("instr: MIDIInputPortCreate failed (\(ps))")
            return
        }
        midiPort = port
        connectAllMIDISources()
    }

    /// (Re)connect every present MIDI source — initial setup AND the setup-changed reconnect
    /// (plugging a keyboard in mid-session must just work). Disconnect-then-connect keeps the
    /// port single-subscribed per source across repeated setup notifications.
    private func connectAllMIDISources() {
        guard midiPort != 0 else { return }
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            MIDIPortDisconnectSource(midiPort, src)
            MIDIPortConnectSource(midiPort, src, nil)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr,
               let n = name?.takeRetainedValue() {
                names.append(n as String)
            }
        }
        midiSourceNames = names
        dlog("instr: MIDI sources (\(names.count)) connected")
    }

    /// CoreMIDI-thread packet handler (`nonisolated static` — it must never touch the actor).
    /// Sound first (the bridge), log second; per-note cost is a couple of comparisons + one
    /// short lock hold.
    nonisolated private static func handleMIDIEventList(_ listPtr: UnsafePointer<MIDIEventList>,
                                                        log: InstrumentEventLog,
                                                        rt: InstrumentRealtimeBridge) {
        for packetPtr in listPtr.unsafeSequence() {
            let stamp = packetPtr.pointee.timeStamp
            let host = stamp == 0 ? mach_absolute_time() : stamp   // 0 = "now" per CoreMIDI
            let wordCount = Int(packetPtr.pointee.wordCount)
            withUnsafePointer(to: packetPtr.pointee.words) { wordsPtr in
                wordsPtr.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                    for i in 0..<min(wordCount, 64) {
                        guard let msg = parseMIDI1Word(words[i]) else { continue }
                        switch msg {
                        case .noteOn(let note, let velocity):
                            log.liveOn(note: Int(note), velocity: Int(velocity), hostTime: host)
                            if rt.engineReady, let smp = rt.sampler {
                                smp.startNote(note, withVelocity: velocity, onChannel: 0)
                            }
                            log.noteOn(note: Int(note), velocity: Int(velocity), hostTime: host)
                        case .noteOff(let note):
                            log.liveOff(note: Int(note), hostTime: host)
                            if rt.engineReady, let smp = rt.sampler {
                                smp.stopNote(note, onChannel: 0)
                            }
                            log.noteOff(note: Int(note), hostTime: host)
                        }
                    }
                }
            }
        }
    }

    /// Decode one MIDI 1.0 Universal-MIDI-Packet word into the note messages the instrument
    /// handles. UMP message type 2 = MIDI 1.0 channel voice: status in bits 16–23, data bytes
    /// below. Note-on with velocity 0 is a note-off per the MIDI spec (running-status devices).
    /// Pure + testable.
    nonisolated static func parseMIDI1Word(_ word: UInt32) -> MIDIVoice? {
        guard (word >> 28) & 0xF == 0x2 else { return nil }
        let status = UInt8((word >> 16) & 0xFF)
        let d1 = UInt8((word >> 8) & 0x7F)
        let d2 = UInt8(word & 0x7F)
        switch status & 0xF0 {
        case 0x90: return d2 == 0 ? .noteOff(note: d1) : .noteOn(note: d1, velocity: d2)
        case 0x80: return .noteOff(note: d1)
        default:   return nil
        }
    }

    // MARK: - Key-highlight pump (~30 Hz coalesced — spec §4's dirty-flag publisher)

    /// Publishes `pressedNotes` at most ~30×/s and ONLY when the held-key set actually changed —
    /// the coalesced alternative to per-note main-actor hops. Idle cost is one lock/flag check.
    /// Commit an edited live stream (the live editable staff). Updates the published copy
    /// immediately and the log's source so notes played after an edit share the same time base.
    func setLiveEvents(_ events: [StudioNoteEvent]) {
        eventLog.setLive(events)
        liveEvents = events
    }

    /// Reset the live staff (after "Save as take", or a manual clear).
    func clearLiveEvents() {
        eventLog.clearLive()
        liveEvents = []
    }

    /// TEST SEAM: run one live-drain synchronously (the 30 Hz pump does this on a timer). Lets a
    /// unit test verify the noteOn/noteOff → liveEvents path without the async pump or a UI gesture.
    func pumpLiveOnceForTesting() {
        if let live = eventLog.snapshotLiveIfDirty() { liveEvents = live }
    }

    private func startHighlightPump() {
        guard highlightTask == nil else { return }
        highlightTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30 Hz
                guard let self else { break }
                if let notes = self.eventLog.drainHighlightsIfDirty() {
                    self.pressedNotes = notes
                }
                if let live = self.eventLog.snapshotLiveIfDirty() {
                    self.liveEvents = live
                }
            }
        }
    }
}
