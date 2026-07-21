import Foundation
import Observation
import AVFoundation
import AudioToolbox        // DynamicsProcessor AU parameter ids + AudioUnitSetParameter (compressor)
import QuartzCore
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
/// It ONLY works for a LOCAL file (a burned or studio track) — normal playback is a single `AVPlayer`
/// with no DSP surface, so `SetlistPlayer` hands the current track's audio off to this engine AT its
/// current position when the user first touches a mix control (`SetlistPlayer.engageMix`). The
/// control state is EPHEMERAL — it resets on every track change (`resetControls`), so nothing here is
/// ever persisted.
///
/// Reuses `MixEngine.Effect` / `MixEngine.rateRange` / `.pitchRange` / `.volumeRange` / `.stemNames`
/// so the Mix tab's control components (`DeckSlider` / `EffectButton`) bind straight to it.
@MainActor
@Observable
final class NowPlayingDSP {

    // MARK: Graph nodes (never observed — mutating the node graph must not invalidate the UI)

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let inputMixer = AVAudioMixerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private let comp = AVAudioUnitEffect(audioComponentDescription: NowPlayingDSP.dynamicsDesc)
    @ObservationIgnored private let filter = AVAudioUnitEQ(numberOfBands: 1)
    @ObservationIgnored private let reverb = AVAudioUnitReverb()
    @ObservationIgnored private let flanger = AVAudioUnitDelay()
    @ObservationIgnored private let masterLimiter = AVAudioUnitEffect(audioComponentDescription: NowPlayingDSP.limiterDesc)
    @ObservationIgnored private var stemNodes: [String: AVAudioPlayerNode] = [:]
    @ObservationIgnored private var built = false

    private let burns: BurnStore

    // MARK: Loaded-file state (non-observed — the schedule geometry, not UI)

    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var sampleRate: Double = 0
    /// The song's slice within the (possibly shared analog album) file.
    @ObservationIgnored private var segStartFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var segEndFrame: AVAudioFramePosition = 0
    /// Held security scopes for a user-folder burned file / stems (released on disengage).
    @ObservationIgnored private var fileRelease: (() -> Void)?
    @ObservationIgnored private var stemFiles: [String: AVAudioFile] = [:]
    @ObservationIgnored private var stemRelease: (() -> Void)?
    /// Bumped on every (re)schedule/stop so a stale completion can't flip state after the fact.
    @ObservationIgnored private var generation = 0

    // MARK: Host-clock scrubber (song-relative seconds; NOT observed → ~10 Hz ticks don't relayout)

    @ObservationIgnored private var playStartHost: Double = 0   // CACurrentMediaTime at song position 0
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
    var stemMode: Bool { _stemMode }
    func isStemMuted(_ name: String) -> Bool { _stemMuted.contains(name) }
    func stemVolume(_ name: String) -> Double { _stemVol[name] ?? 1.0 }

