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

    /// A collection needs at least this many suggestions to earn a tile. Below it the tile is
    /// noise — the point of a per-collection tile is "there is something worth adding here",
    /// and two speculative rows do not clear that bar.
    static let minCollectionSuggestions = 5

    /// - Parameters:
    ///   - newReleaseCount: how many releases are inside the feed window right now.
    ///   - zone: the In Da Zone song ids (already capped by `ZoneEngine`).
    ///   - collections: one entry per collection, with its suggestion ids.
    ///   - cloudSuggestionCount: the cloud rec engine's suggestion count. 0 ⇒ no "Suggested"
    ///     tile at all, which is the default-OFF case — an empty tile for a feature the user has
    ///     not enabled would be worse than no tile.
    static func build(newReleaseCount: Int,
                      zone: [String],
                      collections: [(id: String, kind: String, name: String, suggestions: [String])],
                      cloudSuggestionCount: Int = 0
    ) -> [ForYouTile] {
        var out: [ForYouTile] = []

        // ── Tile 1: New (ALWAYS first) ────────────────────────────────────────────────────────
        // Shown even at zero: "no new releases this month" is a real, useful answer, and a tile
        // that vanishes when empty would make the pinned pair jump around. Its subtitle says so.
        out.append(ForYouTile(
            id: "new",
            title: "New",
            subtitle: newReleaseCount == 0
                ? "No releases in the last 30 days"
                : "From artists you play · last 30 days",
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
}
