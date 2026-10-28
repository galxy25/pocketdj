package com.levi.pocketdj.data.recs

/** Which card a For You tile is. Raw values double as RecFeedback scopes for the reserved two. */
enum class ForYouTileKind(val raw: String) { NEW("new"), ZONE("zone"), COLLECTION("collection") }

data class ForYouTileRoute(
    val kind: ForYouTileKind,
    val collectionId: String? = null,
    val title: String,
) {
    /** The feedback `scope` for rows on this tile: collection id, or the reserved kind. */
    val feedbackContext: String get() = collectionId ?: kind.raw

    val tileId: String get() = collectionId?.let { "col-$it" } ?: kind.raw
}

enum class ForYouTileSource(val raw: String) {
    ON_DEVICE("onDevice"), CLOUD("cloud");

    companion object {
        fun fromRaw(raw: String?): ForYouTileSource? = entries.firstOrNull { it.raw == raw }
    }
}

data class ForYouTile(
    val id: String,
    val title: String,
    val subtitle: String,
    /** Symbolic icon name (iOS SF Symbol name); the renderer maps it. */
    val symbol: String,
    val count: Int,
    val route: ForYouTileRoute,
    val isPinned: Boolean,
    val source: ForYouTileSource = ForYouTileSource.ON_DEVICE,
    /** 0xRRGGBB. */
    val tintHex: Long,
)

/** One collection offered to [ForYouTiles.build]: its LIVE suggestions already filtered. */
data class ForYouCollectionInput(val id: String, val kind: String, val name: String, val suggestions: List<String>)

/** Pure tile derivation. New is #1, In Da Zone #2 ALWAYS; collections with >= 1 live suggestion follow. */
object ForYouTiles {
    const val NEW_TINT = 0xffce6eL
    const val ZONE_TINT = 0x6ea8ffL
    const val COLLECTION_TINT = 0x97a2c0L

    const val MIN_COLLECTION_SUGGESTIONS = 1

    fun build(
        newReleaseCount: Int,
        comingSoonCount: Int = 0,
        zone: List<String>,
        zoneSource: ForYouTileSource = ForYouTileSource.ON_DEVICE,
        collections: List<ForYouCollectionInput>,
        newEmptyNote: String? = null,
    ): List<ForYouTile> {
        val out = ArrayList<ForYouTile>()
        val outNow = maxOf(0, newReleaseCount - comingSoonCount)
        out += ForYouTile(
            id = "new", title = "New",
            subtitle = newReleaseSubtitle(outNow, comingSoonCount, newEmptyNote),
            symbol = "sparkles", count = newReleaseCount,
            route = ForYouTileRoute(ForYouTileKind.NEW, title = "New"),
            isPinned = true, source = ForYouTileSource.ON_DEVICE, tintHex = NEW_TINT,
        )
        out += ForYouTile(
            id = "zone", title = "In Da Zone",
            subtitle = zoneSubtitle(zone.size, zoneSource),
            symbol = "waveform.circle.fill", count = zone.size,
            route = ForYouTileRoute(ForYouTileKind.ZONE, title = "In Da Zone"),
            isPinned = true, source = zoneSource, tintHex = ZONE_TINT,
        )
        val earners = collections
            .filter { it.suggestions.size >= MIN_COLLECTION_SUGGESTIONS }
            .sortedWith(compareByDescending<ForYouCollectionInput> { it.suggestions.size }.thenBy { it.name })
        for (c in earners) {
            out += ForYouTile(
                id = "col-${c.id}", title = c.name,
                subtitle = "Suggested for this ${c.kind}",
                symbol = if (c.kind == "pocket") "square.stack" else "music.note.list",
                count = c.suggestions.size,
                route = ForYouTileRoute(ForYouTileKind.COLLECTION, c.id, c.name),
                isPinned = false, source = ForYouTileSource.ON_DEVICE, tintHex = COLLECTION_TINT,
            )
        }
        return out
    }

    fun zoneSubtitle(count: Int, source: ForYouTileSource): String {
        if (count <= 0) return "Play a few songs to build your zone"
        return when (source) {
            ForYouTileSource.CLOUD -> "Top picks · recommendation engine"
            ForYouTileSource.ON_DEVICE -> "Top picks from your recent activity"
        }
    }

    fun newReleaseSubtitle(outNow: Int, comingSoon: Int, emptyNote: String? = null): String {
        if (outNow == 0 && comingSoon == 0 && !emptyNote.isNullOrEmpty()) return emptyNote
        return when {
            outNow == 0 && comingSoon == 0 -> "No releases in the last 30 days"
            outNow == 0 -> "From artists you play · upcoming"
            comingSoon == 0 -> "From artists you play · last 30 days"
            else -> "From artists you play · last 30 days + upcoming"
        }
    }
}
