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
}
