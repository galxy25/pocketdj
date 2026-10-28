package com.levi.pocketdj.data.edition

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.edition.EditionPolicy.Reason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EditionPolicyTest {
    private val base = "sng_0123456789ab"

    private fun song(
        explicit: Boolean? = true, primary: String? = "100",
        exp: String? = null, clean: String? = null, id: String = base,
    ) = IndexSong(
        id = id, artist = "A", name = "N", explicit = explicit, appleMusicId = primary,
        appleMusicIdExplicit = exp, appleMusicIdClean = clean,
    )

    @Test fun nullSong_unchanged() =
        assertEquals(EditionPolicy.Decision.UNCHANGED, EditionPolicy.decide(null, true, true))

    @Test fun unset_preference_noSubstitution() =
        assertEquals(EditionPolicy.Decision.UNCHANGED, EditionPolicy.decide(song(clean = "200"), false, null))

    @Test fun globalFalse_prefersClean() {
        val d = EditionPolicy.decide(song(clean = "200"), false, false)
        assertEquals(SongVariant.CLEAN, d.edition); assertEquals("200", d.catalogId); assertEquals(Reason.GLOBAL_PREFERENCE, d.reason)
    }

    @Test fun globalTrue_prefersExplicit_whenPrimaryIsClean() {
        val d = EditionPolicy.decide(song(explicit = false, exp = "300"), false, true)
        assertEquals(SongVariant.EXPLICIT, d.edition); assertEquals("300", d.catalogId)
    }

    @Test fun globalTrue_primaryAlreadyExplicit_unchanged() =
        assertEquals(EditionPolicy.Decision.UNCHANGED, EditionPolicy.decide(song(), false, true))

    @Test fun cleanOnly_beatsGlobalExplicit() {
        val d = EditionPolicy.decide(song(clean = "200"), true, true)
        assertEquals(SongVariant.CLEAN, d.edition); assertEquals(Reason.COLLECTION_CLEAN_ONLY, d.reason)
        assertFalse(d.allowsStoredFallback)
    }

    @Test fun cleanOnly_nonExplicit_passesUnchanged() =
        assertEquals(EditionPolicy.Decision.UNCHANGED, EditionPolicy.decide(song(explicit = null), true, true))

    @Test fun cleanOnly_unresolvedClean_edition_noId() {
        val d = EditionPolicy.decide(song(), true, null)
        assertEquals(SongVariant.CLEAN, d.edition); assertNull(d.catalogId)
    }

    @Test fun global_unresolvedEdition_unchanged() =
        assertEquals(EditionPolicy.Decision.UNCHANGED, EditionPolicy.decide(song(), false, false))

    @Test fun storageIds_order_andClean_only() {
        assertEquals(listOf(base), EditionPolicy.storageIds(base, null, true))
        assertEquals(listOf("${base}_explicit", base, "${base}_clean"), EditionPolicy.storageIds(base, SongVariant.EXPLICIT, true))
        assertEquals(listOf("${base}_clean"), EditionPolicy.storageIds(base, SongVariant.CLEAN, false))
    }

    @Test fun resolveStored_fallbackAndWanted() {
        val d = EditionPolicy.decide(song(clean = "200"), false, false)
        assertEquals(EditionPolicy.Stored("${base}_clean", true), EditionPolicy.resolveStored(base, d) { it == "${base}_clean" })
        assertEquals(EditionPolicy.Stored(base, false), EditionPolicy.resolveStored(base, d) { it == base })
        val co = EditionPolicy.decide(song(clean = "200"), true, null)
        assertNull(EditionPolicy.resolveStored(base, co) { it == base })
    }

    @Test fun lazyRip_gate() {
        val d = EditionPolicy.decide(song(clean = "200"), false, false)
        assertEquals("${base}_clean", EditionPolicy.lazyRipId(base, d) { false })
        assertNull(EditionPolicy.lazyRipId(base, d) { it == "${base}_clean" })
        assertNull(EditionPolicy.lazyRipId(base, EditionPolicy.Decision.UNCHANGED) { false })
        assertNull(EditionPolicy.lazyRipId(base, EditionPolicy.decide(song(), true, null)) { false })
    }

    @Test fun cleanOnly_resolve_dropsAndSubstitutes() {
        val ok = song(clean = "200", id = "sng_aaaaaaaaaaaa")
        val bad = song(id = "sng_bbbbbbbbbbbb")
        val plain = song(explicit = false, id = "sng_cccccccccccc")
        val map = listOf(ok, bad, plain).associateBy { it.id }
        val ids = listOf(ok.id, bad.id, plain.id, "smp_x")
        val r = CleanOnly.resolve(ids, map)
        assertEquals(listOf(ok.id, plain.id, "smp_x"), r.ids)
        assertEquals(mapOf(ok.id to SongVariant.CLEAN), r.variants)
        assertEquals(listOf("sng_aaaaaaaaaaaa_clean", plain.id, "smp_x"), CleanOnly.ripIds(ids, map))
        assertTrue(CleanOnly.isSkipped(bad)); assertFalse(CleanOnly.isSkipped(ok)); assertFalse(CleanOnly.isSkipped(null))
    }

    @Test fun songVariant_parse() {
        assertEquals(SongVariant.Parsed("sng_0123456789ab", SongVariant.CLEAN), SongVariant.parse("sng_0123456789ab_clean"))
        assertNull(SongVariant.parse("sng_0123456789AB_clean"))
        assertNull(SongVariant.parse("amrec_1_clean"))
        assertEquals("plain", SongVariant.baseId("plain"))
    }

    @Test fun settings_triState_roundTrip() {
        assertNull(EditionSettings.decode("")); assertEquals(true, EditionSettings.decode("true"))
        assertEquals(false, EditionSettings.decode(EditionSettings.encode(false))); assertEquals("", EditionSettings.encode(null))
    }
}
