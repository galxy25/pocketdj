package com.levi.pocketdj.shell

import com.levi.pocketdj.navigation.PocketDjDestination
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ShellTabsTest {
    @Test fun pushedScreenKeepsItsParentTabSelected() {
        // Start tab Browse, switched to Collections, then pushed a playlist and Now Playing.
        assertEquals(
            PocketDjDestination.Playlists,
            ShellTabs.owningTab(listOf(null, "browse", "playlists", "playlist/{id}", "nowplaying")),
        )
        assertEquals(PocketDjDestination.Browse, ShellTabs.owningTab(listOf(null, "browse", "album/{albumId}")))
        assertEquals(PocketDjDestination.Mix, ShellTabs.owningTab(listOf("browse", "mix")))
    }

    @Test fun noTabOnStackIsNull() {
        assertNull(ShellTabs.owningTab(emptyList()))
        assertNull(ShellTabs.owningTab(listOf(null, "settings")))
    }

    @Test fun moreFoldedSectionsLightTheMoreSlot() {
        // Q7: Jukebox, Games, Mix, Producer live under More (deep link straight to Mix included).
        assertEquals(BarItem.More, ShellTabs.owningBarItem(listOf("history", "mix")))
        assertEquals(BarItem.More, ShellTabs.owningBarItem(listOf("history", MORE_ROUTE, "producer")))
        assertEquals(BarItem.More, ShellTabs.owningBarItem(listOf("history", MORE_ROUTE)))
        assertEquals(BarItem.More, ShellTabs.owningBarItem(listOf("browse", "jukebox", "jukebox/join/{jukeboxId}")))
        assertEquals(BarItem.Collections, ShellTabs.owningBarItem(listOf("browse", "playlists", "nowplaying")))
        assertEquals(BarItem.Browse, ShellTabs.owningBarItem(listOf("browse", "settings")))
        assertNull(ShellTabs.owningBarItem(emptyList()))
        assertEquals(MORE_ROUTE, ShellTabs.routeFor(BarItem.More))
        assertEquals("history", ShellTabs.routeFor(BarItem.History))
        assertEquals(listOf("Browse", "History", "Collections", "More"), BarItem.entries.map { it.label })
    }
}
