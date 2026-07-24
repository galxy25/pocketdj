import Foundation
import AVFoundation
import AudioToolbox
import Observation

/// Non-Observable playhead clock (the fast-clock-must-not-invalidate-SwiftUI doctrine —
/// `DemuxTimelineView`/`StudioMicLevels`). A `TimelineView(.periodic)` samples `currentSeconds`
/// each frame; because it is NOT an @Observable property, sampling it never re-runs the arranger's
/// body. Reads the shared start host-time set at `play(at:)`.
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

/// Plays a `StudioArrangement`'s tracks in sync: one `AVAudioPlayerNode → gain(mixer) → mainMixer`
/// per track, each clip scheduled at its ms→frame offset on the node's own timeline, then EVERY
/// node started at ONE shared `AVAudioTime` (now + a short pre-roll) so their sample timelines
/// coincide — the sequencer's `restartPatternFromTop` / MixEngine stem-sync pattern. The graph is
/// rebuilt fresh on each Play (built while stopped, never a live attach). Mute / solo / per-track
/// gain map to each track's mixer volume and update live. View-scoped: `stop()` on tab exit.
@MainActor
@Observable
final class MultitrackPlayer {
    private(set) var isPlaying = false
    private(set) var playingArrangementId: String?
    /// Sampled by the playhead's TimelineView (non-Observable — see `MultitrackClock`).
    @ObservationIgnored let clock = MultitrackClock()

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var trackNodes: [(player: AVAudioPlayerNode, gain: AVAudioMixerNode)] = []
    @ObservationIgnored private var trackIds: [String] = []
    /// The summing bus every track feeds; the master-FX node + limiter sit between it and the main
    /// mixer. Rebuilt per Play with the rest of the graph.
    @ObservationIgnored private var masterSum = AVAudioMixerNode()
    /// The live master-FX AU (nil if instantiation failed → effects don't apply live but the chain
    /// still plays, and a bounce still bakes them). Params pushed via `applyMasterFX`.
    @ObservationIgnored private var masterFXAU: MasterFXAudioUnit?

    /// Apple's PeakLimiter — the master safety net so a boosted / effect-laden master can't hard-clip
    /// (mirrors MixEngine.limiterDesc).
    private static let limiterDesc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?
    /// Bumped by every `stop()`; `play()` snapshots it after its own stop() and, after the async
    /// clip-decode gap, bails if it changed — so a stop() (tab exit / record / bounce) or a second
    /// concurrent play() during decode invalidates the in-flight load and at most one engine runs.
    @ObservationIgnored private var playGeneration = 0

    private var sampleRate: Double { StudioAudio.canonicalSampleRate }

    /// A decoded clip tagged with its track index + timeline start frame (node time 0 = shared start).
    private struct Scheduled { let trackIndex: Int; let startFrame: AVAudioFramePosition; let buffer: AVAudioPCMBuffer }

