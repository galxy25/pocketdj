package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.mix.nowplaying.StemLock.Indicator
import com.levi.pocketdj.playback.durable.SessionStemLock
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StemLockTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test fun enabledAndDisabledPartsFollowDownloadPriority() {
        val st = StemLockState(enabled = true, stemsOn = true, muted = listOf("bass", "drums"))
        assertEquals(listOf("vocals", "other"), st.enabledParts)
        assertEquals(listOf("drums", "bass"), st.disabledParts)
        assertEquals("stems=on parts=vocals,other muted=bass,drums", st.logSummary)
        assertTrue(st.wantsStems)
        assertFalse(st.copy(stemsOn = false).wantsStems)
        assertFalse(st.copy(enabled = false).wantsStems)
    }

    @Test fun persistenceShapeRoundTripsAndOmitsWhenOff() {
        val st = StemLockState(enabled = true, stemsOn = true, muted = listOf("drums", "bass"), volumes = mapOf("vocals" to 0.5))
        val s = st.toSession()!!
        assertEquals(listOf("bass", "drums"), s.muted)   // sorted on disk
        val text = json.encodeToString(SessionStemLock.serializer(), s)
        val back = StemLockState.fromSession(json.decodeFromString(SessionStemLock.serializer(), text))
        assertEquals(st.copy(muted = listOf("bass", "drums")), back)
        assertNull(StemLockState().toSession())
        assertEquals(StemLockState(), StemLockState.fromSession(null))
        assertEquals(StemLockState(), StemLockState.fromSession(SessionStemLock(enabled = false, stemsOn = true)))
    }

    @Test fun iosShapedJsonDecodes() {
        val ios = """{"enabled":true,"stemsOn":true,"muted":["bass"],"volumes":{"vocals":0.4,"junk":1.0}}"""
        val st = StemLockState.fromSession(json.decodeFromString(SessionStemLock.serializer(), ios))
        assertTrue(st.wantsStems)
        assertEquals(listOf("bass"), st.muted)
        assertEquals(mapOf("vocals" to 0.4), st.volumes)   // unknown part dropped
    }

    @Test fun lockCapturesCurrentStemSetAndCarriesIt() {
        var persisted = 0
        val s = StemLockSession { persisted++ }
        s.setLock(true, StemSnapshot(stemsOn = true, muted = setOf("drums"), volumes = mapOf("vocals" to 0.7)))
        assertTrue(s.current.enabled && s.current.stemsOn)
        assertEquals(listOf("drums"), s.current.muted)
        assertEquals(1, persisted)
        // a user change on a later track updates the carry
        assertTrue(s.onUserStemChange(StemSnapshot(true, setOf("drums", "bass"), emptyMap()), "b", true))
        assertEquals(listOf("bass", "drums"), s.current.muted)
        // identical snapshot: no change, no persist
        val before = persisted
        assertFalse(s.onUserStemChange(StemSnapshot(true, setOf("drums", "bass"), emptyMap()), "b", true))
        assertEquals(before, persisted)
    }

    @Test fun lockOnWithoutEngagedTrackCarriesStemsOff() {
        val s = StemLockSession()
        s.setLock(true, null)
        assertTrue(s.current.enabled); assertFalse(s.current.stemsOn)
    }

    @Test fun applyingTheCarryIsNotAUserChange() {
        val s = StemLockSession()
        s.setLock(true, StemSnapshot(true, emptySet(), emptyMap()))
        s.applying = true
        assertFalse(s.onUserStemChange(StemSnapshot(false, emptySet(), emptyMap()), "x", false))
        assertTrue(s.current.stemsOn)
    }

    @Test fun userChangeIsIgnoredWhenLockOff() {
        val s = StemLockSession()
        assertFalse(s.onUserStemChange(StemSnapshot(true, emptySet(), emptyMap()), "x", true))
        assertEquals(StemLockState(), s.current)
    }

    @Test fun newSessionClearsAndRestoreBringsItBack() {
        val s = StemLockSession()
        s.setLock(true, StemSnapshot(true, setOf("bass"), emptyMap()))
        val persisted = s.current.toSession()
        s.reset()
        assertEquals(StemLockState(), s.current)
        s.restore(persisted)    // process death + session restore
        assertTrue(s.current.wantsStems)
        assertEquals(listOf("bass"), s.current.muted)
    }

    @Test fun carrySurvivesATrackThatCannotDoStems() {
        val s = StemLockSession()
        s.setLock(true, StemSnapshot(true, emptySet(), emptyMap()))
        s.markUnavailable("streamed")
        // no user action on the unavailable track: the carry is untouched
        assertTrue(s.current.stemsOn)
        s.trackStarted()
        assertNull(s.unavailableSongId)
    }

    @Test fun indicatorStates() {
        val on = StemLockState(enabled = true, stemsOn = true)
        fun ind(st: StemLockState = on, id: String? = "a", held: Boolean = false, unavail: String? = null, engaged: Boolean = true, air: Boolean = false, loading: Boolean = false) =
            StemLockSession.indicator(st, id, held, unavail, engaged, air, loading)
        assertEquals(Indicator.OFF, ind(StemLockState()))
        assertEquals(Indicator.IDLE, ind(on.copy(stemsOn = false)))
        assertEquals(Indicator.IDLE, ind(id = null))
        assertEquals(Indicator.IDLE, ind(held = true))
        assertEquals(Indicator.UNAVAILABLE, ind(unavail = "a"))
        assertEquals(Indicator.LOADING, ind(engaged = false))       // the track is still starting
        assertEquals(Indicator.ACTIVE, ind(air = true))
        assertEquals(Indicator.LOADING, ind(loading = true))
        assertEquals(Indicator.UNAVAILABLE, ind())                   // a request that dropped
        assertEquals(Indicator.LOADING, ind(unavail = "other", engaged = false))
    }
}
