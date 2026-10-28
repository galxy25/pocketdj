package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.settings.BrowseSnapshot
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Drives the flushable directly: no debounce, no lifecycle. */
class BrowseSessionFlushableTest {
    private var savedRestored = false
    private var savedKind = BrowseKind.ALBUMS

    @Before fun save() {
        savedRestored = BrowseSession.restored
        savedKind = BrowseSession.kind.value
    }

    @After fun restore() {
        BrowseSession.restored = savedRestored
        BrowseSession.kind.value = savedKind
        BrowseSession.filters.value = BrowseFilters()
    }

    @Test fun flushBeforeRestoreWritesNothing() = runBlocking {
        BrowseSession.restored = false
        val writes = mutableListOf<BrowseSnapshot>()
        BrowseSessionFlushable { writes += it }.flush()
        assertTrue(writes.isEmpty())
    }

    @Test fun flushWritesLiveStateImmediately() = runBlocking {
        BrowseSession.restored = true
        BrowseSession.kind.value = BrowseKind.SONGS
        BrowseSession.filters.value = BrowseFilters().withGenres(setOf("Jazz"))
        val writes = mutableListOf<BrowseSnapshot>()
        BrowseSessionFlushable { writes += it }.flush()
        assertEquals(1, writes.size)
        assertEquals(BrowseSession.currentState().toSnapshot(), writes.single())
    }

    @Test fun persistWritesNewestStateEvenWhenCalledRepeatedly() = runBlocking {
        BrowseSession.restored = true
        val writes = mutableListOf<BrowseSnapshot>()
        BrowseSession.kind.value = BrowseKind.ALBUMS
        BrowseSession.persist { writes += it }
        BrowseSession.kind.value = BrowseKind.SONGS
        BrowseSession.persist { writes += it }
        assertEquals(BrowseSession.currentState().toSnapshot(), writes.last())
    }
}
