import Foundation
import Observation

/// The Apple Music STREAMING playback provider — the first backend the matching
/// engine tries for an "Apple Music (Local)" track. It wraps the existing
/// `AppleMusicProvider` (MusicKit account-link + `resolve(_:)` catalog matcher) and
/// adds the `TrackPlaybackProvider` seam the coordinator drives:
///   • `tryPlay` = `resolve(song)`; on a hit, enqueue + play via `ApplicationMusicPlayer`
///     and return true (this provider wins); on a miss return false so the engine falls
///     through to the rip server.
///   • `isPlaying` / position observe `ApplicationMusicPlayer.shared.state` so the unified
///     inline player can show a working play/pause + a position-only scrubber (Apple Music
///     streaming has no waveform).
///
/// MusicKit ships with the SDK, but the ENTITLEMENT that makes playback actually work is
/// runtime-only — so this compiles + links in the default build and simply reports
/// `isReady == false` until the build is signed with the MusicKit entitlement AND the user
/// authorizes. The `#if canImport(MusicKit)` split keeps a toolchain without the framework
/// compiling (the `#else` stub is permanently un-ready).
@MainActor
@Observable
final class AppleMusicPlaybackProvider: TrackPlaybackProvider {
    let backend: PlaybackBackend = .appleMusic

    /// The now-playing handoff for the inline player (title/artist + the namespaced id the
    /// row keys off, so the coordinator knows which row is the Apple Music now-playing one).
    struct NowPlaying: Equatable {
        var songId: String
        var title: String
        var artist: String
        /// The MusicKit catalog track's artwork URL. Our "Apple Music (Local)" catalog carries
        /// NO cover art (`IndexAlbum.artCandidates` is empty), so this — captured from the
        /// resolved catalog `Song` — is the only cover source for a streamed track. The system
        /// lock-screen/CarPlay card shows art because MusicKit auto-fills it; the app's OWN
        /// surfaces (home deck + widget) need this URL to match.
        var artworkURL: URL?
    }
    private(set) var nowPlaying: NowPlaying?

    #if DEBUG
    /// Test seam — unit tests can't drive MusicKit (no entitlement/authorization headless),
    /// so the SetlistPlayer adoption tests stamp the streamed now-playing state directly.
    func setNowPlayingForTests(_ np: NowPlaying?) { nowPlaying = np }
    #endif

    /// Observable playback state for the inline panel's play/pause icon. Set synchronously
    /// in togglePlayPause / tryPlay / stop because `ApplicationMusicPlayer.state.playbackStatus`
    /// is NOT Observation-tracked — a computed property off it never re-renders the icon.
    private(set) var isPlaying: Bool = false

    /// The resolved catalog track's length (seconds), captured at play time. Drives the
    /// lock-screen / CarPlay Now Playing card's duration (the streaming player exposes no
    /// duration the sequencer can read) and the end-monitor's completion backstop. 0 ⇒ unknown.
    private(set) var durationSeconds: Double = 0

    /// Fired when the CURRENT streaming track reaches its natural end, so the setlist
    /// sequencer can advance. MusicKit's `ApplicationMusicPlayer` is a SEPARATE player the
    /// sequencer doesn't observe, so WITHOUT this the set freezes after one Apple Music song
    /// (the "plays one song then stops" bug). Owned by `SetlistPlayer` across its play()/stop()
    /// lifecycle (mirroring `PlayerEngine.onTrackEnded`); nil ⇒ no consumer.
    var onTrackEnded: ((EndReason) -> Void)?

    /// Fired when the streaming track was RESTARTED from outside (the system remote ⏮, which
    /// iOS delivers to MusicKit itself — it rewinds its one-song queue to 0:00 and tells nobody).
    /// The setlist sequencer turns this into a step BACK, mirroring the in-app ⏮. Owned by
    /// `SetlistPlayer` alongside `onTrackEnded`; nil ⇒ no consumer.
    var onTrackRestarted: (() -> Void)?

    /// Fired when the stream was INTERRUPTED from outside — MusicKit's player went `.stopped`
    /// well before the track's length (another player on this Mac / Apple ID took over: the rip
    /// server's live capture driving Music.app, the 2026-10-13 cascade). This is NOT an end of
    /// track: the set stays on the row, paused at the interruption point, and ▶ resumes there.
    /// Owned by `SetlistPlayer` alongside `onTrackEnded`; nil ⇒ no consumer.
    var onInterrupted: (() -> Void)?

    /// Song-relative seconds where an external interruption stopped the stream; non-nil ⇔ the
    /// current track is interrupted (cleared by a resume, a new `tryPlay`, or `stop`).
    @ObservationIgnored private(set) var interruptedAtSeconds: Double?
    /// True once MusicKit has REPORTED `.playing` for the current track — audio really started
    /// (vs. `isPlaying`, which is set optimistically when `play()` is accepted). Read by the
    /// sequencer's cascade breaker to count audible time honestly.
    @ObservationIgnored private(set) var audioConfirmed = false
    /// The current track's catalog item, kept so a resume after an interruption can re-queue it
    /// (a `.stopped` player may no longer hold it).
    @ObservationIgnored private var currentQueueItem: Any?
    /// When a resume-after-interruption was requested: until MusicKit reports `.playing` again
    /// (bounded by `startTimeoutSeconds`) the still-`.stopped` status must not be re-read as a
    /// fresh interruption — or, worse, as the end of the track.
    @ObservationIgnored private var resumeRequestedAt: (at: Date, position: Double)?

    /// The highest `playbackTime` the end-monitor has observed for the CURRENT track — the
    /// baseline for the backward-jump (system ⏮) detection. Reset by `tryPlay`, re-based by
    /// our own `seek(to:)` so an in-app scrub can never read as a restart.
    @ObservationIgnored private var monitorMaxPlaybackTime: Double = 0

