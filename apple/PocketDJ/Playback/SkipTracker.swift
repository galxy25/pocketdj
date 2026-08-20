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

    /// The history log the skip flag is written into. Weak: both are app-scoped, but the
    /// tracker must never keep the store alive in tests.
    @ObservationIgnored weak var history: PlayHistoryStore?
    /// Cumulative-count sink, wired at app init to `PlayCountService.noteSkipped`.
    @ObservationIgnored var noteSkip: ((String) -> Void)?

    /// A new track started (the history event was just appended). Resets classification state;
    /// the previous track's verdict — if any — was already decided by its advance-away hook.
    func noteTrackStarted(_ event: PlayHistoryStore.PlayEvent) {
        currentEventId = event.id
        currentSongId = event.songId
        classified = false
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
    func noteAdvanceAway(songId: String, positionMs: Int?, durationMs: Int?) {
        guard let eid = currentEventId, !classified, let current = currentSongId,
              SongVariant.baseId(songId) == SongVariant.baseId(current) else { return }
        classified = true
        // The high-water mark beats a clobbered/vanished live read; a live read past the mark
        // (a seek forward between ticks) beats the mark.
        let pos = max(positionMs ?? 0, maxPositionMs)
        guard let dur = durationMs ?? lastKnownDurationMs, dur > 0 else { return }
        guard Double(pos) / Double(dur) < 0.5 else { return }
        history?.markSkipped(eventId: eid)
        noteSkip?(current)
    }
}
