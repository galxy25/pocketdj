package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.recs.ArtistReleaseEntry
import com.levi.pocketdj.data.settings.AppSettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import com.levi.pocketdj.data.recs.ForYouRelease
import com.levi.pocketdj.data.recs.ForYouReleaseSource
import com.levi.pocketdj.data.recs.LikedRelease
import com.levi.pocketdj.data.recs.ReleaseFeedItem
import com.levi.pocketdj.data.recs.ReleaseFeedService
import com.levi.pocketdj.data.recs.ReleaseStatus

/*
 * For You ▸ New: albums vs singles (iOS `NewReleaseKind.swift`; design doc
 * docs/design/foryou-new-kind-filter.md). Levi, 2026-11-23: "for New we should be able to hide or sort
 * albums vs singles; for me I would only want to see albums, for others singles, and others albums first and
 * then singles - as three separate user stories".
 *
 * One pure function decides what a mode shows, so the screen, the tile count and ▶/🔀 can't disagree.
 */

/** What a release IS for filtering - not what Apple's `releaseKind` claims. */
enum class ReleaseKindClass(val raw: String) {
    ALBUM("album"), EP("ep"), SINGLE("single");

    /** album bucket = {album, EP, compilation}; single bucket = {single}. */
    val isAlbumBucket: Boolean get() = this != SINGLE
}

/** Which releases New shows and in what order. `raw` is PERSISTED - never rename. */
enum class NewReleaseKindFilter(val raw: String, val label: String) {
    ALL("all", "Everything"),
    ALBUMS("albums", "Albums only"),
    SINGLES("singles", "Singles only"),
    ALBUMS_FIRST("albumsFirst", "Albums, then singles");

    companion object {
        /** The persisted mode, read once BEFORE first composition so a saved choice never flashes as Everything. */
        fun initial(settings: Flow<AppSettings>): NewReleaseKindFilter =
            runBlocking { from(settings.first().newReleaseKind) }

        /** Missing or unknown raw → ALL (upgrade-safe). */
        fun from(raw: String?): NewReleaseKindFilter = entries.firstOrNull { it.raw == raw } ?: ALL
    }
}

object NewReleaseKinds {

    /**
     * First match wins. Apple suffixes catalog names with " - Single" / " - EP", so the NAME is the most
     * trustworthy signal; then the flag; the track count only guesses (1-3 single, 4-6 EP). An Apple-declared
     * single with many tracks (a remix bundle) stays a single. Unknown everything → album.
     */
    fun classify(kind: String?, name: String?, trackCount: Int?): ReleaseKindClass {
        val n = (name ?: "").trim().lowercase()
        if (n.endsWith(" - single") || n.endsWith(" – single")) return ReleaseKindClass.SINGLE
        if (n.endsWith(" - ep") || n.endsWith(" – ep")) return ReleaseKindClass.EP
        when (kind?.lowercase()) {
            "single" -> return ReleaseKindClass.SINGLE
            "ep" -> return ReleaseKindClass.EP
            // The declared kind wins over the track-count guess (classical works, lead-track pre-orders, compilations).
            "album", "compilation" -> return ReleaseKindClass.ALBUM
        }
        if (trackCount != null) {
            if (trackCount in 1..3) return ReleaseKindClass.SINGLE
            if (trackCount in 4..6) return ReleaseKindClass.EP
        }
        return ReleaseKindClass.ALBUM
    }

    /** The row badge: the CLASS (so a 2-track "album" under Singles only doesn't say Album); Compilation kept. */
    fun badge(kind: String?, cls: ReleaseKindClass): String {
        if (cls == ReleaseKindClass.ALBUM && kind?.lowercase() == "compilation") return "Compilation"
        return when (cls) {
            ReleaseKindClass.ALBUM -> "Album"
            ReleaseKindClass.EP -> "EP"
            ReleaseKindClass.SINGLE -> "Single"
        }
    }

    /**
     * One section, filtered and ordered. [albums]: album bucket in display order (everything in ALL);
     * [singles]: single bucket (empty in ALBUMS and ALL); [grouped] only for ALBUMS_FIRST; [flat] is what
     * renders / plays - in ALL exactly `sink(items)`.
     */
    data class Arranged<T>(
        val albums: List<T>,
        val singles: List<T>,
        val grouped: Boolean,
        val flat: List<T>,
        val hiddenAlbums: Int,
        val hiddenEPs: Int,
        val hiddenSingles: Int,
    ) {
        val hiddenTotal: Int get() = hiddenAlbums + hiddenSingles
    }

