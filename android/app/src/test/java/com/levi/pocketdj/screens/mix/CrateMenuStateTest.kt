package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.mix.download.CatalogShortfall
import com.levi.pocketdj.mix.download.MixDownloadState
import com.levi.pocketdj.mix.model.MixSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CrateMenuStateTest {
    private fun entries() = MixCrateMenuState.entries(
        pockets = listOf(Pocket(id = "p2", name = "zeta"), Pocket(id = "p1", name = "Alpha")),
        playlists = listOf(Playlist(id = "l2", name = "b-side", sequences = emptyList()), Playlist(id = "l1", name = "A-side", sequences = emptyList())),
        setlists = listOf(
            Setlist(id = "s2", playlistId = "l1", name = "Friday"), Setlist(id = "s1", playlistId = "p1", name = null),
            Setlist(id = "orphan", playlistId = "gone", name = "Orphaned"),
            Setlist(id = NOW_PLAYING_SETLIST_ID, name = "Now Playing"),
        ),
    )

    @Test fun sectionsAreInFirstAppearanceOrder() {
        assertEquals(listOf("Pockets", "Playlists", "Set lists"), MixCrateMenuState.sections(entries()))
        // An empty section is simply absent.
        val onlySets = entries().filter { it.section == "Set lists" }
        assertEquals(listOf("Set lists"), MixCrateMenuState.sections(onlySets))
    }

    @Test fun azWithinEachSection_caseInsensitive() {
        val e = entries()
        assertEquals(listOf("Alpha", "zeta"), e.filter { it.section == "Pockets" }.map { it.name })
        assertEquals(listOf("A-side", "b-side"), e.filter { it.section == "Playlists" }.map { it.name })
    }

    @Test fun unnamedSetlistsReadSetList_andReservedNowPlayingIsHidden() {
        val sets = entries().filter { it.section == "Set lists" }
        assertEquals(listOf("Friday", "Set list"), sets.map { it.name })
        assertTrue(sets.none { it.source == MixSource.Setlist(NOW_PLAYING_SETLIST_ID) })
        assertEquals(MixSource.Setlist("s2"), sets.first().source)
    }

    @Test fun orphanedSetlistsAreHidden() {
        assertTrue(entries().none { it.source == MixSource.Setlist("orphan") })
    }

    @Test fun naturalNumericAndDiacriticInsensitiveOrder() {
        val sorted = listOf("Set 10", "set 2", "Éclair", "eclair b", "Zed").sortedWith { a, b -> MixCrateMenuState.naturalCompare(a, b) }
        assertEquals(listOf("Éclair", "eclair b", "set 2", "Set 10", "Zed"), sorted)
    }

    @Test fun rowsPutResetFirstThenHeaderedPicks() {
        val rows = MixCrateMenuState.rows(entries(), MixCrateMenuState.SAME_AS_A)
        assertEquals(MixCrateMenuState.MenuRow.Reset("Same as Crate A"), rows.first())
        assertEquals(MixCrateMenuState.MenuRow.Header("Pockets"), rows[1])
        assertTrue(rows[2] is MixCrateMenuState.MenuRow.Pick)
        // No reset row without a reset title.
        assertTrue(MixCrateMenuState.rows(entries(), null).first() is MixCrateMenuState.MenuRow.Header)
    }

    @Test fun emptyListShowsTheEmptyRow() {
        val rows = MixCrateMenuState.rows(emptyList(), null)
        assertEquals(listOf<MixCrateMenuState.MenuRow>(MixCrateMenuState.MenuRow.Empty), rows)
    }

    @Test fun equalEntryListsAreEqual_soTheMenuCanSkip() {
        // The skippability contract: rebuilding entries from the same collections yields an EQUAL value.
        assertEquals(MixCrateEntries(entries()), MixCrateEntries(entries()))
    }

    @Test fun labelText() {
        assertEquals("A · Alpha", MixCrateMenuState.label("A", "Alpha", "Pick a collection"))
        assertEquals("B · Same as A", MixCrateMenuState.label("B", null, "Same as A"))
    }

    // ---- download bar model ---------------------------------------------------------------

    @Test fun downloadBar_progressRows() {
        val st = MixDownloadState(isActive = true, totalCount = 10, downloadedCount = 4, rippingCount = 2, etaSeconds = 200.0)
        val ui = DownloadBarModel.of(st) as DownloadBarModel.Ui.Progress
        assertEquals("4 of 10 downloaded", ui.headline)
        assertEquals("· ~3m 20s left", ui.eta)
        assertEquals("· 2 ripping", ui.ripping)
        assertEquals(0.4f, ui.fraction, 0.0001f)
        assertNull(ui.shortfall)
    }

    @Test fun downloadBar_hiddenWhenCompleteIdleOrNoSamples() {
        assertNull(DownloadBarModel.of(MixDownloadState()))
        assertNull(DownloadBarModel.of(MixDownloadState(isActive = true, totalCount = 3, downloadedCount = 3)))
        val noEta = DownloadBarModel.of(MixDownloadState(isActive = true, totalCount = 3, downloadedCount = 1)) as DownloadBarModel.Ui.Progress
        assertEquals("· ~— left", noEta.eta)
        assertNull(noEta.ripping)
    }

    @Test fun downloadBar_shortfallCaptionWithAndWithoutRun() {
        val sf = CatalogShortfall(declared = 20, total = 1)
        val idle = DownloadBarModel.of(MixDownloadState(catalogShortfall = sf, catalogStillLoading = true)) as DownloadBarModel.Ui.ShortfallOnly
        assertEquals("Only 1 of 20 songs available on this device — catalog still loading", idle.caption)
        val running = DownloadBarModel.of(MixDownloadState(isActive = true, totalCount = 5, downloadedCount = 1, catalogShortfall = sf, catalogStillLoading = true)) as DownloadBarModel.Ui.Progress
        assertEquals(idle.caption, running.shortfall)
        // P2-MIX-1: "still loading" only while the catalog actually is - afterwards the honest "not in this catalog" copy.
        val done = DownloadBarModel.of(MixDownloadState(catalogShortfall = sf)) as DownloadBarModel.Ui.ShortfallOnly
        assertEquals("19 of 20 crate songs aren\u2019t in this device\u2019s catalog \u2014 a source may be missing or disabled", done.caption)
    }

    @Test fun downloadBar_surfacesLaneIssueAndOffersNowPlayingOnlyWhenNothingCanFetch() {
        fun ui(issue: com.levi.pocketdj.mix.download.LaneIssue?) = DownloadBarModel.of(
            MixDownloadState(isActive = true, totalCount = 418, downloadedCount = 404, rippingCount = 4, laneIssue = issue),
        ) as DownloadBarModel.Ui.Progress
        val healthy = ui(null)
        assertEquals("\u00B7 4 ripping", healthy.ripping)
        assertNull(healthy.issue)
        assertFalse(healthy.offerNowPlaying)
        val rejected = ui(com.levi.pocketdj.mix.download.LaneIssue.TokenRejected)
        assertEquals("The import server rejected this device\u2019s token (Settings \u25B8 Import server)", rejected.issue)
        assertEquals("\u00B7 4 can\u2019t rip \u2014 import server rejected this device\u2019s token", rejected.ripping)
        assertTrue(rejected.offerNowPlaying)
        assertTrue(ui(com.levi.pocketdj.mix.download.LaneIssue.NoServer).offerNowPlaying)
        val stalled = ui(com.levi.pocketdj.mix.download.LaneIssue.RipsStalled)
        assertFalse(stalled.offerNowPlaying)
        assertNull(stalled.issue)
    }
}
