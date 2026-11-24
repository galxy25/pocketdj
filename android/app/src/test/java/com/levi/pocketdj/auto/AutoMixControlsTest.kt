package com.levi.pocketdj.auto

import com.levi.pocketdj.shell.MixFacade
import com.levi.pocketdj.shell.MixSource
import com.levi.pocketdj.shell.MixStartResult
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoMixControlsTest {
    private class Facade(override var autoMixing: Boolean = true) : MixFacade {
        override var autoPaused = false
        override suspend fun startAutoMix(source: MixSource, shuffle: Boolean, allowPendingStart: Boolean) = MixStartResult("X", 1)
        override suspend fun startAutoMix(deckA: MixSource, deckB: MixSource, shuffle: Boolean, allowPendingStart: Boolean) = MixStartResult("X", 1)
        override fun pauseAutoMix() {}
        override fun resumeAutoMix() {}
    }

    private class Extras : AutoMixExtras {
        var ctl: AutoMixControls? = AutoMixControls(
            slots = listOf(AutoFxSlot("Comp · Punch", false), AutoFxSlot("LP", true)),
            rate = 1.0, pitch = 0.0,
        )
        var setup: AutoMixControls? = null
        val calls = mutableListOf<String>()
        var qr: String? = "content://x/qr.png"
        override var slowSkipSeconds = 15.0
        override fun crates() = emptyList<AutoCrate>()
        override fun live() = AutoMixLive(title = "T")
        override fun skipFast() {}
        override fun skipSlow() {}
        override fun stop() {}
        override suspend fun jukeboxSessions() = listOf(AutoJukeSession("j1", "Party", false, "https://x/j1?hostKey=SECRET"))
        override fun controls() = ctl
        override fun setupControls() = setup
        override fun setFxGlide(on: Boolean) { calls += "fxGlide:$on" }
        override fun setAudioGlide(on: Boolean) { calls += "audioGlide:$on" }
        override fun setSlot(index: Int, enabled: Boolean) { calls += "slot:$index:$enabled" }
        override fun setRate(rate: Double) { calls += "rate:$rate" }
        override fun setPitch(semitones: Double) { calls += "pitch:$semitones" }
        override fun setStemMode(on: Boolean) { calls += "stems:$on" }
        override fun toggleStemMute(name: String) { calls += "mute:$name" }
        override fun qrArtworkUri(url: String) = qr
    }

    private val facade = Facade()
    private val extras = Extras()
    private val tab = AutoMixTab(facade, extras)

    private fun kids() = tab.children(AutoMixTab.ROOT)!!
    private fun row(k: AutoMixKind, a: String = "") = kids().first { it.id == AutoId.Mix(k, a).encoded }
    private fun sel(k: AutoMixKind, a: String = "") = runBlocking { tab.select(AutoId.Mix(k, a)) }

    @Test fun liveRows_listEveryControlInIosOrderAfterStop() {
        val ids = kids().map { (AutoId.decode(it.id) as AutoId.Mix).kind }
        val stop = ids.indexOf(AutoMixKind.STOP)
        val tail = ids.drop(stop + 1)
        assertEquals(
            listOf(
                AutoMixKind.FX_GLIDE, AutoMixKind.AUDIO_GLIDE, AutoMixKind.FX_SLOT, AutoMixKind.FX_SLOT,
                AutoMixKind.TEMPO_DOWN, AutoMixKind.TEMPO_UP, AutoMixKind.PITCH_DOWN, AutoMixKind.PITCH_UP,
                AutoMixKind.STEMS, AutoMixKind.STEM_MUTE, AutoMixKind.STEM_MUTE, AutoMixKind.STEM_MUTE, AutoMixKind.STEM_MUTE,
                AutoMixKind.JUKEBOX,
            ),
            tail,
        )
    }

    @Test fun noControls_leavesTheOriginalRowsUntouched() {
        extras.ctl = null
        val ids = kids().map { (AutoId.decode(it.id) as AutoId.Mix).kind }
        assertEquals(AutoMixKind.STOP, ids[ids.size - 2])
        assertEquals(AutoMixKind.JUKEBOX, ids.last())
        sel(AutoMixKind.TEMPO_UP)
        assertTrue(extras.calls.isEmpty())
    }

    @Test fun tempoAndPitch_stepFromTheLeadDeckAndRoundCleanly() {
        extras.ctl = extras.ctl!!.copy(rate = 1.07, pitch = 2.0)
        sel(AutoMixKind.TEMPO_UP); sel(AutoMixKind.TEMPO_DOWN); sel(AutoMixKind.PITCH_UP); sel(AutoMixKind.PITCH_DOWN)
        assertEquals(listOf("rate:1.08", "rate:1.06", "pitch:3.0", "pitch:1.0"), extras.calls)
        assertEquals("107%", row(AutoMixKind.TEMPO_UP).subtitle)
        assertEquals("2", row(AutoMixKind.PITCH_DOWN).subtitle)
    }

    @Test fun midTransition_disablesTempoAndPitchRowsAndIgnoresTaps() {
        extras.ctl = extras.ctl!!.copy(inTransition = true)
        for (k in listOf(AutoMixKind.TEMPO_DOWN, AutoMixKind.TEMPO_UP, AutoMixKind.PITCH_DOWN, AutoMixKind.PITCH_UP)) {
            assertFalse(row(k).playable)
            assertEquals(AutoMixTab.TRANSITION_HOLD, row(k).subtitle)
            sel(k)
        }
        assertTrue(extras.calls.isEmpty())
        assertTrue("FX/stems stay live mid-transition", row(AutoMixKind.STEMS).playable)
    }

    @Test fun stemMute_withStemsOff_turnsStemsOnFirst() {
        sel(AutoMixKind.STEM_MUTE, "drums")
        assertEquals(listOf("stems:true", "mute:drums"), extras.calls)
    }

    @Test fun stemMute_withStemsOn_justToggles_andRowsReflectMutes() {
        extras.ctl = extras.ctl!!.copy(stemsOn = true, mutedStems = setOf("bass"))
        sel(AutoMixKind.STEM_MUTE, "vocals")
        assertEquals(listOf("mute:vocals"), extras.calls)
        assertEquals("Muted", row(AutoMixKind.STEM_MUTE, "bass").subtitle)
        assertEquals("Unmuted", row(AutoMixKind.STEM_MUTE, "other").subtitle)
        assertEquals("On", row(AutoMixKind.STEMS).subtitle)
    }

    @Test fun unknownStemName_isIgnored_andStemsRowShowsLoading() {
        sel(AutoMixKind.STEM_MUTE, "kazoo")
        assertTrue(extras.calls.isEmpty())
        extras.ctl = extras.ctl!!.copy(stemsLoading = true)
        assertEquals("Loading…", row(AutoMixKind.STEMS).subtitle)
    }

    @Test fun stemsToggle_flipsCurrentIntent() {
        sel(AutoMixKind.STEMS)
        extras.ctl = extras.ctl!!.copy(stemsOn = true)
        sel(AutoMixKind.STEMS)
        assertEquals(listOf("stems:true", "stems:false"), extras.calls)
    }

    @Test fun fxSlots_toggleByIndex_andOutOfRangeIsNoop() {
        sel(AutoMixKind.FX_SLOT, "0"); sel(AutoMixKind.FX_SLOT, "1"); sel(AutoMixKind.FX_SLOT, "9"); sel(AutoMixKind.FX_SLOT, "x")
        assertEquals(listOf("slot:0:true", "slot:1:false"), extras.calls)
        assertEquals("FX · Comp · Punch", row(AutoMixKind.FX_SLOT, "0").title)
    }

    @Test fun glideToggles_flipForNextTransition() {
        extras.ctl = extras.ctl!!.copy(fxGlide = true)
        sel(AutoMixKind.FX_GLIDE); sel(AutoMixKind.AUDIO_GLIDE)
        assertEquals(listOf("fxGlide:false", "audioGlide:true"), extras.calls)
    }

    @Test fun controlsNeverFire_whenNoMixIsOnAir() {
        facade.autoMixing = false
        sel(AutoMixKind.TEMPO_UP); sel(AutoMixKind.STEM_MUTE, "drums"); sel(AutoMixKind.FX_SLOT, "0")
        assertTrue(extras.calls.isEmpty())
    }

    @Test fun shortfall_showsIosCopy_inLiveAndSetup() {
        extras.ctl = extras.ctl!!.copy(shortfall = 9 to 6)
        val r = row(AutoMixKind.SHORTFALL)
        assertEquals("Only 6 of 9 songs available", r.title)
        assertEquals("Rest not in this device's catalog yet — re-checks as it loads", r.subtitle)
        assertFalse(r.playable)
        facade.autoMixing = false
        extras.setup = AutoMixControls(shortfall = 4 to 3)
        assertNotNull(kids().firstOrNull { it.id == AutoId.Mix(AutoMixKind.SHORTFALL).encoded })
        assertTrue(kids().any { it.title == "FX Glide" })
    }

    @Test fun setupWithoutControls_hasNoGlideOrShortfall() {
        facade.autoMixing = false
        assertTrue(kids().none { it.title == "FX Glide" || it.id.contains("short") })
    }

    @Test fun jukeboxSession_hasQrArtworkRowThenUrl() {
        val sc = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined)
        tab.bind(sc) { _, _ -> }
        tab.children(AutoId.Mix(AutoMixKind.JUKEBOX))
        val kids = tab.children(AutoId.Mix(AutoMixKind.SESSION, "j1"))!!
        assertEquals(AutoMixKind.SESSION_QR, (AutoId.decode(kids[0].id) as AutoId.Mix).kind)
        assertEquals("content://x/qr.png", kids[0].artUrl)
        assertEquals(AutoMixKind.SESSION_URL, (AutoId.decode(kids[1].id) as AutoId.Mix).kind)
        extras.qr = null
        assertEquals(1, tab.children(AutoId.Mix(AutoMixKind.SESSION, "j1"))!!.size)
        assertNotNull(kids().firstOrNull { it.id == AutoId.Mix(AutoMixKind.JUKEBOX).encoded })
    }

    @Test fun jukeboxNode_presentPreStartToo() {
        facade.autoMixing = false
        assertNotNull(kids().firstOrNull { it.id == AutoId.Mix(AutoMixKind.JUKEBOX).encoded })
    }

    @Test fun qrPayload_stripsHostKey_keepsOtherParams() {
        assertEquals("https://x/j1", AutoJukeboxQr.payload("https://x/j1?hostKey=SECRET"))
        assertEquals("https://x/j1?a=1&b=2#f", AutoJukeboxQr.payload("https://x/j1?a=1&hostKey=S&b=2#f"))
        assertEquals("https://x/j1", AutoJukeboxQr.payload("https://x/j1"))
    }

    @Test fun qrPixels_squareBlackAndWhite_andFileNameStableAndSecretFree() {
        val (px, side) = AutoJukeboxQr.pixels("https://pocketdj.example/j/abc")!!
        assertEquals(side * side, px.size)
        assertTrue(side >= 200)
        assertTrue(px.any { it == 0xFF000000.toInt() } && px.any { it == 0xFFFFFFFF.toInt() })
        assertEquals(AutoJukeboxQr.fileName("https://x/j1?hostKey=A"), AutoJukeboxQr.fileName("https://x/j1?hostKey=B"))
        assertFalse(AutoJukeboxQr.fileName("https://x/j1").contains("x/j1"))
        assertTrue(AutoJukeboxQr.isContentArt("content://a/b"))
        assertFalse(AutoJukeboxQr.isContentArt("file:///a"))
        assertNull(AutoArtwork.httpsOrNull("content://a/b"))
    }

    @Test fun idCodec_roundTripsNewKinds() {
        for (k in AutoMixKind.entries) {
            val id = AutoId.Mix(k, "a1", "b1")
            assertEquals(id, AutoId.decode(id.encoded))
        }
    }
}
