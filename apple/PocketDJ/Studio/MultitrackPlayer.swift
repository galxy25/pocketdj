import Foundation
import AVFoundation
import AudioToolbox
import Observation

/// Non-Observable playhead clock (the fast-clock-must-not-invalidate-SwiftUI doctrine —
/// `DemuxTimelineView`/`StudioMicLevels`). A `TimelineView(.periodic)` samples `currentSeconds`
/// each frame; because it is NOT an @Observable property, sampling it never re-runs the arranger's
/// body. Reads the shared start host-time set when the engine starts.
final class MultitrackClock: @unchecked Sendable {
    private var startHost: UInt64 = 0
    private var running = false

    func start(atHostTime host: UInt64) { startHost = host; running = true }
    func stop() { running = false }
    var isRunning: Bool { running }

    /// Seconds since the shared start (0 during the pre-roll, before `startHost`).
    var currentSeconds: Double {
        guard running, startHost > 0 else { return 0 }
        let now = mach_absolute_time()
        guard now > startHost else { return 0 }
        return AVAudioTime.seconds(forHostTime: now - startHost)
    }
}

/// The audio-thread render state for the arranger: the decoded clips (immutable after Play), the
/// LIVE per-track mix scalars + master-FX kernel (updated from the main thread; value-type reads on
/// the audio thread are benign under torn reads), a loop region, and a frame cursor. `render` mixes
/// every clip that overlaps the current window with its track's gain/pan, then runs the master-FX
/// kernel over the summed output — so live mix moves AND live master-FX knobs affect the audio
/// immediately, exactly like riding faders on a mixer. Pure buffer math, no allocation in the loop.
final class MultitrackRenderContext: @unchecked Sendable {
    struct Clip { let trackIndex: Int; let startFrame: Int; let frameLength: Int
                  let srcStart: Int   // in-file offset (frames) — the scissor-cut window start
                  let data: [UnsafeMutablePointer<Float>]; let srcChannels: Int }

    private let channels: Int
    private var clips: [Clip] = []
    private var retained: [AVAudioPCMBuffer] = []   // keep the decoded buffers (clip.data) alive
    private var trackCount = 0

    // Live per-track scalars (index = track index). Written from main, read on the audio thread.
    private var gain: [Float] = []      // linear, 0 when inaudible (mute / not-soloed)
    private var panL: [Float] = []
    private var panR: [Float] = []

    // Loop + cursor (cursor lives on the audio thread only).
    private var looping = false
    private var loopStart = 0
    private var loopEnd = 0
    private var cursor = 0
    private var renderedTotal = 0       // monotonic, drives the kernel's beat/LFO phase base

    // Master FX.
    let kernel = MasterFXKernel()
    private var fxActive = false

    private var outPtrs: [UnsafeMutablePointer<Float>?]   // reused per callback (no alloc)

    init(channels: Int) {
        self.channels = max(1, channels)
        outPtrs = Array(repeating: nil, count: self.channels)
    }

    /// Build the immutable clip set + initial cursor/loop from the decoded buffers (called on main
    /// before the engine starts).
    func load(clips: [Clip], retain: [AVAudioPCMBuffer], trackCount: Int,
              cursor: Int, looping: Bool, loopStart: Int, loopEnd: Int, sampleRate: Double) {
        self.clips = clips
        self.retained = retain
        self.trackCount = max(trackCount, 0)
        gain = Array(repeating: 0, count: self.trackCount)
        panL = Array(repeating: 1, count: self.trackCount)
        panR = Array(repeating: 1, count: self.trackCount)
        self.cursor = cursor
        // Anchor the FX phase base to the START frame (seek / loopStart) so the beat-synced Brazilian
        // bass pump lands on the arrangement's real beats after a seek, not offset from playback start.
        self.renderedTotal = cursor
        self.looping = looping
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        kernel.configure(sampleRate: sampleRate, channelCount: channels)
    }

    /// Live per-track mix (called from `applyMix`). Center-unity balance for pan.
    func setTrackMix(index: Int, gainLinear: Float, pan: Float) {
        guard index >= 0, index < trackCount else { return }
        gain[index] = gainLinear
        let p = min(1, max(-1, pan))
        panL[index] = p <= 0 ? 1 : 1 - p
        panR[index] = p >= 0 ? 1 : 1 + p
    }

