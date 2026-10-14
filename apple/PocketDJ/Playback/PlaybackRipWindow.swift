import Foundation

/// The RIP-AHEAD WINDOW of a playback session (Levi, 2026-10-13: "in this case we should only
/// stream ahead say the next 10 songs").
///
/// Field report: "Potential" on shuffle, macOS, rip server on the SAME Mac. Every track start
/// queued a rip; the server's live capture drove Music.app, which interrupted the app's own
/// Apple Music stream; the set read that as the end of the song (or a dead source) and
/// advanced, which queued another rip — the server was left with a long capture queue for
/// songs nobody heard, while no music played.
///
/// The rule: a PLAYBACK-originated rip (the passive rip on an Apple Music start, the
/// stream-through rip of the rip fallback, an edition lazy-rip) may only be requested for the
/// playing row and the next `ahead` rows. Every such id this session actually got QUEUED is
/// tracked here; when the playhead moves, the queue is reshuffled/edited, or the session
/// stops/is replaced, the tracked ids that fell out of the window are cancelled on the server
/// (`POST /rip-cancel`) — except:
///   • the playing row (it is what the listener hears right now),
///   • a row the listener actually HEARD (≥ `heardSeconds` of audible playback) — that is the
///     legitimate passive rip of a song they listened to, and cancelling it would quietly turn
///     passive ripping off for anyone whose server is busier than real time,
///   • anything a USER surface asked for (collection Rip / Rip+Burn / recognizer add) — the
///     caller filters those out, this type never sees the difference.
///
/// Pure value type so the bookkeeping is unit-testable without a server or a player.
struct PlaybackRipWindow: Equatable {
    /// How many rows AFTER the playing one may have a playback rip requested.
    static let ahead = 10
    /// Audible seconds after which a row counts as heard (its rip is never cancelled).
    static let heardSeconds: Double = 30

    /// Rip ids (base or variant song ids, exactly as POSTed) this session got queued and may
    /// still cancel.
    private(set) var requested: Set<String> = []

    /// The ids inside the window for a queue at `index`: the playing row + the next `ahead`.
    /// Each row contributes BOTH its base id and its resolve id (a substituted row rips under
    /// its variant id, the passive rip under the projected id — either may be what was POSTed).
    static func windowIds(rows: [(id: String, resolveId: String)], index: Int) -> Set<String> {
        guard index >= 0, index < rows.count else { return [] }
        var out = Set<String>()
        for r in rows[index..<min(rows.count, index + 1 + ahead)] {
            out.insert(r.id); out.insert(r.resolveId)
        }
        return out
    }

    /// Whether a playback rip for `id` may be requested at all right now.
    static func allows(_ id: String, rows: [(id: String, resolveId: String)], index: Int) -> Bool {
        windowIds(rows: rows, index: index).contains(id)
    }

    /// This session got `id` queued on the server.
    mutating func record(_ id: String) { requested.insert(id) }

    /// The listener heard `ids` (one row's base + resolve id): never cancel their rips.
    mutating func keep(_ ids: Set<String>) { requested.subtract(ids) }

    /// Drop and RETURN every tracked id outside `window` (the playing row is always inside it).
    /// The caller cancels what comes back.
    mutating func evict(keeping window: Set<String>) -> [String] {
        let out = requested.subtracting(window)
        requested.subtract(out)
        return out.sorted()
    }

    /// The session ends (stop, or a fresh `play` replacing it): drop and RETURN everything
    /// tracked except `playing` (the row that was sounding — leave its rip alone).
    mutating func endSession(playing: Set<String>) -> [String] {
        let out = requested.subtracting(playing)
        requested = []
        return out.sorted()
    }
}

/// The AUTO-ADVANCE CASCADE BREAKER. When the sequencer auto-advances (dead source, an Apple
/// Music stream that ended/never started, a failed item) several times IN A ROW and none of
/// those tracks produced real audio, something outside the queue is wrong — an interrupted
/// Apple Music session, a server that can't deliver — and advancing again just burns through
/// the queue (and, before the rip window, the rip server's queue too). Stop instead: pause on
/// the current row, keep the queue position, tell the listener.
///
/// Any user transport (⏭, ⏮, jump, play-now, ▶) or a track that DID play resets it.
struct AutoAdvanceCascadeBreaker: Equatable {
    /// Consecutive quick auto-advances that trip the breaker (the Nth is not performed).
    static let limit = 3
    /// Audible seconds below which an auto-advanced track counts as "quick" (never heard).
    static let minAudibleSeconds: Double = 5

    private(set) var quickAdvances = 0

    /// An auto-advance is about to happen off a track that played `audibleSeconds`. Returns
    /// true when the breaker TRIPS: the caller must not advance.
    mutating func shouldHalt(afterAudibleSeconds audibleSeconds: Double) -> Bool {
        guard audibleSeconds < Self.minAudibleSeconds else { quickAdvances = 0; return false }
        quickAdvances += 1
        if quickAdvances >= Self.limit { quickAdvances = 0; return true }
        return false
    }

    /// The listener acted (or a track played properly) — the run is no longer a cascade.
    mutating func reset() { quickAdvances = 0 }
}
