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
/// The fast-moving playback position. It is deliberately NOT `@Observable`: the ~4×/s
/// position ticks must NOT invalidate any SwiftUI view, because doing so re-lays-out the
/// inline player and drops in-flight clicks on its sibling control buttons (the "dead
/// slide-out play/pause · chevron · ✕" bug — proven by a UI test reading a toggle-count
/// probe). The scrubber instead SAMPLES this clock on a `TimelineView` schedule, which
/// redraws itself without triggering Observation, so the buttons' subtree stays stable.
@MainActor
final class PlayerClock {
    /// Plain stored values, mutated 4×/s by the engine's periodic observer. Reading them
    /// does not register an Observation dependency, so no view is invalidated by a tick.
    var currentTime: Double = 0
    /// Duration is also published as an @Observable on the engine (it changes rarely —
    /// once per track — and the scrubber's range needs to react to it).
    var duration: Double = 0
}

@MainActor
@Observable
final class PlayerEngine {
    /// The fast (non-observable) time source. Sampled by the scrubber via TimelineView.
    @ObservationIgnored let clock = PlayerClock()
    /// Track duration — observable (changes once per track), drives the scrubber range.
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var isLive: Bool = false
    /// Test probe: increments on every `toggle()` so a UI test can confirm the button
    /// action actually fired (independent of whether the resulting state flipped).
    private(set) var toggleCount: Int = 0

    /// Non-observable position snapshot (for the scrubber's TimelineView sampling and any
    /// non-reactive reader). Views that want to react to playback should read `isPlaying`.
    var currentTime: Double { clock.currentTime }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    /// The seek target (ms) to apply once the current item becomes ready (analog only).
    private var pendingSeekMs: Int?
    /// A POSITION-based end boundary for the current item (absolute seconds within the file).
    /// When playback passes it we signal end ONCE — so the setlist sequencer advances at the
    /// track's KNOWN length even when the natural end won't fire there. A track inside a shared
    /// album-rip mp3 plays past its own logical end into the NEXT album track; its
    /// `.AVPlayerItemDidPlayToEndTime` only posts at the end of the WHOLE FILE. nil ⇒ rely
    /// solely on the natural end (per-song files, live streams).
    private var endBoundarySec: Double?
    /// One-shot latch shared by BOTH end paths (the natural `.AVPlayerItemDidPlayToEndTime`
    /// AND the position boundary): whichever lands first fires `onTrackEnded` and the other is
    /// suppressed, so the set can't double-advance. Reset on every `load`/`setEndBoundary`.
    private var trackEndSignaled = false

    /// Fired when the CURRENT item plays to its natural end (finite mp3 / burnt-local file).
    /// The setlist sequencer (Feature 3) owns this to auto-advance; nil means no consumer.
    /// A LIVE HLS stream has no natural end, so this never fires for `live` tracks — the
    /// sequencer handles those separately. The engine does NOT nil this on stop() (the
    /// sequencer owns its lifecycle); only `load()` re-registers the per-item observer.
    var onTrackEnded: (() -> Void)?
    /// Lock-screen / Control Center / CarPlay NEXT + PREVIOUS drive these (Feature: background
    /// audio). The setlist sequencer owns them across its play()/stop() lifecycle (mirroring
    /// `onTrackEnded`); nil ⇒ no set is running, so the commands are disabled + reject input.
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// The end-of-track NotificationCenter observer, re-registered per loaded item.
    private var endObserver: NSObjectProtocol?
    /// The AVAudioSession interruption observer (iOS) — re-activates + resumes after a call /
    /// other-app interruption ends so a backgrounded set keeps playing per the user's intent.
    private var interruptionObserver: NSObjectProtocol?

    // Current track's lock-screen metadata (title / artist) for MPNowPlayingInfoCenter.
    private var nowPlayingTitle: String = ""
    private var nowPlayingArtist: String = ""

