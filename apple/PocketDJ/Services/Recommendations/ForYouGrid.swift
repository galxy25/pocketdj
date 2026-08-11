import Foundation

/// **THE ONE DERIVATION OF THE For You GRID** — frozen snapshot + the owner's live decisions →
/// the tile cards, in order.
///
/// ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────
/// This was `ForYouTilesView.deriveTiles`, inline in a SwiftUI view. That was fine while the phone
/// was the only surface. It stopped being fine the moment CarPlay grew a For You tab: the owner's
/// requirement is that the car shows *"new and recommended pinned up top"* **matching the phone
/// order**, and the only way to guarantee that is for both surfaces to call the same function —
/// not for two implementations to be kept in step by hand across two files, one of which cannot be
/// headless-tested at all.
///
/// So the derivation moved here verbatim and both callers use it. It is `@MainActor` (the stores it
/// reads are), pure apart from those reads, and cheap: a pass over a few thousand frozen ids, never
/// a catalog sweep. The RANKING still happens only in `ForYouFeedStore.refresh`.
///
/// ── WHAT IS "LIVE" AND WHY IT IS APPLIED HERE RATHER THAN FROZEN IN ──────────────────────────
/// Three filters sit between the frozen ranking and the card, and every one of them is the OWNER
/// ACTING, not the engine changing its mind — so they are evaluated at read and never baked in:
///  · a 👎 sinks a row (`RecFeedbackStore.partition`), and its undo must take effect at once;
///  · an ADD removes a suggestion from its crate (`suggestionsExcludingMembers`) — including the
///    add a 👍 just made from this very tile;
///  · a collection switched off, or deleted, must lose its tile on the next frame rather than at
///    the next refresh.
@MainActor
enum ForYouGrid {

    /// The tile cards. `ForYouTiles.build` fixes the ORDER (New, In Da Zone, then collections by
    /// how much there is to add) — this supplies what it counts.
    static func tiles(snapshot: ForYouFeedSnapshot,
                      collections: CollectionsStore,
                      feedback: RecFeedbackStore?,
                      releaseFeed: ReleaseFeedService?,
                      nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [ForYouTile] {
        let releases = releaseFeed?.feed(nowMs: nowMs) ?? []
        let soon = releases.filter { $0.status == .comingSoon }
        let newScope = ForYouTileRoute.Kind.new.rawValue

        // Drop a cached tile whose collection has since been deleted — the ONE way a frozen feed
        // could offer a door to nothing — and one the owner has switched OFF.
        //
        // The opt-out is enforced in BOTH passes, and both are needed for different windows of
        // time. `ForYouFeedBuilder.build` stops the WORK, but only from the next refresh onward;
        // this stops the TILE from the next frame, over a snapshot frozen before the switch was
        // flipped. Without this the tile would sit there until the schedule came round on Friday.
        let crates = snapshot.crates.filter {
            (collections.playlist($0.id) != nil || collections.pocket($0.id) != nil)
                && collections.recommendationsEnabled(forCollection: $0.id)
        }

        let newCount = live(releases.map(\.feedbackId), scope: newScope,
                            feedback: feedback, nowMs: nowMs).count
        return ForYouTiles.build(
            newReleaseCount: newCount,
            comingSoonCount: live(soon.map(\.feedbackId), scope: newScope,
                                  feedback: feedback, nowMs: nowMs).count,
            zone: live(snapshot.zoneIds, scope: ForYouTileRoute.Kind.zone.rawValue,
                       feedback: feedback, nowMs: nowMs),
            // The attribution rides the SNAPSHOT, not live engine state: it has to describe the
            // ids actually on screen, and those were frozen by whichever ranker produced them.
            zoneSource: snapshot.zoneSource,
            collections: crates.map { c in
                (id: c.id, kind: c.kind, name: c.name,
                 suggestions: songIds(forCrate: c.id, frozen: c.songIds, collections: collections,
                                      feedback: feedback, nowMs: nowMs))
            },
            // A ZERO ON THE NEW TILE HAS FOUR DIFFERENT CAUSES. Say which — a bare 0 with
            // "no releases in the last 30 days" beneath it is the card asserting something it
            // has not checked, and it is why this feature read as broken.
            newEmptyNote: newCount == 0 ? releaseFeed?.emptyReason().tileNote : nil)
    }

    /// **The song ids a tile's badge counted** — and therefore exactly what its ▶ must play.
    ///
    /// Returns `[]` for the New tile, and that is not a gap: New's rows are RELEASES the owner does
    /// not own (`ReleaseFeedItem`), which have no catalog song id and are expanded and streamed by
    /// `ReleaseStreaming` instead. Asking this function for New's contents would be asking the
    /// wrong question, so it answers "no songs" rather than something plausible.
    ///
    /// Both filters, in the order the card applies them, so `count` here and the number on the card
    /// are the same number by construction rather than by coincidence.
    static func songIds(forTile tile: ForYouTile,
                        snapshot: ForYouFeedSnapshot,
                        collections: CollectionsStore,
                        feedback: RecFeedbackStore?,
                        nowMs: Double = Date().timeIntervalSince1970 * 1000) -> [String] {
        switch tile.route.kind {
        case .new:
            return []
        case .zone:
            return live(snapshot.zoneIds, scope: ForYouTileRoute.Kind.zone.rawValue,
                        feedback: feedback, nowMs: nowMs)
        case .collection:
            guard let id = tile.route.collectionId,
                  let crate = snapshot.crates.first(where: { $0.id == id }) else { return [] }
            return songIds(forCrate: id, frozen: crate.songIds, collections: collections,
                           feedback: feedback, nowMs: nowMs)
        }
    }

    /// The thumbed-down tail taken off. `nil` feedback ⇒ nothing is suppressed, which is the honest
    /// answer for a host that has no verdict log.
    private static func live(_ ids: [String], scope: String,
                             feedback: RecFeedbackStore?, nowMs: Double) -> [String] {
        feedback?.partition(ids, scope: scope, nowMs: nowMs).live ?? ids
    }

    /// One crate's offer: sunk rows off, then anything already IN the collection off. The second
    /// filter is why a 👍 (which adds) makes the suggestion disappear from the tile immediately
    /// instead of being offered again until Friday.
    private static func songIds(forCrate id: String, frozen: [String],
                                collections: CollectionsStore,
                                feedback: RecFeedbackStore?, nowMs: Double) -> [String] {
        collections.suggestionsExcludingMembers(live(frozen, scope: id, feedback: feedback,
                                                     nowMs: nowMs),
                                                ofCollection: id)
    }
}
