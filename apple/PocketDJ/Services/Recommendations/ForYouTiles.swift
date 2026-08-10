import SwiftUI

/// Where a For You tile goes when tapped. A plain `Hashable` value so it rides `NavigationPath`
/// like every other route (registered once in `NavigationDestinations.swift`).
struct ForYouTileRoute: Hashable, Sendable {
    enum Kind: String, Hashable {
        case new, zone, collection
        /// The cloud recommendation engine's own song suggestions (`RecSuggestionsListView`).
        case suggested
    }
    let kind: Kind
    /// The collection's id — only meaningful for `.collection`.
    let collectionId: String?
    /// Title carried along so the destination's nav bar is right immediately, without having to
    /// re-look-up a collection that may since have been renamed or deleted.
    let title: String

    init(kind: Kind, collectionId: String? = nil, title: String) {
        self.kind = kind
        self.collectionId = collectionId
        self.title = title
    }

    /// What a 👍/👎 given on THIS list is recorded against (`RecFeedbackStore.Decision.context`).
    /// The collection id for a collection tile, the kind otherwise — so the engine can eventually
    /// learn "wrong for this crate" without concluding "disliked everywhere". Deliberately NOT the
    /// title: a rename must not orphan the feedback already recorded against the list.
    var feedbackContext: String { collectionId ?? kind.rawValue }
}

/// One tile in the For You grid.
///
/// `Sendable` because the ranking that produces it runs off the main actor (see
/// `ForYouTilesView.rebuild`) — which is also why the tint is stored as a hex `UInt` and the
/// `Color` is computed on read.
struct ForYouTile: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let count: Int
    let route: ForYouTileRoute
    /// True for the two tiles that are pinned to the top (New, In Da Zone) — they get the
    /// accent border so the fixed pair reads as a pair.
    let isPinned: Bool
    /// Stored as a hex so `ForYouTile` remains a plain value type that a unit test can build and
    /// compare without importing SwiftUI's `Color` equality semantics.
    let tintHex: UInt

    var tint: Color { Color(hex: tintHex) }
}

/// Builds the tile list. PURE — no stores, no views, no clock.
///
/// ── WHY THIS IS A FUNCTION AND NOT A `ForEach` ORDER ─────────────────────────────────────────
/// The owner's rule is that **New and In Da Zone are always the top two tiles**. Expressed as
/// view code that is one careless re-order away from being wrong, and untestable without driving
/// the UI. Expressed here it is three lines and a unit test.
enum ForYouTiles {

    /// The gold "New" tile and the blue "In Da Zone" tile keep fixed identities so the grid does
    /// not reshuffle colors as counts change.
    static let newTint: UInt = 0xffce6e       // Theme.accent2
    static let zoneTint: UInt = 0x6ea8ff      // Theme.accent
    static let collectionTint: UInt = 0x97a2c0 // Theme.fgDim

    /// A collection needs at least this many suggestions to earn a tile.
    ///
    /// ── WHY THIS IS 1 AND NOT A NOISE THRESHOLD ──────────────────────────────────────────────
    /// The owner's words are the spec: "one tile for each collection that **we have suggestions of
    /// items to add to**". One suggestion IS having something to add. This was 5 for a while on a
    /// noise-suppression argument, and that argument is somebody else's product opinion overriding
    /// a literal instruction — a collection with three genuinely good additions was silently given
    /// no way in at all, which is the failure the tile exists to prevent.
    ///
    /// Emptiness is still handled, twice over: `CollectionsStore.suggestibleCollections()` drops
    /// collections with no playable members, and `ZoneEngine.suggestions` only offers a candidate
    /// that matches the collection on artist or genre — so "0 suggestions" means there is honestly
    /// nothing to add, and that collection still gets no tile.
    static let minCollectionSuggestions = 1

