import Foundation
import AVFoundation
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
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?

    private var sampleRate: Double { StudioAudio.canonicalSampleRate }

    /// Build the graph, decode + schedule every clip, and start all track nodes at one host time.
    /// Returns false when there's nothing to play (no resolvable clips).
    @discardableResult
    func play(arrangement: StudioArrangement, store: StudioStore) async -> Bool {
        stop()
        // 1. Decode every clip to a canonical buffer (off-main via the render actor), tagged with
        //    its track index + start frame. A clip whose file can't resolve/decode is skipped.
        struct Scheduled { let trackIndex: Int; let startFrame: AVAudioFramePosition; let buffer: AVAudioPCMBuffer }
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

        // 2. Fresh graph: one player → gain(mixer) → mainMixer per track (canonical throughout).
        engine = AVAudioEngine()
        trackNodes = []; trackIds = []
        let fmt = StudioAudio.canonicalFormat
        for track in arrangement.tracks {
            let p = AVAudioPlayerNode(); let g = AVAudioMixerNode()
            engine.attach(p); engine.attach(g)
            engine.connect(p, to: g, format: fmt)
            engine.connect(g, to: engine.mainMixerNode, format: fmt)
            trackNodes.append((p, g)); trackIds.append(track.id)
        }
        applyMix(arrangement.tracks)

        // 3. Session (iOS/visionOS) + start the engine.
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
        do { try engine.start() } catch { stop(); return false }

        // 4. Schedule each clip on its track's node at the clip's frame offset (node time 0 = the
        //    shared start), then start ALL nodes at one host time so the timelines coincide.
        for s in scheduled where s.trackIndex < trackNodes.count {
            trackNodes[s.trackIndex].player.scheduleBuffer(
                s.buffer, at: AVAudioTime(sampleTime: s.startFrame, atRate: sampleRate),
                options: [], completionHandler: nil)
        }
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.12))
        for (p, _) in trackNodes { p.play(at: when) }
        clock.start(atHostTime: when.hostTime)
        isPlaying = true
        playingArrangementId = arrangement.id
        scheduleAutoStop(lengthMs: arrangement.lengthMs)
        return true
    }

    func stop() {
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
        for (i, track) in tracks.enumerated() where i < trackNodes.count {
            let audible = anySolo ? track.soloed : !track.muted
            let db = min(6, max(-24, track.gainDb))
            trackNodes[i].gain.outputVolume = audible ? Float(pow(10.0, db / 20.0)) : 0
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
