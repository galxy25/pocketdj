package com.levi.pocketdj.data.burns

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class BeatGridSidecarTest {
    @Test fun decodesFullSidecarAndIgnoresUnknownKeys() {
        val g = BeatGridSidecar.parse("""{"beatGridBpm":124.5,"firstDownbeatMs":310,"steady":true,"beatsMs":[0,480,960],"downbeatsMs":[0],"future":1}""")!!
        assertEquals(124.5, g.beatGridBpm!!, 0.0)
        assertEquals(310, g.firstDownbeatMs)
        assertEquals(listOf(0, 480, 960), g.beatsMs)
    }

    @Test fun missingArraysDefaultEmptyLikeIos() {
        val g = BeatGridSidecar.parse("{}")!!
        assertEquals(emptyList<Int>(), g.beatsMs)
        assertNotNull(g)
    }

    @Test fun garbageAndErrorDocumentsAreRejected() {
        assertNull(BeatGridSidecar.parse("<?xml version=\"1.0\"?><Error/>"))
        assertNull(BeatGridSidecar.parse("{\"beatsMs\":[1,2"))
        assertNull(BeatGridSidecar.parse("[1,2,3]"))
        assertNull(BeatGridSidecar.parse(""))
    }
}
