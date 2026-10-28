package com.levi.pocketdj.data.edition

import com.levi.pocketdj.data.catalog.IndexSong

/**
 * THE edition decision (port of iOS EditionPolicy). Precedence: collection clean-only >
 * global tri-state "Prefer explicit versions" (null = never chosen => unchanged) > unchanged.
 * A substitution is real only when the wanted edition's id is known and != the primary id.
 */
object EditionPolicy {
    enum class Reason { COLLECTION_CLEAN_ONLY, GLOBAL_PREFERENCE, NONE }

    data class Decision(
        val edition: SongVariant?,
        val reason: Reason,
        /** Catalog id of [edition]; null => never enqueue a rip for it. */
        val catalogId: String?,
    ) {
        /** Clean-only is skip-not-fallback; the global preference may degrade onto stored files. */
        val allowsStoredFallback: Boolean get() = reason != Reason.COLLECTION_CLEAN_ONLY

        companion object {
            val UNCHANGED = Decision(null, Reason.NONE, null)
        }
    }

    fun decide(song: IndexSong?, collectionCleanOnly: Boolean, preferExplicitRaw: Boolean?): Decision {
        if (song == null) return Decision.UNCHANGED
        if (collectionCleanOnly) {
            if (song.explicit != true) return Decision.UNCHANGED
            return substitution(song, SongVariant.CLEAN, Reason.COLLECTION_CLEAN_ONLY)
        }
        val prefer = preferExplicitRaw ?: return Decision.UNCHANGED
        return substitution(
            song,
            if (prefer) SongVariant.EXPLICIT else SongVariant.CLEAN,
            Reason.GLOBAL_PREFERENCE,
        )
    }

    private fun substitution(song: IndexSong, edition: SongVariant, reason: Reason): Decision {
        val id = song.appleMusicId(edition)
        if (id.isNullOrEmpty()) {
            return if (reason == Reason.COLLECTION_CLEAN_ONLY) Decision(edition, reason, null)
            else Decision.UNCHANGED
        }
        if (id == song.appleMusicId) return Decision.UNCHANGED
        return Decision(edition, reason, id)
    }

    /** Ordered storage ids: [wanted, base, other] with fallback; [wanted] only without. */
    fun storageIds(base: String, edition: SongVariant?, allowFallback: Boolean): List<String> {
        if (edition == null) return listOf(base)
        val wanted = SongVariant.variantId(base, edition)
        if (!allowFallback) return listOf(wanted)
        val other = if (edition == SongVariant.EXPLICIT) SongVariant.CLEAN else SongVariant.EXPLICIT
        return listOf(wanted, base, SongVariant.variantId(base, other))
    }

    data class Stored(val id: String, val isWanted: Boolean)

    fun resolveStored(base: String, decision: Decision, isStored: (String) -> Boolean): Stored? {
        val ids = storageIds(base, decision.edition, decision.allowsStoredFallback)
        val hit = ids.firstOrNull(isStored) ?: return null
        return Stored(hit, hit == ids[0])
    }

    /** Id to lazily rip when the wanted edition isn't stored; null when nothing should be acquired. */
    fun lazyRipId(base: String, decision: Decision, isStored: (String) -> Boolean): String? {
        val edition = decision.edition ?: return null
        if (decision.catalogId.isNullOrEmpty()) return null
        val wanted = SongVariant.variantId(base, edition)
        return if (isStored(wanted)) null else wanted
    }
}

/** Clean-versions-only resolution for a collection with `cleanOnly` on. */
object CleanOnly {
    data class Resolved(val ids: List<String>, val variants: Map<String, SongVariant>)

    /** Explicit with no clean edition => skipped. Null song (unknown id) never skipped. */
    fun isSkipped(song: IndexSong?): Boolean =
        song != null && song.explicit == true && song.appleMusicId(SongVariant.CLEAN) == null

    fun resolve(ids: List<String>, songsById: Map<String, IndexSong>): Resolved {
        val out = ArrayList<String>()
        val variants = LinkedHashMap<String, SongVariant>()
        for (id in ids) {
            val s = songsById[id]
            if (s == null || s.explicit != true) { out += id; continue }
            val d = EditionPolicy.decide(s, collectionCleanOnly = true, preferExplicitRaw = null)
            val v = d.edition
            if (v != null && d.catalogId != null) {
                out += id
                variants[id] = v
            }
            // else dropped: never fall back to the explicit cut
        }
        return Resolved(out, variants)
    }

    fun ripIds(ids: List<String>, songsById: Map<String, IndexSong>): List<String> {
        val r = resolve(ids, songsById)
        return r.ids.map { id -> r.variants[id]?.let { SongVariant.variantId(id, it) } ?: id }
    }
}
