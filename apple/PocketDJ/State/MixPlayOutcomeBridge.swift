import Foundation

/// Turns the Mix decks' play / end reports into per-play OUTCOMES on the history log — the Mix
/// twin of `SkipTracker`, which only ever hears from the SetlistPlayer and so never saw a single
/// Mix or Auto-DJ play (a CarPlay ⏭ during an auto mix went down as a full listen).
///
/// ── LIFECYCLE ───────────────────────────────────────────────────────────────────────────────
/// `MixEngine.onSongPlayed` fires once per deck load; the app records the play and hands the
/// resulting event here (`notePlayed`) — or nil when the 30 s window collapsed it, in which case
/// the newest LOCAL event for the song stands in. `MixEngine.onDeckTrackEnded` later reports, for
/// the SAME deck, the played/duration seconds and WHY it ended (`noteTrackEnded`). The mapping is
/// keyed by DECK, never song id: in a repeat-one auto mix both decks hold the same song, and the
/// incoming deck's play must not capture the outgoing deck's end. The fraction goes onto the event
/// (`noteListened`), and a `.skip` or `.replaced` under 50% is a skip — the SAME <50% rule the
/// set player's SkipTracker applies, so a pocket reads Mix and playlist listening alike.
///
/// Natural ends and stops are never skips, however little played (a dead stream, a stopped
/// mix). Only the FIRST end per mapped event applies; the mapping is dropped with it.
///
/// Pure and injectable (no MixEngine reference), so the whole verdict table is unit-testable.
@MainActor
final class MixPlayOutcomeBridge {
    /// The log outcomes are written into. Weak — app-scoped peers, never retained by tests.
    weak var history: PlayHistoryStore?
    /// Cumulative-count sink, wired to `PlayCountService.noteSkipped` (the SkipTracker contract).
    var noteSkip: ((String) -> Void)?

    /// deck → the history event its current load is writing to (with the song, as a guard).
    private var eventByDeck: [MixEngine.Deck: (songId: String, event: UUID)] = [:]
    /// Events whose outcome has already been applied — a second end for the same event (two
    /// decks briefly holding one song, a collapsed replay mapping back onto it) is ignored.
    /// Bounded: an evicted id can at worst re-apply a max-merged fraction.
    private var endedEvents: [UUID] = []
    private var endedSet: Set<UUID> = []
    private static let endedCap = 256

    init(history: PlayHistoryStore? = nil, noteSkip: ((String) -> Void)? = nil) {
        self.history = history
        self.noteSkip = noteSkip
    }

    /// `deck` started playing `songId`; `event` is what `record` returned (nil = collapsed).
    func notePlayed(deck: MixEngine.Deck, songId: String, event: PlayHistoryStore.PlayEvent?) {
        guard let ev = event ?? history?.lastLocalEvent(forSongId: songId) else {
            eventByDeck[deck] = nil   // never let a stale mapping take this load's end
            return
        }
        eventByDeck[deck] = (songId, ev.id)
    }

    /// `deck`'s track (`songId`) stopped being the music. Seconds are SOURCE seconds; an
    /// unknown (zero) duration reports nothing — never guess against the listener.
    func noteTrackEnded(deck: MixEngine.Deck, songId: String, played: Double, duration: Double,
                        reason: MixTrackEndReason) {
        guard let mapped = eventByDeck.removeValue(forKey: deck), mapped.songId == songId,
              !endedSet.contains(mapped.event) else { return }
        let eid = mapped.event
        remember(eid)
        guard duration > 0, played.isFinite, duration.isFinite else { return }
        let fraction = min(1, max(0, played / duration))
        guard let history else { return }
        history.noteListened(eventId: eid, fraction: fraction)
        guard reason == .skip || reason == .replaced, fraction < 0.5 else { return }
        // Already skipped (a peer's verdict synced in) ⇒ the cumulative count was spent.
        let alreadySkipped = history.events.last(where: { $0.id == eid })?.wasSkipped == true
        history.markSkipped(eventId: eid)
        if !alreadySkipped { noteSkip?(songId) }
    }

    private func remember(_ id: UUID) {
        endedEvents.append(id)
        endedSet.insert(id)
        if endedEvents.count > Self.endedCap {
            endedSet.remove(endedEvents.removeFirst())
        }
    }
}
