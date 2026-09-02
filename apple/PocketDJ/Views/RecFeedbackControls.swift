import SwiftUI

/// 👍 / 👎 — the accept + reject pair, ONE control used on every surface that shows a
/// recommendation: the For You rows, the New tile, the cloud suggestions, the Now Playing deck,
/// the mini bar, and (through `IntentServices` rather than this view) CarPlay and the widgets.
///
/// ── THE ICONOGRAPHY IS SETTLED ───────────────────────────────────────────────────────────────
/// SF Symbols, `hand.thumbsup` / `hand.thumbsdown`, filled when the verdict is set. The owner
/// offered thumbs OR check/x; thumbs won because the two controls must read as a MATCHED PAIR and
/// a thumb beside an ✕ does not — one is an opinion, the other is a dismissal, and the asymmetry
/// makes the reject look like "close this row" rather than "I don't like this". Thumbs also carry
/// the meaning at 13pt in a car and at widget size, which a check/x pair does not. No emoji, no
/// image assets: SF Symbols render natively on CarPlay and in WidgetKit, which is what makes the
/// same pair reachable from the lock screen and the car for free.
///
/// ── ONE DECISION MODEL, TWO ENTRY POINTS ─────────────────────────────────────────────────────
/// SYNC (act on what is playing) and ASYNC (come back to the tile and work the list) are both
/// required, and neither replaces the other. They are the same button writing the same row into
/// the same `RecFeedbackStore`, so a thumbs-down given in the car is already reflected the next
/// time the tile is opened, and vice versa. There is deliberately NO per-surface state to
/// reconcile — reconciliation is `verdict(songId:scope:)` at render time.
///
/// ── ACTING NEVER INTERRUPTS PLAYBACK ─────────────────────────────────────────────────────────
/// This view records a verdict and (on 👍, when a target is given) adds the song. It does not
/// touch the transport: no stop, no skip, no re-shuffle, no queue rebuild.
///
/// A rejection does NOT skip the current song, and that is a deliberate choice rather than an
/// omission. A 👎 is a statement about the RECOMMENDATION — "rank this lower here" — which is
/// about the next pass, not this second; ⏭ already means "get this off now", and conflating them
/// would leave the listener no way to say one without the other. It also decides the failure mode
/// of a mis-tap: a thumbs-down that skips makes the mistake instantly unrecoverable in a moving
/// car (the track you were enjoying is gone), while one that only sinks costs a tap to undo.
struct RecFeedbackButtons: View {
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?
    @Environment(AppModel.self) private var app

    let songId: String
    /// WHICH LIST this row belongs to — a collection id, or a reserved tile name. A reject is
    /// scoped to it: rejecting a song in one crate never suppresses it in another.
    let scope: String
    /// Where the tap happened — recorded, never branched on.
    var surface: RecFeedbackStore.Surface = .tile
    /// Glyph size. Rows keep `.caption`; the deck bumps it so the pair reads as a primary action.
    var font: Font = .caption
    /// Run on 👍 in addition to recording it — the row's existing Add action. When the queue came
    /// from a COLLECTION tile the playing scope is that collection, so every surface supplies an
    /// add (the tile row via `accept`, the now-playing surfaces via `addAcceptedSong`); only a
    /// scope with no implicit collection (In Da Zone, New) leaves a 👍 as pure feedback.
    var onAccept: (() -> Void)?

    private var verdict: RecFeedbackStore.Verdict? {
        feedback?.verdict(songId: songId, scope: scope)
    }

    var body: some View {
        HStack(spacing: 10) {
            button(.accepted)
            button(.rejected)
        }
    }

    @ViewBuilder private func button(_ v: RecFeedbackStore.Verdict) -> some View {
        let isOn = verdict == v
        let accept = v == .accepted
        Button {
            record(v)
        } label: {
            Image(systemName: accept
                  ? (isOn ? "hand.thumbsup.fill" : "hand.thumbsup")
                  : (isOn ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(font)
                .contentShape(Rectangle())
        }
        // `.borderless`, matching `FavoriteToggle` — it is what keeps an enclosing NavigationLink
        // from swallowing the tap AND what survives macOS hit-testing inside a ScrollView +
        // LazyVStack, where a `.plain` button silently drops its press.
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? (accept ? Theme.accent : Theme.fgDim.opacity(0.95)) : Theme.fgDim)
        .accessibilityIdentifier("rec-\(accept ? "accept" : "reject")-\(songId)")
        .accessibilityLabel(accept
                            ? (isOn ? "Undo more like this" : "More like this")
                            : (isOn ? "Undo not for me" : "Not for me"))
    }

    private func record(_ v: RecFeedbackStore.Verdict) {
        guard let feedback else { return }
        let song = app.songsById[songId]
        let landed = feedback.toggle(
            songId: songId, to: v, scope: scope, surface: surface,
            artistKey: song.map { PuzzleSimilarity.artistKey($0.artist) },
            genre: SimilarityFamilies.canonicalGenre(
                song?.albumId.flatMap { app.albumsById[$0] }?.genre))
        // The Add only rides a 👍 that actually LANDED as accepted — tapping a lit thumbs-up is an
        // undo, and undoing feedback must not silently add the song a second time.
        if landed == .accepted { onAccept?() }
    }
}

/// The now-playing variant: the SAME pair, keyed on whatever is playing right now, and hidden
/// unless the running queue actually came from a For You list.
///
/// Exists so the deck, the mini bar and CarPlay can drop in one view instead of each re-deriving
/// the current song id and its scope — the divergence that would let two surfaces disagree about
/// which track a thumbs-down applied to, or file it against a tile the listener never opened.
struct NowPlayingFeedbackButtons: View {
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?
    @Environment(CollectionsStore.self) private var collections
    let font: Font

    init(font: Font = .subheadline) { self.font = font }

    private var target: (songId: String, scope: String)? {
        guard sequencer.isRunning, sequencer.index < sequencer.queue.count else { return nil }
        let id = sequencer.queue[sequencer.index].id
        guard let scope = feedback?.scope(forPlaying: id) else { return nil }
        return (id, scope)
    }

    var body: some View {
        if let t = target {
            RecFeedbackButtons(songId: t.songId, scope: t.scope, surface: .nowPlaying, font: font,
                               onAccept: { collections.addAcceptedSong(t.songId, scopedTo: t.scope) })
        }
    }
}
