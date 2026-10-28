package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.config.Endpoints

/**
 * What tapping ▶ on a song should do (specs/playback.md §3 — the Android P1
 * resolution ladder; no MusicKit rung exists on Android).
 */
sealed interface PlayAction {
    /**
     * Stream the public rip. For analog (vinyl) songs the URL is the shared
     * album-length mp3 and [clipStartMs]/[clipEndMs] carve this song's window;
     * both are null for digital per-song files. [clipEndMs] is null when the
     * manifest has no `durationMs` (older analog rips) — clip start only and
     * play to the file's natural end, exactly like iOS's whole-file case.
     */
    data class Stream(
        val url: String,
        val clipStartMs: Long? = null,
        val clipEndMs: Long? = null,
    ) : PlayAction {
        /** Unbounded analog window — plays into the album tail (no end boundary). */
        val isUnboundedAnalog: Boolean get() = clipStartMs != null && clipEndMs == null
    }

    /** No manifest entry, but a rip server is configured: POST /rip on explicit ▶. */
    data class RipRequired(val songId: String) : PlayAction

    /** Browsable metadata only — no rip, no server (or a device-local Studio id). */
    data class MetadataOnly(val reason: Reason) : PlayAction {
        enum class Reason { NO_SERVER_CONFIGURED, STUDIO_LOCAL_ID }
    }
}

object PlayResolver {
    /**
     * Device-local Studio artifact prefixes — must NEVER be sent to /rip
     * (the server 400s them; iOS refuses client-side first).
     */
    val STUDIO_ID_PREFIXES = listOf("smp_", "lp_", "ptn_", "tk_")

    fun isStudioId(songId: String): Boolean =
        STUDIO_ID_PREFIXES.any(songId::startsWith)

    /** Playable URL for a manifest entry: `ripsBase + "/" + entry.key`. */
    fun playableUrl(entry: RipManifestEntry): String = Endpoints.ripAudioUrl(entry.key)

    fun resolve(
        songId: String,
        entry: RipManifestEntry?,
        ripServerConfigured: Boolean,
    ): PlayAction {
        if (isStudioId(songId)) {
            return PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.STUDIO_LOCAL_ID)
        }
        if (entry != null) {
            val start = entry.startMs
            val end = if (start != null && entry.durationMs != null) start + entry.durationMs else null
            return PlayAction.Stream(
                url = playableUrl(entry),
                clipStartMs = start,
                clipEndMs = end,
            )
        }
        return if (ripServerConfigured) {
            PlayAction.RipRequired(songId)
        } else {
            PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.NO_SERVER_CONFIGURED)
        }
    }

    /** Result of an edition-aware resolution. [playId] is the storage id actually used. */
    data class EditionResolution(
        val playId: String,
        val action: PlayAction,
        val decision: com.levi.pocketdj.data.edition.EditionPolicy.Decision,
        /** Variant id to enqueue as a background rip, or null. */
        val lazyRipId: String? = null,
        /** Clean-only and nothing stored for the clean edition: skip, never fall back. */
        val skipped: Boolean = false,
    )

    /**
     * Edition pick before resolve: consult EditionPolicy for the song, walk its storage ids
     * against the manifest, then resolve the winning id. Nothing stored under a clean-only
     * decision => skipped (no fallback to the explicit cut).
     */
    fun resolveForEdition(
        songId: String,
        song: com.levi.pocketdj.data.catalog.IndexSong?,
        collectionCleanOnly: Boolean,
        preferExplicitRaw: Boolean?,
        manifestEntry: (String) -> RipManifestEntry?,
        ripServerConfigured: Boolean,
    ): EditionResolution {
        val base = com.levi.pocketdj.data.edition.SongVariant.baseId(songId)
        val decision = com.levi.pocketdj.data.edition.EditionPolicy.decide(
            song, collectionCleanOnly, preferExplicitRaw,
        )
        if (decision.edition == null && decision.reason == com.levi.pocketdj.data.edition.EditionPolicy.Reason.NONE) {
            return EditionResolution(songId, resolve(songId, manifestEntry(songId), ripServerConfigured), decision)
        }
        val isStored = { id: String -> manifestEntry(id) != null }
        val hit = com.levi.pocketdj.data.edition.EditionPolicy.resolveStored(base, decision, isStored)
        val lazy = com.levi.pocketdj.data.edition.EditionPolicy.lazyRipId(base, decision, isStored)
        if (hit == null) {
            if (!decision.allowsStoredFallback) {
                val wanted = decision.edition?.let { com.levi.pocketdj.data.edition.SongVariant.variantId(base, it) } ?: base
                // Clean-only with an acquirable clean id may still rip it; with none, skip.
                return if (decision.catalogId != null && ripServerConfigured) {
                    EditionResolution(wanted, PlayAction.RipRequired(wanted), decision, lazy)
                } else {
                    EditionResolution(wanted, PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.NO_SERVER_CONFIGURED), decision, null, skipped = true)
                }
            }
            return EditionResolution(songId, resolve(songId, null, ripServerConfigured), decision)
        }
        return EditionResolution(hit.id, resolve(hit.id, manifestEntry(hit.id), ripServerConfigured), decision, lazy)
    }
}