    /// The `playbackTime` observed on the PREVIOUS poll — the self-heal baseline (see
    /// `advancedDespiteReportedPause`). `playbackStatus` can get stuck reporting NOT-`.playing`
    /// while the audio session keeps genuinely rendering (a known MusicKit staleness class,
    /// confirmed by a CarPlay field report: session ios-3712BFDE, 2026-09-04 — a rapid
    /// pause→resume→pause left the reported status glued to `.paused` for 3+ minutes while
    /// the track was audibly still playing, freezing the CarPlay/lock-screen card on
    /// `playing=false`). Reset alongside `monitorMaxPlaybackTime` on `tryPlay`/`seek` so a
    /// fresh track or an in-app scrub can never read as spurious advancement.
    @ObservationIgnored private var lastPollPlaybackTime: Double = 0

    /// True while the CURRENT paused state was requested through OUR OWN pause paths
    /// (`pausePlayback` / `togglePlayPause` — which is where every in-app and
    /// impersonated-card pause lands). The end-monitor needs it because a pause in the first
    /// second of a track is state-identical to the system-⏭ park (paused, position ≈ 0): with
    /// skip-then-pause — the position is near the top precisely BECAUSE the user just
    /// skipped — the park heuristic read every such pause as another skip and advanced the
    /// set ("pausing skips to a random song", Levi 2026-08-20). Cleared on resume/tryPlay/stop.
    @ObservationIgnored private var pauseWasIntentional = false
    /// Read-only view of `pauseWasIntentional` for the engine's interruption `.ended` verdict and
    /// the supervisor (injected as closures — neither may ever WRITE the flag).
    var pauseIsIntentional: Bool { pauseWasIntentional }
    #if DEBUG
    func setPauseWasIntentionalForTests(_ on: Bool) { pauseWasIntentional = on }
    #endif

    /// Fired ONCE per `tryPlay` when MusicKit first REPORTS `.playing` (audio really started) —
    /// the sequencer closes its start window (background runway) on it.
    @ObservationIgnored var onFirstAudio: (() -> Void)?
    /// True while OUR audio session has an open interruption (a call / Siri) — injected from
    /// `PlayerEngine`. The bounded `.interrupted` auto-resume never fires inside one.
    @ObservationIgnored var sessionInterruptionOpen: (() -> Bool)?
    /// P1-8 — the bounded auto-resume for a stream interrupted by a session fight (see the gate).
    @ObservationIgnored var interruptedResume = InterruptedResumeGate()

    /// P1-8 — MusicKit went `.interrupted` (distinct from `.paused`, which is a user/system pause)
    /// without a listener pause: usually OUR OWN session activation (a materialized Mix, a
    /// re-armed `.playback` session) knocked it off the air and nothing resumed it. This gate
    /// arms a ONE-SHOT resume ladder — first at `delays[0]` s, then `delays[1]` s — that fires only
    /// while the status is STILL `.interrupted`, no listener pause arrived, and our session has no
    /// open interruption (a phone call). Bounded per episode AND per track (`maxPerTrack`) so a
    /// session fight can never ping-pong forever. Pure + clock-injected → unit-testable.
    struct InterruptedResumeGate: Equatable {
        static var delays: [Double] = [2, 6]
        static var maxPerTrack = 4
        private(set) var interruptedSince: Date?
        private(set) var attemptsThisEpisode = 0
        private(set) var attemptsThisTrack = 0

        /// Feed one monitor poll; returns true when `play()` should be called NOW.
        mutating func observe(interrupted: Bool, intentionalPause: Bool, sessionInterrupted: Bool,
                              now: Date) -> Bool {
            guard interrupted, !intentionalPause else {
                interruptedSince = nil; attemptsThisEpisode = 0
                return false
            }
            if interruptedSince == nil { interruptedSince = now; attemptsThisEpisode = 0 }
            guard !sessionInterrupted else { return false }       // a call is in progress — wait it out
            guard attemptsThisEpisode < Self.delays.count, attemptsThisTrack < Self.maxPerTrack else { return false }
            guard now.timeIntervalSince(interruptedSince!) >= Self.delays[attemptsThisEpisode] else { return false }
            attemptsThisEpisode += 1
            attemptsThisTrack += 1
            return true
        }

        /// A new track (tryPlay) / stop: forget everything.
        mutating func resetForTrack() { self = InterruptedResumeGate() }
    }

    /// Fired ONCE per track when the stream is `nearEndLeadSeconds` from its end — the sequencer
    /// pre-arms the hand-off to a LOCAL next row (`PlayerEngine.prearmHandoffSession`) while
    /// MusicKit still holds the audio. Owned by `SetlistPlayer` alongside `onTrackEnded`.
    @ObservationIgnored var onNearEnd: (() -> Void)?
    /// How far (seconds) before the track's end `onNearEnd` fires.
    nonisolated(unsafe) static var nearEndLeadSeconds: Double = 8
    /// Pure verdict for `onNearEnd`: inside the last `nearEndLeadSeconds` of a known length.
    nonisolated static func nearEnd(playbackTime: Double, expectedDuration: Double) -> Bool {
        expectedDuration > nearEndLeadSeconds + 1 && playbackTime >= expectedDuration - nearEndLeadSeconds
    }

    // MARK: Pre-resolve (AM → AM gaps)

    /// PRE-RESOLVE. A start used to run the whole resolve chain — `provider.resolve` (one or
    /// more catalog round trips) then the `MusicCatalogResourceRequest` — only AFTER the
    /// previous track ended: 2–8 s of silence per AM→AM boundary on cellular (dead-air audit,
    /// drive logs 2026-10-23/24). `prefetch` runs that chain for the next rows WHILE the current
    /// one plays; `tryPlay` takes a fresh hit and goes straight to `queue = [song]; play()`.
    /// Values are `MusicKit.Song` (held as `Any` so this stored state compiles without MusicKit).
    struct PrefetchCache {
        nonisolated(unsafe) static var ttlSeconds: Double = 1800
        static let capacity = 8
        private(set) var entries: [String: (at: Date, value: Any)] = [:]

        func value(for key: String, now: Date) -> Any? {
            guard let e = entries[key], now.timeIntervalSince(e.at) < Self.ttlSeconds else { return nil }
            return e.value
        }

