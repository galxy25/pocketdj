package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.recs.ForYouTileKind
import com.levi.pocketdj.data.recs.ForYouTileRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ForYouRoutesTest {
    @Test fun reservedTilesRoundTrip() {
        assertEquals("foryou/new", ForYouRoutes.encode(ForYouTileRoute(ForYouTileKind.NEW, title = "New")))
        assertEquals("foryou/zone", ForYouRoutes.encode(ForYouTileRoute(ForYouTileKind.ZONE, title = "In Da Zone")))
        assertEquals(ForYouTileKind.ZONE, ForYouRoutes.decode("foryou/zone")?.kind)
        assertEquals(ForYouTileKind.NEW, ForYouRoutes.decode(ForYouRoutes.NEW_ROUTE)?.kind)
    }

    @Test fun collectionIdsSurviveSpecialCharacters() {
        val id = "pl 1/é&x"
        val r = ForYouTileRoute(ForYouTileKind.COLLECTION, id, "Mix")
        val back = ForYouRoutes.decode(ForYouRoutes.encode(r)) { "Mix" }
        assertEquals(id, back?.collectionId)
        assertEquals("Mix", back?.title)
        assertEquals("col-$id", back?.tileId)
    }

    @Test fun malformedRoutesDecodeToNull() {
        assertNull(ForYouRoutes.decode("playlist/3"))
        assertNull(ForYouRoutes.decode("foryou/"))
        assertNull(ForYouRoutes.decode("foryou/col-"))
        assertNull(ForYouRoutes.decode("foryou/bogus"))
    }

    @Test fun tabGateIsEngineOrDebugFixture() {
        assertTrue(ForYouGate.visible(recEngineEnabled = true, debugFixture = false))
        assertTrue(ForYouGate.visible(false, true))
        assertFalse(ForYouGate.visible(false, false))
        assertEquals("recEngineEnabled", ForYouGate.REC_ENGINE_ENABLED.name)
    }
}