    /// - Parameters:
    ///   - newReleaseCount: how many releases are in the feed right now — BOTH states.
    ///   - comingSoonCount: how many of those are future-dated pre-orders. Passed separately for
    ///     the SUBTITLE only: the count is one number, but "last 30 days" is a lie about a record
    ///     that ships in three weeks, and `classify` puts no upper bound on the future side at
    ///     all (deliberately — see `ReleaseFeedPolicy.classify`). So the wording has to know the
    ///     split even though the badge does not.
    ///   - zone: the In Da Zone song ids (already capped by `ZoneEngine`).
    ///   - collections: one entry per collection, with its suggestion ids.
    ///   - cloudSuggestionCount: the cloud rec engine's suggestion count. 0 ⇒ no "Suggested"
    ///     tile at all, which is the default-OFF case — an empty tile for a feature the user has
    ///     not enabled would be worse than no tile.
    static func build(newReleaseCount: Int,
                      comingSoonCount: Int = 0,
                      zone: [String],
                      collections: [(id: String, kind: String, name: String, suggestions: [String])],
                      cloudSuggestionCount: Int = 0
    ) -> [ForYouTile] {
        var out: [ForYouTile] = []

        // ── Tile 1: New (ALWAYS first) ────────────────────────────────────────────────────────
        // Shown even at zero: "no new releases this month" is a real, useful answer, and a tile
        // that vanishes when empty would make the pinned pair jump around. Its subtitle says so.
        let outNowCount = max(0, newReleaseCount - comingSoonCount)
        out.append(ForYouTile(
            id: "new",
            title: "New",
            subtitle: newReleaseSubtitle(outNow: outNowCount, comingSoon: comingSoonCount),
            symbol: "sparkles",
            count: newReleaseCount,
            route: ForYouTileRoute(kind: .new, title: "New"),
            isPinned: true,
            tintHex: newTint))

        // ── Tile 2: In Da Zone (ALWAYS second) ────────────────────────────────────────────────
        out.append(ForYouTile(
            id: "zone",
            title: "In Da Zone",
            subtitle: zone.isEmpty
                ? "Play a few songs to build your zone"
                : "Top picks from your recent activity",
            symbol: "waveform.circle.fill",
            count: zone.count,
            route: ForYouTileRoute(kind: .zone, title: "In Da Zone"),
            isPinned: true,
            tintHex: zoneTint))

        // ── Then (when the cloud engine is on and has answers): its suggestions ───────────────
        // Placed after the pinned pair and before the collections: it is a whole-library
        // suggestion set like In Da Zone, so it belongs next to it rather than among the
        // per-collection tiles.
        if cloudSuggestionCount > 0 {
            out.append(ForYouTile(
                id: "suggested",
                title: "Suggested",
                subtitle: "From the recommendation engine",
                symbol: "wand.and.stars",
                count: cloudSuggestionCount,
                route: ForYouTileRoute(kind: .suggested, title: "Suggested"),
                isPinned: false,
                tintHex: collectionTint))
        }

        // ── Then: one tile per collection that has something worth adding ─────────────────────
        // Sorted by how much there is to add (then name, for determinism) so the most actionable
        // collection is first.
        let earners = collections
            .filter { $0.suggestions.count >= minCollectionSuggestions }
            .sorted { $0.suggestions.count > $1.suggestions.count
                   || ($0.suggestions.count == $1.suggestions.count && $0.name < $1.name) }

        for c in earners {
            out.append(ForYouTile(
                id: "col-\(c.id)",
                title: c.name,
                subtitle: "Suggested for this \(c.kind)",
                symbol: c.kind == "pocket" ? "square.stack" : "music.note.list",
                count: c.suggestions.count,
                route: ForYouTileRoute(kind: .collection, collectionId: c.id, title: c.name),
                isPinned: false,
                tintHex: collectionTint))
        }
        return out
    }

    /// Wording for the New tile that matches what the tile actually counts.
    ///
    /// The badge is one number but the feed holds two kinds of thing, and only one of them is
    /// bounded by 30 days. Saying "last 30 days" over a count that includes a pre-order shipping
    /// in three months is simply false, and it is the kind of false a reader cannot detect —
    /// the number looks right.
    static func newReleaseSubtitle(outNow: Int, comingSoon: Int) -> String {
        switch (outNow, comingSoon) {
        case (0, 0):  return "No releases in the last 30 days"
        case (0, _):  return "From artists you play · upcoming"
        case (_, 0):  return "From artists you play · last 30 days"
        default:      return "From artists you play · last 30 days + upcoming"
        }
    }
}
