package com.levi.pocketdj.data.rips

class PlayResolverEditionTest {
    private val base = "sng_0123456789ab"
    private val song = com.levi.pocketdj.data.catalog.IndexSong(
        id = base, artist = "a", name = "n", explicit = true, appleMusicId = "1", appleMusicIdClean = "2",
    )
    private fun entry(key: String) = RipManifestEntry(key = key)

    @org.junit.Test fun cleanOnly_nothingStored_ripsCleanVariant() {
        val r = PlayResolver.resolveForEdition(base, song, true, null, { null }, true)
        org.junit.Assert.assertEquals("${base}_clean", r.playId)
        org.junit.Assert.assertEquals(PlayAction.RipRequired("${base}_clean"), r.action)
        org.junit.Assert.assertNull(r.lazyRipId)
    }

    @org.junit.Test fun globalExplicit_nothingStored_ripsExplicitVariantNotPrimary() {
        val s = song.copy(explicit = false, appleMusicId = "1", appleMusicIdExplicit = "3", appleMusicIdClean = null)
        val r = PlayResolver.resolveForEdition(base, s, false, true, { null }, true)
        org.junit.Assert.assertEquals("${base}_explicit", r.playId)
        org.junit.Assert.assertEquals(PlayAction.RipRequired("${base}_explicit"), r.action)
        org.junit.Assert.assertNull(r.lazyRipId)
    }

    @org.junit.Test fun variantIdPassedIn_unchangedPathUsesBase() {
        val r = PlayResolver.resolveForEdition("${base}_clean", song, false, null, { null }, true)
        org.junit.Assert.assertEquals(PlayAction.RipRequired(base), r.action)
        org.junit.Assert.assertEquals(base, r.playId)
    }

    @org.junit.Test fun cleanOnly_noCleanId_skipped() {
        val r = PlayResolver.resolveForEdition(base, song.copy(appleMusicIdClean = null), true, null, { null }, true)
        org.junit.Assert.assertTrue(r.skipped)
    }

    @org.junit.Test fun globalClean_fallsBackToLegacy_andLazyRips() {
        val r = PlayResolver.resolveForEdition(base, song, false, false, { if (it == base) entry("k.mp3") else null }, true)
        org.junit.Assert.assertEquals(base, r.playId)
        org.junit.Assert.assertTrue(r.action is PlayAction.Stream)
        org.junit.Assert.assertEquals("${base}_clean", r.lazyRipId)
    }

    @org.junit.Test fun unset_unchanged() {
        val r = PlayResolver.resolveForEdition(base, song, false, null, { entry("k.mp3") }, true)
        org.junit.Assert.assertEquals(base, r.playId); org.junit.Assert.assertNull(r.lazyRipId)
    }
}
