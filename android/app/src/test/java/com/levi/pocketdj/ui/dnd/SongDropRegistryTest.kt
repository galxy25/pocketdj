package com.levi.pocketdj.ui.dnd

import androidx.compose.ui.geometry.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class SongDropRegistryTest {
    private fun entry(r: Rect, log: MutableList<String>, name: String) =
        SongDropRegistry.Entry({ r }, { log += "$name:$it" }, { log += "$name:drop"; true })

    @Test fun smallestContainingBoundsWinsAndDropRoutesThere() {
        val log = mutableListOf<String>()
        val list = entry(Rect(0f, 0f, 100f, 100f), log, "list")
        val row = entry(Rect(0f, 10f, 100f, 30f), log, "row")
        SongDropRegistry.register(list); SongDropRegistry.register(row)
        try {
            assertSame(row, SongDropRegistry.entryAt(5f, 20f))
            assertSame(list, SongDropRegistry.entryAt(5f, 60f))
            assertNull(SongDropRegistry.entryAt(500f, 500f))
            SongDropRegistry.hoverAt(5f, 20f)
            SongDropRegistry.hoverAt(5f, 60f)
            assertEquals(listOf("row:true", "row:false", "list:true"), log)
            log.clear()
            SongDropRegistry.dropAt(5f, 20f, com.levi.pocketdj.data.collections.SongTransfer(listOf("x"), null))
            assertEquals(listOf("list:false", "row:drop"), log)
        } finally { SongDropRegistry.unregister(list); SongDropRegistry.unregister(row) }
    }
}