    /// Live master FX (called from `applyMasterFX`).
    func setMasterFX(_ params: MasterFXParams) {
        kernel.update(params)
        fxActive = params.active
    }

    /// The audio-thread render: mix overlapping clips (loop-aware) then apply master FX in place.
    func render(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        let nCh = min(bufs.count, channels)
        guard nCh > 0, frames > 0 else { return }
        for c in 0..<nCh {
            let p = bufs[c].mData?.assumingMemoryBound(to: Float.self)
            outPtrs[c] = p
            if let p { memset(p, 0, frames * MemoryLayout<Float>.size) }
        }

        var written = 0
        var pos = cursor
        let hasLoop = looping && loopEnd > loopStart
        while written < frames {
            let chunk = hasLoop ? min(frames - written, max(1, loopEnd - pos)) : frames - written
            for clip in clips {
                let ti = clip.trackIndex
                guard ti < gain.count else { continue }
                let g = gain[ti]
                if g == 0 { continue }
                let cs = clip.startFrame, ce = cs + clip.frameLength
                let os = max(cs, pos), oe = min(ce, pos + chunk)
                if oe <= os { continue }
                let dstOff = written + (os - pos)
                let srcOff = os - cs
                let cnt = oe - os
                let gl = panL[ti] * g, gr = panR[ti] * g
                let base = clip.srcStart + srcOff
                for c in 0..<nCh {
                    guard let dst = outPtrs[c] else { continue }
                    let src = clip.data[min(c, clip.srcChannels - 1)]
                    let cg = c == 0 ? gl : gr
                    for i in 0..<cnt { dst[dstOff + i] += src[base + i] * cg }
                }
            }
            written += chunk
            pos += chunk
            if hasLoop && pos >= loopEnd { pos = loopStart }
        }
        cursor = pos

        if fxActive { kernel.processABL(abl, frames: frames, framePos: Double(renderedTotal)) }
        renderedTotal += frames
    }
}

/// Plays a `StudioArrangement`'s tracks in sync through ONE `AVAudioSourceNode` whose render block
/// mixes every clip (per-track gain/pan, loop- and seek-aware) and runs the shared `MasterFXKernel`
/// over the summed master — so per-track mix moves AND master-FX knobs affect the audio LIVE, and the
/// exact same kernel bakes a bounce (no reliance on a custom AudioUnit, which failed to instantiate
/// on device — the "only gain worked" bug). A fresh engine per Play; a non-Observable `MultitrackClock`
/// drives the playhead. View-scoped: `stop()` on tab exit.
@MainActor
@Observable
final class MultitrackPlayer {
    private(set) var isPlaying = false
    private(set) var playingArrangementId: String?
    /// The timeline ms playback STARTED from (a ruler seek) — the view adds it to the clock for the
    /// cursor position. Non-observed: set once per play(), read in the playhead's TimelineView.
    @ObservationIgnored private(set) var startOffsetMs = 0
    /// Sampled by the playhead's TimelineView (non-Observable — see `MultitrackClock`).
    @ObservationIgnored let clock = MultitrackClock()

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var source: AVAudioSourceNode?
    @ObservationIgnored private var context: MultitrackRenderContext?
    @ObservationIgnored private var trackIds: [String] = []
    /// Master-output recorder (record-to-master live): a tap on the LIMITER (the canonical-rate master
    /// bus — see `play`) writes to this CAF; the URL is handed to the caller (`consumeRecording`) to
    /// bake into a Master clip.
    @ObservationIgnored private var recordFile: AVAudioFile?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var recordTapped = false
    /// The node the record tap is installed on (the limiter) — held so `stop()` removes it from the
    /// SAME node it was added to (removing from the wrong node silently leaves the tap live).
    @ObservationIgnored private var recordTapNode: AVAudioNode?
    /// Bumped ONLY when a recording ends because playback reached its NATURAL end (auto-stop) — the
    /// view observes this to bake the take. A manual stop / a restart (seek, loop, re-record) does NOT
    /// bump it, so a transient stop() during a play() restart can't trigger a truncated bake.
    private(set) var recordingFinishedNonce = 0

    /// Apple's PeakLimiter — the master safety net so a boosted / effect-laden master can't hard-clip.
    private static let limiterDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?
    /// Bumped by every `stop()`; `play()` snapshots it after its own stop() and, after the async
    /// clip-decode gap, bails if it changed — so a stop() or a second concurrent play() during decode
    /// invalidates the in-flight load and at most one engine runs.
    @ObservationIgnored private var playGeneration = 0

