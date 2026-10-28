package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.shell.NavRequestBus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BrowsePendingQueryTest {
    @Test fun parkedSearchTermLandsInTheSearchField() {
        NavRequestBus.reset()
        BrowseSession.query.value = ""
        assertFalse(BrowseSession.consumePendingQuery())
        NavRequestBus.setPendingBrowseQuery("  daft punk ")
        assertTrue(BrowseSession.consumePendingQuery())
        assertEquals("daft punk", BrowseSession.query.value)
        assertNull(NavRequestBus.pendingBrowseQuery.value)
        BrowseSession.query.value = ""
    }
}
