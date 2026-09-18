import Foundation
import Observation
import AVFoundation        // AVAudioEngine + nodes (iOS · iPad · Mac); AVAudioSession is iOS-only (guarded below)
import AudioToolbox        // DynamicsProcessor AU parameter ids + AudioUnitSetParameter
import MediaPlayer         // MPNowPlayingInfoCenter + MPRemoteCommandCenter (lock-screen Now Playing)
import os                  // mixdiag Logger — device-switch/recovery diagnostics

/// Render-tap liveness mirrors for the `mixdiag` diagnostics — written on the tap thread, read on
/// main. Plain aligned 64-bit stores (a torn read skews a diagnostic by one callback — harmless;
/// same contract as `MixTapSink.isCapturing`).
final class MixTapPulse: @unchecked Sendable {
    /// `Date.timeIntervalSinceReferenceDate` of the last houseSum tap callback (0 = never).
    var lastTapAt: Double = 0
    /// …of the last callback that carried actual signal (peak > -66 dBFS). 0 = never.
    var lastAudibleAt: Double = 0
}

/// Per-deck VU-meter level mirror — the SAME non-observable doctrine as `MixTapPulse` /
/// `StudioMicLevels`: written on the realtime tap thread (two taps: pre-fader `flanger`,
/// post-fader `mainGain`), polled by a `TimelineView` in `MixView`. NEVER `@Observable` — fast
/// meter writes must not invalidate SwiftUI (the proven dead-play-button bug). Each field has a
/// single writer thread (pre* ← the flanger tap, post* ← the mainGain tap), so a torn read on
/// main skews one meter frame at worst — invisible. `rms` is a one-pole-smoothed body level and
/// `peak` is a fast-attack / slow-decay peak hold; BOTH ballistics run on the tap thread so the
/// view stays a pure renderer.
final class MixDeckLevels: @unchecked Sendable {
    var prePeak: Float = 0
    var preRMS: Float = 0
    var postPeak: Float = 0
    var postRMS: Float = 0
    /// `Date.timeIntervalSinceReferenceDate` of the last tap write (0 = never) — lets the meter
    /// decay to silence when the taps stop firing (engine parked by a route change / interruption).
    var updatedAt: Double = 0
}

/// The in-app DEBUG-SESSION log behind Settings ▸ Debug: turn capture ON, reproduce the issue,
/// turn it OFF, export the session (a remote TestFlight tester ships the file back via iCloud).
/// Every `MixEngine` diagnostic line goes to os_log unconditionally; while capturing it is ALSO
/// buffered here (~1 heartbeat line/s + recovery/transport events — a few KB per minute).
@MainActor
@Observable
final class MixDiag {
    static let shared = MixDiag()
    private(set) var isCapturing = false
    private(set) var lines: [String] = []
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Begin a fresh session (clears the previous capture).
    func start() {
        lines = []
        startedAt = Date()
        endedAt = nil
        isCapturing = true
        append("mixdiag session START — \(Self.buildIdentity())")
        // Main-thread stall attribution rides every capture (see MainThreadStallWatchdog):
        // its STALL/marker lines land in this same buffer, so the exported session carries them.
        MainThreadStallWatchdog.shared.start()
    }

    /// End the session; the buffer stays for export until the next `start()`.
    func stop() {
        guard isCapturing else { return }
        MainThreadStallWatchdog.shared.stop()
        append("mixdiag session END")
        isCapturing = false
        endedAt = Date()
    }

    func append(_ line: String) {
        guard isCapturing else { return }
        lines.append(Self.stampFmt.string(from: Date()) + "  " + line)
        if lines.count > 50_000 { lines.removeFirst(lines.count / 2) }   // runaway-session bound
    }

    /// The full session as a shareable text file body.
    func dump() -> String {
        "PocketDJ debug session — \(Self.buildIdentity())\n"
        + "captured \(startedAt.map { $0.formatted() } ?? "?") → \(endedAt.map { $0.formatted() } ?? "running")\n\n"
        + lines.joined(separator: "\n") + "\n"
    }

    static func buildIdentity() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        #if os(macOS)
        let plat = "macOS"
        #else
        let plat = "iOS"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "v\(v) build \(b) · \(plat) \(os)"
    }
}

/// Cross-platform DJ mix engine — a first-party two-deck `AVAudioEngine` graph. Each deck is
///
///   AVAudioPlayerNode → AVAudioUnitTimePitch → DynamicsProcessor(comp) → AVAudioUnitEQ(filter)
///                     → AVAudioUnitReverb → AVAudioUnitDelay(flanger) → mainMixerNode → output
///
/// which gives, live and on-device: **tempo** (`timePitch.rate`, pitch preserved), **pitch**
/// (`timePitch.pitch`, tempo preserved), sample-accurate **seek** (`scheduleSegment(startingFrame:)`
/// — which also lets an analog shared-album file start at the song's `startMs`), an equal-power
/// **crossfader** (per-deck player volume), four **effects** with a continuous per-deck **strength**,
/// and **beat-matching** (designate a Lead deck → Sync matches the follower's effective BPM via rate
/// + best-effort downbeat phase align). Runs on iPhone · iPad · Mac with no `#if os` gating of the
/// graph (only `AVAudioSession` is iOS-only).
///
/// App-scoped (`@Observable` env object) so deck state survives tab switches. Owns the `BurnStore`
/// so a deck resolves ONLY locally-burned files, holding each file's security scope while loaded.
/// Engine build is LAZY (`ensureEngine`, first use) so the realtime graph isn't spun up at launch.
@MainActor
@Observable
final class MixEngine {

    // MARK: Types

    /// The two decks. The rawValue ("A"/"B") labels the UI + namespaces node dictionaries.
    enum Deck: String, CaseIterable, Identifiable { case a = "A", b = "B"; var id: String { rawValue } }

    /// Which tap the deck's VU meter shows: PRE-fader (post-FX, before the volume+crossfader gain —
    /// gain-staging view, stays lit regardless of fader) or POST-fader (after volume×crossfade — what
    /// the deck actually contributes to the master). Toggled per deck via the meter's context menu.
    enum MeterSource: String, CaseIterable, Sendable { case pre, post }

    /// The four per-deck effects.
    enum Effect: String, CaseIterable, Identifiable {
        case compressor, reverb, flanger, filter
        var id: String { rawValue }
        var label: String {
            switch self {
            case .compressor: return "Comp"
            case .reverb:     return "Reverb"
            case .flanger:    return "Flanger"
            case .filter:     return "Filter"
            }
        }
        var icon: String {
            switch self {
            case .compressor: return "waveform.path.ecg"
            case .reverb:     return "dot.radiowaves.left.and.right"
            case .flanger:    return "wind"
            case .filter:     return "line.3.horizontal.decrease.circle"
            }
        }
    }

    /// Which cutoff shape the "Filter" FX sweeps — LOW-pass (strength cuts highs, classic DJ
    /// build-down) or HIGH-pass (strength cuts bass, classic DJ build-up). Toggled via the small
    /// LP/HP chip alongside the strength control; the effect's on/off + strength stay as they were.
    enum FilterMode: String, Codable, CaseIterable {
        case lowPass, highPass
        var label: String { self == .lowPass ? "LP" : "HP" }
    }

    /// The 3-band deck EQ (low shelf / mid peak / high shelf), always active — unlike `Effect` it
    /// has no on/off toggle, just a gain per band. `bandIndex` matches the fixed band order the
    /// per-deck `AVAudioUnitEQ(numberOfBands: 3)` is configured with once at build (see `ensureEngine`).
    enum EQBand: CaseIterable, Hashable {
        case low, mid, high
        var bandIndex: Int {
            switch self { case .low: return 0; case .mid: return 1; case .high: return 2 }
        }
        var label: String {
            switch self { case .low: return "Low"; case .mid: return "Mid"; case .high: return "High" }
        }
    }

    /// A deck's display payload — the view re-resolves artwork + waveform from this, so the engine
    /// stays free of catalog/UI types.
    struct LoadedTrack: Equatable {
        let songId: String
        let title: String
        let artist: String
        let bpm: Double?
        let camelot: String?
        let key: String?
        let albumId: String?
        /// Measured beat grid (from the rips manifest indexer), when available. `gridBpm` is
        /// preferred over the catalog `bpm` for beat-matching; `firstDownbeatMs` is the downbeat
        /// phase reference (relative to the song's 0:00); `steady` gates single-ratio sync. All
        /// default nil ⇒ the engine falls back to catalog bpm + a downbeat-at-0 assumption.
        var gridBpm: Double? = nil
        var firstDownbeatMs: Int? = nil
        var steady: Bool? = nil
        /// The full per-beat grid (ms from the song's 0:00) from the analysis sidecar, when it's been
        /// burned/fetched locally. Drives the phase-locked beat pulse on the EXACT measured beats
        /// (handles tempo-drifting tracks); nil ⇒ the pulse synthesizes beats from `gridBpm` +
        /// `firstDownbeatMs`. `downbeatsMs` ⊆ `beatsMs` marks the bar starts (brighter pulse).
        var beatsMs: [Int]? = nil
        var downbeatsMs: [Int]? = nil
    }

    /// One entry in an Auto-Mix queue: a loadable track plus its known length (ms).
    struct AutoMixItem: Equatable {
        let loadable: MixLoadable
        let durationMs: Int
        /// WHERE the track came from — the crate (pocket/set list) name a queue surface shows
        /// next to the row (two-crate Auto DJ provenance). nil for manual/legacy queue entries.
        let sourceLabel: String?
        init(loadable: MixLoadable, durationMs: Int, sourceLabel: String? = nil) {
            self.loadable = loadable
            self.durationMs = durationMs
            self.sourceLabel = sourceLabel
        }
    }

    /// Auto-DJ repeat: `.one` replays the on-air track (the next load slot re-queues the current
    /// item; the cursor never moves), `.all` wraps a drained queue back to its head instead of
    /// ending exhausted. Engine-scoped like the glide toggles (survives across mixes in-process)
    /// and persisted with the durable auto session.
    enum AutoRepeatMode: String, CaseIterable {
        case off, one, all
    }

    // MARK: Tunable ranges

    /// Tempo multiplier range (time-stretch, pitch preserved). 1.0 = original.
    /// `nonisolated` so the pure, `nonisolated` tempo math (`octaveFolded` / `syncRate`) can read
    /// it without hopping the main actor — an immutable `Sendable` constant is safe from any context
    /// (and silences the Swift 6 "main-actor-isolated static referenced from nonisolated" error).
    nonisolated static let rateRange: ClosedRange<Double> = 0.5...2.0
    /// Pitch range in semitones (frequency shift, tempo preserved). 0 = original.
    nonisolated static let pitchRange: ClosedRange<Double> = -12...12
    /// Deck volume range. 0…1 is attenuation; 1…2 is a **gain boost** to +6 dB (200%) applied on the
    /// deck's always-present TRIM node `globalGain`. A master peak limiter catches the resulting peaks.
    nonisolated static let volumeRange: ClosedRange<Double> = 0...2.0
    /// 3-band deck EQ gain range, in dB. 0 = flat.
    nonisolated static let eqRange: ClosedRange<Double> = -12...12

    /// The four stem parts — MATCH the burned file suffixes (`BurnStore` stem cache) so
    /// `localStemURLs` keys line up. The Mix stem grid + per-deck stem playback key on these.
    nonisolated static let stemNames = ["vocals", "drums", "bass", "other"]

    // MARK: Observable state

    private struct DeckState: Equatable {
        var loaded: LoadedTrack?
        var startMs: Int?
        var isPlaying = false
        var volume: Double = 1.0
        var rate: Double = 1.0       // tempo multiplier
        var pitch: Double = 0.0      // semitones
        /// The FX RACK: four positional slots, each holding any effect family + variety, with that
        /// effect's on/off + strength. DUPLICATES ARE LEGAL (two compressors, or a low-pass in one
        /// slot and a high-pass in another). Index == rack position; always exactly `slotCount`.
        /// Replaces the old flat `compressor/reverb/flanger/filter` bools + per-effect strengths.
        var slots: [FXSlot] = DeckState.defaultSlots
        /// Stem mode: when on (and the track has burned stems), the deck plays its 4 stems through
        /// the SAME effect chain + crossfader, with per-stem mute + level. Reset on load.
        var stemMode = false
        var stemMuted: Set<String> = []
        var stemVol: [String: Double] = [:]   // per-stem 0…1 (absent ⇒ 1.0)
        /// CUE / PFL: when on, this deck is ALSO sent (pre-fader) to the cue/monitor channel so you can
        /// pre-listen it without changing the house mix — standard pre-fade listen. `cueVol` is the
        /// independent monitor level for that send (0…1). Both survive a deck reset.
        var cued = false
        var cueVol: Double = 1.0
        /// LOOP (∞): when on, the deck repeats a window around the playhead forever until released.
        /// `loopUnits` is its LENGTH in the deck's natural unit — BEATS when the track has a usable
        /// grid (measured `beatsMs`, else a bpm to synthesize one), SECONDS when it has neither.
        /// Both are user intent ⇒ they ride the durable session; the resolved window is runtime
        /// plumbing (derivable from position + grid) and lives in `loopWindows`.
        var loopOn = false
        var loopUnits: Double = 2
        /// 3-band EQ gain in dB, always active (no on/off — 0 is flat/no-op). NOT part of the rack:
        /// the 3-band EQ is a permanent channel-strip control, not a swappable effect.
        var eqLow: Double = 0, eqMid: Double = 0, eqHigh: Double = 0

        /// The rack's size + its factory layout — the pre-rack grid order, so an existing user's
        /// decks look and sound exactly as they did before the rack shipped.
        static let slotCount = 4
        static let defaultSlots: [FXSlot] = [
            FXSlot(.compressor), FXSlot(.reverb), FXSlot(.flanger), FXSlot(.filter),
        ]

        func eqGain(_ b: EQBand) -> Double {
            switch b { case .low: return eqLow; case .mid: return eqMid; case .high: return eqHigh }
        }
        mutating func setEqGain(_ b: EQBand, _ db: Double) {
            switch b { case .low: eqLow = db; case .mid: eqMid = db; case .high: eqHigh = db }
        }

        /// Index of the first slot holding `e`, or nil if the rack has none of that family.
        func firstSlot(_ e: Effect) -> Int? { slots.firstIndex { $0.effect == e } }

        // MARK: Effect-keyed shims (FIRST-MATCH)
        //
        // The pre-rack API, kept so the effect-keyed surfaces (CarPlay, the TV app, the Now Playing
        // mini-panel, the Auto-DJ glide) keep working without knowing about slots. DELIBERATELY
        // LOSSY once a rack holds duplicates: a read is "ANY slot of this family", a write hits the
        // FIRST one. A rack with no slot of that family reads as off/default and ignores writes.
        // The Mix deck itself drives slots by INDEX (see `setSlot…`) and is never lossy.

        func isEnabled(_ e: Effect) -> Bool { slots.contains { $0.effect == e && $0.enabled } }
        func strength(_ e: Effect) -> Double { slots.first { $0.effect == e }?.strength ?? 0.5 }
        mutating func set(_ e: Effect, _ on: Bool) {
            guard let i = firstSlot(e) else { return }
            slots[i].enabled = on
        }
        mutating func setStrength(_ e: Effect, _ v: Double) {
            guard let i = firstSlot(e) else { return }
            slots[i].setStrength(v)
        }
    }

    private var deckA = DeckState()
    private var deckB = DeckState()
    /// True iff EITHER deck is playing — drives the bottom transport.
    private(set) var isRunning = false
    /// 0 = full A, 1 = full B. Equal-power; centered so both loaded decks are audible.
    private(set) var crossfader: Double = 0.5
    /// Which output channel the CUE monitor is panned to: true ⇒ cue on the RIGHT (main/house on the
    /// left); false ⇒ cue on the LEFT (main on the right). Mirrors the user's `SettingsStore` choice,
    /// pushed in from the view. Only audible while a deck is actually cued.
    private(set) var cueOnRight = true
    /// The designated LEAD deck for beat-matching (nil = none). The follower's Sync matches it.
    private(set) var leadDeck: Deck?
    /// True once the AVAudioEngine graph is built + running.
    var isReady: Bool { built }

    /// Per-deck playhead (source seconds) + length — SEPARATE stored properties (not in `DeckState`)
    /// so the ~10 Hz position updates invalidate ONLY the seek slider subview, not the whole deck.
    private(set) var positionA: Double = 0
    private(set) var positionB: Double = 0
    private(set) var durationA: Double = 0
    private(set) var durationB: Double = 0

    /// Per-deck VU-meter source (pre/post fader) — OBSERVABLE (rare user toggle; drives the context
    /// menu check + which mirror field the meter reads). Default post-fader: the meter sits directly
    /// above the volume slider, so it reads most intuitively as "what this fader is sending".
    private(set) var meterSourceA: MeterSource = .post
    private(set) var meterSourceB: MeterSource = .post

    // MARK: Auto-Mix (auto-DJ) — observable

    private(set) var autoEnabled = false
    private(set) var autoMixing = false
    /// True when the LAST auto-mix ended because the queue was exhausted (natural end / skip on the
    /// last track / resume with nothing unplayed) — NOT because the user stopped it. Runtime-only
    /// (never persisted): the collection downloader reads it to CONTINUE the mix when a track that
    /// finished downloading after the exhaustion lands. Cleared by any start, by a user Stop, and
    /// by any MANUAL deck load/play (the DJ took the decks — a landing must never seize them).
    private(set) var autoEndedExhausted = false
    /// Monotonic count of deck-touching calls (`load`/`play`/`playBoth`). The collection
    /// downloader's ZERO-START pickup captures it when ▶ arms the pending mix and refuses to
    /// fire if it moved since — any deck activity after the arm means the DJ took the decks by
    /// hand, and a background download landing must never seize them mid-performance.
    private(set) var deckGestureGeneration = 0
    /// PAUSED auto-mix: the DJ stepped away → hit Pause. The mix stays `autoMixing` (recording +
    /// playback keep running) but the TRANSITION machine is suspended so you can take the decks over by
    /// hand; Resume re-arms it. Distinct from `autoMixing=false` (a full Stop). See `pauseAuto`/`resumeAuto`.
    private(set) var autoPaused = false
    private(set) var autoStatus: String?
    /// FX GLIDE (auto-mix pill): when on, each auto-mix transition sweeps a coherent effect (held for a
    /// run of 3–5 transitions) IN on the outgoing deck, holds it across the crossfade on both decks,
    /// then sweeps it back OFF on the incoming deck. Read per-transition (a mid-mix toggle takes effect
    /// on the NEXT transition; an in-flight one finishes in the mode it began).
    private(set) var fxGlideEnabled = false
    /// MIX GLIDE (auto-mix pill): when on, each transition glides bpm+pitch (1 Camelot key = ±10% each,
    /// capped ±1 key) so the outgoing + incoming decks bend toward a shared key, with a best-effort
    /// downbeat align (beat sync), then the incoming settles back to its natural tempo/pitch.
    private(set) var mixGlideEnabled = false
    /// The collection name an auto-mix is running over (e.g. a pocket / set list). Lives on the
    /// app-scoped engine so the source label survives a Mix-tab teardown (the view-local `autoSource`
    /// picker is forgotten on tab switch, but the running mix — and this label — are not).
    private(set) var autoSourceLabel: String?

    // MARK: Studio (performance-item) seams — wired at app init from StudioStore; nil in tests.

    /// Resolve a performance item's local file (url + scope release + title + lengthMs). Lets a deck
    /// load samples/loops/sequences/instrumentals, which have no BurnStore file.
    @ObservationIgnored var studioResolve: ((String) -> (url: URL, release: (() -> Void)?, title: String, lengthMs: Int)?)?
    /// The item's beat grid + key for the LoadedTrack (bpm/firstDownbeat/beatsMs/camelot). The grid
    /// is derived from the item's KNOWN bpm; the key is on-device detected.
    @ObservationIgnored var studioMixInfo: ((String) -> (bpm: Double?, firstDownbeatMs: Int, beatsMs: [Int]?, camelot: String?)?)?
    /// PROFILE ("Pocket DJ") seam (wired at app init to `ProfileSourceStore.localURLForPlayback`):
    /// resolve a `pdj_` id to its device-local original. `release` is always nil (app-managed audio,
    /// no security scope). nil ⇒ absent local file ⇒ the deck load is skipped.
    @ObservationIgnored var profileResolve: ((String) -> (url: URL, release: (() -> Void)?, title: String, lengthMs: Int)?)?
    /// Stage 7 seam (wired at app init to `ProfileSourceStore.stemURLs`): a "Pocket DJ" profile
    /// item's 4 app-managed stem URLs (release-less), else nil.
    @ObservationIgnored var profileStemResolve: ((String) -> [String: URL]?)?

    // MARK: Private — graph

    @ObservationIgnored private let burns: BurnStore
    /// `var` (not `let`): after a media-services reset every node — including the engine itself —
    /// is orphaned and must be recreated (`rebuildAfterMediaReset`).
    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var built = false
    @ObservationIgnored private var players: [Deck: AVAudioPlayerNode] = [:]
    /// Per-deck normalizing mixer right after the player. `player → inputMixer` carries the FILE's
    /// format (mono/stereo, any sample rate) and is the ONLY link reconnected per load; everything
    /// downstream stays pinned at canonical stereo so the effect AUs never see a live channel/SR
    /// reconfiguration (which AVAudioEngine asserts-and-hard-crashes on). The mixer up/down-mixes
    /// and resamples each file into canonical.
    @ObservationIgnored private var inputMixers: [Deck: AVAudioMixerNode] = [:]
    @ObservationIgnored private var timePitches: [Deck: AVAudioUnitTimePitch] = [:]
    /// Always-active 3-band deck EQ (low shelf / mid peak / high shelf). NOT part of the FX rack —
    /// it's a permanent channel-strip control, always in the chain, never bypassed.
    @ObservationIgnored private var eqs: [Deck: AVAudioUnitEQ] = [:]

    /// Every effect TYPE, pre-built, for ONE rack slot. Exactly one is un-bypassed at a time, so
    /// swapping a slot's effect is a BYPASS FLIP — the graph is never rewired (see `connectChain`,
    /// whose whole contract is "connected once at build"). That's what makes a mid-mix swap
    /// glitch-free: no detach/attach, no format renegotiation, no schedule invalidation.
    ///
    /// The internal order (comp → filter → reverb → mod) is arbitrary and inaudible: at most one of
    /// the four is ever active, so they can't colour each other.
    private final class SlotNodes {
        let comp: AVAudioUnitEffect
        let filter: AVAudioUnitEQ
        let reverb: AVAudioUnitReverb
        let mod: AVAudioUnitDelay
        /// The reverb preset currently loaded. `loadFactoryPreset` rebuilds the tail, and `applySlot`
        /// runs at ~10 Hz through an Auto-DJ FX glide — so only reload when the variant ACTUALLY
        /// changed, never once per tick.
        var loadedPreset: EffectVariant?

        init(dynamicsDesc: AudioComponentDescription) {
            comp = AVAudioUnitEffect(audioComponentDescription: dynamicsDesc)
            filter = AVAudioUnitEQ(numberOfBands: 1)
            reverb = AVAudioUnitReverb()
            mod = AVAudioUnitDelay()
            reverb.loadFactoryPreset(FXParams.reverbPreset(.hall))
            loadedPreset = .hall
        }
        /// Fixed serial order within the slot.
        var ordered: [AVAudioNode] { [comp, filter, reverb, mod] }
    }
    /// The rack: `DeckState.slotCount` node bundles per deck, in rack order.
    @ObservationIgnored private var slotNodes: [Deck: [SlotNodes]] = [:]
    /// Modulation runtime mirrors — the CURRENT per-slot LFO phase (nil = nothing to lock to) and
    /// per-deck envelope level, maintained by the mod tick / envelope tap and read by
    /// `effectiveStrength`. NON-OBSERVABLE plumbing (PlayerClock doctrine): these change at up to
    /// 60 Hz and must never invalidate SwiftUI; the user's `slots[i].mod`/`strength` stay the only
    /// observable truth. Empty until the mod tick lands (commit 5) — `effectiveStrength` reads
    /// nil/0 ⇒ identity, so this refactor is behaviour-neutral.
    @ObservationIgnored private var modPhaseMirror: [Deck: [Double?]] = [:]
    @ObservationIgnored private var envMirror: [Deck: Double] = [:]
    /// The ~60 Hz modulation driver — a SECOND task, deliberately separate from the 10 Hz
    /// `tickTask` (which also persists, recovers, and runs the Auto-DJ; none of that belongs at
    /// 60 Hz). Self-terminating like its sibling: exits when no rendering deck has a live
    /// modulated slot, restarted by the same sites that start the main tick plus `setSlotMod`.
    @ObservationIgnored private var modTask: Task<Void, Never>?
    /// Last strength actually written per (deck, slot) — the dead-band that keeps a idle LFO
    /// (depth 0 / flat envelope) from spamming identical AU writes. -1 = never written.
    @ObservationIgnored private var modLastWritten: [Deck: [Double]] = [:]
    /// Per-deck phase-clock state for the mod tick: `truePlayhead` is sample-accurate but nil in
    /// stem mode / while paused, and the 10 Hz `position` accumulator alone would quantize the LFO
    /// phase (~21% of a beat at 128 BPM). Between position changes we extrapolate wall-clock ×
    /// rate, clamped to a little over one main-tick period so a stalled engine can't run away.
    @ObservationIgnored private var modClockLastPos: [Deck: Double] = [:]
    @ObservationIgnored private var modClockStamp: [Deck: Double] = [:]
    /// True while the tick has live modulated values on a deck — the snap-back flag: when the deck
    /// stops or its last modulated slot turns off, one `applyAllSlots` lands the nodes exactly on
    /// the user's stored strengths (otherwise they'd freeze mid-wobble).
    @ObservationIgnored private var modWasActive: [Deck: Bool] = [:]
    /// Per-deck TRIM — a 1-band EQ whose band is permanently bypassed, used ONLY as a `globalGain`
    /// carrier for the >unity volume boost (`applyBoost`). Pre-rack that gain rode the deck's filter
    /// EQ, which can't work once "filter" is a swappable slot effect that may not be in the rack at
    /// all. Sits at the END of the chain but UPSTREAM of the main/cue split, exactly where the old
    /// filter node sat relative to the split — so `applyCueRouting`'s boost divide-out stays valid.
    @ObservationIgnored private var trims: [Deck: AVAudioUnitEQ] = [:]
    /// Per-deck output split — the standard DJ channel-strip model. After the effect chain the deck's
    /// post-FX signal fans into two sends (so it follows conventional mixer signal flow, which keeps it
    /// easy to extend):
    ///   • `mainGains[d]` — the CHANNEL FADER feeding the main/house mix: `outputVolume` = the deck's
    ///     volume × the equal-power crossfade factor. This is the only thing the audience hears.
    ///   • `cueGains[d]` — a PRE-FADER PFL (cue) send feeding the monitor/cue bus: `outputVolume` =
    ///     the deck's independent `cueVol` when cued, else 0. Untouched by the channel fader/crossfader,
    ///     so you can pre-listen a deck at any level without changing the house mix.
    /// Both sends sum at `mainMixerNode`; while any deck is cued they pan hard to opposite output
    /// channels (main vs `cueOnRight`) so a stereo interface carries house on one side, cue on the
    /// other. Centered when nothing is cued ⇒ an un-cued mix is bit-identical normal stereo.
    @ObservationIgnored private var mainGains: [Deck: AVAudioMixerNode] = [:]
    @ObservationIgnored private var cueGains: [Deck: AVAudioMixerNode] = [:]
    /// The clean HOUSE SUM — both decks' `mainGains` merge here in NORMAL stereo (no cue pan), and
    /// this is where an audio RECORDING taps. `houseSum → housePan → mainMixerNode`: the cue-side hard
    /// pan (that collapses the house to one output channel while monitoring) lives on `housePan`,
    /// DOWNSTREAM of the tap — so a recording made while a deck is cued still captures the clean stereo
    /// house mix (the audience's mix) instead of the mono-collapsed house + private cue bleed.
    @ObservationIgnored private var houseSum: AVAudioMixerNode?
    @ObservationIgnored private var housePan: AVAudioMixerNode?
    /// Master peak limiter on the output bus (built in `ensureEngine`) — the safety net for the
    /// >unity volume boost so two loud decks can't clip the device.
    @ObservationIgnored private var masterLimiter: AVAudioUnitEffect?
    @ObservationIgnored private var files: [Deck: AVAudioFile] = [:]
    /// The song's playback WINDOW within the file, in frames: `[startFrames, endFrames)`. For a
    /// per-song cut this is the whole file; for an analog shared-album fallback it is the song's
    /// `[startMs, startMs+lengthMs)` slice (so the deck stops at the song boundary, not end-of-side).
    @ObservationIgnored private var startFrames: [Deck: AVAudioFramePosition] = [:]
    @ObservationIgnored private var endFrames: [Deck: AVAudioFramePosition] = [:]
    @ObservationIgnored private var sampleRates: [Deck: Double] = [:]
    /// The SOURCE-seconds offset at which the player's CURRENT scheduled segment begins (0 on load /
    /// restart, the seek target on seek). `player.playerTime.sampleTime` resets to 0 on every
    /// `scheduleSegment`, so `truePlayhead` adds this back to recover absolute source position.
    @ObservationIgnored private var segmentStartSeconds: [Deck: Double] = [:]
    /// Mirrors the Mix beat-pulse setting (pushed from the view). Gates the on-load DOWNLOAD of a
    /// track's per-beat sidecar — when the pulse is off we never fetch a grid a track lacks.
    @ObservationIgnored private var beatPulseEnabled = false
    @ObservationIgnored private var releases: [Deck: () -> Void] = [:]
    @ObservationIgnored private var paths: [Deck: String] = [:]
    /// Four stem player nodes per deck, all summing into the deck's `inputMixer` (so they ride the
    /// same tempo/pitch/effect/crossfader chain as the main file). Idle until stem mode wires real
    /// files; their burn-folder scope is held in `stemReleases`.
    @ObservationIgnored private var stemPlayers: [Deck: [String: AVAudioPlayerNode]] = [:]
    @ObservationIgnored private var stemFiles: [Deck: [String: AVAudioFile]] = [:]
    @ObservationIgnored private var stemReleases: [Deck: () -> Void] = [:]
    #if os(iOS)
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaResetObserver: NSObjectProtocol?
    /// Interruption `.began` actually parked a LIVE mix, so `.ended` may auto-resume it. Without
    /// this, `.ended`+shouldResume replays a STALE in-app pause memory (remotePause's idempotency
    /// guard deliberately preserves `masterPausedDecks`) or starts a loaded-but-never-played deck
    /// via `resumeMasterPaused`'s now-playing fallback.
    @ObservationIgnored private var interruptionParked = false
    #endif
    /// Observer for `.AVAudioEngineConfigurationChange` — registered PER ENGINE INSTANCE (the
    /// notification's object is the engine), so a media-reset rebuild re-registers it.
    @ObservationIgnored private var configChangeObserver: NSObjectProtocol?
    /// Device-switch / recovery diagnostics. ~1 info line per second while a deck plays, plus one
    /// line per recovery event — invisible cost unless collected:
    ///   log stream --predicate 'subsystem == "com.levi.pocketdj"' --info
    @ObservationIgnored private static let diag = Logger(subsystem: "com.levi.pocketdj", category: "mixdiag")
    private func dlog(_ s: String) {
        Self.diag.info("\(s, privacy: .public)")
        MixDiag.shared.append(s)     // no-op unless a Settings ▸ Debug capture session is running
    }
    @ObservationIgnored private let tapPulse = MixTapPulse()
    /// Per-deck VU level mirrors — written by the pre/post-fader taps installed in `ensureEngine`,
    /// read by the meter's `TimelineView`. Persist across a media-services rebuild (the taps are
    /// re-installed onto fresh nodes but keep writing these same objects).
    @ObservationIgnored private let levelsA = MixDeckLevels()
    @ObservationIgnored private let levelsB = MixDeckLevels()
    @ObservationIgnored private var lastDiagHeartbeat: Date?
    /// Throttles the steady-state Now Playing card rewrite to ~1 Hz inside the 10 Hz tick.
    @ObservationIgnored private var lastCardRefresh: Date?
    @ObservationIgnored private var lastRenderingDiag: Bool?
    /// Wall-clock moment the tick watchdog first saw the engine stopped while the mix thinks it's
    /// live. Parks the auto-machine clocks (mirroring `remotePausedAt`) so a stall never burns a
    /// track's runway or fires a transition into a dead engine; recovery shifts them forward.
    @ObservationIgnored private var engineStallAt: Date?
    /// Last engine-recovery attempt — rate-limits the tick watchdog's restart tries to ~1/s.
    @ObservationIgnored private var lastEngineRecoveryAttempt: Date?
    /// The engine was seen down (or reconfigured — config change) while the mix was live. The next
    /// RENDERING tick re-primes the playing decks: a node that played through an engine stop can
    /// come back as a ZOMBIE (claims playing, renders silence) that only a pause()+play() revives —
    /// and the engine can restart via ANY path (watchdog, observer, a transport call, macOS itself).
    @ObservationIgnored private var engineDownWhileLive = false

    /// Single ~10 Hz driver: advances each playing deck's playhead AND steps the auto-mix crossfade.
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastTickAt: Date?