    /// Build the graph, decode + schedule every clip, and start all track nodes at one host time.
    /// Returns false when there's nothing to play (no resolvable clips).
    @discardableResult
    func play(arrangement: StudioArrangement, store: StudioStore) async -> Bool {
        stop()
        let gen = playGeneration     // snapshot AFTER our own stop(); guarded across the decode gap
        // 1. Decode every clip to a canonical buffer (off-main via the render actor), tagged with
        //    its track index + start frame. A clip whose file can't resolve/decode is skipped.
        var scheduled: [Scheduled] = []
        for (ti, track) in arrangement.tracks.enumerated() {
            for clip in track.clips {
                guard let url = store.clipFileURL(clip.fileName),
                      let buf = try? await StudioRender.shared.decodeBuffer(url: url),
                      buf.frameLength > 0 else { continue }
                let startFrame = AVAudioFramePosition((Double(clip.startMs) / 1000 * sampleRate).rounded())
                scheduled.append(Scheduled(trackIndex: ti, startFrame: startFrame, buffer: buf))
            }
        }
        guard !scheduled.isEmpty else { return false }
        // A stop() (tab exit / record / bounce) or a newer play() intervened during the decode above
        // → bail before building an engine, so stop-during-load wins and only one engine ever runs.
        guard gen == playGeneration else { return false }

        // 2. Fresh graph: one player → gain(mixer) → masterSum per track, then the master chain
        //    masterSum → [MasterFX] → PeakLimiter → mainMixer (canonical throughout).
        engine = AVAudioEngine()
        trackNodes = []; trackIds = []; masterFXAU = nil
        let fmt = StudioAudio.canonicalFormat
        masterSum = AVAudioMixerNode()
        engine.attach(masterSum)
        for track in arrangement.tracks {
            let p = AVAudioPlayerNode(); let g = AVAudioMixerNode()
            engine.attach(p); engine.attach(g)
            engine.connect(p, to: g, format: fmt)
            engine.connect(g, to: masterSum, format: fmt)
            trackNodes.append((p, g)); trackIds.append(track.id)
        }
        // Master chain. The custom FX node is created async (Apple's AVAudioUnit contract); if the
        // load fails, route straight to the limiter so playback never depends on it.
        let limiter = AVAudioUnitEffect(audioComponentDescription: Self.limiterDesc)
        engine.attach(limiter)
        if let (fxNode, fxAU) = await MasterFXAudioUnit.make() {
            guard gen == playGeneration else { return false }   // stop() during the async instantiate
            engine.attach(fxNode)
            masterFXAU = fxAU
            engine.connect(masterSum, to: fxNode, format: fmt)
            engine.connect(fxNode, to: limiter, format: fmt)
        } else {
            engine.connect(masterSum, to: limiter, format: fmt)
        }
        engine.connect(limiter, to: engine.mainMixerNode, format: fmt)
        applyMix(arrangement.tracks)
        applyMasterFX(arrangement.masterFX, bpm: arrangement.bpm)

        // 3. Session (iOS/visionOS) + start the engine.
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
        do { try engine.start() } catch { stop(); return false }

        // 4. Schedule playback. Normal: each clip on its track's node at its frame offset. Looping:
        //    one per-track REGION buffer (that track's clips summed within [loopStart, loopEnd)),
        //    scheduled with `.loops` so the region repeats seamlessly forever. Node time 0 = the
        //    shared start either way, so the timelines coincide when all nodes start together.
        let looping = arrangement.loopEnabled && arrangement.loopEndMs > arrangement.loopStartMs
        if looping {
            let startFrame = AVAudioFramePosition((Double(arrangement.loopStartMs) / 1000 * sampleRate).rounded())
            let endFrame = AVAudioFramePosition((Double(arrangement.loopEndMs) / 1000 * sampleRate).rounded())
            for (ti, buf) in Self.regionBuffers(scheduled: scheduled, trackCount: trackNodes.count,
                                                startFrame: startFrame, endFrame: endFrame, format: fmt) {
                trackNodes[ti].player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
            }
        } else {
            for s in scheduled where s.trackIndex < trackNodes.count {
                trackNodes[s.trackIndex].player.scheduleBuffer(
                    s.buffer, at: AVAudioTime(sampleTime: s.startFrame, atRate: sampleRate),
                    options: [], completionHandler: nil)
            }
        }
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.12))
        for (p, _) in trackNodes { p.play(at: when) }
        clock.start(atHostTime: when.hostTime)
        isPlaying = true
        playingArrangementId = arrangement.id
        if !looping { scheduleAutoStop(lengthMs: arrangement.lengthMs) }   // a loop runs until stop()
        return true
    }

    /// Sum each track's clips that intersect `[startFrame, endFrame)` into one region-length buffer
    /// per track (windowed to the region), for `.loops` scheduling. Returns only tracks that have
    /// audio in the region. Pure buffer math — cheap for the short spans a loop region covers.
    private static func regionBuffers(scheduled: [Scheduled], trackCount: Int,
                                      startFrame: AVAudioFramePosition, endFrame: AVAudioFramePosition,
                                      format: AVAudioFormat) -> [(Int, AVAudioPCMBuffer)] {
        let regionFrames = Int(endFrame - startFrame)
        guard regionFrames > 0 else { return [] }
        let channels = Int(format.channelCount)
        var result: [(Int, AVAudioPCMBuffer)] = []
        for ti in 0..<trackCount {
            let clips = scheduled.filter { $0.trackIndex == ti }
            guard !clips.isEmpty,
                  let rb = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(regionFrames)),
                  let rd = rb.floatChannelData else { continue }
            rb.frameLength = AVAudioFrameCount(regionFrames)
            for ch in 0..<channels { memset(rd[ch], 0, regionFrames * MemoryLayout<Float>.size) }
            var contributed = false
            for s in clips {
                guard let sd = s.buffer.floatChannelData else { continue }
                let srcCh = Int(s.buffer.format.channelCount)
                let clipEnd = s.startFrame + AVAudioFramePosition(s.buffer.frameLength)
                let overlapStart = max(s.startFrame, startFrame)
                let overlapEnd = min(clipEnd, endFrame)
                guard overlapEnd > overlapStart else { continue }
                let dstOff = Int(overlapStart - startFrame)
                let srcOff = Int(overlapStart - s.startFrame)
                let count = Int(overlapEnd - overlapStart)
                for ch in 0..<channels {
                    let src = sd[min(ch, srcCh - 1)]; let dst = rd[ch]
                    for i in 0..<count { dst[dstOff + i] += src[srcOff + i] }
                }
                contributed = true
            }
            if contributed { result.append((ti, rb)) }
        }
        return result
    }

    func stop() {
        playGeneration &+= 1     // invalidate any in-flight play() still in its decode gap
        autoStopTask?.cancel(); autoStopTask = nil
        for (p, _) in trackNodes { p.stop() }
        if engine.isRunning { engine.stop() }
        trackNodes = []; trackIds = []
        clock.stop()
        isPlaying = false
        playingArrangementId = nil
    }

    /// Recompute each track's mixer volume from its mute / solo / gain — solo wins (only soloed
    /// tracks audible when any is soloed). Safe to call live during playback.
    func applyMix(_ tracks: [StudioTrack]) {
        let anySolo = tracks.contains { $0.soloed }
        for track in tracks {
            // Match by track ID, not array position — a delete/duplicate mid-play shifts indices, so
            // index-zipping would apply one track's mix to another's still-playing node.
            guard let i = trackIds.firstIndex(of: track.id) else { continue }
            let audible = anySolo ? track.soloed : !track.muted
            let db = min(6.0, max(-24.0, track.gainDb))
            trackNodes[i].gain.outputVolume = audible ? Float(pow(10.0, db / 20.0)) : 0
            // Stereo placement — AVAudioMixerNode has a native pan (-1…+1); updates live.
            trackNodes[i].gain.pan = Float(min(1, max(-1, track.pan)))
        }
    }

    /// Push master-FX + master-gain to the live chain (safe to call mid-play — the panel's knobs).
    /// With the FX node present, everything (incl. gain) runs in its kernel; without it (load
    /// failed) master gain falls back to the summing bus (attenuation reliable).
    func applyMasterFX(_ fx: StudioMasterFX, bpm: Double) {
        let params = MasterFXParams(fx, bpm: bpm)
        if let au = masterFXAU {
            au.kernel.update(params)
            masterSum.outputVolume = 1
        } else {
            masterSum.outputVolume = Float(max(0, min(1, params.masterGain)))
        }
    }

    private func scheduleAutoStop(lengthMs: Int) {
        autoStopTask?.cancel()
        let seconds = Double(max(0, lengthMs)) / 1000 + 0.35   // + a small tail past the last clip
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000) + 120_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
}
