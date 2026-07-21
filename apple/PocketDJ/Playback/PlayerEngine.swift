import Foundation
import Observation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
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
    /// A security-scoped-access RELEASE for the currently-loaded burned file in a USER-PICKED
    /// burn folder. The scope MUST stay open while AVPlayer reads the file, so the burn store
    /// hands it here; we release it when the item is replaced (next `load`) or `stop`ped.
    /// Releasing it early leaves AVPlayer unable to READ the file → a silent 0:00 / no audio.
    /// nil for app-storage files (no scope needed).
    private var scopeRelease: (() -> Void)?

    // MARK: External now-playing (Apple Music streaming)
    //
    // PlayerEngine can drive the lock-screen / CarPlay Now Playing card + remote commands for
    // audio it does NOT itself play — MusicKit's `ApplicationMusicPlayer`. MusicKit writes
    // nothing to `MPNowPlayingInfoCenter` and swallows the system next button (its queue is one
    // song), so during a streamed setlist track PlayerEngine OWNS the arbiter, publishes the
    // card (title/artist/artwork + elapsed pulled from `externalPosition`), and routes
    // ⏭/⏮/play/pause to the set + the stream. Its own AVPlayer is idled so nothing double-plays.
    /// True while impersonating an external streaming source's card.
    private var externalActive = false
    /// Pulls the streaming player's current position (seconds) for the card's elapsed time.
    private var externalPosition: (() -> Double)?
    /// Reflects the streaming player's real play/pause state into the card.
    private var externalIsPlaying: (() -> Bool)?
    /// Resume / pause the streaming player (driven by the remote play/pause commands).
    private var externalPlay: (() -> Void)?
    private var externalPause: (() -> Void)?
    /// ~1 Hz ticker that refreshes the card's elapsed time + play state while external.
    @ObservationIgnored private var externalTicker: Task<Void, Never>?

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
    /// The lock-screen / Control Center ♥ (`MPRemoteCommandCenter.likeCommand`) drives these.
    /// Injected once at launch (mirroring `artworkURLsProvider`) from the favorites store + the
    /// catalog: `toggleCurrentFavorite` flips the CURRENT track's favorite (resolving its Apple
    /// Music id for the owner-gated push); `isCurrentFavorite` reports the state so the card's ♥
    /// renders filled/outline. nil in tests that don't wire them (the command then no-ops). The
    /// engine stays decoupled from the favorites/catalog layer — same pattern as the art provider.
    @ObservationIgnored var toggleCurrentFavorite: (() -> Void)?
    @ObservationIgnored var isCurrentFavorite: (() -> Bool)?
    /// The end-of-track NotificationCenter observer, re-registered per loaded item.
    private var endObserver: NSObjectProtocol?
    /// The AVAudioSession interruption observer (iOS) — re-activates + resumes after a call /
    /// other-app interruption ends so a backgrounded set keeps playing per the user's intent.
    private var interruptionObserver: NSObjectProtocol?

    // Current track's lock-screen metadata (title / artist) for MPNowPlayingInfoCenter.
    private var nowPlayingTitle: String = ""
    private var nowPlayingArtist: String = ""
    /// Resolves a song id to its cover-art candidate URLs (self-hosted CDN cover first, then any
    /// remote iTunes cover — same order `CoverImage` tries). Injected once at launch from the
    /// catalog (`AppModel.album(forSongId:)`); nil ⇒ no artwork is attached to the card. Kept as a
    /// closure so the audio engine stays decoupled from the catalog model.
    @ObservationIgnored var artworkURLsProvider: (@MainActor (String) -> [URL])?
    /// The now-playing song id (for artwork resolution) + the fetched Now-Playing-card artwork.
    /// A monotonic token supersedes an in-flight fetch when the track changes, so a slow image
    /// never lands on the wrong song's card.
    private(set) var nowPlayingSongId: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var artworkToken = 0

    init() {
        // NO synchronous audio-session activation here. Activating a `.playback` AVAudioSession
        // (`setActive(true)`) can BLOCK on a cold audio subsystem, and PlayerEngine is built in
        // `PocketDJApp.init()` — i.e. BEFORE the SwiftUI scene body runs. On visionOS that stalled
        // the first-frame presentation, so the launch placeholder ("TestFlight Launch screen") never
        // got replaced — a blank window until a second launch found the subsystem warm ("open
        // twice"). The session is (re-)armed lazily by whoever actually needs audio: `load()` below
        // re-arms it before playback, and every engine (Mix / Studio / Stem / Instrument) does its
        // own setCategory + setActive on start — so nothing is silenced; activation just no longer
        // sits on the launch critical path.
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
                // External mode: the streaming player owns the clock (via the external ticker) and
                // our AVPlayer is idle at 0 — skip so we don't stomp the card's elapsed time.
                if self.externalActive { return }
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
                guard let self else { return }
                // In external mode our AVPlayer is idle (rate 0); the streaming player's state
                // drives `isPlaying` via the external ticker — don't let the idle rate clobber it.
                if self.externalActive { return }
                self.isPlaying = player.rate != 0
                self.updateNowPlayingInfo()
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
              songId: String? = nil, endBoundaryMs: Int? = nil, scopeRelease: (() -> Void)? = nil) {
        // Loading a real item ends any external-source impersonation (Apple Music handoff).
        NPLog.trace("engine.load title=\(title) live=\(live)")
        endExternalNowPlaying()
        // Defensively re-arm the audio session: an interruption (call / other app) can
        // deactivate it, and a backgrounded set must keep playing across track boundaries.
        configureAudioSession()
        // Release the PREVIOUS track's scoped-folder access before swapping items, then hold the
        // NEW one for the lifetime of this item so AVPlayer can read a user-folder burned file.
        self.scopeRelease?()
        self.scopeRelease = scopeRelease
        isLive = live
        clock.currentTime = 0
        clock.duration = 0
        duration = 0
        pendingSeekMs = live ? nil : startMs
        endBoundarySec = (live ? nil : endBoundaryMs).map { Double($0) / 1000 }
        trackEndSignaled = false
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingSongId = songId
        refreshArtwork(for: songId)   // async: fetches the cover, then re-pushes the card

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
        NowPlayingArbiter.shared.claim(self)   // this engine started audio → own the lock-screen card
        // Re-assert the setlist-driven ⏭/⏮ enablement on every claim: the Mix engine flips the SAME
        // shared commands for its auto-mix skip mapping, so reclaiming the card must restore the
        // collection semantics (⏮ previous / ⏭ next while a set runs, disabled otherwise).
        setNextPreviousEnabled(onNext != nil)
        setLikeCommandEnabled(true)            // reclaim heals the ♥ if a Mix interlude disabled it
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

    func play() {
        // External mode: resume the streaming player, not our idle AVPlayer.
        if externalActive { NPLog.trace("engine.play → external stream"); externalPlay?(); isPlaying = true; updateNowPlayingInfo(); return }
        // IDLE GUARD: no item and not external ⇒ there is NO audio for this engine to start.
        // A blind play() here used to re-claim the arbiter and re-write the Now Playing card
        // with the PREVIOUS track's stale title (the macOS "ghost second card" bug) and flip
        // `isPlaying` with no sound behind it (the widget play-state mismatch). Refuse it.
        guard player.currentItem != nil else { NPLog.trace("engine.play REFUSED (idle)"); return }
        NowPlayingArbiter.shared.claim(self)
        setNextPreviousEnabled(onNext != nil)   // reclaim heals ⏭/⏮ after a Mix auto-mix flipped them
        setLikeCommandEnabled(true)             // …and heals the ♥ a Mix card interlude disabled
        player.play(); isPlaying = true; updateNowPlayingInfo()
    }
    func pause() {
        if externalActive { NPLog.trace("engine.pause → external stream"); externalPause?(); isPlaying = false; updateNowPlayingInfo(); return }
        guard player.currentItem != nil else { NPLog.trace("engine.pause REFUSED (idle)"); return }
        player.pause(); isPlaying = false; updateNowPlayingInfo()
    }
    /// Toggle off the player's REAL `timeControlStatus` — NOT the async rate-KVO-observed
    /// `isPlaying`, which lags a tap and made rapid back-to-back play/pause unreliable.
    func toggle() {
        toggleCount += 1
        if externalActive { (externalIsPlaying?() ?? isPlaying) ? pause() : play(); return }
        guard player.currentItem != nil else { NPLog.trace("engine.toggle REFUSED (idle)"); return }
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

    /// Take over the Now Playing card + remote transport on behalf of an EXTERNAL streaming
    /// player (Apple Music via MusicKit). Idles our own AVPlayer so only the stream sounds,
    /// claims the arbiter (so ⏭/⏮/play/pause reach us), publishes the card, and starts a ~1 Hz
    /// ticker that mirrors the stream's live position + play state. Auto-advance is handled by
    /// the caller's own end observer, not here.
    func beginExternalNowPlaying(title: String, artist: String, songId: String?,
                                 durationSeconds: Double,
                                 position: @escaping () -> Double,
                                 isPlaying: @escaping () -> Bool,
                                 play: @escaping () -> Void,
                                 pause: @escaping () -> Void) {
        // Idle our AVPlayer + drop any per-item end observer / boundary from a prior local track
        // so it can't fire against the (now empty) item, and release its scoped-folder access.
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObservation?.invalidate(); statusObservation = nil
        endBoundarySec = nil; trackEndSignaled = true
        pendingSeekMs = nil
        scopeRelease?(); scopeRelease = nil
        isLive = false

        NPLog.trace("engine → beginExternalNowPlaying title=\(title) dur=\(Int(durationSeconds)) (iOS AM: own the card for MusicKit)")
        externalActive = true
        externalPosition = position
        externalIsPlaying = isPlaying
        externalPlay = play
        externalPause = pause

        clock.currentTime = 0
        clock.duration = durationSeconds
        duration = durationSeconds
        self.isPlaying = true                         // `isPlaying` param shadows the property here
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingSongId = songId

        NowPlayingArbiter.shared.claim(self)          // own the card + remote commands
        setNextPreviousEnabled(onNext != nil)         // ⏭/⏮ advance the set
        setLikeCommandEnabled(true)                   // iOS AM card offers the ♥ (PlayerEngine owns it)
        refreshArtwork(for: songId)                   // async cover fetch → re-pushes the card
        updateNowPlayingInfo()
        startExternalTicker()
    }

    /// Refresh the external card's elapsed time + play state ~1×/s from the live providers.
    private func startExternalTicker() {
        externalTicker?.cancel()
        externalTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.externalActive, !Task.isCancelled else { return }
                self.isPlaying = self.externalIsPlaying?() ?? self.isPlaying
                self.clock.currentTime = self.externalPosition?() ?? self.clock.currentTime
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Idle our AVPlayer for an external streaming source (Apple Music) WITHOUT taking over the
    /// system Now Playing card. Used on **macOS**, where MusicKit's `ApplicationMusicPlayer`
    /// already publishes a full Control Center Now Playing entry (art / album / transport) — so
    /// writing our OWN card too showed as a duplicate second "Now Playing" source. Auto-advance
    /// (`onTrackEnded`) and the in-app deck read the coordinator directly, so no card takeover is
    /// needed here; we only silence our AVPlayer (a prior local track) and drop our stale card.
    func idleForExternalPlayback() {
        NPLog.trace("engine → idleForExternalPlayback (macOS AM: scrub card, go inert)")
        endExternalNowPlaying()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObservation?.invalidate(); statusObservation = nil
        endBoundarySec = nil; trackEndSignaled = true
        pendingSeekMs = nil
        scopeRelease?(); scopeRelease = nil
        isLive = false
        isPlaying = false
        // SCRUB the card metadata, not just the card: any later stray write (a remote command,
        // a rate-observer tick) would otherwise resurrect the PREVIOUS track's title on a fresh
        // card — the macOS "ghost second card frozen on the first song" bug. With empty
        // title/artist, `updateNowPlayingInfo` clears instead of writing.
        nowPlayingTitle = ""; nowPlayingArtist = ""; nowPlayingSongId = nil
        artworkToken += 1; nowPlayingArtwork = nil
        // If WE still own the card from a prior local track, clear it so MusicKit's AM card
        // isn't shadowed by our now-stale one (and resign so nothing double-writes).
        if NowPlayingArbiter.shared.isActive(self) { clearNowPlayingInfo() }
    }

    /// Leave external mode (a local track is loading, or playback stopped). Called by `load()`
    /// and `stop()`; safe to call when not external.
    private func endExternalNowPlaying() {
        guard externalActive else { return }
        externalActive = false
        externalPosition = nil; externalIsPlaying = nil; externalPlay = nil; externalPause = nil
        externalTicker?.cancel(); externalTicker = nil
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
        endExternalNowPlaying()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation?.invalidate(); statusObservation = nil
        // Drop the per-item end observer (a nil'd item can't fire). Do NOT nil `onTrackEnded`
        // — the setlist sequencer owns that hook across its own play()/stop() lifecycle.
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        clock.currentTime = 0; clock.duration = 0; duration = 0; isPlaying = false; isLive = false
        pendingSeekMs = nil
        endBoundarySec = nil; trackEndSignaled = false
        scopeRelease?(); scopeRelease = nil   // release the user-folder file's security scope
        artworkToken += 1; nowPlayingSongId = nil; nowPlayingArtwork = nil   // drop any in-flight art fetch
        clearNowPlayingInfo()
    }

    private func configureAudioSession() {
        #if canImport(UIKit) && !os(macOS)
        // Studio mic capture holds the shared session at .playAndRecord — re-arming .playback
        // here (every load calls this) would tear down the recorder's live input tap mid-take
        // (spec §4 coexistence rule); playback works fine under .playAndRecord, so skip.
        guard !AudioSessionPolicy.micCaptureActive else { return }
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

    /// Enable/disable the lock-screen ♥ (`likeCommand`) — PlayerEngine OWNS the like, so every arbiter
    /// claim re-asserts it (mirrors `setNextPreviousEnabled` above). The Mix engine DISABLES this SAME
    /// process-global command while IT owns the card (Mix offers no like — the "Mix/Auto-DJ card = like
    /// OMITTED" rule), so reclaiming the card must HEAL the ♥ back on — otherwise it would stay dead for
    /// the rest of a PlayerEngine-owned track after a Mix interlude flipped it off. Diffed so a same-value
    /// set doesn't churn the shared command center.
    func setLikeCommandEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        if center.likeCommand.isEnabled != enabled { center.likeCommand.isEnabled = enabled }
    }

    // MARK: - Lock-screen / Control Center (MPNowPlayingInfoCenter + remote commands)

    /// Wire the remote command center once: the lock screen, Control Center, AirPods,
    /// and CarPlay drive play / pause / toggle / scrub through these. Live streams reject
    /// position changes (there's no seekable duration).
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self) else { return .commandFailed }
            self.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self) else { return .commandFailed }
            self.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self) else { return .commandFailed }
            self.toggle(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, NowPlayingArbiter.shared.isActive(self), !self.isLive,
                  let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime); return .success
        }
        // NEXT / PREVIOUS drive the setlist sequencer (Feature: background audio). They reject
        // input (and stay disabled) when no set is running (`onNext`/`onPrevious` nil).
        center.nextTrackCommand.isEnabled = false
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self), let onNext = self.onNext else { return .commandFailed }
            onNext(); return .success
        }
        center.previousTrackCommand.isEnabled = false
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, NowPlayingArbiter.shared.isActive(self), let onPrevious = self.onPrevious else { return .commandFailed }
            onPrevious(); return .success
        }
        // The ♥ — a SINGLE feedback toggle (not a like/dislike pair). Registered behind the SAME
        // single-owner arbiter guard as play/pause: a second uncoordinated writer of the shared
        // command center reproduces the documented "ghost second card" bug. Its handler flips the
        // current track's favorite through the injected closure (nil ⇒ no-op); `isActive` (the
        // filled-heart state) is re-pushed by `updateNowPlayingInfo` on every card write.
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "Favorite"
        center.likeCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.handleLikeCommand()
        }
    }

    /// The lock-screen ♥ handler body, extracted from the command target for unit-testability (the
    /// MediaPlayer command can't be invoked directly in a headless test — same reason `checkEndBoundary`
    /// is extracted). Guarded by the SAME single-owner arbiter check as play/pause: only the engine that
    /// OWNS the card may flip the favorite, so a second uncoordinated writer of the shared command center
    /// (the "ghost second card" bug) is rejected. nil `toggleCurrentFavorite` (tests / unwired) also fails.
    /// Returns the exact status the command target reports.
    func handleLikeCommand() -> MPRemoteCommandHandlerStatus {
        guard NowPlayingArbiter.shared.isActive(self),
              let toggle = toggleCurrentFavorite else { return .commandFailed }
        toggle(); return .success
    }

    /// Re-push the Now Playing card so the ♥ (`likeCommand.isActive`) reflects a favorite that
    /// changed OUTSIDE a transport event (the in-app row, the widget, an Apple Music pull). Wired
    /// to the shared favorites observer; a plain re-run of `updateNowPlayingInfo`, which is guarded
    /// (arbiter-owned + non-idle) so it's a no-op when this engine doesn't own the card.
    func refreshFavoriteState() { updateNowPlayingInfo() }

    /// Push current track metadata + playback position to the Now Playing card. Skipped
    /// for a live stream's duration (it has none); the card still shows title + artist.
    private func updateNowPlayingInfo() {
        guard NowPlayingArbiter.shared.isActive(self) else {
            NPLog.trace("engine card SKIP (arbiter owned elsewhere)")
            return   // yield while the Mix owns the card
        }
        // An IDLE engine must never touch the card: after stop() a straggling observer
        // (rate/periodic draining out) re-published the stale previous track — the traced
        // "engine card WRITE … pos=0 dur=0" ghost that put a dead second Now Playing entry
        // in the macOS menu bar during the local → Apple Music handoff.
        guard player.currentItem != nil || externalActive else {
            NPLog.trace("engine card SKIP (idle)")
            return
        }
        guard !nowPlayingTitle.isEmpty || !nowPlayingArtist.isEmpty else { clearNowPlayingInfo(); return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingArtist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if !isLive, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        NPLog.trace("engine card WRITE title=\(nowPlayingTitle) playing=\(isPlaying) pos=\(Int(currentTime)) dur=\(Int(duration)) art=\(nowPlayingArtwork != nil) external=\(externalActive)")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // Also set the explicit playbackState: CarPlay (the head-unit Now Playing template + the
        // system "Now Playing" app) and watchOS rely on it, not just the info dict's PlaybackRate.
        // Without it a phone-started track shows on the CarPlay dashboard but not in Now Playing.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        // The lock-screen ♥ fill state — pushed on every card write (this method re-runs on each
        // load/play/pause/seek AND on a favorite change via refreshFavoriteState). Reads through
        // the injected closure; stays false when unwired (tests) or no current song.
        MPRemoteCommandCenter.shared().likeCommand.isActive = isCurrentFavorite?() ?? false
    }

    /// Resolve + fetch the current track's cover art and attach it to the Now Playing card.
    /// Fire-and-forget: `artworkToken` supersedes an in-flight fetch when the track changes, so a
    /// slow image never lands on the wrong song. No provider / no candidates / no decodable image
    /// ⇒ the card simply keeps title + artist (art shown only "if available").
    private func refreshArtwork(for songId: String?) {
        artworkToken += 1
        nowPlayingArtwork = nil
        let token = artworkToken
        guard let songId, let urls = artworkURLsProvider?(songId), !urls.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let image = await PlayerEngine.loadFirstImage(urls) else { return }
            guard let self, self.artworkToken == token else { return }   // track changed → drop
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    /// Try each candidate URL in order; return the first that decodes to an image (mirrors
    /// `CoverImage`'s fallback ladder). The network I/O happens off the main actor. Shared with
    /// `MixEngine`, which owns the lock-screen card while a Mix deck is playing — hence internal,
    /// not private.
    static func loadFirstImage(_ urls: [URL]) async -> PlatformImage? {
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
                if let img = PlatformImage(data: data) { return img }
            } catch { continue }
        }
        return nil
    }

    private func clearNowPlayingInfo() {
        guard NowPlayingArbiter.shared.isActive(self) else { return }   // don't wipe the Mix's card
        NPLog.trace("engine card CLEAR (+resign)")
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Reset the ♥ fill: nil-ing the card leaves `likeCommand.isActive` stuck TRUE, so a favorited
        // track's filled heart would bleed into the next owner / the idle lock screen. This is the sole
        // resign funnel, so clearing it here also covers the resign path.
        MPRemoteCommandCenter.shared().likeCommand.isActive = false
        NowPlayingArbiter.shared.resign(self)                           // release so the Mix can reclaim
    }
}