    // Auto-Mix machine (Date/wall-clock based; it only drives the public transport, independent of the
    // audio backend).
    @ObservationIgnored private var autoQueue: [AutoMixItem] = []
    @ObservationIgnored private var autoLivePos = 0
    @ObservationIgnored private var autoNextToLoad = 0
    @ObservationIgnored private(set) var autoLiveDeck: Deck = .a
    /// The repeat mode (observable — the TV toggle renders it). See `AutoRepeatMode`.
    private(set) var autoRepeat: AutoRepeatMode = .off
    /// Transition-scoped: the in-flight crossfade was begun by the repeat-one lane — its finish
    /// must FREEZE the cursor (no livePos/nextToLoad advance; the mix replays the same slot).
    /// Stamped at begin so a mid-fade mode change can't desync the finish from what's loaded.
    @ObservationIgnored private var autoTransitionRepeatOne = false
    /// Transition-scoped twin for repeat-all: the crossfade wraps into queue[0] — its finish
    /// resets the cursor to the head instead of advancing.
    @ObservationIgnored private var autoTransitionWrap = false
    @ObservationIgnored private var autoDeckEndsAt: [Deck: Date] = [:]
    @ObservationIgnored private var autoDeckDurationMs: [Deck: Int] = [:]
    @ObservationIgnored private var autoFadeStartedAt: Date?
    @ObservationIgnored private var autoFadeFrom: Deck = .a
    @ObservationIgnored private var autoLeadSeconds: Double = 15
    @ObservationIgnored private var autoFadeSeconds: Double = 3
    /// When a one-off manual Skip sets a custom fade length, the baseline `autoFadeSeconds` to put
    /// back once that crossfade finishes — so a fast 5 s skip never shortens the NEXT automatic
    /// crossfade. nil when no restore is pending.
    @ObservationIgnored private var pendingFadeRestore: Double?
    /// RESUME-with-both-decks-active handoff: when Resume finds two decks playing (a manual blend), the
    /// auto machine must wait for the FIRST (soonest-ending) deck to finish, then hand off from the
    /// SURVIVOR to the next unplayed track. This holds that soonest-ending deck; the idle tick watches
    /// it and, the moment it ends, retires it, loads the next track onto it, and glides the survivor
    /// over. nil in the normal single-live-deck case.
    @ObservationIgnored private var autoResumeEndDeck: Deck?
    /// Set by `restoreAutoSuspended`: the machine was rebuilt from a DURABLE SNAPSHOT, so the
    /// FIRST resume must trust the restored cursor + the standby deck's cued track over a
    /// played-log re-derivation. The session log SURVIVES relaunches (a session lasts until
    /// Reset), and `beginAutoCrossfade` marks the incoming track played at fade START — so a
    /// kill mid-transition leaves the still-cued on-deck track "played", and the resume's
    /// next-unplayed scan skips it and loads one slot further, consuming one upcoming track
    /// per relaunch (field: TV build 1788406415, "it skips to the next song when you relaunch
    /// the app"). Consumed by the next `resumeAuto`; dies with the machine.
    @ObservationIgnored private var autoResumeFromRestore = false

    // MARK: Auto-Mix — glide transition phases (FX Glide + Mix Glide)

    /// A transition layers optional PRE-ROLL (ramp glide in on the outgoing deck, before the volume
    /// sweep) and POST-ROLL (ramp glide back off on the incoming deck, after the sweep) around the
    /// existing crossfade. Non-nil ⇒ that phase is active; the crossfade proper still uses
    /// `autoFadeStartedAt`. With no glide feature on, neither is ever set (⇒ behavior is unchanged).
    @ObservationIgnored private var autoPrerollStartedAt: Date?
    @ObservationIgnored private var autoPostrollStartedAt: Date?
    /// This transition's preroll length (s) — capped so preroll + fade fit the outgoing runway.
    @ObservationIgnored private var glideInSecondsActive: Double = 0
    /// True while the IN-FLIGHT transition is a glide (captured at its start, so a mid-transition toggle
    /// of FX/Mix Glide can't corrupt a transition that already began).
    @ObservationIgnored private var autoTransitionIsGlide = false
    /// The in-flight transition's glide parameters (effect + peak, per-deck tempo/pitch targets, and
    /// the effect state to restore afterward). nil between transitions.
    @ObservationIgnored private var glideCtx: GlideContext?

    /// FX Glide texture coherence: the current effect + peak strength held for `fxTextureRunRemaining`
    /// more transitions (a run of 3–5), then re-rolled. Seeded per auto-mix so it's deterministic.
    @ObservationIgnored private var fxTextureEffect: Effect?
    @ObservationIgnored private var fxTexturePeak: Double = 0.6
    @ObservationIgnored private var fxTextureRunRemaining = 0
    @ObservationIgnored private var fxGlidePrng: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// GLIDE LENGTH (s): how long the tempo/pitch/effect eases IN on the outgoing deck (pre-roll) and
    /// back OUT on the incoming deck (post-roll) — a longer value = a smoother, more gradual glide.
    /// User-configurable (Settings ▸ Mix, default 10), pushed in via `setMixGlideSeconds`. The pre-roll
    /// is additionally capped to the runway left before the outgoing track ends.
    @ObservationIgnored private var mixGlideSeconds: Double = 10

    /// Set the glide length (Settings ▸ Mix). Clamped to a sane floor.
    func setMixGlideSeconds(_ s: Double) { mixGlideSeconds = max(0.5, s) }

    /// Mirror of Settings ▸ Mix "Skip fade" (pushed in by MixView) — the lock-screen ⏮ slow-skip length.
    func setSkipFadeSeconds(_ s: Double) { skipFadeSeconds = max(1, s) }

    /// Per-transition glide parameters, snapshotted when a glide transition begins.
    private struct GlideContext {
        let from: Deck, to: Deck
        // FX Glide
        let fxOn: Bool
        /// The rolled texture — kept for the timeline (`param`), not for addressing a node.
        let fxEffect: Effect
        /// The RACK SLOT the glide sweeps on each deck. Resolved per-deck at transition time, so the
        /// two decks can differ (their racks are independent), and nil when that deck's rack holds
        /// nothing sweepable — a rack of four compressors is a legitimate choice, not a bug, and
        /// simply means no FX glide on that deck.
        let fxSlotFrom: Int?
        let fxSlotTo: Int?
        let fxPeak: Double
        let savedFrom: (on: Bool, strength: Double)   // outgoing deck's pre-glide state for its slot
        let savedTo: (on: Bool, strength: Double)      // incoming deck's pre-glide state for its slot
        // Mix Glide (1.0 rate / 0 pitch ⇒ no harmonic glide on that deck)
        let mixOn: Bool
        let outRate: Double, outPitch: Double          // outgoing target (held across the crossfade)
        let inRate: Double, inPitch: Double            // incoming start (ramps → natural in the postroll)
    }

    /// Per-deck flag: do the 4 stem nodes currently hold a live scheduled segment? Set by
    /// `scheduleStems` (true when anything scheduled), cleared by `stopStemNodes`/`stopActiveNodes`
    /// (which `stop()` the nodes, discarding the schedule). A `pause()` keeps the schedule, so this
    /// stays true across a pause — letting `play()` resume vs. reschedule correctly.
    @ObservationIgnored private var stemsScheduled: [Deck: Bool] = [:]

    /// Per-deck flag: does the MAIN player node hold a schedule we can TRUST? Set by every real
    /// scheduling site (`loadFile` / `seek` / `restart` / `scheduleLoopPasses` / the stem-mode-off
    /// re-prime / `rescheduleFile`), cleared by `stopActiveNodes` — and marked UNTRUSTED where the
    /// OS may drop a schedule behind our back: a materialized session restore (tvOS flushes the
    /// never-rendered cues when the first `engine.start()` renegotiates the output — field session
    /// tvos-95F9E8D4: Resume rendered 10 s of "playing" silence until a skip's fresh load healed
    /// it) and an `.AVAudioEngineConfigurationChange` (the engine uninitializes). A `pause()`
    /// keeps the schedule, so a normal pause→resume stays trusted and never restart-glitches.
    @ObservationIgnored private var fileScheduled: [Deck: Bool] = [:]
    /// Count of ensure-triggered re-arms (`ensureDeckScheduled` actually rebuilding a schedule) —
    /// never counts a load/seek/restart's own scheduling. Test seam for the silent-resume guard.
    @ObservationIgnored private(set) var deckRescheduleCountForTesting = 0

    /// One-time guard so the shared remote-command center is wired exactly once per engine.
    @ObservationIgnored private var remoteCommandsConfigured = false

    /// Resolves a song id to its cover-art URLs — same seam `PlayerEngine` uses, injected once
    /// at launch from the catalog (async: the streaming fallback resolves through MusicKit).
    /// Lets the Mix's lock-screen card show art too.
    @ObservationIgnored var artworkURLsProvider: (@MainActor (String) async -> [URL])?
    /// The now-playing card's fetched artwork + which song it belongs to. `updateSystemNowPlaying`
    /// fires on every position tick, so the fetch must be gated on the song id actually CHANGING —
    /// unlike `PlayerEngine.load`, there's no natural "track changed" call site to hook here.
    @ObservationIgnored private var nowPlayingArtworkSongId: String?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkToken = 0

    /// The deck(s) the last master pause (`pauseBoth`) actually silenced. The LOCK-SCREEN ▶ resumes
    /// exactly these — pausing a one-deck mix from the lock screen and hitting play again must bring
    /// back just that deck, never surprise-start the other loaded deck. In-app behavior is untouched:
    /// the master transport button keeps its explicit "Play both decks" semantics (`playBoth`).
    @ObservationIgnored private var masterPausedDecks: Set<Deck> = []
    /// The user's Settings ▸ Mix "Skip fade" length (seconds) — mirrored in by MixView so the
    /// lock-screen ⏮ (slow skip) matches the in-app single-tap Skip exactly. Default mirrors
    /// SettingsStore's own default.
    @ObservationIgnored private var skipFadeSeconds: Double = 15
    /// Non-nil ⟺ the auto machine's WALL CLOCK is frozen by a remote pause. The in-app `pauseAuto`
    /// keeps audio playing, so letting an in-flight pre-roll/fade complete there is correct — but the
    /// remote pause SILENCES the decks, and an unfrozen transition timer would fire `beginAutoCrossfade`
    /// seconds into the pause and audibly un-pause the locked phone. While set, `autoFire` is a no-op;
    /// `remotePlay`/`remoteSkip` shift every armed timestamp forward by the frozen interval so the
    /// machine resumes exactly where it stopped (a half-swept fade stays half-swept).
    @ObservationIgnored private var remotePausedAt: Date?
    /// Gates the sticky `lastNowPlayingDeck` update during BATCH transport (pauseBoth / playBoth /
    /// resumeMasterPaused): those silence/start the decks one at a time, and the intermediate
    /// "exactly one playing" states would rewrite the card's subject mid-batch — the exact
    /// pause-flips-the-card bug the sticky memory exists to prevent.
    @ObservationIgnored private var suppressStickyUpdates = false

    init(burns: BurnStore) { self.burns = burns }

    // MARK: - Session recording

    /// The mix-session log sink (the app's `MixSessionStore`). Weak so the engine never retains the
    /// app graph; nil ⇒ recording is a no-op (tests, before wiring).
    @ObservationIgnored weak var recorder: MixSessionRecorder?
    /// Play-stats hook (the storage manager's LRP prune signal): fired alongside
    /// `recorder?.notePlayed` whenever a deck transitions to playing. Wired at app init
    /// to `PlayStatsStore.notePlayed`; nil in tests.
    @ObservationIgnored var onSongPlayed: ((String) -> Void)?

    // MARK: - Durable mix-deck session (state)

    /// The durable mix-deck snapshot store (`pocketdj-mix-decks.json`) — phase 2 of durable
    /// playback sessions. Wired at app init (nil in tests until set); every structural deck /
    /// auto-queue change persists through it in real time so a force-quit restores the Mix tab.
    @ObservationIgnored var sessionStore: MixDeckSessionStore?
    /// The snapshot read at launch, parked here WITHOUT touching audio. Materialized lazily —
    /// the first Mix-tab appearance (or the launch task, if the tab is already up, e.g. macOS
    /// lands on Mix) actually re-loads the decks. Dropped by any real deck action that beats
    /// materialization (an intent-started auto-mix, a manual load).
    @ObservationIgnored private var pendingMixRestore: MixDeckSessionStore.Snapshot?
    /// The Mix tab already asked to materialize (its `.task` can run BEFORE RootView's launch
    /// task on macOS, where Mix is the landing tab) — so `restorePersistedMixIfIdle` finishes
    /// the job the moment the snapshot is read instead of waiting for a tab re-visit.
    @ObservationIgnored private var materializeWanted = false
    /// True while a restore is materializing: suppresses session-log recording, persist
    /// re-entry, and system Now Playing card writes (the one-audio-owner rule — a restore
    /// claims no card; the card belongs to whoever is actually sounding, and nobody is).
    @ObservationIgnored private var isRestoringMixSession = false

    /// Emit one session event for a deck (or global) action, stamping the deck's loaded song + its
    /// current playhead. The store owns the timeline (t0/tMs), coalescing, and persistence.
    private func rec(_ kind: MixEventKind, _ deck: Deck? = nil, param: String? = nil,
                     value: Double? = nil, flag: Bool? = nil, slot: Int? = nil) {
        guard let recorder else { return }
        let l = deck.flatMap { state($0).loaded }
        let posMs = deck.map { Int(position($0) * 1000) }
        recorder.logEvent(kind, deck: deck?.rawValue, songId: l?.songId, title: l?.title,
                          artist: l?.artist, bpm: nil, camelot: nil, param: param,
                          value: value, flag: flag, posMs: posMs, slot: slot)
    }

    /// The SINGLE transport funnel — set a deck's playing flag, recording `.play` (+ marking the
    /// song played) / `.pause` ONLY on an actual transition. Routing every start/stop (manual,
    /// master, auto-DJ, natural track-end) through here logs each exactly once; an idempotent
    /// re-issue (e.g. seek/restart while already playing) records nothing.
    private func setPlaying(_ deck: Deck, _ playing: Bool) {
        let was = state(deck).isPlaying
        mutate(deck) { $0.isPlaying = playing }
        guard playing != was else { return }
        if playing {
            NowPlayingArbiter.shared.claim(self)   // a Mix deck started → own the lock-screen card
            rec(.play, deck)
            if let id = state(deck).loaded?.songId {
                recorder?.notePlayed(songId: id)
                onSongPlayed?(id)
            }
        } else {
            rec(.pause, deck)
        }
        // Track the last UNAMBIGUOUS card subject (exactly one deck playing) so `nowPlayingDeck`
        // stays sticky across pauses/blends — the card must not flip decks just because you paused.
        // Suppressed during batch transport: pauseBoth/playBoth walk the decks sequentially and their
        // INTERMEDIATE one-playing states are artifacts, not the user's card subject.
        let aOn = state(.a).isPlaying, bOn = state(.b).isPlaying
        if aOn != bOn, !suppressStickyUpdates { lastNowPlayingDeck = aOn ? .a : .b }
        updateSystemNowPlaying()                    // reflect the new play state / now-playing deck
        // Land the freshest playheads on a play/pause transition (immediate through the store's
        // run/pause detector — a restore must cue at the PAUSED position, not one 5 s stale).
        persistMixPositions()
    }

    // MARK: - Audio recording (capture the mixed house output)

    /// True while a live audio capture is running (drives the pulsing record button). App-scoped like
    /// the engine, so it survives a Mix-tab teardown — a recording keeps running when you leave the tab.
    private(set) var isRecording = false
    /// The PERSISTENT recording sink: its tap is installed ONCE on `houseSum` (in `ensureEngine`) and
    /// never removed — start/stop just toggle a capture flag. Installing/removing a tap on a node in the
    /// live render path mid-playback reconfigures the graph and can pause the player nodes on-device, so
    /// the tap stays put and recording is gated inside it instead.
    @ObservationIgnored private let recordingSink = MixTapSink()
    /// The session-folder security-scope release held for the WHOLE capture (nil ⇒ app storage).
    @ObservationIgnored private var recordingRelease: (() -> Void)?
    /// One-shot per take: the sink's writer FAILED PERMANENTLY (disk full / the session folder's
    /// provider died). Wired by `MixRecorder` to auto-stop and file the partial take — the
    /// fragments up to the failure are durable; without this the tap drops every later buffer
    /// silently while the UI keeps pulsing "recording". Also fired by the media-reset rebuild.
    @ObservationIgnored var onRecordingFailed: (() -> Void)?
    /// Seconds of MEDIA actually appended to the current take — the take's CONTENT clock (wall
    /// clock minus stalls/drops). Feeds the recorder's duration metadata + liveness watchdog.
    var recordingAppendedSeconds: Double { recordingSink.appendedSeconds }

    /// Begin capturing the fully-mixed HOUSE output to `url` as AAC (`.m4a`) — just toggles the
    /// already-installed `houseSum` tap's capture flag (no graph change → playback is untouched).
    /// Buffers are copied + written OFF the realtime thread so AAC encoding never stalls audio.
    /// `release` is the session-folder security scope, which this method OWNS: held for the whole
    /// capture, dropped on `stopRecording()`; on failure it's dropped immediately. Returns false if the
    /// graph isn't built, a capture is already running, or the file can't be opened.
    ///
    /// The tap sits on `houseSum` (the clean stereo house mix, BEFORE the cue-side pan + the cue send),
    /// so a capture is the audience's mix even while you monitor a deck in the cue/headphones. It is
    /// pre-master-limiter, so a two-deck >unity boost could in theory clip the take (a rare edge; the
    /// output itself is still limiter-protected).
    @discardableResult
    func startRecording(to url: URL, release: (() -> Void)?) -> Bool {
        ensureEngine()
        guard built, !isRecording, let node = houseSum else { release?(); return false }
        let format = node.outputFormat(forBus: 0)                 // canonical 44.1 kHz stereo float
        guard recordingSink.begin(url: url, sampleRate: format.sampleRate,
                                  channels: format.channelCount) else { release?(); return false }
        recordingRelease = release
        isRecording = true
        dlog("rec: START run=\(engine.isRunning ? 1 : 0)")
        return true
    }

    /// Stop an in-progress capture: flip off the sink's flag (the tap stays installed → no graph
    /// reconfiguration, so playback keeps running), finalize the file, and drop the session-folder
    /// scope — but only AFTER the async finalize completes: releasing a provider folder's security
    /// scope mid-`finishWriting` can fail the fragmented file's tail write. No-op if not recording.
    func stopRecording() {
        guard isRecording else { return }
        dlog("rec: STOP appended=\(String(format: "%.1f", recordingAppendedSeconds))s")
        let release = recordingRelease
        recordingRelease = nil
        isRecording = false
        recordingSink.end {
            if let release { DispatchQueue.main.async { release() } }
        }
    }

    // MARK: - Lifecycle