    /// Current song-relative position (seconds), sampled off the host clock (non-observable).
    var currentTime: Double {
        let t = isPlaying ? (CACurrentMediaTime() - playStartHost) : pausedAt
        return min(max(0, t), duration)
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

        fileRelease?()                                 // release a prior engage's scope
        fileRelease = release
        file = f
        sampleRate = sr
        segStartFrame = segStart
        segEndFrame = segStart + count
        duration = Double(count) / sr
        loadedSongId = songId
        stemsAvailable = songId.map { burns.stemsBurned(forSong: $0) } ?? false
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

    /// Hand the audio back: stop everything, release scopes, and RETURN the current SONG-RELATIVE
    /// position (seconds) so the caller can reload the AVPlayer there (`startMs + position`). Does NOT
    /// reset the control state — `resetControls()` is the separate ephemeral clear.
    @discardableResult
    func disengage() -> Double {
        let pos = currentTime
        generation += 1
        player.stop()
        for n in stemNodes.values { n.stop() }
        if engine.isRunning { engine.stop() }   // idle the graph so the AVPlayer owns audio alone
        file = nil
        stemFiles = [:]
        fileRelease?(); fileRelease = nil
        stemRelease?(); stemRelease = nil
        isPlaying = false
        isEngaged = false
        loadedSongId = nil
        stemsAvailable = false
        pausedAt = 0
        duration = 0
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
        player.pause()
        for n in stemNodes.values { n.pause() }
        isPlaying = false
    }

    func resume() {
        guard isEngaged, !isPlaying else { return }
        startAudio(fromSongSeconds: currentTime >= duration ? 0 : currentTime)
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

    /// Enter/leave stem mode. Returns FALSE (and stays in single-file mode) when the track has no
    /// burned stems — so the panel can degrade the stem sub-section independently while tempo/pitch/
    /// gain/effects keep working. Mirrors `MixEngine.setStemMode`.
    @discardableResult
    func setStemMode(_ on: Bool) -> Bool {
        guard isEngaged, built else { return false }
        let was = isPlaying
        let pos = currentTime
        if on {
            guard wireStems() else { return false }                       // no local stems → refuse
            guard scheduleStems(fromSongSeconds: min(pos, maxStemSeconds())) else { return false }
            player.stop()                                                 // only NOW silence the single file
            _stemMode = true
            applyStemGains()
            if was { startScheduled(stemMode: true, fromSongSeconds: pos) }
        } else {
            for n in stemNodes.values { n.stop() }
            _stemMode = false
            guard scheduleMain(fromSongSeconds: pos) else { return true }
            if was { startScheduled(stemMode: false, fromSongSeconds: pos) }
        }
        return true
    }

    func toggleStemMute(_ name: String) {
        if _stemMuted.contains(name) { _stemMuted.remove(name) } else { _stemMuted.insert(name) }
        applyStemGains()
    }

    func setStemVolume(_ name: String, _ v: Double) {
        _stemVol[name] = min(max(v, 0), 1)
        applyStemGains()
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
            node.volume = _stemMuted.contains(name) ? 0 : Float(_stemVol[name] ?? 1.0)
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
        guard let f = file, sampleRate > 0 else { return false }
        player.stop()
        let frame = min(max(segStartFrame, segStartFrame + AVAudioFramePosition(pos * sampleRate)), segEndFrame)
        let count = segEndFrame - frame
        guard count > 0 else { return false }
        let gen = generation
        player.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(count), at: nil) { [weak self] in
            Task { @MainActor in self?.handleReachedEnd(gen) }
        }
        return true
    }

    @discardableResult
    private func scheduleStems(fromSongSeconds pos: Double) -> Bool {
        guard !stemFiles.isEmpty else { return false }
        let gen = generation
        let lead = stemFiles["vocals"] != nil ? "vocals" : stemFiles.keys.sorted().first
        var any = false
        for (name, f) in stemFiles {
            guard let node = stemNodes[name] else { continue }
            node.stop()
            let sr = f.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(pos * sr)
            let count = f.length - startFrame
            guard count > 0 else { continue }
            let isLead = (name == lead)
            node.scheduleSegment(f, startingFrame: startFrame, frameCount: AVAudioFrameCount(count), at: nil) { [weak self] in
                guard isLead else { return }
                Task { @MainActor in self?.handleReachedEnd(gen) }
            }
            any = true
        }
        return any
    }

    /// Schedule + start playback from a song-relative position (single file OR stems).
    private func startAudio(fromSongSeconds pos: Double) {
        guard built, isEngaged else { return }
        generation += 1
        let scheduled: Bool = _stemMode ? scheduleStems(fromSongSeconds: min(pos, maxStemSeconds()))
                                        : scheduleMain(fromSongSeconds: pos)
        guard scheduled else { isPlaying = false; pausedAt = min(max(0, pos), duration); return }
        startScheduled(stemMode: _stemMode, fromSongSeconds: pos)
    }

    /// Start the already-scheduled voices at ONE shared host time (sample-synced stems).
    private func startScheduled(stemMode: Bool, fromSongSeconds pos: Double) {
        configureSession()
        guard startEngineIfNeeded() else { isPlaying = false; pausedAt = min(max(0, pos), duration); return }
        applyStemGains()
        let voices: [AVAudioPlayerNode] = stemMode
            ? MixEngine.stemNames.compactMap { stemFiles[$0] != nil ? stemNodes[$0] : nil }
            : [player]
        guard !voices.isEmpty else { isPlaying = false; pausedAt = min(max(0, pos), duration); return }
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.06))
        for n in voices { n.play(at: when) }
        playStartHost = CACurrentMediaTime() - pos
        pausedAt = pos
        isPlaying = true
    }

    private func handleReachedEnd(_ gen: Int) {
        guard gen == generation, isPlaying else { return }   // ignore a stale (reseeked/stopped) completion
        isPlaying = false
        pausedAt = duration
        onReachedEnd?()
    }

    /// Open the 4 burned stem files + reconnect each stem node at the file's format (only that link).
    /// Holds the burn-folder scope. False when the track isn't stem-burned locally / a file won't open.
    private func wireStems() -> Bool {
        guard built, let songId = loadedSongId, let resolved = burns.localStemURLs(forSong: songId) else { return false }
        var opened: [String: AVAudioFile] = [:]
        for (name, url) in resolved.urls {
            if let f = try? AVAudioFile(forReading: url) { opened[name] = f }
        }
        guard opened.count == MixEngine.stemNames.count else { resolved.release?(); return false }
        for (name, f) in opened {
            guard let node = stemNodes[name] else { continue }
            node.stop()
            engine.connect(node, to: inputMixer, format: f.processingFormat)
        }
        stemRelease?(); stemRelease = resolved.release
        stemFiles = opened
        return true
    }

    /// The longest song-relative position at which `scheduleStems` still gets real audio.
    private func maxStemSeconds() -> Double {
        guard !stemFiles.isEmpty else { return 0 }
        let m = stemFiles.values.map { Double($0.length) / $0.processingFormat.sampleRate }.min() ?? 0
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