        mutating func insert(_ value: Any, for key: String, now: Date) {
            entries[key] = (now, value)
            entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.ttlSeconds }
            while entries.count > Self.capacity,
                  let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
                entries.removeValue(forKey: oldest)
            }
        }

        mutating func remove(_ key: String) { entries.removeValue(forKey: key) }
        mutating func removeAll() { entries = [:] }
    }
    @ObservationIgnored var prefetchCache = PrefetchCache()
    /// Keys whose prefetch is in flight (a re-prefetch of the same rows must not double-fetch).
    @ObservationIgnored var prefetchInFlight: Set<String> = []

    /// Is a fresh pre-resolve held for `song` (its start needs no catalog round trip)?
    func isPrefetched(_ song: IndexSong, now: Date = Date()) -> Bool {
        prefetchCache.value(for: Self.prefetchKey(song), now: now) != nil
    }

    /// The cache key: the id AND every catalog id the edition choice reads — a row re-stamped
    /// to another edition is a different resolve.
    nonisolated static func prefetchKey(_ song: IndexSong) -> String {
        [song.id, song.appleMusicId ?? "", song.appleMusicIdExplicit ?? "", song.appleMusicIdClean ?? "",
         song.explicit.map { $0 ? "e" : "c" } ?? ""].joined(separator: "|")
    }

    /// The polling task that watches `ApplicationMusicPlayer` for end-of-track. Cancelled on
    /// stop / superseded on each new `tryPlay`.
    @ObservationIgnored private var stateMonitor: Task<Void, Never>?

    /// Monotonic ticket for `tryPlay`'s supersede guard — a newer call invalidates an older
    /// one still parked at a network await (see the guard comment in `tryPlay`).
    @ObservationIgnored private var tryPlayGeneration = 0

    /// Wall-clock position smoothing. MusicKit's `playbackTime` is laggy/stale DURING playback
    /// (it advances mainly on state changes), which froze the CarPlay/lock-screen progress bar
    /// and the in-app deck — each ~1 Hz card update re-wrote elapsed with the same stale value,
    /// defeating the OS's own extrapolation. We extrapolate `base + wall-elapsed` so the position
    /// ticks smoothly, snapping forward whenever the real `playbackTime` jumps ahead of us.
    @ObservationIgnored private var positionBase: Double = 0
    @ObservationIgnored private var positionStartWall: Date?

    /// The wrapped account-link + recognizer. Held as the concrete type (not `any
    /// StreamingProvider`) so we can call `resolve(_:)`.
    private let provider: AppleMusicProvider

    init(provider: AppleMusicProvider) {
        self.provider = provider
    }

    /// The end-monitor's per-tick "is the current track OVER?" verdict, extracted pure so
    /// it's unit-testable (MusicKit itself can't run headless).
    ///
    /// `paused` alone is NOT ended — the listener can pause from MusicKit's own system card
    /// (the monitor's external-pause sync). But iOS routes the lock-screen / CarPlay ⏭ to
    /// MusicKit ITSELF (never our `MPRemoteCommandCenter` handler): it "skips" past its
    /// ONE-SONG queue and parks the player PAUSED with the position reset to ~0 (or pinned
    /// at the track's end) — a state a real listener pause never lands in mid-song
    /// (`playbackTime` is exact on state changes, and a pause anchors AT the pause point).
    /// Those parked-paused shapes must count as ended, else the set freezes on the old
    /// track — the "system ⏭ stops the song but never advances" bug.
    nonisolated static func trackEnded(stopped: Bool, paused: Bool,
                                       playbackTime: Double, expectedDuration: Double,
                                       maxObserved: Double, intentionalPause: Bool) -> Bool {
        endReason(stopped: stopped, paused: paused,
                  playbackTime: playbackTime, expectedDuration: expectedDuration,
                  maxObserved: maxObserved, intentionalPause: intentionalPause) != nil
    }

    /// WHY the track ended. The set's reaction differs: a `.natural` end honors repeat-one /
    /// per-track repeat counts (replay the song), while a `.systemSkip` — the listener pressed
    /// ⏭ on the lock screen / CarPlay, which iOS delivers to MusicKit itself, never to our
    /// remote handler — must advance EXACTLY like the in-app ⏭ does. Before the reason was
    /// plumbed through, repeat-one swallowed the skip-park as a natural end and REPLAYED the
    /// same song: with repeat-one on, the car's ⏭ could never leave the track (Levi,
    /// 2026-08-19). nil ⇒ not ended.
    /// `.neverStarted`: `play()` was ACCEPTED but the stream never reached `.playing` within
    /// `startTimeoutSeconds` (an unavailable / placeholder row, a buffering failure on cellular)
    /// — a dead source: the set ADVANCES (never replays it under repeat-one). Before, the monitor
    /// ignored everything until the first `.playing`, so such a row was silent until ⏭.
    enum EndReason { case natural, systemSkip, neverStarted }
    /// Seconds a play MusicKit accepted may take to actually start before it counts as dead.
    nonisolated(unsafe) static var startTimeoutSeconds: Double = 12
    /// Pure verdict for the never-started case. A listener pause before audio started is not a
    /// dead source.
    nonisolated static func neverStarted(everPlayed: Bool, waitedSeconds: Double, intentionalPause: Bool) -> Bool {
        !everPlayed && !intentionalPause && waitedSeconds >= startTimeoutSeconds
    }
    nonisolated static func endReason(stopped: Bool, paused: Bool,
                                      playbackTime: Double, expectedDuration: Double,
                                      maxObserved: Double, intentionalPause: Bool) -> EndReason? {
        if stopped { return .natural }
        let atEnd = expectedDuration > 0 && playbackTime >= expectedDuration - 0.5
        if paused {
            if atEnd { return .natural }
            // Paused parked at the very top (≤1 s). Three ways to land here, discriminated
            // in order — a pause in the first second is NOT rare in practice: after a skip
            // the position is near the top by construction, so skip-then-pause used to read
            // as ANOTHER skip and advanced the set ("pausing skips to a random song").
            if playbackTime <= 1.0 {
                // 1. The position made a hard BACKWARD RESET to the top after real progress.
                //    A listener pause anchors AT the pause point (playbackTime is exact on
                //    state changes), so a reset can only be the system remote ⏭ exhausting
                //    MusicKit's one-song queue — even if a pause was requested moments
                //    earlier (pause at 0:30 → car ⏭ → park at 0 with maxObserved 30).
                if maxObserved >= 2.0 { return .systemSkip }
                // 2. OUR OWN pause landed while the track was still near the top — the
                //    skip-storm-then-pause case. Sticky until resume/tryPlay clears it:
                //    a time-window here would just delay the phantom advance.
                if intentionalPause { return nil }
                // 3. Parked at the top from OUTSIDE with no progress to reset from — the
                //    car ⏭ pressed within the first seconds of the new track (rapid storm).
                return .systemSkip
            }
            return nil
        }
        return atEnd ? .natural : nil
    }

    /// Whether a still-PLAYING track was restarted from outside — the system remote ⏮,
    /// which iOS delivers to MusicKit itself: it rewinds its one-song queue to 0:00 with no
    /// state change we could observe. The signal is `playbackTime` (monotonic per item apart
    /// from seeks, all of which route through our `seek(to:)` and re-base `maxObserved`)
    /// making a hard backward jump to the top. Undetectable inside the first ~10 s —
    /// indistinguishable from MusicKit's laggy position reads — so an early ⏮ just restarts
    /// the song (Apple's own near-the-top ⏮ behavior anyway).
    nonisolated static func trackRestarted(playbackTime: Double, maxObserved: Double) -> Bool {
        playbackTime < 2.0 && maxObserved > 10.0
    }

    /// A `.stopped` that lands this far (seconds) short of the track's length is an
    /// interruption, not the natural end of the one-song queue.
    nonisolated(unsafe) static var interruptionGraceSeconds: Double = 10

    /// Whether a `.stopped` poll is an EXTERNAL INTERRUPTION rather than the end of the track.
    /// MusicKit reports both as `.stopped` (and resets `playbackTime`, so the position MusicKit
    /// reports can't tell them apart) — `playedSeconds` is OUR clock instead: the wall-clock
    /// play time (frozen across pauses, re-anchored on seeks) maxed with the highest observed
    /// `playbackTime`. A one-song queue that finished has played ~its whole length; a stream
    /// another player took over (Music.app driven by a same-Mac rip capture) has not. Unknown
    /// length ⇒ never an interruption (the old `.stopped` ⇒ ended rule stands).
    nonisolated static func stoppedByInterruption(stopped: Bool, expectedDuration: Double,
                                                  playedSeconds: Double) -> Bool {
        stopped && expectedDuration > 0 && playedSeconds < expectedDuration - interruptionGraceSeconds
    }

    /// Below this much movement (seconds) across one ~400 ms poll, a `playbackTime` re-read
    /// is noise — the SAME underlying value re-observed. At/above it, real audio has
    /// unambiguously kept advancing: a poll interval's worth of genuine playback is ~0.4 s,
    /// so this sits comfortably below that while staying well clear of rounding jitter.
    private static let selfHealEpsilonSeconds: Double = 0.25

    /// Ground truth for the self-heal check: ONLY real, ongoing playback can advance
    /// `playbackTime` — a genuinely paused/stopped player holds it still. So if
    /// `playbackStatus` reports NOT `.playing` but the position keeps moving anyway, the
    /// reported status — not the position — is the stale one.
    nonisolated static func advancedDespiteReportedPause(playbackTime: Double, lastPollPlaybackTime: Double) -> Bool {
        playbackTime - lastPollPlaybackTime > selfHealEpsilonSeconds
    }

    /// One tick of `startStateMonitor`'s play/pause reconciliation, extracted pure (like
    /// `trackEnded`/`endReason`/`trackRestarted` above) so the self-heal fix is unit-testable
    /// without a live MusicKit player.
    ///
    /// CONFIRMED FIELD BUG (session ios-3712BFDE, 2026-09-04): Levi streamed a 4,011-song
    /// collection over CarPlay; a rapid pause→resume→pause (system/CarPlay-originated, not
    /// one of our own action paths) left `player.state.playbackStatus` glued to reporting
    /// `.paused` for 3+ minutes — a known MusicKit staleness class — while the track was
    /// audibly still playing. The monitor mirrored that stale status into `isPlaying` with no
    /// cross-check, freezing the CarPlay/lock-screen card on `playing=false` until Levi
    /// manually paused/resumed to "retrigger it to be alive". `reallyPlaying` below is the
    /// fix: trust `playbackTime` actually advancing over a status that says otherwise.
    struct PollVerdict: Equatable {
        /// What `isPlaying` should become after this poll.
        var isPlaying: Bool
        /// Set only on a TRANSITION (`isPlaying` flipping) — nil on a steady-state poll,
        /// mirroring the monitor's original `if !self.isPlaying { … }` / `else if … self.isPlaying`
        /// guards, which only touch the clock/log on a change, never on every poll.
        var transition: Transition?
        /// The wall-clock anchor (seconds) to re-base the position clock from. Set exactly
        /// when `transition` is non-nil.
        var anchorTime: Double?
        enum Transition: Equatable {
            /// `selfHealed == true` ⇒ this is the frozen-false field bug self-correcting
            /// (status said NOT-playing, position proved otherwise); `false` ⇒ an ordinary
            /// external resume (status genuinely flipped to `.playing`).
            case resumed(selfHealed: Bool)
            case paused
        }
    }

    nonisolated static func reconcilePoll(reportedPlaying: Bool, currentlyPlaying: Bool,
                                          playbackTime: Double, lastPollPlaybackTime: Double) -> PollVerdict {
        // The self-heal check PREEMPTS the ordinary paused-status read: a status that claims
        // "paused" while the position keeps moving is the one that's wrong.
        let reallyPlaying = reportedPlaying ||
            advancedDespiteReportedPause(playbackTime: playbackTime, lastPollPlaybackTime: lastPollPlaybackTime)
        guard reallyPlaying != currentlyPlaying else {
            return PollVerdict(isPlaying: currentlyPlaying, transition: nil, anchorTime: nil)
        }
        return reallyPlaying
            ? PollVerdict(isPlaying: true, transition: .resumed(selfHealed: !reportedPlaying), anchorTime: playbackTime)
            : PollVerdict(isPlaying: false, transition: .paused, anchorTime: playbackTime)
    }
}

