import Foundation
import Observation
import AVFoundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// Synchronized multi-stem player for the SongDetail stem-audition panel — the e2e test
/// harness for the Demucs stem feature (and the foundation for per-deck stems on the Mix tab).
///
/// Graph: 4× `AVAudioPlayerNode` (vocals/drums/bass/other) → `engine.mainMixerNode` → output.
/// All four are scheduled from the same song second (past any mp3 encoder priming — headerless
/// Demucs parts decode one 576-sample granule late) and started on ONE sample frame
/// (`StemSync.startTogether`; a shared HOST time lands them a few samples apart — a flam), so
/// they play sample-accurately in sync. Per-stem `node.volume` gives instant mute / solo with no
/// glitch.
///
/// Plays from LOCAL files only — the stems are BURNED to the app's offline store first (see
/// `BurnStore.burnStems`), never streamed. So once a song is auditioned, its stems play fully
/// offline (and this is the same local-file model the Mix tab's stem decks will use).
///
/// The displayed scrubber position is sampled off a monotonic host clock (not Observation),
/// mirroring `PlayerEngine.PlayerClock`, so the 4×/s ticks don't invalidate the control buttons.
@MainActor
@Observable
final class StemPlayer {
    static let stems = ["vocals", "drums", "bass", "other"]

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var nodes: [String: AVAudioPlayerNode] = [:]
    @ObservationIgnored private var files: [String: AVAudioFile] = [:]
    /// Held only if the stems live in a security-scoped (user-picked) folder; released on stop.
    @ObservationIgnored private var scopeRelease: (() -> Void)?
    /// Bumped on every stop/seek so a stale schedule-completion can't flip state after the fact.
    @ObservationIgnored private var generation = 0
    /// Encoder priming at the head of the loaded set (`StemSync.mp3PrimingFrames`).
    @ObservationIgnored private var prime: AVAudioFramePosition = 0

    /// Which song's stems are currently loaded (so the panel reloads when the song changes).
    private(set) var loadedSongId: String?
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    /// Stems explicitly muted by the user (independent of solo).
    private(set) var muted: Set<String> = []
    /// When non-nil, ONLY this stem is audible (the per-stem ▶ "play just this one").
    private(set) var soloed: String?
    private(set) var loadError: String?

    // Host-clock scrubber state (not observed → ticks don't re-lay-out the buttons).
    @ObservationIgnored private var playStartHost: Double = 0   // CACurrentMediaTime at position 0
    @ObservationIgnored private var pausedAt: Double = 0

    init() {
        for name in Self.stems {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            nodes[name] = node
        }
    }

    /// Current playback position in seconds (sampled, non-observable).
    var currentTime: Double {
        let t = isPlaying ? (CACurrentMediaTime() - playStartHost) : pausedAt
        return min(max(0, t), duration)
    }

    /// True once the stems are loaded + ready to play.
    var ready: Bool { loadedSongId != nil && !files.isEmpty }

    /// Effective audible state for a stem (drives the row's icon).
    func isAudible(_ name: String) -> Bool {
        if let s = soloed { return name == s }
        return !muted.contains(name)
    }

    // MARK: Load (LOCAL files — stems are burned to the offline store first)

