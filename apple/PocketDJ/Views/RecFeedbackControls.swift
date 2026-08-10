import SwiftUI

/// 👍 / 👎 — the ONE accept/reject control, shared by every surface that has one: the For You
/// tile rows, the Suggested list, the Now Playing deck, the iOS mini-bar. (The widget and CarPlay
/// cannot render SwiftUI from this target, so they build the same pair from
/// `RecFeedbackAction`'s symbols and call the same store through the same intents.)
///
/// ── WHY A PAIR AND NOT A SINGLE TOGGLE ───────────────────────────────────────────────────────
/// "No opinion", "more like this" and "less like this" are three states, and a single control can
/// only express two. The engine needs the distinction: an untouched suggestion is neutral input,
/// a rejected one is negative input, and collapsing them would make every song the user has not
/// yet judged look rejected.
///
/// ── THE ICONOGRAPHY IS SETTLED ───────────────────────────────────────────────────────────────
/// SF Symbols, thumbs, as a matched pair — `hand.thumbsup` / `hand.thumbsdown`, filled when the
/// decision is live. Chosen over checkmark/xmark because these rows ALREADY carry a ＋ that turns
/// into a `checkmark.circle.fill` when a song has been added: a second checkmark meaning
/// "accepted" beside it would be two different ticks a row apart. Never emoji — they would drag
/// skin-tone rendering into a 14pt glyph on a lock screen.
///
/// ── ACTING NEVER INTERRUPTS PLAYBACK ─────────────────────────────────────────────────────────
/// Neither control touches the queue. Accepting adds and keeps playing; rejecting records and
/// keeps playing. A reject deliberately does NOT skip: the pair has to read as symmetric (accept
/// doesn't skip either), a skip makes a mis-tap in the car cost you the song with no way back,
/// and the visible consequence — the row sinking to the bottom of its tile, and the engine
/// dropping it next build — is available without touching what is sounding.
struct RecFeedbackControls: View {
    @Environment(RecFeedbackStore.self) private var feedback: RecFeedbackStore?

    let songId: String
    /// Which surface this instance is on — recorded with the decision.
    var surface: RecFeedbackStore.Surface = .tile
    /// The tile the decision was made from ("zone" / "suggested" / "col-<id>"), when there is one.
    var context: String?
    /// Glyph size. Rows keep the compact default; the deck's action cluster bumps it.
    var font: Font = .caption
    /// Run when a FRESH accept lands (not on a clear, and not on a re-tap). The tile's ＋ path
    /// hangs off this, so "accept" and "add" are one gesture there without this view knowing
    /// anything about collections.
    var onAccepted: (() -> Void)?
    /// Run when a reject lands, so a list can re-sort. Never called for a clear.
    var onRejected: (() -> Void)?

    private var state: RecFeedbackStore.Action? { feedback?.state(for: songId) }

    var body: some View {
        HStack(spacing: 10) {
            button(.accepted)
            button(.rejected)
        }
        // The container carries NO accessibility identifier: putting one on a stack of buttons
        // absorbs the children's identifiers and makes them invisible to XCUITest (and to
        // VoiceOver on macOS — the NavigationLink-label trap this project has already hit).
    }

    @ViewBuilder private func button(_ action: RecFeedbackStore.Action) -> some View {
        let on = state == action
        let accept = action == .accepted
        Button {
            guard let feedback else { return }
            let resulting = feedback.toggle(songId: songId, to: action, surface: surface,
                                            context: context)
            if resulting == .accepted { onAccepted?() }
            if resulting == .rejected { onRejected?() }
        } label: {
            Image(systemName: on
                    ? (accept ? RecFeedbackAction.acceptSymbolFilled : RecFeedbackAction.rejectSymbolFilled)
                    : (accept ? RecFeedbackAction.acceptSymbol : RecFeedbackAction.rejectSymbol))
                .font(font)
                .contentShape(Rectangle())
        }
        // `.borderless`, exactly like `FavoriteToggle` and `RowTransport`: it keeps an enclosing
        // NavigationLink from swallowing the tap AND it survives macOS hit-testing inside a
        // ScrollView + LazyVStack, where `.plain` silently drops the press.
        .buttonStyle(.borderless)
        .foregroundStyle(on ? (accept ? Theme.accent : Theme.danger) : Theme.fgDim)
        .disabled(feedback == nil)
        .accessibilityIdentifier("rec-\(accept ? "accept" : "reject")-\(songId)")
        .accessibilityLabel(accept
            ? (on ? "Clear more like this" : "More like this")
            : (on ? "Clear less like this" : "Less like this"))
    }
}
