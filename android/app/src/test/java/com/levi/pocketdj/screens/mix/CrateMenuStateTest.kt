package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.mix.download.CatalogShortfall
import com.levi.pocketdj.mix.download.MixDownloadState
import com.levi.pocketdj.mix.model.MixSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CrateMenuStateTest {
    private fun entries() = MixCrateMenuState.entries(
        pockets = listOf(Pocket(id = "p2", name = "zeta"), Pocket(id = "p1", name = "Alpha")),
        playlists = listOf(Playlist(id = "l2", name = "b-side", sequences = emptyList()), Playlist(id = "l1", name = "A-side", sequences = emptyList())),
        setlists = listOf(
            Setlist(id = "s2", name = "Friday"), Setlist(id = "s1", name = null),
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
        val idle = DownloadBarModel.of(MixDownloadState(catalogShortfall = sf)) as DownloadBarModel.Ui.ShortfallOnly
        assertEquals("Only 1 of 20 songs available on this device — catalog still loading", idle.caption)
        val running = DownloadBarModel.of(MixDownloadState(isActive = true, totalCount = 5, downloadedCount = 1, catalogShortfall = sf)) as DownloadBarModel.Ui.Progress
        assertEquals(idle.caption, running.shortfall)
    }
}
