package com.levi.pocketdj.data.recs

/** A release row as the grid needs it (BRW-14's feed adapts to this). */
data class ForYouRelease(val feedbackId: String, val comingSoon: Boolean)

/** The New-releases feed seam (iOS `ReleaseFeedService`); BRW-14 implements it. */
interface ForYouReleaseSource {
    fun feed(nowMs: Double): List<ForYouRelease>
    /** Why New is empty, as a tile subtitle; null = use the default copy. */
    fun emptyTileNote(): String?
}

/** The slice of CollectionsStore the grid reads (see CollectionsRecs.asForYouCollections). */
interface ForYouCollections {
    fun exists(id: String): Boolean
    fun recommendationsEnabled(id: String): Boolean
    fun suggestionsExcludingMembers(suggestionIds: List<String>, id: String): List<String>
}

/**
 * Derives the visible tile list from the FROZEN snapshot + current feedback + current collection
 * state, at read time (port of iOS `ForYouGrid`). Deleted and recs-off crates drop here; accepted
 * rows leave the zone/new/crate scopes permanently; tombstoned rows are not counted.
 */
object ForYouGrid {

    fun tiles(
        snapshot: ForYouFeedSnapshot,
        collections: ForYouCollections,
        feedback: RecFeedbackStore?,
        releaseFeed: ForYouReleaseSource?,
        nowMs: Double = System.currentTimeMillis().toDouble(),
    ): List<ForYouTile> {
        val releases = releaseFeed?.feed(nowMs).orEmpty()
        val soon = releases.filter { it.comingSoon }
        val newScope = ForYouTileKind.NEW.raw

        val crates = snapshot.crates.filter {
            collections.exists(it.id) && collections.recommendationsEnabled(it.id)
        }
        val newCount = live(releases.map { it.feedbackId }, newScope, feedback, nowMs).size
        return ForYouTiles.build(
            newReleaseCount = newCount,
            comingSoonCount = live(soon.map { it.feedbackId }, newScope, feedback, nowMs).size,
            zone = live(snapshot.zoneIds, ForYouTileKind.ZONE.raw, feedback, nowMs),
            zoneSource = snapshot.zoneSource,
            collections = crates.map { c ->
                ForYouCollectionInput(c.id, c.kind, c.name, songIdsForCrate(c.id, c.songIds, collections, feedback, nowMs))
            },
            newEmptyNote = if (newCount == 0) releaseFeed?.emptyTileNote() else null,
        )
    }

    /** The song ids a tile would play/list right now. New is owned by the release feed -> empty. */
    fun songIds(
        tile: ForYouTile,
        snapshot: ForYouFeedSnapshot,
        collections: ForYouCollections,
        feedback: RecFeedbackStore?,
        nowMs: Double = System.currentTimeMillis().toDouble(),
    ): List<String> = when (tile.route.kind) {
        ForYouTileKind.NEW -> emptyList()
        ForYouTileKind.ZONE -> live(snapshot.zoneIds, ForYouTileKind.ZONE.raw, feedback, nowMs)
        ForYouTileKind.COLLECTION -> {
            val id = tile.route.collectionId
            val crate = id?.let { i -> snapshot.crates.firstOrNull { it.id == i } }
            if (id == null || crate == null) emptyList()
            else songIdsForCrate(id, crate.songIds, collections, feedback, nowMs)
        }
    }

    /** Drop rows already accepted in [scope] (a 👍 is permanent in zone/new/crate scopes). */
    fun excludingAccepted(ids: List<String>, scope: String, feedback: RecFeedbackStore?): List<String> {
        if (feedback == null) return ids
        val accepted = feedback.acceptedInScope(scope)
        return if (accepted.isEmpty()) ids else ids.filter { it !in accepted }
    }

    private fun live(ids: List<String>, scope: String, feedback: RecFeedbackStore?, nowMs: Double): List<String> {
        val offered = excludingAccepted(ids, scope, feedback)
        return feedback?.partition(offered, scope, nowMs)?.live ?: offered
    }

    private fun songIdsForCrate(
        id: String, frozen: List<String>, collections: ForYouCollections,
        feedback: RecFeedbackStore?, nowMs: Double,
    ): List<String> = collections.suggestionsExcludingMembers(live(frozen, id, feedback, nowMs), id)
}