    /// Load the 4 burned-on-disk stem files. `release` (optional) keeps a security-scoped folder
    /// open for the lifetime of playback (released on `stop`). Replaces any prior load.
    func load(songId: String, localURLs: [String: URL], release: (() -> Void)? = nil) {
        if loadedSongId == songId, !files.isEmpty { release?(); return }
        stop()
        loadedSongId = songId
        scopeRelease = release
        loadError = nil

        var newFiles: [String: AVAudioFile] = [:]
        for name in Self.stems {
            guard let url = localURLs[name] else { continue }
            if let f = try? AVAudioFile(forReading: url) { newFiles[name] = f }
        }
        files = newFiles
        prime = StemSync.setPrimingFrames(newFiles, order: Self.stems)
        duration = newFiles.values.map { StemSync.songSeconds($0, prime: prime) }.max() ?? 0
        muted = []; soloed = nil; pausedAt = 0
        if newFiles.isEmpty { loadError = "Couldn’t load stems" }
        for (name, file) in newFiles {
            if let node = nodes[name] { engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat) }
        }
        engine.prepare()
    }

    // MARK: Transport

    /// Play ALL stems from the start, in sync, every stem audible (the "Play All" button).
    func playAll() {
        muted = []; soloed = nil
        startSynced(from: 0)
    }

    /// Solo ONE stem (the per-stem ▶). Tapping the soloed stem again clears solo (back to the
    /// current mute set). Starts/continues playback.
    func solo(_ name: String) {
        soloed = (soloed == name) ? nil : name
        applyVolumes()
        if !isPlaying { startSynced(from: currentTime >= duration ? 0 : currentTime) }
    }

    /// Toggle a stem's mute (independent of solo; muting clears any solo so the toggles read true).
    func toggleMute(_ name: String) {
        soloed = nil
        if muted.contains(name) { muted.remove(name) } else { muted.insert(name) }
        applyVolumes()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { startSynced(from: currentTime >= duration ? 0 : currentTime) }
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), duration)
        if isPlaying { startSynced(from: target) } else { pausedAt = target }
    }

    private func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime
        for node in nodes.values { node.pause() }
        isPlaying = false
    }

    /// Schedule all loaded stems from `offset` and start them on ONE sample frame.
    private func startSynced(from offset: Double) {
        guard !files.isEmpty else { return }
        generation += 1
        let gen = generation
        let leadName = files["vocals"] != nil ? "vocals" : files.keys.sorted().first
        var started: [AVAudioPlayerNode] = []
        for (name, node) in nodes {
            guard let file = files[name] else { continue }
            node.stop()
            let startFrame = StemSync.frame(file, prime: prime, atSeconds: offset)
            let count = file.length - startFrame
            guard count > 0 else { continue }
            let isLead = (name == leadName)            // one node owns the end signal
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(count),
                                 at: nil) { [weak self] in
                guard isLead else { return }
                Task { @MainActor in self?.handlePlaybackEnded(gen) }
            }
            started.append(node)
        }
        guard !started.isEmpty else {                  // seek at/past EOF: nothing schedulable
            isPlaying = false; pausedAt = duration
            return
        }
        configureSession()
        if !engine.isRunning {
            do { try engine.start() } catch {          // play(at:) on a dead engine is uncatchable
                isPlaying = false; pausedAt = min(max(0, offset), duration)
                return
            }
        }
        applyVolumes()
        StemSync.startTogether(started, lead: 0.08)
        playStartHost = CACurrentMediaTime() - offset
        isPlaying = true
    }

    private func handlePlaybackEnded(_ gen: Int) {
        guard gen == generation, isPlaying else { return }   // ignore a stale (seeked/stopped) completion
        isPlaying = false
        pausedAt = 0
    }

    /// TEST PROBE: the render frame each loaded stem node started on — one value when in sync.
    func startFramesForTesting() -> [AVAudioFramePosition?] {
        Self.stems.compactMap { files[$0] != nil ? nodes[$0] : nil }.map { StemSync.startFrame(of: $0) }
    }

    private func applyVolumes() {
        for (name, node) in nodes { node.volume = isAudible(name) ? 1 : 0 }
    }

    /// Stop playback + release the engine/scope. Does NOT delete the burned stem files (they're
    /// the persistent offline cache). Called on panel close / song change.
    func stop() {
        generation += 1
        for node in nodes.values { node.stop() }
        if engine.isRunning { engine.stop() }
        files = [:]
        prime = 0
        scopeRelease?(); scopeRelease = nil
        isPlaying = false; pausedAt = 0; duration = 0
        muted = []; soloed = nil
        loadedSongId = nil
    }

    private func configureSession() {
        #if canImport(UIKit) && !os(macOS)
        // Studio mic capture holds the shared session at .playAndRecord — re-arming .playback
        // here would tear down the recorder's live input tap mid-take (spec §4 coexistence
        // rule); stem audition works fine under .playAndRecord, so skip.
        guard !AudioSessionPolicy.micCaptureActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* best-effort */ }
        #endif
    }
}
