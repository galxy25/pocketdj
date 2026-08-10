import SwiftUI

/// Where a For You tile goes when tapped. A plain `Hashable` value so it rides `NavigationPath`
/// like every other route (registered once in `NavigationDestinations.swift`).
struct ForYouTileRoute: Hashable, Sendable {
    /// ── THERE IS NO `.suggested` ──────────────────────────────────────────────────────────────
    /// There used to be: a third tile holding the cloud engine's own song list. Owner, verbatim:
    /// *"remove Suggested tile (that is what New and In Da Zone [are])"* and *"new and in da zone
    /// should use the recommendation engine if available, only doing on device when not enabled."*
    /// So the engine did not lose a surface, it gained two — its ranking now arrives INSIDE
    /// In Da Zone (see `ForYouTileSource`), and a separate tile for the same content was the
    /// duplication the owner asked to remove.
    enum Kind: String, Hashable {
        case new, zone, collection
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

    /// The id of the TILE this route came from — the key the frozen feed
    /// (`ForYouFeedSnapshot.songIds(forTileId:)`) stores this list's ids under. Kept in lock-step
    /// with the ids `ForYouTiles.build` mints, so the card the owner tapped and the list that
    /// opens are literally the same array rather than two rankings that happen to agree.
    var tileId: String { collectionId.map { "col-\($0)" } ?? kind.rawValue }
}

/// WHICH RANKER PRODUCED A TILE'S CONTENT.
///
/// ── WHY THIS IS ON THE TILE AND NOT IN A LOG ─────────────────────────────────────────────────
/// Two rankers now feed the same grid — the cloud engine when it is enabled, reachable and has an
/// answer, the on-device engine otherwise — and they fail in completely different ways. Without
/// this the owner (and the next person debugging it) cannot tell a cloud regression from an
/// on-device one, or notice that a tile has been silently falling back for a week because the
/// Lambda 500s. The fallback is deliberately INVISIBLE in the sense that it never shows an error
/// or an empty tile; it must not be invisible in the sense that nobody can tell it happened.
enum ForYouTileSource: String, Hashable, Sendable {
    /// Ranked here, from the local catalog + play history. The default and the common case — the
    /// engine is opt-in and ships OFF.
    case onDevice
    /// Ranked by the cloud recommendation engine, then shaped locally
    /// (`ZoneEngine.shapeCloudRanking`) so the per-artist cap, the rediscovery floor and the 👎
    /// tombstones still hold.
    case cloud
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
    /// Which ranker produced `count` (and the ids behind it). Collection tiles are always
    /// `.onDevice`; see `ForYouTileSource`. Defaulted so only the tiles that can actually have a
    /// cloud answer have to say anything about it.
    var source: ForYouTileSource = .onDevice
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
    ///   - zoneSource: which ranker produced `zone` — the cloud engine, or this device. See
    ///     `ForYouTileSource`; it is the tile's attribution and it changes the subtitle so the
    ///     owner can read the answer off the card rather than off a log.
    ///   - collections: one entry per collection, with its suggestion ids.
    ///   - newEmptyNote: why the New tile is empty, when it is and when the reason is not simply
    ///     "nothing came out". A tile that renders a bare 0 with no explanation is how this
    ///     feature got reported as broken; the card says which of seeding / unauthorized /
    ///     offline / not-yet-checked it is, and the screen behind it says it at length.
    static func build(newReleaseCount: Int,
                      comingSoonCount: Int = 0,
                      zone: [String],
                      zoneSource: ForYouTileSource = .onDevice,
                      collections: [(id: String, kind: String, name: String, suggestions: [String])],
                      newEmptyNote: String? = nil
    ) -> [ForYouTile] {
        var out: [ForYouTile] = []

        // ── Tile 1: New (ALWAYS first) ────────────────────────────────────────────────────────
        // Shown even at zero: "no new releases this month" is a real, useful answer, and a tile
        // that vanishes when empty would make the pinned pair jump around. Its subtitle says so.
        //
        // NEW HAS NO CLOUD SOURCE, AND THAT IS A FINDING, NOT AN OMISSION. The rec engine's
        // `/recs/songs` scores candidates out of `rec-features.json` — a slim projection of the
        // user's OWN catalog indexes. Every id it can return is therefore a song he already owns,
        // which is precisely the set New exists to exclude: unowned releases from the last 30 days,
        // fetched from Apple Music by `ReleaseFeedService`. Wiring New to that route would hand it
        // a list it can only answer with things New must never show. So New stays on-device until
        // the engine grows a route over an UNOWNED-release corpus, and the tile says `.onDevice`
        // rather than pretending a source it does not have.
        let outNowCount = max(0, newReleaseCount - comingSoonCount)
        out.append(ForYouTile(
            id: "new",
            title: "New",
            subtitle: newReleaseSubtitle(outNow: outNowCount, comingSoon: comingSoonCount,
                                         emptyNote: newEmptyNote),
            symbol: "sparkles",
            count: newReleaseCount,
            route: ForYouTileRoute(kind: .new, title: "New"),
            isPinned: true,
            source: .onDevice,
            tintHex: newTint))

        // ── Tile 2: In Da Zone (ALWAYS second) ────────────────────────────────────────────────
        // The one tile with two possible rankers. The subtitle is the attribution: it names the
        // engine when the cloud answered, and describes the local ranking when it did not — so a
        // silent week of fallback is legible on the card instead of only in a network trace.
        out.append(ForYouTile(
            id: "zone",
            title: "In Da Zone",
            subtitle: zoneSubtitle(count: zone.count, source: zoneSource),
            symbol: "waveform.circle.fill",
            count: zone.count,
            route: ForYouTileRoute(kind: .zone, title: "In Da Zone"),
            isPinned: true,
            source: zoneSource,
            tintHex: zoneTint))

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
                source: .onDevice,
                tintHex: collectionTint))
        }
        return out
    }

    /// In Da Zone's subtitle — and its SOURCE ATTRIBUTION, in one line.
    ///
    /// The empty answer wins over the attribution: "play a few songs" is what the owner needs to
    /// read off an empty tile, and naming whichever ranker produced nothing is trivia at that
    /// point. Above zero the line says which engine spoke, because that is the only place the two
    /// are distinguishable from the outside.
    static func zoneSubtitle(count: Int, source: ForYouTileSource) -> String {
        guard count > 0 else { return "Play a few songs to build your zone" }
        switch source {
        case .cloud:    return "Top picks · recommendation engine"
        case .onDevice: return "Top picks from your recent activity"
        }
    }

    /// Wording for the New tile that matches what the tile actually counts.
    ///
    /// The badge is one number but the feed holds two kinds of thing, and only one of them is
    /// bounded by 30 days. Saying "last 30 days" over a count that includes a pre-order shipping
    /// in three months is simply false, and it is the kind of false a reader cannot detect —
    /// the number looks right.
    /// `emptyNote` wins at zero, and only at zero: "No releases in the last 30 days" is a CLAIM,
    /// and it is a false one while the feed is still seeding, unauthorized or offline. Saying
    /// nothing came out when nothing was ever asked is the specific way this tile lied.
    static func newReleaseSubtitle(outNow: Int, comingSoon: Int,
                                   emptyNote: String? = nil) -> String {
        if outNow == 0, comingSoon == 0, let note = emptyNote, !note.isEmpty { return note }
        switch (outNow, comingSoon) {
        case (0, 0):  return "No releases in the last 30 days"
        case (0, _):  return "From artists you play · upcoming"
        case (_, 0):  return "From artists you play · last 30 days"
        default:      return "From artists you play · last 30 days + upcoming"
        }
    }
}