    /// Build the two-deck graph ON FIRST USE and start the engine. Idempotent.
    func ensureEngine() {
        guard !built else { return }
        // Session activation includes tvOS (mirroring PlayerEngine's fence): without an active
        // .playback session the TV suspends MIX audio the moment the app backgrounds — the
        // sequencer survived (its engine already activated) while the mix died (Levi, live TV
        // 2026-09-02). The interruption/route/media-reset observers stay iOS-only: their
        // recovery choreography is tuned to iOS session semantics, and widening them is not
        // tonight's bug.
        #if canImport(UIKit) && !os(macOS)
        activateAudioSession()
        #endif
        #if os(iOS)
        registerInterruptionHandling()
        registerRouteChangeHandling()
        registerMediaResetHandling()
        #endif
        let canonical = Self.canonicalFormat
        // The shared clean house-sum + its downstream cue-pan node (see the `houseSum` doc). Built once.
        let hSum = AVAudioMixerNode(); let hPan = AVAudioMixerNode()
        engine.attach(hSum); engine.attach(hPan)
        houseSum = hSum; housePan = hPan
        for d in Deck.allCases {
            let player = AVAudioPlayerNode()
            let inputMixer = AVAudioMixerNode()
            let tp = AVAudioUnitTimePitch()
            let eq3 = AVAudioUnitEQ(numberOfBands: 3)  // always-active 3-band low/mid/high gain EQ
            Self.configureEQ3(eq3)
            // The FX RACK: one bundle of every effect type per slot. All pre-allocated and wired
            // now, once — a slot swap only flips bypass flags (see `SlotNodes`).
            let rack = (0..<DeckState.slotCount).map { _ in SlotNodes(dynamicsDesc: Self.dynamicsDesc) }
            let trim = AVAudioUnitEQ(numberOfBands: 1)   // volume-boost `globalGain` carrier only
            trim.bands.first?.bypass = true
            let mainGain = AVAudioMixerNode()      // deck → main/house channel (crossfade factor)
            let cueGain = AVAudioMixerNode()       // deck → cue channel (full, only while cued)
            let rackNodes = rack.flatMap(\.ordered)
            for n in [player, inputMixer, tp] + rackNodes + [eq3, trim, mainGain, cueGain] as [AVAudioNode] {
                engine.attach(n)
            }
            // `player → inputMixer` carries the file's real format (set per load); the mixer converts
            // it into canonical stereo. The effect chain below it is pinned at canonical FOR LIFE, so
            // loading a mono / 48 kHz / odd file never reconfigures (and crashes) a live AU.
            engine.connect(player, to: inputMixer, format: canonical)
            connectChain(d, nodes: [inputMixer, tp] + rackNodes + [eq3, trim])
            // Split the deck's post-FX output (trim) into the main + cue buses, both → master. The
            // crossfade/cue levels + pans live on these two mixers (see `applyCueRouting`); the chain
            // above is untouched so stems (which merge at `inputMixer`) ride the split for free.
            engine.connect(trim, to: [AVAudioConnectionPoint(node: mainGain, bus: 0),
                                      AVAudioConnectionPoint(node: cueGain, bus: 0)],
                           fromBus: 0, format: canonical)
            // House send: `mainGain → houseSum` (clean stereo, tapped for recording); the cue-pan is
            // applied downstream on `housePan`. The cue send goes straight to the master mix.
            engine.connect(mainGain, to: hSum, format: canonical)
            engine.connect(cueGain, to: engine.mainMixerNode, format: canonical)
            players[d] = player; inputMixers[d] = inputMixer; timePitches[d] = tp
            eqs[d] = eq3; slotNodes[d] = rack; trims[d] = trim
            mainGains[d] = mainGain; cueGains[d] = cueGain
            // Four stem player nodes summing into the SAME inputMixer → they pass through the deck's
            // tempo/pitch/effects/crossfader exactly like the main file. Idle (canonical format) until
            // stem mode wires real files, which reconnects each at its own file format.
            var stemNodes: [String: AVAudioPlayerNode] = [:]
            for name in Self.stemNames {
                let sn = AVAudioPlayerNode()
                engine.attach(sn)
                engine.connect(sn, to: inputMixer, format: canonical)
                stemNodes[name] = sn
            }
            stemPlayers[d] = stemNodes
        }
        // Clean house sum → cue-side pan → master. The tap point (`hSum`) is BEFORE the pan, so a
        // recording is always normal stereo house even while a deck is cued (the pan only steers the
        // physical monitor split). Cue sends already merge directly at `mainMixerNode`.
        engine.connect(hSum, to: hPan, format: canonical)
        engine.connect(hPan, to: engine.mainMixerNode, format: canonical)
        // Master PEAK LIMITER between mainMixer and the device: two decks at up to 200% (+6 dB each)
        // plus the compressor's makeup gain can sum past 0 dBFS — the limiter catches those peaks so
        // the boost feature can't hard-clip the output. Transparent below threshold.
        let limiter = AVAudioUnitEffect(audioComponentDescription: Self.limiterDesc)
        engine.attach(limiter)
        engine.connect(engine.mainMixerNode, to: limiter, format: canonical)
        engine.connect(limiter, to: engine.outputNode, format: canonical)
        masterLimiter = limiter
        engine.prepare()
        // Soft-fail: no audio device (e.g. a headless CI / unit-test host) leaves the graph unbuilt
        // and `isReady` false — the app degrades to a silent Mix tab rather than crashing.
        do { try engine.start() } catch { return }
        built = true
        registerConfigChangeHandling()  // per-instance: the system stops the engine on a route-format change
        configureMixRemoteCommands()    // wire lock-screen transport once the graph is live
        // Push whatever the UI already set, then derive gains.
        for d in Deck.allCases {
            applyRate(d); applyPitch(d)
            applyAllSlots(d)
            applyAllEQ(d)
        }
        applyMixGains()
        for d in Deck.allCases { applyBoost(d) }   // >unity boost (globalGain) AFTER effects set the filter EQ
        // Install the recording tap ONCE, here — never per-recording — on the clean house sum. It fires
        // continuously but only copies/writes while capturing (see `MixTapSink`); keeping it installed
        // means starting/stopping a recording never reconfigures the live graph (which would pause the
        // decks on-device).
        if let hs = houseSum {
            let sink = recordingSink
            let pulse = tapPulse
            hs.installTap(onBus: 0, bufferSize: 4096, format: hs.outputFormat(forBus: 0)) { buffer, _ in
                // Liveness mirrors for mixdiag: proves the render graph is actually pulling, and
                // whether it carries signal. Sparse peak scan — diagnostics, not metering.
                let now = Date().timeIntervalSinceReferenceDate
                pulse.lastTapAt = now
                if let ch = buffer.floatChannelData?[0] {
                    var peak: Float = 0
                    let n = Int(buffer.frameLength)
                    var i = 0
                    while i < n { peak = max(peak, abs(ch[i])); i += 64 }
                    if peak > 0.0005 { pulse.lastAudibleAt = now }
                }
                sink.write(buffer)
            }
        }
        // Per-deck VU-meter taps — installed ONCE here, exactly like the recording tap above (never
        // toggled at runtime: adding/removing a tap on a live node pauses the decks on-device). TWO
        // taps per deck feed one `MixDeckLevels`: PRE-fader off `trim` (the last node before the
        // main/cue split — post-FX, before the volume+crossfade gain) and POST-fader off `mainGain`
        // (after it). The UI picks which to show, so both always run; the overhead (peak+RMS over
        // ≤4096 frames, ~10 Hz) is trivial. These ride the `ensureEngine` rebuild (media-services
        // reset) for free onto the fresh nodes.
        for d in Deck.allCases {
            let lv = d == .a ? levelsA : levelsB
            if let pre = trims[d] {
                pre.installTap(onBus: 0, bufferSize: 4096, format: pre.outputFormat(forBus: 0)) { buffer, _ in
                    let (p, r) = Self.vuMeter(buffer)
                    lv.prePeak = max(p, lv.prePeak * Self.vuPeakDecay)
                    lv.preRMS += (r - lv.preRMS) * (r > lv.preRMS ? Self.vuRmsAttack : Self.vuRmsRelease)
                    lv.updatedAt = Date().timeIntervalSinceReferenceDate
                }
            }
            if let post = mainGains[d] {
                post.installTap(onBus: 0, bufferSize: 4096, format: post.outputFormat(forBus: 0)) { buffer, _ in
                    let (p, r) = Self.vuMeter(buffer)
                    lv.postPeak = max(p, lv.postPeak * Self.vuPeakDecay)
                    lv.postRMS += (r - lv.postRMS) * (r > lv.postRMS ? Self.vuRmsAttack : Self.vuRmsRelease)
                    lv.updatedAt = Date().timeIntervalSinceReferenceDate
                }
            }
        }
        // Writer death (disk full / provider folder vanished) surfaces here: hop to the main actor
        // and let the recorder auto-stop + file the partial take (fragments to this point are
        // durable). One-shot per take (the sink re-arms on the next `begin`).
        recordingSink.onWriterFailure = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.onRecordingFailed?()
                if self.isRecording { self.stopRecording() }   // recorder not wired → still stop cleanly
            }
        }
    }

    func prepare() { ensureEngine() }

    // TEST SEAMS — dead-engine transport tests (route-change hardening). The system stops the
    // engine out from under the app on a route/config change; tests reproduce that state here
    // (the graph stays built, exactly like the real event).
    func stopEngineForTesting() { engine.stop() }
    var engineIsRunningForTesting: Bool { engine.isRunning }
    /// Drive the route/config-change observer path directly (the real observers are wired to the
    /// shared session / the private engine instance, which tests can't post as).
    func simulateEngineRecoveryForTesting() { recoverFromEngineStop() }
    /// Backdate a stall park (as if the tick watchdog stamped it `age` seconds ago).
    func parkEngineStallForTesting(secondsAgo age: Double) { engineStallAt = Date().addingTimeInterval(-age) }
    var autoFadeStartedAtForTesting: Date? { autoFadeStartedAt }
    /// Park a deck's player NODE while leaving the deck's intent playing (the macOS device-switch
    /// state: engine renders on, node silently stopped).
    func parkPlayerNodeForTesting(_ deck: Deck) { players[deck]?.pause() }
    func playerNodeIsPlayingForTesting(_ deck: Deck) -> Bool { players[deck]?.isPlaying ?? false }
    /// The LIVE filter-band frequency on a slot's filter node — lets a modulation test assert the
    /// LFO actually moves the graph (and snaps back) without reaching into AVAudio.
    func slotFilterFrequencyForTesting(_ i: Int, on deck: Deck) -> Float? {
        slotNodes[deck]?[safe: i]?.filter.bands.first?.frequency
    }

    // Auto-mix queue introspection (auto-reset + collection-downloader progressive-append tests).
    var autoQueueCountForTesting: Int { autoQueue.count }
    var autoNextToLoadForTesting: Int { autoNextToLoad }
    /// Complete the in-flight crossfade NOW (tests can't wait out a wall-clock fade).
    func finishAutoCrossfadeForTesting() { if autoFadeStartedAt != nil { finishAutoCrossfade() } }
    func autoDeckDurationMsForTesting(_ deck: Deck) -> Int? { autoDeckDurationMs[deck] }
    /// Drive one tick's park-heal pass directly (the watchdog path a test can't wait for).
    func healParkedPlayersForTesting() { healParkedPlayers() }
    /// Drive one `autoFire` pass directly (the tick's advance decision, which a unit test
    /// can't wall-clock-wait for) — pair with `backdateAutoDeckEndForTesting`.
    func autoFireForTesting() { autoFire() }
    /// Re-stamp the LIVE deck's end clock to `secondsLeft` from now, so the next
    /// `autoFireForTesting` sees an advance window (or an expired track).
    func backdateAutoDeckEndForTesting(secondsLeft: Double) {
        autoDeckEndsAt[autoLiveDeck] = Date().addingTimeInterval(secondsLeft)
    }
    // tvOS silent-resume seams: reproduce the OS dropping every node's never-rendered schedule
    // behind the engine's back (the first-start output renegotiation / an engine uninit) —
    // `stop()` flushes each node's queue WITHOUT updating the engine's bookkeeping, exactly
    // like the field event. Pair with `deckRescheduleCountForTesting` / `fileScheduledForTesting`.
    func flushNodeSchedulesForTesting() {
        for d in Deck.allCases {
            players[d]?.stop()
            for n in (stemPlayers[d] ?? [:]).values { n.stop() }
        }
    }
    /// Does the engine trust this deck's MAIN-file schedule to be live?
    func fileScheduledForTesting(_ deck: Deck) -> Bool { fileScheduled[deck] == true }
    /// Drive the `.AVAudioEngineConfigurationChange` observer body directly (the real
    /// notification is posted by the private engine instance, which tests can't post as).
    func simulateConfigChangeForTesting() { handleEngineConfigurationChange() }
    /// The next-unplayed loader with its drop-the-unloadable behaviour — the resume-handoff and
    /// re-establish paths run it where a wall-clock deck end can't be waited out.
    @discardableResult
    func loadNextUnplayedForTesting(onto deck: Deck, excludingDeck exclude: Deck? = nil) -> Int? {
        loadNextUnplayed(onto: deck, excludingDeck: exclude)
    }

    func teardown() {
        endAutoLoop()
        stopRecording()                 // finalize any in-progress capture (the file stays on disk)
        tickTask?.cancel(); tickTask = nil
        modTask?.cancel(); modTask = nil
        pauseBoth()
        if built { engine.stop() }
        releases[.a]?(); releases[.a] = nil
        releases[.b]?(); releases[.b] = nil
        stemReleases[.a]?(); stemReleases[.a] = nil
        stemReleases[.b]?(); stemReleases[.b] = nil
        stemFiles = [:]
        mutate(.a) { $0.loaded = nil; $0.startMs = nil }
        mutate(.b) { $0.loaded = nil; $0.startMs = nil }
        #if os(iOS)
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o); interruptionObserver = nil }
        if let o = routeChangeObserver { NotificationCenter.default.removeObserver(o); routeChangeObserver = nil }
        if let o = mediaResetObserver { NotificationCenter.default.removeObserver(o); mediaResetObserver = nil }
        #endif
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
    }

    // MARK: - Loading

    func load(songId: String, title: String, artist: String, bpm: Double?,
              camelot: String?, key: String?, albumId: String?, lengthMs: Int? = nil, on deck: Deck) {
        deckGestureGeneration &+= 1
        // A load while an exhausted-ended auto mix is armed for pickup means the DJ started
        // hand-mixing: the pickup dies here, or a later background download landing would
        // eject these decks mid-performance and restart the old mix unbidden. Auto-machine
        // loads (`loadAuto`) only ever run while the flag is already false, so this only ever
        // disarms MANUAL activity.
        autoEndedExhausted = false
        // STUDIO performance items resolve via the studio seam (no BurnStore file). Their beat grid
        // (from the item's known bpm) + detected key ride `studioMixInfo` into the LoadedTrack, so
        // the pulse/beat-sync + harmonic glide work exactly like a burned song's.
        if StudioFactory.isStudioId(songId), let resolve = studioResolve, let res = resolve(songId) {
            let info = studioMixInfo?(songId)
            loadFile(res.url, release: res.release, startMs: nil, lengthMs: nil,
                     meta: LoadedTrack(songId: songId, title: title, artist: artist,
                                       bpm: bpm ?? info?.bpm, camelot: camelot ?? info?.camelot, key: key,
                                       albumId: nil,
                                       gridBpm: info?.bpm, firstDownbeatMs: info?.firstDownbeatMs,
                                       steady: true, beatsMs: info?.beatsMs, downbeatsMs: nil),
                     on: deck)
            return
        }
        // PROFILE ("Pocket DJ") items: device-local original via the profileResolve seam (no
        // BurnStore file). albumId rides through for cover art; the constant beat grid comes from
        // the item's known bpm. Stems are NOT wired here (Stage 7) — a fresh load resets stem state,
        // so this arm must not pre-set any. `pdj_` is outside studioPrefixes (no collision).
        if ProfileSourceStore.isProfileSongId(songId), let resolve = profileResolve, let res = resolve(songId) {
            loadFile(res.url, release: res.release, startMs: nil, lengthMs: nil,
                     meta: LoadedTrack(songId: songId, title: title, artist: artist,
                                       bpm: bpm, camelot: camelot, key: key, albumId: albumId,
                                       gridBpm: bpm, firstDownbeatMs: 0,
                                       steady: true, beatsMs: nil, downbeatsMs: nil),
                     on: deck)
            return
        }
        guard let handle = burns.localURLForPlaybackPreferringCut(forSong: songId) else { return }
        // A per-song CUT plays its whole file from 0:00; an analog shared-album fallback SEEKS to the
        // song's startMs AND bounds playback to the song's lengthMs window, so it stops at the song
        // boundary instead of bleeding into the next song on the side.
        let startMs = handle.isCut ? nil : burns.startMs(forSong: songId)
        let windowMs = handle.isCut ? nil : lengthMs
        let grid = burns.beatGrid(forSong: songId)
        let localBeats = burns.localBeatGrid(forSong: songId)   // offline per-beat grid, if burned
        loadFile(handle.url, release: handle.release, startMs: startMs, lengthMs: windowMs,
                 meta: LoadedTrack(songId: songId, title: title, artist: artist,
                                   bpm: bpm, camelot: camelot, key: key, albumId: albumId,
                                   gridBpm: grid?.bpm, firstDownbeatMs: grid?.firstDownbeatMs,
                                   steady: grid?.steady,
                                   beatsMs: localBeats?.beatsMs, downbeatsMs: localBeats?.downbeatsMs),
                 on: deck)
        if localBeats == nil { hydrateBeatGrid(deck, songId: songId) }   // fetch on load iff pulse on
    }

    /// Internal load seam (shared by the BurnStore path above AND the integration/stress tests):
    /// open `url`, reconnect only the player→inputMixer link at the file's format, schedule the
    /// `[startMs, startMs+lengthMs)` window (analog) or the whole file, and reset tempo/pitch/lead.
    /// `release` is the held security-scope closure (nil for app-storage / test files). On any early
    /// return it releases `release` (so a bad file never leaks a scope) and leaves the deck's current
    /// track untouched. A zero-frame window is rejected (scheduling it would be an uncatchable crash).
    func loadFile(_ url: URL, release: (() -> Void)?, startMs: Int?, lengthMs: Int? = nil,
                  meta: LoadedTrack, on deck: Deck) {
        // A REAL load supersedes a parked (not-yet-materialized) restore — the user (or an
        // intent) started something new; the old mix must not rehydrate on top of it later.
        if !isRestoringMixSession { pendingMixRestore = nil }
        ensureEngine()
        guard let player = players[deck], let inputMixer = inputMixers[deck] else { release?(); return }
        guard let file = try? AVAudioFile(forReading: url) else { release?(); return }   // unreadable / corrupt
        masterPausedDecks.remove(deck)   // a NEW track was never silenced by the pause — lock ▶ must not blast it
        let sr = file.processingFormat.sampleRate
        let total = file.length
        let start = min(max(0, AVAudioFramePosition((Double(startMs ?? 0) / 1000.0) * sr)), total)
        let available = total - start
        let windowed = lengthMs.map { AVAudioFramePosition((Double($0) / 1000.0) * sr) }
        let count = windowed.map { min(available, max(0, $0)) } ?? available
        guard count > 0 else { release?(); return }    // over-length startMs / empty file — keep current track

        player.stop()
        engine.connect(player, to: inputMixer, format: file.processingFormat)   // only the varying link
        releases[deck]?()                  // release the PREVIOUS file's scope, hold the new one
        releases[deck] = release
        paths[deck] = url.path
        files[deck] = file
        sampleRates[deck] = sr
        startFrames[deck] = start
        endFrames[deck] = start + count
        segmentStartSeconds[deck] = 0          // segment begins at source 0:00 (true-playhead base)
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(count),
                               at: nil, completionHandler: nil)
        fileScheduled[deck] = true
        if leadDeck == deck { leadDeck = nil }   // load resets this deck's lead role + tempo/pitch
        mutate(deck) {
            $0.loaded = meta
            $0.startMs = startMs
            $0.isPlaying = false
            $0.rate = 1.0
            $0.pitch = 0.0
            $0.stemMode = false       // a fresh track starts in single-file mode
            $0.stemMuted = []
            $0.stemVol = [:]
            $0.loopOn = false         // the PREVIOUS track's window means nothing here
        }
        clearLoopState(deck)          // …and drop its resolved window + pass count
        unwireStems(deck)             // drop the prior track's stem files + scope
        // Loading stopped this deck OUTSIDE setPlaying (direct isPlaying=false above) — mirror the
        // sticky-card update so the card can't later fall back to this deck's never-played new track
        // (e.g. blend on A+B, queue a new song onto B, pause A → the card must stay on A).
        let aOn = state(.a).isPlaying, bOn = state(.b).isPlaying
        if aOn != bOn { lastNowPlayingDeck = aOn ? .a : .b }
        setDuration(deck, Double(count) / sr)
        setPosition(deck, 0)
        applyRate(deck); applyPitch(deck)
        // Record the load with the track's musical attributes (bpm/camelot) so the corpus is
        // self-describing without a catalog join. tempo/pitch reset to default are implied by .load.
        if let recorder, let l = state(deck).loaded {
            recorder.logEvent(.load, deck: deck.rawValue, songId: l.songId, title: l.title,
                              artist: l.artist, bpm: l.bpm, camelot: l.camelot, param: nil,
                              value: nil, flag: nil, posMs: 0, slot: nil)
        }
        updateSystemNowPlaying()      // a new track on the now-playing deck → refresh the card
        persistMixDeckSession()       // deck load = structural change — the mix survives a kill
    }

    // MARK: - Transport

    /// Start the engine if it isn't running — REPORTING failure instead of swallowing it. Every
    /// transport path must check this before `AVAudioPlayerNode.play()`/`play(at:)`: play on a
    /// stopped engine raises an UNCATCHABLE ObjC exception (`_engine->IsRunning()`) — the
    /// headphones→speaker route-change crash. A failed start means "stay parked": the tick
    /// watchdog + route/config observers keep retrying and `resumePlayingDecks()` brings the
    /// audio back the moment the engine can run again.
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

    /// Resume every deck the UI still considers playing (single-file or stems) — the shared tail
    /// of engine recovery (route/config change, interruption end, tick watchdog restart).
    ///
    /// RE-PRIME, don't just play: a node that was playing when the system stopped the engine can
    /// come back from the restart as a ZOMBIE — `isPlaying` true, schedule intact, position
    /// advancing, rendering pure silence (observed on macOS across the 44.1↔48 kHz output-format
    /// change of an AirPods switch; a bare `play()` no-ops on it because it already claims to be
    /// playing). `pause()` then `play()` — exactly the manual workaround — re-primes the render
    /// state without touching the schedule, so the deck resumes from where it stopped.
    private func resumePlayingDecks() {
        for d in Deck.allCases where state(d).isPlaying {
            ensureDeckScheduled(d)   // an engine uninit DROPS schedules — re-arm before re-priming
            if stemActive(d) {
                for n in (stemPlayers[d] ?? [:]).values where n.isPlaying { n.pause() }
                startStems(d)
            } else if let p = players[d] {
                if p.isPlaying { p.pause() }
                p.play()
            }
        }
    }

    /// A macOS output-device switch can leave the ENGINE rendering while the PLAYER nodes were
    /// silently parked by the reconfigure — the mix looks alive, `houseSum` renders zeros, and an
    /// open take records dead air with no warning (the content clock keeps advancing). Deck INTENT
    /// is the truth: re-kick any intent-playing deck whose node isn't actually playing. Safe to
    /// call every tick — a no-op in every legitimate state (every deliberate pause clears the
    /// intent first, and seek/restart stop+re-play inside one main-actor turn the tick can't
    /// interleave). Callers must ensure the engine is RUNNING (play() on a dead engine traps).
    private func healParkedPlayers() {
        for d in Deck.allCases where state(d).isPlaying {
            if stemActive(d) {
                if let nodes = stemPlayers[d], nodes.values.contains(where: { !$0.isPlaying }) {
                    dlog("heal: re-kick STEMS deck \(d.rawValue)")
                    ensureStemsScheduled(d)
                    startStems(d)
                }
            } else if let p = players[d], !p.isPlaying {
                dlog("heal: re-kick deck \(d.rawValue)")
                ensureDeckScheduled(d)
                p.play()
            }
        }
    }

    /// Re-arm THIS deck's voices from the current playhead IF their schedule can't be trusted —
    /// the single-file (and loop-aware) twin of `ensureStemsScheduled`. The tvOS silent-resume
    /// field bug (session tvos-95F9E8D4/2026-09-03): a materialize-restored deck was CUED on a
    /// never-started engine; the first `engine.start()` (Resume) reconfigured the output and
    /// dropped the never-rendered schedules, so the bare `play()` ran the deck "playing" into an
    /// empty queue — a state neither the zombie re-prime (pause/play keeps the schedule it assumes
    /// is intact) nor `healParkedPlayers` (the node CLAIMS playing) could see; only a skip's fresh
    /// load healed it. A trusted schedule is left untouched, so a normal pause→resume (segments
    /// alive) never restart-glitches. Never starts a voice itself — the caller owns play().
    private func ensureDeckScheduled(_ deck: Deck) {
        guard state(deck).loaded != nil else { return }
        if loopWindow(deck) != nil {          // a live loop re-arms as a LOOP, not a linear tail
            let trusted = stemActive(deck) ? stemsScheduled[deck] == true : fileScheduled[deck] == true
            if !trusted {
                deckRescheduleCountForTesting += 1
                dlog("ensure: re-arm LOOP deck \(deck.rawValue) @\(String(format: "%.2f", position(deck)))")
                _ = armLoop(deck, resumeAt: position(deck))
            }
            return
        }
        if stemActive(deck) { ensureStemsScheduled(deck); return }
        guard fileScheduled[deck] != true else { return }
        deckRescheduleCountForTesting += 1
        dlog("ensure: re-arm deck \(deck.rawValue) @\(String(format: "%.2f", position(deck)))")
        rescheduleFile(deck, fromSeconds: position(deck))
    }

    /// Stop + schedule the deck's single file from `sec` — `seek`'s scheduling tail WITHOUT its
    /// gesture side effects (no recorder event, no card write, no persist, no auto re-time).
    private func rescheduleFile(_ deck: Deck, fromSeconds sec: Double) {
        guard built, let file = files[deck], let player = players[deck], let sr = sampleRates[deck],
              let start = startFrames[deck], let end = endFrames[deck] else { return }
        let clamped = min(max(0, sec), duration(deck))
        let frame = min(max(start, start + AVAudioFramePosition(clamped * sr)), end)
        let count = end - frame
        player.stop()
        segmentStartSeconds[deck] = clamped
        setPosition(deck, clamped)
        guard count > 0 else { return }       // cued at the very end — nothing schedulable
        player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(count),
                               at: nil, completionHandler: nil)
        fileScheduled[deck] = true
    }

    func play(_ deck: Deck) {
        guard state(deck).loaded != nil else { return }   // never run an empty deck's playhead
        dlog("ui: play(\(deck.rawValue)) run=\(engine.isRunning ? 1 : 0) node=\((players[deck]?.isPlaying ?? false) ? 1 : 0)")
        deckGestureGeneration &+= 1
        autoEndedExhausted = false   // a manual start disarms the exhausted pickup (see `load`)
        masterPausedDecks = []   // any manual start invalidates the lock-screen pause memory
        ensureEngine()
        // Even when the engine can't run RIGHT NOW (mid route change / session in transition) the
        // deck is still marked playing — that's the INTENT the watchdog restores; only the
        // uncatchable play()-on-a-dead-engine call is skipped.
        if startEngineIfNeeded() {
            ensureDeckScheduled(deck)   // tvOS silent-resume: an untrusted/dropped schedule re-arms BEFORE play
            if stemActive(deck) { startStems(deck) } else { players[deck]?.play() }
        }
        setPlaying(deck, true)
        refreshTransport()
        startTickIfNeeded()
    }

    func pause(_ deck: Deck) {
        dlog("ui: pause(\(deck.rawValue)) run=\(engine.isRunning ? 1 : 0) node=\((players[deck]?.isPlaying ?? false) ? 1 : 0)")
        // A manual pause during a RUNNING Auto-DJ ends it — but NOT while auto is PAUSED, where you're
        // deliberately hand-mixing and a per-deck pause must behave like a normal manual pause.
        if autoMixing && !autoPaused { endAutoLoop() }
        silence(deck)
    }

    /// Stop a deck's player WITHOUT ending an active auto-mix — for the auto crossfade machine's own
    /// internal "retire the outgoing deck" step (the public `pause` ends the auto-mix).
    private func silence(_ deck: Deck) {
        pauseActiveNodes(deck)              // keeps the scheduled position (main + any stems)
        setPlaying(deck, false)
        refreshTransport()
    }

    func togglePlay(_ deck: Deck) { state(deck).isPlaying ? pause(deck) : play(deck) }

    func playBoth() {
        dlog("ui: playBoth run=\(engine.isRunning ? 1 : 0)")
        deckGestureGeneration &+= 1
        autoEndedExhausted = false   // a manual start disarms the exhausted pickup (see `load`)
        masterPausedDecks = []   // any manual start invalidates the lock-screen pause memory
        unfreezeAutoClock()      // master play un-silences everything — unpark any remote-frozen fade
        ensureEngine()
        let engineUp = startEngineIfNeeded()   // dead engine → decks still marked playing; watchdog resumes
        suppressStickyUpdates = true; defer { suppressStickyUpdates = false }   // batch — see the flag
        for d in Deck.allCases where state(d).loaded != nil {
            if engineUp {
                ensureDeckScheduled(d)   // see play(): re-arm anything whose schedule was dropped
                if stemActive(d) { startStems(d) } else { players[d]?.play() }
            }
            setPlaying(d, true)
        }
        refreshTransport()
        startTickIfNeeded()
    }

    func pauseBoth() {
        dlog("ui: pauseBoth run=\(engine.isRunning ? 1 : 0)")
        masterPausedDecks = Set(Deck.allCases.filter { state($0).isPlaying })   // what the lock-screen ▶ resumes
        if autoMixing && !autoPaused { endAutoLoop() }     // a manual master-Pause during a RUNNING Auto-DJ ends it
        suppressStickyUpdates = true; defer { suppressStickyUpdates = false }   // batch — see the flag
        for d in Deck.allCases { pauseActiveNodes(d); setPlaying(d, false) }
        refreshTransport()
    }

    func toggleAll() { isRunning ? pauseBoth() : playBoth() }

    /// LOCK-SCREEN ▶ only — resume exactly what the last master pause silenced (`masterPausedDecks`),
    /// NOT both decks: with one deck playing, lock-screen ⏸ then ▶ must bring back just that deck.
    /// No pause memory (e.g. the decks were paused individually in-app, or nothing was playing when
    /// paused) falls back to the card's now-playing deck — play the track the card is showing.
    /// The in-app master transport deliberately keeps `playBoth()`; this never replaces it.
    func resumeMasterPaused() {
        let remembered = masterPausedDecks.filter { state($0).loaded != nil }
        masterPausedDecks = []
        guard !remembered.isEmpty else {
            if let d = nowPlayingDeck {
                // Field report (Levi, CarPlay, 2026-09-04): a cold-launch session parked over an
                // hour (engine never touched) resumed via THIS exact fallback — the card showed
                // playing=true with the playhead advancing, but no audible output. `play(d)` below
                // is provably correct on paper (ensureEngine → ensureDeckScheduled re-arm → play,
                // all synchronous), so the doubt is HARDWARE truth, not software state — sample it.
                let cold = !built
                let rearmedBefore = deckRescheduleCountForTesting
                play(d)
                logResumeHealth(d, cold: cold, rearmed: deckRescheduleCountForTesting > rearmedBefore)
            }
            return
        }
        suppressStickyUpdates = true; defer { suppressStickyUpdates = false }   // batch — see the flag
        for d in Deck.allCases where remembered.contains(d) { play(d) }
    }

    /// Hardware-truth telemetry for the now-playing-fallback resume above: the software model
    /// (`isPlaying`, tick-advanced position) can look perfectly healthy while nothing renders —
    /// see `MixTapPulse`'s doc. Two samples: immediately (engine/node state right after `play()`)
    /// and ~400 ms later (one house-sum tap has had time to fire at least once, so `tapPulse`'s
    /// ages are meaningful) — always shipped in TestFlight/Debug (never gated behind the owner's
    /// telemetry opt-in; this fires once per resume gesture, never per tick, so the rate cost is
    /// negligible). If this recurs, the +400ms line proves definitively which layer is silent:
    /// `run=0` → the engine itself died; `node=0` → the player node isn't playing; `tapAge` large →
    /// the render graph isn't even being pulled; `sigAge` large with `tapAge` small → the graph
    /// renders but carries no signal (a real software bug); everything fresh → real PCM is
    /// reaching the output node and the fault is a route/session issue outside this engine.
    private func logResumeHealth(_ deck: Deck, cold: Bool, rearmed: Bool) {
        DiagLog.shared.log("mix", "resume-health deck=\(deck.rawValue) cold=\(cold ? 1 : 0) "
            + "rearmed=\(rearmed ? 1 : 0) run0=\(engine.isRunning ? 1 : 0) "
            + "node0=\((players[deck]?.isPlaying ?? false) ? 1 : 0)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.isPlaying(deck) else { return }   // a real pause/skip beat us here
            let t = Date().timeIntervalSinceReferenceDate
            let tapAge = self.tapPulse.lastTapAt == 0 ? -1 : t - self.tapPulse.lastTapAt
            let sigAge = self.tapPulse.lastAudibleAt == 0 ? -1 : t - self.tapPulse.lastAudibleAt
            DiagLog.shared.log("mix", "resume-health+400ms deck=\(deck.rawValue) "
                + "run=\(self.engine.isRunning ? 1 : 0) "
                + "node=\((self.players[deck]?.isPlaying ?? false) ? 1 : 0) "
                + "tapAge=\(String(format: "%.2f", tapAge)) sigAge=\(String(format: "%.2f", sigAge))")
        }
    }

    /// Set by `remotePause` when it suspended a RUNNING Auto-DJ, so the matching `remotePlay`
    /// resumes the Auto-DJ too — but never resurrects one the user deliberately paused in-app.
    @ObservationIgnored private var resumeAutoOnRemotePlay = false

    /// LOCK-SCREEN ⏸ — unlike the in-app master pause (which deliberately ENDS a running Auto-DJ
    /// and drops you to manual), the lock-screen pause SUSPENDS it: `pauseAuto()` first (machine
    /// paused, session + queue alive), then freeze the machine's wall clock (`remotePausedAt` —
    /// an in-flight pre-roll/fade must not complete into silent decks), then silence the decks.
    /// The matching lock-screen ▶ resumes both the audio and the Auto-DJ, so a pocket pause never
    /// kicks the mix back to manual mode. IDEMPOTENT: Bluetooth/AVRCP heads re-send discrete PAUSE —
    /// a duplicate while already paused must not clobber the pause memory or the resume intent.
    func remotePause() {
        guard isRunning || (remotePausedAt == nil && masterPausedDecks.isEmpty) else { return }
        DiagLog.shared.telemetry("action", "mix pause (remote seam)")
        let autoWasRunning = autoMixing && !autoPaused
        if autoWasRunning {
            pauseAuto()                      // BEFORE pauseBoth — a running auto-loop would be ended by it
            resumeAutoOnRemotePlay = true    // set-only: never clobber an earlier ⏸'s intent
        }
        if autoMixing {
            unparkEngineStall()              // fold an in-progress stall into the freeze — the resume
                                             // shift must not count the overlapping dead time twice
            remotePausedAt = Date()          // freeze transition timers while the decks are silent
        }
        pauseBoth()                          // records masterPausedDecks; autoPaused=true keeps the loop
    }

    /// LOCK-SCREEN ▶ — un-freeze the machine's wall clock (shift every armed timestamp forward by the
    /// frozen interval so an in-flight transition resumes exactly where it stopped), resume the paused
    /// deck(s) (`resumeMasterPaused`), then, if the matching lock-screen ⏸ was what suspended the
    /// Auto-DJ, resume it too. An Auto-DJ the user paused IN-APP (hand-mixing) stays paused — the
    /// lock screen only undoes its own suspension.
    func remotePlay() {
        DiagLog.shared.telemetry("action", "mix resume (remote seam)")
        unfreezeAutoClock()
        resumeMasterPaused()
        if resumeAutoOnRemotePlay, autoMixing, autoPaused { resumeAuto() }
        resumeAutoOnRemotePlay = false
    }

    /// LOCK-SCREEN ⏭/⏮ — a skip while the Auto-DJ is suspended means "resume the mix on the next
    /// track": un-freeze, bring the audio back, lift the machine's pause, THEN fire the transition.
    /// Skipping into a suspended machine would play one track and stall in silence at its end.
    func remoteSkip(fadeSeconds: Double) {
        DiagLog.shared.telemetry("action", "mix skip fade=\(Int(fadeSeconds))s")
        if autoPaused {
            unfreezeAutoClock()
            resumeMasterPaused()
            resumeAuto()                     // consumes resumeAutoOnRemotePlay; no-ops the re-arm mid-fade
        }
        skipToNext(fadeSeconds: fadeSeconds)
    }

    /// Shift every armed auto-machine timestamp forward by the interval spent remote-frozen, so the
    /// machine resumes exactly where the pause stopped it (a half-swept fade stays half-swept, the
    /// live deck's end-at moves out by the pause length). No-op when not frozen.
    private func unfreezeAutoClock() {
        guard let frozeAt = remotePausedAt else { return }
        remotePausedAt = nil
        let delta = Date().timeIntervalSince(frozeAt)
        guard delta > 0 else { return }
        autoPrerollStartedAt = autoPrerollStartedAt?.addingTimeInterval(delta)
        autoFadeStartedAt = autoFadeStartedAt?.addingTimeInterval(delta)
        autoPostrollStartedAt = autoPostrollStartedAt?.addingTimeInterval(delta)
        for (d, t) in autoDeckEndsAt { autoDeckEndsAt[d] = t.addingTimeInterval(delta) }
    }

    /// Return a deck to the BEGINNING (its window's start frame) and resume if it was playing.
    func restart(_ deck: Deck) {
        let was = state(deck).isPlaying
        clearLoopState(deck)   // rewinding past the window would leave a stale loop half-armed
        if stemActive(deck) {                              // stem mode: rewind + re-sync the 4 stems
            stopStemNodes(deck)
            guard scheduleStems(deck, fromSeconds: 0) else { return }
            setPosition(deck, 0)
            if was { startStems(deck) }
        } else {
            guard built, let file = files[deck], let player = players[deck],
                  let start = startFrames[deck], let end = endFrames[deck], end > start else { return }
            player.stop()
            player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(end - start),
                                   at: nil, completionHandler: nil)
            fileScheduled[deck] = true
            segmentStartSeconds[deck] = 0       // rewound to source 0:00
            setPosition(deck, 0)
            if was {
                if startEngineIfNeeded() { player.play() }   // dead engine → stay scheduled; watchdog resumes
                setPlaying(deck, true)                        // was already playing → no spurious event
            }
        }
        refreshTransport()
        startTickIfNeeded()
    }

    /// Full deck RESET: return EVERY per-deck parameter to default — tempo (1.0×), pitch (0),
    /// volume (100%), and all four effects OFF with their strength back to the 0.5 default — then
    /// rewind to the start. Keeps the loaded track + its lead role. The ↺ button calls this so one
    /// tap clears a deck back to a clean slate.
    func resetDeck(_ deck: Deck) {
        mutate(deck) {
            $0.rate = 1.0
            $0.pitch = 0.0
            $0.volume = 1.0
            // SILENCE the rack but KEEP ITS LAYOUT: which effects/varieties are on the board is
            // board configuration the DJ set up — like the loaded track and the Lead role, which
            // reset also preserves. ↺ turns every slot off and re-centres its strength.
            for i in $0.slots.indices { $0.slots[i].enabled = false; $0.slots[i].setStrength(0.5) }
            $0.eqLow = 0; $0.eqMid = 0; $0.eqHigh = 0
            $0.stemMuted = []     // un-mute + re-level every stem (keeps stem mode itself)
            $0.stemVol = [:]
        }
        applyRate(deck); applyPitch(deck)
        for e in Effect.allCases { applyEffect(e, on: deck) }
        applyAllEQ(deck)
        applyMixGains()
        applyBoost(deck)         // volume back to 100% → globalGain back to 0 dB
        restart(deck)            // rewind to the start (no-op if nothing is loaded)
        rec(.resetDeck, deck)    // ONE semantic event (not a burst of per-parameter resets)
        persistMixDeckSession()  // every parameter changed at once — persist immediately
    }

    /// Full deck CLEAR — the "zero state". Everything `resetDeck` returns to default (tempo, pitch,
    /// volume, effects, stems) AND the track itself is EJECTED: the player stops, the file + its
    /// security scope are released, any stem wiring is dropped, the lead role and cue send are
    /// cleared, and the deck goes empty. Bound to a LONG-PRESS / RIGHT-CLICK on the ↺ Reset button —
    /// a plain tap just resets parameters + rewinds (`resetDeck`), keeping the loaded track. One
    /// semantic `.resetDeck` event marks it in the session log (a clear is a reset that also ejects).
    func clearDeck(_ deck: Deck) {
        ejectDeckCore(deck)
        rec(.resetDeck, deck)
        persistMixDeckSession()   // eject persists; BOTH decks empty (no auto) ⇒ session cleared
    }

    /// The eject CORE shared by `clearDeck` and `startAutoMix`'s take-over reset: stop the deck,
    /// drop its track/stems/loops/scopes, return EVERY per-deck parameter to default — including
    /// the cue/PFL send, which `resetDeck` deliberately keeps — and push the defaults onto the
    /// graph. Records/persists NOTHING: the caller owns the semantic timeline event + the persist.
    private func ejectDeckCore(_ deck: Deck) {
        setPlaying(deck, false)          // emit .pause if it was running (BEFORE we forget the track)
        stopActiveNodes(deck)            // stop the single file + any stem voices
        unwireStems(deck)                // drop stem files + their security scope
        releases[deck]?(); releases[deck] = nil   // release the main file's scope
        files[deck] = nil; paths[deck] = nil; sampleRates[deck] = nil
        startFrames[deck] = nil; endFrames[deck] = nil; segmentStartSeconds[deck] = nil
        clearLoopState(deck)                              // the loop dies with the track
        if leadDeck == deck { leadDeck = nil }     // give up the lead role if this deck held it
        mutate(deck) { $0 = DeckState() }          // empty track, every parameter back to default, cue off
        setDuration(deck, 0); setPosition(deck, 0)
        applyRate(deck); applyPitch(deck)          // push the defaults onto the graph so nothing lingers
        for e in Effect.allCases { applyEffect(e, on: deck) }
        applyMixGains(); applyBoost(deck); applyCueRouting()
        updateSystemNowPlaying()                   // an empty now-playing deck → clear/refresh the card
        refreshTransport()
    }

    /// Seek to an absolute SOURCE position (seconds from the song's start). Sample-accurate, bounded
    /// to the song's window so an analog fallback can't scrub past its slice into the next song.
    func seek(_ deck: Deck, toSeconds sec: Double) {
        let clamped = min(max(0, sec), duration(deck))
        let was = state(deck).isPlaying
        // Scrubbing while LOOPED moves the loop to where you dropped the playhead (rather than
        // fighting it or silently dropping out) — re-arm and take the same housekeeping tail.
        // `setLoop(off)` clears `loopOn` BEFORE it calls seek, so this can't recurse.
        if state(deck).loopOn, let nw = loopBounds(deck, anchorSec: clamped) {
            loopWindows[deck] = nw
            armLoop(deck)
            refreshTransport()
            startTickIfNeeded()
            rec(.seek, deck, value: clamped)
            updateSystemNowPlaying()
            persistMixDeckSession(debounced: true)
            return
        }
        if stemActive(deck) {                            // stem mode: re-seek + re-sync the 4 stems
            stopStemNodes(deck)
            let ok = scheduleStems(deck, fromSeconds: clamped)
            setPosition(deck, clamped)
            if was, ok { startStems(deck) }
        } else {
            guard built, let file = files[deck], let player = players[deck], let sr = sampleRates[deck],
                  let start = startFrames[deck], let end = endFrames[deck] else { return }
            let frame = min(max(start, start + AVAudioFramePosition(clamped * sr)), end)
            let count = end - frame
            player.stop()
            if count > 0 {
                player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(count),
                                       at: nil, completionHandler: nil)
            }
            fileScheduled[deck] = count > 0
            segmentStartSeconds[deck] = clamped   // the new segment begins `clamped` s into the source
            setPosition(deck, clamped)
            if was, count > 0 {
                if startEngineIfNeeded() { player.play() }   // dead engine → stay scheduled; watchdog resumes
                setPlaying(deck, true)                        // was already playing → no spurious event
            }
        }
        refreshTransport()
        startTickIfNeeded()
        refreshAutoDeckEndIfLive(deck)   // auto-mix: re-time the crossfade to the NEW position
        rec(.seek, deck, value: clamped)
        updateSystemNowPlaying()      // new elapsed on the lock-screen scrubber
        persistMixDeckSession(debounced: true)   // scrub surface — one write per burst
    }

    // MARK: - Loop (∞) — repeat a beat/second window until released

    /// How many copies of the window stay queued ahead of the playhead. The node plays queued
    /// segments back-to-back with no gap, so a loop is sample-accurate BY CONSTRUCTION (no
    /// completion handler, no tick-timed re-seek that would land up to a tick late); the tick only
    /// tops the queue back up. Same 1-bar-horizon doctrine as the Studio sequencer.
    private static let loopHorizonPasses = 3
    /// Resolved windows in SOURCE seconds (runtime plumbing — the durable session stores intent).
    @ObservationIgnored private var loopWindows: [Deck: (start: Double, end: Double)] = [:]
    /// Passes handed to the voices SINCE THE LAST ARM (the node timeline is zeroed by `stop()` in
    /// `armLoop`, so this counter and `sampleTime` share an origin — see `topUpLoop`'s reset guard).
    @ObservationIgnored private var loopPasses: [Deck: Int] = [:]
    /// Last elapsed reading, to catch a node timeline RESET (route change / external stop) that
    /// would otherwise strand the pass arithmetic and silently starve the queue.
    @ObservationIgnored private var loopLastElapsed: [Deck: Double] = [:]
    /// Which stem actually carries the queue (its render clock drives the top-up). nil ⇒ single file.
    @ObservationIgnored private var loopClockStem: [Deck: String] = [:]

    /// Forget everything about a deck's loop — the ONE teardown, called wherever a deck's audio
    /// timeline is rebuilt out from under a window (load, restart/reset, clear, release).
    private func clearLoopState(_ deck: Deck) {
        if state(deck).loopOn { mutate(deck) { $0.loopOn = false } }
        loopWindows[deck] = nil
        loopPasses[deck] = nil
        loopLastElapsed[deck] = nil
        loopClockStem[deck] = nil
    }

    /// Does this deck count loop length in BEATS? True when the track has a measured grid or any
    /// usable bpm to synthesize one; false ⇒ the unit is SECONDS (the documented fallback).
    func loopUsesBeats(_ deck: Deck) -> Bool {
        guard let l = state(deck).loaded else { return false }
        if let b = l.beatsMs, b.count >= 2 { return true }
        return (l.gridBpm ?? l.bpm ?? 0) > 0
    }

    /// One loop unit in seconds — a beat at the deck's grid tempo, else exactly 1 s.
    func loopUnitSeconds(_ deck: Deck) -> Double {
        guard loopUsesBeats(deck) else { return 1 }
        // MEASURED lattice first: `loopUsesBeats` can be true purely on `beatsMs` (the async grid
        // hydrate patches beats WITHOUT a gridBpm), and the window walks that same lattice — so a
        // nominal-bpm unit here would disagree with the window it's supposed to describe.
        if let beats = state(deck).loaded?.beatsMs, beats.count >= 2 {
            let gaps = zip(beats.dropFirst(), beats).map { Double($0 - $1) }.filter { $0 > 0 }.sorted()
            if let median = gaps.isEmpty ? nil : gaps[gaps.count / 2], median > 0 { return median / 1000 }
        }
        let bpm = state(deck).loaded?.gridBpm ?? state(deck).loaded?.bpm ?? 120
        return 60.0 / min(max(bpm, 20), 300)
    }

    func loopOn(_ deck: Deck) -> Bool { state(deck).loopOn }
    func loopUnits(_ deck: Deck) -> Double { state(deck).loopUnits }
    /// The live window (nil unless a loop is armed) — also the test hook for wrap math.
    func loopWindow(_ deck: Deck) -> (start: Double, end: Double)? {
        guard state(deck).loopOn, let w = loopWindows[deck], w.end > w.start else { return nil }
        return w
    }

    /// Resolve the window for `units` around `anchorSec`: snap the START back to the PREVIOUS unit
    /// boundary (the beat you're in — or the previous whole second) and run `units` forward from
    /// there. A measured grid drives both edges through `BeatMath` (so real tempo drift is
    /// honored); otherwise the boundaries are synthesized from bpm + downbeat phase. Clamped into
    /// the deck's window, sliding back rather than shrinking when it would overrun the end.
    private func loopBounds(_ deck: Deck, anchorSec: Double) -> (start: Double, end: Double)? {
        let dur = duration(deck)
        guard dur > 0 else { return nil }
        let units = min(max(state(deck).loopUnits, 1), 32)
        let anchor = min(max(0, anchorSec), dur)
        var start: Double
        var end: Double
        if loopUsesBeats(deck) {
            let l = state(deck).loaded
            let bpm = l?.gridBpm ?? l?.bpm ?? 120
            let period = loopUnitSeconds(deck)
            let anchorMs = anchor * 1000
            if let beats = l?.beatsMs, beats.count >= 2 {
                let prevMs = BeatMath.lastBeat(beatsMs: beats, downbeatsMs: l?.downbeatsMs,
                                               atMs: anchorMs)?.beatMs
                let startMs = Double(prevMs ?? Int(anchorMs))
                // Walk `units` beats off the MEASURED lattice (drift-correct); the helper
                // synthesizes past the last measured beat at a constant period.
                if let sb = BeatMath.sliceBoundaries(
                    anchorMs: Int(startMs.rounded()), beats: units,
                    grid: (bpm: bpm, firstDownbeatMs: l?.firstDownbeatMs ?? 0, beatsMs: beats)) {
                    start = Double(sb.startMs) / 1000
                    end = Double(sb.endMs) / 1000
                } else {
                    start = startMs / 1000
                    end = start + units * period
                }
            } else {
                // No measured beats — synthesize the lattice off the downbeat phase + tempo.
                return Self.loopWindowMath(anchorSec: anchor,
                                           phaseSec: Double(l?.firstDownbeatMs ?? 0) / 1000,
                                           unitSeconds: period, units: units, durationSec: dur)
            }
        } else {
            return Self.loopWindowMath(anchorSec: anchor, phaseSec: 0,   // previous whole second
                                       unitSeconds: 1, units: units, durationSec: dur)
        }
        return Self.clampLoopWindow(start: start, end: end, durationSec: dur)
    }

    /// Snap `anchor` back to the previous unit boundary off `phase`, then run `units` forward —
    /// the ungridded (and synthesized-grid) path. Pure + testable without an audio device.
    nonisolated static func loopWindowMath(anchorSec: Double, phaseSec: Double, unitSeconds: Double,
                                           units: Double, durationSec: Double) -> (start: Double, end: Double)? {
        guard unitSeconds > 0, units > 0, durationSec > 0 else { return nil }
        let anchor = min(max(0, anchorSec), durationSec)
        let rel = anchor - phaseSec
        let start = rel >= 0 ? phaseSec + floor(rel / unitSeconds) * unitSeconds : phaseSec
        return clampLoopWindow(start: start, end: start + units * unitSeconds, durationSec: durationSec)
    }

    /// Fit a window inside the deck: enforce a floor length (a sub-50 ms window is a click, not a
    /// loop) and, when it would overrun the end, SLIDE it back rather than shrink it — a 4-beat
    /// loop stays 4 beats even when engaged in the last bar. Pure + testable.
    nonisolated static func clampLoopWindow(start: Double, end: Double,
                                            durationSec: Double) -> (start: Double, end: Double)? {
        guard durationSec > 0 else { return nil }
        var s = start
        let len = min(max(end - s, 0.05), durationSec)
        var e = s + len
        if e > durationSec { e = durationSec; s = max(0, e - len) }   // slide back, keep the length
        if s < 0 { s = 0; e = min(durationSec, len) }
        guard e > s else { return nil }
        return (s, e)
    }

    /// (Re)queue the window on the deck's voices — the single file, or ALL FOUR stems in stem mode
    /// (they're sample-aligned and restarted at one shared host time, so queueing the same window
    /// on each keeps them locked together exactly as normal stem playback does).
    /// (Re)queue the window. `resumeAt` (when inside the window) keeps the playhead where it is by
    /// queueing a PARTIAL first pass from there — so re-arming for a length tweak or an engine
    /// comeback doesn't yank the audio back to the top of the loop.
    ///
    /// Order is load-bearing: prove the window is schedulable BEFORE stopping any voice. Stopping
    /// first and then failing to schedule leaves a deck that reports Playing while rendering
    /// silence — the exact trap `setStemMode` documents ("schedule BEFORE muting… only commit if
    /// they actually scheduled").
    @discardableResult
    private func armLoop(_ deck: Deck, resumeAt: Double? = nil) -> Bool {
        guard let w = loopWindow(deck), built else { return false }
        guard loopSchedulable(deck, window: w) else { return false }   // ← check before any stop()
        let was = state(deck).isPlaying
        // A resume point strictly inside the window becomes a shorter FIRST pass; the tail passes
        // are whole windows, so the loop is phase-continuous from wherever it already was.
        let head: (start: Double, end: Double)? = {
            guard let r = resumeAt, r > w.start + 0.02, r < w.end - 0.02 else { return nil }
            return (r, w.end)
        }()
        let stems = stemActive(deck)
        if stems { stopStemNodes(deck) } else { players[deck]?.stop() }   // zeroes the node timeline
        var passes = Self.loopHorizonPasses
        if let head {
            guard scheduleLoopPasses(deck, window: head, passes: 1) else { return false }
            passes -= 1
        }
        if passes > 0 { scheduleLoopPasses(deck, window: w, passes: passes) }
        loopPasses[deck] = Self.loopHorizonPasses     // head + tails = one horizon's worth
        loopLastElapsed[deck] = 0                     // fresh timeline origin
        let from = head?.start ?? w.start
        if !stems { segmentStartSeconds[deck] = from }
        setPosition(deck, from)
        if was {
            if stems { startStems(deck) }
            else if startEngineIfNeeded() { players[deck]?.play(); setPlaying(deck, true) }
        }
        refreshTransport()
        startTickIfNeeded()
        return true
    }

    /// Would `scheduleLoopPasses` produce any audio for this window? Pure check — no side effects.
    private func loopSchedulable(_ deck: Deck, window w: (start: Double, end: Double)) -> Bool {
        if stemActive(deck) {
            guard let stems = stemFiles[deck], let nodes = stemPlayers[deck] else { return false }
            return nodes.contains { name, _ in
                guard let f = stems[name] else { return false }
                let sr = f.processingFormat.sampleRate
                guard sr > 0 else { return false }
                let f0 = min(max(0, AVAudioFramePosition(w.start * sr)), f.length)
                let f1 = min(max(f0, AVAudioFramePosition(w.end * sr)), f.length)
                return f1 - f0 > 0
            }
        }
        guard files[deck] != nil, players[deck] != nil, let sr = sampleRates[deck], sr > 0,
              let startF = startFrames[deck], let endF = endFrames[deck] else { return false }
        let f0 = min(max(startF, startF + AVAudioFramePosition(w.start * sr)), endF)
        let f1 = min(max(f0, startF + AVAudioFramePosition(w.end * sr)), endF)
        return f1 - f0 > 0
    }

    /// Append `passes` copies of the window to the deck's voice(s). Handles both modes; returns
    /// false when nothing could be queued (no file / zero-frame window).
    @discardableResult
    private func scheduleLoopPasses(_ deck: Deck, window w: (start: Double, end: Double),
                                    passes: Int) -> Bool {
        guard passes > 0 else { return false }
        if stemActive(deck) {
            guard let stems = stemFiles[deck], let nodes = stemPlayers[deck] else { return false }
            var any = false
            for name in Self.stemNames {          // canonical order ⇒ a deterministic clock stem
                guard let node = nodes[name], let file = stems[name] else { continue }
                let sr = file.processingFormat.sampleRate
                guard sr > 0 else { continue }
                // Stem files start at the SONG's 0:00 (no album offset), so the window maps directly.
                let f0 = min(max(0, AVAudioFramePosition(w.start * sr)), file.length)
                let f1 = min(max(f0, AVAudioFramePosition(w.end * sr)), file.length)
                let count = f1 - f0
                guard count > 0 else { continue }
                for _ in 0..<passes {
                    node.scheduleSegment(file, startingFrame: f0, frameCount: AVAudioFrameCount(count),
                                         at: nil, completionHandler: nil)
                }
                // The FIRST stem that really received frames owns the top-up clock: reading a node
                // with an empty queue would report an elapsed that never advances.
                if !any { loopClockStem[deck] = name }
                any = true
            }
            if any { stemsScheduled[deck] = true }
            return any
        }
        guard let file = files[deck], let player = players[deck], let sr = sampleRates[deck], sr > 0,
              let startF = startFrames[deck], let endF = endFrames[deck] else { return false }
        let f0 = min(max(startF, startF + AVAudioFramePosition(w.start * sr)), endF)
        let f1 = min(max(f0, startF + AVAudioFramePosition(w.end * sr)), endF)
        let count = f1 - f0
        guard count > 0 else { return false }
        for _ in 0..<passes {
            player.scheduleSegment(file, startingFrame: f0, frameCount: AVAudioFrameCount(count),
                                   at: nil, completionHandler: nil)
        }
        fileScheduled[deck] = true
        return true
    }

    /// The render clock representing the deck: its player, or any stem node (all four are started
    /// at one shared host time, so any of them reports the same elapsed).
    private func loopClock(_ deck: Deck) -> (node: AVAudioPlayerNode, sampleRate: Double)? {
        if stemActive(deck) {
            // The stem the queue was actually written to (recorded at schedule time) — NOT merely
            // the first canonical one, which may have had no frames in this window.
            guard let name = loopClockStem[deck], let n = stemPlayers[deck]?[name],
                  let f = stemFiles[deck]?[name], f.processingFormat.sampleRate > 0 else { return nil }
            return (n, f.processingFormat.sampleRate)
        }
        guard let p = players[deck], let sr = sampleRates[deck], sr > 0 else { return nil }
        return (p, sr)
    }

    /// Tick duty: keep `loopHorizonPasses` copies queued ahead of what the node has consumed, so
    /// the loop never runs out of scheduled audio (the seam that would otherwise click).
    private func topUpLoop(_ deck: Deck) {
        guard state(deck).isPlaying, let w = loopWindow(deck),
              let clock = loopClock(deck),
              let nodeTime = clock.node.lastRenderTime,
              let pt = clock.node.playerTime(forNodeTime: nodeTime) else { return }
        let len = w.end - w.start
        guard len > 0 else { return }
        // The node timeline is in SOURCE frames, so a tempo change doesn't distort this count —
        // it only changes how fast passes are consumed in wall time.
        let elapsed = max(0, Double(pt.sampleTime) / clock.sampleRate)
        // TIMELINE RESET: anything that stops the node outside `armLoop` (route/config change →
        // engine rebuild, an external stop) zeroes `sampleTime` while `loopPasses` keeps its old
        // count — after which `want <= scheduled` forever and the queue silently starves to dead
        // air. Detect the rewind and re-arm in place instead.
        if let last = loopLastElapsed[deck], elapsed + 0.05 < last {
            let resume = w.start + elapsed.truncatingRemainder(dividingBy: len)
            dlog("loop \(deck.rawValue): node timeline reset — re-arming")
            armLoop(deck, resumeAt: resume)
            return
        }
        loopLastElapsed[deck] = elapsed
        let consumed = Int(floor(elapsed / len))
        let scheduled = loopPasses[deck] ?? 0
        let want = consumed + Self.loopHorizonPasses
        guard want > scheduled else { return }
        if scheduleLoopPasses(deck, window: w, passes: want - scheduled) { loopPasses[deck] = want }
    }

    /// Engage / release the loop. Engaging arms a window around the CURRENT playhead; releasing
    /// re-schedules the rest of the track from wherever inside the window you were, so the audio
    /// carries straight on (and the auto-mix crossfade re-times against the real runway).
    func setLoop(_ deck: Deck, on: Bool) {
        guard state(deck).loaded != nil, on != state(deck).loopOn else { return }
        if on {
            if let songId = state(deck).loaded?.songId {
                hydrateBeatGrid(deck, songId: songId, force: true)   // beats need the grid NOW
            }
            let anchor = truePlayhead(deck) ?? position(deck)
            guard let w = loopBounds(deck, anchorSec: anchor) else { return }
            mutate(deck) { $0.loopOn = true }
            loopWindows[deck] = w
            // COMMIT ONLY ON SUCCESS: a window that can't schedule (e.g. past the end of the
            // burned stems) must leave the deck exactly as it was, never lit-but-silent.
            guard armLoop(deck, resumeAt: anchor) else {
                clearLoopState(deck)
                dlog("loop ON \(deck.rawValue) REFUSED — window not schedulable")
                return
            }
            dlog("loop ON \(deck.rawValue) \(String(format: "%.2f–%.2f", w.start, w.end))s "
                 + "(\(Int(state(deck).loopUnits)) \(loopUsesBeats(deck) ? "beat" : "sec"))")
        } else {
            let resume = truePlayhead(deck) ?? position(deck)
            clearLoopState(deck)
            seek(deck, toSeconds: resume)   // re-arms the rest of the track + re-times auto-mix
            dlog("loop OFF \(deck.rawValue) → \(String(format: "%.2f", resume))s")
        }
        persistMixDeckSession()   // discrete tap — persist immediately
    }

    /// Set the loop LENGTH in units (1…32). Keeps the window's start; re-arms when live.
    func setLoopUnits(_ deck: Deck, _ units: Double) {
        let u = min(max(units.rounded(), 1), 32)
        guard u != state(deck).loopUnits else { return }
        mutate(deck) { $0.loopUnits = u }
        if state(deck).loopOn, let w = loopWindows[deck], let nw = loopBounds(deck, anchorSec: w.start) {
            // Keep playing where we are: dragging the length slider issues a re-arm per step, and
            // restarting each one from the top of the window would machine-gun the loop.
            let here = truePlayhead(deck) ?? position(deck)
            loopWindows[deck] = nw
            armLoop(deck, resumeAt: (here > nw.start && here < nw.end) ? here : nil)
        }
        persistMixDeckSession(debounced: true)   // slider surface — one write per burst
    }

    /// Nudge one EDGE by ±1 unit (the popover's ← → arrows). Moving an edge changes the loop's
    /// length, so `loopUnits` follows; both stay inside 1…32 units and the deck's window.
    func nudgeLoop(_ deck: Deck, edge: LoopEdge, byUnits delta: Double) {
        guard let w = loopWindow(deck) else { return }
        let unit = loopUnitSeconds(deck)
        let step = unit * delta
        let dur = duration(deck)
        var (s, e) = (w.start, w.end)
        switch edge {
        case .start: s = min(max(0, s + step), e - unit)
        case .end:   e = min(max(e + step, s + unit), dur)
        }
        // Clamp the WINDOW to the same 1…32 units the slider exposes — clamping only the derived
        // count would let repeated nudges grow a real 40-unit loop while the stored length reads
        // 32, after which the slider's equality guard makes the mismatch unfixable.
        let maxLen = 32 * unit
        if e - s > maxLen {
            if edge == .start { s = e - maxLen } else { e = s + maxLen }
        }
        guard e > s else { return }
        let units = min(max(((e - s) / unit).rounded(), 1), 32)
        let here = truePlayhead(deck) ?? position(deck)
        loopWindows[deck] = (s, e)
        mutate(deck) { $0.loopUnits = units }
        armLoop(deck, resumeAt: (here > s && here < e) ? here : nil)
        persistMixDeckSession(debounced: true)
    }

    enum LoopEdge { case start, end }

    /// After a manual SEEK of the auto-mix live deck, re-stamp when it will end (wall-clock, allowing
    /// for tempo) so the crossfade fires relative to the NEW position. Sliding a song near its end now
    /// auto-mixes on time (capped by the crossfade lead/length) instead of playing silently past it.
    private func refreshAutoDeckEndIfLive(_ deck: Deck) {
        guard autoMixing, deck == autoLiveDeck, !autoTransitioning else { return }
        checkpointEngineStall()   // a mid-stall seek's fresh stamp gets only the stall that follows it
        let durMs = autoDeckDurationMs[deck] ?? Self.autoFallbackDurationMs
        let remaining = max(0, Double(durMs) / 1000 - position(deck)) / max(0.05, state(deck).rate)
        autoDeckEndsAt[deck] = Date().addingTimeInterval(remaining)
    }

    // MARK: - Tempo / pitch / beat-match

    func setRate(_ rate: Double, on deck: Deck) {
        mutate(deck) { $0.rate = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound) }
        applyRate(deck)
        rec(.tempo, deck, value: state(deck).rate)
        persistMixDeckSession(debounced: true)   // slider surface — one write per burst
    }

    func setPitch(_ semitones: Double, on deck: Deck) {
        mutate(deck) { $0.pitch = min(max(semitones, Self.pitchRange.lowerBound), Self.pitchRange.upperBound) }
        applyPitch(deck)
        rec(.pitch, deck, value: state(deck).pitch)
        persistMixDeckSession(debounced: true)   // slider surface — one write per burst
    }

    // MARK: - 3-band EQ

    func eqGain(_ band: EQBand, on deck: Deck) -> Double { state(deck).eqGain(band) }
    func setEqGain(_ band: EQBand, _ db: Double, on deck: Deck) {
        mutate(deck) { $0.setEqGain(band, min(max(db, Self.eqRange.lowerBound), Self.eqRange.upperBound)) }
        applyEQ(band, on: deck)
        rec(.eq, deck, param: "\(band)", value: state(deck).eqGain(band))
        persistMixDeckSession(debounced: true)   // knob surface — one write per burst
    }

    // MARK: - Filter mode (low-pass / high-pass)
    //
    // The pre-rack LP/HP API, now expressed as the FIRST filter slot's variant. Superseded by the
    // general `setSlotVariant` (any slot, any family) once the rack UI lands; kept here so the
    // existing call sites keep working unchanged.

    func filterMode(_ deck: Deck) -> FilterMode {
        guard let i = state(deck).firstSlot(.filter) else { return .lowPass }
        return state(deck).slots[i].variant == .highPass ? .highPass : .lowPass
    }
    func setFilterMode(_ mode: FilterMode, on deck: Deck) {
        guard let i = state(deck).firstSlot(.filter) else { return }
        mutate(deck) { $0.slots[i].setVariant(mode == .highPass ? .highPass : .lowPass) }
        applyEffect(.filter, on: deck)
        rec(.filterMode, deck, param: mode.rawValue)
        persistMixDeckSession()                  // discrete tap — persist immediately
    }

    /// Designate (or clear) the Lead deck for beat-matching. Tapping the current lead clears it.
    func setLead(_ deck: Deck) {
        leadDeck = (leadDeck == deck) ? nil : deck
        rec(.lead, deck, flag: isLead(deck))
        persistMixDeckSession()
    }
    func isLead(_ deck: Deck) -> Bool { leadDeck == deck }

    /// Match the follower's effective BPM to the Lead (rate = leadBPM·leadRate / followerBPM,
    /// octave-folded into range), then best-effort phase-align the downbeats. Prefers each deck's
    /// MEASURED grid BPM (rips indexer) over the catalog. No-op if there's no Lead, the follower IS
    /// the lead, or a BPM is unknown.
    func syncToLead(_ follower: Deck) {
        guard let lead = leadDeck, lead != follower,
              let leadBPM = matchBPM(lead), let folBPM = matchBPM(follower) else { return }
        setRate(Self.syncRate(leadBPM: leadBPM, leadRate: state(lead).rate, followerBPM: folBPM), on: follower)
        phaseAlign(follower: follower, lead: lead)
        // A `.sync` marker rides alongside the real `.tempo` (and the phase-align `.seek`) it caused —
        // replay applies all; consumers counting gestures dedupe on `.sync`. value = the matched rate.
        rec(.sync, follower, value: state(follower).rate)
    }

    /// Whether a follower CAN sync (there's a lead ≠ this deck, both with a known BPM).
    func canSync(_ deck: Deck) -> Bool {
        guard let lead = leadDeck, lead != deck, matchBPM(lead) != nil, matchBPM(deck) != nil else { return false }
        return true
    }

    /// The BPM to beat-match on: the MEASURED grid BPM (from the rips indexer) when available — it's
    /// measured on the exact burned file, so it avoids the catalog's rounded-BPM drift — else the
    /// catalog BPM. nil if neither is known.
    private func matchBPM(_ deck: Deck) -> Double? {
        let l = state(deck).loaded
        if let g = l?.gridBpm, g > 0 { return g }
        if let b = l?.bpm, b > 0 { return b }
        return nil
    }

    // MARK: - Volume / crossfader / effects

    func setVolume(_ volume: Double, on deck: Deck) {
        mutate(deck) { $0.volume = min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound) }
        applyMixGains()       // 0…1 portion (+ equal-power crossfade) on the source nodes
        applyBoost(deck)      // >unity portion on the deck's EQ globalGain (volume-change only)
        rec(.volume, deck, value: state(deck).volume)
        persistMixDeckSession(debounced: true)   // slider surface — one write per burst
    }

    func setCrossfader(_ value: Double) {
        applyCrossfader(value)
        rec(.crossfader, nil, value: crossfader)
        persistMixDeckSession(debounced: true)   // slider surface — one write per burst
    }

    // MARK: - Cue / PFL (pre-fade listen)

    /// Whether a deck is currently cued (its pre-fader monitor send is live).
    func cued(_ deck: Deck) -> Bool { state(deck).cued }
    /// The deck's independent cue/monitor level (0…1).
    func cueVolume(_ deck: Deck) -> Double { state(deck).cueVol }
    /// True while EITHER deck is cued — drives the main/cue hard-pan split (see `applyCueRouting`).
    var anyCued: Bool { deckA.cued || deckB.cued }

    /// Toggle a deck's pre-fade-listen send on/off (the cue button). The house mix is untouched.
    func setCued(_ on: Bool, on deck: Deck) {
        mutate(deck) { $0.cued = on }
        applyCueRouting()
    }
    func toggleCue(_ deck: Deck) { setCued(!state(deck).cued, on: deck) }

    /// Set a deck's cue/monitor level (the long-press cue-volume slider). Clamped 0…1.
    func setCueVolume(_ value: Double, on deck: Deck) {
        mutate(deck) { $0.cueVol = min(max(value, 0), 1) }
        applyCueRouting()
    }

    /// Pick which output channel the cue/monitor bus pans to (true ⇒ right, main on the left). Pushed
    /// in from the Settings tab; applies live.
    func setCueOnRight(_ right: Bool) {
        cueOnRight = right
        applyCueRouting()
    }

    // MARK: - Beat grid (pulse data)

    /// Mirror the Mix beat-pulse setting (pushed from the view). When turned ON, hydrate the per-beat
    /// grid for whatever's already loaded so an enabled pulse is precise immediately; when OFF we
    /// simply stop fetching grids on load.
    func setBeatPulseEnabled(_ on: Bool) {
        beatPulseEnabled = on
        guard on else { return }
        for d in Deck.allCases { if let id = state(d).loaded?.songId { hydrateBeatGrid(d, songId: id) } }
    }

    /// Attach the song's full per-beat grid to the deck's `LoadedTrack` so the pulse can phase-lock to
    /// the real beats. Uses the LOCAL sidecar synchronously if it's already burned; otherwise — only
    /// when the pulse is enabled — downloads it in the background and patches the deck if it's still
    /// showing this song. A no-op when the song has no sidecar (the pulse falls back to synthesis).
    /// `force` bypasses the beat-pulse opt-in: engaging a LOOP needs real beats now, whether or not
    /// the pulse visual is on (without it a beat loop would silently fall back to synthesis).
    private func hydrateBeatGrid(_ deck: Deck, songId: String, force: Bool = false) {
        if state(deck).loaded?.beatsMs != nil { return }                 // already hydrated
        if let local = burns.localBeatGrid(forSong: songId), !local.beatsMs.isEmpty {
            mutate(deck) { $0.loaded?.beatsMs = local.beatsMs; $0.loaded?.downbeatsMs = local.downbeatsMs }
            return
        }
        guard beatPulseEnabled || force else { return }                  // OFF ⇒ never download on load
        Task { [weak self] in
            guard let self, let sc = await self.burns.burnBeatGrid(forSong: songId), !sc.beatsMs.isEmpty else { return }
            guard self.state(deck).loaded?.songId == songId else { return }   // deck moved on → drop it
            self.mutate(deck) { $0.loaded?.beatsMs = sc.beatsMs; $0.loaded?.downbeatsMs = sc.downbeatsMs }
            // A loop armed BEFORE the download landed was resolved against synthesized beats (this
            // fetch is why `force` exists) — re-resolve it on the real lattice now that it's here,
            // keeping the playhead in place.
            guard self.loopWindow(deck) != nil else { return }
            let here = self.truePlayhead(deck) ?? self.position(deck)
            guard let nw = self.loopBounds(deck, anchorSec: here) else { return }
            self.loopWindows[deck] = nw
            self.armLoop(deck, resumeAt: (here > nw.start && here < nw.end) ? here : nil)
        }
    }

    /// Diagnostics / tests: the live send levels + pans on a deck's main + cue buses (nil until the
    /// graph is built). Lets a real-graph test assert the PFL routing without reaching into AVAudio.
    func cueRoutingSnapshot(_ deck: Deck) -> (mainVol: Float, cueVol: Float, mainPan: Float, cuePan: Float)? {
        guard let m = mainGains[deck], let c = cueGains[deck] else { return nil }
        // The house pan now lives on the shared `housePan` (post-tap) rather than per-deck `mainGains`.
        return (m.outputVolume, c.outputVolume, housePan?.pan ?? 0, c.pan)
    }

    /// Diagnostics / tests: a stem node's live `volume` (nil until the graph is built). Used to assert
    /// stems carry ONLY their per-stem balance (the deck volume + crossfade live downstream, so the
    /// deck gain isn't applied twice in stem mode).
    func stemNodeVolume(_ name: String, on deck: Deck) -> Float? { stemPlayers[deck]?[name]?.volume }

    /// Non-recording crossfade apply. The auto-DJ internals use THIS so machine moves aren't logged as
    /// user `.crossfader` gestures (and a Manual→Auto→Manual toggle on an idle session stays empty —
    /// no phantom event that would materialize a junk "Session N" on Reset).
    private func applyCrossfader(_ value: Double) {
        crossfader = min(max(value, 0), 1)
        applyCueRouting()     // crossfade lives on the main bus now — NOT applyBoost (keeps globalGain off the fade path)
    }

    func setEffect(_ effect: Effect, enabled: Bool, on deck: Deck) {
        mutate(deck) { $0.set(effect, enabled) }
        applyEffect(effect, on: deck)
        rec(.effectToggle, deck, param: effect.rawValue, flag: enabled)
        persistMixDeckSession()                  // discrete tap — persist immediately
    }

    /// Per-deck per-effect STRENGTH (0…1) — the wet amount / cutoff / threshold the long-press popup
    /// dials in. Always stored; only audible while the effect is enabled.
    func setEffectStrength(_ effect: Effect, _ strength: Double, on deck: Deck) {
        mutate(deck) { $0.setStrength(effect, strength) }
        applyEffect(effect, on: deck)
        rec(.effectStrength, deck, param: effect.rawValue, value: state(deck).strength(effect))
        persistMixDeckSession(debounced: true)   // slider surface — one write per burst
    }

    // MARK: - FX rack (slot-indexed)
    //
    // The Mix deck's own API. Unlike the effect-keyed calls above, these address a rack POSITION, so
    // they stay exact when the rack holds duplicates (two compressors, an LP and an HP filter, …).

    nonisolated static var fxSlotCount: Int { 4 }

    func slots(_ deck: Deck) -> [FXSlot] { state(deck).slots }
    func slot(_ i: Int, on deck: Deck) -> FXSlot? { state(deck).slots[safe: i] }

    func setSlot(_ i: Int, enabled: Bool, on deck: Deck) {
        guard let s = state(deck).slots[safe: i], s.enabled != enabled else { return }
        mutate(deck) { $0.slots[i].enabled = enabled }
        applySlot(i, on: deck)
        startModTickIfNeeded()                   // an enabled modulated slot may now need the tick
        rec(.effectToggle, deck, param: s.effect.rawValue, flag: enabled, slot: i)
        persistMixDeckSession()                  // discrete tap — persist immediately
    }

    func setSlotStrength(_ i: Int, _ strength: Double, on deck: Deck) {
        guard state(deck).slots[safe: i] != nil else { return }
        mutate(deck) { $0.slots[i].setStrength(strength) }
        applySlot(i, on: deck)
        let s = state(deck).slots[i]
        rec(.effectStrength, deck, param: s.effect.rawValue, value: s.strength, slot: i)
        persistMixDeckSession(debounced: true)   // slider surface — one write per burst
    }

    /// Swap which effect family a slot holds. The variant resets to that family's default, and the
    /// slot keeps its on/off + strength so a swap mid-build doesn't drop out or jump in level.
    func setSlotEffect(_ effect: Effect, slot i: Int, on deck: Deck) {
        guard let s = state(deck).slots[safe: i], s.effect != effect else { return }
        mutate(deck) { $0.slots[i].setEffect(effect) }
        applySlot(i, on: deck)
        rec(.effectSlot, deck, param: effect.rawValue, slot: i)
        persistMixDeckSession()
    }

    /// Set a slot's modulation configuration (source / musical rate / signed depth / shape /
    /// phase offset). Persists as user intent; the LIVE modulated value is runtime plumbing and
    /// never touches the stored slot.
    func setSlotMod(_ mod: SlotMod, slot i: Int, on deck: Deck) {
        guard let s = state(deck).slots[safe: i], s.mod != mod else { return }
        mutate(deck) { $0.slots[i].mod = mod }
        applySlot(i, on: deck)
        // A beat-synced LFO needs the MEASURED grid NOW — the lazy download is gated on the Beat
        // pulse setting (off by default), so force it exactly like arming a loop does. Without
        // this most decks would silently degrade to the catalog-BPM lattice.
        if mod.source == .lfo, let id = state(deck).loaded?.songId {
            hydrateBeatGrid(deck, songId: id, force: true)
        }
        rec(.effectMod, deck, param: "\(mod.source.rawValue):\(mod.rate.rawValue):\(mod.shape.rawValue)",
            value: mod.depth, slot: i)
        startModTickIfNeeded()                   // may have just become worth ticking
        persistMixDeckSession()                  // discrete config change — persist immediately
    }

    /// Pick a different variety of the effect a slot already holds (LP→HP, Hall→Plate, …).
    func setSlotVariant(_ variant: EffectVariant, slot i: Int, on deck: Deck) {
        guard let s = state(deck).slots[safe: i],
              s.variant != variant, variant.effect == s.effect else { return }
        mutate(deck) { $0.slots[i].setVariant(variant) }
        applySlot(i, on: deck)
        rec(.effectVariant, deck, param: variant.rawValue, slot: i)
        persistMixDeckSession()
    }

    // MARK: - Auto-Mix (auto-DJ)

    private static let autoFallbackDurationMs = 180_000

    func setAutoEnabled(_ on: Bool) {
        autoEnabled = on
        if !on { endAutoLoop() }
    }

    /// Toggle FX Glide / Mix Glide (the auto-mix pill). Safe to flip mid-mix: an in-flight transition
    /// finishes in the mode it began; the change applies to the NEXT transition.
    func setFXGlide(_ on: Bool) {
        fxGlideEnabled = on
        DiagLog.shared.telemetry("action", "fx glide \(on ? "on" : "off")")
    }
    func setMixGlide(_ on: Bool) {
        mixGlideEnabled = on
        DiagLog.shared.telemetry("action", "audio glide \(on ? "on" : "off")")
    }

    /// Whether either glide feature is armed (⇒ a transition uses the pre/post-roll machine).
    private var anyGlide: Bool { fxGlideEnabled || mixGlideEnabled }
    /// A transition (preroll, crossfade, or postroll) is in progress.
    /// PUBLIC READ for remote surfaces: the TV's tempo/pitch steppers gray out while a
    /// transition (pre-roll → fade → post-roll, incl. any glide) owns the decks — a manual
    /// nudge mid-glide would fight the Auto DJ's own rate/pitch ramps.
    var autoTransitioning: Bool {
        autoPrerollStartedAt != nil || autoFadeStartedAt != nil || autoPostrollStartedAt != nil
    }

    func startAutoMix(_ items: [AutoMixItem], shuffled: Bool, lead: Double, fade: Double,
                      label: String? = nil) {
        guard !items.isEmpty else { return }
        DiagLog.shared.telemetry("action", "auto-mix start '\(label ?? "?")' items=\(items.count) shuffled=\(shuffled)")
        ensureEngine()
        endAutoLoop()

        // BUG FIX (two songs at once): starting an Auto Mix takes over BOTH decks, so fully EJECT
        // them first — stop any already-playing deck (deck B kept sounding under the new mix) and
        // return every per-deck parameter to default: volume/boost, effects + strengths, stem
        // toggles, loops, AND the cue/PFL send (`resetDeck` deliberately keeps cue; the eject
        // doesn't). Manual deck starts never come through here, so hand-mixing is untouched.
        ejectDeckCore(.a)
        ejectDeckCore(.b)
        rec(.resetDeck, .a); rec(.resetDeck, .b)   // honest timeline: the auto start wiped both decks
        masterPausedDecks = []   // stale lock-screen pause memory dies with the old mix
        autoEndedExhausted = false

        autoEnabled = true
        autoSourceLabel = label
        autoLeadSeconds = max(1, lead)
        autoFadeSeconds = max(0.2, fade)
        pendingFadeRestore = nil
        autoQueue = shuffled ? items.shuffled() : items
        autoLivePos = 0
        autoLiveDeck = .a
        autoPaused = false
        autoResumeEndDeck = nil
        autoResumeFromRestore = false
        autoTransitionRepeatOne = false
        autoTransitionWrap = false
        resumeAutoOnRemotePlay = false
        remotePausedAt = nil
        autoFadeStartedAt = nil
        autoDeckEndsAt = [:]
        autoDeckDurationMs = [:]
        // Reset the glide machine + seed the (deterministic) FX texture PRNG for this mix.
        autoPrerollStartedAt = nil; autoPostrollStartedAt = nil
        autoTransitionIsGlide = false; glideCtx = nil
        fxTextureEffect = nil; fxTextureRunRemaining = 0
        fxGlidePrng = Self.fxSeed(from: autoQueue)

        applyCrossfader(0)
        // A queue item whose file vanished (purged burn / detached folder) must not claim a deck —
        // the machine would burn a whole transition on silence. Drop unloadable LEADING items, then
        // preload the next loadable onto B; ALL unloadable ⇒ no mix (mirrors the empty-queue guard).
        while !autoQueue.isEmpty, !loadAuto(autoQueue[0], onto: .a) { autoQueue.removeFirst() }
        guard !autoQueue.isEmpty else {
            refreshAutoStatus()
            persistMixDeckSession()   // the eject above emptied both decks — land that state
            return
        }
        while autoQueue.count > 1, !loadAuto(autoQueue[1], onto: .b) { autoQueue.remove(at: 1) }
        autoNextToLoad = min(2, autoQueue.count)

        let now = Date()
        autoDeckEndsAt[.a] = now.addingTimeInterval(Double(autoDeckDurationMs[.a] ?? Self.autoFallbackDurationMs) / 1000)
        autoMixing = true
        setLockScreenSkipCommandsEnabled(true)   // lock-screen ⏭/⏮ = fast/slow auto-mix skip
        play(.a)
        startTickIfNeeded()
        refreshAutoStatus()
        persistMixDeckSession()   // the whole (post-shuffle) queue + cursor — survives a kill
    }

    func stopAutoMix() {
        DiagLog.shared.telemetry("action", "auto-mix stop")
        autoEndedExhausted = false   // user-initiated stop by default; exhaust sites re-set it after
        endAutoLoop()
        pauseBoth()
    }

    /// PAUSE the auto-DJ without stopping it: suspends the transition machine so you can take the decks
    /// over by hand. Playback and any in-flight recording keep running untouched — only the auto-advance
    /// (and the auto-stop-at-end-of-queue) is gated. Recorded as one `.autoPause` timeline marker.
    /// No-op unless a mix is actively running (and not already paused).
    func pauseAuto() {
        guard autoMixing, !autoPaused else { return }
        autoPaused = true
        autoResumeEndDeck = nil        // a fresh pause clears any stale resume-handoff intent
        rec(.autoPause)
        refreshAutoStatus()
        persistMixDeckSession()
    }

    /// RESUME the auto-DJ after a manual interlude. Rather than cutting whatever's playing, it re-arms
    /// the machine against the CURRENT live playback so the next transition lands naturally:
    ///  • ONE deck playing  → arm its end from its REAL remaining time; the machine waits for the
    ///    crossfade window, then loads the next unplayed track onto the free deck and fades over.
    ///  • BOTH decks playing (a manual blend) → keep the later-ending deck as the survivor and WATCH the
    ///    soonest-ending one; the instant it finishes, load the next unplayed track onto that freed deck
    ///    and glide the survivor over (idle-tick `autoResumeEndDeck` + `beginResumeHandoff`).
    ///  • NEITHER playing → restart the live deck (its track, or the next unplayed) before arming.
    /// Recorded as one `.autoResume` marker. No-op unless a mix is paused.
    func resumeAuto() {
        guard autoMixing, autoPaused else { return }
        let fromRestore = autoResumeFromRestore
        autoResumeFromRestore = false    // consume-once: only the FIRST resume after a restore
        unfreezeAutoClock()              // an IN-APP Resume after a lock-screen ⏸ must also unpark the
                                         // machine's frozen wall clock, or autoFire stays gated forever
        checkpointEngineStall()          // resuming mid-stall: the fresh end stamps below must only be
                                         // shifted by the stall time that FOLLOWS them
        autoPaused = false
        resumeAutoOnRemotePlay = false   // ANY resume consumes the remote-restore intent — a later
                                         // deliberate in-app pause must not be resurrected by a stray
                                         // remote play (Siri / CarPlay reconnect re-sends).
        rec(.autoResume)
        // Mid-transition: the (possibly just-unfrozen) pre-roll/fade owns both decks — lifting the
        // pause gate is all that's needed. The blend re-arm below would fight it: it watches the
        // OUTGOING deck and would fire a second, immediate handoff the moment the fade retires it,
        // double-skipping the track the mix was fading INTO.
        if autoTransitioning { refreshAutoStatus(); startTickIfNeeded(); persistMixDeckSession(); return }
        let now = Date()
        let aOn = state(.a).isPlaying, bOn = state(.b).isPlaying

        if aOn && bOn {
            // Two decks blended: the later-ending deck stays live; watch the other and hand off when it ends.
            let remA = max(0, duration(.a) - position(.a)), remB = max(0, duration(.b) - position(.b))
            let survivor: Deck = remA >= remB ? .a : .b            // ends LAST → stays live
            autoLiveDeck = survivor
            autoResumeEndDeck = other(survivor)                    // ends FIRST → handoff trigger
            autoDeckEndsAt[survivor] = now.addingTimeInterval(survivor == .a ? remA : remB)
            refreshAutoStatus(); startTickIfNeeded(); persistMixDeckSession()
            return
        }

        // One (or zero) deck playing → establish a single live deck + preload the next unplayed track.
        let live: Deck = aOn ? .a : (bOn ? .b : autoLiveDeck)
        if !aOn && !bOn {                                          // nothing playing — get the live deck going again
            if state(live).loaded == nil { loadNextUnplayed(onto: live) }
            if state(live).loaded != nil { play(live) }
        }
        autoLiveDeck = live
        autoResumeEndDeck = nil
        let standby = other(live)
        if fromRestore, let cued = state(standby).loaded,
           cued.songId != state(live).loaded?.songId,
           let k = autoQueue.firstIndex(where: { $0.loadable.songId == cued.songId }) {
            // RESUMING A RESTORED MIX: the snapshot already cued the on-deck next — trust it over
            // the played-log scan. The log outlives relaunches, and a transition that BARELY began
            // before the kill already marked its incoming track played (`beginAutoCrossfade` →
            // `play(to)` → `notePlayed`), so re-deriving "next unplayed" here would skip the cued
            // track and re-load one slot further on EVERY relaunch — each restore consumed one
            // upcoming song. Keeping the deck also preserves its restored cue point (the reload
            // lane rewinds it to 0:00). Cursor math mirrors the load lane below.
            autoLivePos = max(0, k - 1)
            autoNextToLoad = k + 1
        } else if let k = loadNextUnplayed(onto: standby, excludingDeck: live) {   // preload the on-deck next
            autoLivePos = max(0, k - 1)
            autoNextToLoad = k + 1
        } else {
            autoLivePos = max(autoLivePos, autoQueue.count - 1)    // queue exhausted — ride the live deck out
        }
        autoDeckEndsAt[live] = now.addingTimeInterval(max(0, duration(live) - position(live)))
        refreshAutoStatus(); startTickIfNeeded(); persistMixDeckSession()
    }

    /// Two-deck RESUME handoff (called from the idle tick when `autoResumeEndDeck` finishes): retire the
    /// just-ended deck, load the next unplayed track onto it, and glide/crossfade the still-playing
    /// survivor (the live deck) over to it — after which the normal auto loop continues. Ends the mix if
    /// nothing is left to play.
    private func beginResumeHandoff(now: Date, freed: Deck) {
        silence(freed)                                            // the ended deck is done — retire it cleanly
        // freed == other(autoLiveDeck). A vanished burn here must not crossfade into the deck's
        // RETIRED track (the defect class the auto-queue append fix closed elsewhere).
        guard let k = loadNextUnplayed(onto: freed, excludingDeck: autoLiveDeck) else {
            // REPEAT ALL: everything is played/unloadable by the log's lights — wrap to the
            // queue head instead of ending (`ensureWrapPreloaded` targets `other(autoLiveDeck)`,
            // which IS `freed` here).
            if autoRepeat == .all, ensureWrapPreloaded() {
                autoTransitionWrap = true
                if anyGlide { beginGlideTransition(now: now, preroll: 0) }
                else { beginAutoCrossfade(now: now) }
                return
            }
            stopAutoMix()
            autoEndedExhausted = true   // resume-handoff with nothing loadable = exhausted too
            return
        }
        autoLivePos = max(0, k - 1)
        autoNextToLoad = k + 1
        if anyGlide { beginGlideTransition(now: now, preroll: 0) }  // no preroll — the first track already ended
        else { beginAutoCrossfade(now: now) }
    }

    /// Load the next unplayed queue item onto `deck`, DROPPING entries whose audio has vanished
    /// (a burn deleted or storage-pruned mid-mix) rather than leaving the deck empty. The auto
    /// machine transitions on a clock, so an unloaded deck is not a no-op: the crossfade either
    /// fades into silence or REPLAYS whatever retired track the deck still holds. Returns the
    /// loaded item's queue index, or nil when nothing unplayed can be loaded at all.
    @discardableResult
    private func loadNextUnplayed(onto deck: Deck, excludingDeck exclude: Deck? = nil) -> Int? {
        while let k = nextUnplayedQueueIndex(excludingDeck: exclude) {
            if loadAuto(autoQueue[k], onto: deck) { return k }
            autoQueue.remove(at: k)                  // unloadable — it can never play; drop it
            if autoNextToLoad > k { autoNextToLoad -= 1 }
            if autoLivePos > k { autoLivePos -= 1 }
        }
        return nil
    }

    /// First index in the auto queue whose song hasn't started playing this session (nil ⇒ all played).
    /// `excludingDeck` skips whatever is loaded on that deck (e.g. the live deck's current track).
    private func nextUnplayedQueueIndex(excludingDeck exclude: Deck? = nil) -> Int? {
        let skip = exclude.flatMap { state($0).loaded?.songId }
        for (i, item) in autoQueue.enumerated() {
            let sid = item.loadable.songId
            if sid == skip { continue }
            if recorder?.hasPlayed(sid) == true { continue }
            return i
        }
        return nil
    }

    private func endAutoLoop() {
        // ⏭/⏮ only drive the auto-mix queue — but the commands are process-global, so only flip them
        // off while WE own the card. A setlist that owns the card mid-auto-mix-teardown (e.g. the auto
        // queue exhausted while a set plays) keeps its own ⏮ previous / ⏭ next untouched.
        if NowPlayingArbiter.shared.isActive(self) { setLockScreenSkipCommandsEnabled(false) }
        let wasMixing = autoMixing
        // Abort any in-flight glide: restore both decks' forced effect + natural tempo/pitch, so a
        // Stop mid-transition never leaves an effect on / a deck pitched.
        abortGlide()
        autoFadeStartedAt = nil
        autoPrerollStartedAt = nil
        autoPostrollStartedAt = nil
        autoTransitionIsGlide = false
        pendingFadeRestore = nil
        autoPaused = false
        autoResumeEndDeck = nil
        autoResumeFromRestore = false
        autoTransitionRepeatOne = false
        autoTransitionWrap = false
        resumeAutoOnRemotePlay = false
        remotePausedAt = nil
        engineStallAt = nil     // a stale stall park must never shift the NEXT mix's fresh clocks
        autoMixing = false
        autoStatus = nil
        autoSourceLabel = nil
        // Recenter ONLY after a real auto-mix (it swept the fader to an extreme) — and non-recording,
        // so ending an auto-mix never injects a user `.crossfader` event. A bare Manual→Auto→Manual
        // toggle (wasMixing == false) leaves the fader where the user left it.
        if wasMixing {
            applyCrossfader(0.5)
            persistMixDeckSession()   // auto over — the decks (still loaded) persist without it
        }
    }

    /// Restore both decks from an interrupted glide (used by `endAutoLoop`): put each deck's forced
    /// effect back to its pre-glide state + tempo/pitch to natural. No-op when no glide is in flight.
    private func abortGlide() {
        guard let c = glideCtx else { return }
        setGlideSlot(c.fxSlotFrom, enabled: c.savedFrom.on, strength: c.savedFrom.strength, on: c.from)
        setGlideSlot(c.fxSlotTo, enabled: c.savedTo.on, strength: c.savedTo.strength, on: c.to)
        setGlideRate(1.0, on: c.from); setGlidePitch(0.0, on: c.from)
        setGlideRate(1.0, on: c.to);   setGlidePitch(0.0, on: c.to)
        glideCtx = nil
    }

    /// One auto-mix step (called from the unified tick while `autoMixing`). A transition runs, in
    /// order: PRE-ROLL (glide only — ramp the effect/pitch in on the outgoing deck) → CROSSFADE (the
    /// volume sweep) → POST-ROLL (glide only — ramp the incoming deck back to natural). With no glide
    /// feature on, only the crossfade phase is ever entered, so the behavior is unchanged.
    func setAutoRepeat(_ mode: AutoRepeatMode) {
        guard autoRepeat != mode else { return }
        autoRepeat = mode
        DiagLog.shared.telemetry("action", "mix repeat \(mode.rawValue)")
        persistMixDeckSession()          // survives a kill with the auto session
        refreshAutoStatus()
    }

    /// The TV/remote toggle: off → all → one → off (standard transport cycling).
    func cycleAutoRepeat() {
        switch autoRepeat {
        case .off: setAutoRepeat(.all)
        case .all: setAutoRepeat(.one)
        case .one: setAutoRepeat(.off)
        }
    }

    /// The item repeat-one replays: the live queue slot when it still matches the on-air track
    /// (queue edits keep indices < livePos+1 stable), else a rebuilt item from the deck itself
    /// (belt for drift after drops) — nil only when the live deck is empty.
    private func repeatOneItem() -> AutoMixItem? {
        if autoLivePos < autoQueue.count,
           autoQueue[autoLivePos].loadable.songId == state(autoLiveDeck).loaded?.songId {
            return autoQueue[autoLivePos]
        }
        guard let l = state(autoLiveDeck).loaded else { return nil }
        return AutoMixItem(loadable: MixLoadable(songId: l.songId, title: l.title, artist: l.artist,
                                                 bpm: l.bpm, camelot: l.camelot, key: l.key,
                                                 albumId: l.albumId, lengthMs: nil),
                           durationMs: autoDeckDurationMs[autoLiveDeck] ?? Self.autoFallbackDurationMs)
    }

    /// Repeat-one preload: the NEXT load slot (the standby deck) re-queues the CURRENT item.
    /// Deliberately touches neither cursor (`autoLivePos`/`autoNextToLoad` stay frozen) nor the
    /// queue, so nothing is ever falsely retired into `autoPlayed` and the played-log's dedup
    /// keeps `notePlayed` a no-op on the replays. The dup-deck path mirrors
    /// `ensureNextPreloaded`'s: `beginAutoCrossfade` re-schedules via `restart`, so a
    /// fully-consumed player replays.
    private func ensureRepeatOnePreloaded() -> Bool {
        guard let item = repeatOneItem() else { return false }
        let deck = other(autoLiveDeck)
        if state(deck).loaded?.songId == item.loadable.songId {
            autoDeckDurationMs[deck] = item.durationMs
            return true
        }
        return loadAuto(item, onto: deck)
    }

    /// Repeat-all preload: the wrap target is queue[0]. Unloadable heads (purged burns) are
    /// dropped exactly like `startAutoMix`'s leading-drop — with the cursor shifted down so the
    /// live slot keeps pointing at the on-air track. False when nothing at the head can load
    /// (the tick then degrades to the ordinary exhaustion end).
    private func ensureWrapPreloaded() -> Bool {
        let deck = other(autoLiveDeck)
        while !autoQueue.isEmpty {
            let item = autoQueue[0]
            if state(deck).loaded?.songId == item.loadable.songId {
                autoDeckDurationMs[deck] = item.durationMs
                return true
            }
            if loadAuto(item, onto: deck) { return true }
            autoQueue.removeFirst()
            if autoLivePos > 0 { autoLivePos -= 1 }
            if autoNextToLoad > 0 { autoNextToLoad -= 1 }
        }
        return false
    }

    private func autoFire() {
        guard autoEnabled, autoMixing, isReady else { return }
        // REMOTE-FROZEN: the decks are silent and every armed timestamp is parked (remotePlay shifts
        // them forward by the frozen interval). Without this gate a wall-clock pre-roll/fade would
        // hit p ≥ 1 during the pause and audibly restart playback on a locked, paused phone.
        guard remotePausedAt == nil else { return }
        // Engine stalled (route change / lost session): the clocks are parked by the tick watchdog
        // — a transition must not fire into a dead engine (the play()-on-stopped-engine crash).
        guard engineStallAt == nil else { return }
        let now = Date()
        if let prerollStart = autoPrerollStartedAt {                       // PRE-ROLL (glide)
            let p = min(max(now.timeIntervalSince(prerollStart) / max(0.05, glideInSecondsActive), 0), 1)
            applyOutgoingGlide(p)
            if p >= 1 {
                autoPrerollStartedAt = nil
                beginAutoCrossfade(now: now)     // start the incoming deck + the volume sweep
                startGlideCrossfade()            // snap outgoing to target, offset incoming, beat-sync
            }
        } else if let fadeStart = autoFadeStartedAt {                      // CROSSFADE (volume sweep)
            let p = min(max(now.timeIntervalSince(fadeStart) / autoFadeSeconds, 0), 1)
            applyCrossfader(autoFadeFrom == .a ? p : 1 - p)
            if p >= 1 { finishAutoCrossfade() }
        } else if let postrollStart = autoPostrollStartedAt {             // POST-ROLL (glide)
            let p = min(max(now.timeIntervalSince(postrollStart) / max(0.05, mixGlideSeconds), 0), 1)
            applyIncomingGlide(p)
            if p >= 1 { finishGlide() }
        } else {                                                          // IDLE — maybe start a transition
            // RESUME with two decks blended: hold everything until the SOONEST-ending deck finishes,
            // then retire it, load the next unplayed track onto it, and glide the survivor over. This
            // runs even while `autoPaused` is being lifted; it takes priority over the normal window check.
            if let endDeck = autoResumeEndDeck {
                let ended = !state(endDeck).isPlaying || (duration(endDeck) - position(endDeck)) <= 0.05
                if ended {
                    autoResumeEndDeck = nil
                    beginResumeHandoff(now: now, freed: endDeck)
                }
                refreshAutoStatus()
                return
            }
            // PAUSED: the DJ is hand-mixing — never auto-advance (nor auto-stop at end-of-track). Playback
            // + recording keep running; the live deck simply plays on until Resume re-arms the machine.
            guard !autoPaused else { return }
            // LOOPING: an engaged loop is a hand-mix hold — never crossfade out from under it
            // (the live deck would advance mid-loop). Releasing the loop re-times the transition.
            guard !state(autoLiveDeck).loopOn else { return }
            guard let endsAt = autoDeckEndsAt[autoLiveDeck] else { return }
            let secondsLeft = endsAt.timeIntervalSince(now)
            if secondsLeft <= autoLeadSeconds, autoRepeat == .one, ensureRepeatOnePreloaded() {
                // REPEAT ONE: replay the on-air track — the standby deck holds the SAME item and
                // the finish freezes the cursor. A failed re-preload (file purged mid-mix) falls
                // through to the ordinary lanes below, so the mix degrades instead of stalling.
                autoTransitionRepeatOne = true
                beginAdvanceTransition(now: now, secondsLeft: secondsLeft)
            } else if autoLivePos + 1 < autoQueue.count {
                // `ensureNextPreloaded` (not just the count check): a progressive append — a
                // collection-download landing or jukebox insert — can arrive while the LAST queued
                // track is live, AFTER all preloading already ran, so the idle deck holds a retired
                // (or no) track. Transitioning into it would double-play the old track or fade to
                // silence. On failure the unloadable tail was dropped; the natural end takes over.
                if secondsLeft <= autoLeadSeconds, ensureNextPreloaded() {
                    beginAdvanceTransition(now: now, secondsLeft: secondsLeft)
                }
            } else if secondsLeft <= autoLeadSeconds, autoRepeat == .all, !autoQueue.isEmpty,
                      ensureWrapPreloaded() {
                // REPEAT ALL: the LAST track wraps back into queue[0] instead of ending
                // exhausted — `autoEndedExhausted` never arms, so the downloader's exhaustion
                // re-arm (`continueAutoMixIfArmed`) has nothing to fight: while the mix runs its
                // late landings keep appending to the queue END, which simply extends the lap.
                autoTransitionWrap = true
                beginAdvanceTransition(now: now, secondsLeft: secondsLeft)
            } else if secondsLeft <= 0 {
                stopAutoMix()
                autoEndedExhausted = true   // natural end — a late-landing download may continue it
            }
        }
        refreshAutoStatus()
    }

    /// Begin the tick-driven advance transition into the already-preloaded standby deck — the
    /// fade-cap + glide-fitting tail shared by the normal, repeat-one, and repeat-all lanes.
    private func beginAdvanceTransition(now: Date, secondsLeft: Double) {
        // Cap the fade to the runway left: if you slid a track to (say) 2 s from its end,
        // crossfade over ~2 s instead of the full length so it completes before it runs out.
        if secondsLeft < autoFadeSeconds, pendingFadeRestore == nil {
            pendingFadeRestore = autoFadeSeconds
            autoFadeSeconds = max(0.5, secondsLeft)
        }
        if anyGlide {
            // Fit the preroll into what's left after the (possibly capped) fade + a margin.
            // Mix Glide bends the OUTGOING deck's tempo up to +10%, so it consumes audio
            // faster than wall-clock — divide the runway by that headroom so the fading deck
            // can't reach end-of-audio before the crossfade completes.
            let headroom = mixGlideEnabled ? 1.12 : 1.0
            let preroll = max(0, min(mixGlideSeconds,
                                     secondsLeft / headroom - autoFadeSeconds - 0.3))
            beginGlideTransition(now: now, preroll: preroll)
        } else {
            beginAutoCrossfade(now: now)
        }
    }

    /// Manual SKIP: immediately advance to the next queued track, crossfading over `fadeSeconds`.
    /// Reuses the automatic fade machine (`beginAutoCrossfade` + the tick's fade ramp), so the only
    /// extra work is choosing the fade length. Ignored mid-fade (so a double-advance can't jump the
    /// fader); on the LAST track it ends the mix, mirroring the natural end. The custom fade length is
    /// restored to the configured baseline once the crossfade finishes (see `finishAutoCrossfade`), so
    /// a one-off fast skip never shortens the next AUTOMATIC crossfade.
    func skipToNext(fadeSeconds: Double) {
        guard autoEnabled, autoMixing, isReady, !autoTransitioning else { return }
        // An explicit skip OVERRIDES repeat-one (next means next — the universal transport
        // convention); repeat-ALL turns the last-track skip into a wrap to the queue head.
        var wrapping = false
        if autoLivePos + 1 < autoQueue.count {
            // Late-append safety (see the tick): the incoming deck must actually hold the next
            // queue item before a transition fires into it. All-unloadable tail ⇒ last track.
            guard ensureNextPreloaded() else {
                stopAutoMix()
                autoEndedExhausted = true
                return
            }
        } else if autoRepeat == .all, !autoQueue.isEmpty, ensureWrapPreloaded() {
            wrapping = true
        } else {                                                                // last track → end
            stopAutoMix()
            autoEndedExhausted = true   // skip-exhausted twin of the natural end above
            return
        }
        autoTransitionWrap = wrapping
        if anyGlide {
            // A manual skip glides too, but with NO preroll (skip = advance now); it still applies the
            // effect / pitch offset on the incoming deck + rolls it back off in the postroll.
            beginGlideTransition(now: Date(), preroll: 0, fade: fadeSeconds)
        } else {
            pendingFadeRestore = autoFadeSeconds
            autoFadeSeconds = max(0.2, fadeSeconds)
            beginAutoCrossfade(now: Date())
        }
        refreshAutoStatus()
    }

    private func beginAutoCrossfade(now: Date) {
        let to = other(autoLiveDeck)
        autoFadeFrom = autoLiveDeck
        autoFadeStartedAt = now
        // Capture the crossfade itself as a compact .glide node (from current → the target extreme over
        // the fade) — every auto-mix transition (glide or plain, auto or Skip) so a replay/model has the
        // fader move, not just the deck moves.
        recGlide("crossfader", deck: nil, from: crossfader,
                 to: autoFadeFrom == .a ? 1.0 : 0.0, span: autoFadeSeconds)
        restart(to)
        play(to)
        autoDeckEndsAt[to] = now.addingTimeInterval(Double(autoDeckDurationMs[to] ?? Self.autoFallbackDurationMs) / 1000)
    }

    private func finishAutoCrossfade() {
        let from = autoFadeFrom
        let to = other(from)
        applyCrossfader(from == .a ? 1 : 0)
        silence(from)           // retire the outgoing deck WITHOUT ending the auto-mix we're inside
        autoLiveDeck = to
        let repeatedOne = autoTransitionRepeatOne
        if autoTransitionRepeatOne {
            // Repeat-one: the mix replays the same slot — cursor FROZEN (no advance, nothing
            // retired into autoPlayed, autoNextToLoad unconsumed).
        } else if autoTransitionWrap {
            autoLivePos = 0         // repeat-all wrap: the head is live again
            autoNextToLoad = 1
        } else {
            autoLivePos += 1
        }
        autoTransitionRepeatOne = false
        autoTransitionWrap = false
        autoFadeStartedAt = nil
        if let restore = pendingFadeRestore { autoFadeSeconds = restore; pendingFadeRestore = nil }
        // Glide: the OUTGOING deck is retired + about to be reused for the next queued track — restore
        // its forced effect (a load doesn't clear effects) + natural tempo/pitch BEFORE the load, then
        // hand off to the postroll that eases the now-live INCOMING deck back to natural.
        if autoTransitionIsGlide, let c = glideCtx {
            setGlideSlot(c.fxSlotFrom, enabled: c.savedFrom.on, strength: c.savedFrom.strength, on: from)
            setGlideRate(1.0, on: from); setGlidePitch(0.0, on: from)
        }
        // Preload the next LOADABLE queue item, advancing past entries whose file vanished (a
        // failed load returns false and must not burn the next transition on a stale/empty deck).
        // Repeat-one skips this: consuming `autoNextToLoad` here would drift the cursor, and the
        // retired deck already holds the replayed track — the next advance re-preloads it.
        if !repeatedOne {
            while autoNextToLoad < autoQueue.count {
                let ok = loadAuto(autoQueue[autoNextToLoad], onto: from)
                autoNextToLoad += 1
                if ok { break }
            }
        }
        updateSystemNowPlaying()      // the now-playing deck just switched → refresh the card
        if autoTransitionIsGlide {
            if mixGlideSeconds > 0.05 {
                autoPostrollStartedAt = Date()
                emitIncomingGlideEvents()      // one compact .glide node per incoming settle-back ramp
            } else { finishGlide() }
        }
        persistMixDeckSession()       // the cursor advanced (auto or Skip) — persist the new live pos
    }

    /// Late-append safety net for the transition machine: verify the deck the mix is about to
    /// crossfade INTO (`other(autoLiveDeck)`) actually holds `autoQueue[autoLivePos + 1]`, loading
    /// it now if not. Preloading normally happens in `startAutoMix` and `finishAutoCrossfade`, so a
    /// progressive append (collection-download landing, jukebox request) that arrives while the
    /// LAST queued track is live is never on the idle deck — that deck still holds the previous,
    /// retired track (double-play) or nothing at all (fade to silence). Unloadable entries
    /// (vanished burns) are dropped from the queue. Returns false when nothing loadable remains at
    /// `autoLivePos + 1` — the caller must not begin a transition.
    private func ensureNextPreloaded() -> Bool {
        let deck = other(autoLiveDeck)
        while autoLivePos + 1 < autoQueue.count {
            let next = autoQueue[autoLivePos + 1]
            if state(deck).loaded?.songId == next.loadable.songId {
                // Already preloaded — or a queue DUPLICATE of what this deck still holds, which is
                // equally fine: `beginAutoCrossfade` re-schedules the segment via `restart`, so
                // even a fully-consumed player replays. Re-stamp the duration in case the queue
                // entry differs (an insert of the same song with another length).
                autoDeckDurationMs[deck] = next.durationMs
                autoNextToLoad = max(autoNextToLoad, autoLivePos + 2)
                return true
            }
            if loadAuto(next, onto: deck) {
                // The deck just committed to index livePos+1 — later inserts must land after it.
                autoNextToLoad = max(autoNextToLoad, autoLivePos + 2)
                return true
            }
            autoQueue.remove(at: autoLivePos + 1)
            if autoNextToLoad > autoLivePos + 1 { autoNextToLoad -= 1 }
        }
        return false
    }

    /// Load a queue item onto a deck for the auto machine. Returns false — WITHOUT stamping the
    /// deck's duration — when the underlying `load` failed (BurnStore/studio/profile miss, unreadable
    /// file): a failed load must not arm a transition clock against a track that isn't there.
    @discardableResult
    private func loadAuto(_ item: AutoMixItem, onto deck: Deck) -> Bool {
        load(item.loadable, on: deck)
        guard state(deck).loaded?.songId == item.loadable.songId else { return false }
        autoDeckDurationMs[deck] = item.durationMs
        return true
    }

    private func refreshAutoStatus() {
        let s: String?
        if autoMixing {
            let detail = autoPaused ? "paused — hand-mixing"
                       : (autoTransitioning ? "fading" : "Deck \(autoLiveDeck.rawValue)")
            s = "\(min(autoLivePos + 1, autoQueue.count)) / \(autoQueue.count) · \(detail)"
        } else { s = nil }
        if s != autoStatus { autoStatus = s }
    }

    // MARK: - Auto-Mix glide (FX Glide + Mix Glide)

    /// Begin a GLIDE transition. Snapshots the FX texture + Mix-Glide tempo/pitch targets, then either
    /// starts a PRE-ROLL (ramp the glide in on the outgoing deck before the volume sweep) or — when
    /// there's no room / a manual skip — snaps the outgoing glide and goes straight to the crossfade.
    /// `fade` (manual skip) overrides the crossfade length for this one transition.
    private func beginGlideTransition(now: Date, preroll: Double, fade: Double? = nil) {
        let from = autoLiveDeck
        let to = other(from)
        let fxOn = fxGlideEnabled
        let tex: (effect: Effect, peak: Double) = fxOn ? currentTexture() : (.filter, 0)
        let mixOn = mixGlideEnabled
        let mp: (outRate: Double, outPitch: Double, inRate: Double, inPitch: Double) =
            mixOn ? Self.glideParams(fromCamelot: state(from).loaded?.camelot,
                                     toCamelot: state(to).loaded?.camelot,
                                     fromBPM: matchBPM(from), toBPM: matchBPM(to))
                  : (1, 0, 1, 0)
        // Resolve the rolled texture to a RACK SLOT per deck (each deck has its own rack), and save
        // that slot's pre-glide state so the restore paths put back exactly what the DJ had.
        let slotFrom = glideSlot(for: tex.effect, on: from)
        let slotTo = glideSlot(for: tex.effect, on: to)
        let savedFrom = slotFrom.flatMap { state(from).slots[safe: $0] }
        let savedTo = slotTo.flatMap { state(to).slots[safe: $0] }
        glideCtx = GlideContext(
            from: from, to: to,
            fxOn: fxOn, fxEffect: tex.effect, fxSlotFrom: slotFrom, fxSlotTo: slotTo, fxPeak: tex.peak,
            savedFrom: (savedFrom?.enabled ?? false, savedFrom?.strength ?? 0.5),
            savedTo: (savedTo?.enabled ?? false, savedTo?.strength ?? 0.5),
            mixOn: mixOn,
            outRate: mp.outRate, outPitch: mp.outPitch, inRate: mp.inRate, inPitch: mp.inPitch)
        autoTransitionIsGlide = true
        if let fade {                                   // manual skip: custom fade, restore after
            if pendingFadeRestore == nil { pendingFadeRestore = autoFadeSeconds }
            autoFadeSeconds = max(0.2, fade)
        }
        if preroll > 0.05 {
            glideInSecondsActive = preroll
            autoPrerollStartedAt = now
            emitOutgoingGlideEvents(span: preroll)     // one compact .glide node per outgoing ramp
            if fxOn { setGlideSlot(slotFrom, enabled: true, strength: 0, on: from) }  // engage at 0
            applyOutgoingGlide(0)
        } else {                                        // no runway / skip → snap + straight to fade
            glideInSecondsActive = 0
            emitOutgoingGlideEvents(span: 0)            // near-step ramp (skip / no preroll)
            applyOutgoingGlide(1)
            beginAutoCrossfade(now: now)
            startGlideCrossfade()
        }
    }

    /// PRE-ROLL step (progress `p` 0→1): ramp the texture effect + tempo/pitch IN on the outgoing deck.
    private func applyOutgoingGlide(_ p: Double) {
        guard let c = glideCtx else { return }
        if c.fxOn { setGlideSlot(c.fxSlotFrom, enabled: true, strength: p * c.fxPeak, on: c.from) }
        if c.mixOn {
            setGlideRate(1 + (c.outRate - 1) * p, on: c.from)
            setGlidePitch(c.outPitch * p, on: c.from)
        }
    }

    /// CROSSFADE begin: pin the outgoing deck at its glide target + the effect at peak on BOTH decks,
    /// start the incoming deck at its opposite offset, and best-effort downbeat-align it (beat sync).
    private func startGlideCrossfade() {
        guard let c = glideCtx else { return }
        if c.fxOn {
            setGlideSlot(c.fxSlotFrom, enabled: true, strength: c.fxPeak, on: c.from)
            setGlideSlot(c.fxSlotTo, enabled: true, strength: c.fxPeak, on: c.to)
        }
        if c.mixOn {
            setGlideRate(c.outRate, on: c.from); setGlidePitch(c.outPitch, on: c.from)
            setGlideRate(c.inRate, on: c.to);    setGlidePitch(c.inPitch, on: c.to)
            glidePhaseAlign(incoming: c.to, outgoing: c.from)   // align the incoming downbeat (beat sync)
        }
    }

    /// Best-effort downbeat align for the glide's incoming deck — same phase math as `phaseAlign`, but
    /// applied via a NON-recording reschedule (auto-mix internals must not emit user `.seek` events,
    /// mirroring the non-recording `applyCrossfader`). The incoming deck is always a freshly-loaded
    /// single file (auto-mix never enters stem mode), so only the single-player path is needed.
    private func glidePhaseAlign(incoming f: Deck, outgoing l: Deck) {
        guard state(f).isPlaying, state(l).isPlaying,
              let leadBPM = matchBPM(l), let folBPM = matchBPM(f) else { return }
        let leadBeat = 60.0 / leadBPM, folBeat = 60.0 / folBPM
        let leadDb = Double(state(l).loaded?.firstDownbeatMs ?? 0) / 1000.0
        let folDb = Double(state(f).loaded?.firstDownbeatMs ?? 0) / 1000.0
        let leadPhase = ((position(l) - leadDb) / leadBeat).truncatingRemainder(dividingBy: 1)
        let folPhase = ((position(f) - folDb) / folBeat).truncatingRemainder(dividingBy: 1)
        var delta = leadPhase - folPhase
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        // Use the RECORDING seek so the beat-align repositioning lands in the timeline too (every
        // action is captured for faithful replay). During a transition `refreshAutoDeckEndIfLive`
        // no-ops (autoTransitioning is true), so this doesn't disturb the crossfade timing.
        seek(f, toSeconds: max(0, position(f) + delta * folBeat))
    }

    /// POST-ROLL step (progress `p` 0→1): ease the incoming deck's effect OFF + tempo/pitch back to
    /// natural (the crossfade already fully favours it).
    private func applyIncomingGlide(_ p: Double) {
        guard let c = glideCtx else { return }
        if c.fxOn { setGlideSlot(c.fxSlotTo, enabled: true, strength: (1 - p) * c.fxPeak, on: c.to) }
        if c.mixOn {
            setGlideRate(c.inRate + (1 - c.inRate) * p, on: c.to)
            setGlidePitch(c.inPitch * (1 - p), on: c.to)
        }
    }

    /// Transition complete: restore the incoming deck's pre-glide effect state + natural tempo/pitch,
    /// and clear the glide context.
    private func finishGlide() {
        autoPostrollStartedAt = nil
        if let c = glideCtx {
            setGlideSlot(c.fxSlotTo, enabled: c.savedTo.on, strength: c.savedTo.strength, on: c.to)
            if c.mixOn { setGlideRate(1.0, on: c.to); setGlidePitch(0.0, on: c.to) }
        }
        glideCtx = nil
        autoTransitionIsGlide = false
    }

    /// The FX texture for this transition — reuse the current one across a run of 3–5 transitions
    /// (coherent texture), then re-roll. Deterministic (seeded in `startAutoMix`).
    private func currentTexture() -> (effect: Effect, peak: Double) {
        if fxTextureRunRemaining <= 0 || fxTextureEffect == nil {
            let t = Self.rollTexture(&fxGlidePrng)
            fxTextureEffect = t.effect
            fxTexturePeak = t.peak
            fxTextureRunRemaining = t.run
        }
        fxTextureRunRemaining -= 1
        return (fxTextureEffect ?? .filter, fxTexturePeak)
    }

    // Glide appliers — mutate deck state + push to the graph every ~10 Hz tick WITHOUT emitting a
    // per-tick event (that would flood the corpus). The deck sliders/chips still reflect the live
    // values (they read the same observable state), so you SEE the glide; the trajectory is captured
    // COMPACTLY as one `.glide` event per ramp (from/to/rate — see `recGlide`), because an auto-mix
    // glide is a deterministic linear ramp. (Manual moves, by contrast, stay sampled per-change.)
    private func setGlideRate(_ rate: Double, on deck: Deck) {
        mutate(deck) { $0.rate = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound) }
        applyRate(deck)
    }
    private func setGlidePitch(_ semitones: Double, on deck: Deck) {
        mutate(deck) { $0.pitch = min(max(semitones, Self.pitchRange.lowerBound), Self.pitchRange.upperBound) }
        applyPitch(deck)
    }
    /// Sweep ONE rack slot. Deliberately never touches the slot's effect/variant — the glide rides
    /// whatever the DJ put there (put Plate in slot 2 and the Auto-DJ sweeps Plate), it doesn't
    /// impose its own. A nil slot (nothing sweepable in that rack) is a silent no-op.
    private func setGlideSlot(_ i: Int?, enabled: Bool, strength: Double, on deck: Deck) {
        guard let i, state(deck).slots[safe: i] != nil else { return }
        mutate(deck) {
            $0.slots[i].enabled = enabled
            $0.slots[i].setStrength(strength)
        }
        applySlot(i, on: deck)
    }

    /// Which slot an FX glide should sweep on `deck`: the first slot holding the rolled texture
    /// effect, else the first holding ANY sweepable (pool) effect — so a rack without, say, a filter
    /// still glides on its reverb instead of silently doing nothing. nil ⇒ that rack has nothing
    /// worth sweeping (e.g. all compressors), and the deck simply sits the glide out.
    private func glideSlot(for effect: Effect, on deck: Deck) -> Int? {
        let slots = state(deck).slots
        if let i = slots.firstIndex(where: { $0.effect == effect }) { return i }
        return slots.firstIndex { Self.fxGlidePool.contains($0.effect) }
    }

    /// Emit ONE compact `.glide` timeline event for a ramp: `param` from→to over `span` seconds, with
    /// the average rate of change. Skips a no-op ramp (from ≈ to), so an identical-key / no-preroll
    /// segment doesn't log a phantom node. Deck playhead + loaded track are stamped for the corpus.
    private func recGlide(_ param: String, deck: Deck?, from: Double, to: Double, span: Double,
                          slot: Int? = nil) {
        guard let recorder, abs(to - from) > 1e-6 else { return }
        let l = deck.flatMap { state($0).loaded }
        recorder.logGlide(deck: deck?.rawValue, param: param, songId: l?.songId, title: l?.title,
                          artist: l?.artist, from: from, to: to,
                          rate: (to - from) / max(0.05, span),
                          posMs: deck.map { Int(position($0) * 1000) }, slot: slot)
    }

    /// The OUTGOING deck's glide ramps (tempo/pitch bend up-toward + effect sweep-in) — logged once as
    /// the pre-roll begins. `span` is the ramp length (≈0 on a skip ⇒ a near-step rate).
    private func emitOutgoingGlideEvents(span: Double) {
        guard let c = glideCtx else { return }
        if c.mixOn {
            recGlide("tempo", deck: c.from, from: 1.0, to: c.outRate, span: span)
            recGlide("pitch", deck: c.from, from: 0.0, to: c.outPitch, span: span)
        }
        // Only log an FX ramp that actually happened: a rack with nothing sweepable resolves to no
        // slot, and must not leave a phantom "filter swept" node in the corpus.
        if c.fxOn, let i = c.fxSlotFrom {
            recGlide(c.fxEffect.rawValue, deck: c.from, from: 0.0, to: c.fxPeak, span: span, slot: i)
        }
    }

    /// The INCOMING deck's glide ramps (tempo/pitch settle-to-natural + effect sweep-out) — logged
    /// once as the post-roll begins.
    private func emitIncomingGlideEvents() {
        guard let c = glideCtx else { return }
        let span = max(mixGlideSeconds, 0.01)
        if c.mixOn {
            recGlide("tempo", deck: c.to, from: c.inRate, to: 1.0, span: span)
            recGlide("pitch", deck: c.to, from: c.inPitch, to: 0.0, span: span)
        }
        if c.fxOn, let i = c.fxSlotTo {
            recGlide(c.fxEffect.rawValue, deck: c.to, from: c.fxPeak, to: 0.0, span: span, slot: i)
        }
    }

    // MARK: Glide math (pure — testable)

    /// The FX-Glide effect pool: sweepy effects that read as a texture across a transition (the
    /// compressor is excluded — it's a dynamics tool, not a sweep).
    nonisolated static let fxGlidePool: [Effect] = [.filter, .reverb, .flanger]

    /// 1 Camelot "key" (wheel hour) as a pitch shift in SEMITONES, at the user's 10%-per-key
    /// convention: a +10% frequency ratio is `12·log2(1.1)` ≈ 1.65 semitones.
    nonisolated static let semitonesPerKey: Double = 12 * log2(1.1)

    /// Signed Camelot-hour distance a→b, wrapped to the shortest way round the 12-hour wheel (−6…+6).
    /// nil if either code is unparseable. Positive ⇒ b is "higher" (glide the outgoing deck up to it).
    nonisolated static func signedCamelotSteps(_ a: String?, _ b: String?) -> Int? {
        guard let pa = Camelot.parse(a), let pb = Camelot.parse(b) else { return nil }
        var d = pb.num - pa.num
        if d > 6 { d -= 12 } else if d < -6 { d += 12 }
        return d
    }

    /// Tempo multiplier for a glide of `keys` (Camelot hours; 1 key = ±10%), clamped to `rateRange`.
    nonisolated static func glideRate(keys: Double) -> Double {
        min(max(1 + 0.10 * keys, rateRange.lowerBound), rateRange.upperBound)
    }
    /// Pitch shift (semitones) for a glide of `keys`, clamped to `pitchRange`.
    nonisolated static func glidePitch(keys: Double) -> Double {
        min(max(keys * semitonesPerKey, pitchRange.lowerBound), pitchRange.upperBound)
    }

    /// Per-deck tempo/pitch targets for a transition A(out)→B(in). Two INDEPENDENT, data-gated bends
    /// (no default — with neither datum it's identity, i.e. just the volume crossfade):
    ///   • PITCH — only when BOTH Camelot keys are known: harmonic bend toward each other (≤1 key each,
    ///     1 key = ~1.65 st), so the overlap meets in the middle; the incoming then settles back.
    ///   • TEMPO — only when BOTH BPMs are known: a real BEAT-MATCH toward the middle. Using the SAME
    ///     octave-folded ratio the Lead/Sync buttons use (`octaveFolded`, fed the measured grid BPM via
    ///     the caller's `matchBPM`), the full match is SPLIT between the two decks so they meet at a
    ///     common effective BPM — their beats lock during the overlap (the caller then downbeat-aligns
    ///     via the grid). Similar BPMs ⇒ a tiny nudge; only far-apart tempos bend much.
    /// Combining a little pitch + a beat-matched tempo is the "subtle mix"; each is skipped if its datum
    /// is missing for either track.
    nonisolated static func glideParams(fromCamelot a: String?, toCamelot b: String?,
                                        fromBPM: Double?, toBPM: Double?)
        -> (outRate: Double, outPitch: Double, inRate: Double, inPitch: Double) {
        var outPitch = 0.0, inPitch = 0.0, outRate = 1.0, inRate = 1.0
        // PITCH — Camelot harmonic bend (both keys known + not identical).
        if let d = signedCamelotSteps(a, b), abs(d) >= 1 {
            let mag = min(1.0, Double(abs(d)) / 2.0)
            let dir = d > 0 ? 1.0 : -1.0
            outPitch = glidePitch(keys: dir * mag)        // outgoing bends toward incoming
            inPitch = glidePitch(keys: -dir * mag)        // incoming starts opposite, settles back
        }
        // TEMPO — beat-match, split between the decks so they MEET (octave-folded like Sync).
        if let ra = fromBPM, let rb = toBPM, ra > 0, rb > 0 {
            let split = octaveFolded(ra / rb).squareRoot()   // incoming's full match to outgoing, halved
            inRate = min(max(split, rateRange.lowerBound), rateRange.upperBound)   // incoming toward the match
            outRate = min(max(1 / split, rateRange.lowerBound), rateRange.upperBound) // outgoing meets it
        }
        return (outRate, outPitch, inRate, inPitch)
    }

    /// splitmix64 — a tiny deterministic PRNG so texture selection is reproducible + unit-testable.
    nonisolated static func splitmix64(_ state: inout UInt64) -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Roll the next FX-Glide texture: an effect from the pool, a peak strength (0.5…0.8), and a run
    /// length (3…5 transitions to keep it). Pure + deterministic given `state`.
    nonisolated static func rollTexture(_ state: inout UInt64) -> (effect: Effect, peak: Double, run: Int) {
        let a = splitmix64(&state), b = splitmix64(&state), c = splitmix64(&state)
        let effect = fxGlidePool[Int(a % UInt64(fxGlidePool.count))]
        let peak = 0.5 + Double(b % 1000) / 1000.0 * 0.3
        let run = 3 + Int(c % 3)
        return (effect, peak, run)
    }

    /// A stable per-mix seed from the queue (FNV-1a over the first song id ⊕ count) — deterministic, so
    /// a given track set always textures the same way, without wall-clock randomness (which the app
    /// avoids for reproducibility).
    nonisolated static func fxSeed(from items: [AutoMixItem]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (items.first?.loadable.songId ?? "seed").utf8 {
            h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return h ^ UInt64(items.count)
    }

    // MARK: - Stems (per-deck stem-mode playback + grid)

    /// Stem mode is ON for this deck (the grid shows; Play drives the 4 stems).
    func stemModeOn(_ deck: Deck) -> Bool { state(deck).stemMode }
    /// Stem mode is on AND the 4 stem files are wired (playback actually routes to stems).
    func stemActive(_ deck: Deck) -> Bool { state(deck).stemMode && (stemFiles[deck]?.isEmpty == false) }
    func isStemMuted(_ name: String, on deck: Deck) -> Bool { state(deck).stemMuted.contains(name) }
    func stemVolume(_ name: String, on deck: Deck) -> Double { state(deck).stemVol[name] ?? 1.0 }

    /// Enable / disable stem mode for a deck. Enabling resolves the BURNED-local 4 stems (the caller
    /// burns them first — see `BurnStore.burnStems`) and routes the deck through them, still THROUGH
    /// the deck's effect chain + crossfader; disabling returns to the single mixed file. Switches live
    /// when the deck is already playing (a brief re-schedule gap). No-op (stays off) when the track
    /// has no locally-burned stems.
    func setStemMode(_ on: Bool, on deck: Deck) {
        guard state(deck).loaded != nil else { return }
        ensureEngine()
        let was = state(deck).isPlaying
        let pos = position(deck)
        if on {
            guard wireStems(deck) else { return }    // no local stems → can't enter stem mode
            // Schedule the stems BEFORE muting the main file, and ONLY commit to stem mode if they
            // actually scheduled. Clamp `pos` to just inside the shortest stem so an end-of-track
            // playhead (the auto-mix tick pins it at `duration`, e.g. right after interrupting a mix)
            // still lands on real audio instead of zero frames. Without this guard, the old code muted
            // the main file, set stemMode=true, then discarded a failed `scheduleStems` → the deck went
            // SILENT (both main stopped AND stems unscheduled) until you toggled stem mode back off.
            guard scheduleStems(deck, fromSeconds: min(pos, maxStemSeconds(deck))) else { return }
            players[deck]?.stop()                    // only NOW silence the single mixed file
            fileScheduled[deck] = false
            mutate(deck) { $0.stemMode = true }
            rec(.stemMode, deck, flag: true)
            applyStemGains(deck)
            if was { startStems(deck) }
        } else {
            stopStemNodes(deck)
            mutate(deck) { $0.stemMode = false }
            rec(.stemMode, deck, flag: false)
            // Re-prime (and resume) the single mixed file from the same spot.
            guard built, let file = files[deck], let player = players[deck], let sr = sampleRates[deck],
                  let start = startFrames[deck], let end = endFrames[deck] else { refreshTransport(); return }
            let frame = min(max(start, start + AVAudioFramePosition(pos * sr)), end)
            let count = end - frame
            player.stop()
            segmentStartSeconds[deck] = pos    // the single file resumes `pos` s in (true-playhead base)
            fileScheduled[deck] = count > 0
            if count > 0 {
                player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(count),
                                       at: nil, completionHandler: nil)
                if was, startEngineIfNeeded() { player.play() }   // dead engine → watchdog resumes
            }
        }
        // A LIVE loop follows the deck across the mode flip: re-arm on whichever voices now play
        // (the branches above scheduled the whole remaining track, which would run past the window).
        if loopWindow(deck) != nil { armLoop(deck) }
        refreshTransport()
        persistMixDeckSession()                  // stem-mode flip — structural, persist immediately
    }

    func toggleStemMute(_ name: String, on deck: Deck) {
        mutate(deck) { if $0.stemMuted.contains(name) { $0.stemMuted.remove(name) } else { $0.stemMuted.insert(name) } }
        applyStemGains(deck)
        rec(.stemMute, deck, param: name, flag: isStemMuted(name, on: deck))
        persistMixDeckSession()                  // discrete tap — persist immediately
    }

    func setStemVolume(_ name: String, _ v: Double, on deck: Deck) {
        mutate(deck) { $0.stemVol[name] = min(max(v, 0), 1) }
        applyStemGains(deck)
        rec(.stemVolume, deck, param: name, value: stemVolume(name, on: deck))
        persistMixDeckSession(debounced: true)   // slider surface — one write per burst
    }

    /// Resolve + open the deck track's 4 burned stem files and reconnect each stem node at the file's
    /// format (only that link; the chain stays canonical). Holds the burn-folder scope. Returns false
    /// when the track isn't stem-burned locally / a file won't open.
    private func wireStems(_ deck: Deck) -> Bool {
        guard built, let songId = state(deck).loaded?.songId, let inputMixer = inputMixers[deck] else { return false }
        // Stem source: a "Pocket DJ" profile item's app-managed stems (no security scope), else the
        // burned set (scoped). Everything downstream is source-agnostic; profile just feeds release=nil.
        let urls: [String: URL]
        let release: (() -> Void)?
        if ProfileSourceStore.isProfileSongId(songId), let u = profileStemResolve?(songId) {
            urls = u; release = nil
        } else if let r = burns.localStemURLs(forSong: songId) {
            urls = r.urls; release = r.release
        } else {
            return false
        }
        var opened: [String: AVAudioFile] = [:]
        for (name, url) in urls {
            if let f = try? AVAudioFile(forReading: url) { opened[name] = f }
        }
        guard opened.count == Self.stemNames.count else { release?(); return false }
        for (name, file) in opened {
            guard let node = stemPlayers[deck]?[name] else { continue }
            node.stop()
            engine.connect(node, to: inputMixer, format: file.processingFormat)
        }
        stemReleases[deck]?()              // release a prior wiring's scope, hold the new one
        stemReleases[deck] = release
        stemFiles[deck] = opened
        return true
    }

    /// Tear down a deck's stem wiring (stop nodes, drop files, release the burn-folder scope).
    private func unwireStems(_ deck: Deck) {
        stopStemNodes(deck)
        stemFiles[deck] = nil
        stemReleases[deck]?(); stemReleases[deck] = nil
    }

    /// The longest position (seconds) at which `scheduleStems` still gets real audio — just inside the
    /// SHORTEST wired stem so a request never rounds up to zero frames. 0 when no stems are wired.
    private func maxStemSeconds(_ deck: Deck) -> Double {
        guard let files = stemFiles[deck], !files.isEmpty else { return 0 }
        let secs = files.values.map { Double($0.length) / $0.processingFormat.sampleRate }
        return max(0, (secs.min() ?? 0) - 0.05)
    }

    /// Re-schedule the stems from the current playhead IF they hold no live schedule (e.g. a prior
    /// `stop()` cleared it at end-of-track / after an auto-mix retired the deck). A no-op when already
    /// scheduled, so resuming a paused deck keeps its position instead of rewinding.
    private func ensureStemsScheduled(_ deck: Deck) {
        guard stemsScheduled[deck] != true else { return }
        _ = scheduleStems(deck, fromSeconds: min(position(deck), maxStemSeconds(deck)))
    }

    /// Schedule the 4 stem nodes from `posSec` (song-relative). Returns whether anything scheduled.
    private func scheduleStems(_ deck: Deck, fromSeconds posSec: Double) -> Bool {
        guard let files = stemFiles[deck], !files.isEmpty, let nodes = stemPlayers[deck] else { return false }
        var any = false
        for (name, node) in nodes {
            node.stop()
            guard let file = files[name] else { continue }
            let sr = file.processingFormat.sampleRate
            let startFrame = min(max(0, AVAudioFramePosition(max(0, posSec) * sr)), file.length)
            let count = file.length - startFrame
            guard count > 0 else { continue }
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(count),
                                 at: nil, completionHandler: nil)
            any = true
        }
        stemsScheduled[deck] = any
        return any
    }

    /// Start the deck's stem nodes at ONE shared host time → sample-accurate sync.
    private func startStems(_ deck: Deck) {
        guard startEngineIfNeeded() else { return }   // play(at:) on a dead engine is the same uncatchable trap
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.06))
        for n in (stemPlayers[deck] ?? [:]).values { n.play(at: when) }
    }

    private func stopStemNodes(_ deck: Deck) {
        for n in (stemPlayers[deck] ?? [:]).values { n.stop() }
        stemsScheduled[deck] = false       // stop() discards the scheduled segment
    }

    /// Pause a deck's ACTIVE voices (the single file + any stems) keeping their scheduled position.
    private func pauseActiveNodes(_ deck: Deck) {
        players[deck]?.pause()
        for n in (stemPlayers[deck] ?? [:]).values { n.pause() }
    }

    /// Stop a deck's ACTIVE voices (resets their scheduled position).
    private func stopActiveNodes(_ deck: Deck) {
        players[deck]?.stop()
        for n in (stemPlayers[deck] ?? [:]).values { n.stop() }
        fileScheduled[deck] = false
        stemsScheduled[deck] = false
    }

    // MARK: - Jukebox Hero seams (docs/design/jukebox-hero.md)
    //
    // While a jukebox BROADCAST rides an auto-mix, the setlist is the shared concept:
    // guests see the mix's on-air track + the auto queue's tail, and accepted requests
    // are INSERTED into the auto queue. In-mix actions always take precedence — inserts
    // never land before `autoNextToLoad`, so a track already loaded/preloaded on a deck
    // is never displaced, and manual deck moves keep working exactly as without a jukebox.

    /// What's ON AIR for jukebox guests: the auto-mix live deck's track, else whichever
    /// deck is audibly playing (manual mixing), else nil.
    var onAirTrack: LoadedTrack? {
        if autoMixing { return state(autoLiveDeck).loaded }
        if state(.a).isPlaying { return state(.a).loaded }
        if state(.b).isPlaying { return state(.b).loaded }
        return nil
    }

    /// The auto queue's not-yet-reached tail (position order) — the guests' "up next".
    /// Empty when not auto-mixing (a manual mix has no knowable next).
    var autoUpcoming: [MixLoadable] {
        guard autoMixing, autoLivePos + 1 < autoQueue.count else { return [] }
        return autoQueue[(autoLivePos + 1)...].map(\.loadable)
    }

    /// `autoUpcoming` with per-row provenance (the crate the track came from) — the TV queue
    /// surfaces render "— deck · crate" from it. The plain [MixLoadable] contract above stays
    /// for existing callers.
    var autoUpcomingDetailed: [(loadable: MixLoadable, sourceLabel: String?)] {
        guard autoMixing, autoLivePos + 1 < autoQueue.count else { return [] }
        return autoQueue[(autoLivePos + 1)...].map { ($0.loadable, $0.sourceLabel) }
    }

    /// `autoPlayed`'s provenance twin (consumed head, newest first).
    var autoPlayedDetailed: [(loadable: MixLoadable, sourceLabel: String?)] {
        guard autoMixing, autoLivePos > 0 else { return [] }
        return autoQueue[..<min(autoLivePos, autoQueue.count)]
            .map { ($0.loadable, $0.sourceLabel) }.reversed()
    }

    /// Shuffle the auto queue's not-yet-committed tail (the TV card's 🔀). The low bound is
    /// `autoNextToLoad` — the in-flight transition and the preloaded on-deck track always win
    /// (the same in-mix-precedence rule `autoQueueInsert` documents).
    func autoQueueShuffleUpcoming() {
        guard autoMixing else { return }
        let lo = min(max(autoNextToLoad, autoLivePos + 1), autoQueue.count)
        guard autoQueue.count - lo > 1 else { return }
        autoQueue[lo...].shuffle()
        refreshAutoStatus()
        persistMixDeckSession()
        DiagLog.shared.telemetry("action", "mix shuffle upcoming (\(autoQueue.count - lo) tracks)")
    }

    /// Remove a not-yet-committed upcoming row (offset into `autoUpcoming`). No-op for rows a
    /// deck has already committed to (below `autoNextToLoad` — the in-mix-precedence rule
    /// `autoQueueInsert` documents) and for out-of-range offsets.
    func autoQueueRemoveUpcoming(offset: Int) {
        guard autoMixing else { return }
        let idx = autoLivePos + 1 + offset
        let lo = min(max(autoNextToLoad, autoLivePos + 1), autoQueue.count)
        guard idx >= lo, idx < autoQueue.count else { return }
        autoQueue.remove(at: idx)
        refreshAutoStatus()
        persistMixDeckSession()
        DiagLog.shared.telemetry("action", "mix queue remove upcoming #\(offset)")
    }

    /// Move a not-yet-committed upcoming row to NEXT (right after the committed head) or END.
    /// Same precedence bound as removal.
    func autoQueueMoveUpcoming(offset: Int, toEnd: Bool) {
        guard autoMixing else { return }
        let idx = autoLivePos + 1 + offset
        let lo = min(max(autoNextToLoad, autoLivePos + 1), autoQueue.count)
        guard idx >= lo, idx < autoQueue.count else { return }
        let item = autoQueue.remove(at: idx)
        autoQueue.insert(item, at: toEnd ? autoQueue.count : lo)
        refreshAutoStatus()
        persistMixDeckSession()
        DiagLog.shared.telemetry("action", "mix queue move upcoming #\(offset) → \(toEnd ? "end" : "next")")
    }

    /// How many of `autoUpcoming`'s leading rows are COMMITTED (a deck holds them) and so
    /// cannot be moved/removed — the TV queue menus disable themselves on those.
    var autoUpcomingLockedCount: Int {
        guard autoMixing else { return 0 }
        return max(0, min(autoNextToLoad, autoQueue.count) - (autoLivePos + 1))
    }

    /// The auto queue's consumed head, NEWEST FIRST — the "previously played" list the TV's
    /// unified Now Playing card reveals. Empty when not auto-mixing.
    var autoPlayed: [MixLoadable] {
        guard autoMixing, autoLivePos > 0 else { return [] }
        return autoQueue[..<min(autoLivePos, autoQueue.count)].map(\.loadable).reversed()
    }

    /// Insert a track into the RUNNING auto queue for the jukebox request line.
    /// `slot` semantics mirror SetlistPlayer's live edits, but the low bound is
    /// `autoNextToLoad` — the first index no deck has committed to yet — so the
    /// in-flight transition and the preloaded on-deck track always win (the
    /// in-mix-precedence rule). No-op when not auto-mixing.
    func autoQueueInsert(_ item: AutoMixItem, placement: JukeboxDecisionAction,
                         slot: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) {
        guard autoMixing else { return }
        let lo = min(max(autoNextToLoad, autoLivePos + 1), autoQueue.count)
        let at: Int
        switch placement {
        case .next:   at = lo
        case .end:    at = autoQueue.count
        case .random: at = slot(lo...autoQueue.count)
        case .denied: return
        }
        autoQueue.insert(item, at: at)
        refreshAutoStatus()   // the "x / count" readout grew by one
        persistMixDeckSession()   // a guest's accepted request must survive a force-quit
    }

    // MARK: - Durable mix-deck session (persist + restore)
    //
    // Phase 2 of durable playback sessions (see `MixDeckSessionStore` + the phase-1 pattern in
    // `SetlistPlayer`): the live mix — both decks, mixer, and the Auto-DJ queue — writes itself
    // down IN REAL TIME and rehydrates at launch, HELD (no audio, no Now Playing card, Auto-DJ
    // suspended) until the user acts.
    //
    // Persisted: per-deck track identity + playhead + volume/tempo/pitch/effects/stem state;
    // crossfader; lead deck; the Auto-DJ queue/cursor/label/glide flags. EXCLUDED (and why):
    //  • recording state — `MixRecorder` has its own crash-orphan recovery (fragmented file);
    //  • cue/PFL routing + cue volume — transient monitoring state (restoring a hard-panned
    //    house/cue split after a reboot would be a surprise, and the headphone rig is gone);
    //  • VU meters / realtime taps / `truePlayhead` — pure runtime derivations;
    //  • beat grids / cue points — derivable from burned analysis sidecars + the studio store,
    //    re-hydrated by the normal `load` path (never duplicated in the snapshot);
    //  • in-flight transition state (pre-roll/fade/post-roll clocks, glide context) — wall-clock
    //    runtime state; a kill mid-crossfade restores in the suspended idle state and the
    //    existing Resume re-arms the machine against live playback.

    /// Relaunch entry point (RootView's launch task): read the persisted snapshot and PARK it —
    /// no audio, no engine build, no card. Skipped when the engine is already in use (an intent
    /// launch started a mix first) and under the `PDJ_DISABLE_SESSION_RESTORE` seam. If the Mix
    /// tab already asked to materialize (macOS lands on Mix and its `.task` can win the race),
    /// materialize right away.
    func restorePersistedMixIfIdle() {
        guard let sessionStore else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["PDJ_DISABLE_SESSION_RESTORE"] == nil else { return }
        guard !isRunning, !autoMixing, loaded(.a) == nil, loaded(.b) == nil else { return }
        sessionStore.seedFixtureIfRequested()
        guard let snap = sessionStore.load() else { return }
        pendingMixRestore = snap
        NPLog.trace("mix RESTORE parked decks=\(snap.deckA != nil ? "A" : "")\(snap.deckB != nil ? "B" : "") auto=\(snap.auto?.queue.count ?? 0)")
        if materializeWanted { materializeNow() }
    }

    /// Mix-tab entry point (MixView's `.task`, after `prepare()`): actually re-load the parked
    /// snapshot onto the decks. Lazy on purpose — deck files + the AVAudioEngine graph are only
    /// touched when the Mix surface first appears, never at launch. Idempotent; remembers the
    /// request so a launch-task restore that lands later can finish the job.
    func materializePendingRestoreIfNeeded() {
        materializeWanted = true
        materializeNow()
    }

    /// Rebuild the mix from the parked snapshot: decks re-loaded and CUED at their saved
    /// playheads, mixer state re-applied, Auto-DJ queue rebuilt SUSPENDED. Nothing plays —
    /// `AVAudioPlayerNode.play()` is never called, the session-log recorder is detached (a
    /// restore is not a user gesture), and Now Playing card writes are suppressed
    /// (`isRestoringMixSession`) so no card is claimed. A track whose file vanished since
    /// (purged burn, deleted stem source) simply leaves that deck empty — restore what's
    /// loadable, drop what isn't, never block. No-op when the engine is already in use.
    private func materializeNow() {
        guard let snap = pendingMixRestore else { return }
        pendingMixRestore = nil
        guard !isRunning, !autoMixing, loaded(.a) == nil, loaded(.b) == nil else { return }
        isRestoringMixSession = true
        let savedRecorder = recorder
        recorder = nil                      // restore must not spam the mix-session action log
        defer {
            recorder = savedRecorder
            isRestoringMixSession = false
            persistMixDeckSession()         // re-sync: dropped (unloadable) decks fall out of the file
        }
        ensureEngine()                      // the Mix tab is up — same warm-up its `.task` already does
        if let a = snap.deckA { restoreDeck(.a, from: a) }
        if let b = snap.deckB { restoreDeck(.b, from: b) }
        applyCrossfader(snap.crossfader)    // non-recording apply (machine move, not a gesture)
        if let lead = snap.leadDeck.flatMap(Deck.init(rawValue:)), state(lead).loaded != nil {
            leadDeck = lead                 // after the loads — a load clears its deck's lead role
        }
        if let auto = snap.auto { restoreAutoSuspended(auto) }
        NPLog.trace("mix RESTORE materialized A=\(loaded(.a)?.songId ?? "-") B=\(loaded(.b)?.songId ?? "-") auto=\(autoMixing ? 1 : 0)")
    }

    /// Re-load one deck through the NORMAL load path (BurnStore cut/analog resolution, studio
    /// seam, grid hydration), then re-apply its plain-value controls and cue the playhead.
    /// If the file is gone the load is a silent no-op and the deck stays empty (per-deck drop).
    private func restoreDeck(_ deck: Deck, from ds: MixDeckSessionStore.DeckSnapshot) {
        let t = ds.track
        load(songId: t.songId, title: t.title, artist: t.artist, bpm: t.bpm,
             camelot: t.camelot, key: t.key, albumId: t.albumId, lengthMs: t.lengthMs, on: deck)
        guard state(deck).loaded?.songId == t.songId else { return }   // file vanished → deck empty
        setVolume(ds.volume, on: deck)
        setRate(ds.rate, on: deck)
        setPitch(ds.pitch, on: deck)
        // Restore the whole FX rack in ONE state write, then push it to the graph. `resolvedSlots`
        // hands back the lossless `fxSlots` when present and migrates a pre-rack session (flat
        // fields + filterMode → the default layout) when it isn't, so an upgrading user's deck comes
        // back exactly as they left it.
        let restored = ds.resolvedSlots.map { s -> FXSlot in
            let effect = Effect(rawValue: s.effect) ?? .compressor
            var slot = FXSlot(effect, variant: EffectVariant(rawValue: s.variant),
                              enabled: s.on, strength: s.strength)
            slot.mod = s.resolvedMod
            return slot
        }
        mutate(deck) { $0.slots = restored }
        applyAllSlots(deck)
        setEqGain(.low, ds.eqLow ?? 0, on: deck)
        setEqGain(.mid, ds.eqMid ?? 0, on: deck)
        setEqGain(.high, ds.eqHigh ?? 0, on: deck)
        if ds.stemMode {
            setStemMode(true, on: deck)     // stems no longer burned → stays single-file (graceful)
            if stemActive(deck) {
                for name in ds.stemMuted where !isStemMuted(name, on: deck) { toggleStemMute(name, on: deck) }
                for (name, v) in ds.stemVol { setStemVolume(name, v, on: deck) }
            }
        }
        if ds.positionMs > 0 { seek(deck, toSeconds: Double(ds.positionMs) / 1000) }   // cue, not play
        // LOOP last: the window is derived from the restored position, so it must be armed AFTER
        // the seek above (and after stem mode, so it arms on the voices that will actually play).
        if ds.loopOn == true {
            setLoopUnits(deck, ds.loopUnits ?? 2)
            setLoop(deck, on: true)
        }
        // Everything above was cued on a not-yet-started engine, and tvOS drops exactly such
        // never-rendered schedules when the first `engine.start()` (the user's Resume)
        // renegotiates the output format — the field silent-resume: 10 s of "playing" into a
        // flushed queue, healed only by a skip's fresh load. Mark the cues UNTRUSTED so the
        // first play re-arms them from the cued position via `ensureDeckScheduled` (a no-op
        // rebuild of the identical schedule when nothing was actually dropped).
        fileScheduled[deck] = false
        stemsScheduled[deck] = false
    }

    /// Rebuild the Auto-DJ machine SUSPENDED (`autoPaused` — the exact state the lock-screen ⏸
    /// leaves a running mix in): queue + cursor + label + glide flags live, transition machine
    /// idle, wall clocks unarmed. It must NOT self-resume (the silent-fades invariant from the
    /// lock-screen transport work) — the existing Resume paths (`resumeAuto` via the banner /
    /// remote ▶ once the user starts audio) re-stamp the end clocks from live playback, so no
    /// stale pre-kill timestamps are ever trusted. Deliberately does NOT touch the lock-screen
    /// ⏭/⏮ enablement or the arbiter — no card is claimed until real sound starts.
    private func restoreAutoSuspended(_ auto: MixDeckSessionStore.AutoSnapshot) {
        guard !auto.queue.isEmpty else { return }
        autoQueue = auto.queue.map {
            AutoMixItem(loadable: MixLoadable(songId: $0.track.songId, title: $0.track.title,
                                              artist: $0.track.artist, bpm: $0.track.bpm,
                                              camelot: $0.track.camelot, key: $0.track.key,
                                              albumId: $0.track.albumId, lengthMs: $0.track.lengthMs),
                        durationMs: $0.durationMs, sourceLabel: $0.sourceLabel)
        }
        autoRepeat = auto.repeatMode.flatMap(AutoRepeatMode.init(rawValue:)) ?? .off
        autoEnabled = true
        autoSourceLabel = auto.sourceLabel
        autoLeadSeconds = max(1, auto.leadSeconds)
        autoFadeSeconds = max(0.2, auto.fadeSeconds)
        fxGlideEnabled = auto.fxGlide
        mixGlideEnabled = auto.mixGlide
        autoLivePos = min(max(0, auto.livePos), autoQueue.count - 1)
        autoNextToLoad = min(max(0, auto.nextToLoad), autoQueue.count)
        autoLiveDeck = Deck(rawValue: auto.liveDeck) ?? .a
        // Fresh machine internals — no in-flight transition, no frozen clocks, no stale intents.
        autoFadeStartedAt = nil; autoPrerollStartedAt = nil; autoPostrollStartedAt = nil
        autoTransitionIsGlide = false; glideCtx = nil
        autoTransitionRepeatOne = false; autoTransitionWrap = false
        pendingFadeRestore = nil
        autoResumeEndDeck = nil
        resumeAutoOnRemotePlay = false
        remotePausedAt = nil
        engineStallAt = nil
        autoDeckEndsAt = [:]                 // re-stamped by resumeAuto from live positions
        fxTextureEffect = nil; fxTextureRunRemaining = 0
        fxGlidePrng = Self.fxSeed(from: autoQueue)
        for d in Deck.allCases where state(d).loaded != nil {
            autoDeckDurationMs[d] = Int(duration(d) * 1000)
        }
        autoPaused = true                    // SUSPENDED — never self-resumes
        autoResumeFromRestore = true         // first resume: restored cursor wins over the play-log
        autoMixing = true
        refreshAutoStatus()
    }

    /// End the WHOLE mix — stop any Auto-DJ and eject both decks. The Settings nuclear reset
    /// rides this; with both decks empty the persist hook `clear()`s the durable session, so a
    /// reset device launches quiet. Also drops a not-yet-materialized restore.
    func ejectAll() {
        pendingMixRestore = nil
        endAutoLoop()
        clearDeck(.a)
        clearDeck(.b)
    }

    /// Snapshot the ENTIRE mix into the session store. `debounced` for continuous surfaces
    /// (sliders); immediate for structural changes. Nothing worth restoring (both decks empty,
    /// no auto queue) ⇒ the session is CLEARED — the mix is over. Guarded off while a restore
    /// materializes (its `defer` re-syncs once) and while a parked snapshot awaits
    /// materialization (the on-disk file IS the pending state — an idle-engine write must not
    /// clobber or clear it).
    private func persistMixDeckSession(debounced: Bool = false) {
        guard let sessionStore, !isRestoringMixSession, pendingMixRestore == nil else { return }
        guard let snap = mixDeckSnapshot() else { sessionStore.clear(); return }
        if debounced { sessionStore.saveDebounced(snap) } else { sessionStore.save(snap) }
    }

    /// The live state → snapshot builder. nil when there is nothing to restore.
    private func mixDeckSnapshot() -> MixDeckSessionStore.Snapshot? {
        let a = deckSnapshot(.a)
        let b = deckSnapshot(.b)
        var auto: MixDeckSessionStore.AutoSnapshot?
        if autoMixing, !autoQueue.isEmpty {
            auto = MixDeckSessionStore.AutoSnapshot(
                queue: autoQueue.map {
                    MixDeckSessionStore.AutoRow(track: trackRef($0.loadable), durationMs: $0.durationMs,
                                                sourceLabel: $0.sourceLabel)
                },
                livePos: autoLivePos, nextToLoad: autoNextToLoad,
                liveDeck: autoLiveDeck.rawValue, sourceLabel: autoSourceLabel,
                leadSeconds: autoLeadSeconds, fadeSeconds: pendingFadeRestore ?? autoFadeSeconds,
                fxGlide: fxGlideEnabled, mixGlide: mixGlideEnabled,
                repeatMode: autoRepeat == .off ? nil : autoRepeat.rawValue)
        }
        guard a != nil || b != nil || auto != nil else { return nil }
        return MixDeckSessionStore.Snapshot(
            deckA: a, deckB: b, crossfader: crossfader, leadDeck: leadDeck?.rawValue,
            auto: auto, wasRunning: isRunning,
            updatedAt: Date().timeIntervalSince1970 * 1000)
    }

    private func deckSnapshot(_ deck: Deck) -> MixDeckSessionStore.DeckSnapshot? {
        let s = state(deck)
        guard let l = s.loaded else { return nil }
        // `lengthMs` round-trips the playback WINDOW (`duration` = the scheduled slice): a
        // per-song cut reports its full length (and re-load ignores it), an analog shared-album
        // fallback reports its song slice — exactly what its re-load needs to re-window.
        let lengthMs = duration(deck) > 0 ? Int(duration(deck) * 1000) : nil
        return MixDeckSessionStore.DeckSnapshot(
            track: MixDeckSessionStore.TrackRef(songId: l.songId, title: l.title, artist: l.artist,
                                                bpm: l.bpm, camelot: l.camelot, key: l.key,
                                                albumId: l.albumId, lengthMs: lengthMs),
            positionMs: max(0, Int(position(deck) * 1000)),
            volume: s.volume, rate: s.rate, pitch: s.pitch,
            // The flat per-effect fields are written through the FIRST-MATCH shims. They're the
            // rollback contract: an older build (which knows nothing about slots) still restores a
            // sane deck from them. The rack's own lossless form rides `fxSlots` (added next).
            compressor: s.isEnabled(.compressor), reverb: s.isEnabled(.reverb),
            flanger: s.isEnabled(.flanger), filter: s.isEnabled(.filter),
            compStrength: s.strength(.compressor), reverbStrength: s.strength(.reverb),
            flangerStrength: s.strength(.flanger), filterStrength: s.strength(.filter),
            stemMode: s.stemMode, stemMuted: Array(s.stemMuted).sorted(), stemVol: s.stemVol,
            loopOn: s.loopOn, loopUnits: s.loopUnits,
            eqLow: s.eqLow, eqMid: s.eqMid, eqHigh: s.eqHigh,
            filterMode: filterMode(deck).rawValue,
            // The rack's LOSSLESS form — duplicates, varieties, and per-slot state that the flat
            // fields above can't express.
            fxSlots: s.slots.map {
                MixDeckSessionStore.FXSlotSnapshot(effect: $0.effect.rawValue,
                                                   variant: $0.variant.rawValue,
                                                   on: $0.enabled, strength: $0.strength,
                                                   modSource: $0.mod.source == .off ? nil : $0.mod.source.rawValue,
                                                   modRate: $0.mod.source == .off ? nil : $0.mod.rate.rawValue,
                                                   modShape: $0.mod.source == .off ? nil : $0.mod.shape.rawValue,
                                                   modDepth: $0.mod.source == .off ? nil : $0.mod.depth,
                                                   modPhase: $0.mod.source == .off ? nil : $0.mod.phase)
            })
    }

    private func trackRef(_ l: MixLoadable) -> MixDeckSessionStore.TrackRef {
        MixDeckSessionStore.TrackRef(songId: l.songId, title: l.title, artist: l.artist,
                                     bpm: l.bpm, camelot: l.camelot, key: l.key,
                                     albumId: l.albumId, lengthMs: l.lengthMs)
    }

    /// The decks' playheads → the store's throttled position channel (immediate on a run/pause
    /// transition, ~5 s otherwise). Fed by the ~10 Hz tick and every `setPlaying` transition.
    private func persistMixPositions() {
        guard !isRestoringMixSession, pendingMixRestore == nil else { return }
        sessionStore?.updatePosition(aMs: Int(positionA * 1000), bMs: Int(positionB * 1000),
                                     isRunning: deckA.isPlaying || deckB.isPlaying)
    }

    // MARK: - Readers (for the UI)

    func loaded(_ deck: Deck) -> LoadedTrack? { state(deck).loaded }
    func isPlaying(_ deck: Deck) -> Bool { state(deck).isPlaying }
    func volume(_ deck: Deck) -> Double { state(deck).volume }
    func rate(_ deck: Deck) -> Double { state(deck).rate }
    func pitch(_ deck: Deck) -> Double { state(deck).pitch }
    func isEnabled(_ effect: Effect, on deck: Deck) -> Bool { state(deck).isEnabled(effect) }
    func strength(_ effect: Effect, on deck: Deck) -> Double { state(deck).strength(effect) }
    func position(_ deck: Deck) -> Double { deck == .a ? positionA : positionB }
    func duration(_ deck: Deck) -> Double { deck == .a ? durationA : durationB }

    // MARK: - VU metering (pre/post fader)

    /// The deck's non-observable level mirror — poll from a `TimelineView` (never triggers observation).
    func levels(_ deck: Deck) -> MixDeckLevels { deck == .a ? levelsA : levelsB }
    /// The deck's meter source (pre/post fader) — observable; the meter's context menu toggles it.
    func meterSource(_ deck: Deck) -> MeterSource { deck == .a ? meterSourceA : meterSourceB }
    func setMeterSource(_ source: MeterSource, on deck: Deck) {
        switch deck { case .a: meterSourceA = source; case .b: meterSourceB = source }
    }

    /// Peak-hold decay + RMS one-pole coefficients, applied once per tap callback (~10 Hz at 4096
    /// frames / 44.1 kHz). `vuPeakDecay` ≈ −1.4 dB/callback ≈ −15 dB/s peak fall; the RMS body rises
    /// fast (attack) and falls slower (release) for a settled VU-style read.
    private static let vuPeakDecay: Float = 0.85
    private static let vuRmsAttack: Float = 0.5
    private static let vuRmsRelease: Float = 0.2

    /// Instantaneous peak + RMS of one tap buffer across all channels — runs ON the realtime tap
    /// thread (a straight float loop over ≤4096 frames × ≤2 ch is microseconds). Peak across channels
    /// (a hard-panned mix still meters), RMS over every sample.
    private nonisolated static func vuMeter(_ buffer: AVAudioPCMBuffer) -> (peak: Float, rms: Float) {
        guard let chans = buffer.floatChannelData, buffer.frameLength > 0 else { return (0, 0) }
        let n = Int(buffer.frameLength)
        let ch = Int(buffer.format.channelCount)
        var peak: Float = 0
        var sumSq: Float = 0
        for c in 0..<ch {
            let samples = chans[c]
            for i in 0..<n {
                let v = samples[i]
                let a = abs(v)
                if a > peak { peak = a }
                sumSq += v * v
            }
        }
        return (peak, sqrtf(sumSq / Float(n * max(ch, 1))))
    }

    /// The TRUE audio playhead in source seconds, read from the deck's player render clock (NOT the
    /// ~10 Hz wall-clock accumulator), so a visual that wants sample-accuracy — the beat pulse — can
    /// phase-lock to what you actually hear. `playerTime.sampleTime` is in the file's own sample rate
    /// and resets to 0 each `scheduleSegment`, so add back `segmentStartSeconds`; the time-stretch
    /// rate is already baked into how fast it advances, so dividing by the file rate gives source
    /// seconds at any tempo. nil while not rendering (just-loaded / paused-after-seek / stem mode) →
    /// callers fall back to `position`.
    func truePlayhead(_ deck: Deck) -> Double? {
        guard !stemActive(deck),
              let player = players[deck], let nodeTime = player.lastRenderTime,
              let pt = player.playerTime(forNodeTime: nodeTime),
              let sr = sampleRates[deck], sr > 0 else { return nil }
        let raw = (segmentStartSeconds[deck] ?? 0) + Double(pt.sampleTime) / sr
        // LOOPING: the node's timeline runs monotonically across the queued repeats, so fold it
        // back into the window — every caller (beat pulse, seek slider, snapshot) wants the
        // position you HEAR, which is inside the loop.
        if let w = loopWindow(deck), raw >= w.start {
            return w.start + (raw - w.start).truncatingRemainder(dividingBy: w.end - w.start)
        }
        return raw
    }

    /// The deck whose track is the Mix's "Now Playing" — what the lock-screen card shows. Rule: if
    /// exactly ONE deck is actively playing, that's the one ("the only active track"); otherwise
    /// (zero or both playing) fall back to Deck A regardless of its play state — and to Deck B only
    /// when A is empty. nil only when neither deck has a track loaded.
    var nowPlayingDeck: Deck? {
        let aLoaded = loaded(.a) != nil, bLoaded = loaded(.b) != nil
        let aPlaying = aLoaded && isPlaying(.a), bPlaying = bLoaded && isPlaying(.b)
        if aPlaying != bPlaying { return aPlaying ? .a : .b }   // exactly one playing → that deck
        // Ambiguous (zero or both playing): STAY with the last unambiguous subject — pausing deck B
        // must not flip the card (title + art) over to deck A, only to flip back on resume. The
        // A-then-B preference is just the cold-start fallback when there's no history for a loaded deck.
        if let last = lastNowPlayingDeck, state(last).loaded != nil { return last }
        if aLoaded { return .a }                                 // cold start: prefer Deck A
        return bLoaded ? .b : nil
    }
    /// The deck the card last showed while playback was unambiguous (exactly one deck playing).
    /// Keeps the card sticky across pause (zero playing) and blends (both playing).
    @ObservationIgnored private var lastNowPlayingDeck: Deck?

    /// The track behind `nowPlayingDeck` (the in-app + lock-screen "Now Playing").
    var nowPlaying: LoadedTrack? { nowPlayingDeck.flatMap { loaded($0) } }

    // MARK: - System Now Playing (lock screen / Control Center)

    /// Push the now-playing track to the system lock-screen / Control Center card — but only while
    /// THIS engine owns the card (a Mix deck started most recently; see `NowPlayingArbiter`). When the
    /// standalone player is the active source instead, this no-ops so the two never stomp each other.
    /// Elapsed/rate are set on each transport change and the system interpolates between; the rate is
    /// the deck's tempo so the scrubber moves at the audible speed.
    private func updateSystemNowPlaying() {
        // Restoring a session must claim NO card (the one-audio-owner rule): at cold launch the
        // arbiter is unowned, so without this gate the restore's deck loads/seeks would write a
        // paused card for audio nobody started. The first real play claims + writes as usual.
        guard !isRestoringMixSession else { return }
        guard NowPlayingArbiter.shared.isActive(self) else { return }
        guard let deck = nowPlayingDeck, let track = loaded(deck) else { return }
        // Re-assert ⏭/⏮ enablement on EVERY card write, not just at startAutoMix: a standalone-player
        // interlude (song audition / setlist) flips the same shared commands off via its own lifecycle,
        // and without this the skips would stay dead for the remainder of a running auto-mix.
        setLockScreenSkipCommandsEnabled(autoMixing)
        // The Mix/Auto-DJ card offers NO ♥ (a live blend has no single "current track" the like layer can
        // own). DISABLE the shared `likeCommand` while THIS engine owns the card — mirrors the ⏭/⏮ dance
        // above so the ♥ appears ONLY on the standalone player's card, whose owner (`PlayerEngine`) can
        // actually service it. `PlayerEngine` re-enables it whenever IT reclaims the card. Also drop any
        // stale fill so a previously-favorited player track's heart doesn't linger on the Mix card. Diffed
        // so a same-value set doesn't churn the shared command center on every position tick.
        let like = MPRemoteCommandCenter.shared().likeCommand
        if like.isEnabled { like.isEnabled = false }
        if like.isActive { like.isActive = false }
        refreshArtworkIfNeeded(for: track.songId)
        let playing = isPlaying(deck)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position(deck),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? state(deck).rate : 0.0,
        ]
        let dur = duration(deck)
        if dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur }
        if let nowPlayingArtwork, nowPlayingArtworkSongId == track.songId {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        NPLog.trace("mix card WRITE title=\(track.title) playing=\(playing)")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // Explicit playbackState so CarPlay (head-unit Now Playing + system Now Playing app) and
        // watchOS reflect the deck's transport, not just the info dict's PlaybackRate.
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    /// Fetch cover art for the now-playing card ONLY when the song id actually changed since the
    /// last fetch — `updateSystemNowPlaying` fires on every position tick, so this must not re-fetch
    /// every call. `artworkToken` supersedes an in-flight fetch when the song changes again before
    /// it resolves, so a slow image never lands on the wrong track.
    private func refreshArtworkIfNeeded(for songId: String) {
        guard songId != nowPlayingArtworkSongId else { return }
        nowPlayingArtworkSongId = songId
        nowPlayingArtwork = nil
        artworkToken += 1
        let token = artworkToken
        guard let provider = artworkURLsProvider else { return }
        Task { @MainActor [weak self] in
            // Provider runs inside the superseded task — its streaming fallback can hit the
            // network, and a slow resolve for an already-ejected track must drop, not land.
            let urls = await provider(songId)
            guard self?.artworkToken == token, !urls.isEmpty else { return }
            guard let image = await PlayerEngine.loadFirstImage(urls) else { return }
            guard let self, self.artworkToken == token else { return }   // song changed again → drop
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateSystemNowPlaying()
        }
    }

    /// Register the shared remote-command handlers ONCE. Each is guarded by `NowPlayingArbiter` so it
    /// only acts while the Mix owns the lock screen — the standalone `PlayerEngine` registers the same
    /// commands and yields when the Mix is active (and vice-versa), so the lock-screen transport always
    /// drives the audio source you're actually hearing.
    private func configureMixRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        // ⏸/▶ are the REMOTE pair: pause suspends a running Auto-DJ (never ends it — no silent drop
        // to manual mode), play resumes ONLY what the pause silenced and un-suspends the Auto-DJ.
        center.playCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self) else { return .commandFailed }
            self.remotePlay(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self) else { return .commandFailed }
            self.remotePause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self) else { return .commandFailed }
            if self.isRunning { self.remotePause() } else { self.remotePlay() }
            return .success
        }
        // Auto-mix only: ⏭ = the FAST switch (5 s sweep — in-app double-tap Skip); ⏮ = the SLOW
        // switch (the Settings ▸ Mix skip-fade — in-app single-tap Skip). Both advance the queue;
        // there is no "previous track" in a live mix, so ⏮ maps to the gentler transition instead.
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self), self.autoMixing else { return .commandFailed }
            self.remoteSkip(fadeSeconds: 5); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self), self.autoMixing else { return .commandFailed }
            self.remoteSkip(fadeSeconds: self.skipFadeSeconds); return .success
        }
    }

    /// Enable/disable the shared lock-screen ⏭/⏮ with the Auto-DJ's lifecycle — they only advance the
    /// auto-mix queue, so outside auto-mix the Mix card offers play/pause only. The commands are
    /// PROCESS-GLOBAL (`MPRemoteCommandCenter`), shared with `PlayerEngine`'s setlist ⏮/⏭, so three
    /// rules keep the two engines from stranding each other:
    ///  • `updateSystemNowPlaying` re-asserts this on every card write while the Mix owns the card
    ///    (heals after a standalone-player interlude flipped the commands off mid-auto-mix),
    ///  • `endAutoLoop` flips them off ONLY while the Mix owns the card (a set that owns it keeps its
    ///    own enablement),
    ///  • `PlayerEngine` re-asserts its setlist-driven enablement whenever IT reclaims the card.
    /// Writes are diffed — this runs per card write, and same-value sets shouldn't churn the card.
    private func setLockScreenSkipCommandsEnabled(_ on: Bool) {
        let center = MPRemoteCommandCenter.shared()
        if center.nextTrackCommand.isEnabled != on { center.nextTrackCommand.isEnabled = on }
        if center.previousTrackCommand.isEnabled != on { center.previousTrackCommand.isEnabled = on }
    }

    // MARK: - Internals

    private func state(_ deck: Deck) -> DeckState { deck == .a ? deckA : deckB }

    private func mutate(_ deck: Deck, _ body: (inout DeckState) -> Void) {
        switch deck { case .a: body(&deckA); case .b: body(&deckB) }
    }

    private func setPosition(_ deck: Deck, _ v: Double) {
        switch deck { case .a: positionA = v; case .b: positionB = v }
    }
    private func setDuration(_ deck: Deck, _ v: Double) {
        switch deck { case .a: durationA = v; case .b: durationB = v }
    }

    private func other(_ d: Deck) -> Deck { d == .a ? .b : .a }

    private func refreshTransport() {
        isRunning = deckA.isPlaying || deckB.isPlaying
        #if os(iOS)
        // ANY resume (in-app deck ▶, master play, lock-screen ▶/⏭) supersedes an interruption's
        // park — a later stray .ended must not auto-resume over a subsequent deliberate pause.
        if isRunning { interruptionParked = false }
        #endif
    }

    /// Push gains onto the graph. The deck's main VOLUME + equal-power crossfade live downstream on
    /// `mainGains` (see `applyCueRouting`), NOT on the source nodes — so the post-FX CUE tap is
    /// independent of the main fader (true PFL: a separate cue-volume slider sets the monitor level).
    /// The player runs at unity; the stem nodes carry only their per-stem balance.
    private func applyMixGains() {
        guard built else { return }
        players[.a]?.volume = 1
        players[.b]?.volume = 1
        applyStemGains(.a)
        applyStemGains(.b)
        applyCueRouting()
    }

    /// The deck's main volume CLAMPED to ≤1.0 (the documented 0…1 mixer range). The >unity boost
    /// (100%…200%) is added separately on the deck's filter EQ `globalGain` (see `applyBoost`). Used
    /// only on the MAIN bus; the cue bus uses the independent `cueVol`.
    private func userGain(_ deck: Deck) -> Float { Float(min(state(deck).volume, 1.0)) }

    /// The equal-power crossfade factor for a deck (0…1): full at its own end, →0 at the other.
    private func crossfadeFactor(_ deck: Deck) -> Float {
        let v = Float(crossfader)
        return deck == .a ? cosf(.pi / 2 * v) : cosf(.pi / 2 * (1 - v))
    }

    /// Route each deck onto the main + cue buses (PFL). MAIN always carries the deck at its own
    /// volume × the equal-power crossfade (so the existing Vol slider + crossfader still drive the
    /// house mix); CUE *additionally* monitors a cued deck at its independent `cueVol`, untouched by
    /// the main fader or crossfader. While ANY deck is cued the two buses pan hard to opposite
    /// channels (main vs `cueOnRight`); when nothing is cued both stay centered, so an un-cued mix is
    /// bit-identical normal stereo (no surprise mono for casual listening).
    private func applyCueRouting() {
        guard built else { return }
        let active = deckA.cued || deckB.cued
        let cueSide: Float = cueOnRight ? 1 : -1
        // The house pan lives on the shared `housePan` node — DOWNSTREAM of the recording tap
        // (`houseSum`) — so a capture stays clean stereo house even while a deck is cued. The per-deck
        // `mainGains` stay centered (they only carry the deck's volume × crossfade now).
        housePan?.pan = active ? -cueSide : 0
        for d in Deck.allCases {
            mainGains[d]?.outputVolume = userGain(d) * crossfadeFactor(d)
            mainGains[d]?.pan = 0
            // Cue is pre-fader AND pre-boost: the >unity boost lives on the shared EQ UPSTREAM of the
            // split (it can't sit on a mixer's 0…1 outputVolume), so it leaks into this tap. Divide it
            // back out (`/ max(vol,1)`) so the monitor level is exactly `cueVol`, untouched by the Vol
            // slider/crossfader. (≤100% ⇒ divide by 1, a no-op.)
            cueGains[d]?.outputVolume = state(d).cued
                ? Float(state(d).cueVol) / Float(max(state(d).volume, 1.0)) : 0
            cueGains[d]?.pan = cueSide
        }
    }

    /// Apply the deck's >unity volume boost as the TRIM node's `globalGain`: 0 dB at ≤100%, up to
    /// +6 dB at 200%. Trim sits downstream of the deck's `inputMixer`, so the boost lifts the main
    /// file AND the 4 stems uniformly, and upstream of the main/cue split, so `applyCueRouting`'s
    /// divide-out still yields an unboosted monitor. Driven ONLY by a volume change (build /
    /// `setVolume` / `resetDeck`) — never the crossfader path — so an equal-power fade doesn't
    /// re-write it.
    ///
    /// Pre-rack this rode the deck's filter EQ; once "filter" became a swappable slot effect that a
    /// rack may not contain at all, the boost needed a node that is ALWAYS present.
    private func applyBoost(_ deck: Deck) {
        guard built else { return }
        trims[deck]?.globalGain = Float(20 * log10(max(state(deck).volume, 1.0)))
    }

    /// Push one EQ band's gain onto the deck's always-active 3-band `AVAudioUnitEQ` node.
    private func applyEQ(_ band: EQBand, on deck: Deck) {
        eqs[deck]?.bands[band.bandIndex].gain = Float(state(deck).eqGain(band))
    }
    private func applyAllEQ(_ deck: Deck) {
        for b in EQBand.allCases { applyEQ(b, on: deck) }
    }

    /// Set each stem node's volume to ONLY its per-stem balance (0…1, zeroed when muted) — exactly like
    /// the single-file player, which now runs at unity. The deck volume + crossfade live downstream on
    /// `mainGains`, and the cue send taps upstream of them, so stems ride the main fader + cue PFL for
    /// free without the deck gain being applied twice. Harmless when not in stem mode (those nodes
    /// aren't scheduled → silent regardless).
    private func applyStemGains(_ deck: Deck) {
        guard let nodes = stemPlayers[deck] else { return }
        let st = state(deck)
        for (name, node) in nodes {
            node.volume = st.stemMuted.contains(name) ? 0 : Float(st.stemVol[name] ?? 1.0)
        }
    }

    private func applyRate(_ deck: Deck) { timePitches[deck]?.rate = Float(state(deck).rate) }
    private func applyPitch(_ deck: Deck) { timePitches[deck]?.pitch = Float(state(deck).pitch * 100) } // cents

    /// Realize ONE rack slot onto its pre-allocated nodes: bypass every effect type in the bundle
    /// except the one this slot currently holds (and bypass them ALL when the slot is off), handle
    /// the reverb preset, then push the active node's parameters.
    ///
    /// This is the ONLY place the rack changes graph STATE (bypasses + preset), and it never
    /// attaches, detaches, or reconnects anything — a mid-mix swap is just these four `bypass`
    /// writes. The per-frame VALUE writes live in `writeSlotParams`, which the modulation tick
    /// calls directly so it can never touch bypasses or reload a reverb tail at 60 Hz.
    private func applySlot(_ i: Int, on deck: Deck) {
        guard built, let bundle = slotNodes[deck]?[safe: i],
              let slot = state(deck).slots[safe: i] else { return }
        let live = slot.enabled
        bundle.comp.bypass   = !(live && slot.effect == .compressor)
        bundle.filter.bypass = !(live && slot.effect == .filter)
        bundle.reverb.bypass = !(live && slot.effect == .reverb)
        bundle.mod.bypass    = !(live && slot.effect == .flanger)
        guard live else { return }          // fully bypassed ⇒ its parameters are inaudible
        // `loadFactoryPreset` rebuilds the reverb tail — only on an ACTUAL variant change, never
        // per glide/mod tick.
        if slot.effect == .reverb, bundle.loadedPreset != slot.variant {
            bundle.reverb.loadFactoryPreset(FXParams.reverbPreset(slot.variant))
            bundle.loadedPreset = slot.variant
        }
        writeSlotParams(i, on: deck, slot: slot, strength: effectiveStrength(i, on: deck))
    }

    /// The strength the NODES should see right now: the user's stored value plus the modulator's
    /// current offset (beat-synced LFO phase / envelope level, both from non-observable mirrors the
    /// mod tick maintains). Read by EVERY write path — including the 10 Hz Auto-DJ glide, whose
    /// `setGlideSlot` moves the BASE while the LFO keeps wobbling around it (they compose instead
    /// of the glide stomping the wobble). Identity while the slot doesn't modulate, and for the
    /// families `FXParams.modulates` scopes out.
    private func effectiveStrength(_ i: Int, on deck: Deck) -> Double {
        guard let slot = state(deck).slots[safe: i] else { return 0.5 }
        guard slot.mod.source != .off, FXParams.modulates(slot.effect) != nil else { return slot.strength }
        return FXParams.modulated(base: slot.strength, mod: slot.mod,
                                  phase01: modPhaseMirror[deck]?[safe: i] ?? nil,
                                  env: envMirror[deck] ?? 0)
    }

    /// Pure node VALUE writes for one live slot — no bypass churn, no preset loads, no allocation.
    /// `strength` is the LIVE (possibly modulated) value; `slot.strength` remains the user's base.
    /// The single delayTime rule lives here: `AVAudioUnitDelay.delayTime` is derived from the BASE
    /// strength only — an un-ramped delay-length jump moves the read pointer mid-waveform and
    /// clicks, so modulation may move wet/feedback but the comb length follows only deliberate
    /// user gestures (exactly as before modulation existed).
    private func writeSlotParams(_ i: Int, on deck: Deck, slot: FXSlot, strength: Double) {
        guard built, let bundle = slotNodes[deck]?[safe: i] else { return }
        let v = slot.variant
        let s = strength
        switch slot.effect {
        case .reverb:
            bundle.reverb.wetDryMix = Float(s) * 100
        case .filter:
            guard let band = bundle.filter.bands.first else { return }
            band.bypass = false             // the NODE's bypass (applySlot) gates the effect
            band.filterType = FXParams.filterType(v)
            band.frequency = FXParams.filterFrequency(v, s)
            band.bandwidth = FXParams.filterBandwidth(v, s)
        case .flanger:
            bundle.mod.delayTime = FXParams.modDelayTime(v, slot.strength)   // BASE only — see doc
            bundle.mod.feedback = FXParams.modFeedback(v, s)
            bundle.mod.wetDryMix = FXParams.modWetDryMix(v, s)
            bundle.mod.lowPassCutoff = FXParams.modLowPassCutoff(v)
        case .compressor:
            let au = bundle.comp.audioUnit
            AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold,
                                  kAudioUnitScope_Global, 0, FXParams.compThreshold(v, s), 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom,
                                  kAudioUnitScope_Global, 0, FXParams.compHeadRoom(v), 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime,
                                  kAudioUnitScope_Global, 0, FXParams.compAttack(v), 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime,
                                  kAudioUnitScope_Global, 0, FXParams.compRelease(v), 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain,
                                  kAudioUnitScope_Global, 0, FXParams.compMakeup(v, s), 0)
        }
    }

    private func applyAllSlots(_ deck: Deck) {
        for i in 0..<DeckState.slotCount { applySlot(i, on: deck) }
    }

    // MARK: - The modulation tick (~60 Hz)

    /// Whether ANY rendering deck currently has a slot worth modulating.
    private var modWanted: Bool {
        Deck.allCases.contains { d in
            state(d).isPlaying && state(d).slots.contains {
                $0.enabled && $0.mod.source != .off && FXParams.modulates($0.effect) != nil
            }
        }
    }

    private func startModTickIfNeeded() {
        guard modTask == nil, modWanted else { return }
        modTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)   // ~60 Hz
                if Task.isCancelled { break }
                guard let self, self.modFire() else { break }
            }
        }
    }

    /// One modulation step. Reads the phase clock, computes each live modulated slot's current
    /// value, and writes ONLY node parameters + private mirrors — nothing observable, nothing
    /// persisted, nothing recorded (the PlayerClock doctrine). Phase is DERIVED from the playhead
    /// each tick, never integrated, so tick jitter cannot accumulate into drift.
    /// Returns false (and clears `modTask`) when nothing needs modulating — the task self-exits.
    private func modFire() -> Bool {
        guard built else { modTask = nil; return false }
        var anyLive = false
        let now = Date().timeIntervalSinceReferenceDate
        for d in Deck.allCases {
            let slots = state(d).slots
            let liveIdx = slots.indices.filter {
                slots[$0].enabled && slots[$0].mod.source != .off
                    && FXParams.modulates(slots[$0].effect) != nil
            }
            guard state(d).isPlaying, !liveIdx.isEmpty else {
                // SNAP-BACK: the deck stopped (or its modulated slots turned off) mid-wobble —
                // land every node back on the user's stored strengths exactly once.
                if modWasActive[d] == true {
                    modWasActive[d] = false
                    modPhaseMirror[d] = nil
                    modLastWritten[d] = nil
                    applyAllSlots(d)
                }
                continue
            }
            anyLive = true
            modWasActive[d] = true
            let atMs = modClockPosition(d, now: now) * 1000
            let t = state(d).loaded
            var phases = modPhaseMirror[d] ?? Array(repeating: nil, count: DeckState.slotCount)
            var written = modLastWritten[d] ?? Array(repeating: -1, count: DeckState.slotCount)
            for i in liveIdx {
                let slot = slots[i]
                var phase: Double?
                if slot.mod.source == .lfo, let t {
                    phase = BeatMath.cyclePhase(atMs: atMs,
                                                beatsMs: t.beatsMs, downbeatsMs: t.downbeatsMs,
                                                bpm: (t.gridBpm ?? t.bpm) ?? 0,
                                                firstDownbeatMs: t.firstDownbeatMs ?? 0,
                                                cycleBeats: slot.mod.rate.beats,
                                                offset: slot.mod.phase)
                }
                phases[i] = phase
                modPhaseMirror[d] = phases
                let eff = effectiveStrength(i, on: d)
                // Dead-band: skip the AU write when the value hasn't meaningfully moved (an idle
                // envelope / zero-depth LFO costs nothing).
                if abs(eff - written[i]) >= 0.002 {
                    writeSlotParams(i, on: d, slot: slot, strength: eff)
                    written[i] = eff
                }
            }
            modLastWritten[d] = written
        }
        if !anyLive, Deck.allCases.allSatisfy({ modWasActive[$0] != true }) {
            modTask = nil
            return false
        }
        return true
    }

    /// The deck's CURRENT source position (seconds) for phase derivation: the sample-accurate
    /// `truePlayhead` when the render clock serves (loop-folded), else the 10 Hz `position`
    /// accumulator EXTRAPOLATED by wall-clock × rate since it last changed — clamped to a little
    /// over one main-tick period so a stalled engine can't run the phase away.
    private func modClockPosition(_ deck: Deck, now: Double) -> Double {
        if let tp = truePlayhead(deck) {
            modClockLastPos[deck] = tp
            modClockStamp[deck] = now
            return tp
        }
        let p = position(deck)
        if modClockLastPos[deck] != p {
            modClockLastPos[deck] = p
            modClockStamp[deck] = now
            return p
        }
        let elapsed = min(now - (modClockStamp[deck] ?? now), 0.15)
        return p + max(elapsed, 0) * state(deck).rate
    }

    /// Push every slot holding `effect` — the bridge for the effect-keyed shims (`setEffect`,
    /// `setEffectStrength`, the Auto-DJ glide), which address a family rather than a position.
    /// With duplicates in the rack, one family write legitimately touches several slots.
    private func applyEffect(_ effect: Effect, on deck: Deck) {
        guard built else { return }
        for (i, s) in state(deck).slots.enumerated() where s.effect == effect {
            applySlot(i, on: deck)
        }
    }

    /// The fixed downstream format. The effect chain (inputMixer → … → mainMixer) is wired at this
    /// canonical stereo format ONCE and never reconnected, so no per-file load can reconfigure a live
    /// AU's channel count / sample rate (which AVAudioEngine asserts-and-crashes on).
    private static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// Serially connect a deck's chain at the fixed canonical format:
    /// `inputMixer → timePitch → slot0 … slot3 (4 nodes each) → eq3 → trim`.
    /// Called ONCE per deck at build; NEVER reconnected — the rack changes by bypass, not by
    /// rewiring. The trim's output is split onto the main + cue buses by the caller (`ensureEngine`).
    private func connectChain(_ deck: Deck, nodes: [AVAudioNode]) {
        let fmt = Self.canonicalFormat
        for (a, b) in zip(nodes, nodes.dropFirst()) { engine.connect(a, to: b, format: fmt) }
    }

    /// One-time band setup for a deck's 3-band EQ node: low shelf @ 320 Hz, mid peak @ 1 kHz
    /// (moderate Q so it doesn't smear neighboring bands), high shelf @ 3.2 kHz — standard DJ-mixer
    /// EQ points. Only `gain` changes after this (per `applyEQ`); type/frequency/bandwidth are fixed.
    private static func configureEQ3(_ eq: AVAudioUnitEQ) {
        let low = eq.bands[EQBand.low.bandIndex]
        low.filterType = .lowShelf
        low.frequency = 320
        low.gain = 0
        low.bypass = false
        let mid = eq.bands[EQBand.mid.bandIndex]
        mid.filterType = .parametric
        mid.frequency = 1000
        mid.bandwidth = 1.0
        mid.gain = 0
        mid.bypass = false
        let high = eq.bands[EQBand.high.bandIndex]
        high.filterType = .highShelf
        high.frequency = 3200
        high.gain = 0
        high.bypass = false
    }

    /// Octave-fold a tempo ratio into `rateRange` (×2 / ÷2 = half/double-time match), then clamp.
    /// Pure + testable. A non-finite / non-positive ratio (missing BPM) folds to 1.0 (no change).
    nonisolated static func octaveFolded(_ ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 1 }
        var r = ratio
        while r > rateRange.upperBound { r /= 2 }
        while r < rateRange.lowerBound { r *= 2 }
        return min(max(r, rateRange.lowerBound), rateRange.upperBound)
    }

    /// The follower tempo multiplier that matches the Lead's effective BPM (octave-folded into range).
    /// Pure + testable.
    nonisolated static func syncRate(leadBPM: Double, leadRate: Double, followerBPM: Double) -> Double {
        guard followerBPM > 0 else { return 1 }
        return octaveFolded(leadBPM * leadRate / followerBPM)
    }

    /// BEST-EFFORT downbeat phase-align: nudge the follower up to ±½ beat so its beat phase matches
    /// the lead's, assuming beat-0 at each song's start (BPM only — no beat-grid yet). The grid
    /// indexer (see docs/design/mix-ondevice-tempo-pitch-beatmatch-spec.md) makes this exact.
    private func phaseAlign(follower f: Deck, lead l: Deck) {
        guard state(f).isPlaying, state(l).isPlaying,
              let leadBPM = matchBPM(l), let folBPM = matchBPM(f) else { return }
        let leadBeat = 60.0 / leadBPM
        let folBeat = 60.0 / folBPM
        // Phase RELATIVE TO each song's measured first downbeat (0 when the grid is absent — the old
        // beat-0-at-song-start assumption). Both positions are song-relative, so this aligns the
        // decks' actual downbeats rather than an arbitrary beat-of-bar.
        let leadDb = Double(state(l).loaded?.firstDownbeatMs ?? 0) / 1000.0
        let folDb = Double(state(f).loaded?.firstDownbeatMs ?? 0) / 1000.0
        let leadPhase = ((position(l) - leadDb) / leadBeat).truncatingRemainder(dividingBy: 1)
        let folPhase = ((position(f) - folDb) / folBeat).truncatingRemainder(dividingBy: 1)
        var delta = leadPhase - folPhase
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        seek(f, toSeconds: max(0, position(f) + delta * folBeat))
    }

    // MARK: - Tick (playhead + auto-mix)

    private func startTickIfNeeded() {
        startModTickIfNeeded()   // playback (re)starting is also the mod tick's wake signal
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

    /// Advance playheads + step the auto-mix; returns false (→ stop ticking) when fully idle.
    private func tickFire() -> Bool {
        let now = Date()
        // Clamp dt: a suspension or a stopped-engine stall must not teleport playheads to
        // end-of-track (which would fire an instant overdue transition on resume).
        let dt = min(lastTickAt.map { now.timeIntervalSince($0) } ?? 0, 0.5)
        lastTickAt = now
        let rendering = built && engine.isRunning
        if lastRenderingDiag != rendering {
            dlog("render \(lastRenderingDiag.map(String.init) ?? "nil")→\(rendering)")
            lastRenderingDiag = rendering
        }
        diagHeartbeat(rendering: rendering)
        if rendering {
            unparkEngineStall()      // engine came back via any path → shift the parked clocks
            if engineDownWhileLive { // …and re-prime: zombie nodes survive a bare play()
                engineDownWhileLive = false
                dlog("re-prime after engine comeback")
                resumePlayingDecks()
            }
            healParkedPlayers()      // macOS device switch: engine renders on, player nodes parked
            for d in Deck.allCases where state(d).isPlaying {
                let dur = duration(d)
                guard dur > 0 else {             // nothing / zero-length loaded — don't run the playhead forever
                    if !autoMixing { setPlaying(d, false); stopActiveNodes(d) }
                    continue
                }
                // LOOPING: the playhead folds back into the window instead of advancing to the
                // end, and the queue is topped up so the repeats never run dry.
                if let w = loopWindow(d) {
                    var p = position(d) + dt * state(d).rate
                    if p >= w.end { p = w.start + (p - w.start).truncatingRemainder(dividingBy: w.end - w.start) }
                    setPosition(d, p)
                    topUpLoop(d)
                    continue
                }
                let pos = min(position(d) + dt * state(d).rate, dur)   // source advances at rate× wall time
                setPosition(d, pos)
                if pos >= dur, !autoMixing { setPlaying(d, false); stopActiveNodes(d) }
            }
        } else if deckA.isPlaying || deckB.isPlaying || autoMixing {
            // WATCHDOG: the system stopped the engine (route change / missed interruption-.ended /
            // config change) while the mix thinks it's live — park the clocks and bring it back
            // (~1 try/s). Positions deliberately do NOT advance: nothing is rendering, and a
            // recording's content clock is frozen with the tap. The parked-state policy (a
            // remote/interruption ⏸ stays silent unless a deck was hand-started) lives in
            // `recoverFromEngineStop`.
            engineDownWhileLive = true
            recoverFromEngineStop()
        }
        refreshTransport()
        // ~1 Hz STEADY-STATE CARD REFRESH — the third engine path to learn the same CarPlay
        // lesson (PlayerEngine's local observer and its external ticker both have it): the card's
        // elapsed/rate were written only at discrete transport events on the assumption that "the
        // system interpolates between", and a head unit that doesn't extrapolate showed a frozen
        // slider for the entire mix. Rewrite once a second while a deck is audibly playing —
        // never while paused (that would fight card scrubbing); `updateSystemNowPlaying` is
        // arbiter-, restore- and loaded-guarded, its command enablement is diffed, and its art
        // fetch is memoized by song id, so the periodic call is cheap and stomp-proof. This also
        // keeps the scrubber's speed honest after a tempo change, which previously never rewrote
        // the card's PlaybackRate at all.
        if rendering, deckA.isPlaying || deckB.isPlaying,
           lastCardRefresh.map({ now.timeIntervalSince($0) >= 1 }) ?? true {
            lastCardRefresh = now
            updateSystemNowPlaying()
        }
        if autoMixing, rendering { autoFire() }
        // Playhead refresh into the durable session (~10 Hz call, throttled to ~5 s writes
        // while running inside the store; steady paused state writes nothing).
        persistMixPositions()
        let active = deckA.isPlaying || deckB.isPlaying || autoMixing
        if !active { tickTask = nil; return false }
        return true
    }

    /// One `mixdiag` line per second while anything plays: the full liveness picture — engine
    /// state vs render-callback age vs signal age vs per-deck intent/node/position — so a silent
    /// failure in the field shows exactly WHICH layer died (engine stopped / callbacks stopped /
    /// rendering zeros / node parked).
    private func diagHeartbeat(rendering: Bool) {
        let now = Date()
        guard lastDiagHeartbeat.map({ now.timeIntervalSince($0) >= 1 }) ?? true else { return }
        lastDiagHeartbeat = now
        let t = now.timeIntervalSinceReferenceDate
        let tapAge = tapPulse.lastTapAt == 0 ? -1 : t - tapPulse.lastTapAt
        let audibleAge = tapPulse.lastAudibleAt == 0 ? -1 : t - tapPulse.lastAudibleAt
        let outHz = Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)
        func deck(_ d: Deck) -> String {
            let intent = state(d).isPlaying ? 1 : 0
            let node = (players[d]?.isPlaying ?? false) ? 1 : 0
            return "(\(intent),\(node),\(String(format: "%.1f", position(d))))"
        }
        dlog("hb render=\(rendering ? 1 : 0) run=\(engine.isRunning ? 1 : 0)"
             + " tapAge=\(String(format: "%.2f", tapAge)) sigAge=\(String(format: "%.2f", audibleAge))"
             + " A=\(deck(.a)) B=\(deck(.b)) out=\(outHz)Hz rec=\(isRecording ? 1 : 0)"
             + " stall=\(engineStallAt != nil ? 1 : 0) rp=\(remotePausedAt != nil ? 1 : 0) auto=\(autoMixing ? 1 : 0)/\(autoPaused ? 1 : 0)")
    }

    /// Bring a system-stopped engine back and resume the decks that were playing. Called from the
    /// route/config-change observers and the tick watchdog; safe to call any time (no-ops when the
    /// engine is running or nothing wants audio). A failed start stays parked — `engineStallAt`
    /// freezes the auto-machine clocks so a stall never burns a track's runway, and the tick keeps
    /// retrying about once a second until the session comes back.
    private func recoverFromEngineStop() {
        guard built else { return }
        // Deliberately parked with SILENT decks (lock-screen ⏸ / interruption .began): restarting
        // the engine would render real silence at full rate into an open take — only an explicit
        // resume unparks. But a deck the user HAND-STARTED during the park (autoPaused
        // hand-mixing) is meant to be audible, so it keeps full recovery.
        let anyDeckPlaying = deckA.isPlaying || deckB.isPlaying
        guard remotePausedAt == nil || anyDeckPlaying else {
            dlog("recover: parked (rp set, decks silent) — no restart")
            return
        }
        // Engine survived (or auto-recovered — macOS does this on some device switches) but the
        // PLAYER nodes may have been parked by the reconfigure: silence renders into the house
        // sum (and an open take) while everything claims to be live. Re-kick them.
        //
        // UNCONDITIONAL re-prime (`resumePlayingDecks`, not the cheap `healParkedPlayers`): this
        // branch only runs off a genuine route/config-change NOTIFICATION (never every tick — the
        // tick's own per-frame safety net stays on `healParkedPlayers`), and `isPlaying` is exactly
        // the signal `handleEngineConfigurationChange`'s own comment warns can lie ("playing nodes
        // may be zombies") — `healParkedPlayers`'s `!p.isPlaying` gate trusted that lie and would
        // silently skip re-priming a node that claims to be playing but isn't actually rendering.
        // Bounded cost: one pause+play blip per real recovery event, not per tick.
        if engine.isRunning {
            unparkEngineStall()
            let rearmedBefore = deckRescheduleCountForTesting
            resumePlayingDecks()
            DiagLog.shared.log("mix", "recover: engine survived — re-primed A=\(deckA.isPlaying ? 1 : 0) "
                + "B=\(deckB.isPlaying ? 1 : 0) rearmed=\(deckRescheduleCountForTesting > rearmedBefore ? 1 : 0)")
            return
        }
        guard anyDeckPlaying || autoMixing else { return }
        // While remote-frozen the auto clocks are ALREADY parked — a stall park stacked on top
        // would shift them twice on resume. Recover the audio without the stall bookkeeping.
        if remotePausedAt == nil, engineStallAt == nil {
            engineStallAt = Date()
            dlog("recover: engine down — stall parked")
        }
        if let last = lastEngineRecoveryAttempt, Date().timeIntervalSince(last) < 0.9 { return }
        lastEngineRecoveryAttempt = Date()
        let ok = startEngineIfNeeded()
        dlog("recover: engine.start → \(ok ? "OK" : "FAILED")")
        guard ok else {
            DiagLog.shared.log("mix", "recover: engine restart FAILED")
            return
        }
        unparkEngineStall()
        resumePlayingDecks()             // re-primes (pause+play) — a bare play() no-ops on zombies
        engineDownWhileLive = false      // re-primed here; the tick needn't do it again
        DiagLog.shared.log("mix", "recover: engine restarted — re-primed A=\(deckA.isPlaying ? 1 : 0) "
            + "B=\(deckB.isPlaying ? 1 : 0)")
    }

    /// Shift every armed auto-machine timestamp past the stall (mirrors `unfreezeAutoClock`) so
    /// the machine resumes where the engine died instead of firing a burst of overdue transitions.
    private func unparkEngineStall() {
        guard let stalledAt = engineStallAt else { return }
        engineStallAt = nil
        let delta = Date().timeIntervalSince(stalledAt)
        guard delta > 0 else { return }
        autoPrerollStartedAt = autoPrerollStartedAt?.addingTimeInterval(delta)
        autoFadeStartedAt = autoFadeStartedAt?.addingTimeInterval(delta)
        autoPostrollStartedAt = autoPostrollStartedAt?.addingTimeInterval(delta)
        for (d, t) in autoDeckEndsAt { autoDeckEndsAt[d] = t.addingTimeInterval(delta) }
    }

    /// Re-base an in-progress stall: shift the already-armed clocks by the stall-so-far and park
    /// again from NOW. Call before stamping a fresh auto-machine timestamp mid-stall — the fresh
    /// stamp must be shifted only by the stall time that FOLLOWS it, not the whole stall.
    private func checkpointEngineStall() {
        guard engineStallAt != nil else { return }
        unparkEngineStall()
        engineStallAt = Date()
    }

    /// The DynamicsProcessor (compressor) component description — Apple's built-in AU.
    private static let dynamicsDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)

    /// The PeakLimiter (master safety net) component description — Apple's built-in AU.
    private static let limiterDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)

    #if canImport(UIKit) && !os(macOS)
    private func activateAudioSession() {
        // Studio mic capture holds the shared session at .playAndRecord — re-arming .playback
        // here would tear the live input tap's route out from under the recorder mid-take
        // (spec §4 coexistence rule); playback works fine under .playAndRecord, so skip.
        guard !AudioSessionPolicy.micCaptureActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* non-fatal */ }
    }
    #endif

    #if os(iOS)

    /// Recover from an audio-session interruption (phone call / Siri / route loss).
    ///
    /// `.began`: the system already stopped the engine — SUSPEND the mix exactly like a lock-screen
    /// ⏸ (`remotePause`: park the auto-machine clocks, remember the playing decks, silence). Without
    /// this the wall-clock machine keeps arming and drives a transition into the dead engine — the
    /// uncatchable play()-on-stopped-engine crash — and a recording keeps "running" over dead air.
    ///
    /// `.ended`: resume what the ⏸ recorded when iOS says `.shouldResume` (`remotePlay` restarts the
    /// engine via the guarded path and un-parks the clocks). When iOS says DON'T auto-resume, stay
    /// parked with the engine stopped: restarting it with silent decks would append real silence at
    /// full rate into an open take. Lock-screen ▶ / in-app play resumes manually — and Apple
    /// documents `.ended` itself is not guaranteed, which is why the tick watchdog exists.
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
                    // LATCH (never assign): a duplicate .began delivered over the already-parked
                    // mix (Bluetooth/CarPlay re-sends) must not erase the pairing record.
                    if self.isRunning { self.interruptionParked = true }
                    self.remotePause()
                case .ended:
                    let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
                    guard shouldResume else { return }   // stay parked — no silence into an open take
                    // Resume ONLY what .began itself silenced, and only while it is still parked:
                    // an unconditional remotePlay would replay a stale in-app pause memory or start
                    // a loaded-but-never-played deck via the now-playing fallback.
                    guard self.interruptionParked, !self.isRunning else { return }
                    self.interruptionParked = false
                    self.remotePlay()
                @unknown default:
                    break
                }
            }
        }
    }

    /// A route CHANGE (headphones ⇄ speaker ⇄ Bluetooth) can stop the engine WITHOUT any
    /// interruption — the reported crash scenario. Recover immediately instead of waiting for the
    /// tick watchdog, so an active recording misses as little as possible. `recoverFromEngineStop`
    /// no-ops when the engine kept running (same-format route swaps).
    private func registerRouteChangeHandling() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromEngineStop() }
        }
    }

    /// mediaserverd crashed: every engine/node/tap in this process is orphaned and must be
    /// RECREATED (Apple's contract for `mediaServicesWereReset`) — without this, `built` stays true
    /// forever, the graph is dead for the life of the process, and an active capture freezes with
    /// `isRecording` stuck on.
    private func registerMediaResetHandling() {
        guard mediaResetObserver == nil else { return }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterMediaReset() }
        }
    }

    /// Rebuild the whole graph after a media-services reset. File any in-flight take FIRST (the
    /// writer is not CoreAudio-backed and can still finalize its fragments), then recreate the
    /// engine + every node. Decks come back loaded-but-paused at their positions — restarting
    /// playback after a daemon crash is the user's call; what matters is the capture files cleanly
    /// and the Mix tab isn't dead until relaunch.
    private func rebuildAfterMediaReset() {
        guard built else { return }
        onRecordingFailed?()                   // recorder auto-stops + files the partial take
        if isRecording { stopRecording() }     // recorder not wired (tests) → still finalize + drop scope
        endAutoLoop()
        pauseBoth()
        tickTask?.cancel(); tickTask = nil
        modTask?.cancel(); modTask = nil
        unwireStems(.a); unwireStems(.b)
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
        engine.stop()
        engine = AVAudioEngine()               // the orphaned graph is unusable — recreate everything
        built = false
        engineStallAt = nil
        ensureEngine()                         // fresh graph + tap; re-pushes the UI's rates/effects/gains
        // Re-open + re-schedule each deck's file at its position, paused. The old `AVAudioFile`
        // objects are orphaned with the daemon — reopen from the stored path.
        for d in Deck.allCases {
            guard let path = paths[d], files[d] != nil else { continue }
            if let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) { files[d] = f }
            seek(d, toSeconds: position(d))
        }
    }
    #endif

    /// The system stopped + uninitialized the engine because its I/O configuration changed — the
    /// headphones→speaker sample-rate flip of the reported crash. Restart and resume: the graph's
    /// internal connections are all pinned at the canonical format (the output node re-negotiates
    /// the hardware rate on start), so no re-wiring is needed — the whole failure mode was that
    /// NOBODY restarted the engine while the wall-clock machine kept driving into it.
    private func registerConfigChangeHandling() {
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o) }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEngineConfigurationChange() }
        }
    }

    private func handleEngineConfigurationChange() {
        dlog("CONFIG CHANGE: run=\(engine.isRunning ? 1 : 0)"
             + " nodeA=\((players[.a]?.isPlaying ?? false) ? 1 : 0)"
             + " nodeB=\((players[.b]?.isPlaying ?? false) ? 1 : 0)"
             + " out=\(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate))Hz")
        // A config change means the engine WAS stopped/reconfigured — even if it (or the
        // watchdog) already restarted it between ticks, playing nodes may be zombies. And the
        // uninit can DROP never-rendered schedules outright (the tvOS silent-resume field bug):
        // mark every deck's schedule untrusted so the recovery re-ARMS from the tracked
        // positions instead of bare-replaying empty queues.
        fileScheduled = [:]
        stemsScheduled = [:]
        engineDownWhileLive = true
        recoverFromEngineStop()
    }
}

