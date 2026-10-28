package com.levi.pocketdj.data.games.friends

import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.shell.DeepLink
import com.levi.pocketdj.shell.DeepLinkSeams
import com.levi.pocketdj.shell.ShellRoute
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class MwFDeepLinkHandlerTest {
    private val opened = mutableListOf<MwFLink>()
    private val routes = mutableListOf<ShellRoute>()
    private val handler = MwFDeepLinkHandler({ opened += it }, { routes += it })

    @Test fun seamLinkOpensAndLandsOnGames() {
        assertTrue(handler.open(DeepLink.Mwf("abcd2345", "https://jukebox.pocket-dj.com")))
        assertEquals(listOf(MwFLink("abcd2345", "https://jukebox.pocket-dj.com")), opened)
        assertEquals(listOf<ShellRoute>(ShellRoute.Tab(PocketDjDestination.Games)), routes)
    }

    @Test fun invalidIdIsRejectedWithoutSideEffects() {
        assertFalse(handler.open(DeepLink.Mwf("BAD!", null)))
        assertTrue(opened.isEmpty() && routes.isEmpty())
    }

    @Test fun rawUrlsBothFormsParse() {
        assertTrue(handler.openUrl("pocketdj://mwf/abcd2345"))
        assertTrue(handler.openUrl("https://jukebox.pocket-dj.com/mwf/zzzz2345/"))
        assertFalse(handler.openUrl("https://example.com/mwf/abcd2345"))
        assertEquals(listOf("abcd2345", "zzzz2345"), opened.map { it.sessionId })
        assertNull(opened[0].guestBase)
        assertEquals("https://jukebox.pocket-dj.com", opened[1].guestBase)
    }

    @Test fun installClaimsSeamAndReplaysParkedLink() {
        val seams = DeepLinkSeams()
        handler.install(seams) { DeepLink.Mwf("abcd2345", null) }
        assertEquals(1, opened.size)
        val seam = seams.mwf!!
        seam(DeepLink.Mwf("wxyz2345", null))
        assertEquals(listOf("abcd2345", "wxyz2345"), opened.map { it.sessionId })
        assertEquals(2, routes.size)
    }
}