// ============================================================================
// MARK: - Real implementation (MusicKit)
// ============================================================================
#if canImport(MusicKit)
import MusicKit

@available(iOS 16.0, macOS 14.0, *)
extension AppleMusicPlaybackProvider {
    /// Enabled in this build AND the user has authorized MusicKit. (A subscription that
    /// can play catalog content is required for actual audio, but that surfaces as a
    /// failed `play()` rather than blocking the attempt — we still want Apple Music FIRST.)
    var isReady: Bool {
        AppleMusicCredentials.isEnabled && MusicAuthorization.currentStatus == .authorized
    }

    /// Current playback position (seconds) — drives the CarPlay/lock-screen card, the home deck,
    /// and the inline scrubber. Wall-clock-smoothed (see `positionBase`): while playing it's
    /// `base + wall-elapsed`, re-anchored on every start/resume/seek. This deliberately does NOT
    /// read the laggy `playbackTime` on each tick (that reset the OS's own extrapolation to a
    /// stale value → the frozen CarPlay bar); playback advances 1:1 with the wall clock, so the
    /// only divergence is a rare mid-song network stall, self-corrected on the next resume.
    var positionSeconds: Double {
        guard let start = positionStartWall else { return positionBase }
        return positionBase + Date().timeIntervalSince(start)
    }

