package com.levi.pocketdj.screens.games

import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.shell.DeepLinkSeams
import com.levi.pocketdj.shell.GameLink
import com.levi.pocketdj.shell.ShellRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GamesDeepLinkTest {
    private val routes = mutableListOf<ShellRoute>()
    private val handler = GameLinkHandler { routes += it }

    @Test fun openPostsGamesTabAndParksGameUntilConsumed() {
        handler.open(GameLink.InThePocket)
        assertEquals(listOf<ShellRoute>(ShellRoute.Tab(PocketDjDestination.Games)), routes)
        assertEquals(GameLink.InThePocket, handler.pendingGame.value)
        assertEquals(GameLink.InThePocket, handler.consume())
        assertNull(handler.consume())
    }

    @Test fun installClaimsSeamAndReplaysEarlyLink() {
        val seams = DeepLinkSeams()
        handler.install(seams) { GameLink.Puzzle }
        assertEquals(GameLink.Puzzle, handler.pendingGame.value)
        seams.game!!.invoke(GameLink.InThePocket)
        assertEquals(GameLink.InThePocket, handler.consume())
        assertEquals(2, routes.size)
    }

    @Test fun lenientTokens() {
        assertEquals(GameLink.Puzzle, GameLink.fromToken("Gems"))
        assertEquals(GameLink.InThePocket, GameLink.fromToken("ITP"))
        assertNull(GameLink.fromToken(null))
    }

    @Test fun applyGameLinkPuzzleOpensOnlyPuzzleAndClearsSession() {
        assertEquals(GameLinkState(true, false, null), applyGameLink(GameLink.Puzzle))
    }

    @Test fun applyGameLinkInThePocketOpensOnlyItp() {
        assertEquals(GameLinkState(false, true, null), applyGameLink(GameLink.InThePocket))
    }

    @Test fun lenientTokensCoverGameNames() {
        for (t in listOf("gem-collector", "gemcollector", "collectorsPuzzle", "collectors_puzzle", "Gem-Collector"))
            assertEquals(t, GameLink.Puzzle, GameLink.fromToken(t))
    }
}