// MARK: - Recording tap sink

/// The PERSISTENT recording sink behind the always-installed `houseSum` tap. It encodes to a
/// FRAGMENTED AAC `.m4a` via `AVAssetWriter` (a `moof` fragment flushed every couple of seconds), so a
/// take is CRASH- / disk-out-SAFE — everything up to the last flushed fragment survives an app kill or
/// a full disk, without the ~10× on-disk cost of raw PCM. Writes are serialized onto a private queue
/// so the realtime tap thread never blocks on AAC encoding, and recording is toggled by `begin`/`end`
/// (a flag) rather than installing/removing the tap — so start/stop never reconfigures the live graph.
///
/// `@unchecked Sendable`: the writer state is touched ONLY on `queue`; `isCapturing` is a plain aligned
/// `Bool` (realtime tap reads it, main writes it) where the only race — a start/stop landing between
/// two buffers — drops at most one buffer, which is harmless.
final class MixTapSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pocketdj.mix.recording")
    // Queue-confined writer state:
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    /// The writer failed PERMANENTLY (startWriting refused / status left `.writing`). Latched for
    /// the take: `startWriting` must NEVER be retried on a failed writer — the second call raises
    /// an uncatchable `NSInternalInconsistencyException` one tap-buffer (~93 ms) later.
    private var failed = false
    private var reportedFailure = false
    private var nextPTS: CMTime = .zero
    private var isCapturing = false         // realtime-readable

    /// One-shot (per take) permanent-failure callback — fired ON THE SINK QUEUE with
    /// `writer.error`. The engine hops it to the main actor.
    var onWriterFailure: ((Error?) -> Void)?

    /// Media seconds appended to the current take — the CONTENT clock, readable from any thread
    /// (the recorder's duration metadata + liveness watchdog read it from the main actor).
    private let appendedLock = NSLock()
    private var appendedSecondsValue: Double = 0
    var appendedSeconds: Double {
        appendedLock.lock(); defer { appendedLock.unlock() }
        return appendedSecondsValue
    }
    private func setAppendedSeconds(_ v: Double) {
        appendedLock.lock(); appendedSecondsValue = v; appendedLock.unlock()
    }

    /// Begin a fragmented-AAC capture at `url`. Returns false if the writer can't be created.
    func begin(url: URL, sampleRate: Double, channels: AVAudioChannelCount) -> Bool {
        try? FileManager.default.removeItem(at: url)          // AVAssetWriter refuses an existing file
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return false }
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)   // crash-safe: flush ~every 2 s
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ]
        let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        guard w.canAdd(inp) else { return false }
        w.add(inp)
        queue.async {
            self.writer = w; self.input = inp; self.started = false
            self.failed = false; self.reportedFailure = false
            self.nextPTS = .zero
            // Zero the mirror ON THE QUEUE: a previous take's final append can still be pending
            // ahead of us and would overwrite a caller-thread reset with the OLD take's total.
            self.setAppendedSeconds(0)
        }
        isCapturing = true
        return true
    }

    /// Stop capturing immediately, then finalize (fragments already make it playable pre-finish).
    /// `completion` fires (on the sink queue) once the finalize has COMPLETED — the caller holds
    /// the session folder's security scope open until then.
    func end(_ completion: (() -> Void)? = nil) {
        isCapturing = false
        queue.async {
            guard let w = self.writer, let inp = self.input else { self.reset(); completion?(); return }
            self.reset()
            if w.status == .writing {
                inp.markAsFinished()
                w.finishWriting { [w] in _ = w; completion?() }   // `w` lives until finalize COMPLETES
            } else {
                completion?()   // failed/never-started writer: `finishWriting` would throw — the
                                // flushed fragments (if any) are durable without it
            }
        }
    }

    private func reset() {
        writer = nil; input = nil; started = false; nextPTS = .zero
        failed = false; reportedFailure = false
    }

    /// Queue-confined: latch the take as dead and surface it ONCE. Every later buffer is a cheap
    /// no-op — the alternative (silently dropping forever while the UI pulses "recording") was the
    /// unbounded-loss hole.
    private func fail(_ w: AVAssetWriter?) {
        failed = true
        guard !reportedFailure else { return }
        reportedFailure = true
        onWriterFailure?(w?.error)
    }

    /// Realtime tap entry (fires continuously): while capturing, copy the transient buffer + enqueue
    /// the encode/append off the realtime thread. Otherwise an immediate return (one flag check).
    func write(_ buffer: AVAudioPCMBuffer) {
        guard isCapturing, let copy = buffer.deepCopy() else { return }
        queue.async {
            guard let w = self.writer, let inp = self.input, !self.failed else { return }
            if !self.started {                                // lazily start on the first buffer
                guard w.startWriting() else { self.fail(w); return }   // NEVER retried — see `failed`
                w.startSession(atSourceTime: .zero)
                self.started = true; self.nextPTS = .zero
            }
            guard w.status == .writing else { self.fail(w); return }   // writer died mid-take → surface it
            guard inp.isReadyForMoreMediaData,
                  let sb = Self.sampleBuffer(from: copy, pts: self.nextPTS) else { return }   // transient: drop one buffer
            if inp.append(sb) {
                self.nextPTS = CMTimeAdd(self.nextPTS,
                    CMTime(value: CMTimeValue(copy.frameLength), timescale: CMTimeScale(copy.format.sampleRate)))
                self.setAppendedSeconds(CMTimeGetSeconds(self.nextPTS))
            } else if w.status != .writing {
                self.fail(w)                                   // append refused because the writer failed
            }
        }
    }

    /// Wrap a PCM buffer as a `CMSampleBuffer` (16-byte-aligned COPY of the audio, so it outlives the
    /// transient tap buffer) with a monotonic presentation timestamp, for `AVAssetWriterInput.append`.
    private static func sampleBuffer(from pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        let fmtDesc = pcm.format.formatDescription
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmtDesc,
            sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard status == noErr, let buf = sb else { return nil }
        let set = CMSampleBufferSetDataBufferFromAudioBufferList(
            buf, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, bufferList: pcm.audioBufferList)
        return set == noErr ? buf : nil
    }
}

private extension AVAudioPCMBuffer {
    /// A standalone copy of this buffer's frames — the tap buffer is only valid during the callback, so
    /// deferring the write to another queue needs an owned copy. Handles the canonical float format
    /// (and int16/int32 defensively); nil if the buffer can't be allocated / has no channel data.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size) }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size) }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int32>.size) }
        } else {
            return nil
        }
        return copy
    }
}
