package com.levi.pocketdj.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPermissionTest {
    @Test fun asksOnlyOn13PlusWhenNotGrantedAndNeverAsked() {
        assertTrue(NotificationPermission.shouldAsk(33, granted = false, askedBefore = false))
        assertTrue(NotificationPermission.shouldAsk(36, granted = false, askedBefore = false))
        assertFalse(NotificationPermission.shouldAsk(32, granted = false, askedBefore = false)) // install-time grant
        assertFalse(NotificationPermission.shouldAsk(36, granted = true, askedBefore = false))
        assertFalse(NotificationPermission.shouldAsk(36, granted = false, askedBefore = true)) // no nagging
    }
}
