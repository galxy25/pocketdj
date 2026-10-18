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
    /// The streaming source's playback speed for the card (the Now Playing DSP's tempo); nil ⇒ 1×.
    private var externalRate: (() -> Double)?
    /// ~1 Hz ticker that refreshes the card's elapsed time + play state while external.
    @ObservationIgnored private var externalTicker: Task<Void, Never>?

    // MARK: Card timeline (song-relative) + stall state
    //
    // An analog album rip is ONE shared mp3 with per-song offsets, and the AVPlayer clock is
    // absolute-in-file. The system card must show the SONG's own timeline — elapsed from the
    // song's start and the song's length — or CarPlay draws a cursor crawling across a
    // 45-minute album bar (reads as "not moving"), which then keeps going into the next song.
    /// The current song's start inside the loaded file (seconds); 0 for per-song files.
    @ObservationIgnored private var cardOffsetSec: Double = 0
    /// True while AVPlayer WANTS to play but is waiting for data (`timeControlStatus ==
    /// .waitingToPlayAtSpecifiedRate`): `rate` is already non-zero then, but the audio isn't
    /// moving — the card must publish rate 0 or the cursor runs ahead and snaps back.
    @ObservationIgnored private var isStalled = false
    private var timeControlObservation: NSKeyValueObservation?

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
    /// Lock-screen / Control Center / CarPlay REPEAT + SHUFFLE (`changeRepeatModeCommand` /
    /// `changeShuffleModeCommand`) drive these. The setlist sequencer owns them across its
    /// play()/stop() lifecycle (mirroring `onNext`/`onPrevious`); nil ⇒ no set is running, so the
    /// commands stay disabled and reject input. Repeat maps `MPRepeatType`↔`RepeatMode`; shuffle is
    /// a plain on/off (`.items`/`.off`).
    var onRepeatModeChange: ((RepeatMode) -> Void)?
    var onShuffleChange: ((Bool) -> Void)?
    /// The repeat/shuffle state advertised on the system card's changeRepeat/changeShuffle commands,
    /// set by the setlist and RE-ASSERTED on every card write (like `likeCommand.isActive`) so a Mix
    /// interlude that reclaims the card can't leave a stale glyph.
    @ObservationIgnored private var remoteRepeatType: MPRepeatType = .off
    @ObservationIgnored private var remoteShuffleType: MPShuffleType = .off
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
    /// Per-item failed-to-play-to-end + playback-stalled observers.
    private var failObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    /// Fired when the current item FAILS mid-song (a dead source — the sequencer advances).
    var onTrackFailed: (() -> Void)?
    /// The AVAudioSession interruption observer (iOS) — re-activates + resumes after a call /
    /// other-app interruption ends so a backgrounded set keeps playing per the user's intent.
    private var interruptionObserver: NSObjectProtocol?

    // Current track's lock-screen metadata (title / artist) for MPNowPlayingInfoCenter.
    private var nowPlayingTitle: String = ""
    private var nowPlayingArtist: String = ""
    /// Resolves a song id to its cover-art URLs (self-hosted CDN cover first, then any remote
    /// iTunes cover, then the streaming fallback — same order `CoverImage` tries; async because
    /// the fallback resolves through MusicKit). Injected once at launch from the catalog
    /// (`AppModel.album(forSongId:)` + `AlbumArtworkStore`); nil ⇒ no artwork is attached to the
    /// card. Kept as a closure so the audio engine stays decoupled from the catalog model.
    @ObservationIgnored var artworkURLsProvider: (@MainActor (String) async -> [URL])?
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
                // ~1 Hz LOCAL-path card refresh: the card's elapsed used to be written only at
                // discrete events (load/ready/play/pause/art) — all near 0 — leaving the
                // CarPlay/lock-screen bar entirely dependent on the OS extrapolating from
                // PlaybackRate, and a head unit that doesn't extrapolate showed 0:00 for the
                // whole song. Rewrite the dict once a second while PLAYING (never while paused —
                // that would fight card scrubbing; `updateNowPlayingInfo` is arbiter- and
                // idle-guarded, so a Mix/AM owner is never stomped). Mirrors the external
                // (Apple Music impersonation) ticker, which never had this bug.
                if self.isPlaying {
                    self.cardRefreshAccumulator += 1
                    if self.cardRefreshAccumulator >= 4 {   // 4 ticks × 0.25 s = 1 s
                        self.cardRefreshAccumulator = 0
                        self.updateNowPlayingInfo()
                    }
                }
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, !self.externalActive else { return }
                // FIRST AUDIO after a load: the start window (runway + start watchdog) closes here.
                if player.timeControlStatus == .playing { self.noteFirstAudioIfPending() }
                let stalled = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                guard stalled != self.isStalled else { return }
                self.isStalled = stalled
                self.updateNowPlayingInfo()   // stall ⇒ rate 0; playing again ⇒ rate 1 at the real position
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                // In external mode our AVPlayer is idle (rate 0); the streaming player's state
                // drives `isPlaying` via the external ticker — don't let the idle rate clobber it.
                if self.externalActive { return }
                let wasPlaying = self.isPlaying
                self.isPlaying = player.rate != 0
                if wasPlaying, !self.isPlaying { self.logRateDropped() }
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
              songId: String? = nil, endBoundaryMs: Int? = nil, songStartMs: Int? = nil,
              scopeRelease: (() -> Void)? = nil) {
        // Loading a real item ends any external-source impersonation (Apple Music handoff).
        NPLog.trace("engine.load title=\(title) live=\(live)")
        endExternalNowPlaying()
        // Defensively re-arm the audio session: an interruption (call / other app) can
        // deactivate it, and a backgrounded set must keep playing across track boundaries.
        configureAudioSession(by: "player.load")
        // Release the PREVIOUS track's scoped-folder access before swapping items, then hold the
        // NEW one for the lifetime of this item so AVPlayer can read a user-folder burned file.
        self.scopeRelease?()
        self.scopeRelease = scopeRelease
        isLive = live
        pausedByListener = false
        clock.currentTime = 0
        clock.duration = 0
        duration = 0
        pendingSeekMs = live ? nil : startMs
        endBoundarySec = (live ? nil : endBoundaryMs).map { Double($0) / 1000 }
        trackEndSignaled = false
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingSongId = songId
        cardOffsetSec = live ? 0 : max(0, Double(songStartMs ?? 0) / 1000)
        isStalled = false
        // A load is a START: the listener wants sound (gesture or the sequencer's advance), any
        // interruption that never delivered `.ended` is over, and the first-audio hook re-arms.
        listenerIntentPlaying = true
        interruptionOpen = false
        firstAudioPending = true
        loadedAt = Date()
        refreshArtwork(for: songId)   // async: fetches the cover, then re-pushes the card

        let item = AVPlayerItem(url: url)
        // A smaller forward buffer gets a cold cellular start to "playing" sooner (the 29-32 s
        // `.waitingToPlayAtSpecifiedRate` gaps at the AM→local boundary). Stalling policy itself
        // (`automaticallyWaitsToMinimizeStalling`) is left at its default this ship.
        item.preferredForwardBufferDuration = 4
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
        // MID-SONG FAILURE (a network error on a streamed mp3 over cellular): the item never
        // posts DidPlayToEndTime — without this the set sat silent until ⏭. Same one-shot latch
        // as the natural end, routed to `onTrackFailed` (a dead source ADVANCES — it never
        // replays under repeat-one). Stalls are logged only: AVPlayer resumes those itself.
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                NPLog.trace("engine item FAILED mid-song \(err.map { "\($0.domain)#\($0.code)" } ?? "?")")
                DiagLog.shared.log("playback", "item failed-to-end song=\(self?.nowPlayingSongId ?? "?") err=\(err.map { "\($0.domain)#\($0.code)" } ?? "?")")
                self?.signalTrackFailed()
            }
        }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DiagLog.shared.log("playback", "item stalled song=\(self?.nowPlayingSongId ?? "?")")
            }
        }
        player.replaceCurrentItem(with: item)
        NowPlayingArbiter.shared.claim(self, reason: "load")   // this engine started audio → own the lock-screen card
        // Re-assert the setlist-driven ⏭/⏮ enablement on every claim: the Mix engine flips the SAME
        // shared commands for its auto-mix skip mapping, so reclaiming the card must restore the
        // collection semantics (⏮ previous / ⏭ next while a set runs, disabled otherwise).
        setNextPreviousEnabled(onNext != nil)
        setLikeCommandEnabled(true)            // reclaim heals the ♥ if a Mix interlude disabled it
        player.play()
        updateNowPlayingInfo()
    }

    private func itemBecameReady(_ item: AVPlayerItem) {
        if item.status == .failed {
            let err = item.error as NSError?
            NPLog.trace("engine item status FAILED \(err.map { "\($0.domain)#\($0.code)" } ?? "?")")
            DiagLog.shared.log("playback", "item load failed song=\(nowPlayingSongId ?? "?") err=\(err.map { "\($0.domain)#\($0.code)" } ?? "?")")
            // A dead item never plays and never posts an end — without this the set sat silent
            // on it until ⏭. Same one-shot latch as the natural end, after a short grace
            // (`itemFailedSignalDelay`) in which a superseding load/skip wins — only the item
            // that is STILL current when the grace ends advances the set.
            guard item === player.currentItem else { return }
            firstAudioPending = false
            let delay = Self.itemFailedSignalDelay
            Task { @MainActor [weak self, weak item] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard let self, let item, item === self.player.currentItem, item.status == .failed else { return }
                DiagLog.shared.log("playback", "item load failed → advance song=\(self.nowPlayingSongId ?? "?")")
                self.signalTrackFailed()
            }
            return
        }
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
        if externalActive {
            listenerIntentPlaying = true; interruptionOpen = false
            NPLog.trace("engine.play → external stream"); externalPlay?(); isPlaying = true
            clock.currentTime = externalPosition?() ?? clock.currentTime   // resume FROM the live position
            updateNowPlayingInfo(); return
        }
        // IDLE GUARD: no item and not external ⇒ there is NO audio for this engine to start.
        // A blind play() here used to re-claim the arbiter and re-write the Now Playing card
        // with the PREVIOUS track's stale title (the macOS "ghost second card" bug) and flip
        // `isPlaying` with no sound behind it (the widget play-state mismatch). Refuse it.
        guard player.currentItem != nil else {
            // The idle engine's owner (a held / never-started setlist) gets the chance to turn
            // this ▶ into real playback (interruption `.ended`, widget, intents all land here).
            if let verdict = onIdlePlay?() { NPLog.trace("engine.play idle → onIdlePlay→\(verdict)"); return }
            NPLog.trace("engine.play REFUSED (idle)"); return
        }
        listenerIntentPlaying = true
        interruptionOpen = false
        NowPlayingArbiter.shared.claim(self, reason: "play")
        setNextPreviousEnabled(onNext != nil)   // reclaim heals ⏭/⏮ after a Mix auto-mix flipped them
        setLikeCommandEnabled(true)             // …and heals the ♥ a Mix card interlude disabled
        pausedByListener = false
        player.play(); isPlaying = true; updateNowPlayingInfo()
    }
    func pause() {
        if externalActive {
            listenerIntentPlaying = false
            NPLog.trace("engine.pause → external stream"); externalPause?(); isPlaying = false
            clock.currentTime = externalPosition?() ?? clock.currentTime   // pin WHERE the audio stopped
            updateNowPlayingInfo(); return
        }
        guard player.currentItem != nil else { NPLog.trace("engine.pause REFUSED (idle)"); return }
        pausedByListener = true
        listenerIntentPlaying = false
        lastPauseCallAt = Date()
        DiagLog.shared.log("playback", "engine.pause local byListener=1 song=\(nowPlayingSongId ?? "?")")
        player.pause(); isPlaying = false; updateNowPlayingInfo()
    }
    /// The loaded item was paused ON PURPOSE (our `pause()`), as opposed to not rendering
    /// because it is loading / stalled / dead. Reset by `play()` and every `load`.
    private(set) var pausedByListener = false
    /// Does this engine actually hold audio to act on? Exactly the condition the play /
    /// pause / toggle idle guards above refuse on — surfaced so a ▶ SURFACE can route to
    /// "start the deck's current row" instead of firing a toggle that is silently refused
    /// (or, worse, resumes a stale item from the previous row).
    var hasLoadedItem: Bool { externalActive || player.currentItem != nil }
    /// TEST SEAM: the loaded AVPlayerItem (to post its item notifications).
    var currentItemForTesting: AVPlayerItem? { player.currentItem }

    // MARK: Bulletproof playback seams (docs/design/playback-bulletproof-plan.md)

    /// P0-1 — asked when a ▶ reaches this engine while it holds NO item (a restored, HELD set;
    /// a row whose resolve produced no audio). The owner (`SetlistPlayer`, wired in its init so
    /// it is live while held) turns it into real playback and returns the verdict it took
    /// ("resumeHeld" / "startCurrent" / "startInFlight"), or nil when it had nothing to start.
    @ObservationIgnored var onIdlePlay: (() -> String?)?
    /// P0-1 — a REMOTE ▶ refused because nothing (no item, no held set) could act on it — the
    /// head unit's play-on-connect landing before the launch task restored the session. The
    /// restore consumes it (within a short window) and resumes the held set.
    @ObservationIgnored private(set) var pendingRemotePlayAt: Date?
    /// Take the pending remote ▶ if it is younger than `maxAge` seconds (always clears it).
    func consumePendingRemotePlay(maxAge: TimeInterval, now: Date = Date()) -> Date? {
        guard let t = pendingRemotePlayAt else { return nil }
        pendingRemotePlayAt = nil
        return now.timeIntervalSince(t) <= maxAge ? t : nil
    }
    /// P0-4 — Apple Music's "the current pause was OURS (a listener gesture)" flag, injected so
    /// an interruption `.ended` never un-pauses a stream the listener paused before the call.
    @ObservationIgnored var appleMusicPauseWasIntentional: (() -> Bool)?
    /// P0-6 — while a SET runs, keep the arbiter ownership across the gap between two tracks
    /// (the local-lane `stop()` before the next row resolves): `clearNowPlayingInfo` still
    /// clears the card + ♥ but does not resign, so a parked Mix can't grab the card / remote
    /// commands in the gap. Set by the sequencer while it runs, cleared on its `stop()`.
    @ObservationIgnored var holdsOwnershipAcrossTracks = false
    /// P1-7 — fired ONCE per `load` when the item first actually renders (`timeControlStatus ==
    /// .playing`). The sequencer closes its start window (runway + start watchdog) on it.
    @ObservationIgnored var onFirstAudio: (() -> Void)?
    /// Grace between an item reporting `.failed` and the failed-track signal (a superseding
    /// skip/load within it wins). Tests shorten it.
    static var itemFailedSignalDelay: Double = 2.5
    /// How many times this engine asked for `.playback` + `setActive(true)` (diagnostics/tests).
    @ObservationIgnored private(set) var sessionActivationRequests = 0
    @ObservationIgnored private var firstAudioPending = false
    @ObservationIgnored private var loadedAt: Date?
    /// §3 — the listener's last REQUEST: true after load/play/a resumed interruption, false
    /// after pause / an interruption that did not resume / a route loss (headphones, CarPlay
    /// unplugged). The supervisor only ever acts while this is true.
    @ObservationIgnored private(set) var listenerIntentPlaying = false
    /// An audio-session interruption (call, Siri, another app) began and has not ended.
    @ObservationIgnored private(set) var interruptionOpen = false
    @ObservationIgnored private var wasPlayingAtInterruption = false
    @ObservationIgnored private var lastPauseCallAt: Date?
    @ObservationIgnored private var routeLossAt: Date?
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    /// Live AVPlayer state for the start watchdog / supervisor (read-only).
    var timeControlStatus: AVPlayer.TimeControlStatus { externalActive ? .paused : player.timeControlStatus }
    var reasonForWaitingToPlay: String { player.reasonForWaitingToPlay?.rawValue ?? "-" }
    var itemStatusDescription: String {
        guard let item = player.currentItem else { return "none" }
        switch item.status {
        case .unknown: return "unknown"
        case .readyToPlay: return "ready"
        case .failed: return "failed"
        @unknown default: return "?"
        }
    }
    var itemErrorDescription: String {
        (player.currentItem?.error as NSError?).map { "\($0.domain)#\($0.code)" } ?? "-"
    }
    /// The current item already fired its end/failed signal (the sequencer owns what's next).
    var trackEndAlreadySignaled: Bool { trackEndSignaled }

    /// The sequencer's own intent changes (stop / cascade halt → false; resume → true).
    func noteListenerIntent(_ playing: Bool) { listenerIntentPlaying = playing }

    /// Re-kick a loaded local item IN PLACE: re-arm the session and ask AVPlayer to play again.
    /// Never un-pauses a listener pause. Used by the start watchdog (8 s), the supervisor's L1,
    /// and a ⏯ press on a still-waiting item.
    func rekick(by caller: String) {
        guard !externalActive, player.currentItem != nil, !pausedByListener else { return }
        configureAudioSession(by: caller)
        listenerIntentPlaying = true
        interruptionOpen = false
        player.play()
        updateNowPlayingInfo()
    }

    /// First render after a load → close the start window (once per load).
    private func noteFirstAudioIfPending() {
        guard firstAudioPending else { return }
        firstAudioPending = false
        let ms = loadedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        DiagLog.shared.log("playback", "start-ok song=\(nowPlayingSongId ?? "?") after=\(ms)ms")
        onFirstAudio?()
    }

    #if DEBUG
    /// Tests: AVPlayer never renders a stub file headlessly — fire the first-audio path directly.
    func simulateFirstAudioForTesting() { noteFirstAudioIfPending() }
    /// Tests: is a first-audio signal still owed for the current load?
    var firstAudioPendingForTesting: Bool { firstAudioPending }
    #endif

    /// The rate dropped to 0 — record WHY (a pause we made, an interruption, the end, a stall,
    /// a route loss, or nothing we know of — the drive logs had bare rate→0 lines).
    private func logRateDropped() {
        let now = Date()
        let cause: String
        if let t = lastPauseCallAt, now.timeIntervalSince(t) < 1.5 { cause = "pause" }
        else if interruptionOpen { cause = "interruption" }
        else if let t = routeLossAt, now.timeIntervalSince(t) < 1.5 { cause = "route" }
        else if trackEndSignaled { cause = "end" }
        else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { cause = "stall" }
        else if player.currentItem == nil { cause = "unload" }
        else { cause = "unknown" }
        DiagLog.shared.log("playback", "rate→0 cause=\(cause) song=\(nowPlayingSongId ?? "?") t=\(Int(clock.currentTime))")
    }

    // MARK: Remote command bodies (extracted from the MPRemoteCommandCenter targets — testable)

    private func transportLog(_ cmd: String, _ verdict: String) {
        let arb = NowPlayingArbiter.shared
        DiagLog.shared.telemetry("transport", "rc cmd=\(cmd) engine=PlayerEngine owner=\(NowPlayingArbiter.name(arb.owner)) "
                                 + "preferred=\(NowPlayingArbiter.name(arb.preferred)) verdict=\(verdict)")
    }

    /// The remote ▶ (`playCommand`) body. An idle engine first offers the ▶ to its owner
    /// (`onIdlePlay` — resume the held set / start the never-started row); if nobody can act,
    /// the press is LATCHED for a restore that may land a moment later.
    func handleRemotePlay() -> MPRemoteCommandHandlerStatus {
        guard NowPlayingArbiter.shared.isActive(self) else { transportLog("play", "not-owner"); return .commandFailed }
        if !hasLoadedItem {
            if let verdict = onIdlePlay?() { transportLog("play", "onIdlePlay→\(verdict)"); return .success }
            pendingRemotePlayAt = Date()
            transportLog("play", "refused-idle")
            NPLog.trace("engine.play REFUSED (idle) — latched for a pending restore")
            return .success
        }
        transportLog("play", "handled")
        play(); return .success
    }

    func handleRemotePause() -> MPRemoteCommandHandlerStatus {
        guard NowPlayingArbiter.shared.isActive(self) else { transportLog("pause", "not-owner"); return .commandFailed }
        transportLog("pause", hasLoadedItem ? "handled" : "refused-idle")
        pause(); return .success
    }

    /// The remote ⏯ body — an idle engine has nothing to pause, so ⏯ means ▶ (same ladder).
    func handleRemoteToggle() -> MPRemoteCommandHandlerStatus {
        guard NowPlayingArbiter.shared.isActive(self) else { transportLog("toggle", "not-owner"); return .commandFailed }
        if !hasLoadedItem {
            if let verdict = onIdlePlay?() { transportLog("toggle", "onIdlePlay→\(verdict)"); return .success }
            pendingRemotePlayAt = Date()
            transportLog("toggle", "refused-idle")
            toggle()   // keeps the probe count + the REFUSED trace
            return .success
        }
        transportLog("toggle", "handled")
        toggle(); return .success
    }

    /// Toggle off the player's REAL `timeControlStatus` — NOT the async rate-KVO-observed
    /// `isPlaying`, which lags a tap and made rapid back-to-back play/pause unreliable.
    func toggle() {
        toggleCount += 1
        if externalActive { (externalIsPlaying?() ?? isPlaying) ? pause() : play(); return }
        guard player.currentItem != nil else { NPLog.trace("engine.toggle REFUSED (idle)"); return }
        // A track that WANTS to play but is still waiting for data shows ⏸ on the honest card;
        // a ▶/⏯ press there means "play it", not "pause it" — re-kick instead of pausing (the
        // old behaviour made the field "kick" take two presses). The discrete pause still pauses.
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate, !pausedByListener {
            NPLog.trace("engine.toggle while waiting → re-kick (not pause)")
            rekick(by: "player.toggle"); return
        }
        player.timeControlStatus == .paused ? play() : pause()
    }

    /// Arm/disarm the position-based end boundary for the CURRENTLY-loaded item WITHOUT
    /// reloading it — used when the setlist sequencer ADOPTS a track that another surface
    /// (a row ▶) just started, so the adopted track still auto-advances at its known length.
    func setEndBoundary(ms: Int?, songStartMs: Int? = nil) {
        endBoundarySec = (isLive ? nil : ms).map { Double($0) / 1000 }
        if let songStartMs, !isLive { cardOffsetSec = max(0, Double(songStartMs) / 1000) }
        trackEndSignaled = false
        updateNowPlayingInfo()   // the card's song window changed
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

    /// The current item FAILED mid-song: fire `onTrackFailed` (falling back to `onTrackEnded`)
    /// at most once per item — the same latch as the natural end.
    private func signalTrackFailed() {
        guard !trackEndSignaled else { return }
        trackEndSignaled = true
        if let onTrackFailed { onTrackFailed() } else { onTrackEnded?() }
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
                                 rate: (() -> Double)? = nil,
                                 play: @escaping () -> Void,
                                 pause: @escaping () -> Void) {
        // Idle our AVPlayer + drop any per-item end observer / boundary from a prior local track
        // so it can't fire against the (now empty) item, and release its scoped-folder access.
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver); self.failObserver = nil }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver); self.stallObserver = nil }
        statusObservation?.invalidate(); statusObservation = nil
        endBoundarySec = nil; trackEndSignaled = true
        pendingSeekMs = nil
        scopeRelease?(); scopeRelease = nil
        isLive = false

        NPLog.trace("engine → beginExternalNowPlaying title=\(title) dur=\(Int(durationSeconds)) (iOS AM: own the card for MusicKit)")
        externalActive = true
        externalPosition = position
        externalIsPlaying = isPlaying
        externalRate = rate
        externalPlay = play
        externalPause = pause
        cardOffsetSec = 0
        isStalled = false
        firstAudioPending = false   // the stream's own first audio is the provider's signal

        // Seed the card from the stream's LIVE state — never a hard-coded 0:00 / playing. A
        // restored session resuming mid-song published 0:00 for the first second (field
        // 2026-10-04: pos=0 then 207), and a DSP engaged while PAUSED published a running cursor.
        clock.currentTime = position()
        clock.duration = durationSeconds
        duration = durationSeconds
        self.isPlaying = isPlaying()                  // `isPlaying` param shadows the property here
        listenerIntentPlaying = self.isPlaying
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingSongId = songId

        NowPlayingArbiter.shared.claim(self, reason: "beginExternal")   // own the card + remote commands
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
                self.externalTick()
            }
        }
    }

    /// One external-ticker beat: mirror the stream's live play state + position into the card.
    private func externalTick() {
        isPlaying = externalIsPlaying?() ?? isPlaying
        clock.currentTime = externalPosition?() ?? clock.currentTime
        updateNowPlayingInfo()
    }

    /// Re-publish the external card NOW from the live providers (e.g. right after the caller
    /// started the external audio, instead of waiting up to a second for the ticker).
    func refreshExternalNowPlaying() { if externalActive { externalTick() } }

    #if DEBUG
    /// Tests: run one external-ticker beat synchronously (the real ticker sleeps 1 s between beats).
    /// A no-op unless external — exactly the guard the real ticker loop applies.
    func externalTickForTesting() { if externalActive { externalTick() } }
    #endif

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
        if let failObserver { NotificationCenter.default.removeObserver(failObserver); self.failObserver = nil }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver); self.stallObserver = nil }
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
        artworkToken += 1; nowPlayingArtwork = nil; artworkSongId = nil
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
        externalRate = nil
        externalTicker?.cancel(); externalTicker = nil
    }

    /// Seek to an absolute time (seconds). No-op for a live stream beyond its buffer.
    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        clock.currentTime = max(0, seconds)
        updateNowPlayingInfo()
    }

    /// A scrub on the system card / CarPlay (`changePlaybackPositionCommand`): the card's
    /// timeline → this engine's clock.
    func seekFromCard(toCardSeconds seconds: Double) {
        seek(to: seconds + cardOffsetSec)
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
        if let failObserver { NotificationCenter.default.removeObserver(failObserver); self.failObserver = nil }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver); self.stallObserver = nil }
        clock.currentTime = 0; clock.duration = 0; duration = 0; isPlaying = false; isLive = false
        cardOffsetSec = 0; isStalled = false
        firstAudioPending = false
        pendingSeekMs = nil
        endBoundarySec = nil; trackEndSignaled = false
        scopeRelease?(); scopeRelease = nil   // release the user-folder file's security scope
        artworkToken += 1; nowPlayingSongId = nil; nowPlayingArtwork = nil   // drop any in-flight art fetch
        artworkSongId = nil   // …and the same-song memo, so the next load re-fetches
        clearNowPlayingInfo()
    }

    /// Re-arm the shared session for playback. `by` names the call site for the `[session]
    /// activate` telemetry row (the drive logs could not tell who re-grabbed the session).
    private func configureAudioSession(by caller: String = "player") {
        sessionActivationRequests += 1
        #if canImport(UIKit) && !os(macOS)
        // Studio mic capture holds the shared session at .playAndRecord — re-arming .playback
        // here (every load calls this) would tear down the recorder's live input tap mid-take
        // (spec §4 coexistence rule); playback works fine under .playAndRecord, so skip.
        guard !AudioSessionPolicy.micCaptureActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            DiagLog.shared.log("session", "activate by=\(caller) amActive=\(externalActive ? 1 : 0) result=ok")
        } catch {
            // Best-effort — playback still works in most cases — but no longer SILENT: a failed
            // activation under someone else's non-mixable session is exactly the dead-air shape.
            let e = error as NSError
            DiagLog.shared.log("session", "activate by=\(caller) amActive=\(externalActive ? 1 : 0) "
                               + "result=err \(e.domain)#\(e.code) otherAudio=\(session.isOtherAudioPlaying ? 1 : 0)")
        }
        #endif
    }

    /// Interruptions (call, Siri, another app) — OWNER- and INTENT-scoped (plan P0-4):
    ///  - `.began` records whether THIS engine was actually playing (the stream's real state while
    ///    impersonating Apple Music, else the AVPlayer rate) and parks the listener intent.
    ///  - `.ended` resumes ONLY what was playing and was not paused on purpose. While Apple Music
    ///    owns the audio we never re-activate OUR session (MusicKit owns it — re-grabbing it
    ///    interrupted MusicKit again: the pause/resume ping-pong); the stream is resumed through
    ///    its own closure unless the listener's pause was intentional.
    /// iOS-only — macOS has no `AVAudioSession` interruption notification.
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
                let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt
                self.handleInterruption(began: type == .began,
                                        shouldResume: opts.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) })
            }
        }
        // A ROUTE LOSS (headphones / CarPlay / BT unplugged) makes AVPlayer pause itself. That is
        // the listener's pause by platform convention — record it as one, so neither the start
        // watchdog nor the supervisor re-kicks the set out of the phone speaker.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      reason == .oldDeviceUnavailable else { return }
                self.handleRouteLoss()
            }
        }
        #endif
    }

    /// The interruption verdict, extracted so it is unit-testable without posting system
    /// notifications (`shouldResume` nil ⇒ the option key was missing — treated as resume, as
    /// before). Returns the action taken ("resume" / "hold") for `.ended`, nil for `.began`.
    @discardableResult
    func handleInterruption(began: Bool, shouldResume: Bool?) -> String? {
        let owner = NowPlayingArbiter.name(NowPlayingArbiter.shared.owner)
        if began {
            wasPlayingAtInterruption = externalActive ? (externalIsPlaying?() ?? false) : player.rate > 0
            interruptionOpen = true
            DiagLog.shared.log("session", "interruption began engine=player wasPlaying=\(wasPlayingAtInterruption ? 1 : 0) "
                               + "external=\(externalActive ? 1 : 0) owner=\(owner)")
            return nil
        }
        interruptionOpen = false
        let resumeAllowed = shouldResume ?? true
        let action: String
        if externalActive {
            let intentional = appleMusicPauseWasIntentional?() ?? false
            if resumeAllowed && wasPlayingAtInterruption && !intentional {
                action = "resume"
                listenerIntentPlaying = true
                externalPlay?(); isPlaying = true
                clock.currentTime = externalPosition?() ?? clock.currentTime
                updateNowPlayingInfo()
            } else {
                action = "hold"
                if wasPlayingAtInterruption { listenerIntentPlaying = false }
            }
            DiagLog.shared.log("session", "interruption ended shouldResume=\(shouldResume.map { $0 ? "1" : "0" } ?? "missing") engine=player "
                               + "external=1 pauseWasIntentional=\(intentional ? 1 : 0) wasPlaying=\(wasPlayingAtInterruption ? 1 : 0) action=\(action)")
        } else {
            if resumeAllowed && wasPlayingAtInterruption && !pausedByListener && player.currentItem != nil {
                action = "resume"
                configureAudioSession(by: "player.ended")
                play()
            } else {
                action = "hold"
                // The system said not to resume (or nothing was playing): the set stays paused,
                // and the supervisor must treat it as such.
                if wasPlayingAtInterruption { listenerIntentPlaying = false }
            }
            DiagLog.shared.log("session", "interruption ended shouldResume=\(shouldResume.map { $0 ? "1" : "0" } ?? "missing") engine=player "
                               + "external=0 pausedByListener=\(pausedByListener ? 1 : 0) wasPlaying=\(wasPlayingAtInterruption ? 1 : 0) action=\(action)")
        }
        wasPlayingAtInterruption = false
        return action
    }

    /// Headphones / CarPlay / BT went away and AVPlayer paused itself: a listener pause.
    func handleRouteLoss() {
        routeLossAt = Date()
        listenerIntentPlaying = false
        guard !externalActive, player.currentItem != nil else { return }
        pausedByListener = true
        DiagLog.shared.log("session", "route change reason=oldDeviceUnavailable engine=player → treated as listener pause")
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

    /// Enable/disable the lock-screen / CarPlay REPEAT + SHUFFLE commands — the setlist sequencer
    /// turns them on while a set runs (so they drive the SET's modes) and off otherwise (a
    /// single-song play shows no repeat/shuffle glyph). Diffed so a same-value set doesn't churn the
    /// process-global command center.
    func setRepeatShuffleCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        if center.changeRepeatModeCommand.isEnabled != enabled { center.changeRepeatModeCommand.isEnabled = enabled }
        if center.changeShuffleModeCommand.isEnabled != enabled { center.changeShuffleModeCommand.isEnabled = enabled }
    }

    /// Advertise the whole-session repeat mode on the system card (the sequencer calls this on every
    /// mode change). Stored in `remoteRepeatType` + re-asserted on each card write, like `likeCommand`.
    func setRemoteRepeatMode(_ mode: RepeatMode) {
        switch mode {
        case .off: remoteRepeatType = .off
        case .all: remoteRepeatType = .all
        case .one: remoteRepeatType = .one
        }
        MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = remoteRepeatType
        updateNowPlayingInfo()
    }

    /// Advertise the shuffle state on the system card (on ⇒ `.items`).
    func setRemoteShuffle(_ on: Bool) {
        remoteShuffleType = on ? .items : .off
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = remoteShuffleType
        updateNowPlayingInfo()
    }

    // MARK: - Lock-screen / Control Center (MPNowPlayingInfoCenter + remote commands)

    /// Wire the remote command center once: the lock screen, Control Center, AirPods,
    /// and CarPlay drive play / pause / toggle / scrub through these. Live streams reject
    /// position changes (there's no seekable duration).
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Bodies extracted (`handleRemote*`) for unit tests + the `[transport]` telemetry row.
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.handleRemotePlay()
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.handleRemotePause()
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.handleRemoteToggle()
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, NowPlayingArbiter.shared.isActive(self), !self.isLive,
                  let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seekFromCard(toCardSeconds: e.positionTime); return .success
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

        // REPEAT + SHUFFLE — one wiring surfaces them on the lock screen, Control Center, AND
        // CarPlay's `CPNowPlayingTemplate` at once (the head unit auto-renders the affordances when
        // the commands are enabled + `currentRepeatType`/`currentShuffleType` are set). Enabled only
        // while a set runs (`setRepeatShuffleCommandsEnabled`, driven by the sequencer's arm/stop),
        // and guarded by the SAME single-owner arbiter as play/pause so a Mix interlude that owns the
        // card rejects them. Glyph state is re-asserted on every card write (`updateNowPlayingInfo`).
        center.changeRepeatModeCommand.isEnabled = false
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self, NowPlayingArbiter.shared.isActive(self),
                  let onRepeat = self.onRepeatModeChange,
                  let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode
            switch e.repeatType {
            case .off: mode = .off
            case .one: mode = .one
            case .all: mode = .all
            @unknown default: mode = .off
            }
            onRepeat(mode); return .success
        }
        center.changeShuffleModeCommand.isEnabled = false
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let self, NowPlayingArbiter.shared.isActive(self),
                  let onShuffle = self.onShuffleChange,
                  let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            // Any non-off shuffle type (.items / .collections) reads as "on".
            onShuffle(e.shuffleType != .off); return .success
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
        // Through the ONE card funnel (`NowPlayingCardPublisher`): it writes the dict AND the
        // explicit playbackState (CarPlay's Now Playing template + watchOS read it, not just the
        // dict's PlaybackRate), enforces the moving-cursor invariants, and traces (rate-limited).
        // The SONG's timeline (see `cardOffsetSec`): elapsed from the song's start; duration =
        // the armed end boundary (the song's own end inside a shared file), else the file's rest.
        let cardDuration: Double? = {
            guard !isLive else { return nil }
            if let end = endBoundarySec, end > cardOffsetSec { return end - cardOffsetSec }
            return duration > cardOffsetSec ? duration - cardOffsetSec : nil
        }()
        // Advancing = playing AND not stalled on the network; external rate = the source's tempo.
        NowPlayingCardPublisher.shared.publish(
            writer: externalActive ? "engine-ext" : "engine",
            title: nowPlayingTitle, artist: nowPlayingArtist,
            elapsed: currentTime - cardOffsetSec, duration: cardDuration,
            advancing: isPlaying && !isStalled,
            rate: externalActive ? (externalRate?() ?? 1) : 1,
            isLive: isLive, artwork: nowPlayingArtwork,
            // HONEST card: a start that is still buffering wants to play — state `.playing`
            // (head unit shows ⏸), cursor frozen (rate 0). A listener pause stays `.paused`.
            intentPlaying: isPlaying && isStalled && !pausedByListener,
            detail: "art=\(nowPlayingArtwork != nil)\(isStalled ? " stalled" : "")\(cardOffsetSec > 0 ? " off=\(Int(cardOffsetSec))" : "")")
        // The lock-screen ♥ fill state — pushed on every card write (this method re-runs on each
        // load/play/pause/seek AND on a favorite change via refreshFavoriteState). Reads through
        // the injected closure; stays false when unwired (tests) or no current song.
        MPRemoteCommandCenter.shared().likeCommand.isActive = isCurrentFavorite?() ?? false
        // Re-assert the repeat/shuffle glyph state on every card write — a Mix interlude that
        // reclaimed the card would otherwise leave a stale type. Harmless while the commands are
        // disabled (a single-song play): the glyphs are hidden then regardless.
        let rc = MPRemoteCommandCenter.shared()
        rc.changeRepeatModeCommand.currentRepeatType = remoteRepeatType
        rc.changeShuffleModeCommand.currentShuffleType = remoteShuffleType
    }

    /// The song id the current `artworkToken` fetch (or landed art) belongs to — lets a
    /// `load()` that follows an `announceUpcoming` for the SAME song keep the in-flight (or
    /// already-landed) fetch instead of cancelling and re-firing it.
    private var artworkSongId: String?

    /// Counts periodic-observer ticks toward the ~1 Hz local-path card refresh (4 × 0.25 s).
    @ObservationIgnored private var cardRefreshAccumulator = 0

    /// Resolve + fetch the current track's cover art and attach it to the Now Playing card.
    /// Fire-and-forget: `artworkToken` supersedes an in-flight fetch when the track changes, so a
    /// slow image never lands on the wrong song. No provider / no candidates / no decodable image
    /// ⇒ the card simply keeps title + artist (art shown only "if available").
    private func refreshArtwork(for songId: String?) {
        // Same song as the fetch already in flight (announce → load for one skip): keep it.
        if let songId, songId == artworkSongId { return }
        artworkToken += 1
        nowPlayingArtwork = nil
        artworkSongId = songId
        let token = artworkToken
        guard let songId, let provider = artworkURLsProvider else { return }
        Task { @MainActor [weak self] in
            // The provider itself may resolve through the network (streaming fallback), so it
            // runs inside the superseded task too — a slow resolve for a skipped track drops.
            let urls = await provider(songId)
            guard self?.artworkToken == token else { return }
            guard !urls.isEmpty else { return }   // honestly no art — keep title/artist card
            guard let image = await PlayerEngine.loadFirstImage(urls) else {
                // Failed fetch: clear the same-song memo so a LATER call for this song can
                // retry, instead of memoizing the failure for the rest of the track.
                if let self, self.artworkToken == token { self.artworkSongId = nil }
                return
            }
            guard let self, self.artworkToken == token else { return }   // track changed → drop
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    /// INSTANT metadata for the track the sequencer just moved to, written BEFORE its audio
    /// resolves — so a listener skipping through a set (lock screen, CarPlay, the watch) sees
    /// each row's title/artist the moment ⏭ lands and can seek straight to the song they want,
    /// instead of staring at the previous track's card for the seconds a cloud resolve takes.
    ///
    /// This deliberately bypasses `updateNowPlayingInfo`'s idle guard (the engine may hold no
    /// item right now — the outgoing track was just stopped), which is safe ONLY because of the
    /// arbiter guard: a blind write from a NON-owner is exactly the "ghost second card" bug, so
    /// a caller that doesn't currently own the card is refused. Elapsed 0 / rate 0 — honest
    /// "cueing up" state; the real load()/play() re-writes with live position within seconds.
    /// The art fetch starts here too, in parallel with the audio resolve, so the cover is often
    /// already on the card when audio starts (and `refreshArtwork`'s same-song memo keeps
    /// load() from cancelling this fetch).
    func announceUpcoming(title: String, artist: String, songId: String?) {
        guard NowPlayingArbiter.shared.isActive(self) else {
            NPLog.trace("engine card ANNOUNCE refused (arbiter owned elsewhere)")
            return
        }
        // The OUTGOING stream's impersonation ends here: its ~1 Hz ticker would otherwise keep
        // re-publishing the ENDED track's clock (and duration, paused) under THIS title while the
        // next track resolves — field 2026-10-04 20:10:36 "Try It … pos=302 dur=301", for 20 s
        // when the resolve was slow. The next hand-off (AM / local load) re-arms whatever it needs.
        endExternalNowPlaying()
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingSongId = songId
        refreshArtwork(for: songId)
        NPLog.trace("engine card ANNOUNCE title=\(title)")
        NowPlayingCardPublisher.shared.publish(
            writer: "engine-announce", title: title, artist: artist, elapsed: 0, duration: nil,
            advancing: false, artwork: nowPlayingArtwork, updatesPlaybackState: false)
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
        NowPlayingCardPublisher.shared.clear(writer: "engine")
        // Reset the ♥ fill: nil-ing the card leaves `likeCommand.isActive` stuck TRUE, so a favorited
        // track's filled heart would bleed into the next owner / the idle lock screen. This is the sole
        // resign funnel, so clearing it here also covers the resign path.
        MPRemoteCommandCenter.shared().likeCommand.isActive = false
        // P0-6: a running SET keeps the card ownership across the gap between two tracks (the
        // local-lane stop before the next row resolves) — resigning there let a parked Mix
        // answer the next remote command / flash its stale card. The set's own stop() clears
        // the flag first, so a finished set still frees the card.
        if holdsOwnershipAcrossTracks {
            NPLog.trace("engine card CLEAR (ownership held across tracks)")
            return
        }
        NowPlayingArbiter.shared.resign(self)                           // release so the Mix can reclaim
    }
}
