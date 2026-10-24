import Foundation
import AVFoundation

/// "KEEP PLAYING" SUPERVISOR — the setlist lane (docs/design/playback-bulletproof-plan.md §3).
///
/// A 1 Hz watchdog over the ONE invariant the drive logs kept breaking: *while the listener wants
/// the set playing, something is audibly playing.* Every tick it builds a `Probe` (who owns the
/// set's audio, what the listener last asked for, whether there is proof of sound) and feeds it to
/// the pure `Core`, which decides whether to log and which recovery step (if any) to take.
///
/// SAFETY RULES (the reason this is conservative):
///  - It NEVER acts while the listener paused (`intentPlaying == false`, `userPaused`), while an
///    audio-session interruption is open (a call / Siri), on a HELD restore (restores never set
///    intent), or after the cascade breaker halted the set. A genuine user pause is never un-paused.
///  - It does NOT FIGHT THE START WATCHDOG. A track start (load → first audio) is owned by
///    `SetlistPlayer`'s start window (runway + 8 s re-kick / 20 s escalate). While that window is
///    open (`startPending`) the supervisor only COUNTS dead air; its ladder clock starts once the
///    window closes. Its own L2 ("retry this row in place") re-opens a start window, which hands
///    the row back to the start watchdog — so escalation past a re-resolve (hop to an on-device row
///    / advance through the `AutoAdvanceCascadeBreaker`) is owned by ONE place for track starts.
///    The supervisor's own L3 only runs if the retry never opened a start window.
///  - Apple Music is DETECTOR-ONLY here: the provider owns AM recovery (its never-started dead-source
///    advance and the bounded `.interrupted` auto-resume), and a MusicKit `.paused` can be a pause
///    from its own system card that we never saw — re-starting it would override the listener.
///  - A track that already signalled its end is detector-only: the sequencer's advance owns it.
///
/// Ladder (timers reset on proof; anchored when the start window closes):
///   L0 silent → log · L1 @3 s re-kick in place · L2 @+12 s retry the row in place (fresh resolve at
///   the current position) · L3 @+8 s escalate (hop / advance via the breaker).
/// Every 60 s with dead air it logs the running `dead-air total`.
@MainActor
final class PlaybackSupervisor {
    // MARK: Pure core (table-driven unit tests drive this with a fake clock)

    struct Probe: Equatable {
        enum Lane: String { case idle, local, appleMusic }
        var lane: Lane = .idle
        /// The listener's last request was "play" (set only by gestures / a resumed interruption).
        var intentPlaying = false
        /// The current item was paused ON PURPOSE (local `pausedByListener`; AM intentional pause).
        var userPaused = false
        var interruptionOpen = false
        var held = false
        var cascadeHalted = false
        /// A track start window is open (owned by the start watchdog).
        var startPending = false
        /// The current item already signalled its end (the sequencer's advance owns it).
        var trackEnded = false
        /// Proof of sound this tick (local: `.playing` AND the clock advanced; AM: confirmed playing).
        var audible = false
        var songId: String?
    }

    enum Action: Equatable { case rekick, retryInPlace, escalate }

    struct Core {
        static var l1Seconds: Double = 3
        static var l2Seconds: Double = 12
        static var l3Seconds: Double = 8
        /// L2 retries allowed per song before the ladder goes straight to escalation.
        static var maxRetriesPerSong = 2
        static var reportWindowSeconds: Double = 60

        private(set) var silentSince: Date?
        private(set) var ladderAnchor: Date?
        private(set) var stage = 0
        private(set) var deadAirTotal: Double = 0
        /// Seconds the lane was ENGAGED (listener wants sound, lane owned) — dead air's denominator.
        private(set) var activeTotal: Double = 0
        /// The share of `deadAirTotal` spent inside a track start / after the track ended.
        private(set) var transitionDeadTotal: Double = 0
        private var windowDeadAir: Double = 0
        private var windowStart: Date?
        private var lastTick: Date?
        private var haltedLogged = false
        private var retries: [String: Int] = [:]