    private var sampleRate: Double { StudioAudio.canonicalSampleRate }

    /// Decode + build the render context, wire `source → limiter → mainMixer`, and start. `fromMs`
    /// starts playback at a timeline offset (a ruler seek); ignored while looping (which starts the
    /// region). Returns false when there's nothing to play.
    @discardableResult
    func play(arrangement: StudioArrangement, store: StudioStore, fromMs: Int = 0,
              record: Bool = false, quantized: Bool = false) async -> Bool {
        stop()
        let gen = playGeneration
        // 1. Decode every clip to a canonical buffer off the main actor, tagged with its track index.
        let fmt = StudioAudio.canonicalFormat
        let channels = Int(fmt.channelCount)
        var clips: [MultitrackRenderContext.Clip] = []
        var retained: [AVAudioPCMBuffer] = []
        for (ti, track) in arrangement.tracks.enumerated() {
            for clip in track.clips {
                guard let url = store.clipFileURL(clip.fileName),
                      let buf = try? await StudioRender.shared.decodeBuffer(url: url),
                      buf.frameLength > 0, let ch = buf.floatChannelData else { continue }
                let srcCh = Int(buf.format.channelCount)
                let data = (0..<srcCh).map { ch[$0] }
                let startFrame = Int((Double(clip.startMs) / 1000 * sampleRate).rounded())
                // Honor the non-destructive scissor window: play only file frames
                // [srcStart, srcStart + frameLength), clamped to what the decoded buffer holds.
                let bufFrames = Int(buf.frameLength)
                let srcStart = max(0, min(bufFrames, Int((Double(clip.fileStartMs) / 1000 * sampleRate).rounded())))
                let avail = bufFrames - srcStart
                let durFrames = clip.durationMs > 0 ? Int((Double(clip.durationMs) / 1000 * sampleRate).rounded()) : avail
                let frameLength = max(0, min(avail, durFrames))
                guard frameLength > 0 else { continue }
                clips.append(.init(trackIndex: ti, startFrame: startFrame, frameLength: frameLength,
                                   srcStart: srcStart, data: data, srcChannels: srcCh))
                retained.append(buf)
            }
        }
        guard !clips.isEmpty else { return false }
        guard gen == playGeneration else { return false }   // stop-during-decode wins

        // 2. Loop / seek geometry.
        let looping = arrangement.loopEnabled && arrangement.loopEndMs > arrangement.loopStartMs
        let seekMs = max(0, min(fromMs, arrangement.lengthMs))
        let seekFrame = Int((Double(seekMs) / 1000 * sampleRate).rounded())
        let loopStart = Int((Double(arrangement.loopStartMs) / 1000 * sampleRate).rounded())
        let loopEnd = Int((Double(arrangement.loopEndMs) / 1000 * sampleRate).rounded())

        // 3. Build the render context + a single source node.
        let ctx = MultitrackRenderContext(channels: channels)
        ctx.load(clips: clips, retain: retained, trackCount: arrangement.tracks.count,
                 cursor: looping ? loopStart : seekFrame,
                 looping: looping, loopStart: loopStart, loopEnd: loopEnd, sampleRate: sampleRate)
        context = ctx
        trackIds = arrangement.tracks.map(\.id)
        startOffsetMs = looping ? 0 : seekMs

        engine = AVAudioEngine()
        let src = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl in
            ctx.render(abl, frames: Int(frameCount))
            return noErr
        }
        source = src
        let limiter = AVAudioUnitEffect(audioComponentDescription: Self.limiterDesc)
        engine.attach(src); engine.attach(limiter)
        engine.connect(src, to: limiter, format: fmt)
        engine.connect(limiter, to: engine.mainMixerNode, format: fmt)

        applyMix(arrangement.tracks)
        applyMasterFX(arrangement.masterFX, bpm: arrangement.bpm)

        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
        do { try engine.start() } catch { stop(); return false }

        // Record-to-master: install the tap AFTER the engine is running so the mixer reports its true
        // format (reading it before start yields the stale 44.1 kHz default — the original pitch bug).
        // Clean mode taps the canonical-rate limiter; Quantized (lo-fi) taps the hardware-rate mixer.
        if record { setupRecordTap(limiter: limiter, canonical: fmt, quantized: quantized) }

