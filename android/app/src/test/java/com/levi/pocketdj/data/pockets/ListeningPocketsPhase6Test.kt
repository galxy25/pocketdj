package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.history.PocketRunTag
import com.levi.pocketdj.data.pockets.wheel.MotionToken
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ListeningPocketsPhase6Test {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var fx: PocketsFixture

    @Before fun setUp() { fx = PocketsFixture(tmp.root) }
    @After fun tearDown() { fx.close() }

    private val run = PocketRunTag(runId = "11111111-2222", momentKey = "h08|d2|running", rowCollectionId = "pk1", slot = 3)

    private fun ev(motion: String? = null, carPlay: Boolean? = null, pocketRun: PocketRunTag? = null,
                   source: PlaySource = PlaySource.BROWSER) =
        PlayEvent(id = "e1", songId = "s1", playedAt = 1_750_000_000_000.0, source = source, tzOffsetMin = 0,
            carPlay = carPlay, motion = motion, pocketRun = pocketRun)

    private fun ListeningPocketsService.enableMotion() { motionOptedIn = { true } }

    // ---- response / caps ----

    @Test fun responseParsesCapsAndAbsentIsNull() {
        val with = ListeningPocketsUploadResponse.parse(Json.parseToJsonElement("""{"ok":true,"caps":["wheel","x"]}"""))
        assertEquals(listOf("wheel", "x"), with.caps)
        assertNull(ListeningPocketsUploadResponse.parse(Json.parseToJsonElement("""{"ok":true}""")).caps)
        assertEquals(emptyList<String>(), ListeningPocketsUploadResponse.parse(Json.parseToJsonElement("""{"caps":[]}""")).caps)
    }

    @Test fun noteServerCapsPersistsAcrossRestart() {
        val svc = fx.service()
        assertFalse(svc.serverSupportsWheel)
        svc.noteServerCaps(listOf("wheel"))
        assertTrue(svc.serverSupportsWheel)
        assertTrue(fx.service().serverSupportsWheel)   // reloaded from the sync file
        svc.noteServerCaps(emptyList())
        assertFalse(svc.serverSupportsWheel)
    }

    @Test fun oldSyncDocWithoutServerCapsDecodes() {
        fx.syncFile.writeText("""{"schemaVersion":1,"profileId":"prof-A","sent":{"a":"completed|-|-|0"}}""")
        val svc = fx.service()
        assertFalse(svc.serverSupportsWheel)
        assertEquals("completed|-|-|0", svc.acknowledgedFingerprints["a"])
    }

    // ---- never before caps ----

    @Test fun wireOmitsModeAndRunBeforeCaps() {
        val svc = fx.service(); svc.enableMotion()
        val j = svc.wireEvent(ev(motion = MotionToken.RUNNING, pocketRun = run), false).toJson()
        assertFalse(j.containsKey("mode")); assertFalse(j.containsKey("run"))
    }

    @Test fun wireCarriesModeAndRunAfterCaps() {
        val svc = fx.service(); svc.enableMotion(); svc.noteServerCaps(listOf("wheel"))
        val j = svc.wireEvent(ev(motion = MotionToken.RUNNING, pocketRun = run), false).toJson()
        assertEquals("running", j["mode"]!!.jsonPrimitive.content)
        val r = j["run"]!!.jsonObject
        assertEquals(listOf("id", "moment", "slot", "collectionId"), r.keys.toList())
        assertEquals("11111111-2222", r["id"]!!.jsonPrimitive.content)
        assertEquals("h08|d2|running", r["moment"]!!.jsonPrimitive.content)
        assertEquals(3, r["slot"]!!.jsonPrimitive.content.toInt())
        assertEquals("pk1", r["collectionId"]!!.jsonPrimitive.content)
    }

    @Test fun runCollectionIdOmittedWhenNil() {
        val j = ListeningPocketsUploadEvent.RunWire("r", "m", 1, null).toJson()
        assertEquals(listOf("id", "moment", "slot"), j.keys.toList())
    }

    @Test fun modeNeedsMotionOptIn() {
        val svc = fx.service(); svc.noteServerCaps(listOf("wheel"))
        assertFalse(svc.wireEvent(ev(motion = MotionToken.WALKING), false).toJson().containsKey("mode"))
        svc.enableMotion()
        assertEquals("walking", svc.wireEvent(ev(motion = MotionToken.WALKING), false).mode)
    }

    @Test fun sensorModeRules() {
        assertEquals("running", ListeningPocketsService.sensorMode(ev(motion = MotionToken.RUNNING), null))
        assertEquals("walking", ListeningPocketsService.sensorMode(ev(motion = MotionToken.WALKING), null))
        assertEquals("trip", ListeningPocketsService.sensorMode(ev(motion = MotionToken.AUTOMOTIVE), null))
        assertEquals("trip", ListeningPocketsService.sensorMode(ev(motion = MotionToken.CYCLING), null))
        // Surface modes and stationary are derivable server-side: never sent.
        assertNull(ListeningPocketsService.sensorMode(ev(motion = MotionToken.STATIONARY), null))
        assertNull(ListeningPocketsService.sensorMode(ev(carPlay = true), null))
        assertNull(ListeningPocketsService.sensorMode(ev(), null))
        // A trip decided by the location ctx (no motion) rides as ctx, not mode.
        val tripCtx = ListeningContextTag(kind = "trip", tripId = "t1", origin = "o")
        assertNull(ListeningPocketsService.sensorMode(ev(), tripCtx))
        // Games are excluded.
        assertNull(ListeningPocketsService.sensorMode(ev(motion = MotionToken.RUNNING, source = PlaySource.GAME), null))
    }

    @Test fun runTagQueueIdNeverRidesAsContext() {
        val svc = fx.service(); svc.noteServerCaps(listOf("wheel"))
        val e = ev(pocketRun = run.copy(rowCollectionId = "pwr_abc")).copy(contextId = "pwr_abc")
        assertNull(svc.wireEvent(e, false).contextId)
    }

    // ---- fingerprints ----

    private fun base(mode: String? = null, run: ListeningPocketsUploadEvent.RunWire? = null, cid: String? = null) =
        ListeningPocketsUploadEvent(
            id = "e", songId = "s", atMs = 0, ord = 0, tzOffsetMin = 0, source = "browser", outcome = "completed",
            fraction = 0.8, originInstallId = null, artist = null, carPlay = null, ctx = null,
            contextId = cid, contextKind = cid?.let { "pocket" }, mode = mode, run = run,
        )

    @Test fun fingerprintStableWithoutWheelFields() {
        assertEquals("completed|80|-|0", ListeningPocketsService.fingerprint(base()))
        assertEquals("completed|80|-|0|pocket/c1", ListeningPocketsService.fingerprint(base(cid = "c1")))
    }

    @Test fun fingerprintAppendsSuffixesOnlyWhenPresent() {
        val r = ListeningPocketsUploadEvent.RunWire("rid", "m", 2, "c")
        assertEquals("completed|80|-|0|m:running", ListeningPocketsService.fingerprint(base(mode = "running")))
        assertEquals("completed|80|-|0|r:rid/2", ListeningPocketsService.fingerprint(base(run = r)))
        assertEquals("completed|80|-|0|pocket/c1|m:trip|r:rid/2",
            ListeningPocketsService.fingerprint(base(mode = "trip", run = r, cid = "c1")))
    }

    // ---- end to end through the Lambda stub ----

    @Test fun firstUploadWithoutCapsHasNoWheelKeysThenCapsEchoResendsOnce() = runBlocking {
        val e = fx.history.record("s0", nowMs = fx.clock - 120_000L, tzOffsetMin = 0)!!
        fx.history.stampMotion(mapOf(e.id to MotionToken.RUNNING))
        val svc = fx.service(); svc.enableMotion()
        val be = fx.backend
        assertTrue(svc.flushNow())
        assertFalse(be.events(0)[0].containsKey("mode"))
        assertFalse(be.events(0)[0].containsKey("run"))
        assertFalse(svc.serverSupportsWheel)
        assertEquals("completed|-|-|0".replace("completed", "unknown"), svc.acknowledgedFingerprints[e.id])
        // Same server, still no caps: nothing moved, no re-send.
        assertFalse(svc.flushNow()); assertEquals(1, be.eventCount())
        // The server starts echoing wheel on a later response (a pending change triggers that POST).
        be.eventsBody = """{"ok":true,"caps":["wheel"]}"""
        fx.history.markSkipped(e.id)
        assertTrue(svc.flushNow())
        assertFalse(be.events(1)[0].containsKey("mode"))   // that batch was built before the echo
        assertTrue(svc.serverSupportsWheel)
        // Next flush: the mode suffix moved the fingerprint, so the play re-sends once, with the mode.
        assertTrue(svc.flushNow())
        assertEquals("running", be.events(2)[0]["mode"]!!.jsonPrimitive.content)
        assertEquals("skipped|-|-|0|m:running", svc.acknowledgedFingerprints[e.id])
        assertFalse(svc.flushNow()); assertEquals(3, be.eventCount())
    }
}