        /// One tick. Returns the action to take (nil = none) and the `[supervisor]` lines to log.
        mutating func step(_ p: Probe, now: Date) -> (action: Action?, lines: [String]) {
            var lines: [String] = []
            let dt = lastTick.map { min(max(0, now.timeIntervalSince($0)), 5) } ?? 0
            lastTick = now
            if windowStart == nil { windowStart = now }
            if let ws = windowStart, now.timeIntervalSince(ws) >= Self.reportWindowSeconds {
                if windowDeadAir >= 1 {
                    lines.append("dead-air total=\(Int(deadAirTotal.rounded()))s last60=\(Int(windowDeadAir.rounded()))s")
                }
                windowDeadAir = 0
                windowStart = now
            }
            let engaged = p.lane != .idle && p.intentPlaying && !p.userPaused && !p.held && !p.interruptionOpen
            guard engaged else { reset(); haltedLogged = false; return (nil, lines) }
            if p.cascadeHalted {
                if !haltedLogged {
                    lines.append("halted lane=\(p.lane.rawValue) song=\(p.songId ?? "?") (cascade breaker) — holding")
                    haltedLogged = true
                }
                reset()
                return (nil, lines)
            }
            haltedLogged = false
            activeTotal += dt
            if p.audible {
                if let s = silentSince {
                    lines.append("ok after=\(Int(now.timeIntervalSince(s).rounded()))s lane=\(p.lane.rawValue) stage=L\(stage)")
                }
                reset()
                return (nil, lines)
            }
            // SILENT while the listener wants sound — dead air.
            deadAirTotal += dt
            windowDeadAir += dt
            if p.startPending || p.trackEnded { transitionDeadTotal += dt }
            if silentSince == nil {
                silentSince = now
                lines.append("silent owner=\(p.lane == .appleMusic ? "AppleMusic" : "PlayerEngine") lane=\(p.lane.rawValue) "
                             + "song=\(p.songId ?? "?") since=0s startPending=\(p.startPending ? 1 : 0) ended=\(p.trackEnded ? 1 : 0)")
            }
            // Detector-only states: the start watchdog / sequencer / AM provider own these.
            if p.startPending || p.trackEnded || p.lane == .appleMusic {
                ladderAnchor = nil
                stage = 0
                return (nil, lines)
            }
            if ladderAnchor == nil { ladderAnchor = now }
            let elapsed = now.timeIntervalSince(ladderAnchor!)
            let since = Int(now.timeIntervalSince(silentSince!).rounded())
            let song = p.songId ?? "?"
            if stage == 0, elapsed >= Self.l1Seconds {
                stage = 1
                lines.append("step=L1 action=rekick song=\(song) silent=\(since)s")
                return (.rekick, lines)
            }
            if stage == 1, elapsed >= Self.l1Seconds + Self.l2Seconds {
                stage = 2
                let n = retries[song, default: 0]
                if n < Self.maxRetriesPerSong {
                    retries[song] = n + 1
                    lines.append("step=L2 action=retryInPlace song=\(song) silent=\(since)s retry=\(n + 1)")
                    return (.retryInPlace, lines)
                }
                stage = 3
                lines.append("step=L3 action=escalate song=\(song) silent=\(since)s (retries exhausted)")
                return (.escalate, lines)
            }
            if stage == 2, elapsed >= Self.l1Seconds + Self.l2Seconds + Self.l3Seconds {
                stage = 3
                lines.append("step=L3 action=escalate song=\(song) silent=\(since)s")
                return (.escalate, lines)
            }
            return (nil, lines)
        }

        private mutating func reset() {
            silentSince = nil
            ladderAnchor = nil
            stage = 0
        }
    }

    // MARK: Shell (live engines → probe; actions → engines)

    /// Builds the tick's probe. Injected so tests can drive the shell with stubs.
    var probe: () -> Probe
    var perform: (Action) -> Void
    var now: () -> Date = Date.init
    var log: (String) -> Void = { DiagLog.shared.log("supervisor", $0) }
    private(set) var core = Core()
    private var ticker: Task<Void, Never>?
    /// Actions taken (diagnostics + tests).
    private(set) var actionsTaken: [Action] = []
    /// Where each tick's active / dead seconds roll up (nil in shell tests).
    var meter: DeadAirMeter?

    init(probe: @escaping () -> Probe, perform: @escaping (Action) -> Void) {
        self.probe = probe
        self.perform = perform
    }

    /// The production wiring: the setlist lane over the real sequencer / engine / AM provider.
    convenience init(setlist: SetlistPlayer, player: PlayerEngine, coordinator: PlaybackCoordinator) {
        var lastLocalTime: Double = -1
        self.init(probe: { [weak setlist, weak player, weak coordinator] in
            guard let setlist, let player, let coordinator else { return Probe() }
            var p = Probe()
            p.songId = setlist.currentSongId
            p.held = setlist.isHeldForResume
            p.cascadeHalted = setlist.pausedByCascade
            p.startPending = setlist.isStartPending
            p.interruptionOpen = player.interruptionOpen
            p.intentPlaying = player.listenerIntentPlaying
            // Another engine (a Mix the listener started) owns the card ⇒ the listener moved on;
            // the setlist lane is not ours to "keep playing". The DSP hand-off is not supervised.
            let owner = NowPlayingArbiter.shared.owner
            guard setlist.isRunning, !setlist.mixEngaged, owner == nil || owner === player else {
                lastLocalTime = -1; return p
            }
            if coordinator.activeBackend == .appleMusic {
                p.lane = .appleMusic
                p.userPaused = coordinator.appleMusic.pauseIsIntentional
                p.audible = coordinator.appleMusic.isPlaying && coordinator.appleMusic.audioConfirmed
                lastLocalTime = -1
            } else {
                p.lane = .local
                p.userPaused = player.pausedByListener
                p.trackEnded = player.trackEndAlreadySignaled
                let t = player.currentTime
                p.audible = player.timeControlStatus == .playing && lastLocalTime >= 0 && abs(t - lastLocalTime) > 0.1
                lastLocalTime = t
            }
            return p
        }, perform: { [weak setlist, weak player] action in
            switch action {
            case .rekick: player?.rekick(by: "supervisor.L1")
            case .retryInPlace: setlist?.supervisorRetryInPlace()
            case .escalate: setlist?.supervisorEscalate()
            }
        })
        meter = .shared
    }

    func start() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func stopTicking() { ticker?.cancel(); ticker = nil }

    /// One supervisor beat (the ticker calls this at 1 Hz; tests call it directly).
    func tick() {
        let p = probe()
        let at = now()
        let before = (core.activeTotal, core.deadAirTotal, core.transitionDeadTotal)
        let (action, lines) = core.step(p, now: at)
        for l in lines { log(l) }
        if let meter {
            meter.accumulate(active: core.activeTotal - before.0, dead: core.deadAirTotal - before.1,
                             transitionDead: core.transitionDeadTotal - before.2, now: at)
            // The listener paused / a call / a held restore mid-start: that silence is theirs.
            if !p.intentPlaying || p.userPaused || p.held || p.interruptionOpen {
                meter.transitionAbandoned(reason: p.interruptionOpen ? "interruption" : p.held ? "held" : "paused")
            }
        }
        if let action {
            actionsTaken.append(action)
            perform(action)
        }
    }
}
