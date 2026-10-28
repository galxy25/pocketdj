package com.levi.pocketdj.screens.collections

import com.levi.pocketdj.data.backup.CollectionShare
import com.levi.pocketdj.shell.NavRequestBus
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals

class ExportMimeNoticeTest {
    @Test
    fun collectionExportsUseAnOpaqueMimeSoDocumentsUiDoesNotAppendZip() {
        assertEquals("application/octet-stream", CollectionShare.COLLECTION_MIME)
        assertNotEquals("application/zip", CollectionShare.COLLECTION_MIME)
    }

    @Test
    fun exportResultsRideTheNoticeChannelNotTheCantOpenThatAlert() {
        NavRequestBus.reset()
        NavRequestBus.postNotice("Exported X.pocket.pdjcollection")
        assertEquals("Exported X.pocket.pdjcollection", NavRequestBus.notice.value)
        assertEquals(null, NavRequestBus.routeMessage.value)
        NavRequestBus.clearNotice()
        assertEquals(null, NavRequestBus.notice.value)
    }
}
