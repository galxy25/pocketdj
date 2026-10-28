package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.recs.RecRecordingIdentity.Candidate
import com.levi.pocketdj.data.recs.RecRecordingIdentity.Identity
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecIdentityTest {

    private fun cases(): List<Map<String, String>> {
        val text = javaClass.classLoader!!.getResourceAsStream("recs/version-identity-cases.json")!!
            .readBytes().toString(Charsets.UTF_8)
        return (Json.parseToJsonElement(text) as JsonArray).map { e ->
            e.jsonObject.mapValues { it.value.jsonPrimitive.content }
        }
    }

    @Test fun titleParseFixture() {
        val all = cases()
        assertTrue(all.size >= 30)
        for (c in all) {
            val p = RecVersionIdentity.parse(c.getValue("title"))
            assertEquals("base of ${c["title"]}", c["base"], p.base)
            assertEquals("signature of ${c["title"]}", c["signature"], p.signature)
            assertEquals("class of ${c["title"]}", c["klass"], p.klass.name)
        }
    }

    private fun diff(ct: String, ot: String, ca: String = "Fleetwood Mac", oa: String = "Fleetwood Mac") =
        RecVersionIdentity.isDifferentVersion(ct, ca, ot, oa)

    @Test fun deluxeBonusRemixExtendedAreSuppressed() {
        assertTrue(diff("Rumours (Deluxe Edition)", "Rumours"))
        assertTrue(diff("Rumours", "Rumours (Deluxe Edition)"))
        assertTrue(diff("Song (Extended Mix)", "Song"))
        assertTrue(diff("Song - Radio Edit", "Song"))
        assertTrue(diff("Song (Bonus Track Version)", "Song"))
    }

    @Test fun liveAcousticInstrumentalFailOpen() {
        assertFalse(diff("Song (Live)", "Song"))
        assertFalse(diff("Song", "Song (Live)"))
        assertFalse(diff("Song (Acoustic)", "Song"))
        assertFalse(diff("Song (Instrumental)", "Song"))
        assertFalse(diff("Song (Taylor's Version)", "Song"))
    }

    @Test fun neverOnArtistAndTitleAlone() {
        assertFalse(diff("Intro", "Intro"))
        assertFalse(diff("Song (Deluxe Edition)", "Song (Deluxe Edition)"))
        // different artist (remixer's own record) stays
        assertFalse(diff("Song (Remix)", "Song", ca = "Remixer", oa = "Original"))
    }

    @Test fun discsOfASetAreNotEditions() {
        assertFalse(diff("Ultimate Aaliyah [Disc 2]", "Ultimate Aaliyah [Disc 1]", "Aaliyah", "Aaliyah"))
    }

    @Test fun artistKeyFoldsCreditsAndArticle() {
        assertEquals("sade", RecVersionIdentity.artistKey("Sade (feat. Sweetback)"))
        assertEquals("beatles", RecVersionIdentity.artistKey("The Beatles"))
        assertEquals("beyonce", RecVersionIdentity.artistKey("Beyoncé"))
        assertEquals("simon and garfunkel", RecVersionIdentity.artistKey("Simon & Garfunkel"))
        assertEquals("", RecVersionIdentity.artistKey("[IVY]"))
        assertEquals("ivy", RecVersionIdentity.ownershipArtistKey("[IVY]"))
    }

    @Test fun creditArtistKeysSplitsCollaborations() {
        val keys = RecVersionIdentity.creditArtistKeys("Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington")
        assertTrue("dinner party" in keys)
        assertTrue("terrace martin" in keys)
        assertTrue("kamasi washington" in keys)
        assertTrue("9th wonder" in keys)
        assertEquals(1, RecVersionIdentity.creditArtistKeys("Sade").size)
        assertTrue("ivy" in RecVersionIdentity.creditArtistKeys("[IVY] & XIRA"))
    }

    @Test fun versionIndexOwnership() {
        val owned = listOfNotNull(
            RecVersionIdentity.key("Popstar", "Tinashe"),
            RecVersionIdentity.key("Rumours (Live)", "Fleetwood Mac"),
        )
        val idx = RecVersionIndex(owned)
        assertTrue(idx.hasRecord("Pop Star", "Tinashe"))
        assertTrue(idx.hasRecord("Popstar (Deluxe)", "Tinashe"))
        assertFalse(idx.supersedes("Rumours", "Fleetwood Mac"))   // owning a live cut suppresses nothing
        assertTrue(idx.hasRecord("Rumours (Live)", "Fleetwood Mac"))
        assertFalse(idx.hasRecord("Rumours", "Fleetwood Mac"))
        assertTrue(idx.supersedes("Popstar (Remix)", "Tinashe"))
        assertFalse(RecVersionIndex(owned.takeLast(1)).supersedes("Rumours", "Fleetwood Mac"))
        assertTrue(RecVersionIndex(owned.takeLast(1)).isEmpty)
    }

    // ── membership ──

    @Test fun validStoreKeyRejectsNonNumeric() {
        assertEquals("am:12345", RecMembership.validStoreKey("12345"))
        assertNull(RecMembership.validStoreKey("12a45"))
        assertNull(RecMembership.validStoreKey("0000"))
        assertNull(RecMembership.validStoreKey("123"))
        assertNull(RecMembership.validStoreKey(""))
        assertEquals("999999", RecMembership.adHocStoreId("amrec_999999"))
        assertNull(RecMembership.adHocStoreId("amrec_9x"))
        assertNull(RecMembership.adHocStoreId("sng_abc"))
    }

    @Test fun membershipMatchesVariantsAndStoreIds() {
        val base = "sng_0123456789ab"
        val m = RecMembership(
            listOf(base, "amrec_55555"),
            appleMusicId = { if (it == base) "777777" else null },
        )
        assertTrue(m.contains(base))
        assertTrue(m.contains(base + "_clean"))
        assertTrue(m.contains(base + "_explicit"))
        assertTrue(m.contains("sng_other00000a", appleMusicId = "777777"))
        assertTrue(m.contains("sng_other00000b", appleMusicId = "55555"))
        assertTrue(m.contains("amrec_777777"))
        assertFalse(m.contains("sng_other00000c", appleMusicId = "888888"))
        assertFalse(m.contains("sng_other00000d", appleMusicId = "not-a-number"))
    }

    @Test fun membershipExcludingUsesRecordingAndVersion() {
        val titles = mapOf(
            "sng_aaaaaaaaaaaa" to RecMembership.TitleArtist("Rumours", "Fleetwood Mac"),
            "sng_bbbbbbbbbbbb" to RecMembership.TitleArtist("Rumours", "Fleetwood Mac"),     // same recording, other id
            "sng_cccccccccccc" to RecMembership.TitleArtist("Rumours (Deluxe Edition)", "Fleetwood Mac"),
            "sng_dddddddddddd" to RecMembership.TitleArtist("Rumours (Live)", "Fleetwood Mac"),
            "sng_eeeeeeeeeeee" to RecMembership.TitleArtist("Dreams", "Fleetwood Mac"),
        )
        val m = RecMembership(listOf("sng_aaaaaaaaaaaa"), titleArtist = { titles[it] })
        val kept = m.excluding(titles.keys.toList(), titleArtist = { titles[it] })
        assertEquals(listOf("sng_dddddddddddd", "sng_eeeeeeeeeeee"), kept)
        assertTrue(RecMembership.EMPTY.excluding(listOf("x")).single() == "x")
    }

    // ── recording collapse ──

    private fun rec(id: String, title: String, len: Int?, am: String? = null, score: Double = 0.0, playable: Boolean = false) =
        Candidate(
            id,
            RecRecordingIdentity.identity(id, am, RecVersionIdentity.key(title, "Artist"), len),
            score = score, playable = playable,
        )

    @Test fun collapseRequiresDurationCorroboration() {
        val a = rec("sng_aaaaaaaaaaaa", "Song", 200_000, score = 1.0)
        val b = rec("sng_bbbbbbbbbbbb", "Song (Remastered)", 202_000, score = 2.0)
        assertEquals(listOf(false, true), RecRecordingIdentity.keepMask(listOf(a, b)))
        // contradicting lengths are different recordings
        val c = rec("sng_cccccccccccc", "Song", 260_000)
        assertEquals(listOf(true, true), RecRecordingIdentity.keepMask(listOf(a, c)))
        // unknown length corroborates by title alone
        val d = rec("sng_dddddddddddd", "Song", null)
        assertEquals(listOf(true, false), RecRecordingIdentity.keepMask(listOf(a.copy(), d)))
    }

    @Test fun collapseKeepsDerivativeAndLiveApart() {
        val a = rec("sng_aaaaaaaaaaaa", "Song", 200_000)
        val b = rec("sng_bbbbbbbbbbbb", "Song (Extended Mix)", 200_000)
        val c = rec("sng_cccccccccccc", "Song (Live)", 200_000)
        assertEquals(listOf(true, true, true), RecRecordingIdentity.keepMask(listOf(a, b, c)))
    }

    @Test fun collapseByIdVariantAndStoreId() {
        val a = rec("sng_aaaaaaaaaaaa", "Song", null)
        val b = rec("sng_aaaaaaaaaaaa_clean", "Other Title", null)
        assertEquals(1, RecRecordingIdentity.keepMask(listOf(a, b)).count { it })
        // store id: amrec_ ad-hoc row meets a library row resolving to the same id
        val e = rec("amrec_424242", "Zed", 100_000)
        val f = rec("sng_ffffffffffff", "Yankee", 100_500, am = "424242", playable = true)
        assertEquals(listOf(false, true), RecRecordingIdentity.keepMask(listOf(e, f)))
        // ...but not when durations contradict
        val g = rec("sng_gggggggggggg", "Yankee", 190_000, am = "424242")
        assertEquals(listOf(true, true), RecRecordingIdentity.keepMask(listOf(e, g)))
    }

    @Test fun identityDedupesAdHocAndResolvedKey() {
        val id: Identity = RecRecordingIdentity.identity("amrec_123456", "123456")
        assertEquals("am:123456", id.adHocStoreKey)
        assertNull(id.resolvedStoreKey)
        assertEquals(listOf("amrec_123456", "am:123456"), RecRecordingIdentity.identityKeys("amrec_123456", "123456"))
        assertTrue(RecRecordingIdentity.resolvesToStreamableAudio("123456"))
        assertFalse(RecRecordingIdentity.resolvesToStreamableAudio("12"))
    }
}
