package com.levi.pocketdj.playback.session

import com.levi.pocketdj.data.recs.RecFeedbackStore.Surface
import com.levi.pocketdj.data.recs.RecFeedbackStore.Verdict
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.session.MediaButtonPrefs.Input
import com.levi.pocketdj.playback.session.MediaButtonPrefs.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaButtonPrefsTest {
    private fun kinds(i: Input) = MediaButtonPrefs.specs(i).map { it.kind }

    @Test fun nothingWhenIdle() = assertEquals(emptyList<Kind>(), kinds(Input()))

    @Test fun heartOnlyForOwnerAndReflectsFilled() {
        val s = MediaButtonPrefs.specs(Input(favoriteVisible = true, favoriteFilled = true))
        assertEquals(listOf(Kind.FAVORITE), s.map { it.kind })
        assertEquals(true, s[0].lit)
        assertEquals(FavoriteCommand.ACTION, s[0].action)
    }

    @Test fun shuffleAndRepeatOnlyWhileRunning() {
        assertEquals(emptyList<Kind>(), kinds(Input(repeat = RepeatMode.ALL, shuffle = true)))
        val s = MediaButtonPrefs.specs(Input(runActive = true, repeat = RepeatMode.ONE, shuffle = true))
        assertEquals(listOf(Kind.SHUFFLE, Kind.REPEAT), s.map { it.kind })
        assertEquals(true, s[0].lit)
        assertEquals(RepeatMode.ONE, s[1].repeat)
        assertEquals(true, s[1].lit)
    }

    @Test fun pocketRunShowsEffectiveOffRepeat() {
        // The effective mode is what the input carries; a pocket run forces OFF so the glyph is unlit.
        val r = MediaButtonPrefs.specs(Input(runActive = true, repeat = RepeatMode.OFF)).first { it.kind == Kind.REPEAT }
        assertEquals(false, r.lit)
    }

    @Test fun thumbsAreAnAllOrNothingPairOnlyWithTarget() {
        assertEquals(emptyList<Kind>(), kinds(Input(verdict = Verdict.ACCEPTED)))
        val s = MediaButtonPrefs.specs(Input(hasRecTarget = true))
        assertEquals(listOf(Kind.THUMB_UP, Kind.THUMB_DOWN), s.map { it.kind })
        assertEquals(listOf(false, false), s.map { it.lit })
    }

    @Test fun onlyTheVerdictsThumbLights() {
        val up = MediaButtonPrefs.specs(Input(hasRecTarget = true, verdict = Verdict.ACCEPTED))
        assertEquals(listOf(true, false), up.map { it.lit })
        val down = MediaButtonPrefs.specs(Input(hasRecTarget = true, verdict = Verdict.REJECTED))
        assertEquals(listOf(false, true), down.map { it.lit })
        val cleared = MediaButtonPrefs.specs(Input(hasRecTarget = true, verdict = Verdict.CLEARED))
        assertEquals(listOf(false, false), cleared.map { it.lit })
    }

    @Test fun fullStateOrderIsHeartShuffleRepeatThumbs() {
        val i = Input(true, false, true, RepeatMode.ALL, false, true, null)
        assertEquals(listOf(Kind.FAVORITE, Kind.SHUFFLE, Kind.REPEAT, Kind.THUMB_UP, Kind.THUMB_DOWN), kinds(i))
        assertEquals(
            listOf(FavoriteCommand.ACTION, "pdj.shuffle", "pdj.repeat", "pdj.rec.accept", "pdj.rec.reject"),
            MediaButtonPrefs.specs(i).map { it.action },
        )
    }

    @Test fun verdictAndRepeatMapping() {
        assertEquals(Verdict.ACCEPTED, MediaButtonPrefs.verdictFor(MediaButtonPrefs.ACTION_REC_ACCEPT))
        assertEquals(Verdict.REJECTED, MediaButtonPrefs.verdictFor(MediaButtonPrefs.ACTION_REC_REJECT))
        assertNull(MediaButtonPrefs.verdictFor(MediaButtonPrefs.ACTION_REPEAT))
        assertEquals(RepeatMode.ALL, MediaButtonPrefs.nextRepeat(RepeatMode.OFF))
        assertEquals(RepeatMode.ONE, MediaButtonPrefs.nextRepeat(RepeatMode.ALL))
        assertEquals(RepeatMode.OFF, MediaButtonPrefs.nextRepeat(RepeatMode.ONE))
    }

    @Test fun surfaceByController() {
        assertEquals(Surface.CAR_PLAY, MediaButtonPrefs.surfaceFor("com.google.android.projection.gearhead"))
        assertEquals(Surface.NOW_PLAYING, MediaButtonPrefs.surfaceFor("com.android.systemui"))
    }

    @Test fun equalInputsGiveEqualSpecs_soServiceCanSkipRepublish() {
        val i = Input(favoriteVisible = true, runActive = true, shuffle = true, hasRecTarget = true)
        assertEquals(MediaButtonPrefs.specs(i), MediaButtonPrefs.specs(i.copy()))
        assert(MediaButtonPrefs.specs(i) != MediaButtonPrefs.specs(i.copy(verdict = Verdict.ACCEPTED)))
    }
}
