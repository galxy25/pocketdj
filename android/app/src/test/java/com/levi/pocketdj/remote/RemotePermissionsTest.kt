package com.levi.pocketdj.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemotePermissionsTest {
    @Test fun hostingNeedsAdvertiseJoiningDoesNot() {
        assertTrue(RemotePermissions.BLUETOOTH_ADVERTISE in RemotePermissions.requiredFor(true))
        assertFalse(RemotePermissions.BLUETOOTH_ADVERTISE in RemotePermissions.requiredFor(false))
        assertTrue(RemotePermissions.BLUETOOTH_SCAN in RemotePermissions.requiredFor(false))
    }

    @Test fun missingListsOnlyWhatIsUngranted() {
        val granted = setOf(RemotePermissions.BLUETOOTH_SCAN, RemotePermissions.BLUETOOTH_CONNECT)
        assertEquals(
            listOf(RemotePermissions.BLUETOOTH_ADVERTISE, RemotePermissions.NEARBY_WIFI_DEVICES),
            RemotePermissions.missing(true) { it in granted },
        )
        assertTrue(RemotePermissions.missing(true) { true }.isEmpty())
    }

    @Test fun theWifiPermissionIsOptionalButBluetoothIsNot() {
        val all = RemotePermissions.REQUIRED.associateWith { true }
        assertTrue(RemotePermissions.canProceed(all, true))
        assertTrue(RemotePermissions.canProceed(all + (RemotePermissions.NEARBY_WIFI_DEVICES to false), true))
        assertFalse(RemotePermissions.canProceed(all + (RemotePermissions.BLUETOOTH_CONNECT to false), false))
        assertFalse(RemotePermissions.canProceed(all + (RemotePermissions.BLUETOOTH_ADVERTISE to false), true))
        assertTrue(RemotePermissions.canProceed(all + (RemotePermissions.BLUETOOTH_ADVERTISE to false), false))
    }

    @Test fun rationaleSaysWhyAndThatLocationIsNotUsed() {
        assertTrue(RemotePermissions.rationale(true).contains("advertises"))
        assertTrue(RemotePermissions.rationale(false).contains("scans"))
        assertTrue(RemotePermissions.rationale(true).contains("location"))
    }
}