    init() {
        configureAudioSession()
        configureInterruptionObserver()
        configureRemoteCommands()
        // Drive the scrubber ~4×/s.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // `queue: .main` delivers on the main thread == the main actor's executor, so
            // assert that isolation to mutate the @MainActor currentTime/duration WITHOUT an
            // async Task hop (which would defer the scrubber and re-order updates). Fixes the
            // "can not be mutated from a Sendable closure" warnings.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Position: plain clock only (NO Observation → no view invalidated).
                self.clock.currentTime = time.seconds.isFinite ? time.seconds : 0
                // Duration: publish to the observable when it first becomes known.
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, self.duration != d {
                    self.clock.duration = d
                    self.duration = d
                }
                // Advance at the track's KNOWN length even inside a shared album file: when the
                // position passes the armed boundary, signal end ONCE. While paused the position
                // doesn't advance, so this can't fire early. (Extracted for unit-testability.)
                self.checkEndBoundary(atSeconds: self.clock.currentTime)
            }
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
    /// `endBoundaryMs` (optional) arms a position-based end boundary (absolute ms in the
    /// file) so the sequencer advances at the track's own length inside a shared album mp3.
    func load(url: URL, live: Bool, startMs: Int?, title: String = "", artist: String = "",
              endBoundaryMs: Int? = nil) {
        // Defensively re-arm the audio session: an interruption (call / other app) can
        // deactivate it, and a backgrounded set must keep playing across track boundaries.
        configureAudioSession()
        isLive = live
        clock.currentTime = 0
        clock.duration = 0
        duration = 0
        pendingSeekMs = live ? nil : startMs
        endBoundarySec = (live ? nil : endBoundaryMs).map { Double($0) / 1000 }
        trackEndSignaled = false
        nowPlayingTitle = title
        nowPlayingArtist = artist

        let item = AVPlayerItem(url: url)
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemBecameReady(item) }
        }
        // Re-arm the natural-end observer on the NEW item (auto-advance, Feature 3). Fires
        // only for a finite item; a live HLS stream never posts this. `assumeIsolated` keeps
        // the @MainActor closure hop-free (the notification is delivered on .main).
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signalTrackEnded() }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        updateNowPlayingInfo()
    }

    private func itemBecameReady(_ item: AVPlayerItem) {
        guard item.status == .readyToPlay else { return }
        let d = item.duration.seconds
        if d.isFinite, d > 0 { clock.duration = d; duration = d }
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
    func toggle() {
        toggleCount += 1
        player.timeControlStatus == .paused ? play() : pause()
    }

    /// Arm/disarm the position-based end boundary for the CURRENTLY-loaded item WITHOUT
    /// reloading it — used when the setlist sequencer ADOPTS a track that another surface
    /// (a row ▶) just started, so the adopted track still auto-advances at its known length.
    func setEndBoundary(ms: Int?) {
        endBoundarySec = (isLive ? nil : ms).map { Double($0) / 1000 }
        trackEndSignaled = false
    }

    /// Evaluate the position boundary against `seconds`, signalling end ONCE if it's passed.
    /// Extracted from the periodic time observer so the boundary fire is deterministically
    /// unit-testable. A live stream is never armed (`endBoundarySec` stays nil).
    func checkEndBoundary(atSeconds seconds: Double) {
        guard let b = endBoundarySec, !isLive, seconds >= b else { return }
        signalTrackEnded()
    }

    /// Fire `onTrackEnded` AT MOST ONCE per loaded item — the single funnel for BOTH the
    /// natural `.AVPlayerItemDidPlayToEndTime` and the position boundary, so whichever lands
    /// first advances the set and the other can't double-advance. The latch resets on load.
    private func signalTrackEnded() {
        guard !trackEndSignaled else { return }
        trackEndSignaled = true
        onTrackEnded?()
    }

    /// Seek to an absolute time (seconds). No-op for a live stream beyond its buffer.
    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        clock.currentTime = max(0, seconds)
        updateNowPlayingInfo()
    }

    /// Stop playback and release the current item (used when the player panel closes).
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation?.invalidate(); statusObservation = nil
        // Drop the per-item end observer (a nil'd item can't fire). Do NOT nil `onTrackEnded`
        // — the setlist sequencer owns that hook across its own play()/stop() lifecycle.
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        clock.currentTime = 0; clock.duration = 0; duration = 0; isPlaying = false; isLive = false
        pendingSeekMs = nil
        endBoundarySec = nil; trackEndSignaled = false
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

    /// Re-activate the audio session + resume playback when an interruption (call, other app)
    /// ends, so a backgrounded/locked set keeps going per the user's intent. iOS-only — macOS
    /// has no `AVAudioSession` interruption notification.
    private func configureInterruptionObserver() {
        #if canImport(UIKit) && !os(macOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let info = note.userInfo,
                      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .ended {
                    // The system signals whether we SHOULD resume; honor it (and the user intent
                    // to keep the set running) by re-activating + playing.
                    let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
                    self.configureAudioSession()
                    if shouldResume { self.play() }
                }
            }
        }
        #endif
    }

    /// Enable/disable the lock-screen NEXT + PREVIOUS commands — the setlist sequencer turns
    /// them on while a set is running (so they advance the SET) and off otherwise.
    func setNextPreviousEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = enabled
        center.previousTrackCommand.isEnabled = enabled
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
        // NEXT / PREVIOUS drive the setlist sequencer (Feature: background audio). They reject
        // input (and stay disabled) when no set is running (`onNext`/`onPrevious` nil).
        center.nextTrackCommand.isEnabled = false
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, let onNext = self.onNext else { return .commandFailed }
            onNext(); return .success
        }
        center.previousTrackCommand.isEnabled = false
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, let onPrevious = self.onPrevious else { return .commandFailed }
            onPrevious(); return .success
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
