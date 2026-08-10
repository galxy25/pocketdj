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
    /// This tile's items that resolve to a CATALOG song, IN DISPLAY ORDER — i.e. exactly what
    /// "play in order" queues.
    ///
    /// Its own list, never derived from `count`, because the two genuinely differ. **New** counts
    /// RELEASES the owner does not own (nothing to queue: empty), and a cloud suggestion can name
    /// an id this device's catalog cannot resolve. A tile with nothing playable must present a
    /// DISABLED ▶ rather than a live one that silently does nothing — a dead Play button is the
    /// failure this field exists to make impossible.
    let playableSongIds: [String]

    var tint: Color { Color(hex: tintHex) }
    var playableCount: Int { playableSongIds.count }
    /// Can this tile be played at all? Drives every ▶/🔀 affordance, on the card and in the header.
    var isPlayable: Bool { !playableSongIds.isEmpty }
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
    /// - Parameters (continued):
    ///   - playableZoneIds / playableCloudIds / `playableByCollectionId`: which of that tile's
    ///     ids this device can actually queue, in display order. Defaulted to the tile's own list
    ///     (zone / collection ids come OUT of the catalog, so they are playable by construction),
    ///     which is why every existing caller and test keeps working unchanged. The CLOUD list has
    ///     no default: a suggestion can name an id this catalog cannot resolve, so the caller must
    ///     say — and an absent one yields an unplayable Suggested tile rather than a lying count.
    static func build(newReleaseCount: Int,
                      zone: [String],
                      collections: [(id: String, kind: String, name: String, suggestions: [String])],
                      cloudSuggestionCount: Int = 0,
                      playableZoneIds: [String]? = nil,
                      playableCloudIds: [String] = [],
                      playableByCollectionId: [String: [String]] = [:]
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
            tintHex: newTint,
            // ALWAYS 0. A release the owner does not own has no catalog song behind it, so the
            // New tile can never be played as a setlist — it offers Add (through the album
            // preview) instead, and its ▶ is disabled rather than dead.
            playableSongIds: []))

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
            tintHex: zoneTint,
            playableSongIds: playableZoneIds ?? zone))

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
                tintHex: collectionTint,
                playableSongIds: playableCloudIds))
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
                tintHex: collectionTint,
                playableSongIds: playableByCollectionId[c.id] ?? c.suggestions))
        }
        return out
    }
}
