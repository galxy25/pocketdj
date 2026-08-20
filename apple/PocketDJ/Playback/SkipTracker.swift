import Foundation
import Observation

/// Classifies each playback as SKIPPED or not — the one place the "<50% played" rule lives, so
/// the playback engines stay hook-shaped (SetlistPlayer only reports *what happened*; the
/// verdict is decided here).
///
/// ── THE RULE ────────────────────────────────────────────────────────────────────────────────
/// A playback counts as a SKIP when the user ADVANCES AWAY from the track (in-app ⏭,
/// remote/CarPlay ⏭ including the Apple-Music `systemSkip` end reason, jumping to another row,
/// or replacing the running set with a fresh play) with LESS THAN HALF of it played
/// (position / duration < 0.5, STRICT — exactly 50% is not a skip). Everything else — natural
/// end, repeat-one replay, per-track repeat, the setlist length-boundary auto-advance, a
/// dead-source auto-advance, pause, explicit stop, app quit — is NOT a skip, and those paths
/// simply never call `noteAdvanceAway`.
///
/// ── LIFECYCLE ───────────────────────────────────────────────────────────────────────────────
/// `PlayHistoryStore.onRecord` (the one choke point every play surface funnels through) calls
/// `noteTrackStarted` with the freshly-appended event — `currentEventId` is therefore also the
/// History view's "live row" key. The SetlistPlayer's ~1 Hz ticker feeds `samplePosition`, and
/// its advance-away call sites report `noteAdvanceAway`. A skip verdict marks the history event
/// (`PlayHistoryStore.markSkipped`) and bumps the cumulative per-song total (`noteSkip`, wired
/// to `PlayCountService.noteSkipped`).
///
/// ── WHY THE ONE-DEEP `previous` STASH EXISTS (the adopt ordering) ──────────────────────────
/// A row ▶ over a running set is SYNCHRONOUS: the provider stamps now-playing → `onPlay` →
/// `record` → `onRecord` → `noteTrackStarted(NEW event)` — all before the adopt observer's
/// deferred main-actor task runs `adoptNowPlayingIfJumped`, whose `noteAdvanceAway(OLD song)`
/// therefore arrives with the tracker already re-armed on the NEW track. Dropping that verdict
/// silently lost every "jumped to another row" skip. So arming a new track STASHES the one it
/// replaces (event id + samples + classified latch, exactly one deep); a late advance-away that
/// doesn't match the current track classifies the stashed one instead. The stash dies at the
/// next arm — a verdict can only ever be one track late.
///
/// ── WHY THE HIGH-WATER MARK EXISTS (load-bearing twice) ────────────────────────────────────
/// 1. The Apple-Music `systemSkip` detection tick clobbers the provider's position clock to ~0
///    BEFORE the end callback fires, so the live position read at advance-away time lies. The
///    ticker-fed max retains the true position without touching the provider (which a
///    concurrent branch owns).
/// 2. The adopt path (`adoptNowPlayingIfJumped`) fires AFTER the new play already re-stamped
///    now-playing — the old track's clock is gone; `positionMs: nil` falls back to the samples.
/// Bias after a seek-back is toward NOT-skip — the conservative direction (a false "skip" would
/// demote a song the listener actually played).
@MainActor
@Observable
final class SkipTracker {

    /// The history event id of the CURRENTLY-PLAYING track — observable on purpose: this is the
    /// key HistoryView's live "playing now" indicator matches rows against.
    private(set) var currentEventId: UUID?
    /// The song id of the current track, exactly as recorded in history (a base id in every
    /// real path — the play hooks normalize before recording).
    private(set) var currentSongId: String?

    /// True once this playback has been classified — a second advance-away for the same event
    /// (e.g. a jump racing a fresh play) must not double-count.
    @ObservationIgnored private var classified = false
    /// High-water playback position (ms) for the current track, fed ~1 Hz by the ticker.
    @ObservationIgnored private var maxPositionMs = 0
    /// Last duration (ms) the ticker knew for the current track; nil until one arrives.
    @ObservationIgnored private var lastKnownDurationMs: Int?

    /// The track the current one REPLACED — the adopt path's late verdict lands here (see the
    /// class doc). One deep on purpose: a verdict more than one track late is a bug upstream,
    /// and holding a chain would let a stale hook classify ancient history.
    private struct PreviousTrack {
        let eventId: UUID
        let songId: String
        var classified: Bool
        let maxPositionMs: Int
        let lastKnownDurationMs: Int?
    }
    @ObservationIgnored private var previous: PreviousTrack?

    /// The history log the skip flag is written into. Weak: both are app-scoped, but the
    /// tracker must never keep the store alive in tests.
    @ObservationIgnored weak var history: PlayHistoryStore?
    /// Cumulative-count sink, wired at app init to `PlayCountService.noteSkipped`.
    @ObservationIgnored var noteSkip: ((String) -> Void)?

