package com.levi.pocketdj.remote

import com.levi.pocketdj.screens.remote.RemoteJoinCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class NearbyInviteTest {
    @Test fun tokensAreEightUnambiguousCharsAndTheUrlCarriesTheToken() {
        val t = NearbyInvite.newToken(Random(7))
        assertEquals(8, t.length)
        assertTrue(t.all { it in "ABCDEFGHJKMNPQRSTUVWXYZ23456789" })
        val inv = NearbyInvite.invite(t)
        assertEquals(t, inv.code)
        assertEquals("pocketdj://remote/join/$t", inv.url)
        assertEquals(t, RemoteJoinCode.parse(inv.url)) // the Remote screen's join field accepts the QR link
        assertNotEquals(t, NearbyInvite.newToken(Random(8)))
    }

    @Test fun hashIsStableCaseInsensitiveAndNeverTheToken() {
        val h = NearbyInvite.hash("ABCD2345")
        assertEquals(8, h.length)
        assertEquals(h, NearbyInvite.hash(" abcd2345 "))
        assertNotEquals(h, NearbyInvite.hash("ABCD2346"))
        assertFalse(h.equals("ABCD2345", true))
    }

    @Test fun endpointNameRoundTripsAndSurvivesAPipeInTheDeviceName() {
        val n = NearbyInvite.endpointName("Levi's Pixel | 9", "deadbeef", RemoteSessionMode.BACKSEAT)
        val p = NearbyInvite.parseEndpointName(n)
        assertEquals("Levi's Pixel   9", p.deviceName)
        assertEquals("deadbeef", p.hash)
        assertEquals(RemoteSessionMode.BACKSEAT, p.mode)
        assertEquals(RemoteSessionMode.LISTEN_TOGETHER, NearbyInvite.parseEndpointName(NearbyInvite.endpointName("X", "h", RemoteSessionMode.LISTEN_TOGETHER)).mode)
        assertNull(NearbyInvite.parseEndpointName(NearbyInvite.endpointName("X", "h", null)).mode)
    }

    @Test fun aForeignAdvertisementNeverMatches() {
        assertNull(NearbyInvite.parseEndpointName("JBL Speaker").hash)
        assertNull(NearbyInvite.parseEndpointName("").hash)
        assertTrue(NearbyInvite.endpointName("a".repeat(200), "h", null).length < 60)
        assertTrue(NearbyInvite.endpointName("   ", "h", null).startsWith("Android|"))
    }

    @Test fun theHostAcceptsTheRightHashOrAnAllowedOpenJoinOnly() {
        assertTrue(NearbyInvite.accepts("h1", "h1", false))
        assertFalse(NearbyInvite.accepts("h2", "h1", true))
        assertFalse(NearbyInvite.accepts(null, "h1", true))
        assertTrue(NearbyInvite.accepts(NearbyInvite.OPEN_HASH, "h1", true))
        assertFalse(NearbyInvite.accepts(NearbyInvite.OPEN_HASH, "h1", false))
    }
}
