package com.levi.pocketdj.data.transfers

import org.junit.Assert.assertEquals
import org.junit.Test

class TransferNotificationsTest {
    @Test fun titleShowsPositionInRun() {
        assertEquals("Downloading… 1 of 5", TransferNotifications.title(TransferProgress(5, 0)))
        assertEquals("Downloading… 3 of 5", TransferNotifications.title(TransferProgress(5, 2)))
        assertEquals("Downloading… 5 of 5", TransferNotifications.title(TransferProgress(5, 9)))
        assertEquals("Downloading…", TransferNotifications.title(TransferProgress(1, 0)))
    }
}
