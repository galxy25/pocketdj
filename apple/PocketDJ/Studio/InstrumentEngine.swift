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
    /// Overdub mode is armed — the CoreMIDI thread mirrors hand-played notes into the overdub
    /// capture stream. Same aligned-Bool contract as `engineReady` (a torn read costs one note).
    var overdubActive = false
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
    /// The live stream hit its note BUDGET and is refusing new onsets (see `liveOn`).
    private var liveFull = false

    /// Hard cap on the always-on live capture. A pair of hands never reaches it; a LATCHED ARP
    /// is a machine that strikes up to ~40 notes/second for as long as its transport runs, and an
    /// unbounded staff is re-quantized + re-paginated on every publish until the app hangs. The
    /// stream stops growing at the cap and says so (`liveCaptureFull`) instead.
    static let maxLiveEvents = 4_000

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
        // BUDGET (see `maxLiveEvents`): past the cap the stream refuses NEW onsets — notes already
        // sounding still close normally, so nothing dangles — and publishes that it is full.
        guard liveEvents.count < Self.maxLiveEvents else { liveFull = true; return }
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
        lock.lock()
        guard liveDirty else { lock.unlock(); return nil }
        liveDirty = false
        let snapshot = liveEvents          // O(1) COW handoff — the SORT happens unlocked, below
        lock.unlock()
        // Sorting inside the lock would make the MIDI thread wait on an O(n log n) main-actor
        // sort of a growing array, ~10 times a second, for its per-note append. It waits on a
        // retain instead.
        return snapshot.sorted { $0.onMs < $1.onMs }
    }

    /// The live capture is at its budget and refusing new notes (the UI says so; Save/Clear resets).
    var liveCaptureFull: Bool {
        lock.lock(); defer { lock.unlock() }
        return liveFull
    }

    /// Replace the live stream (score editing on the live staff). Keeps the anchor + any held
    /// notes, so notes played AFTER an edit still land on the same time base.
    func setLive(_ newEvents: [StudioNoteEvent]) {
        lock.lock(); defer { lock.unlock() }
        liveEvents = newEvents
        liveFull = newEvents.count >= Self.maxLiveEvents
        liveDirty = true
    }

    /// Reset the live stream (new session / after "Save as take").
    func clearLive() {
        lock.lock(); defer { lock.unlock() }
        liveEvents = []
        livePending = [:]
        liveAnchor = nil
        liveFull = false
        liveDirty = true
    }

    // MARK: Overdub capture (a THIRD stream — the take stream belongs to `startTake`, the live
    // stream is the always-on free-play staff; overdub is its own armed gate + its own anchor,
    // BASE-OFFSET by the score position the user chose, so captured events land ABSOLUTE on the
    // take's one score clock).

    private var odArmed = false
    private var odAnchorHost: UInt64 = 0
    private var odBaseMs = 0                       // the chosen score position P (caller-clamped)
    /// EXCLUSIVE end of the overdub REGION on the score clock — the score's end at arm time
    /// (req: an overdub can NEVER extend the score). `Int.max` = unbounded (legacy callers).
    private var odRegionEndMs = Int.max
    /// Looper mode over the confined region: strike positions WRAP (`base + elapsed % L`), every
    /// iteration LAYERS into the same capture, and a note held across the wrap closes AT the
    /// boundary — no onset ever hangs across iterations.
    private var odLoop = false
    private var odEvents: [StudioNoteEvent] = []
    /// note → (wrapped onset, velocity, iteration index) — iteration 0 always in non-loop mode.
    private var odPending: [Int: (onMs: Int, velocity: Int, iter: Int)] = [:]
    /// Completed-capture dirty flag: the pump publishes the IN-PROGRESS overdub staff from this
    /// (completed notes only — the live-staff precedent: a held note appears on release).
    private var odDirty = false

    /// Arm the overdub stream: notes from `anchorHostTime` onward capture at
    /// `baseMs + elapsed` — the caller anchors at the same instant the backing replay anchors
    /// its clock, so hand/arp notes land at the true score position.
    /// `regionEndMs` confines the capture to `[baseMs, regionEndMs)` on the score clock;
    /// `loop` wraps positions into that region looper-style (both default to the legacy
    /// unbounded single-pass behavior).
    func overdubArm(anchorHostTime: UInt64, baseMs: Int,
                    regionEndMs: Int = .max, loop: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        odArmed = true
        odAnchorHost = anchorHostTime
        odBaseMs = max(0, baseMs)
        odRegionEndMs = max(odBaseMs, regionEndMs)
        odLoop = loop && odRegionEndMs > odBaseMs && odRegionEndMs < .max
        odEvents = []
        odPending = [:]
        odDirty = false
    }

    /// Map raw elapsed-ms since the anchor to a position inside the region, or nil when the
    /// strike falls OUTSIDE it — pre-anchor stamps (the count-in convention) and, loop OFF,
    /// anything at/past the boundary (req: the pass stops accepting notes at the score's end).
    /// Loop ON never discards: positions wrap into the region with their iteration index.
    private func odPosition(elapsedMs e: Int) -> (ms: Int, iter: Int)? {
        guard e >= 0 else { return nil }
        if odLoop {
            let len = odRegionEndMs - odBaseMs
            return (odBaseMs + e % len, e / len)
        }
        let ms = odBaseMs + e
        guard ms < odRegionEndMs else { return nil }
        return (ms, 0)
    }

    /// Close a sounding overdub note at raw elapsed `e`: same iteration ⇒ its wrapped position,
    /// a LATER iteration ⇒ AT the region boundary (a held note never crosses the wrap); non-loop
    /// offs clamp to the boundary the same way (a note held past the score's end closes there).
    private func odCloseMs(pending pnd: (onMs: Int, velocity: Int, iter: Int), elapsedMs e: Int) -> Int {
        let off: Int
        if odLoop {
            let len = odRegionEndMs - odBaseMs
            off = (e >= 0 && e / len == pnd.iter) ? odBaseMs + e % len : odRegionEndMs
        } else {
            off = min(odBaseMs + max(0, e), odRegionEndMs)
        }
        return max(pnd.onMs, off)
    }

    /// Overdub note-on (any thread). Strikes OUTSIDE the region are dropped (`odPosition`);
    /// a re-trigger with no off closes the prior sounding at the new strike.
    func overdubOn(note: Int, velocity: Int, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard odArmed else { return }
        let e = msFrom(odAnchorHost, hostTime)
        guard let pos = odPosition(elapsedMs: e) else { return }
        if let prev = odPending.removeValue(forKey: note) {
            odEvents.append(StudioNoteEvent(onMs: prev.onMs, offMs: odCloseMs(pending: prev, elapsedMs: e),
                                            note: note, velocity: prev.velocity))
            odDirty = true
        }
        odPending[note] = (pos.ms, velocity, pos.iter)
    }

    /// Overdub note-off (any thread) — closes the sounding note into the capture (clamped/
    /// wrap-closed by `odCloseMs`).
    func overdubOff(note: Int, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard odArmed, let p = odPending.removeValue(forKey: note) else { return }
        odEvents.append(StudioNoteEvent(onMs: p.onMs,
                                        offMs: odCloseMs(pending: p, elapsedMs: msFrom(odAnchorHost, hostTime)),
                                        note: note, velocity: p.velocity))
        odDirty = true
    }

    /// Disarm + close every still-sounding note at `endHostTime`, returning the capture sorted
    /// by onset (absolute score-clock ms) — the clone of `disarmAndFinish` for the third stream.
    func overdubDisarmAndFinish(atHostTime endHostTime: UInt64) -> [StudioNoteEvent] {
        lock.lock(); defer { lock.unlock() }
        guard odArmed else { return [] }
        odArmed = false
        let e = msFrom(odAnchorHost, endHostTime)
        for (note, p) in odPending {
            odEvents.append(StudioNoteEvent(onMs: p.onMs, offMs: odCloseMs(pending: p, elapsedMs: e),
                                            note: note, velocity: p.velocity))
        }
        odPending = [:]
        let out = odEvents.sorted { $0.onMs < $1.onMs }
        odEvents = []
        odDirty = false
        return out
    }

    /// Coalesced drain of the ARMED pass's completed captures — the score UIs render the
    /// in-progress overdub staff from this (the staff fills DURING the pass, not only at End
    /// overdub). nil when unchanged since the last drain.
    func snapshotOverdubIfDirty() -> [StudioNoteEvent]? {
        lock.lock()
        guard odDirty else { lock.unlock(); return nil }
        odDirty = false
        let snapshot = odEvents            // O(1) COW handoff — the SORT happens unlocked, below
        lock.unlock()
        // Same rule as `snapshotLiveIfDirty`: a looping pass layers for as long as the user keeps
        // playing, and the realtime append must never queue behind a sort of the whole capture.
        return snapshot.sorted { $0.onMs < $1.onMs }
    }

    /// Has the CONFINED region run out? True only for an armed, NON-looping, bounded pass whose
    /// elapsed time has reached the region's end — the point where the pass stops accepting notes
    /// (`odPosition` already discards them) and the engine publishes the auto-finalize. A looping
    /// pass never exhausts: it wraps forever until the user ends it.
    func overdubRegionExhausted(atHostTime hostTime: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard odArmed, !odLoop, odRegionEndMs < .max else { return false }
        return odBaseMs + msFrom(odAnchorHost, hostTime) >= odRegionEndMs
    }

    /// Captured-so-far count for the ARMED overdub (completed + pending) — the engine's
    /// `overdubCapturedCount` reads this for the score screen's re-anchor rule.
    var overdubCount: Int {
        lock.lock(); defer { lock.unlock() }
        guard odArmed else { return 0 }
        return odEvents.count + odPending.count
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
    /// The metronome is ON — a take's click OR the free-play/overdub MONITORING click (req 7).
    /// Published so the toggle always shows what the graph is actually doing, and flippable LIVE
    /// through `setClickEnabled` mid-take or mid-overdub. The click node joins at `mainMixer`,
    /// DOWNSTREAM of the take tap, so it is monitoring-only: it can never reach a take's audio,
    /// an offline render, or a single score event.
    private(set) var clickEnabled = false
    /// A recorded take's events are being replayed through the sampler.
    private(set) var isReplaying = false
    /// Currently-held keys (MIDI + on-screen), coalesced at ~30 Hz — the ONLY note-driven UI
    /// state, and it's pump-published, never per-note (spec §4's threading rule).
    private(set) var pressedNotes: Set<Int> = []
    /// The always-on LIVE (free-play) note stream, coalesced at ~30 Hz — the live editable staff
    /// renders this. Completed notes only; edits round-trip through `setLiveEvents`.
    private(set) var liveEvents: [StudioNoteEvent] = []
    /// Does the live staff hold ANY notes? A cheap Bool the live-score SECTION reads instead of
    /// the event array, so a staff publish invalidates only the one view that renders the notes —
    /// not the overdub staffs, the in-progress capture and the footer around it.
    private(set) var liveHasEvents = false
    /// The live capture reached `InstrumentEventLog.maxLiveEvents` and is refusing new notes
    /// (a latched arp is a machine): surfaced in the live score's footer. Save/Clear resets it.
    private(set) var liveCaptureFull = false
    /// Display names of connected wired/USB MIDI sources (refreshed on CoreMIDI setup changes).
    private(set) var midiSourceNames: [String] = []
    /// The in-flight take's file name — `StudioStore.activeTakeFileName` wires to this so
    /// delete-all can never sweep the file the writer holds open (spec §3).
    private(set) var activeTakeFileName: String?

    // MARK: Arpeggiator state (deliberately OUTSIDE any #if os fence — the platform-fence lesson)

    /// Arp master switch. Turning it off pauses the transport + leaves program mode but KEEPS the
    /// selected set (off/on is non-destructive; `arpClearSelection` is the explicit reset).
    var arpEnabled = false {
        didSet {
            guard !arpEnabled, oldValue else { return }
            arpProgramming = false
            stopArpPlayback()
        }
    }
    /// PROGRAM mode (the panel's "Program" button — named for what it does: it programs the
    /// pattern, it does not record a performance): keys toggle membership in the arp set (each
    /// sounds ONCE on add, stays highlighted) — and write NOTHING to any score (live, take, or
    /// overdub). Programming is INDEPENDENT of the transport: the pattern can be audibly playing
    /// while you add/remove notes, so you hear it evolve (edits land at the next cycle boundary).
    var arpProgramming = false
    /// The arp TRANSPORT is running (read by the panel's play/pause button). Published, so latch
    /// OFF's auto-pause at the end of one cycle shows up as a paused button with no user action.
    private(set) var arpPlaying = false
    /// The programmed arp set — insertion-ordered (drives `.order`) and deduped; also drives the
    /// keyboard's steady highlight.
    private(set) var arpSelectedNotes: [Int] = []
    /// Knob state, mirrored from SettingsStore by the panel. Cycle-boundary reads: edits take
    /// effect at the NEXT cycle, mid-cycle timing untouched.
    var arpSettings = ArpSettings()
    /// Cancellation latch for the play-mode scheduler + the record-mode once-sound — the
    /// `replayGeneration` discipline (cancelled tasks never claim generations).
    @ObservationIgnored private var arpGeneration: UInt64 = 0

    // MARK: Overdub state (same fence rule)

    /// Overdub mode: while armed, played notes (hand keys, MIDI, or the arp's play mode) also
    /// capture into the overdub stream — a NEW staff starting at the chosen score position.
    private(set) var overdubActive = false
    /// The score position the current overdub was anchored at (clamped caller input).
    private(set) var overdubBaseMs = 0
    /// EXCLUSIVE end of the pass's CONFINED region on the score clock — the score's own end at
    /// arm time. An overdub can NEVER extend the score (req 5), so notes struck past this are
    /// discarded and a held note closes AT it. `Int.max` = unbounded, which ONLY an EMPTY score
    /// degrades to — there is no region to confine to, and nothing to lengthen.
    private(set) var overdubRegionEndMs = Int.max
    /// Looper mode over that region (req 6): the backing replay loops `[base, regionEnd)`, the
    /// pass stays armed across iterations, and every iteration's notes LAYER into one capture at
    /// their wrapped position.
    private(set) var overdubLoop = false
    /// The ARMED pass's capture so far, coalesced at ~30 Hz by the same pump that publishes
    /// `liveEvents` — the score views render the in-progress overdub staff from this, so the
    /// staff visibly fills DURING the pass instead of appearing at "End overdub" (req 4).
    /// Completed notes only (the live-staff precedent: a held note appears on release).
    private(set) var overdubEvents: [StudioNoteEvent] = []
    /// A non-looping pass ran out of region: it accepts nothing more, and the owning score view
    /// finalizes it on the next observation tick (req 5's clean auto-finalize).
    private(set) var overdubReachedEnd = false

    /// One LIVE overdub staff (staffs 2…4 of the free-play score). IN-MEMORY ONLY, like
    /// `liveEvents` itself — the live score has never persisted; "Save" files everything as a
    /// take (`StudioTakeStaff` is the durable twin).
    struct LiveStaff: Identifiable, Equatable {
        let id: String
        var instrument: InstrumentKey
        var events: [StudioNoteEvent]
    }
    /// The live score's overdub staffs (primary = `liveEvents`). Capped with the primary at
    /// `StudioTake.maxStaffs` total, same as a saved take.
    private(set) var liveExtraStaffs: [LiveStaff] = []

    /// Append a finished LIVE overdub capture as a new staff. Refused (nil) at the
    /// `StudioTake.maxStaffs` cap or for an empty capture (no junk staffs) — the
    /// `StudioStore.addOverdubStaff` contract, in memory.
    @discardableResult
    func appendLiveExtraStaff(instrument: InstrumentKey, events: [StudioNoteEvent]) -> String? {
        guard !events.isEmpty, 1 + liveExtraStaffs.count < StudioTake.maxStaffs else { return nil }
        let id = StudioFactory.newStaffId()
        liveExtraStaffs.append(LiveStaff(id: id, instrument: instrument, events: events))
        return id
    }

    /// Commit an edited stream for one live overdub staff (its score editor's `onEdit`).
    func setLiveExtraStaffEvents(id: String, events: [StudioNoteEvent]) {
        guard let i = liveExtraStaffs.firstIndex(where: { $0.id == id }) else { return }
        liveExtraStaffs[i].events = events
    }

    /// Switch one live overdub staff's voice (polyphonic playback re-synthesizes through it).
    func setLiveExtraStaffInstrument(id: String, _ instrument: InstrumentKey) {
        guard let i = liveExtraStaffs.firstIndex(where: { $0.id == id }) else { return }
        liveExtraStaffs[i].instrument = instrument
    }

    /// Remove one live overdub staff.
    func deleteLiveExtraStaff(id: String) {
        liveExtraStaffs.removeAll { $0.id == id }
    }

    /// Reset the live overdub staffs (after "Save as take", or a manual clear — callers clear
    /// these alongside `clearLiveEvents()`; the two are separate so an edit-commit never races).
    func clearLiveExtraStaffs() {
        liveExtraStaffs = []
    }

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
    @ObservationIgnored private var takeInstrument: InstrumentKey?
    /// Host time of beat 1 (end of count-in) — the click realign + event log anchor.
    @ObservationIgnored private var takeBeat1Host: UInt64 = 0
    /// The bar-loop click buffer for the click's current BPM (kept for realign after recovery).
    @ObservationIgnored private var clickBuffer: AVAudioPCMBuffer?
    /// The BPM the click grid is running at — the take's BPM mid-take, the caller's otherwise.
    @ObservationIgnored private var clickBpm: Double = 120
    /// The click grid's phase anchor: beat 1 of a take, or the instant a MONITORING click was
    /// switched on. Every start/realign lands on a beat of THIS grid, so a mid-take flip can
    /// never fold the parked gap into the bar phase.
    @ObservationIgnored private var clickGridHost: UInt64 = 0
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
    /// The running backing's LOOP region, if it is a looper (an overdub with Loop on). The
    /// cursor wraps through it, so the playhead paints inside the region instead of marching off
    /// the end of a score the loop never actually leaves. `@ObservationIgnored` for the same
    /// reason the anchor is — it is read from a `TimelineView` tick.
    @ObservationIgnored private var replayLoopRegion: (startMs: Int, endMs: Int)?

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

    /// PLAYBACK-PATH trace. `NPLog` (not `dlog`) because a "why is it silent" capture is taken
    /// either way the tester has one: it os_logs under `nowplaying` unconditionally AND mirrors
    /// into the Settings ▸ Debug buffer the exported `pocketdj-debug-*.txt` is built from. Every
    /// refusal on this path carries a DISTINCT reason — the next capture must name the failure.
    private func plog(_ s: String) { NPLog.trace("instr: \(s)") }

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
        let backing = AVAudioPlayerNode()
        engine.attach(smp)
        engine.attach(mix)
        engine.attach(click)
        engine.attach(backing)
        // sampler → instrumentMix → mainMixer, all canonical. The take tap lives on
        // instrumentMix; the click joins at mainMixer DOWNSTREAM of it (never recorded).
        engine.connect(smp, to: mix, format: canonical)
        engine.connect(mix, to: engine.mainMixerNode, format: canonical)
        engine.connect(click, to: engine.mainMixerNode, format: canonical)
        // The rendered-audio backing joins at instrumentMix — INSIDE the take tap, exactly where
        // the sampler is. Attached EAGERLY (an idle player node costs nothing) rather than on the
        // first multi-staff play: reconfiguring a LIVE graph is the class of risk this whole fix
        // exists to remove.
        engine.connect(backing, to: mix, format: canonical)
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
        backingPlayer = backing
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
        stopBacking()          // stopReplay early-returns when nothing was playing — never leak the scope
        stopArpPlayback()
        _ = stopOverdub()
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
        stopArpPlayback()                                  // the arp voice is about to reload
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
        // Arp PROGRAM mode: keys SELECT notes (sound once, stay highlighted) and never fall
        // through — programming writes NOTHING to any score (live, take, or overdub), even while
        // the transport is audibly playing the pattern being programmed.
        if arpEnabled && arpProgramming {
            arpToggleSelection(note, velocity: velocity)
            return
        }
        #if os(iOS)
        interruptionParked = false     // an explicit key press is a user resume
        #endif
        _ = startEngineIfNeeded()      // wake a system-stopped engine before making sound
        let n = UInt8(clamping: max(0, min(127, note)))
        let v = UInt8(clamping: max(1, min(127, velocity)))
        // Score capture — before the audible guard (a note counts even with no instrument
        // loaded, the live-staff precedent) and separate from the take log so it never desyncs
        // a take's audio. While an overdub is armed the note belongs to the NEW staff ONLY —
        // mirroring it into the always-on live staff would double-write the composition (the
        // arp loop's "deliberately NO liveOn" rule, applied to hand/MIDI keys too).
        if overdubActive {
            eventLog.overdubOn(note: Int(n), velocity: Int(v), hostTime: mach_absolute_time())
        } else {
            eventLog.liveOn(note: Int(n), velocity: Int(v), hostTime: mach_absolute_time())
        }
        guard rt.engineReady, let smp = sampler else { return }
        smp.startNote(n, withVelocity: v, onChannel: 0)
        eventLog.noteOn(note: Int(n), velocity: Int(v), hostTime: mach_absolute_time())
        NowPlayingArbiter.shared.claim(self)   // audible → own the card slot (no card written)
    }

    func noteOff(_ note: Int) {
        // Arp program mode consumed the matching noteOn; the once-sound self-terminates.
        if arpEnabled && arpProgramming { return }
        let n = UInt8(clamping: max(0, min(127, note)))
        // liveOff stays unconditional: it closes a note that was pressed BEFORE the overdub
        // armed (it no-ops when the live stream has no pending onset for the note), so a
        // straddling note never dangles. The overdub close is gated as before.
        eventLog.liveOff(note: Int(n), hostTime: mach_absolute_time())
        if overdubActive {
            eventLog.overdubOff(note: Int(n), hostTime: mach_absolute_time())
        }
        guard rt.engineReady, let smp = sampler else { return }
        smp.stopNote(n, onChannel: 0)
        eventLog.noteOff(note: Int(n), hostTime: mach_absolute_time())
    }

    // MARK: - Arpeggiator (program/select + transport scheduler; math in ArpeggiatorEngine.swift)

    /// Toggle a note's membership in the arp set (program mode). Adding SOUNDS it once (250 ms,
    /// generation-guarded) and appends in insertion order (the `.order` contract); re-pressing
    /// removes it silently. NOTHING is logged to any score stream.
    private func arpToggleSelection(_ note: Int, velocity: Int) {
        let n = max(0, min(127, note))
        if let i = arpSelectedNotes.firstIndex(of: n) {
            arpSelectedNotes.remove(at: i)
            return
        }
        arpSelectedNotes.append(n)
        _ = startEngineIfNeeded()
        guard rt.engineReady, let smp = sampler else { return }
        let v = UInt8(clamping: max(1, min(127, velocity)))
        smp.startNote(UInt8(clamping: n), withVelocity: v, onChannel: 0)
        NowPlayingArbiter.shared.claim(self)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.rt.engineReady, let smp = self.sampler else { return }
            // Deliberately NOT generation-guarded: the transport starting/stopping — or the Arp
            // master toggle flipping OFF, which bumps the generation and (paused) sends no
            // all-notes-off — would strand this preview SOUNDING FOREVER. The only note this must
            // not cut is one the scheduler is currently sounding; that one owns its own gate-off.
            guard !self.arpSoundingNotes.contains(n) else { return }
            smp.stopNote(UInt8(clamping: n), onChannel: 0)
        }
    }

    /// Empty the arp set (the panel's explicit "Clear"; toggling Arp off keeps the set).
    func arpClearSelection() {
        arpSelectedNotes = []
        if arpPlaying { stopArpPlayback() }
    }

    /// TRANSPORT ▶: loop the current pattern through the instrument's own voice (the loaded
    /// program, channel 0 — the same node as live keys). The cycle is REGENERATED from the
    /// current set + knobs at each cycle boundary, so edits — including notes added/removed in
    /// PROGRAM mode while this is running — take effect next cycle; latch OFF plays exactly one
    /// cycle then auto-pauses (`arpPlaying` drops, which is what the transport button shows).
    /// Modeled on `replayTake`'s scheduling loop.
    @discardableResult
    func startArpPlayback(bpm: Double) -> Bool {
        startArpPlayback(bpm: bpm, requireAudio: true)
    }

    /// TEST SEAM: the same transport with the audio preconditions relaxed — headless CI has no
    /// sampler and no 32 MB bank, so the sounding path is unreachable there, but the SCORE-write
    /// path (req: a playing arp is captured like hand keys) and the latch/auto-pause state
    /// machine are exactly the shipped ones.
    @discardableResult
    func startArpPlaybackForTesting(bpm: Double) -> Bool {
        startArpPlayback(bpm: bpm, requireAudio: false)
    }

    @discardableResult
    private func startArpPlayback(bpm: Double, requireAudio: Bool) -> Bool {
        ensureEngine()
        if requireAudio {
            guard built, rt.engineReady, !isLoadingInstrument, sampler != nil else { return false }
        }
        guard !arpSelectedNotes.isEmpty else { return false }
        // During an OVERDUB the running replay IS the backing the arp plays over — stopping it
        // would end the pass out from under the user (the views file the capture when the
        // backing's isReplaying drops). Outside an overdub the old exclusivity holds.
        if !overdubActive { stopReplay() }
        stopArpPlayback()
        if requireAudio { guard startEngineIfNeeded() else { return false } }
        arpGeneration &+= 1
        let gen = arpGeneration
        arpPlaying = true
        NowPlayingArbiter.shared.claim(self)
        let start = ContinuousClock.now
        dlog("instr: arp START — \(arpSelectedNotes.count) notes \(arpSettings.order.rawValue)")
        Task { @MainActor [weak self] in
            var cycleBaseMs = 0
            var rng: any RandomNumberGenerator = SystemRandomNumberGenerator()
            while true {
                guard let eng = self, eng.arpGeneration == gen else { return }
                // Snapshot set + knobs at the cycle boundary (edits land next cycle).
                let s = eng.arpSettings
                let cycle = ArpPattern.cycle(notes: eng.arpSelectedNotes, order: s.order,
                                             octaves: s.octaves, rng: &rng)
                guard !cycle.isEmpty else { break }
                let step = ArpPattern.stepMs(length: s.length, bpm: bpm)
                for (k, note) in cycle.enumerated() {
                    let onAt = cycleBaseMs + ArpPattern.onsetMs(step: k, stepMs: step,
                                                                swingPct: s.swingPct)
                    let offAt = cycleBaseMs + ArpPattern.gateOffMs(step: k, stepMs: step,
                                                                   swingPct: s.swingPct)
                    try? await Task.sleep(until: start + .milliseconds(onAt), clock: .continuous)
                    guard let eng = self, eng.arpGeneration == gen else { return }
                    eng.arpStrikeOn(note)
                    try? await Task.sleep(until: start + .milliseconds(offAt), clock: .continuous)
                    guard let eng = self, eng.arpGeneration == gen else { return }
                    eng.arpStrikeOff(note)
                }
                // Next cycle starts on the grid: cycle length rounded UP to a whole pair so the
                // swing phase is preserved across cycles.
                let pairs = (cycle.count + 1) / 2
                cycleBaseMs += Int((Double(pairs) * 2 * step).rounded())
                guard cycleBaseMs <= ArpPattern.maxOnsetMs else { break }
                if !s.latch { break }                     // latch OFF ⇒ exactly one cycle
            }
            guard let eng = self, eng.arpGeneration == gen else { return }
            eng.finishArpPlayback()
        }
        return true
    }

    /// One arp step's ONSET, on the SAME write path a hand key takes (`noteOn`): the score
    /// capture happens BEFORE the audible guard — a PLAYING arp is a live performance and is
    /// captured like any other playing (req 3) — into the overdub staff while a pass is armed,
    /// else into the always-on live staff. NEVER both (the double-write rule). PROGRAM mode is
    /// unaffected: it never reaches here, it only edits `arpSelectedNotes`.
    private func arpStrikeOn(_ note: Int) {
        let clamped = max(0, min(127, note))
        let host = mach_absolute_time()
        if overdubActive {
            eventLog.overdubOn(note: clamped, velocity: Int(Self.arpVelocity), hostTime: host)
        } else {
            eventLog.liveOn(note: clamped, velocity: Int(Self.arpVelocity), hostTime: host)
        }
        arpSoundingNotes.insert(clamped)
        guard rt.engineReady, let smp = sampler else { return }
        smp.startNote(UInt8(clamping: clamped), withVelocity: Self.arpVelocity, onChannel: 0)
        // EXACTLY what replayTake does: highlights follow, and the take log fills iff a take is
        // armed ("arp records like hand keys" during a take is free).
        eventLog.noteOn(note: clamped, velocity: Int(Self.arpVelocity), hostTime: mach_absolute_time())
    }

    /// One arp step's GATE-OFF — the `noteOff` mirror: `liveOff` is unconditional (it self-guards
    /// when the live stream has no pending onset, so a note struck BEFORE a pass armed still
    /// closes on the live staff), the overdub close is gated on the armed pass.
    private func arpStrikeOff(_ note: Int) {
        let clamped = max(0, min(127, note))
        guard arpSoundingNotes.remove(clamped) != nil else { return }
        let host = mach_absolute_time()
        eventLog.liveOff(note: clamped, hostTime: host)
        if overdubActive { eventLog.overdubOff(note: clamped, hostTime: host) }
        guard rt.engineReady, let smp = sampler else { return }
        smp.stopNote(UInt8(clamping: clamped), onChannel: 0)
        eventLog.noteOff(note: clamped, hostTime: mach_absolute_time())
    }

    /// TEST SEAM: drive ONE arp step through the shipped write path (see `arpStrikeOn/Off`).
    func arpStepForTesting(note: Int, on: Bool) {
        on ? arpStrikeOn(note) : arpStrikeOff(note)
    }

    /// The arp's fixed strike velocity (the pattern is a machine, not a performance).
    nonisolated static let arpVelocity: UInt8 = 96

    /// Cancel arp playback (the transport's ⏸): bump the generation (the loop exits at its next
    /// wake) and silence anything still sounding NOW — cancelled tasks never claim generations.
    func stopArpPlayback() {
        arpGeneration &+= 1
        guard arpPlaying else { return }
        finishArpPlayback()
    }

    /// Notes the arp scheduler is currently sounding (silenced on stop/cancel).
    @ObservationIgnored private var arpSoundingNotes: Set<Int> = []

    private func finishArpPlayback() {
        arpPlaying = false
        // Close every sounding step through the SAME gate-off path a scheduled step takes, so a
        // pause (or latch-OFF's auto-pause) can never leave a hanging onset in the live staff or
        // the overdub capture. Iterate a copy — `arpStrikeOff` mutates the set.
        for n in arpSoundingNotes { arpStrikeOff(n) }
        arpSoundingNotes = []
        if rt.engineReady, let smp = sampler { smp.sendController(123, withValue: 0, onChannel: 0) }
        NowPlayingArbiter.shared.resign(self)
    }

    // MARK: - Overdub mode (played notes — hand or arp — capture into a NEW staff at a position)

    /// Arm overdub capture from score position `fromMs` (clamped). `anchorHostTime` is the
    /// host-time instant that MAPS to `fromMs` — the caller passes the same instant it anchors
    /// the backing replay's clock, so captured notes land at the true score position. Refused
    /// mid-take (`startTake` owns that session's streams).
    ///
    /// `scoreEndMs` confines the pass to `[fromMs, scoreEndMs)` — the overdub can never extend
    /// the score (req 5). Only an EMPTY score (`scoreEndMs == .max`, what the score screens pass
    /// when there is nothing to confine to) degrades to the unbounded pass, which is what
    /// "overdub from silence" has always been; a cursor parked at a REAL score's end has no room
    /// and is refused (`hasOverdubRoom`). `loop` turns the confined region into a looper (req 6);
    /// it is ignored for an unbounded pass, which has no wrap point.
    @discardableResult
    func startOverdub(fromMs: Int, anchorHostTime: UInt64 = mach_absolute_time(),
                      scoreEndMs: Int = .max, loop: Bool = false) -> Bool {
        guard !isRecordingTake, !overdubActive else { return false }
        let base = max(0, min(fromMs, Self.maxReplayMs))
        // UNBOUNDED is the EMPTY-score case ONLY — `scoreEndMs == .max`, which is what both score
        // screens pass for a score with no notes ("overdub from silence"). A REAL score always
        // confines the pass, INCLUDING when the cursor is parked at its very end (playing a score
        // to the end parks it exactly there): degrading that to unbounded would let the pass
        // lengthen the score, which is precisely what req 5 forbids. With no room at the anchor
        // there is nothing to overdub, so the pass is REFUSED — arming it would auto-finalize on
        // the next pump tick and look like a dead button. The callers say why.
        var end = Int.max
        if scoreEndMs != .max {
            end = min(scoreEndMs, Self.maxReplayMs)
            guard end - base >= Self.minOverdubRegionMs else {
                dlog("instr: overdub REFUSED — no room at \(base) ms (score ends at \(end) ms)")
                return false
            }
        }
        overdubBaseMs = base
        overdubRegionEndMs = end
        overdubLoop = loop && end < .max
        overdubEvents = []
        overdubReachedEnd = false
        overdubActive = true
        rt.overdubActive = true
        eventLog.overdubArm(anchorHostTime: anchorHostTime, baseMs: base,
                            regionEndMs: end, loop: overdubLoop)
        dlog("instr: overdub ARM at \(base) ms region→\(end == .max ? "∞" : String(end))"
             + " loop=\(overdubLoop ? 1 : 0)")
        return true
    }

    /// The least room a CONFINED pass needs at the anchor: below this the "pass" is an instant
    /// auto-finalize — armed and finished before the backing (or the user) played a note.
    nonisolated static let minOverdubRegionMs = 250

    /// Is there room to overdub at `fromMs`? `scoreEndMs == 0` is an EMPTY score, always
    /// overdubbable (the unbounded from-silence pass). The score screens ask BEFORE arming so a
    /// refusal can be explained instead of looking like a dead button.
    nonisolated static func hasOverdubRoom(fromMs: Int, scoreEndMs: Int) -> Bool {
        guard scoreEndMs > 0 else { return true }
        return min(scoreEndMs, maxReplayMs) - max(0, min(fromMs, maxReplayMs)) >= minOverdubRegionMs
    }

    /// The score's END on the score clock — the exclusive upper bound of an overdub region: the
    /// last note-off across every staff, 0 for an empty score (which `startOverdub` reads as
    /// "unbounded"). Pure + testable; both score screens compute the region with it.
    nonisolated static func scoreEndMs(staffs: [[StudioNoteEvent]]) -> Int {
        var end = 0
        for staff in staffs {
            for e in staff { end = max(end, max(0, e.onMs), e.offMs) }
        }
        return min(end, maxReplayMs)
    }

    /// End overdub mode, returning the captured events (ABSOLUTE score-clock ms, onset-sorted).
    /// Empty ⇒ the caller files no staff (no junk).
    func stopOverdub() -> [StudioNoteEvent] {
        guard overdubActive else { return [] }
        overdubActive = false
        rt.overdubActive = false
        let events = eventLog.overdubDisarmAndFinish(atHostTime: mach_absolute_time())
        // The in-progress publication is handed OFF here, never duplicated: the caller files
        // exactly these events as the finished staff, so the "recording" staff the views render
        // from `overdubEvents` must vanish in the same turn.
        overdubEvents = []
        overdubReachedEnd = false
        overdubRegionEndMs = .max
        overdubLoop = false
        dlog("instr: overdub END — \(events.count) events from \(overdubBaseMs) ms")
        return events
    }

    /// Loop OFF: the confined region is exhausted ⇒ the log already refuses further strikes and
    /// closed any held note AT the boundary; publish it so the owning score view finalizes the
    /// pass cleanly (req 5). Runs on the audio-INDEPENDENT 30 Hz pump — a pass with no backing
    /// (overdubbing over a silent bank) must auto-finalize exactly the same way.
    private func overdubDeadlineTick() {
        guard overdubActive, !overdubLoop, !overdubReachedEnd else { return }
        guard !Self.deadlineDeferred(isReplaying: isReplaying, backingReady: backingReady,
                                     backingPreparing: backingPreparing,
                                     capturedCount: eventLog.overdubCount) else { return }
        guard eventLog.overdubRegionExhausted(atHostTime: mach_absolute_time()) else { return }
        overdubReachedEnd = true
        dlog("instr: overdub region END at \(overdubRegionEndMs) ms — auto-finalize")
    }

    /// A pass whose BACKING has not started yet has not started: the capture arms at the button
    /// press, but the backing re-anchors an empty capture to the instant it is actually audible —
    /// and getting there costs real time (an on-demand mixdown render, a preset parse). Running the
    /// deadline against the press anchor in that window finalizes a short-region pass before the
    /// user hears a single note of backing (Overdub then looks like a dead button). Defer until the
    /// anchor is real; a capture that already has notes keeps its anchor, so its deadline runs as
    /// before. `backingPreparing` covers the OFF-ENGINE half of the warm-up (the render), where
    /// `isReplaying` is deliberately still false.
    nonisolated static func deadlineDeferred(isReplaying: Bool, backingReady: Bool,
                                             backingPreparing: Bool = false,
                                             capturedCount: Int) -> Bool {
        guard capturedCount == 0 else { return false }
        return backingPreparing || (isReplaying && !backingReady)
    }

    /// Notes the armed overdub has captured so far (completed + still-sounding). The score
    /// screen's re-anchor rule reads this: a tap while overdubbing moves the anchor only while
    /// NOTHING has been captured — once notes exist the anchor is fixed for this pass.
    var overdubCapturedCount: Int {
        overdubActive ? eventLog.overdubCount : 0
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
        takeInstrument = instrument
        activeTakeFileName = fileName
        isRecordingTake = true
        isCountingIn = countSec > 0
        takeGeneration &+= 1
        let gen = takeGeneration

        // PRE-LATCH the recording gate (spec §4): armed now, cutoff enforced by timestamp.
        eventLog.arm(beat1HostTime: takeBeat1Host)

        // The take's grid: beat 1 is the anchor, the click's first tick is the count-in's start.
        clickBpm = b
        clickGridHost = takeBeat1Host
        clickEnabled = click
        if click {
            clickBuffer = Self.makeClickBarBuffer(bpm: b, format: Self.canonicalFormat)
            if let clickPlayer, let buf = clickBuffer {
                // Bar loop scheduled once with .loops and started at the count-in's first tick —
                // the metronome then free-runs phase-locked to the beat-1 anchor.
                clickPlayer.stop()
                clickPlayer.scheduleBuffer(buf, at: nil, options: [.loops])
                clickPlayer.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: startSec)))
            }
        } else {
            // Intent and node must never diverge: a MONITORING click already running (the
            // free-play / overdub toggle) would tick right through the take with every control
            // showing OFF — and `healParkedClick`/`realignClick` gate on `clickEnabled`, so
            // nothing would ever take it back.
            clickPlayer?.stop()
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
        clickEnabled = false
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
            }
            smp.sendController(123, withValue: 0, onChannel: 0)
        }
        // A multi-staff replay voices through the backing — an audio mixdown (stopped + its
        // security scope released) or the sampler pool (CC 123 across every slot).
        stopBacking()
        silenceBackingSamplers()
        for n in replayActiveNotes { eventLog.noteOff(note: n, hostTime: mach_absolute_time()) }
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
        // An AUDIO backing is its own clock: read the player's render time so cursor and audio can
        // never disagree (and so a stalled engine freezes the cursor rather than letting a wall
        // clock march it on). `sampleTime` is monotonic across `.loops` iterations — the wrap folds
        // it back into the region, exactly as the scheduled-note looper's cursor did.
        if backingFile != nil {
            if let p = backingPlayer, p.isPlaying, let nt = p.lastRenderTime,
               let pt = p.playerTime(forNodeTime: nt),
               let sr = backingFile?.processingFormat.sampleRate, sr > 0 {
                // `sampleTime` reads slightly NEGATIVE in the instant between `play()` and the
                // first render (the node's start is a hair ahead of `lastRenderTime`) — floor the
                // elapsed at 0 or a looping cursor reports a position OUTSIDE its own region.
                let elapsed = max(0, Int((Double(pt.sampleTime) / sr * 1000).rounded()))
                let ms = backingStartMs + elapsed
                return Self.wrapIntoLoop(ms: max(0, min(ms, Self.maxReplayMs)),
                                         region: replayLoopRegion)
            }
            return backingPausedMs
        }
        guard let anchor = replayAnchor else { return replayFrozenMs }
        let c = (ContinuousClock.now - anchor).components
        let secs = Double(c.seconds) + Double(c.attoseconds) / 1e18
        // Clamp BEFORE the Int conversion — a wild clock delta must degrade, never trap (the
        // StaffChordView Int.min lesson). 24 h is far past any instrumental.
        guard secs.isFinite else { return replayFrozenMs }
        let ms = Int((min(max(secs, 0), 86_400) * 1000).rounded())
        return Self.wrapIntoLoop(ms: ms, region: replayLoopRegion)
    }

    /// A looping backing's cursor: positions past the wrap point fold back into the region, so
    /// iteration 3 of an overdub loop paints at the same place iteration 1 did. Pure + testable;
    /// identity when there is no loop.
    nonisolated static func wrapIntoLoop(ms: Int, region: (startMs: Int, endMs: Int)?) -> Int {
        guard let r = region, r.endMs > r.startMs, ms >= r.endMs else { return ms }
        return r.startMs + (ms - r.startMs) % (r.endMs - r.startMs)
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
        replayLoopRegion = nil
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

    // MARK: - Polyphonic replay scheduling (multi-staff — pure, unit-testable)

    /// One scheduled polyphonic action: `replayActions` tagged with the staff's MIDI channel.
    typealias MultiAction = (ms: Int, on: Bool, note: Int, velocity: Int, channel: Int)

    /// Channel/program assignment for a multi-staff take: staff 0 (the primary) → channel 0 with
    /// the take's instrument, extra staff i → channel i+1 with ITS instrument. Max 4 channels by
    /// the `StudioTake.maxStaffs` cap — the one shared bank is addressed per-channel, never
    /// duplicated.
    nonisolated static func channelPrograms(for take: StudioTake) -> [(channel: Int, program: UInt8)] {
        var out: [(channel: Int, program: UInt8)] = [(0, take.instrument.gmProgram)]
        for (i, staff) in (take.extraStaffs ?? []).enumerated() {
            out.append((i + 1, staff.instrument.gmProgram))
        }
        return out
    }

    /// The merged action list for a polyphonic replay starting at `from`: each staff's events run
    /// through the SAME chase-aware `replayActions(events:from:)`, tagged with the staff's
    /// channel, then globally sorted — ms ascending, offs before ons at equal ms (the
    /// `actionOrder` semantics), channel/note as deterministic tiebreaks (Swift's sort is not
    /// guaranteed stable).
    nonisolated static func replayActionsMulti(staffs: [(events: [StudioNoteEvent], channel: Int)],
                                               from: Int = 0) -> [MultiAction] {
        var merged: [MultiAction] = []
        for staff in staffs {
            for a in replayActions(events: staff.events, from: from) {
                merged.append((a.ms, a.on, a.note, a.velocity, staff.channel))
            }
        }
        return merged.sorted { a, b in
            if a.ms != b.ms { return a.ms < b.ms }
            if a.on != b.on { return !a.on }
            if a.channel != b.channel { return a.channel < b.channel }
            return a.note < b.note
        }
    }

    // MARK: - Backing playback (rendered audio; the multi-staff ▶ and the overdub backing)

    /// The RENDERED-AUDIO backing node — one `AVAudioPlayerNode` playing a take's cached mixdown
    /// (`StudioTakeRenderer.ensureRendered`), attached ONCE in `ensureEngine` as
    /// `backingPlayer → instrumentMix`: inside the permanent take tap, upstream of the click, so a
    /// backing is recordable exactly where the sampler is.
    ///
    /// Multi-staff playback rides THIS rather than a multitimbral MIDI synth. Per-staff timbre
    /// never needed one: the offline renderer already voices each staff through its own plain
    /// `AVAudioUnitSampler` (`loadSoundBankInstrument` loads ONE preset, not the whole 32 MB
    /// font), so the mixdown it writes is the same music with none of the AU's warm-up. Playing a
    /// FILE also leaves the live sampler completely free — it is the user's overdub voice, and the
    /// backing can never contend with it.
    @ObservationIgnored private var backingPlayer: AVAudioPlayerNode?
    /// The open mixdown. Non-nil ONLY while an audio backing is scheduled — it is also the gate
    /// that hands `replayPositionMs()` to the render clock instead of the wall clock.
    @ObservationIgnored private var backingFile: AVAudioFile?
    /// Security-scope release for a user-folder mixdown — held for the whole PLAY and released in
    /// `stopBacking` (releasing early ⇒ silent 0:00, the BurnStore lesson).
    @ObservationIgnored private var backingRelease: (() -> Void)?
    /// Score-clock ms of the scheduled window's frame 0 (the render's frame 0 IS score ms 0 —
    /// `StudioRender.pumpSampler` writes the leading silence), so position = start + elapsed.
    @ObservationIgnored private var backingStartMs = 0
    /// Last known backing position — mirrored by the 30 Hz pump and before every `stop()`, so a
    /// freeze parks where the audio actually stopped rather than where a wall clock guessed.
    @ObservationIgnored private var backingPausedMs = 0
    /// The `engineReady` contract for a backing: true only once it is actually scheduled and
    /// playing (an audio file) or its sampler pool is loaded (the live path) — never poked
    /// mid-parse. `deadlineDeferred` reads it.
    @ObservationIgnored private var backingReady = false
    /// A backing is being PREPARED off-screen (an on-demand render/decode before playback). The
    /// overdub deadline defers on it exactly as it defers on a warming bank: the capture armed at
    /// the button press, and a short region must not finalize before a note of backing is heard.
    /// `@ObservationIgnored` on purpose — the spinner is view state, so `isReplaying` stays FALSE
    /// through the whole prepare (a score reading it as "replay ended" would write a bogus cursor).
    @ObservationIgnored private var backingPreparing = false

    /// Why a backing did (or did not) start. EVERY exit is named: on device a silent `return` and
    /// a working call that happens to make no sound are indistinguishable, which is precisely how
    /// the multi-staff silence survived a shipped release.
    enum BackingStart: String, CaseIterable, Sendable {
        case started
        case startedOnePassFallback
        case noEngine
        case engineStopped
        case fileUnreadable
        case emptyFile
        case zeroFrameWindow
        case seekPastEnd

        /// Did audio actually start? (Both start cases sound; everything else is a refusal.)
        var isAudible: Bool { self == .started || self == .startedOnePassFallback }
    }

    /// Mark a backing as being prepared (an on-demand render) — see `backingPreparing`.
    func setBackingPreparing(_ on: Bool) { backingPreparing = on }

    /// The frame window a backing plays: `[fromMs, end-of-file)` normally, `[loop.start, loop.end)`
    /// when looping. A zero-frame window is REFUSED (nil) rather than scheduled — scheduling one is
    /// an uncatchable crash (the `StudioEngine.scheduleSampleWindow` rule). Pure + testable.
    nonisolated static func backingWindow(fromMs: Int, loop: (startMs: Int, endMs: Int)?,
                                          fileFrames: AVAudioFramePosition, sampleRate: Double)
        -> (startFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount, loops: Bool)? {
        guard fileFrames > 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
        func frame(_ ms: Int) -> AVAudioFramePosition {
            let clamped = max(0, min(ms, maxReplayMs))
            return min(AVAudioFramePosition((Double(clamped) / 1000 * sampleRate).rounded()), fileFrames)
        }
        let loops = (loop?.endMs ?? 0) > (loop?.startMs ?? 0)
        let start = frame(loops ? loop!.startMs : fromMs)
        let end = loops ? frame(loop!.endMs) : fileFrames
        let count = end - start
        guard count > 0, count <= AVAudioFramePosition(AVAudioFrameCount.max) else { return nil }
        return (start, AVAudioFrameCount(count), loops)
    }

    /// Play a take's RENDERED mixdown as the backing, from `fromMs` on the score clock — the
    /// multi-staff ▶ and the overdub backing both land here. `release` is the mixdown's
    /// security scope: this engine OWNS it from now until the backing stops.
    ///
    /// `loopRegion` makes it a looper over `[startMs, endMs)` (an overdub with Loop on replays its
    /// confined region forever, so notes layer pass after pass). The score cursor wraps with it
    /// (`replayPositionMs`), and the position is read from the player's own render clock, so
    /// cursor and audio can never disagree.
    @discardableResult
    func replayRenderedAudio(url: URL, release: (() -> Void)? = nil, fromMs: Int = 0,
                             forTake takeId: String? = nil,
                             loopRegion: (startMs: Int, endMs: Int)? = nil) -> BackingStart {
        ensureEngine()
        let name = url.lastPathComponent
        guard built, let player = backingPlayer else {
            release?()
            plog("backing REFUSED noEngine — graph not built (no audio device?) \(name)")
            return .noEngine
        }
        stopReplay()
        // A latched arp SURVIVES the overdub backing starting: it is the advertised overdub source
        // ("latch the arp, then Overdub"), playing the sampler while the backing plays the file.
        // Outside an overdub the old replay-vs-arp exclusivity holds.
        if !overdubActive { stopArpPlayback() }
        guard startEngineIfNeeded() else {
            release?()
            plog("backing REFUSED engineStopped — startEngineIfNeeded failed \(name)")
            return .engineStopped
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            release?()
            plog("backing REFUSED fileUnreadable — \(name): \(error.localizedDescription)")
            return .fileUnreadable
        }
        guard file.length > 0 else {
            release?()
            plog("backing REFUSED emptyFile — \(name) 0 frames")
            return .emptyFile
        }
        let from = max(0, min(fromMs, Self.maxReplayMs))
        let loop: (startMs: Int, endMs: Int)? = loopRegion.flatMap {
            let r = (startMs: max(0, min($0.startMs, Self.maxReplayMs)),
                     endMs: max(0, min($0.endMs, Self.maxReplayMs)))
            return r.endMs > r.startMs ? r : nil
        }
        let sr = file.processingFormat.sampleRate
        guard let win = Self.backingWindow(fromMs: from, loop: loop, fileFrames: file.length,
                                           sampleRate: sr) else {
            release?()
            // Park the cursor where the seek asked for (the `replayTake` rule) — the "last played"
            // emphasis holds instead of the button doing nothing at all.
            if from > 0 { parkReplayPosition(atMs: from, forTake: takeId) } else { replayOwner = takeId }
            if loop == nil {
                plog("backing seek past end — cursor parked at \(from) ms (\(name) \(file.length)f)")
                return .seekPastEnd
            }
            plog("backing REFUSED zeroFrameWindow from=\(from) loop=\(loop!.startMs)…\(loop!.endMs)"
                 + " len=\(file.length)f")
            return .zeroFrameWindow
        }

        replayGeneration &+= 1
        let gen = replayGeneration
        var outcome = BackingStart.started
        var region: (startMs: Int, endMs: Int)?
        player.stop()
        var scheduledLoop = false
        if win.loops, let loop {
            // Seamless loop: read the region into a buffer and `.loops` it (the
            // `StudioEngine.scheduleSampleWindow` looper). The cursor wraps through the SAME
            // region, so iteration 3 paints where iteration 1 did.
            if let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: win.frameCount) {
                file.framePosition = win.startFrame
                if (try? file.read(into: buf, frameCount: win.frameCount)) != nil, buf.frameLength > 0 {
                    player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
                    scheduledLoop = true
                    let playedMs = Int((Double(win.frameCount) / sr * 1000).rounded())
                    region = (startMs: loop.startMs, endMs: loop.startMs + playedMs)
                    if region!.endMs != loop.endMs {
                        plog("backing loop CLAMPED to the render — \(loop.startMs)…\(region!.endMs)"
                             + " (asked \(loop.endMs))")
                    }
                }
            }
            if !scheduledLoop {
                plog("backing loopReadFailed — one pass instead of looping"
                     + " \(loop.startMs)…\(loop.endMs) (\(name))")
                outcome = .startedOnePassFallback
            }
        }
        if !scheduledLoop {
            // One pass. `.dataPlayedBack` is the only truthful end signal — the player node does
            // NOT stop itself when a segment runs dry (`isPlaying` stays true, rendering silence).
            player.scheduleSegment(file, startingFrame: win.startFrame, frameCount: win.frameCount,
                                   at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finishBackingReplay(gen: gen) }
            }
        }
        backingFile = file
        backingRelease = release
        backingStartMs = scheduledLoop ? (loop?.startMs ?? from) : from
        backingPausedMs = backingStartMs
        backingReady = true
        replayOwner = takeId
        isReplaying = true
        NowPlayingArbiter.shared.claim(self)
        // Fallback clock for the instant before the render clock reports (and for a stalled
        // engine): back-dated by `from`, the `replayTake` anchor contract.
        replayAnchor = ContinuousClock.now - .milliseconds(backingStartMs)
        replayFrozenMs = backingStartMs
        replayLoopRegion = region
        player.play()
        // The overdub capture armed at the button press, but the backing only starts NOW (an
        // on-demand render/decode costs real time). Re-anchor a capture that has nothing in it yet
        // to this instant, so notes played in time with the backing land at the true score
        // position. A capture with notes keeps its anchor (re-basing captured events corrupts them).
        if overdubActive, eventLog.overdubCount == 0 {
            eventLog.overdubArm(anchorHostTime: mach_absolute_time(), baseMs: overdubBaseMs,
                                regionEndMs: overdubRegionEndMs, loop: overdubLoop)
        }
        plog("backing START \(name) from=\(backingStartMs) ms"
             + " loop=\(region.map { "\($0.startMs)…\($0.endMs)" } ?? "-")"
             + " win=\(win.startFrame)+\(win.frameCount)f")
        return outcome
    }

    /// The backing ran out (its `.dataPlayedBack` completion, or the pump's backstop for a node
    /// that went idle without one). Generation-guarded — a stopped/replaced replay never ends the
    /// one that took its place.
    private func finishBackingReplay(gen: Int) {
        guard replayGeneration == gen, isReplaying, backingFile != nil else { return }
        isReplaying = false
        freezeReplayPosition()
        stopBacking()
        NowPlayingArbiter.shared.resign(self)
        plog("backing END at \(replayFrozenMs ?? 0) ms")
    }

    /// Stop + fully release the audio backing: mirror the position FIRST (so a freeze parks where
    /// the audio really is), stop the node, drop the file, and release its security scope. Called
    /// ONLY from `stopReplay`/`finishBackingReplay`/teardown paths, so no exit can leak the scope.
    private func stopBacking() {
        if backingFile != nil, let p = backingPlayer {
            if p.isPlaying, let ms = replayPositionMs() { backingPausedMs = ms }
            p.stop()
        }
        backingFile = nil
        backingReady = false
        backingRelease?()
        backingRelease = nil
    }

    /// Pump duty (30 Hz): mirror the backing position, and END a backing whose node has gone idle.
    /// The completion handler is not a contract worth trusting after a route change — without this
    /// backstop `isReplaying` sticks true forever, the arbiter is never resigned, and ▶ becomes a
    /// permanent Stop.
    private func backingTick() {
        guard backingFile != nil, let p = backingPlayer else { return }
        if p.isPlaying, let ms = replayPositionMs() { backingPausedMs = ms }
        guard isReplaying, !p.isPlaying else { return }
        plog("backing STOP — node idle at \(backingPausedMs) ms")
        finishBackingReplay(gen: replayGeneration)
    }

    // MARK: - Live multi-staff replay (real time, one sampler per staff)

    /// The per-staff sampler pool — ONE plain `AVAudioUnitSampler` per staff, each holding its own
    /// single GM preset (`loadSoundBankInstrument` loads one preset, NOT the 32 MB font, which is
    /// what lets `StudioRender.renderStaffPCM` do exactly this offline). Attached once and reused,
    /// never detached; capped by `StudioTake.maxStaffs`.
    @ObservationIgnored private var backingSamplers: [AVAudioUnitSampler] = []
    /// What each pool slot currently holds ("<bank path>|<program>") — the idempotence key, so a
    /// repeat pass re-parses nothing.
    @ObservationIgnored private var backingLoaded: [String?] = []

    /// Replay MULTIPLE staffs mixed, IN REAL TIME through the sampler pool — the fallback for a
    /// backing with no rendered mixdown to play (an unsaved LIVE score, or a render that could not
    /// be produced). A saved take plays `replayRenderedAudio` instead: proven audio, no AU warm-up.
    ///
    /// Single staff delegates to `replayTake` — zero regression on legacy takes. `bankURL` is the
    /// shared SoundFont (nil at the caller is the "download the pack first" prompt).
    /// `loopRegion` turns it into a looper over `[startMs, endMs)`: every iteration re-strikes from
    /// `startMs` and ALL notes are silenced at the wrap, so nothing hangs across the boundary.
    func replayStaffsLive(staffs: [(events: [StudioNoteEvent], instrument: InstrumentKey)],
                          bankURL: URL, fromMs: Int = 0, forTake takeId: String? = nil,
                          loopRegion: (startMs: Int, endMs: Int)? = nil) {
        guard !staffs.isEmpty else {
            plog("live-staffs REFUSED noStaffs")
            return
        }
        guard staffs.count > 1 || overdubActive else {
            // One staff, no overdub: the shipped single-staff path, untouched.
            if let only = staffs.first {
                replayTake(events: only.events, instrument: only.instrument,
                           fromMs: fromMs, forTake: takeId)
            }
            return
        }
        ensureEngine()
        guard built else {
            plog("live-staffs REFUSED noEngine — graph not built (no audio device?)")
            return
        }
        stopReplay()
        // A latched arp SURVIVES the overdub backing starting (see `replayRenderedAudio`).
        if !overdubActive { stopArpPlayback() }
        guard startEngineIfNeeded() else {
            plog("live-staffs REFUSED engineStopped — startEngineIfNeeded failed")
            return
        }
        let from = max(0, min(fromMs, Self.maxReplayMs))
        let programs = staffs.enumerated().map { (channel: $0.offset,
                                                  program: $0.element.instrument.gmProgram) }
        var actions = Self.replayActionsMulti(
            staffs: staffs.enumerated().map { (events: $0.element.events, channel: $0.offset) },
            from: from)
        // A looping backing plays the REGION only: everything at/after the wrap point is cut, and
        // the wrap itself silences whatever is still sounding (below).
        let loop: (startMs: Int, endMs: Int)? = loopRegion.flatMap {
            let r = (startMs: max(0, min($0.startMs, Self.maxReplayMs)),
                     endMs: max(0, min($0.endMs, Self.maxReplayMs)))
            return r.endMs > r.startMs ? r : nil
        }
        if let loop { actions = actions.filter { $0.ms < loop.endMs } }
        guard !actions.isEmpty else {
            if from > 0 { parkReplayPosition(atMs: from, forTake: takeId) } else { replayOwner = takeId }
            plog("live-staffs nothing to play from \(from) ms — cursor parked")
            return
        }
        replayOwner = takeId
        isReplaying = true
        NowPlayingArbiter.shared.claim(self)
        replayGeneration &+= 1
        let gen = replayGeneration
        plog("live-staffs START — \(staffs.count) staffs, \(actions.count) actions"
             + (from > 0 ? " from \(from) ms" : ""))
        // Provisional anchor so the cursor reads `from` immediately; re-anchored below once the
        // pool is loaded (a first-time preset parse must not compress the opening notes).
        replayAnchor = ContinuousClock.now - .milliseconds(from)
        replayFrozenMs = from
        replayLoopRegion = loop
        Task { @MainActor [weak self] in
            guard let eng0 = self else { return }
            let ok = await eng0.ensureBackingSamplers(bankURL: bankURL, programs: programs)
            guard let eng1 = self, eng1.replayGeneration == gen else { return }
            guard ok else {
                eng1.plog("live-staffs ABORT — samplers unavailable")
                eng1.isReplaying = false
                eng1.freezeReplayPosition()
                NowPlayingArbiter.shared.resign(eng1)
                return
            }
            // Real anchor: back-dated by `from` so the loop's absolute sleeps and the score's
            // playhead agree (the `replayTake` anchor contract).
            let start = ContinuousClock.now - .milliseconds(from)
            eng1.replayAnchor = start
            // The overdub capture armed at button-press but the backing only starts NOW — re-anchor
            // an empty capture to this instant (a capture with notes keeps its anchor).
            if eng1.overdubActive, eng1.eventLog.overdubCount == 0 {
                eng1.eventLog.overdubArm(anchorHostTime: mach_absolute_time(),
                                         baseMs: eng1.overdubBaseMs,
                                         regionEndMs: eng1.overdubRegionEndMs,
                                         loop: eng1.overdubLoop)
            }
            // One pass per iteration; a non-looping backing runs the body exactly once (`break`
            // at the bottom), so the legacy path is bit-for-bit what it was.
            var iteration = 0
            while true {
                let offset = (loop.map { $0.endMs - $0.startMs } ?? 0) * iteration
                for a in actions {
                    try? await Task.sleep(until: start + .milliseconds(a.ms + offset),
                                          clock: .continuous)
                    guard let eng = self, eng.replayGeneration == gen else { return }
                    guard eng.backingReady, a.channel < eng.backingSamplers.count else { continue }
                    let smp = eng.backingSamplers[a.channel]
                    let n = UInt8(clamping: max(0, min(127, a.note)))
                    if a.on {
                        smp.startNote(n, withVelocity: UInt8(clamping: max(1, min(127, a.velocity))),
                                      onChannel: 0)
                        eng.replayActiveNotes.insert(a.note)
                        eng.eventLog.noteOn(note: a.note, velocity: a.velocity,
                                            hostTime: mach_absolute_time())   // highlights follow
                    } else {
                        smp.stopNote(n, onChannel: 0)
                        eng.replayActiveNotes.remove(a.note)
                        eng.eventLog.noteOff(note: a.note, hostTime: mach_absolute_time())
                    }
                }
                guard let loop else { break }
                // Sleep to the wrap point (the region's end, not the last action's) and silence
                // everything AT the boundary — no backing note may hang into the next iteration.
                try? await Task.sleep(until: start + .milliseconds(loop.endMs + offset),
                                      clock: .continuous)
                guard let eng = self, eng.replayGeneration == gen else { return }
                eng.silenceBackingSamplers()
                for n in eng.replayActiveNotes {
                    eng.eventLog.noteOff(note: n, hostTime: mach_absolute_time())
                }
                eng.replayActiveNotes = []
                iteration += 1
            }
            guard let eng = self, eng.replayGeneration == gen else { return }
            eng.isReplaying = false
            eng.replayActiveNotes = []
            eng.freezeReplayPosition()
            eng.silenceBackingSamplers()
            eng.backingReady = false
            NowPlayingArbiter.shared.resign(eng)
            eng.plog("live-staffs END")
        }
    }

    /// CC 123 all-notes-off across the pool — belt-and-braces silence at a loop wrap and on stop.
    private func silenceBackingSamplers() {
        for s in backingSamplers { s.sendController(123, withValue: 0, onChannel: 0) }
    }

    /// Grow + load the per-staff sampler pool (idempotent; re-parses only what actually changed).
    /// Each preset parse runs OFF the main actor with `backingReady` gated closed — the
    /// `loadInstrument` discipline. Any failure returns false, and the caller ABORTS the replay
    /// rather than playing a silently-missing part.
    private func ensureBackingSamplers(bankURL: URL,
                                       programs: [(channel: Int, program: UInt8)]) async -> Bool {
        guard built, let mix = instrumentMix else {
            plog("live-staffs REFUSED noEngine — pool has no mixer")
            return false
        }
        while backingSamplers.count < programs.count {
            let s = AVAudioUnitSampler()
            engine.attach(s)
            engine.connect(s, to: mix, format: Self.canonicalFormat)
            backingSamplers.append(s)
            backingLoaded.append(nil)
        }
        backingReady = false
        func key(_ program: UInt8) -> String { "\(bankURL.path)|\(program)" }
        let pending = programs.enumerated()
            .filter { backingLoaded[$0.offset] != key($0.element.program) }
            .map { BackingLoadItem(index: $0.offset, sampler: backingSamplers[$0.offset],
                                   program: $0.element.program) }
        if !pending.isEmpty {
            let failed: [Int] = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    var bad: [Int] = []
                    for item in pending {
                        do {
                            try item.sampler.loadSoundBankInstrument(
                                at: bankURL, program: item.program,
                                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                        } catch { bad.append(item.index) }
                    }
                    cont.resume(returning: bad)
                }
            }
            for item in pending {
                let ok = !failed.contains(item.index)
                backingLoaded[item.index] = ok ? key(item.program) : nil
                if !ok {
                    plog("live-staffs REFUSED bankLoad — idx \(item.index) program \(item.program)"
                         + " \(bankURL.lastPathComponent)")
                }
            }
            guard failed.isEmpty else { return false }
        }
        backingReady = true
        return true
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

    /// The next BEAT boundary at/after `nowSec + lead` on the click grid, with its index WITHIN
    /// the bar (0 = the accented beat 1). Works before the grid anchor too (negative beat indices
    /// wrap positively). Wild input degrades to "now + lead, beat 1" — never traps (the
    /// StaffChordView `Int.min` lesson: clamp BEFORE the Int conversion).
    nonisolated static func nextBeatOnGrid(nowSec: Double, gridSec: Double, beatSec: Double,
                                           lead: Double = 0.05) -> (atSec: Double, beatInBar: Int) {
        guard beatSec.isFinite, beatSec > 0, nowSec.isFinite, gridSec.isFinite else {
            return (nowSec.isFinite ? nowSec + lead : lead, 0)
        }
        let raw = ((nowSec + lead - gridSec) / beatSec).rounded(.up)
        guard raw.isFinite, abs(raw) < 1e12 else { return (nowSec + lead, 0) }
        let n = Int(raw)
        return (gridSec + Double(n) * beatSec, ((n % 4) + 4) % 4)
    }

    /// The REMAINDER of a bar-click buffer from `beat` (1…3) onward — scheduled ONCE ahead of the
    /// looping bar so a click switched on mid-bar starts at the next beat while the loop behind it
    /// still lands on the bar line. nil for beat 0 (the loop alone is already in phase).
    nonisolated static func clickTailBuffer(_ bar: AVAudioPCMBuffer, fromBeat beat: Int)
        -> AVAudioPCMBuffer? {
        let total = Int(bar.frameLength)
        let beatFrames = total / 4
        let b = max(0, min(3, beat))
        guard b > 0, beatFrames > 0 else { return nil }
        let offset = b * beatFrames
        let length = total - offset
        guard length > 0,
              let out = AVAudioPCMBuffer(pcmFormat: bar.format,
                                         frameCapacity: AVAudioFrameCount(length)),
              let src = bar.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(length)
        for ch in 0..<Int(bar.format.channelCount) {
            memcpy(dst[ch], src[ch] + offset, length * MemoryLayout<Float>.size)
        }
        return out
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
        guard clickEnabled else { return }
        startClickOnGrid()
    }

    /// Start (or restart) the click on its own grid, at the NEXT BEAT: mid-bar, the remainder of
    /// the bar is scheduled ONCE as a tail so the looping bar behind it still lands on the bar
    /// line (the accent stays on beat 1). This is the LIVE-toggle path (req 7: flipping the click
    /// takes effect on the next beat, without stopping the take, reconfiguring the graph, or
    /// writing anything anywhere) AND the recovery path — a stop + fresh schedule revives a
    /// zombie node, which no resume-in-place can.
    private func startClickOnGrid() {
        guard built, let click = clickPlayer else { return }
        guard let bar = Self.makeClickBarBuffer(bpm: clickBpm, format: Self.canonicalFormat) else { return }
        clickBuffer = bar
        guard startEngineIfNeeded() else { return }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let grid = AVAudioTime.seconds(forHostTime: clickGridHost)
        let beat = Self.nextBeatOnGrid(nowSec: now, gridSec: grid,
                                       beatSec: 60.0 / max(1, clickBpm))
        click.stop()
        if beat.beatInBar > 0, let tail = Self.clickTailBuffer(bar, fromBeat: beat.beatInBar) {
            click.scheduleBuffer(tail, at: nil, options: [])
        }
        click.scheduleBuffer(bar, at: nil, options: [.loops])
        click.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: beat.atSec)))
    }

    /// Flip the metronome LIVE — free play, an overdub pass (looped or not), or mid-take. The
    /// take/pass is never touched: only the click node stops or (re)starts, on the next beat of
    /// the current grid. `bpm` sets the monitoring grid; mid-take the take's own BPM always wins.
    func setClickEnabled(_ on: Bool, bpm: Double? = nil) {
        ensureEngine()
        guard on else {
            clickEnabled = false
            clickPlayer?.stop()
            if !isRecordingTake { clickBuffer = nil }
            dlog("instr: click OFF")
            return
        }
        let requested: Double = {
            guard let asked = bpm, asked.isFinite, asked > 0 else { return clickBpm }
            return min(300, max(40, asked))          // the startTake range, one clamp for both
        }()
        let b = isRecordingTake ? takeBpm : requested
        // Already ticking at this tempo ⇒ a no-op re-assert (never a restart, which would audibly
        // stutter the grid the user is playing to).
        if clickEnabled, abs(b - clickBpm) < 0.0001, clickPlayer?.isPlaying == true { return }
        if !isRecordingTake, !clickEnabled || abs(b - clickBpm) >= 0.0001 {
            clickGridHost = AVAudioTime.hostTime(forSeconds:
                AVAudioTime.seconds(forHostTime: mach_absolute_time()) + Self.clickStartLead)
        }
        clickBpm = b
        clickEnabled = true
        startClickOnGrid()
        dlog("instr: click ON at \(Int(b)) BPM")
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
    /// click node — intent (`clickEnabled`) vs `node.isPlaying` is the truth. Realigns rather
    /// than blindly `play()`s so the bar phase survives.
    private func healParkedClick() {
        guard clickEnabled, let click = clickPlayer, !click.isPlaying else { return }
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
        stopArpPlayback()
        rt.engineReady = false
        rt.sampler = nil
        stopBacking()                     // the open mixdown + its security scope die with the graph
        backingSamplers = []              // the pool's AUs are orphaned with the daemon
        backingLoaded = []
        backingPreparing = false
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
        engine.stop()
        engine = AVAudioEngine()          // the orphaned graph is unusable — recreate everything
        built = false
        isReady = false
        sampler = nil
        instrumentMix = nil
        clickPlayer = nil
        backingPlayer = nil
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
                            // Overdub armed ⇒ the note belongs to the NEW staff only (never
                            // double-written into the live staff — the hand-key rule).
                            if rt.overdubActive {
                                log.overdubOn(note: Int(note), velocity: Int(velocity), hostTime: host)
                            } else {
                                log.liveOn(note: Int(note), velocity: Int(velocity), hostTime: host)
                            }
                            if rt.engineReady, let smp = rt.sampler {
                                smp.startNote(note, withVelocity: velocity, onChannel: 0)
                            }
                            log.noteOn(note: Int(note), velocity: Int(velocity), hostTime: host)
                        case .noteOff(let note):
                            log.liveOff(note: Int(note), hostTime: host)
                            if rt.overdubActive {
                                log.overdubOff(note: Int(note), hostTime: host)
                            }
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
        publishLive(events)
    }

    /// Reset the live staff (after "Save as take", or a manual clear).
    func clearLiveEvents() {
        eventLog.clearLive()
        publishLive([])
    }

    /// TEST SEAM: run ONE pump pass synchronously (the 30 Hz pump does exactly this on a timer):
    /// publish the live staff, publish the in-progress overdub staff, and check the confined
    /// region's deadline. Lets a unit test verify the capture → published-state paths without the
    /// async pump or a UI gesture.
    func pumpLiveOnceForTesting() {
        publishStaffs()
        overdubDeadlineTick()
    }

    /// Publish the drained live staff + in-progress overdub staff, and the cheap flags derived
    /// from the live one (one place, so the pump, the test seam and score edits never disagree).
    private func publishStaffs() {
        if let live = eventLog.snapshotLiveIfDirty() { publishLive(live) }
        if let od = eventLog.snapshotOverdubIfDirty() { overdubEvents = od }
    }

    /// Assign the live staff + its derived flags, writing each only on a real change (an
    /// @Observable set invalidates its readers even when the value is identical).
    private func publishLive(_ events: [StudioNoteEvent]) {
        liveEvents = events
        if liveHasEvents != !events.isEmpty { liveHasEvents = !events.isEmpty }
        let full = eventLog.liveCaptureFull
        if liveCaptureFull != full { liveCaptureFull = full }
    }

    /// Staff publishes are coalesced HARDER than key highlights: each one re-quantizes and
    /// re-paginates the staff that renders it, while a highlight only compares a small Set. Every
    /// third ~30 Hz tick ⇒ ~10 Hz, which still reads as "the notation fills as you play" and costs
    /// a third of the layout. A skipped tick consumes NOTHING: the dirty flags stay set and the
    /// next publish carries everything.
    nonisolated static let staffPublishEveryNTicks = 3

    private func startHighlightPump() {
        guard highlightTask == nil else { return }
        highlightTask = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30 Hz
                guard let self else { break }
                if let notes = self.eventLog.drainHighlightsIfDirty() {
                    self.pressedNotes = notes
                }
                // The live staff and the IN-PROGRESS overdub staff (req 4) ride the same
                // coalesced, append-only drain — at ~10 Hz (see `staffPublishEveryNTicks`), and
                // only when the capture changed, so a filling staff never costs a per-note (nor a
                // per-frame) full-score relayout.
                ticks &+= 1
                if ticks % Self.staffPublishEveryNTicks == 0 { self.publishStaffs() }
                self.backingTick()
                self.overdubDeadlineTick()
            }
        }
    }
}

/// Off-main-actor carrier for one pool sampler + the preset it must load — the
/// `InstrumentRealtimeBridge` device. `@unchecked Sendable` for the same reason: the parse runs on
/// a background queue while `backingReady` is closed, so nothing else talks to these AUs for its
/// duration, and `loadSoundBankInstrument` is safe from any thread under that rule.
private final class BackingLoadItem: @unchecked Sendable {
    let index: Int
    let sampler: AVAudioUnitSampler
    let program: UInt8
    init(index: Int, sampler: AVAudioUnitSampler, program: UInt8) {
        self.index = index; self.sampler = sampler; self.program = program
    }
}
