package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.mix.nowplaying.DjEngineDecline
import com.levi.pocketdj.playback.dj.DjDecline.Inputs
import com.levi.pocketdj.playback.dj.DjDecline.Reason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DjDeclineTest {
    private fun reason(i: Inputs = Inputs(), skip: Boolean = false) = DjDecline.reason(i, skip)

    @Test fun aPlainMiddleRowMixes() = assertNull(reason())

    @Test fun noCurrentRowIsTheLastSong() = assertEquals(Reason.LAST_SONG, reason(Inputs(hasCurrent = false)))

    @Test fun transitionsOff() = assertEquals(Reason.TRANSITIONS_OFF, reason(Inputs(transitionsOn = false)))

    @Test fun repeatOne() = assertEquals(Reason.REPEATING, reason(Inputs(repeatOne = true)))

    @Test fun aRepeatCountStillRunning() = assertEquals(Reason.REPEATING, reason(Inputs(playsRemaining = 2)))

    @Test fun theLastPlayOfARepeatCountMixes() = assertNull(reason(Inputs(playsRemaining = 1)))

    @Test fun aCascadeHalt() = assertEquals(Reason.HALTED, reason(Inputs(halted = true)))

    @Test fun theLastRow() = assertEquals(Reason.LAST_SONG, reason(Inputs(hasNext = false)))

    @Test fun theLastRowOfARepeatingSetIsSetRepeats() =
        assertEquals(Reason.SET_REPEATS, reason(Inputs(hasNext = false, repeatAll = true)))

    @Test fun anAlbumRunPlayingThrough() = assertEquals(Reason.ALBUM_RUN, reason(Inputs(albumRunPlaying = true)))

    @Test fun theNextRowStartsAnAlbumRun() = assertEquals(Reason.ALBUM_STARTS, reason(Inputs(nextStartsAlbumRun = true)))

    @Test fun aRowTheDspDoesNotOwnIsPlain() = assertEquals(Reason.PLAIN, reason(Inputs(dspEngaged = false)))

    @Test fun theNextRowNotLocal() = assertEquals(Reason.NEXT_NOT_LOCAL, reason(Inputs(nextLocal = false)))

    @Test fun localnessNotAskedIsNotADecline() = assertNull(reason(Inputs(nextLocal = null)))

    @Test fun theOrderIsTheContract() {
        // everything wrong at once: the first reason in iOS order wins
        val all = Inputs(
            hasCurrent = true, transitionsOn = false, repeatOne = true, playsRemaining = 3, halted = true, hasNext = false,
            repeatAll = true, albumRunPlaying = true, nextStartsAlbumRun = true, dspEngaged = false, nextLocal = false,
        )
        assertEquals(Reason.TRANSITIONS_OFF, reason(all))
        assertEquals(Reason.REPEATING, reason(all.copy(transitionsOn = true)))
        assertEquals(Reason.HALTED, reason(all.copy(transitionsOn = true, repeatOne = false, playsRemaining = 1)))
        assertEquals(Reason.SET_REPEATS, reason(all.copy(transitionsOn = true, repeatOne = false, playsRemaining = 1, halted = false)))
        assertEquals(Reason.ALBUM_RUN, reason(all.copy(transitionsOn = true, repeatOne = false, playsRemaining = 1, halted = false, hasNext = true)))
        assertEquals(
            Reason.ALBUM_STARTS,
            reason(all.copy(transitionsOn = true, repeatOne = false, playsRemaining = 1, halted = false, hasNext = true, albumRunPlaying = false)),
        )
        assertEquals(
            Reason.PLAIN,
            reason(Inputs(dspEngaged = false, nextLocal = false)),
        )
    }

    @Test fun aSkipOverridesRepeatAndLiftsTheHalt() {
        val busy = Inputs(repeatOne = true, playsRemaining = 4, halted = true)
        assertEquals(Reason.REPEATING, reason(busy))
        assertNull(reason(busy, skip = true))
        // but a skip still obeys everything else
        assertEquals(Reason.TRANSITIONS_OFF, reason(busy.copy(transitionsOn = false), skip = true))
        assertEquals(Reason.ALBUM_RUN, reason(busy.copy(albumRunPlaying = true), skip = true))
    }

    @Test fun chipWordsAndIndicatorsMatchTheChipVocabulary() {
        assertEquals(DjMode.Indicator.LastTrack, Reason.LAST_SONG.indicator)
        assertEquals(DjMode.Indicator.NoMix("set repeats"), Reason.SET_REPEATS.indicator)
        assertEquals("DJ — transitions off", Reason.TRANSITIONS_OFF.indicator.chipText)
        assertEquals("DJ — repeating this song", Reason.REPEATING.indicator.chipText)
        assertEquals("DJ — paused", Reason.HALTED.indicator.chipText)
        assertEquals("DJ — album plays through", Reason.ALBUM_RUN.indicator.chipText)
        assertEquals("DJ — album side next", Reason.ALBUM_STARTS.indicator.chipText)
        assertEquals("DJ — this song ends as is", Reason.NEXT_NOT_LOCAL.indicator.chipText)
    }

    @Test fun rawWordsAreTheIosStrings() {
        assertEquals("transitions off", Reason.TRANSITIONS_OFF.raw)
        assertEquals("repeat", Reason.REPEATING.raw)
        assertEquals("halted", Reason.HALTED.raw)
        assertEquals("last song", Reason.LAST_SONG.raw)
        assertEquals("set repeats", Reason.SET_REPEATS.raw)
        assertEquals("album run", Reason.ALBUM_RUN.raw)
        assertEquals("next starts an album side", Reason.ALBUM_STARTS.raw)
        assertEquals("next not local", Reason.NEXT_NOT_LOCAL.raw)
    }

    @Test fun aSkipsLogWordsArePrefixed() {
        assertEquals("skip: halted", DjDecline.logWords("halted", true))
        assertEquals("halted", DjDecline.logWords("halted", false))
    }

    @Test fun engineReasonsGetChipWords() {
        assertEquals("stems muted", DjDecline.engineWords(DjEngineDecline.STEMS_MUTED))
        assertEquals("still downloading", DjDecline.engineWords(DjEngineDecline.GROWING))
        assertEquals("too close to the end", DjDecline.engineWords(DjEngineDecline.TOO_CLOSE))
        assertEquals("something new", DjDecline.engineWords("something new"))
    }
}