    /// (Re)start the smooth clock from `seconds` — playback just started/resumed/seeked.
    private func startPositionClock(from seconds: Double) {
        positionBase = max(0, seconds)
        positionStartWall = Date()
    }
    /// Freeze the smooth clock at the current position — playback paused/stopped.
    private func freezePositionClock() {
        positionBase = positionSeconds
        positionStartWall = nil
    }

    /// `atMs` (spec §9 cue offset) is applied PLAY-THEN-SEEK: MusicKit exposes no "start
    /// at position" enqueue, so we start playback and then set
    /// `ApplicationMusicPlayer.playbackTime` (via the existing `seek(to:)`). DOCUMENTED
    /// IMPRECISION: the seek lands after playback has audibly started and the streaming
    /// player snaps to its own buffer boundaries, so the cue is accurate to roughly <1 s
    /// (vs. sample-exact for burned/ripped local files) — acceptable per spec §9.
    func tryPlay(_ song: IndexSong, atMs: Int?) async -> Bool {
        guard isReady else { return false }
        // SUPERSEDE GUARD (provider-level): a skip storm can leave an OLDER tryPlay parked at
        // one of the two network awaits below while a NEWER one already queued its song — the
        // stale one resuming would re-queue the OLD song over the new audio and stamp
        // `nowPlaying` with it. Claim a ticket at entry; after each await, a stale ticket
        // stands down (mirrors SetlistPlayer's playGeneration; both layers are needed because
        // the sequencer's cancel can land between this provider's suspension points).
        tryPlayGeneration &+= 1
        let ticket = tryPlayGeneration
        // The OLD track's end-monitor dies the moment a new play intent exists — NOT when the
        // new monitor arms after play() returns. In that gap our own `player.queue = [...]`
        // swap parks the player (transiently paused at 0), which a still-armed stale monitor
        // read as the system-skip artifact and double-advanced the set during skip storms
        // (debug capture 2026-08-20 12:13:42: "external PAUSE at 0s" mid-tryPlay).
        stateMonitor?.cancel(); stateMonitor = nil
        pauseWasIntentional = false
        interruptedAtSeconds = nil
        resumeRequestedAt = nil
        audioConfirmed = false
        interruptedResume.resetForTrack()
        do {
            let player = ApplicationMusicPlayer.shared
            let catalogSong: MusicKit.Song
            if let hit = prefetchCache.value(for: Self.prefetchKey(song), now: Date()) as? MusicKit.Song {
                // PRE-RESOLVED while the previous track played — no network before play().
                catalogSong = hit
                DiagLog.shared.log("playback", "am prefetch hit song=\(song.id)")
            } else {
                // 1) Resolve the song to a catalog track (namespaced `am:<id>` → direct fetch,
                //    else a title/artist search) and 2) fetch it by store id. A resolve miss →
                //    false → the engine falls back to rips.
                guard let fetched = try await fetchCatalogSong(song, ticket: ticket) else { return false }
                catalogSong = fetched
            }
            guard ticket == tryPlayGeneration else { return false }   // superseded mid-fetch
            do {
                player.queue = [catalogSong]
                try await player.play()
            } catch {
                // A skip storm's overlapping queue-swaps can make the NEWEST intent's play()
                // throw the transient MPMusicPlayerController queue-race (domain error 2) —
                // observed 2026-08-20 when the newest skip failed and let a stale one keep
                // the audio. One short retry keeps the stream on Apple Music instead of
                // dropping to the rip fallback; a superseded ticket stands down instead.
                guard ticket == tryPlayGeneration else { return false }
                try await Task.sleep(nanoseconds: 250_000_000)
                guard ticket == tryPlayGeneration else { return false }
                player.queue = [catalogSong]
                try await player.play()
            }
            // A stale tryPlay must not claim the win AFTER play() either: its play() can
            // succeed just before a newer call's queue-swap, and claiming nowPlaying/monitor
            // here resurrected the OLDER skip target over the newer one (Go Gina, 2026-08-20).
            guard ticket == tryPlayGeneration else { return false }
            // 3) Cue: `play()` has returned (playback started), so the position write
            //    sticks — a write before the queue item is ready would be ignored.
            if let atMs, atMs > 0 { seek(to: Double(atMs) / 1000) }
            isPlaying = true
            startPositionClock(from: atMs.map { Double($0) / 1000 } ?? 0)
            monitorMaxPlaybackTime = atMs.map { Double($0) / 1000 } ?? 0
            lastPollPlaybackTime = monitorMaxPlaybackTime
            durationSeconds = catalogSong.duration ?? 0
            currentQueueItem = catalogSong
            // Capture the catalog artwork URL — the app's own now-playing surfaces (home deck +
            // widget) can't get a cover from our art-less AM-Local catalog, so this is it.
            let artURL = catalogSong.artwork?.url(width: 600, height: 600)
            NPLog.trace("AM play title=\(song.name) dur=\(Int(durationSeconds)) artURL=\(artURL != nil)")
            nowPlaying = NowPlaying(songId: song.id, title: song.name, artist: song.artist,
                                    artworkURL: artURL)
            // 4) Arm the end-of-track monitor so the setlist advances when this streaming song
            //    finishes (nothing else observes MusicKit's player).
            startStateMonitor()
            return true
        } catch {
            // A real playback failure (e.g. no active subscription) — don't claim the win,
            // let the rip server fall back. The coordinator surfaces no error for this
            // (the fallback will), matching "first attempt is Apple Music; else rip".
            NPLog.trace("AM tryPlay FAILED title=\(song.name): \(error.localizedDescription)")
            prefetchCache.remove(Self.prefetchKey(song))   // never replay a bad pre-resolve
            return false
        }
    }