    /** [sink] is the rejected-sinks-last rule, applied INSIDE each group so a 👎'd album stays above the singles. */
    fun <T> arrange(
        items: List<T>,
        mode: NewReleaseKindFilter,
        cls: (T) -> ReleaseKindClass,
        sink: (List<T>) -> List<T> = { it },
    ): Arranged<T> = when (mode) {
        NewReleaseKindFilter.ALL -> sink(items).let { Arranged(it, emptyList(), false, it, 0, 0, 0) }
        NewReleaseKindFilter.ALBUMS -> {
            val a = sink(items.filter { cls(it).isAlbumBucket })
            Arranged(a, emptyList(), false, a, 0, 0, items.size - a.size)
        }
        NewReleaseKindFilter.SINGLES -> {
            val s = sink(items.filter { !cls(it).isAlbumBucket })
            Arranged(emptyList(), s, false, s, items.size - s.size, items.count { cls(it) == ReleaseKindClass.EP }, 0)
        }
        NewReleaseKindFilter.ALBUMS_FIRST -> {
            val a = sink(items.filter { cls(it).isAlbumBucket })
            val s = sink(items.filter { !cls(it).isAlbumBucket })
            Arranged(a, s, true, a + s, 0, 0, 0)
        }
    }

    /** "3 singles hidden" · "1 single hidden" · "2 albums hidden" · "2 albums & EPs hidden" · null if none. */
    fun hiddenNote(albums: Int, eps: Int, singles: Int): String? {
        val parts = mutableListOf<String>()
        if (albums > 0) parts += "$albums ${if (eps > 0) "albums & EPs" else if (albums == 1) "album" else "albums"}"
        if (singles > 0) parts += "$singles ${if (singles == 1) "single" else "singles"}"
        if (parts.isEmpty()) return null
        return parts.joinToString(", ") + " hidden"
    }

    /** Albums-only footer caveat: the feed keeps one latest release per artist, so a newer single can displace its album. */
    fun footerCaveat(mode: NewReleaseKindFilter, hiddenSingles: Int): String? =
        if (mode == NewReleaseKindFilter.ALBUMS && hiddenSingles > 0) "A newer single can hide an artist's album." else null

    /** "albums" / "singles": what a mode is looking at, for "No new albums". */
    fun shownNoun(mode: NewReleaseKindFilter): String = if (mode == NewReleaseKindFilter.SINGLES) "singles" else "albums"

    fun emptyNote(mode: NewReleaseKindFilter, hidden: String): String = "No new ${shownNoun(mode)} · $hidden"

    /**
     * What play / shuffle queue: the OFFERED out-now list arranged by [mode], rejected dropped. The caller
     * passes the already-offered list (accepted removed). `ReleaseStreaming` caps AFTER this ordering, so in
     * ALBUMS_FIRST the singles are what get cut.
     */
    fun liveOutNow(
        offered: List<ReleaseFeedItem>,
        mode: NewReleaseKindFilter,
        tombstones: Map<String, Double>,
    ): List<ReleaseFeedItem> {
        val arranged = arrange(offered, mode, { it.entry.kindClass }, { NewReleasesPresentation.sunkLast(it, tombstones) })
        return NewReleasesPresentation.live(arranged.flat, tombstones)
    }
}

val ArtistReleaseEntry.kindClass: ReleaseKindClass
    get() = NewReleaseKinds.classify(releaseKind, releaseName, trackCount)

val LikedRelease.kindClass: ReleaseKindClass
    get() = NewReleaseKinds.classify(kind, title, trackCount)

/**
 * The For You grid's view of the feed through the albums/singles choice: the New tile counts only what its
 * screen shows. Lives here rather than in `ForYouGrid`/`ForYouTiles` (shared with the parity branch); the
 * "Albums from …" subtitle prefix waits for that branch to land. Implemented over `service.feed`, not
 * `ReleaseFeedForYouSource`, so that file stays untouched.
 */
class KindFilteredForYouSource(
    private val service: ReleaseFeedService,
    private val mode: NewReleaseKindFilter,
) : ForYouReleaseSource {
    private fun shown(nowMs: Double) =
        NewReleaseKinds.arrange(service.feed(nowMs), mode, { it.entry.kindClass })

    override fun feed(nowMs: Double): List<ForYouRelease> =
        shown(nowMs).flat.map { ForYouRelease(it.feedbackId, it.status == ReleaseStatus.COMING_SOON) }

    /** The filter's own note when IT emptied the tile ("No new albums · 3 singles hidden"), else the reason. */
    override fun emptyTileNote(): String? {
        val a = shown(System.currentTimeMillis().toDouble())
        if (a.flat.isEmpty()) {
            val hidden = NewReleaseKinds.hiddenNote(a.hiddenAlbums, a.hiddenEPs, a.hiddenSingles)
            if (hidden != null) return NewReleaseKinds.emptyNote(mode, hidden)
        }
        return service.emptyReason().tileNote
    }
}
