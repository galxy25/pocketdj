import Foundation
import Observation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// A thin `AVPlayer` wrapper that the inline player binds to. AVPlayer plays HLS
/// (`.m3u8`) AND mp3 natively, so no third-party HLS library is needed.
///
/// `load(url:live:startMs:)` swaps the current item; `currentTime`/`duration`/
/// `isPlaying` are observed (a periodic time observer drives the scrubber). For an
/// analog (non-live) track it seeks to `startMs` once the item is ready. A live HLS
/// stream is started immediately and never seeks (no static duration to scrub).
@MainActor
@Observable
final class PlayerEngine {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var isLive: Bool = false

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    /// The seek target (ms) to apply once the current item becomes ready (analog only).
    private var pendingSeekMs: Int?

    // Current track's lock-screen metadata (title / artist) for MPNowPlayingInfoCenter.
    private var nowPlayingTitle: String = ""
    private var nowPlayingArtist: String = ""

    init() {
        configureAudioSession()
        configureRemoteCommands()
        // Drive the scrubber ~4×/s.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.rate != 0
                self?.updateNowPlayingInfo()
            }
        }
    }

    // No deinit teardown: PlayerEngine lives for the app's lifetime (injected once at
    // launch), and AVPlayer releases its periodic observer when it deallocates. Touching
    // the MainActor-isolated observer from a nonisolated deinit isn't allowed anyway.

    /// Load a new track. `live` HLS starts immediately and won't seek; otherwise we
    /// seek to `startMs` (analog track offset) once the item reports a usable duration.
    /// `title`/`artist` populate the lock-screen / Control Center Now Playing card.
    func load(url: URL, live: Bool, startMs: Int?, title: String = "", artist: String = "") {
        isLive = live
        currentTime = 0
        duration = 0
        pendingSeekMs = live ? nil : startMs
        nowPlayingTitle = title
        nowPlayingArtist = artist

        let item = AVPlayerItem(url: url)
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemBecameReady(item) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        updateNowPlayingInfo()
    }

    private func itemBecameReady(_ item: AVPlayerItem) {
        guard item.status == .readyToPlay else { return }
        let d = item.duration.seconds
        if d.isFinite, d > 0 { duration = d }
        if let ms = pendingSeekMs, d.isFinite, d > 0 {
            pendingSeekMs = nil
            let target = min(Double(ms) / 1000.0, d - 0.1)
            seek(to: max(0, target))
        }
        updateNowPlayingInfo()
    }

    func play() { player.play(); isPlaying = true; updateNowPlayingInfo() }
    func pause() { player.pause(); isPlaying = false; updateNowPlayingInfo() }
    /// Toggle off the player's REAL `timeControlStatus` — NOT the async rate-KVO-observed
    /// `isPlaying`, which lags a tap and made rapid back-to-back play/pause unreliable.
    func toggle() { player.timeControlStatus == .paused ? play() : pause() }

    /// Seek to an absolute time (seconds). No-op for a live stream beyond its buffer.
    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
        updateNowPlayingInfo()
    }

    /// Stop playback and release the current item (used when the player panel closes).
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation?.invalidate(); statusObservation = nil
        currentTime = 0; duration = 0; isPlaying = false; isLive = false
        pendingSeekMs = nil
        clearNowPlayingInfo()
    }

    private func configureAudioSession() {
        #if canImport(UIKit) && !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* best-effort — playback still works in most cases */ }
        #endif
    }

    // MARK: - Lock-screen / Control Center (MPNowPlayingInfoCenter + remote commands)

    /// Wire the remote command center once: the lock screen, Control Center, AirPods,
    /// and CarPlay drive play / pause / toggle / scrub through these. Live streams reject
    /// position changes (there's no seekable duration).
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.toggle(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, !self.isLive,
                  let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime); return .success
        }
    }

    /// Push current track metadata + playback position to the Now Playing card. Skipped
    /// for a live stream's duration (it has none); the card still shows title + artist.
    private func updateNowPlayingInfo() {
        guard !nowPlayingTitle.isEmpty || !nowPlayingArtist.isEmpty else { clearNowPlayingInfo(); return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingArtist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if !isLive, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
