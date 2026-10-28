package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.MixSessionEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MixEventSentencesTest {
    private fun ev(kind: MixEventKind, deck: String? = "A", title: String? = null, artist: String? = null,
                   param: String? = null, value: Double? = null, flag: Boolean? = null,
                   from: Double? = null, slot: Int? = null) =
        MixSessionEvent(id = "e1", tMs = 0, kind = kind, deck = deck, title = title, artist = artist,
            param = param, value = value, flag = flag, fromValue = from, slot = slot)

    private fun text(e: MixSessionEvent) = MixEventSentences.describe(e).text

    @Test fun load() {
        assertEquals("Load: Song — Band", text(ev(MixEventKind.Load, title = "Song", artist = "Band")))
        assertEquals("Load: track", text(ev(MixEventKind.Load)))
    }
    @Test fun playPause() {
        assertEquals("Play", text(ev(MixEventKind.Play)))
        assertEquals(EventTint.GREEN, MixEventSentences.describe(ev(MixEventKind.Play)).tint)
        assertEquals("Pause", text(ev(MixEventKind.Pause)))
    }
    @Test fun seekTempoPitchVolCross() {
        assertEquals("Seek → 1:05", text(ev(MixEventKind.Seek, value = 65.0)))
        assertEquals("Tempo → 1.05×", text(ev(MixEventKind.Tempo, value = 1.05)))
        assertEquals("Tempo → 1.00×", text(ev(MixEventKind.Tempo)))
        assertEquals("Pitch → +2.0", text(ev(MixEventKind.Pitch, value = 2.0)))
        assertEquals("Pitch → -1.5", text(ev(MixEventKind.Pitch, value = -1.5)))
        assertEquals("Vol → 80%", text(ev(MixEventKind.Volume, value = 0.8)))
        assertEquals("Crossfader → 0.50", text(ev(MixEventKind.Crossfader, deck = null)))
    }
    @Test fun effects() {
        assertEquals("Reverb on", text(ev(MixEventKind.EffectToggle, param = "reverb", flag = true)))
        assertEquals("Reverb off (slot 3)", text(ev(MixEventKind.EffectToggle, param = "reverb", flag = false, slot = 2)))
        assertEquals("Filter 40% (slot 1)", text(ev(MixEventKind.EffectStrength, param = "filter", value = 0.4, slot = 0)))
        assertEquals("Slot 2 → Flanger", text(ev(MixEventKind.EffectSlot, param = "flanger", slot = 1)))
        assertEquals(EventIcon.FLANGER, MixEventSentences.describe(ev(MixEventKind.EffectSlot, param = "flanger")).icon)
        assertEquals("Slot 1 → Cathedral", text(ev(MixEventKind.EffectVariant, param = "cathedral", slot = 0)))
        assertEquals("Slot 1 → Low-pass", text(ev(MixEventKind.EffectVariant, param = "lowPass", slot = 0)))
        assertEquals("Slot 1 → Mystery", text(ev(MixEventKind.EffectVariant, param = "mystery", slot = 0)))
        assertEquals("Slot 4 → variant", text(ev(MixEventKind.EffectVariant, slot = 3)))
    }
    @Test fun effectMod() {
        assertEquals("Slot 1 mod → LFO 1/4 Saw +60%", text(ev(MixEventKind.EffectMod, param = "lfo:quarter:saw", value = 0.6, slot = 0)))
        assertEquals("Slot 1 mod → Off", text(ev(MixEventKind.EffectMod, param = "off:bar:sine", value = 0.6, slot = 0)))
        assertEquals("Slot 1 mod → Off", text(ev(MixEventKind.EffectMod, param = null, slot = 0)))
        assertEquals("Slot 2 mod → Env", text(ev(MixEventKind.EffectMod, param = "envelope", slot = 1)))
        assertEquals("Slot 1 mod → LFO weird zig", text(ev(MixEventKind.EffectMod, param = "lfo:weird:zig", slot = 0)))
    }
    @Test fun eqAndFilterMode() {
        assertEquals("EQ Low → -6 dB", text(ev(MixEventKind.Eq, param = "low", value = -6.0)))
        assertEquals("EQ High → +3 dB", text(ev(MixEventKind.Eq, param = "high", value = 3.0)))
        assertEquals("Filter → High-pass", text(ev(MixEventKind.FilterMode, param = "highPass")))
        assertEquals("Filter → Low-pass", text(ev(MixEventKind.FilterMode, param = "lowPass")))
    }
    @Test fun stems() {
        assertEquals("Stems on", text(ev(MixEventKind.StemMode, flag = true)))
        assertEquals("Stems off", text(ev(MixEventKind.StemMode)))
        assertEquals("Drums muted", text(ev(MixEventKind.StemMute, param = "drums", flag = true)))
        assertEquals(EventTint.YELLOW, MixEventSentences.describe(ev(MixEventKind.StemMute, param = "drums", flag = true)).tint)
        assertEquals("Vocals unmuted", text(ev(MixEventKind.StemMute, param = "vocals", flag = false)))
        assertEquals("Bass 50%", text(ev(MixEventKind.StemVolume, param = "bass", value = 0.5)))
        assertEquals(EventTint.RED, MixEventSentences.describe(ev(MixEventKind.StemVolume, param = "bass", value = 0.5)).tint)
    }
    @Test fun leadSyncReset() {
        assertEquals("Lead set", text(ev(MixEventKind.Lead, flag = true)))
        assertEquals("Lead cleared", text(ev(MixEventKind.Lead, flag = false)))
        assertEquals("Sync → 0.98×", text(ev(MixEventKind.Sync, value = 0.98)))
        assertEquals("Reset deck", text(ev(MixEventKind.ResetDeck)))
    }
    @Test fun autoPauseResume() {
        assertEquals("Auto-mix paused", text(ev(MixEventKind.AutoPause, deck = null)))
        assertEquals("Auto-mix resumed", text(ev(MixEventKind.AutoResume, deck = null)))
    }
    @Test fun glide() {
        assertEquals("Glide · Crossfader 0.00→1.00", text(ev(MixEventKind.Glide, param = "crossfader", from = 0.0, value = 1.0)))
        assertEquals("Glide · Tempo 1.00×→1.04×", text(ev(MixEventKind.Glide, param = "tempo", from = 1.0, value = 1.04)))
        assertEquals("Glide · Pitch +0.0→-2.0", text(ev(MixEventKind.Glide, param = "pitch", from = 0.0, value = -2.0)))
        assertEquals("Glide · Reverb 0%→60%", text(ev(MixEventKind.Glide, param = "reverb", from = 0.0, value = 0.6)))
    }
    @Test fun unknownShowsRawKind() {
        val d = MixEventSentences.describe(ev(MixEventKind.fromRaw("futureThing")))
        assertEquals("futureThing", d.text)
        assertEquals(EventIcon.UNKNOWN, d.icon)
    }
    @Test fun everyKnownKindDescribesWithoutThrowing() {
        for (k in MixEventKind.known.values) assertTrue(k.raw, text(ev(k)).isNotEmpty())
        assertEquals(24, MixEventKind.known.size)
    }
    @Test fun clocks() {
        assertEquals("0:00.0", MixEventSentences.clock(0))
        assertEquals("1:02.3", MixEventSentences.clock(62_345))
        assertEquals("0:00.0", MixEventSentences.clock(-5))
        assertEquals("2:00", MixEventSentences.mmss(119.6))
    }
}