    /// The resolve chain: `provider.resolve` (catalog-id candidates / search) → the catalog
    /// `Song` by store id. nil = no stream for this row (resolve miss, empty fetch, or — with a
    /// `ticket` — superseded mid-resolve). Throws only from the catalog fetch.
    private func fetchCatalogSong(_ song: IndexSong, ticket: Int? = nil) async throws -> MusicKit.Song? {
        guard let track = await provider.resolve(song) else { return nil }
        if let ticket, ticket != tryPlayGeneration { return nil }   // superseded mid-resolve
        var req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(track.providerTrackID))
        req.limit = 1
        return try await req.response().items.first
    }

    /// Pre-resolve `songs` (the next rows that will stream from Apple Music) in the background,
    /// one at a time, so their `tryPlay` starts without a network round trip. Rows already
    /// cached or in flight are skipped; a miss simply leaves the row to resolve at its start.
    func prefetch(_ songs: [IndexSong]) {
        guard isReady else { return }
        let now = Date()
        let todo = songs.filter {
            let k = Self.prefetchKey($0)
            return prefetchCache.value(for: k, now: now) == nil && !prefetchInFlight.contains(k)
        }
        guard !todo.isEmpty else { return }
        for s in todo { prefetchInFlight.insert(Self.prefetchKey(s)) }
        Task { [weak self] in
            for song in todo {
                guard let self else { return }
                let key = Self.prefetchKey(song)
                let t0 = Date()
                let hit = try? await self.fetchCatalogSong(song)
                self.prefetchInFlight.remove(key)
                if let hit { self.prefetchCache.insert(hit, for: key, now: Date()) }
                DiagLog.shared.log("playback", "am prefetch song=\(song.id) ok=\(hit != nil ? 1 : 0) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            }
        }
    }

    func togglePlayPause() {
        let player = ApplicationMusicPlayer.shared
        if player.state.playbackStatus == .playing {
            pauseWasIntentional = true
            player.pause()
            isPlaying = false
            freezePositionClock()
        } else {
            pauseWasIntentional = false
            if resumeAfterInterruption() { return }
            isPlaying = true
            startPositionClock(from: positionSeconds)
            Task { try? await player.play() }
        }
    }

    /// ▶ on an INTERRUPTED stream: re-queue the track if the stopped player dropped it, play,
    /// and seek back to where the interruption landed. Returns false when not interrupted.
    private func resumeAfterInterruption() -> Bool {
        guard let at = interruptedAtSeconds else { return false }
        interruptedAtSeconds = nil
        resumeRequestedAt = (Date(), at)
        isPlaying = true
        startPositionClock(from: at)
        monitorMaxPlaybackTime = 0          // re-based from MusicKit's reads once it is back on air
        lastPollPlaybackTime = 0
        DiagLog.shared.log("playback", "am resume after interruption song=\(nowPlaying?.songId ?? "?") at=\(Int(at))s")
        let item = currentQueueItem as? MusicKit.Song
        Task {
            let player = ApplicationMusicPlayer.shared
            if player.state.playbackStatus == .stopped, let item { player.queue = [item] }
            try? await player.play()
            if at > 1 { player.playbackTime = at }
        }
        return true
    }

    /// Explicit resume/pause — used by the lock-screen / CarPlay remote play/pause commands,
    /// which must land in a KNOWN state (not toggle blindly off a possibly-stale status).
    func resume() {
        pauseWasIntentional = false
        if resumeAfterInterruption() { return }
        isPlaying = true
        startPositionClock(from: positionSeconds)
        Task { try? await ApplicationMusicPlayer.shared.play() }
    }
    func pausePlayback() {
        pauseWasIntentional = true
        ApplicationMusicPlayer.shared.pause()
        isPlaying = false
        freezePositionClock()
    }

    /// Seek the streaming player to an absolute position (seconds).
    func seek(to seconds: Double) {
        ApplicationMusicPlayer.shared.playbackTime = max(0, seconds)
        if positionStartWall != nil { startPositionClock(from: seconds) }   // playing → re-anchor
        else { positionBase = max(0, seconds) }                             // paused → hold
        // Re-base the ⏮-restart baseline: OUR OWN backward scrub must never read as a
        // system-⏮ backward jump (which would spuriously step the set back).
        monitorMaxPlaybackTime = max(0, seconds)
        // Re-base the self-heal baseline too: OUR OWN scrub jumps `playbackTime` by more than
        // one poll's worth in a single step, which — left unbased — the very next poll would
        // misread as "advanced despite reported pause" and wrongly self-heal a real pause.
        lastPollPlaybackTime = max(0, seconds)
    }

    func stop() {
        stateMonitor?.cancel(); stateMonitor = nil
        pauseWasIntentional = false
        interruptedAtSeconds = nil
        resumeRequestedAt = nil
        audioConfirmed = false
        interruptedResume.resetForTrack()
        currentQueueItem = nil
        ApplicationMusicPlayer.shared.stop()
        isPlaying = false
        positionBase = 0; positionStartWall = nil
        nowPlaying = nil
    }

    /// Poll `ApplicationMusicPlayer` — the SINGLE reconciliation loop for the streaming track.
    /// Four jobs, all needed because MusicKit is an OS-level player other UIs can drive:
    ///  1. STATE SYNC: the user can pause/resume from MusicKit's OWN system card (the macOS
    ///     menu-bar entry), which never calls our methods — so our `isPlaying` mirror and the
    ///     wall-clock position MUST follow the real `playbackStatus`, not just our own calls.
    ///  2. SELF-HEAL: `playbackStatus` can itself get STUCK reporting NOT-`.playing` while the
    ///     audio session keeps genuinely rendering — see `reconcilePoll`/`PollVerdict` for the
    ///     confirmed field bug this corrects (session ios-3712BFDE, 2026-09-04: the CarPlay
    ///     card froze on `playing=false` for 3+ minutes of audible playback).
    ///  3. END-OF-TRACK: the single-item queue finishes as `.stopped` (with a played-past-
    ///     duration backstop) → fire `onTrackEnded` ONCE so the setlist advances.
    ///  4. CLOCK ANCHORING: `playbackTime` is accurate ON state changes — re-anchor the smooth
    ///     wall-clock there so an externally-driven pause/resume can't drift the position.
    /// Superseded on the next `tryPlay`, cancelled on `stop`; ~0.4 s cadence is imperceptible.
    private func startStateMonitor() {
        stateMonitor?.cancel()
        let expected = durationSeconds
        stateMonitor = Task { [weak self] in
            let player = ApplicationMusicPlayer.shared
            var everPlayed = false
            var nearEndFired = false
            let armedAt = Date()
            var polls = 0
            var lastStatus: MusicPlayer.PlaybackStatus?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                let status = player.state.playbackStatus
                let t = player.playbackTime
                let reportedPlaying = status == .playing
                // Every STATUS TRANSITION (not only the 25-poll heartbeat): the drive logs could
                // not tell a user pause from a session interruption from a stall.
                if status != lastStatus {
                    DiagLog.shared.log("playback", "am status \(status) t=\(Int(t)) intentional=\(self.pauseWasIntentional ? 1 : 0) song=\(self.nowPlaying?.songId ?? "?")")
                    lastStatus = status
                }
                if reportedPlaying {
                    everPlayed = true
                    if !self.audioConfirmed { self.audioConfirmed = true; self.onFirstAudio?() }
                }
                // P1-8: interrupted (by a session fight), not paused — bounded auto-resume.
                if self.interruptedResume.observe(interrupted: status == .interrupted,
                                                  intentionalPause: self.pauseWasIntentional,
                                                  sessionInterrupted: self.sessionInterruptionOpen?() ?? false,
                                                  now: Date()) {
                    DiagLog.shared.log("playback", "am interrupted-by-session t=\(Int(t)) → auto-resume attempt=\(self.interruptedResume.attemptsThisEpisode) song=\(self.nowPlaying?.songId ?? "?")")
                    Task { try? await player.play() }
                }
                // OUR clock, read BEFORE the reconciliation below re-anchors it to MusicKit's
                // (reset-on-stop) `playbackTime` — the interruption verdict needs the real one.
                let wallPlayed = self.positionSeconds
                // `reallyPlaying` mirrors what `isPlaying` should be after this poll — either
                // the ordinary reported status, or (once we've genuinely played at least once)
                // the self-heal override when `playbackTime` keeps moving despite a reported
                // pause. `guard everPlayed` below preserves the original pre-roll behavior: do
                // nothing until the FIRST real `.playing` observation.
                var reallyPlaying = self.isPlaying
                if everPlayed {
                    let verdict = Self.reconcilePoll(reportedPlaying: reportedPlaying, currentlyPlaying: self.isPlaying,
                                                      playbackTime: t, lastPollPlaybackTime: self.lastPollPlaybackTime)
                    reallyPlaying = verdict.isPlaying
                    if let transition = verdict.transition, let anchor = verdict.anchorTime {
                        switch transition {
                        case .resumed(let selfHealed):
                            if selfHealed {
                                NPLog.trace("AM monitor: self-heal — playbackTime advanced " +
                                    "\(String(format: "%.1f", t - self.lastPollPlaybackTime))s while reported paused, correcting")
                            } else {
                                NPLog.trace("AM monitor: external RESUME at \(Int(anchor))s")
                            }
                            self.isPlaying = true
                            self.pauseWasIntentional = false   // the pause it marked is over
                            self.startPositionClock(from: anchor)
                        case .paused:
                            NPLog.trace("AM monitor: external PAUSE at \(Int(anchor))s")
                            self.isPlaying = false             // paused from OUTSIDE — freeze at
                            self.positionBase = anchor         // the exact (state-change) position
                            self.positionStartWall = nil
                        }
                    }
                }
                self.lastPollPlaybackTime = t
                // CARD DIAGNOSTIC (~every 10 s): MusicKit's OWN view of the clock — status, its
                // playbackRate and playbackTime — next to the smoothed position our impersonated
                // card publishes. iOS routes CarPlay's ⏭ to MusicKit's player, so if the head
                // unit's cursor freezes while our `card PUB` lines advance, this line shows
                // whether MusicKit's player (the other card source) reports itself stalled.
                polls += 1
                if polls % 25 == 0 {
                    NPLog.trace("AM clock status=\(status) mkRate=\(String(format: "%.2f", player.state.playbackRate)) "
                        + "mkTime=\(String(format: "%.1f", t)) smooth=\(String(format: "%.1f", self.positionSeconds)) "
                        + "playing=\(self.isPlaying)")
                }
                if Self.neverStarted(everPlayed: everPlayed, waitedSeconds: Date().timeIntervalSince(armedAt),
                                     intentionalPause: self.pauseWasIntentional) {
                    NPLog.trace("AM monitor: NEVER STARTED after \(Int(Date().timeIntervalSince(armedAt)))s (status=\(status)) → dead source")
                    DiagLog.shared.log("playback", "am never-started song=\(self.nowPlaying?.songId ?? "?") status=\(status)")
                    self.isPlaying = false
                    self.freezePositionClock()
                    self.stateMonitor = nil
                    self.onTrackEnded?(.neverStarted)
                    return
                }
                guard everPlayed else { continue }   // ignore the pre-roll before audio starts
                // INTERRUPTED, not ended: stopped far short of the track's length — another
                // player took over (on macOS, Music.app driven by a same-Mac rip capture). Hold
                // the row paused at the interruption point and keep watching; ▶ resumes there
                // (`resumeAfterInterruption`). Reading this as the end advanced the set, whose
                // next start queued another capture — the 2026-10-13 cascade.
                if let asked = self.resumeRequestedAt {
                    if reportedPlaying {
                        // Back on air. The reconciliation above anchored our clock to MusicKit's
                        // `playbackTime`, which can still read the re-queued item's 0:00 before
                        // the resume seek lands — keep it at the interruption point instead, or
                        // the natural end would later read as another interruption.
                        self.resumeRequestedAt = nil
                        let pos = max(t, asked.position)
                        self.startPositionClock(from: pos)
                        // ⏮-restart baseline restarts from what MusicKit actually reports, so a
                        // pre-seek 0:00 read can never look like a system ⏮ rewind.
                        self.monitorMaxPlaybackTime = t
                    } else if Date().timeIntervalSince(asked.at) < Self.startTimeoutSeconds {
                        continue                         // the resume is still spinning up
                    } else {                             // it never came back: interrupted again
                        self.resumeRequestedAt = nil
                        let at = asked.position
                        DiagLog.shared.log("playback", "am resume did not start song=\(self.nowPlaying?.songId ?? "?") → interrupted at=\(Int(at))s")
                        self.interruptedAtSeconds = at
                        self.isPlaying = false
                        self.positionBase = at; self.positionStartWall = nil
                        self.onInterrupted?()
                        continue
                    }
                }
                if let at = self.interruptedAtSeconds {
                    if reportedPlaying {                 // playing again (resumed from outside)
                        self.interruptedAtSeconds = nil
                    } else {
                        self.positionBase = at; self.positionStartWall = nil
                        continue
                    }
                } else if Self.stoppedByInterruption(stopped: status == .stopped && !reallyPlaying,
                                                     expectedDuration: expected,
                                                     playedSeconds: max(wallPlayed, self.monitorMaxPlaybackTime)) {
                    let at = max(wallPlayed, self.monitorMaxPlaybackTime)
                    NPLog.trace("AM monitor: INTERRUPTED at \(Int(at))s of \(Int(expected))s (status=\(status)) → hold, not end")
                    DiagLog.shared.log("playback", "am interrupted song=\(self.nowPlaying?.songId ?? "?") at=\(Int(at))s of \(Int(expected))s")
                    self.interruptedAtSeconds = at
                    self.isPlaying = false
                    self.positionBase = at; self.positionStartWall = nil
                    self.onInterrupted?()
                    continue
                }
                if t > self.monitorMaxPlaybackTime { self.monitorMaxPlaybackTime = t }
                if !nearEndFired, status == .playing,
                   Self.nearEnd(playbackTime: max(t, self.positionSeconds), expectedDuration: expected) {
                    nearEndFired = true
                    self.onNearEnd?()
                }
                // System remote ⏮ also lands in MusicKit (never our handler): it rewinds its
                // one-song queue to 0:00 while STAYING .playing — no state change to observe,
                // only the backward jump of the otherwise-monotonic playbackTime. Mirror the
                // in-app ⏮: step the set back one track.
                if status == .playing,
                   Self.trackRestarted(playbackTime: t, maxObserved: self.monitorMaxPlaybackTime) {
                    NPLog.trace("AM monitor: RESTART detected (t=\(Int(t)) max=\(Int(self.monitorMaxPlaybackTime))) → previous")
                    self.monitorMaxPlaybackTime = t
                    self.startPositionClock(from: t)
                    self.onTrackRestarted?()
                    continue
                }
                // `trackEnded` covers .stopped, played-past-duration, AND the system-skip
                // artifact (lock-screen/CarPlay ⏭ goes to MusicKit, which exhausts its
                // one-song queue and parks PAUSED at ~0 / the end — see the func doc). A
                // self-healed poll is proven to still be playing (`reallyPlaying`), so it must
                // NOT feed the raw (stale) `.paused`/`.stopped` status into this verdict — that
                // would misread genuine ongoing playback near the top of a track as a system
                // skip.
                if let reason = Self.endReason(stopped: status == .stopped && !reallyPlaying,
                                               paused: status == .paused && !reallyPlaying,
                                               playbackTime: t, expectedDuration: expected,
                                               maxObserved: self.monitorMaxPlaybackTime,
                                               intentionalPause: self.pauseWasIntentional) {
                    NPLog.trace("AM monitor: track ENDED reason=\(reason) (status=\(status) t=\(Int(t)) expected=\(Int(expected)))")
                    self.isPlaying = false
                    self.freezePositionClock()
                    self.stateMonitor = nil
                    self.onTrackEnded?(reason)
                    return
                }
            }
        }
    }
}

#else
// ============================================================================
// MARK: - Stub (MusicKit unavailable — keeps the module compiling everywhere)
// ============================================================================
extension AppleMusicPlaybackProvider {
    var isReady: Bool { false }
    var positionSeconds: Double { 0 }
    func tryPlay(_ song: IndexSong, atMs: Int?) async -> Bool { false }
    func prefetch(_ songs: [IndexSong]) {}
    func togglePlayPause() {}
    func resume() {}
    func pausePlayback() {}
    func seek(to seconds: Double) {}
    func stop() { stateMonitor?.cancel(); stateMonitor = nil; nowPlaying = nil }
}
#endif
