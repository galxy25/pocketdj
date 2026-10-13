import Foundation

/// IN THE POCKET — the round outcome state machine. PURE: what the play-history log says happened
/// since ▶ (plus whether the sequencer still runs this round, and the clock) → each song's state
/// and the round's verdict.
///
/// It deliberately invents NO skip detection of its own. Every verdict comes from the app's one
/// skip machinery — `SkipTracker` (the "<50% played when you ADVANCED AWAY" rule; pause, stop,
/// natural end, ⏮ are never skips) writing `wasSkipped` / `listenedFraction` onto the
/// `PlayHistoryStore` events every play surface records. That is why the round keeps tracking
/// when the player leaves the game screen: the log keeps being written, and this is a function
/// of the log.
///
/// THE RULES (song k of n, in order):
///   · Song k STARTS when the next history event (after ▶) is song k. An event for a song the
///     round already played (⏮, a replay) is ignored. Any OTHER song is FOREIGN: the player
///     moved on.
///   · A song is SKIPPED when its event carries the skip verdict. Skips are final (the flag only
///     goes false → true), so the first one decides the round at once: "Broke at song k".
///   · A song is COMPLETED when a later round song started and it was not skipped (the next start
///     is what `SkipTracker` classifies on), or when its played fraction reaches 90 %, or — once
///     the round has ENDED (foreign play / the sequencer stopped running it / idle timeout) —
///     when it reached 50 %, or its fraction is unknown (an unknown is a play, as in pocket
///     detection).
///   · All n completed → IN THE POCKET.
///   · Ended with a song neither completed nor skipped, or before song 1 → ABANDONED.
///
/// SETTLING: a skip verdict can land up to ONE track late (the adopt path classifies the old track
/// after the new one is already recorded — see `SkipTracker`), and the last song's fraction is
/// reported by the stop checkpoint just AFTER the sequencer stops. So an end signal only counts
/// once it is `settleMs` old; until then the round stays in progress and the next evaluation
/// sees the late verdict.
enum InThePocketRoundEvaluator {

    /// One history event, reduced.
    struct Observation: Equatable {
        var eventId: UUID
        var songId: String
        var playedAtMs: Double
        var wasSkipped: Bool
        var fraction: Double?

        init(eventId: UUID, songId: String, playedAtMs: Double, wasSkipped: Bool, fraction: Double?) {
            self.eventId = eventId; self.songId = songId; self.playedAtMs = playedAtMs
            self.wasSkipped = wasSkipped; self.fraction = fraction
        }

        init(_ e: PlayHistoryStore.PlayEvent) {
            self.init(eventId: e.id, songId: e.songId, playedAtMs: e.playedAt,
                      wasSkipped: e.wasSkipped == true, fraction: e.listenedFraction)
        }
    }

    struct Verdict: Equatable {
        var states: [InThePocketSongState]
        var eventIds: [UUID?]
        var fractions: [Double?]
        /// nil = still in progress.
        var outcome: InThePocketOutcome?
        /// Index of the song playing now (nil before song 1 / after the end).
        var currentIndex: Int?
    }

    static let completeFraction = 0.9
    static let playedThroughFraction = 0.5
    /// How old an end signal must be before it ends the round (see SETTLING).
    static let settleMs: Double = 8_000
    /// No round activity for this long (a long pause, a forgotten round) → abandoned.
    static let idleTimeoutMs: Double = 3 * 3_600_000
    /// ▶ is pressed a beat before the first `record` — events this close before it still count.
    static let startToleranceMs: Double = 2_000

    /// - Parameters:
    ///   - songIds: the round's songs, in order.
    ///   - events: this install's history events (any order; filtered + sorted here).
    ///   - ownershipLostAtMs: when the sequencer stopped running THIS round (nil = still does).
    static func evaluate(songIds: [String], startedAtMs: Double, events: [Observation],
                         ownershipLostAtMs: Double?, nowMs: Double) -> Verdict {
        let n = songIds.count
        let base = songIds.map { SongVariant.baseId($0) }
        let after = events.filter { $0.playedAtMs >= startedAtMs - startToleranceMs }
            .sorted { $0.playedAtMs != $1.playedAtMs ? $0.playedAtMs < $1.playedAtMs
                      : $0.eventId.uuidString < $1.eventId.uuidString }

        var matched: [Observation?] = Array(repeating: nil, count: n)
        var cursor = 0
        var foreignAtMs: Double?
        var lastActivityMs = startedAtMs
        for e in after {
            let id = SongVariant.baseId(e.songId)
            if cursor < n, id == base[cursor] {
                matched[cursor] = e
                cursor += 1
                lastActivityMs = max(lastActivityMs, e.playedAtMs)
            } else if base[..<cursor].contains(id) {
                lastActivityMs = max(lastActivityMs, e.playedAtMs)   // ⏮ / a replay — not foreign
            } else {
                foreignAtMs = e.playedAtMs
                break
            }
        }

        let endSignal = [foreignAtMs, ownershipLostAtMs].compactMap { $0 }.min()
        let ended = endSignal.map { nowMs - $0 >= settleMs } ?? false
        let timedOut = nowMs - lastActivityMs >= idleTimeoutMs
        let over = ended || timedOut

        var states = Array(repeating: InThePocketSongState.pending, count: n)
        for k in 0..<cursor {
            guard let e = matched[k] else { continue }
            if e.wasSkipped { states[k] = .skipped; continue }
            if k < cursor - 1 { states[k] = .completed; continue }
            // The latest-started song.
            if let f = e.fraction, f >= completeFraction { states[k] = .completed; continue }
            if over {
                if let f = e.fraction {
                    states[k] = f >= playedThroughFraction ? .completed : .playing
                } else if foreignAtMs != nil || timedOut {
                    states[k] = .completed   // unknown is a play (pocket detection's rule)
                } else {
                    states[k] = .playing     // the stop checkpoint hasn't landed — never guess "done"
                }
            } else {
                states[k] = .playing
            }
        }

        var outcome: InThePocketOutcome?
        if let k = states.firstIndex(of: .skipped) {
            outcome = .broke(at: k + 1)
        } else if n > 0, states.allSatisfy({ $0 == .completed }) {
            outcome = .pocket
        } else if over {
            // The stop checkpoint can lag the stop itself: an ended round whose last song has no
            // fraction yet waits (bounded by the idle timeout) rather than calling it abandoned.
            let waitingOnCheckpoint = !timedOut && foreignAtMs == nil && cursor > 0
                && matched[cursor - 1]?.fraction == nil
            if !waitingOnCheckpoint { outcome = .abandoned }
        }
        if outcome != nil {
            for k in states.indices where states[k] == .pending { states[k] = .notPlayed }
        }
        let current = outcome == nil && cursor > 0 && states[cursor - 1] == .playing ? cursor - 1 : nil
        return Verdict(states: states, eventIds: matched.map { $0?.eventId },
                       fractions: matched.map { $0?.fraction }, outcome: outcome, currentIndex: current)
    }
}
