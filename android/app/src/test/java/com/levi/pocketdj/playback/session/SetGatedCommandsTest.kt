package com.levi.pocketdj.playback.session

import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SetGatedCommandsTest {
    private val all = Player.Commands.Builder().addAllCommands().build()

    @Test fun notRunningLacksGatedCommands() {
        val c = SetGate.apply(all, false)
        SetGate.GATED.forEach { assertFalse("cmd $it", c.contains(it)) }
        assertTrue(c.contains(Player.COMMAND_PLAY_PAUSE))
        assertTrue(c.contains(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM))
    }

    @Test fun multiItemTimelinePassesBaseCommandsThrough() {
        val c = SetGate.apply(all, false, itemCount = 3)
        SetGate.GATED.forEach { assertTrue(it.toString(), c.contains(it)) }
    }

    @Test fun baseEventsAreRewrittenToTheGatedSet() {
        val ps = FakePlayerState()
        val gp = SetGatedPlayer(fakePlayer(ps))
        val got = mutableListOf<Player.Commands>()
        gp.addListener(object : Player.Listener {
            override fun onAvailableCommandsChanged(availableCommands: Player.Commands) { got += availableCommands }
        })
        ps.listeners.single().onAvailableCommandsChanged(all) // ExoPlayer pushes ungated commands
        assertFalse(got.single().contains(Player.COMMAND_SEEK_TO_NEXT))
        gp.updateSetRunning(true)
        ps.listeners.single().onAvailableCommandsChanged(Player.Commands.Builder().add(Player.COMMAND_PLAY_PAUSE).build())
        assertTrue(got.last().contains(Player.COMMAND_SEEK_TO_NEXT))
        gp.removeListener(gp.let { _ -> object : Player.Listener {} }) // unknown listener is harmless
    }

    @Test fun runningIncludesThemEvenIfBaseLacksThem() {
        val bare = Player.Commands.Builder().add(Player.COMMAND_PLAY_PAUSE).build()
        val c = SetGate.apply(bare, true)
        SetGate.GATED.forEach { assertTrue(c.contains(it)) }
    }

    @Test fun diffedUpdatesDoNotChurn() {
        val ps = FakePlayerState()
        val gp = SetGatedPlayer(fakePlayer(ps))
        var changes = 0
        gp.addListener(object : Player.Listener {
            override fun onAvailableCommandsChanged(availableCommands: Player.Commands) { changes++ }
        })
        assertFalse(gp.updateSetRunning(false))
        assertTrue(gp.updateSetRunning(true))
        assertFalse(gp.updateSetRunning(true))
        assertFalse(gp.updateSetRunning(true))
        assertTrue(gp.updateSetRunning(false))
        assertFalse(gp.updateSetRunning(false))
        assertEquals(2, changes)
    }

    @Test fun favoriteVisibilityRules() {
        val seam = object : FavoriteSeam {
            var avail = true
            val faved = mutableSetOf<String>()
            override val isAvailable get() = avail
            override fun isFavorite(songId: String) = songId in faved
            override fun toggle(songId: String) { if (!faved.add(songId)) faved.remove(songId) }
        }
        assertFalse(FavoriteCommand.visible(null, "s1"))
        assertFalse(FavoriteCommand.visible(seam, null))
        assertTrue(FavoriteCommand.visible(seam, "s1"))
        assertFalse(FavoriteCommand.filled(seam, "s1"))
        assertTrue(FavoriteCommand.press(seam, "s1"))
        assertTrue(FavoriteCommand.filled(seam, "s1"))
        seam.avail = false // Mix owns audio
        assertFalse(FavoriteCommand.press(seam, "s1"))
        assertTrue("s1" in seam.faved)
        assertTrue(FavoriteCommand.layout(seam, "s1").isEmpty())
    }
}
