import SwiftUI

/// ✨ **Recommendations — on or off for THIS collection.**
///
/// Owner, verbatim: *"support ability to turn off recommendations for a collection (eg comfort
/// zone, favorite songs, OTG) as an option in the … menu of the tile."*
///
/// ── WHY ONE COMPONENT AND NOT THREE TOGGLES ──────────────────────────────────────────────────
/// This switch has to appear on THREE surfaces, and they cannot be allowed to disagree about what
/// "off" means or to drift in wording the way `PlaylistDetailView` and `PocketDetailView` already
/// drifted while shipping the same toolbar (see `CollectionToolbar`):
///
///  1. **The For You tile's ⋯** — where the owner asked for it.
///  2. **The collection's own ⋯** (`PlaylistDetailView` / `PocketDetailView`) — the only one of the
///     three that is reachable when the collection has NO TILE, which is the normal state for the
///     crates he named. Favorite Songs, Comfort Zone and OTG earn a tile only on a refresh that
///     found something to add to them; on any other day there is nothing in the grid to long-press.
///     This is also the surface that survives switching off, since it does not live on the tile
///     that switching off removes.
///  3. **Settings ▸ For You** — the roll-up of everything currently switched off, so a collection
///     cannot be lost by being both empty and off (surface 1 gone, surface 2 requires remembering
///     which crate it was).
///
/// ── OFF MEANS OFF AT THE RANKER ──────────────────────────────────────────────────────────────
/// `ForYouFeedBuilder.build` skips a switched-off crate before `ZoneEngine.suggestions` runs, so
/// the ~96k-row catalog sweep that crate would have cost is not spent — this is not a hidden tile
/// that still ranks. `ForYouTilesView.deriveTiles` additionally drops it from a snapshot frozen
/// BEFORE the switch was flipped, so the tile goes on the next frame rather than on Friday.
///
/// What it does NOT turn off: In Da Zone still counts this collection's membership as a
/// co-membership signal ("you file these together"), which is a fact about the library and not a
/// suggestion about the crate. See `CollectionsStore.suggestibleCollections`.
struct CollectionRecsToggle: View {
    @Environment(CollectionsStore.self) private var collections

    /// The collection — kind unknown on purpose, since a For You tile carries only an id.
    let collectionId: String
    /// Accessibility-id stem: `"<idPrefix>-recs-toggle"`. Must be unique app-wide — two live
    /// registrations of one id make BOTH unqueryable in XCUITest.
    let idPrefix: String
    /// Ran only on the OFF transition, and only when the write landed. The For You tile uses it to
    /// say where the switch went, because switching off deletes the tile the switch was on.
    var onTurnedOff: (() -> Void)? = nil

    var body: some View {
        let binding = Binding<Bool>(
            get: { collections.recommendationsEnabled(forCollection: collectionId) },
            set: { on in
                guard collections.setRecommendationsEnabled(on, forCollection: collectionId) else { return }
                if !on { onTurnedOff?() }
            })
        Toggle(isOn: binding) { Label("Recommendations", systemImage: "sparkles") }
            .accessibilityIdentifier("\(idPrefix)-recs-toggle")
    }
}