        clock.start(atHostTime: mach_absolute_time())
        isPlaying = true
        playingArrangementId = arrangement.id
        if !looping { scheduleAutoStop(lengthMs: max(0, arrangement.lengthMs - seekMs)) }
        return true
    }

    /// Install the record-to-master tap on the running engine. CLEAN mode taps the LIMITER at the
    /// canonical rate (`fmt`) — `src → limiter → mainMixer` are wired at 44.1 kHz, so the limiter's
    /// output already carries every master FX + master gain (kernel-applied, upstream) AND the limiter
    /// itself ("exactly what you hear") at a device-rate-independent rate that needs no resample on
    /// bake. QUANTIZED (lo-fi) mode taps the MAIN MIXER at its true post-start HARDWARE format (48 kHz
    /// on iPhone); the bake relabels those frames as 44.1 without resampling for the retro downpitch —
    /// faithfully the pre-fix behavior, now opt-in. The file is captured by value so the tap never
    /// touches @MainActor state.
    private func setupRecordTap(limiter: AVAudioNode, canonical fmt: AVAudioFormat, quantized: Bool) {
        // Discard any leftover unbaked partial from a previous restart (avoid a tmp CAF leak).
        if let old = recordingURL { try? FileManager.default.removeItem(at: old); recordingURL = nil }
        let node: AVAudioNode = quantized ? engine.mainMixerNode : limiter
        let tapFmt = quantized ? engine.mainMixerNode.outputFormat(forBus: 0) : fmt
        guard tapFmt.sampleRate > 0 else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracks-master-\(UUID().uuidString).caf")
        guard let file = try? AVAudioFile(forWriting: url, settings: tapFmt.settings) else { return }
        recordFile = file; recordingURL = url; recordTapped = true; recordTapNode = node
        node.installTap(onBus: 0, bufferSize: 4096, format: tapFmt) { buf, _ in
            try? file.write(from: buf)
        }
    }

    func stop() {
        playGeneration &+= 1
        autoStopTask?.cancel(); autoStopTask = nil
        if recordTapped { recordTapNode?.removeTap(onBus: 0); recordTapNode = nil; recordTapped = false }
        recordFile = nil            // release → the CAF finalizes; recordingURL kept for the caller
        if engine.isRunning { engine.stop() }
        source = nil
        context = nil
        trackIds = []
        clock.stop()
        isPlaying = false
        playingArrangementId = nil
    }

    /// True while a master recording tap is active.
    var isRecording: Bool { recordTapped }

    /// Hand the finished master recording's file URL to the caller (to bake into a Master clip) and
    /// clear it. Call after `stop()`.
    func consumeRecording() -> URL? {
        let url = recordingURL
        recordingURL = nil
        return url
    }

    /// Recompute each track's audible gain + pan from mute / solo / gain (solo wins) and push to the
    /// render context — takes effect on the next render callback. Safe to call live during playback.
    func applyMix(_ tracks: [StudioTrack]) {
        guard let ctx = context else { return }
        let anySolo = tracks.contains { $0.soloed }
        for track in tracks {
            // Match by track ID, not array position — a delete/duplicate mid-play shifts indices.
            guard let i = trackIds.firstIndex(of: track.id) else { continue }
            let audible = anySolo ? track.soloed : !track.muted
            let db = min(6.0, max(-24.0, track.gainDb))
            ctx.setTrackMix(index: i, gainLinear: audible ? Float(pow(10.0, db / 20.0)) : 0, pan: Float(track.pan))
        }
    }

    /// Push master-FX + master-gain to the render context — live. `allowFreeze:false` on the Tracks
    /// path (the grid has no Freezer; a persisted `freezeEnabled` must never silence the mix).
    func applyMasterFX(_ fx: StudioMasterFX, bpm: Double) {
        context?.setMasterFX(MasterFXParams(fx, bpm: bpm, allowFreeze: false))
    }

    private func scheduleAutoStop(lengthMs: Int) {
        autoStopTask?.cancel()
        let seconds = Double(max(0, lengthMs)) / 1000 + 0.35
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000) + 120_000_000)
            guard !Task.isCancelled, let self else { return }
            let wasRecording = self.recordTapped   // playback reached its natural end
            self.stop()
            if wasRecording { self.recordingFinishedNonce &+= 1 }   // → the view bakes the take
        }
    }
}
