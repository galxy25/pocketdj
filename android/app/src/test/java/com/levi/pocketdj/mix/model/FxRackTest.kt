package com.levi.pocketdj.mix.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class FxRackTest {
    @Test fun everyVariantBelongsToExactlyOneFamilyAndRawRoundTrips() {
        for (v in EffectVariant.entries) {
            assertEquals(v, EffectVariant.fromRaw(v.raw))
            assertTrue(v in EffectVariant.all(v.effect))
        }
        assertEquals(EffectVariant.entries.size, Effect.entries.sumOf { EffectVariant.all(it).size })
        assertNull(EffectVariant.fromRaw("nope"))
    }

    @Test fun familyMembership() {
        assertEquals(listOf(EffectVariant.LOW_PASS, EffectVariant.HIGH_PASS, EffectVariant.BAND_PASS), EffectVariant.all(Effect.FILTER))
        assertEquals(listOf(EffectVariant.ROOM, EffectVariant.HALL, EffectVariant.PLATE, EffectVariant.CATHEDRAL), EffectVariant.all(Effect.REVERB))
        assertEquals(listOf(EffectVariant.FLANGE, EffectVariant.CHORUS, EffectVariant.ECHO), EffectVariant.all(Effect.FLANGER))
        assertEquals(listOf(EffectVariant.PUNCH, EffectVariant.GLUE, EffectVariant.LIMIT), EffectVariant.all(Effect.COMPRESSOR))
    }

    @Test fun legacyRawValuesPersistAsIos() {
        assertEquals("flanger", Effect.FLANGER.raw)
        assertEquals("lowPass", EffectVariant.LOW_PASS.raw)
        assertEquals("quarterTriplet", ModRate.QUARTER_TRIPLET.raw)
        assertEquals("envelope", ModSource.ENVELOPE.raw)
        assertEquals(Effect.FLANGER, Effect.fromRaw("flanger"))
    }

    @Test fun defaultVariantPerFamily() {
        assertEquals(EffectVariant.PUNCH, EffectVariant.default(Effect.COMPRESSOR))
        assertEquals(EffectVariant.HALL, EffectVariant.default(Effect.REVERB))
        assertEquals(EffectVariant.FLANGE, EffectVariant.default(Effect.FLANGER))
        assertEquals(EffectVariant.LOW_PASS, EffectVariant.default(Effect.FILTER))
    }

    @Test fun defaultRackLayout() {
        val rack = FxRack.defaultSlots()
        assertEquals(FxRack.SLOT_COUNT, rack.size)
        assertEquals(listOf(Effect.COMPRESSOR, Effect.REVERB, Effect.FLANGER, Effect.FILTER), rack.map { it.effect })
        assertEquals(
            listOf(EffectVariant.PUNCH, EffectVariant.HALL, EffectVariant.FLANGE, EffectVariant.LOW_PASS),
            rack.map { it.variant },
        )
        assertTrue(rack.none { it.enabled })
        assertTrue(rack.all { it.strength == 0.5 })
    }

    @Test fun mismatchedVariantFallsBackToFamilyDefault() {
        val s = FXSlot(Effect.REVERB, EffectVariant.HIGH_PASS)
        assertEquals(EffectVariant.HALL, s.variant)
        assertEquals(s.effect, s.variant.effect)
    }

    @Test fun matchingVariantIsKept() {
        assertEquals(EffectVariant.CATHEDRAL, FXSlot(Effect.REVERB, EffectVariant.CATHEDRAL).variant)
    }

    @Test fun setEffectResetsVariantButKeepsOtherState() {
        val mod = SlotMod.of(ModSource.LFO, ModRate.QUARTER, 0.7, ModShape.SAW, 0.5)
        val s = FXSlot(Effect.FILTER, EffectVariant.HIGH_PASS, true, 0.8, mod)
        val t = s.setEffect(Effect.FLANGER)
        assertEquals(Effect.FLANGER, t.effect)
        assertEquals(EffectVariant.FLANGE, t.variant)
        assertTrue(t.enabled)
        assertEquals(0.8, t.strength, 0.0)
        assertEquals(mod, t.mod)
        assertEquals(t.effect, t.variant.effect)
    }

    @Test fun setEffectSameFamilyKeepsVariant() {
        val s = FXSlot(Effect.FILTER, EffectVariant.BAND_PASS)
        assertSame(s, s.setEffect(Effect.FILTER))
        assertEquals(EffectVariant.BAND_PASS, s.setEffect(Effect.FILTER).variant)
    }

    @Test fun setVariantSameFamilyAppliesCrossFamilyIgnored() {
        val s = FXSlot(Effect.FILTER)
        assertEquals(EffectVariant.HIGH_PASS, s.setVariant(EffectVariant.HIGH_PASS).variant)
        assertSame(s, s.setVariant(EffectVariant.ECHO))
        assertEquals(EffectVariant.LOW_PASS, s.setVariant(EffectVariant.ECHO).variant)
    }

    @Test fun strengthClampedEverywhere() {
        assertEquals(1.0, FXSlot(Effect.FILTER, strength = 7.0).strength, 0.0)
        assertEquals(0.0, FXSlot(Effect.FILTER, strength = -1.0).strength, 0.0)
        assertEquals(1.0, FXSlot(Effect.FILTER).setStrength(3.0).strength, 0.0)
        assertEquals(0.0, FXSlot(Effect.FILTER).setStrength(-3.0).strength, 0.0)
    }

    @Test fun modSurvivesEffectAndVariantChanges() {
        val base = FXSlot(Effect.FILTER)
        assertEquals(ModSource.OFF, base.mod.source)
        val s = base.setMod(SlotMod.of(ModSource.LFO, ModRate.QUARTER, 0.7, ModShape.SAW, 0.5))
            .setVariant(EffectVariant.HIGH_PASS)
        assertEquals(ModRate.QUARTER, s.mod.rate)
        val t = s.setEffect(Effect.FLANGER)
        assertEquals(ModSource.LFO, t.mod.source)
        assertEquals(0.5, t.mod.phase, 1e-9)
    }

    @Test fun slotModDepthClampAndPhaseFold() {
        assertEquals(1.0, SlotMod.of(ModSource.LFO, depth = 7.0).depth, 0.0)
        assertEquals(-1.0, SlotMod.of(ModSource.LFO, depth = -7.0).depth, 0.0)
        assertEquals(0.25, SlotMod.of(ModSource.LFO, phase = 1.25).phase, 1e-9)
        assertEquals(0.75, SlotMod.of(ModSource.LFO, phase = -0.25).phase, 1e-9)
        assertEquals(0.0, SlotMod.of(ModSource.LFO, phase = 3.0).phase, 1e-9)
        val normalized = SlotMod(ModSource.LFO, depth = 9.0, phase = 2.5).normalized()
        assertEquals(1.0, normalized.depth, 0.0)
        assertEquals(0.5, normalized.phase, 1e-9)
    }

    @Test fun slotEqualityIsStructural() {
        assertEquals(FXSlot(Effect.REVERB), FXSlot(Effect.REVERB))
        assertEquals(FXSlot(Effect.REVERB).hashCode(), FXSlot(Effect.REVERB).hashCode())
        assertFalse(FXSlot(Effect.REVERB) == FXSlot(Effect.REVERB).setEnabled(true))
    }

    @Test fun getSafeIsBoundsChecked() {
        val rack = FxRack.defaultSlots()
        assertEquals(Effect.FILTER, rack.getSafe(3)!!.effect)
        assertNull(rack.getSafe(4))
        assertNull(rack.getSafe(-1))
    }

    @Test fun deckAndSourceModels() {
        assertEquals(Deck.B, Deck.A.other)
        assertEquals(Deck.A, Deck.fromLabel("A"))
        assertNull(Deck.fromLabel("C"))
        assertEquals("pocket:p1", MixSource.Pocket("p1").id)
        assertEquals(MixSource.Setlist("s:9"), MixSource.fromId("setlist:s:9"))
        assertEquals(MixSource.Playlist("x"), MixSource.fromId(MixSource.Playlist("x").id))
        assertNull(MixSource.fromId("bogus:1"))
        assertNull(MixSource.fromId("pocket:"))
        assertEquals(listOf(0, 1, 2), EQBand.entries.map { it.bandIndex })
        assertEquals(AutoRepeatMode.ALL, AutoRepeatMode.fromRaw("all"))
        assertEquals(4.0, LoadedTrack("s", "t", "a", bpm = 100.0, gridBpm = 4.0).matchBpm!!, 0.0)
        assertEquals(100.0, LoadedTrack("s", "t", "a", bpm = 100.0).matchBpm!!, 0.0)
    }

    @Test
    fun primaryConstructorNormalisesMod() {
        val s = FXSlot(Effect.FILTER, mod = SlotMod(source = ModSource.LFO, depth = 1.8, phase = 2.25))
        assertEquals(1.0, s.mod.depth, 1e-9)
        assertEquals(0.25, s.mod.phase, 1e-9)
    }
}
