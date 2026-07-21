package com.levi.pocketdj.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Exercises the tab registry that drives the bottom navigation bar. */
class PocketDjDestinationTest {

    @Test
    fun bottomNav_hasSixTabsInProductOrder() {
        val labels = PocketDjDestination.bottomNav.map { it.label }
        assertEquals(
            listOf("Browse", "History", "Jukebox", "Playlists", "Mix", "Producer"),
            labels,
        )
    }

    @Test
    fun phases_matchRoadmap() {
        assertEquals(1, PocketDjDestination.Browse.phase)
        assertEquals(1, PocketDjDestination.History.phase)
        assertEquals(1, PocketDjDestination.Jukebox.phase)
        assertEquals(2, PocketDjDestination.Playlists.phase)
        assertEquals(3, PocketDjDestination.Mix.phase)
        assertEquals(4, PocketDjDestination.Producer.phase)
    }

    @Test
    fun routes_areUniqueAndNonBlank() {
        val routes = PocketDjDestination.bottomNav.map { it.route }
        assertEquals("routes must be unique", routes.size, routes.toSet().size)
        assertTrue("routes must be non-blank", routes.all { it.isNotBlank() })
    }
}
