import SwiftUI

/// ▶ **Play** · ▶▶ **Play All** · 🔀 **Shuffle** — the standard iOS menu items for "a named list of
/// songs you can play". ONE component, used by collection rows (playlist / pocket) and by a For
/// You tile, because — owner, verbatim — *"a tile is just a setlist so that UI should be shared."*
///
/// ── WHAT WAS REUSED, AND WHAT HAD TO BE WIDENED ──────────────────────────────────────────────
/// The wording, the SF Symbols and the ORDER come straight off the collection surfaces that
/// already ship them: `PlaylistDetailView` / `PocketDetailView` / `AlbumDetailView` toolbars
/// (`Label("Play", systemImage: "play.fill")`, `Label("Shuffle", systemImage: "shuffle")`) and
/// CarPlay's list header (`"▶ Play all"` + `"Shuffle"`). What did NOT exist anywhere was a
/// *menu-shaped* version of them — collections expose Play/Shuffle as toolbar BUTTONS on a detail
/// screen, and their ROW context menus had no way to play at all. So rather than copy a pair of
/// buttons into the tile grid, the pair was generalised into these menu items over
/// `(title, songIds, source, originId)` and adopted by both. A collection gaining a menu item now
/// gives it to tiles for free, which a copy would not.
///
/// ── PLAY vs PLAY ALL: THE DISTINCTION IS REAL, AND IT IS NOT INVENTED FOR TILES ───────────────
/// For a plain collection they are the SAME action — `PlaylistDetailView`'s ▶ Play plays the whole
/// playlist from the top, and CarPlay labels that identical action "▶ Play all". Rendering both
/// there would be one live item and one decoy.
///
/// A recommendation list is the case where they genuinely differ. Its rows are not all equal: the
/// ones the listener thumbed down are SUNK rather than removed (they stay on screen for seven days
/// so the lit 👎 that undoes a mis-tap stays reachable — see `RecFeedbackStore.rankedIds`). So:
///   • **Play** — the live picks. What the tile is actually offering.
///   • **Play All** — the whole list *including* the sunk tail. "All" means all of it.
///   • **Shuffle** — the live picks, shuffled (never a shuffled reject).
/// `sunkIds` is empty for a collection, so `Play All` simply does not render there and nothing is
/// dead. That is the distinction the owner's "the play and play all" is about, preserved rather
/// than collapsed.
///
/// ── HOW IT STARTS PLAYBACK ───────────────────────────────────────────────────────────────────
/// Through `IntentServices.playSongIds` — the app's existing "start a set with no navigation" door
/// (the one History's Rewind already uses). That gets the onboarding veto, `ensureReady()`, the
/// reserved Now Playing setlist, the lock screen, CarPlay and the durable session for free. It is
/// deliberately NOT `collections.playNow` on its own, which builds the setlist but starts nothing.
struct CollectionPlayMenuItems: View {
    @Environment(IntentServices.self) private var intents

    /// Display name for the Now Playing set (a tile's title, a collection's name).
    let title: String
    /// The list as offered — the live rows, in order.
    let songIds: [String]
    /// Rows this list SINKS but still shows. Empty for a collection; the 7-day tombstone tail for
    /// a recommendation tile. Only `Play All` includes them.
    var sunkIds: [String] = []
    /// What History files these plays under.
    var source: PlayHistoryStore.PlaySource = .browser
    /// The collection this came from, for "recently played" stamping. nil for a tile (it is not a
    /// stored collection).
    var originId: String? = nil
    /// Accessibility-id stem: `"<idPrefix>-play"` / `"-play-all"` / `"-shuffle"`.
    let idPrefix: String
    /// Ran with the queue that was actually started — For You uses it to stamp the feedback scope
    /// so the now-playing 👍/👎 file against the right tile.
    var onStarted: (([String]) -> Void)? = nil

    private var everything: [String] { songIds + sunkIds.filter { !songIds.contains($0) } }

    var body: some View {
        Button { start(songIds, shuffle: false) } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(songIds.isEmpty)
        .accessibilityIdentifier("\(idPrefix)-play")

        // Only when it MEANS something different from Play (see the type doc).
        if !sunkIds.isEmpty {
            Button { start(everything, shuffle: false) } label: {
                Label("Play All", systemImage: "play.square.stack")
            }
            .accessibilityIdentifier("\(idPrefix)-play-all")
        }

        Button { start(songIds, shuffle: true) } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        .disabled(songIds.isEmpty)
        .accessibilityIdentifier("\(idPrefix)-shuffle")
    }

    private func start(_ ids: [String], shuffle: Bool) {
        guard !ids.isEmpty else { return }
        Task {
            _ = try? await intents.playSongIds(ids, name: title, shuffle: shuffle, source: source)
            // AFTER the play: `CollectionsStore.playNow` clears any previous recommendation scope
            // on its way through, so a stamp made before this would be wiped.
            onStarted?(ids)
        }
    }
}

/// The whole menu, label included — for a surface that wants a ⋯ button rather than menu items
/// folded into an existing `.contextMenu`.
struct CollectionPlayMenu<Extra: View>: View {
    let title: String
    let songIds: [String]
    var sunkIds: [String] = []
    var source: PlayHistoryStore.PlaySource = .browser
    var originId: String? = nil
    let idPrefix: String
    var onStarted: (([String]) -> Void)? = nil
    /// Anything this surface wants under the shared trio (a Refresh, a Rip/Burn…).
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Menu {
            CollectionPlayMenuItems(title: title, songIds: songIds, sunkIds: sunkIds,
                                    source: source, originId: originId,
                                    idPrefix: idPrefix, onStarted: onStarted)
            extra()
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("\(idPrefix)-menu")
    }
}

extension CollectionPlayMenu where Extra == EmptyView {
    init(title: String, songIds: [String], sunkIds: [String] = [],
         source: PlayHistoryStore.PlaySource = .browser, originId: String? = nil,
         idPrefix: String, onStarted: (([String]) -> Void)? = nil) {
        self.init(title: title, songIds: songIds, sunkIds: sunkIds, source: source,
                  originId: originId, idPrefix: idPrefix, onStarted: onStarted,
                  extra: { EmptyView() })
    }
}
