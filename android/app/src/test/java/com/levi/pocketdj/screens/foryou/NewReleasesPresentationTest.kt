package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.recs.ArtistReleaseEntry
import com.levi.pocketdj.data.recs.ForYouTileKind
import com.levi.pocketdj.data.recs.ReleaseEmptyReason
import com.levi.pocketdj.data.recs.ReleaseFeedItem
import com.levi.pocketdj.data.recs.ReleaseStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NewReleasesPresentationTest {
    private val day = 86_400_000.0
    private val now = 1_800_000_000_000.0
    private fun item(id: Int, status: ReleaseStatus = ReleaseStatus.OUT_NOW) =
        ReleaseFeedItem(ArtistReleaseEntry(id, "A$id", 0.0, "r$id", "N$id", now), status)

    private val items = (1..4).map { item(it) }

    @Test fun scopeIsTheReservedNewScope() {
        assertEquals(ForYouTileKind.NEW.raw, NewReleasesPresentation.SCOPE)
        assertEquals("new", NewReleasesPresentation.SCOPE)
    }

    @Test fun thumbedUpReleasesLeaveEntirely() {
        val out = NewReleasesPresentation.offered(items, mapOf("rel:r2" to 1.0))
        assertEquals(listOf(1, 3, 4), out.map { it.id })
        assertEquals(items, NewReleasesPresentation.offered(items, emptyMap()))
    }

    @Test fun thumbedDownReleasesSinkButStayRenderable() {
        val sunk = mapOf("rel:r1" to 1.0, "rel:r3" to 1.0)
        assertEquals(listOf(2, 4, 1, 3), NewReleasesPresentation.sunkLast(items, sunk).map { it.id })
        assertEquals(items, NewReleasesPresentation.sunkLast(items, emptyMap()))
    }

    @Test fun playListIsTheLiveHalfAndTransportGatesOnIt() {
        val sunk = mapOf("rel:r1" to 1.0, "rel:r2" to 1.0, "rel:r3" to 1.0, "rel:r4" to 1.0)
        val rendered = NewReleasesPresentation.sunkLast(items, sunk)
        val live = NewReleasesPresentation.live(rendered, sunk)
        assertEquals(4, rendered.size) // still on screen so the lit thumb can be undone
        assertTrue(live.isEmpty())
        // The shipped bug: gating on the render list left play lit over an empty queue.
        assertFalse(NewReleasesPresentation.canPlay(false, live))
        assertTrue(NewReleasesPresentation.canPlay(false, items))
        assertFalse("busy expanding", NewReleasesPresentation.canPlay(true, items))
    }

    @Test fun relativeWordingKeepsFuturesApart() {
        fun r(deltaDays: Double) = NewReleasesPresentation.relative(now + deltaDays * day, now)
        assertEquals("Today", r(0.0))
        assertEquals("Yesterday", r(-1.0))
        assertEquals("3 days ago", r(-3.0))
        assertEquals("30 days ago", r(-30.0))
        assertEquals("Tomorrow", r(1.0))
        assertEquals("In 6 days", r(6.0))
        assertEquals("In 90 days", r(90.0))
    }

    @Test fun artworkTemplateIsSubstituted() {
        assertEquals(
            "https://x/96x96bb.jpg",
            NewReleasesPresentation.artworkUrl("https://x/{w}x{h}bb.jpg", 96),
        )
        assertNull(NewReleasesPresentation.artworkUrl(null, 96))
    }

    @Test fun everyEmptyStateIsDistinguishable() {
        val reasons = listOf(
            ReleaseEmptyReason.Checking,
            ReleaseEmptyReason.NotAuthorized,
            ReleaseEmptyReason.Unreachable("Couldn't check 3 artists."),
            ReleaseEmptyReason.NotCheckedYet,
            ReleaseEmptyReason.NothingNew,
        )
        assertEquals(5, reasons.map { NewReleasesPresentation.emptyTitle(it) }.toSet().size)
        assertEquals(5, reasons.map { NewReleasesPresentation.emptyDetail(it) }.toSet().size)
        assertTrue(NewReleasesPresentation.emptyDetail(reasons[2]).startsWith("Couldn't check 3 artists."))
        assertEquals("Nothing new in the last 30 days", NewReleasesPresentation.emptyTitle(ReleaseEmptyReason.NothingNew))
    }

    @Test fun albumLinkOpensTheCatalogPage() {
        assertEquals("https://music.apple.com/us/album/123", NewReleasesPresentation.albumUrl("123"))
    }
}
