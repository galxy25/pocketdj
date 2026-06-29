import Foundation
import Observation
import AVFoundation        // AVAudioEngine + nodes (iOS · iPad · Mac); AVAudioSession is iOS-only (guarded below)
import AudioToolbox        // DynamicsProcessor AU parameter ids + AudioUnitSetParameter

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
    }

    /// One entry in an Auto-Mix queue: a loadable track plus its known length (ms).
    struct AutoMixItem: Equatable {
        let loadable: MixLoadable
        let durationMs: Int
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
    /// deck's always-active filter EQ `globalGain`. A master peak limiter catches the resulting peaks.
    nonisolated static let volumeRange: ClosedRange<Double> = 0...2.0

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
        var compressor = false, reverb = false, flanger = false, filter = false
        var compStrength = 0.5, reverbStrength = 0.5, flangerStrength = 0.5, filterStrength = 0.5
        /// Stem mode: when on (and the track has burned stems), the deck plays its 4 stems through
        /// the SAME effect chain + crossfader, with per-stem mute + level. Reset on load.
        var stemMode = false
        var stemMuted: Set<String> = []
        var stemVol: [String: Double] = [:]   // per-stem 0…1 (absent ⇒ 1.0)

        func isEnabled(_ e: Effect) -> Bool {
            switch e {
            case .compressor: return compressor
            case .reverb:     return reverb
            case .flanger:    return flanger
            case .filter:     return filter
            }
        }
        mutating func set(_ e: Effect, _ on: Bool) {
            switch e {
            case .compressor: compressor = on
            case .reverb:     reverb = on
            case .flanger:    flanger = on
            case .filter:     filter = on
            }
        }
        func strength(_ e: Effect) -> Double {
            switch e {
            case .compressor: return compStrength
            case .reverb:     return reverbStrength
            case .flanger:    return flangerStrength
            case .filter:     return filterStrength
            }
        }
        mutating func setStrength(_ e: Effect, _ v: Double) {
            let c = min(max(v, 0), 1)
            switch e {
            case .compressor: compStrength = c
            case .reverb:     reverbStrength = c
            case .flanger:    flangerStrength = c
            case .filter:     filterStrength = c
            }
        }
    }

    private var deckA = DeckState()
    private var deckB = DeckState()
    /// True iff EITHER deck is playing — drives the bottom transport.
    private(set) var isRunning = false
    /// 0 = full A, 1 = full B. Equal-power; centered so both loaded decks are audible.
    private(set) var crossfader: Double = 0.5
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

    // MARK: Auto-Mix (auto-DJ) — observable

    private(set) var autoEnabled = false
    private(set) var autoMixing = false
    private(set) var autoStatus: String?

    // MARK: Private — graph

    @ObservationIgnored private let burns: BurnStore
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var built = false
    @ObservationIgnored private var players: [Deck: AVAudioPlayerNode] = [:]
    /// Per-deck normalizing mixer right after the player. `player → inputMixer` carries the FILE's
    /// format (mono/stereo, any sample rate) and is the ONLY link reconnected per load; everything
    /// downstream stays pinned at canonical stereo so the effect AUs never see a live channel/SR
    /// reconfiguration (which AVAudioEngine asserts-and-hard-crashes on). The mixer up/down-mixes
    /// and resamples each file into canonical.
    @ObservationIgnored private var inputMixers: [Deck: AVAudioMixerNode] = [:]
    @ObservationIgnored private var timePitches: [Deck: AVAudioUnitTimePitch] = [:]
    @ObservationIgnored private var reverbs: [Deck: AVAudioUnitReverb] = [:]
    @ObservationIgnored private var filters: [Deck: AVAudioUnitEQ] = [:]
    @ObservationIgnored private var flangers: [Deck: AVAudioUnitDelay] = [:]
    @ObservationIgnored private var comps: [Deck: AVAudioUnitEffect] = [:]
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
    #endif

    /// Single ~10 Hz driver: advances each playing deck's playhead AND steps the auto-mix crossfade.
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastTickAt: Date?

    // Auto-Mix machine (Date/wall-clock based; it only drives the public transport, independent of the
    // audio backend).
    @ObservationIgnored private var autoQueue: [AutoMixItem] = []
    @ObservationIgnored private var autoLivePos = 0
    @ObservationIgnored private var autoNextToLoad = 0
    @ObservationIgnored private var autoLiveDeck: Deck = .a
    @ObservationIgnored private var autoDeckEndsAt: [Deck: Date] = [:]
    @ObservationIgnored private var autoDeckDurationMs: [Deck: Int] = [:]
    @ObservationIgnored private var autoFadeStartedAt: Date?
    @ObservationIgnored private var autoFadeFrom: Deck = .a
    @ObservationIgnored private var autoLeadSeconds: Double = 15
    @ObservationIgnored private var autoFadeSeconds: Double = 3

    init(burns: BurnStore) { self.burns = burns }

    // MARK: - Session recording

    /// The mix-session log sink (the app's `MixSessionStore`). Weak so the engine never retains the
    /// app graph; nil ⇒ recording is a no-op (tests, before wiring).
    @ObservationIgnored weak var recorder: MixSessionRecorder?

    /// Emit one session event for a deck (or global) action, stamping the deck's loaded song + its
    /// current playhead. The store owns the timeline (t0/tMs), coalescing, and persistence.
    private func rec(_ kind: MixEventKind, _ deck: Deck? = nil, param: String? = nil,
                     value: Double? = nil, flag: Bool? = nil) {
        guard let recorder else { return }
        let l = deck.flatMap { state($0).loaded }
        let posMs = deck.map { Int(position($0) * 1000) }
        recorder.logEvent(kind, deck: deck?.rawValue, songId: l?.songId, title: l?.title,
                          artist: l?.artist, bpm: nil, camelot: nil, param: param,
                          value: value, flag: flag, posMs: posMs)
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
            rec(.play, deck)
            if let id = state(deck).loaded?.songId { recorder?.notePlayed(songId: id) }
        } else {
            rec(.pause, deck)
        }
    }

    // MARK: - Lifecycle

    /// Build the two-deck graph ON FIRST USE and start the engine. Idempotent.
    func ensureEngine() {
        guard !built else { return }
        #if os(iOS)
        activateAudioSession()
        registerInterruptionHandling()
        #endif
        let canonical = Self.canonicalFormat
        for d in Deck.allCases {
            let player = AVAudioPlayerNode()
            let inputMixer = AVAudioMixerNode()
            let tp = AVAudioUnitTimePitch()
            let comp = AVAudioUnitEffect(audioComponentDescription: Self.dynamicsDesc)
            let filter = AVAudioUnitEQ(numberOfBands: 1)
            let reverb = AVAudioUnitReverb()
            let flanger = AVAudioUnitDelay()
            reverb.loadFactoryPreset(.mediumHall)
            for n in [player, inputMixer, tp, comp, filter, reverb, flanger] as [AVAudioNode] { engine.attach(n) }
            // `player → inputMixer` carries the file's real format (set per load); the mixer converts
            // it into canonical stereo. The effect chain below it is pinned at canonical FOR LIFE, so
            // loading a mono / 48 kHz / odd file never reconfigures (and crashes) a live AU.
            engine.connect(player, to: inputMixer, format: canonical)
            connectChain(d, nodes: (inputMixer, tp, comp, filter, reverb, flanger))
            players[d] = player; inputMixers[d] = inputMixer; timePitches[d] = tp; comps[d] = comp
            filters[d] = filter; reverbs[d] = reverb; flangers[d] = flanger
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
        // Push whatever the UI already set, then derive gains.
        for d in Deck.allCases {
            applyRate(d); applyPitch(d)
            for e in Effect.allCases { applyEffect(e, on: d) }
        }
        applyMixGains()
        for d in Deck.allCases { applyBoost(d) }   // >unity boost (globalGain) AFTER effects set the filter EQ
    }

    func prepare() { ensureEngine() }

    func teardown() {
        endAutoLoop()
        tickTask?.cancel(); tickTask = nil
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
        #endif
    }

    // MARK: - Loading

    func load(songId: String, title: String, artist: String, bpm: Double?,
              camelot: String?, key: String?, albumId: String?, lengthMs: Int? = nil, on deck: Deck) {
        guard let handle = burns.localURLForPlaybackPreferringCut(forSong: songId) else { return }
        // A per-song CUT plays its whole file from 0:00; an analog shared-album fallback SEEKS to the
        // song's startMs AND bounds playback to the song's lengthMs window, so it stops at the song
        // boundary instead of bleeding into the next song on the side.
        let startMs = handle.isCut ? nil : burns.startMs(forSong: songId)
        let windowMs = handle.isCut ? nil : lengthMs
        let grid = burns.beatGrid(forSong: songId)
        loadFile(handle.url, release: handle.release, startMs: startMs, lengthMs: windowMs,
                 meta: LoadedTrack(songId: songId, title: title, artist: artist,
                                   bpm: bpm, camelot: camelot, key: key, albumId: albumId,
                                   gridBpm: grid?.bpm, firstDownbeatMs: grid?.firstDownbeatMs,
                                   steady: grid?.steady), on: deck)
    }

    /// Internal load seam (shared by the BurnStore path above AND the integration/stress tests):
    /// open `url`, reconnect only the player→inputMixer link at the file's format, schedule the
    /// `[startMs, startMs+lengthMs)` window (analog) or the whole file, and reset tempo/pitch/lead.
    /// `release` is the held security-scope closure (nil for app-storage / test files). On any early
    /// return it releases `release` (so a bad file never leaks a scope) and leaves the deck's current
    /// track untouched. A zero-frame window is rejected (scheduling it would be an uncatchable crash).
    func loadFile(_ url: URL, release: (() -> Void)?, startMs: Int?, lengthMs: Int? = nil,
                  meta: LoadedTrack, on deck: Deck) {
        ensureEngine()
        guard let player = players[deck], let inputMixer = inputMixers[deck] else { release?(); return }
        guard let file = try? AVAudioFile(forReading: url) else { release?(); return }   // unreadable / corrupt
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
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(count),
                               at: nil, completionHandler: nil)
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
        }
        unwireStems(deck)             // drop the prior track's stem files + scope
        setDuration(deck, Double(count) / sr)
        setPosition(deck, 0)
        applyRate(deck); applyPitch(deck)
        // Record the load with the track's musical attributes (bpm/camelot) so the corpus is
        // self-describing without a catalog join. tempo/pitch reset to default are implied by .load.
        if let recorder, let l = state(deck).loaded {
            recorder.logEvent(.load, deck: deck.rawValue, songId: l.songId, title: l.title,
                              artist: l.artist, bpm: l.bpm, camelot: l.camelot, param: nil,
                              value: nil, flag: nil, posMs: 0)
        }
    }

    // MARK: - Transport

    func play(_ deck: Deck) {
        guard state(deck).loaded != nil else { return }   // never run an empty deck's playhead
        ensureEngine()
        if !engine.isRunning { try? engine.start() }
        if stemActive(deck) { startStems(deck) } else { players[deck]?.play() }
        setPlaying(deck, true)
        refreshTransport()
        startTickIfNeeded()
    }

    func pause(_ deck: Deck) {
        if autoMixing { endAutoLoop() }     // a manual pause during Auto-DJ ends it (else the wall-clock resumes)
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
        ensureEngine()
        if !engine.isRunning { try? engine.start() }
        for d in Deck.allCases where state(d).loaded != nil {
            if stemActive(d) { startStems(d) } else { players[d]?.play() }
            setPlaying(d, true)
        }
        refreshTransport()
        startTickIfNeeded()
    }

    func pauseBoth() {
        if autoMixing { endAutoLoop() }     // a manual master-Pause during Auto-DJ ends it
        for d in Deck.allCases { pauseActiveNodes(d); setPlaying(d, false) }
        refreshTransport()
    }

    func toggleAll() { isRunning ? pauseBoth() : playBoth() }

    /// Return a deck to the BEGINNING (its window's start frame) and resume if it was playing.
    func restart(_ deck: Deck) {
        let was = state(deck).isPlaying
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
            setPosition(deck, 0)
            if was {
                if !engine.isRunning { try? engine.start() }   // recover if an interruption stopped the engine
                player.play(); setPlaying(deck, true)           // was already playing → no spurious event
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
            $0.compressor = false; $0.reverb = false; $0.flanger = false; $0.filter = false
            $0.compStrength = 0.5; $0.reverbStrength = 0.5; $0.flangerStrength = 0.5; $0.filterStrength = 0.5
            $0.stemMuted = []     // un-mute + re-level every stem (keeps stem mode itself)
            $0.stemVol = [:]
        }
        applyRate(deck); applyPitch(deck)
        for e in Effect.allCases { applyEffect(e, on: deck) }
        applyMixGains()
        applyBoost(deck)         // volume back to 100% → globalGain back to 0 dB
        restart(deck)            // rewind to the start (no-op if nothing is loaded)
        rec(.resetDeck, deck)    // ONE semantic event (not a burst of per-parameter resets)
    }

    /// Seek to an absolute SOURCE position (seconds from the song's start). Sample-accurate, bounded
    /// to the song's window so an analog fallback can't scrub past its slice into the next song.
    func seek(_ deck: Deck, toSeconds sec: Double) {
        let clamped = min(max(0, sec), duration(deck))
        let was = state(deck).isPlaying
        if stemActive(deck) {                              // stem mode: re-seek + re-sync the 4 stems
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
            setPosition(deck, clamped)
            if was, count > 0 {
                if !engine.isRunning { try? engine.start() }   // recover if an interruption stopped the engine
                player.play(); setPlaying(deck, true)           // was already playing → no spurious event
            }
        }
        refreshTransport()
        startTickIfNeeded()
        rec(.seek, deck, value: clamped)
    }

    // MARK: - Tempo / pitch / beat-match

    func setRate(_ rate: Double, on deck: Deck) {
        mutate(deck) { $0.rate = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound) }
        applyRate(deck)
        rec(.tempo, deck, value: state(deck).rate)
    }

    func setPitch(_ semitones: Double, on deck: Deck) {
        mutate(deck) { $0.pitch = min(max(semitones, Self.pitchRange.lowerBound), Self.pitchRange.upperBound) }
        applyPitch(deck)
        rec(.pitch, deck, value: state(deck).pitch)
    }

    /// Designate (or clear) the Lead deck for beat-matching. Tapping the current lead clears it.
    func setLead(_ deck: Deck) { leadDeck = (leadDeck == deck) ? nil : deck; rec(.lead, deck, flag: isLead(deck)) }
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
    }

    func setCrossfader(_ value: Double) {
        applyCrossfader(value)
        rec(.crossfader, nil, value: crossfader)
    }

    /// Non-recording crossfade apply. The auto-DJ internals use THIS so machine moves aren't logged as
    /// user `.crossfader` gestures (and a Manual→Auto→Manual toggle on an idle session stays empty —
    /// no phantom event that would materialize a junk "Session N" on Reset).
    private func applyCrossfader(_ value: Double) {
        crossfader = min(max(value, 0), 1)
        applyMixGains()       // crossfade only — NOT applyBoost (keeps globalGain off the fade path)
    }

    func setEffect(_ effect: Effect, enabled: Bool, on deck: Deck) {
        mutate(deck) { $0.set(effect, enabled) }
        applyEffect(effect, on: deck)
        rec(.effectToggle, deck, param: effect.rawValue, flag: enabled)
    }

    /// Per-deck per-effect STRENGTH (0…1) — the wet amount / cutoff / threshold the long-press popup
    /// dials in. Always stored; only audible while the effect is enabled.
    func setEffectStrength(_ effect: Effect, _ strength: Double, on deck: Deck) {
        mutate(deck) { $0.setStrength(effect, strength) }
        applyEffect(effect, on: deck)
        rec(.effectStrength, deck, param: effect.rawValue, value: state(deck).strength(effect))
    }

    // MARK: - Auto-Mix (auto-DJ)

    private static let autoFallbackDurationMs = 180_000

    func setAutoEnabled(_ on: Bool) {
        autoEnabled = on
        if !on { endAutoLoop() }
    }

    func startAutoMix(_ items: [AutoMixItem], shuffled: Bool, lead: Double, fade: Double) {
        guard !items.isEmpty else { return }
        ensureEngine()
        endAutoLoop()

        autoEnabled = true
        autoLeadSeconds = max(1, lead)
        autoFadeSeconds = max(0.2, fade)
        autoQueue = shuffled ? items.shuffled() : items
        autoLivePos = 0
        autoLiveDeck = .a
        autoFadeStartedAt = nil
        autoDeckEndsAt = [:]
        autoDeckDurationMs = [:]

        applyCrossfader(0)
        loadAuto(autoQueue[0], onto: .a)
        if autoQueue.count > 1 { loadAuto(autoQueue[1], onto: .b) }
        autoNextToLoad = min(2, autoQueue.count)

        let now = Date()
        autoDeckEndsAt[.a] = now.addingTimeInterval(Double(autoDeckDurationMs[.a] ?? Self.autoFallbackDurationMs) / 1000)
        autoMixing = true
        play(.a)
        startTickIfNeeded()
        refreshAutoStatus()
    }

    func stopAutoMix() {
        endAutoLoop()
        pauseBoth()
    }

    private func endAutoLoop() {
        let wasMixing = autoMixing
        autoFadeStartedAt = nil
        autoMixing = false
        autoStatus = nil
        // Recenter ONLY after a real auto-mix (it swept the fader to an extreme) — and non-recording,
        // so ending an auto-mix never injects a user `.crossfader` event. A bare Manual→Auto→Manual
        // toggle (wasMixing == false) leaves the fader where the user left it.
        if wasMixing { applyCrossfader(0.5) }
    }

    /// One auto-mix step (called from the unified tick while `autoMixing`).
    private func autoFire() {
        guard autoEnabled, autoMixing, isReady else { return }
        let now = Date()
        if let fadeStart = autoFadeStartedAt {
            let p = min(max(now.timeIntervalSince(fadeStart) / autoFadeSeconds, 0), 1)
            applyCrossfader(autoFadeFrom == .a ? p : 1 - p)
            if p >= 1 { finishAutoCrossfade() }
        } else {
            guard let endsAt = autoDeckEndsAt[autoLiveDeck] else { return }
            let secondsLeft = endsAt.timeIntervalSince(now)
            if autoLivePos + 1 < autoQueue.count {
                if secondsLeft <= autoLeadSeconds { beginAutoCrossfade(now: now) }
            } else if secondsLeft <= 0 {
                stopAutoMix()
            }
        }
        refreshAutoStatus()
    }

    private func beginAutoCrossfade(now: Date) {
        let to = other(autoLiveDeck)
        autoFadeFrom = autoLiveDeck
        autoFadeStartedAt = now
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
        autoLivePos += 1
        autoFadeStartedAt = nil
        if autoNextToLoad < autoQueue.count {
            loadAuto(autoQueue[autoNextToLoad], onto: from)
            autoNextToLoad += 1
        }
    }

    private func loadAuto(_ item: AutoMixItem, onto deck: Deck) {
        load(item.loadable, on: deck)
        autoDeckDurationMs[deck] = item.durationMs
    }

    private func refreshAutoStatus() {
        let s: String?
        if autoMixing {
            let detail = autoFadeStartedAt != nil ? "fading" : "Deck \(autoLiveDeck.rawValue)"
            s = "\(min(autoLivePos + 1, autoQueue.count)) / \(autoQueue.count) · \(detail)"
        } else { s = nil }
        if s != autoStatus { autoStatus = s }
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
            players[deck]?.stop()                    // silence the single mixed file
            mutate(deck) { $0.stemMode = true }
            rec(.stemMode, deck, flag: true)
            _ = scheduleStems(deck, fromSeconds: pos)
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
            if count > 0 {
                player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(count),
                                       at: nil, completionHandler: nil)
                if was { if !engine.isRunning { try? engine.start() }; player.play() }
            }
        }
        refreshTransport()
    }

    func toggleStemMute(_ name: String, on deck: Deck) {
        mutate(deck) { if $0.stemMuted.contains(name) { $0.stemMuted.remove(name) } else { $0.stemMuted.insert(name) } }
        applyStemGains(deck)
        rec(.stemMute, deck, param: name, flag: isStemMuted(name, on: deck))
    }

    func setStemVolume(_ name: String, _ v: Double, on deck: Deck) {
        mutate(deck) { $0.stemVol[name] = min(max(v, 0), 1) }
        applyStemGains(deck)
        rec(.stemVolume, deck, param: name, value: stemVolume(name, on: deck))
    }

    /// Resolve + open the deck track's 4 burned stem files and reconnect each stem node at the file's
    /// format (only that link; the chain stays canonical). Holds the burn-folder scope. Returns false
    /// when the track isn't stem-burned locally / a file won't open.
    private func wireStems(_ deck: Deck) -> Bool {
        guard built, let songId = state(deck).loaded?.songId, let inputMixer = inputMixers[deck],
              let resolved = burns.localStemURLs(forSong: songId) else { return false }
        var opened: [String: AVAudioFile] = [:]
        for (name, url) in resolved.urls {
            if let f = try? AVAudioFile(forReading: url) { opened[name] = f }
        }
        guard opened.count == Self.stemNames.count else { resolved.release?(); return false }
        for (name, file) in opened {
            guard let node = stemPlayers[deck]?[name] else { continue }
            node.stop()
            engine.connect(node, to: inputMixer, format: file.processingFormat)
        }
        stemReleases[deck]?()              // release a prior wiring's scope, hold the new one
        stemReleases[deck] = resolved.release
        stemFiles[deck] = opened
        return true
    }

    /// Tear down a deck's stem wiring (stop nodes, drop files, release the burn-folder scope).
    private func unwireStems(_ deck: Deck) {
        stopStemNodes(deck)
        stemFiles[deck] = nil
        stemReleases[deck]?(); stemReleases[deck] = nil
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
        return any
    }

    /// Start the deck's stem nodes at ONE shared host time → sample-accurate sync.
    private func startStems(_ deck: Deck) {
        if !engine.isRunning { try? engine.start() }
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.06))
        for n in (stemPlayers[deck] ?? [:]).values { n.play(at: when) }
    }

    private func stopStemNodes(_ deck: Deck) { for n in (stemPlayers[deck] ?? [:]).values { n.stop() } }

    /// Pause a deck's ACTIVE voices (the single file + any stems) keeping their scheduled position.
    private func pauseActiveNodes(_ deck: Deck) {
        players[deck]?.pause()
        for n in (stemPlayers[deck] ?? [:]).values { n.pause() }
    }

    /// Stop a deck's ACTIVE voices (resets their scheduled position).
    private func stopActiveNodes(_ deck: Deck) {
        players[deck]?.stop()
        for n in (stemPlayers[deck] ?? [:]).values { n.stop() }
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

    private func refreshTransport() { isRunning = deckA.isPlaying || deckB.isPlaying }

    /// Equal-power crossfade written onto each deck's player volume (× the deck's own volume trim).
    /// Also pushes the same deck gain onto the deck's stem nodes (so the crossfader + Vol move the
    /// whole stem mix), scaled per-stem and zeroed when muted.
    private func applyMixGains() {
        guard built else { return }
        players[.a]?.volume = deckGain(.a)
        players[.b]?.volume = deckGain(.b)
        applyStemGains(.a)
        applyStemGains(.b)
    }

    /// The deck's player gain = its own volume trim × the equal-power crossfade factor. The volume is
    /// CLAMPED to ≤1.0 here (the shared source for the player AND every stem node, both of whose
    /// `volume` is the documented 0…1) — the >unity boost (100%…200%) is added separately and only on
    /// the deck's filter EQ `globalGain` (see `applyBoost`), so it can't double-gain the stems.
    private func deckGain(_ deck: Deck) -> Float {
        let v = Float(crossfader)
        let cf = deck == .a ? cosf(.pi / 2 * v) : cosf(.pi / 2 * (1 - v))
        return Float(min(state(deck).volume, 1.0)) * cf
    }

    /// Apply the deck's >unity volume boost as the filter EQ's `globalGain`: 0 dB at ≤100%, up to
    /// +6 dB at 200%. The EQ sits downstream of the deck's `inputMixer`, so the boost lifts the main
    /// file AND the 4 stems uniformly. Driven ONLY by a volume change (build / `setVolume` /
    /// `resetDeck`) — never the crossfader path — so an equal-power fade doesn't re-write it.
    private func applyBoost(_ deck: Deck) {
        guard built else { return }
        filters[deck]?.globalGain = Float(20 * log10(max(state(deck).volume, 1.0)))
    }

    /// Push the deck gain onto each stem node, scaled by the stem's own volume and zeroed when muted.
    /// Harmless when not in stem mode (those nodes aren't scheduled → silent regardless).
    private func applyStemGains(_ deck: Deck) {
        guard let nodes = stemPlayers[deck] else { return }
        let g = deckGain(deck)
        let st = state(deck)
        for (name, node) in nodes {
            node.volume = st.stemMuted.contains(name) ? 0 : g * Float(st.stemVol[name] ?? 1.0)
        }
    }

    private func applyRate(_ deck: Deck) { timePitches[deck]?.rate = Float(state(deck).rate) }
    private func applyPitch(_ deck: Deck) { timePitches[deck]?.pitch = Float(state(deck).pitch * 100) } // cents

    /// Realize an effect's enabled-state + strength onto its AVAudioUnit.
    private func applyEffect(_ effect: Effect, on deck: Deck) {
        guard built else { return }
        let on = state(deck).isEnabled(effect)
        let s = Float(state(deck).strength(effect))
        switch effect {
        case .reverb:
            guard let n = reverbs[deck] else { return }
            n.wetDryMix = s * 100; n.bypass = !on
        case .filter:
            guard let n = filters[deck], let band = n.bands.first else { return }
            band.filterType = .resonantLowPass
            // Strength sweeps the cutoff log-down from ~18 kHz (subtle) to ~250 Hz (heavy).
            band.frequency = Float(18_000 * pow(250.0 / 18_000.0, Double(s)))
            band.bandwidth = 0.5
            band.bypass = !on
            // The EQ NODE stays active (band-bypass alone gates the filter EFFECT) so its
            // `globalGain` — which carries the deck's >unity volume boost (`applyBoost`) — keeps
            // applying even when the filter is off. At unity + filter-off it's a transparent passthrough.
            n.bypass = false
        case .flanger:
            guard let n = flangers[deck] else { return }
            n.delayTime = 0.004                 // ~4 ms comb (static; a true LFO flanger is future work)
            n.feedback = s * 60                 // %
            n.wetDryMix = s * 50                // %
            n.lowPassCutoff = 15_000
            n.bypass = !on
        case .compressor:
            guard let n = comps[deck] else { return }
            // Threshold drops 0 → −30 dB as strength rises (heavier compression); makeup gain rises
            // ~half that (0 → +15 dB) so engaging Comp adds density/punch instead of just dropping level.
            AudioUnitSetParameter(n.audioUnit, kDynamicsProcessorParam_Threshold,
                                  kAudioUnitScope_Global, 0, AudioUnitParameterValue(-30 * s), 0)
            AudioUnitSetParameter(n.audioUnit, kDynamicsProcessorParam_OverallGain,
                                  kAudioUnitScope_Global, 0, AudioUnitParameterValue(15 * s), 0)
            n.bypass = !on
        }
    }

    /// The fixed downstream format. The effect chain (inputMixer → … → mainMixer) is wired at this
    /// canonical stereo format ONCE and never reconnected, so no per-file load can reconfigure a live
    /// AU's channel count / sample rate (which AVAudioEngine asserts-and-crashes on).
    private static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// Connect a deck's effect chain at the fixed canonical format (inputMixer → timePitch → comp →
    /// filter → reverb → flanger → mainMixer). Called ONCE per deck at build; never reconnected.
    private func connectChain(_ deck: Deck,
                              nodes: (AVAudioMixerNode, AVAudioUnitTimePitch, AVAudioUnitEffect,
                                      AVAudioUnitEQ, AVAudioUnitReverb, AVAudioUnitDelay)) {
        let (inputMixer, tp, comp, filter, reverb, flanger) = nodes
        let fmt = Self.canonicalFormat
        engine.connect(inputMixer, to: tp, format: fmt)
        engine.connect(tp, to: comp, format: fmt)
        engine.connect(comp, to: filter, format: fmt)
        engine.connect(filter, to: reverb, format: fmt)
        engine.connect(reverb, to: flanger, format: fmt)
        engine.connect(flanger, to: engine.mainMixerNode, format: fmt)
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
        let dt = lastTickAt.map { now.timeIntervalSince($0) } ?? 0
        lastTickAt = now
        for d in Deck.allCases where state(d).isPlaying {
            let dur = duration(d)
            guard dur > 0 else {                 // nothing / zero-length loaded — don't run the playhead forever
                if !autoMixing { setPlaying(d, false); stopActiveNodes(d) }
                continue
            }
            let pos = min(position(d) + dt * state(d).rate, dur)   // source advances at rate× wall time
            setPosition(d, pos)
            if pos >= dur, !autoMixing { setPlaying(d, false); stopActiveNodes(d) }
        }
        refreshTransport()
        if autoMixing { autoFire() }
        let active = deckA.isPlaying || deckB.isPlaying || autoMixing
        if !active { tickTask = nil; return false }
        return true
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

    #if os(iOS)
    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* non-fatal */ }
    }

    /// Recover from an audio-session interruption (phone call / Siri / route loss). The system stops
    /// the engine and does NOT auto-restart it — so on `.ended` we reactivate, restart the engine, and
    /// resume whichever decks the UI still considers playing (otherwise the Mix tab goes silently dead
    /// and seek/transport produce no audio). Mirrors `PlayerEngine.configureInterruptionObserver`.
    private func registerInterruptionHandling() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.built,
                      let info = note.userInfo,
                      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
                try? AVAudioSession.sharedInstance().setActive(true)
                if !self.engine.isRunning { try? self.engine.start() }
                if shouldResume {
                    for d in Deck.allCases where self.state(d).isPlaying { self.players[d]?.play() }
                }
            }
        }
    }
    #endif
}
