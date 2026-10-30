package com.levi.pocketdj.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Exercises the tab registry that drives the navigation bar / rail. */
class PocketDjDestinationTest {

    @Test
    fun bottomNav_hasSevenDestinationsInPinnedOrder() {
        val labels = PocketDjDestination.bottomNav.map { it.label }
        assertEquals(
            listOf("Browse", "History", "Jukebox", "Collections", "Mix", "Producer", "Games"),
            labels,
        )
    }

    @Test
    fun q7_barShowsThreeTabsAndMoreFoldsTheRest() {
        assertEquals(listOf("Browse", "History", "Collections"), PocketDjDestination.barTabs.map { it.label })
        assertEquals(listOf("Jukebox", "Games", "Mix", "Producer"), PocketDjDestination.moreTabs.map { it.label })
        assertEquals(PocketDjDestination.entries.toSet(), (PocketDjDestination.barTabs + PocketDjDestination.moreTabs).toSet())
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

    @Test
    fun token_roundTripsForAllSevenDestinations() {
        PocketDjDestination.entries.forEach { dest ->
            assertEquals(dest, PocketDjDestination.fromToken(dest.token))
        }
        assertEquals(7, PocketDjDestination.entries.map { it.token }.toSet().size)
    }

    @Test
    fun tokens_arePinnedToTheIosSectionRawValues() {
        assertEquals("Browser", PocketDjDestination.Browse.token)
        assertEquals("Jukebox Hero", PocketDjDestination.Jukebox.token)
        assertEquals("Playlists", PocketDjDestination.Playlists.token) // label is Collections
        assertEquals("Performance", PocketDjDestination.Producer.token) // label is Producer
        assertEquals("Games", PocketDjDestination.Games.token)
    }

    @Test
    fun unknownOrBlankToken_landsOnHistory() {
        assertEquals(PocketDjDestination.History, PocketDjDestination.fromToken(null))
        assertEquals(PocketDjDestination.History, PocketDjDestination.fromToken(""))
        assertEquals(PocketDjDestination.History, PocketDjDestination.fromToken("Settings"))
        assertEquals(PocketDjDestination.History, PocketDjDestination.default)
    }
}
