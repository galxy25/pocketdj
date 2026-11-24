package com.levi.pocketdj.shell

import com.levi.pocketdj.mix.nowplaying.NpMixMode
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NowPlayingVoiceActionsTest {

    private class FakePort : NowPlayingVoicePort {
        val calls = mutableListOf<String>()
        override var running = true
        override var mixTabLive = false
        override var mixModeEnabled = false
        override var mixAvailable = true
        override var indicator: NpMixMode.Indicator = NpMixMode.Indicator.Ready
        override var mixEngaged = false
        override var stemMode = false
        override var stemsLoading = false
        var engageWorks = true
        var switchWorks = true
        var stemModeWorks = true
        var stemsLoadingAfterOn = false
        val muted = mutableSetOf<String>()

        override fun setMixMode(on: Boolean) { calls += "mixMode($on)"; if (switchWorks) mixModeEnabled = on }
        override suspend fun engageMix() { calls += "engage"; if (engageWorks) mixEngaged = true }
        override fun isStemMuted(stemName: String) = stemName in muted
        override fun setStemMode(on: Boolean): Boolean {
            calls += "stemMode($on)"
            if (!stemModeWorks) return false
            stemMode = on
            stemsLoading = stemsLoadingAfterOn
            return true
        }
        override fun toggleStemMute(stemName: String) {
            calls += "toggle($stemName)"
            if (!muted.add(stemName)) muted.remove(stemName)
        }
    }

    private fun run(p: FakePort, stem: StemPart, muted: Boolean) =
        runBlocking { NowPlayingVoiceActions(p).setStem(stem, muted) }

    @Test fun muteFromCold_runsTheExactPanelOrder() {
        val p = FakePort()
        val said = run(p, StemPart.Vocals, true)
        assertEquals(listOf("mixMode(true)", "engage", "stemMode(true)", "toggle(vocals)"), p.calls)
        assertEquals("Turned on Mix Mode and muted the vocals.", said)
    }

    @Test fun muteWithModeAlreadyOn_doesNotTouchTheSwitch() {
        val p = FakePort().apply { mixModeEnabled = true }
        assertEquals("Muted the drums.", run(p, StemPart.Drums, true))
        assertEquals(listOf("engage", "stemMode(true)", "toggle(drums)"), p.calls)
    }

    @Test fun muteWhenStemModeAlreadyOn_skipsStemMode() {
        val p = FakePort().apply { mixModeEnabled = true; mixEngaged = true; stemMode = true }
        run(p, StemPart.Bass, true)
        assertEquals(listOf("engage", "toggle(bass)"), p.calls)
    }

    @Test fun muteWhileStemsLoading_doesNotReissueStemMode_andSaysItTakesAMoment() {
        val p = FakePort().apply { mixModeEnabled = true; stemsLoading = true }
        val said = run(p, StemPart.Other, true)
        assertFalse("stemMode(true)" in p.calls)
        assertEquals("Muted the other instruments — the stems are loading, so it takes effect in a moment.", said)
    }

    @Test fun alreadyMuted_isReportedAndNeverToggledBack() {
        val p = FakePort().apply { mixModeEnabled = true; mixEngaged = true; stemMode = true; muted += "vocals" }
        assertEquals("The vocals are already muted.", run(p, StemPart.Vocals, true))
        assertTrue(p.calls.isEmpty())
        p.muted += "bass"
        assertEquals("The bass is already muted.", run(p, StemPart.Bass, true))
        assertTrue("vocals" in p.muted)
    }

    @Test fun unmute_onlyTouchesAMutedStem() {
        val p = FakePort().apply { mixModeEnabled = true; mixEngaged = true; stemMode = true; muted += "drums" }
        assertEquals("Unmuted the drums.", run(p, StemPart.Drums, false))
        assertEquals(listOf("toggle(drums)"), p.calls)
        assertEquals("The drums are already playing.", run(p, StemPart.Drums, false))
        assertEquals(listOf("toggle(drums)"), p.calls)
    }

    @Test fun unmute_neverEnablesModeOrEngages() {
        val p = FakePort()
        assertEquals("The bass is already playing.", run(p, StemPart.Bass, false))
        assertTrue(p.calls.isEmpty())
    }

    @Test fun unmute_withStemsOffIsAlreadyPlaying_evenIfMutedSetStale() {
        val p = FakePort().apply { mixEngaged = true; stemMode = false; muted += "vocals" }
        assertEquals("The vocals are already playing.", run(p, StemPart.Vocals, false))
    }

    @Test fun refusals_nothingPlayingAndMixTabLive() {
        val idle = FakePort().apply { running = false }
        try { run(idle, StemPart.Vocals, true); fail() } catch (e: ShellActionException) { assertEquals(ShellActionException.NothingPlaying, e) }
        try { runBlocking { NowPlayingVoiceActions(idle).setMixMode(true) }; fail() } catch (e: ShellActionException) { assertEquals(ShellActionException.NothingPlaying, e) }
        val live = FakePort().apply { mixTabLive = true }
        try { run(live, StemPart.Vocals, false); fail() } catch (e: ShellActionException) {
            assertEquals(ShellActionException.MixTabLive, e)
            assertTrue(e.message!!.startsWith("The Mix tab is playing."))
        }
        assertTrue(live.calls.isEmpty())
    }

    @Test fun unavailable_downloading_explainsWithChipText_afterTurningModeOn() {
        val p = FakePort().apply { mixAvailable = false; indicator = NpMixMode.Indicator.Buffering(0.5) }
        val said = run(p, StemPart.Vocals, true)
        assertEquals(listOf("mixMode(true)"), p.calls)
        assertEquals("Mix Mode is on, but I can't mute the vocals yet — this song is still downloading (${NpMixMode.Indicator.Buffering(0.5).chipText}). Ask again in a moment.", said)
    }

    @Test fun unavailable_otherReason_usesTheChipText_andNoLeadWhenAlreadyOn() {
        val p = FakePort().apply {
            mixModeEnabled = true; mixAvailable = false
            indicator = NpMixMode.Indicator.Unavailable("Not on this device")
        }
        assertEquals("I can't mute the drums on this song: Not on this device.", run(p, StemPart.Drums, true))
        assertTrue(p.calls.isEmpty())
    }

    @Test fun unavailable_withNoChip_fallsBackToNotOnTheDevice() {
        val p = FakePort().apply { mixModeEnabled = true; mixAvailable = false; indicator = NpMixMode.Indicator.Off }
        assertEquals("I can't mute the bass on this song: this song isn't on the device.", run(p, StemPart.Bass, true))
    }

    @Test fun engageRefused_andNoStems_areExplained() {
        val a = FakePort().apply { engageWorks = false }
        assertEquals("Mix Mode is on, but I couldn't open this song for mixing, so the vocals can't be muted.", run(a, StemPart.Vocals, true))
        assertEquals(listOf("mixMode(true)", "engage"), a.calls)
        val b = FakePort().apply { mixModeEnabled = true; stemModeWorks = false }
        assertEquals("this song has no stems yet, so the drums can't be muted.", run(b, StemPart.Drums, true))
        assertFalse(b.calls.any { it.startsWith("toggle") })
    }

    @Test fun mixMode_sentencesAndIdempotence() {
        val p = FakePort()
        val a = NowPlayingVoiceActions(p)
        assertEquals("Mix Mode is off.".let { "Mix Mode is already off." }, a.setMixMode(false))
        assertTrue(p.calls.isEmpty())
        assertEquals("Mix Mode is on — buffering this song and the next ones so stems and effects work on them.", a.setMixMode(true))
        assertEquals("Mix Mode is already on.", a.setMixMode(true))
        assertEquals("Mix Mode is off.", a.setMixMode(false))
        assertEquals(listOf("mixMode(true)", "mixMode(false)"), p.calls)
    }

    @Test fun mixMode_noOpSwitch_isNotReportedAsOn() {
        val p = FakePort().apply { switchWorks = false }
        assertEquals("Mix Mode isn't available right now.", runBlocking { NowPlayingVoiceActions(p).setMixMode(true) })
    }

    @Test fun mute_noOpSwitch_isNotReportedAsTurnedOn() {
        val p = FakePort().apply { switchWorks = false }
        val said = run(p, StemPart.Vocals, true)
        assertTrue(said, said.contains("isn't available"))
        assertFalse("engage" in p.calls)
    }

    @Test fun deepLinks_offSynonymsTurnOff_andGarbageIsNotOn() {
        for (v in listOf("disable", "stop", "off")) {
            assertEquals(DeepLink.NowPlayingMixMode(false), DeepLinkParser.parse("pocketdj://np/mixmode?on=$v"))
        }
        assertEquals(DeepLink.NowPlayingMixMode(true), DeepLinkParser.parse("pocketdj://np/mixmode?on=enable"))
        assertTrue(DeepLinkParser.parse("pocketdj://np/mixmode?on=banana") is DeepLink.Unresolved)
    }

    @Test fun mixMode_onWithMixTabLive_saysItWaits() {
        val p = FakePort().apply { mixTabLive = true }
        assertEquals("Mix Mode is on. It starts buffering once the Mix tab stops.", NowPlayingVoiceActions(p).setMixMode(true))
    }

    @Test fun stemPartSynonyms() {
        assertEquals(StemPart.Vocals, StemPart.parse("voice"))
        assertEquals(StemPart.Vocals, StemPart.parse("The Vocals"))
        assertEquals(StemPart.Drums, StemPart.parse("beat"))
        assertEquals(StemPart.Drums, StemPart.parse("the beat"))
        assertEquals(StemPart.Bass, StemPart.parse("bassline"))
        assertEquals(StemPart.Bass, StemPart.parse("bass line"))
        assertEquals(StemPart.Other, StemPart.parse("instruments"))
        assertEquals(StemPart.Other, StemPart.parse("other"))
        assertNull(StemPart.parse("drop"))
        assertNull(StemPart.parse(""))
        assertNull(StemPart.parse(null))
        assertEquals(listOf("vocals", "drums", "bass", "other"), StemPart.entries.map { it.stemName })
    }

    @Test fun deepLinks_mixMode() {
        assertEquals(DeepLink.NowPlayingMixMode(true), DeepLinkParser.parse("pocketdj://np/mixmode?on=1"))
        assertEquals(DeepLink.NowPlayingMixMode(false), DeepLinkParser.parse("pocketdj://np/mixmode?on=0"))
        assertEquals(DeepLink.NowPlayingMixMode(false), DeepLinkParser.parse("pocketdj://np/mixmode?on=false"))
        assertEquals(DeepLink.NowPlayingMixMode(true), DeepLinkParser.parse("pocketdj://np/mixmode"))
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://np/bogus"))
    }

    @Test fun deepLinks_stem() {
        assertEquals(DeepLink.NowPlayingStem(StemPart.Vocals, true), DeepLinkParser.parse("pocketdj://np/stem/vocals?mute=1"))
        assertEquals(DeepLink.NowPlayingStem(StemPart.Drums, false), DeepLinkParser.parse("pocketdj://np/stem/beat?mute=0"))
        assertEquals(DeepLink.NowPlayingStem(StemPart.Bass, true), DeepLinkParser.parse("pocketdj://np/stem/bass"))
        assertEquals(DeepLink.NowPlayingStem(StemPart.Bass, true), DeepLinkParser.parse("pocketdj:///np/stem/bass%20line?mute=1"))
        assertTrue(DeepLinkParser.parse("pocketdj://np/stem/kazoo?mute=1") is DeepLink.Unresolved)
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://np/stem"))
    }
}