    /// A new track started (the history event was just appended). Stashes the replaced track
    /// (a jump's advance-away arrives AFTER this — the adopt ordering, see the class doc),
    /// then resets classification state for the new one.
    func noteTrackStarted(_ event: PlayHistoryStore.PlayEvent) {
        arm(eventId: event.id, songId: event.songId, classified: false)
    }

    /// The live playback moved onto an EXISTING history event — the 30 s re-count window
    /// collapsed a replay into the row it already wrote (`PlayHistoryStore.onResume`). Without
    /// this the tracker stayed armed on whatever played in between, so History's live indicator
    /// sat on the WRONG row for up to 30 s. Re-arms exactly like a start — fresh high-water
    /// mark (the replay starts from 0:00) — except an already-skipped event resumes CLASSIFIED:
    /// its verdict is spent, and a second skip of the same collapsed listen must not double the
    /// cumulative count.
    func noteTrackResumed(_ event: PlayHistoryStore.PlayEvent) {
        arm(eventId: event.id, songId: event.songId, classified: event.wasSkipped == true)
    }

    /// The CURRENT track restarted from 0:00 with no new history record — repeat-one, a
    /// per-track repeat pass, a duplicate consecutive row of the same song, a same-song
    /// play-now (the rip path dedupes same-id now-playing, so no `onPlay`/`record` fires).
    /// Re-zeroes the high-water mark: without this, pass 1's peak shielded a genuine ⏭ during
    /// the replay (`max(live, mark)` read ≥ 50% forever). Any other song id is a stale signal
    /// racing a track change — dropped, same discipline as `samplePosition`.
    func noteTrackRestarted(songId: String) {
        guard let current = currentSongId,
              SongVariant.baseId(songId) == SongVariant.baseId(current) else { return }
        maxPositionMs = 0
    }

    /// Point the tracker at `eventId`/`songId`, stashing the track it replaces. A re-arm on
    /// the SAME event (the burned-play double-hook collapsing rips + coordinator onto one
    /// record) must keep the existing stash — overwriting it with ourselves would lose the
    /// real previous track while its adopt verdict is still in flight.
    private func arm(eventId: UUID, songId: String, classified: Bool) {
        if let eid = currentEventId, let sid = currentSongId, eid != eventId {
            previous = PreviousTrack(eventId: eid, songId: sid, classified: self.classified,
                                     maxPositionMs: maxPositionMs,
                                     lastKnownDurationMs: lastKnownDurationMs)
        }
        currentEventId = eventId
        currentSongId = songId
        self.classified = classified
        maxPositionMs = 0
        lastKnownDurationMs = nil
    }

    /// ~1 Hz position sample for the current track (rides the SetlistPlayer ticker). Samples
    /// for any OTHER song are dropped — a stale tick racing a track change must not pollute
    /// the new track's high-water mark.
    func samplePosition(songId: String, positionMs: Int, durationMs: Int?) {
        guard let current = currentSongId,
              SongVariant.baseId(songId) == SongVariant.baseId(current) else { return }
        maxPositionMs = max(maxPositionMs, positionMs)
        if let durationMs, durationMs > 0 { lastKnownDurationMs = durationMs }
    }

    /// The user advanced away from `songId`. `positionMs` nil = "the clock is already gone,
    /// use your samples" (the adopt path). Applies the <50% rule; unknown duration ⇒ NOT a
    /// skip (never guess against the listener).
    ///
    /// The CURRENT track is checked first; a report that doesn't match it falls through to the
    /// one-deep `previous` stash — the adopt path's verdict, which arrives after the new play's
    /// record already re-armed the tracker (see the class doc). Anything matching neither is a
    /// stale hook racing across two track changes — dropped.
    func noteAdvanceAway(songId: String, positionMs: Int?, durationMs: Int?) {
        let base = SongVariant.baseId(songId)
        if let current = currentSongId, SongVariant.baseId(current) == base {
            guard let eid = currentEventId, !classified else { return }
            classified = true
            classify(eventId: eid, songId: current,
                     positionMs: max(positionMs ?? 0, maxPositionMs),
                     durationMs: durationMs ?? lastKnownDurationMs)
            return
        }
        if var prev = previous, SongVariant.baseId(prev.songId) == base, !prev.classified {
            prev.classified = true
            previous = prev
            classify(eventId: prev.eventId, songId: prev.songId,
                     positionMs: max(positionMs ?? 0, prev.maxPositionMs),
                     durationMs: durationMs ?? prev.lastKnownDurationMs)
        }
    }

    /// The <50% rule itself, shared by the current-track and stashed-previous verdicts. The
    /// high-water mark beats a clobbered/vanished live read; a live read past the mark (a seek
    /// forward between ticks) beats the mark — callers pass the max of the two.
    private func classify(eventId: UUID, songId: String, positionMs: Int, durationMs: Int?) {
        guard let dur = durationMs, dur > 0 else { return }
        guard Double(positionMs) / Double(dur) < 0.5 else { return }
        history?.markSkipped(eventId: eventId)
        noteSkip?(songId)
    }
}
