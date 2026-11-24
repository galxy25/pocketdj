package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.mix.nowplaying.StemLockState
import com.levi.pocketdj.playback.npmix.EditionSubstitution.Facts
import com.levi.pocketdj.playback.sequencer.QueueItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EditionSubstitutionTest {
    private val base = "sng_0123456789ab"
    private val muted = StemLockState(enabled = true, stemsOn = true, muted = listOf("vocals"))
    private val audible = StemLockState(enabled = true, stemsOn = true, muted = listOf("bass"))
    private val pref = QueueItem(id = base, variant = "explicit", resolveId = "${base}_explicit")
    private val noRipBaseOk = Facts(wantedAvailable = false, baseAvailable = true, baseHasStems = true)

    @Test fun preferenceRowWithoutEditionRipSubstitutesBase() {
        assertEquals(base, EditionSubstitution.substitute(pref, muted, false, noRipBaseOk))
    }

    @Test fun vocalsAudibleOrLockOffNeverSubstitutes() {
        assertNull(EditionSubstitution.substitute(pref, audible, false, noRipBaseOk))
        assertNull(EditionSubstitution.substitute(pref, StemLockState(), false, noRipBaseOk))
        assertNull(EditionSubstitution.substitute(pref, muted.copy(stemsOn = false), false, noRipBaseOk))
        assertNull(EditionSubstitution.substitute(pref, muted.copy(enabled = false), false, noRipBaseOk))
    }

    @Test fun lockedAndCleanOnlyRowsNeverSubstitute() {
        assertNull(EditionSubstitution.substitute(pref.copy(editionLocked = true), muted, false, noRipBaseOk))
        assertNull(EditionSubstitution.substitute(pref.copy(cleanOnlySkip = true), muted, false, noRipBaseOk))
        assertNull(EditionSubstitution.substitute(pref, muted, collectionCleanOnly = true, facts = noRipBaseOk))
    }

    @Test fun rowWithoutVariantOrSameResolveIdNeverSubstitutes() {
        assertNull(EditionSubstitution.substitute(QueueItem(id = base), muted, false, noRipBaseOk))
        assertNull(EditionSubstitution.substitute(pref.copy(resolveId = base), muted, false, noRipBaseOk))
    }

    @Test fun ripAvailabilityMatrix() {
        // wanted edition available -> no substitution
        assertNull(EditionSubstitution.substitute(pref, muted, false, noRipBaseOk.copy(wantedAvailable = true)))
        // base not playable here -> none
        assertNull(EditionSubstitution.substitute(pref, muted, false, noRipBaseOk.copy(baseAvailable = false)))
        // base has no stems -> none (the lock could mute nothing)
        assertNull(EditionSubstitution.substitute(pref, muted, false, noRipBaseOk.copy(baseHasStems = false)))
    }

    @Test fun laneAudioIdFollowsSubstitutionExceptForCurrent() {
        assertEquals(base, EditionSubstitution.laneAudioId(pref, isCurrent = false, substitute = base))
        assertEquals(pref.resolveId, EditionSubstitution.laneAudioId(pref, isCurrent = false, substitute = null))
        // the playing row is sticky: its own (already rewritten) resolveId
        val sticky = pref.copy(resolveId = base)
        assertEquals(base, EditionSubstitution.laneAudioId(sticky, isCurrent = true, substitute = null))
    }

    @Test fun dotsFullOnlyWhenWillPlayFileIsLocal() {
        assertFalse(EditionSubstitution.rowWillPlayLocally(false, ladderLocal = false, laneActive = true, laneCutLocal = false))
        assertTrue(EditionSubstitution.rowWillPlayLocally(false, ladderLocal = false, laneActive = true, laneCutLocal = true))
        assertFalse(EditionSubstitution.rowWillPlayLocally(false, ladderLocal = false, laneActive = false, laneCutLocal = true))
        assertTrue(EditionSubstitution.rowWillPlayLocally(false, ladderLocal = true, laneActive = false, laneCutLocal = false))
        assertTrue(EditionSubstitution.rowWillPlayLocally(true, false, false, false))
    }

    @Test fun logLineShape() {
        assertEquals(
            "edition-substitute row=$base played=clean requested=explicit reason=vocals-muted via=start file=$base",
            EditionSubstitution.logLine(pref, "start", base),
        )
        assertEquals("explicit", EditionSubstitution.playedLabel("clean"))
    }
}
