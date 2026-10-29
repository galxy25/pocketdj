package com.levi.pocketdj.data.location

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.location.DwellDetector.Fix
import com.levi.pocketdj.data.location.DwellDetector.Output
import com.levi.pocketdj.data.pockets.PocketsFixture
import com.levi.pocketdj.screens.settings.sections.ListeningLocationCopy
import com.levi.pocketdj.screens.settings.sections.ListeningLocationCopy.AuthAction
import java.io.File
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

private typealias A = ListeningLocationAuthorization

class LocationSettingsTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun authorizationMapping() {
        assertEquals(A.NOT_DETERMINED, LocationSettings.authorization(false, false, false, askedBefore = false))
        assertEquals(A.DENIED, LocationSettings.authorization(false, false, false, askedBefore = true))
        assertEquals(A.WHEN_IN_USE, LocationSettings.authorization(true, false, false, true))
        assertEquals(A.WHEN_IN_USE, LocationSettings.authorization(false, true, false, true))
        assertEquals(A.ALWAYS, LocationSettings.authorization(true, true, true, true))
        // background without any foreground grant is not a grant
        assertEquals(A.DENIED, LocationSettings.authorization(false, false, true, true))
    }

    @Test fun enablingNeedsPocketsDisablingNever() {
        assertFalse(LocationSettings.canSetEnabled(on = true, pocketsOn = false))
        assertTrue(LocationSettings.canSetEnabled(on = true, pocketsOn = true))
        assertTrue(LocationSettings.canSetEnabled(on = false, pocketsOn = false))
        assertTrue(LocationSettings.toggleEnabled(locationOn = true, pocketsOn = false))
        assertFalse(LocationSettings.toggleEnabled(locationOn = false, pocketsOn = false))
    }

    @Test fun statusAndActionCopyMatchesIos() {
        assertEquals("Denied", LocationSettings.statusText(A.DENIED))
        assertEquals("While using the app", LocationSettings.statusText(A.WHEN_IN_USE))
        assertEquals("Not yet asked", LocationSettings.statusText(A.NOT_DETERMINED))
        assertEquals(AuthAction.OPEN_SETTINGS, ListeningLocationCopy.authAction(A.DENIED, false))
        assertEquals(AuthAction.ALLOW_ALWAYS, ListeningLocationCopy.authAction(A.WHEN_IN_USE, false))
        assertEquals(AuthAction.ALLOW_ALWAYS_IN_SETTINGS, ListeningLocationCopy.authAction(A.WHEN_IN_USE, true))
        assertEquals(AuthAction.NONE, ListeningLocationCopy.authAction(A.ALWAYS, true))
        assertEquals("42 % of time", ListeningLocationCopy.share(0.42))
    }

    @Test fun prominentDisclosureMeetsPlayBackgroundLocationWording() {
        // Play User Data policy: name the data (location), the feature, and background use
        // ("closed or not in use") before the runtime prompt.
        for (msg in listOf(ListeningLocationCopy.DISCLOSURE_FOREGROUND, ListeningLocationCopy.DISCLOSURE_BACKGROUND)) {
            assertEquals(true, msg.contains("collects location data"))
            assertEquals(true, msg.contains("closed or not in use"))
            assertEquals(true, msg.contains("Allow all the time"))
        }
    }

    @Test fun deniedPermissionIngestsNothing() {
        val clock = 1_750_000_000_000L
        val src = object : ListeningLocationSource {
            override var authorization = A.DENIED
            override fun start(store: ListeningLocationStore) {}
            override fun stop() {}
            override fun requestAlwaysUpgrade() {}
        }
        val store = ListeningLocationStore(File(tmp.root, "p.json"), now = { clock }, makeSource = { src }, io = Executor { it.run() })
        store.setEnabled(true)
        assertEquals(A.DENIED, store.authorization)
        assertFalse(store.isActive)
        assertEquals(ListeningContextLookup.Unavailable, store.context((clock - 1000).toDouble()))
        // a source (or stale cached fix) delivering while DENIED must not be ingested
        store.ingestVisit(LocationVisitSample(37.8, -122.4, 20.0, arrivalMs = clock - 3_600_000, departureMs = null))
        store.noteMovement(LocationFixSample(37.9, -122.4, 20.0, clock - 1000))
        assertTrue(store.engine.places.isEmpty())
        assertTrue(store.engine.timeline.isEmpty())
    }

    @Test fun approximateOnlyAndRetryRules() {
        assertTrue(LocationSettings.approximateOnly(coarse = true, fine = false))
        assertFalse(LocationSettings.approximateOnly(coarse = true, fine = true))
        assertFalse(LocationSettings.approximateOnly(coarse = false, fine = false))
        // lapsed one-time grant / first dismissal: re-askable; permanent: Settings only
        assertTrue(LocationSettings.canRequestAgain(denials = 0, shouldShowRationale = false))
        assertTrue(LocationSettings.canRequestAgain(denials = 1, shouldShowRationale = true))
        assertFalse(LocationSettings.canRequestAgain(denials = 1, shouldShowRationale = false))
        assertFalse(LocationSettings.canRequestAgain(denials = 2, shouldShowRationale = true))
        assertEquals(AuthAction.REQUEST_FOREGROUND, ListeningLocationCopy.authAction(A.DENIED, false, canRequestAgain = true))
        assertEquals(AuthAction.OPEN_SETTINGS, ListeningLocationCopy.authAction(A.DENIED, false, canRequestAgain = false))
        assertEquals(AuthAction.OPEN_SETTINGS, ListeningLocationCopy.authAction(A.RESTRICTED, false, canRequestAgain = true))
    }

    /** Detector -> store -> settled play -> upload event: only plc_ ids, no coordinates anywhere in the wire JSON. */
    @Test fun uploadEventCarriesOnlyOpaqueIds() {
        val fx = PocketsFixture(tmp.newFolder())
        try {
            val min = 60_000L
            val t0 = fx.clock - 600 * min
            var now = t0
            val src = object : ListeningLocationSource {
                override val authorization = A.ALWAYS
                override fun start(store: ListeningLocationStore) {}
                override fun stop() {}
                override fun requestAlwaysUpgrade() {}
            }
            val store = ListeningLocationStore(File(tmp.root, "places.json"), now = { now }, makeSource = { src }, io = Executor { it.run() })
            store.setEnabled(true) // tracking starts at t0
            val det = DwellDetector()
            fun feed(lat: Double, atMin: Long) = det.onFix(Fix(lat, -122.4, 15.0, t0 + atMin * min)).forEach {
                when (it) { is Output.Visit -> store.ingestVisit(it.sample); is Output.Hint -> store.noteMovement(it.sample) }
            }
            feed(37.8, 1); feed(37.8, 10); feed(37.8, 20); feed(37.9, 30)
            now = fx.clock
            assertEquals(1, store.engine.places.size)
            assertTrue(store.engine.places.single().id.startsWith("plc_"))

            val play = fx.history.record("song", nowMs = t0 + 15 * min, tzOffsetMin = 0)!!
            val svc = fx.service(store)
            svc.settleContexts()
            val e = fx.history.events.first { it.id == play.id }
            val tag = e.listeningContext!!
            assertTrue(tag.placeId!!.startsWith("plc_"))

            val wire = svc.wireEvent(e, locationOn = true).toJson().toString()
            assertTrue(wire.contains(tag.placeId!!))
            assertFalse("no raw coordinates on the wire", wire.contains("37.8") || wire.contains("122.4"))
            assertNull("location off => ctx never rides", svc.wireEvent(e, locationOn = false).ctx)
        } finally { fx.close() }
    }
}
