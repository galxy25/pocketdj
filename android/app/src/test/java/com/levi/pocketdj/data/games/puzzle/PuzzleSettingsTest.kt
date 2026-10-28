package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.PdjJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PuzzleSettingsTest {
    private fun decode(s: String) = PuzzleSettings.fromJson(s)

    @Test fun lenientDefaultsMissingSimilarityIsOnAndMissingRecencyIsOff() {
        val s = decode(
            """{ "roundSeconds": 180, "playCountBias": "off", "favoriteBias": "off",
                 "genreCategories": [], "membershipMode": "off", "membershipCollectionIds": [],
                 "targetCollectionIds": ["pkt_a"] }""",
        )
        assertEquals(PuzzleSettings.Similarity.ON, s.similarity)
        assertEquals(PuzzleSettings.Bias.OFF, s.recencyBias)
        assertEquals(180, s.roundSeconds)
        assertEquals(listOf("pkt_a"), s.targetCollectionIds)
    }

    @Test fun oldBlobKeepsItsSummaryLineAndPlayCountMeaning() {
        val s = decode(
            """{ "roundSeconds": 120, "playCountBias": "favor", "favoriteBias": "off",
                 "genreCategories": [], "membershipMode": "off", "membershipCollectionIds": [],
                 "targetCollectionIds": [] }""",
        )
        assertEquals(PuzzleSettings.Bias.FAVOR, s.playCountBias)
        assertEquals("2:00 · most played · free file", s.summaryLine)
    }

    @Test fun emptyOrGarbageBlobsDecodeToDefaults() {
        assertEquals(PuzzleSettings(), decode("{}"))
        assertEquals(PuzzleSettings(), decode("not json"))
        assertEquals(PuzzleSettings(), decode("[1,2]"))
        assertEquals(PuzzleSettings(), PuzzleSettings.fromJson(null))
    }

    @Test fun wrongTypedFieldsFallBackIndividuallyWithoutLosingTheRest() {
        val s = decode(
            """{ "roundSeconds": "ninety", "favoriteBias": "favor", "yearMin": "x", "yearMax": 1999,
                 "playCountBias": "sideways", "genreCategories": "hip-hop",
                 "targetCollectionIds": ["a", 7] }""",
        )
        assertEquals(120, s.roundSeconds)
        assertEquals(PuzzleSettings.Bias.FAVOR, s.favoriteBias)
        assertEquals(null, s.yearMin)
        assertEquals(1999, s.yearMax)
        assertEquals(PuzzleSettings.Bias.OFF, s.playCountBias)
        assertTrue(s.genreCategories.isEmpty())
        assertTrue(s.targetCollectionIds.isEmpty())
    }

    @Test fun unknownKeysAreIgnoredAndNullsBecomeDefaults() {
        val s = decode("""{ "roundSeconds": 60, "futureKnob": {"a": 1}, "yearMin": null, "similarity": null }""")
        assertEquals(60, s.roundSeconds)
        assertEquals(null, s.yearMin)
        assertEquals(PuzzleSettings.Similarity.ON, s.similarity)
    }

    @Test fun roundTrip() {
        val s = PuzzleSettings(
            roundSeconds = 300, playCountBias = PuzzleSettings.Bias.AVOID,
            recencyBias = PuzzleSettings.Bias.FAVOR, favoriteBias = PuzzleSettings.Bias.FAVOR,
            genreCategories = setOf("hip-hop", "jazz"), yearMin = 1990, yearMax = 1999,
            membershipMode = PuzzleSettings.MembershipMode.NOT_IN_ANY,
            membershipCollectionIds = setOf("pls_a"),
            targetCollectionIds = listOf("pkt_x", "pls_b"),
            similarity = PuzzleSettings.Similarity.STRICT,
        )
        assertEquals(s, decode(s.toJson()))
    }

    @Test fun encodesIosWireTokens() {
        val s = PuzzleSettings(
            membershipMode = PuzzleSettings.MembershipMode.IN_ANY,
            playCountBias = PuzzleSettings.Bias.FAVOR, yearMin = 1990,
        )
        val o = PdjJson.lenient.parseToJsonElement(s.toJson()) as JsonObject
        assertEquals("inAny", (o["membershipMode"] as JsonPrimitive).content)
        assertEquals("favor", (o["playCountBias"] as JsonPrimitive).content)
        assertEquals("on", (o["similarity"] as JsonPrimitive).content)
        assertEquals("off", (o["recencyBias"] as JsonPrimitive).content)
        assertEquals(1990, (o["yearMin"] as JsonPrimitive).content.toInt())
        assertFalse("nil year bound is omitted, like Swift's Optional encode", o.containsKey("yearMax"))
        assertTrue(o["targetCollectionIds"] is JsonArray)
    }

    @Test fun summaryLineVariants() {
        val d = PuzzleSettings()
        assertEquals("2:00 · free file", d.summaryLine)
        assertFalse(d.summaryLine.contains("0 targets"))
        assertEquals("1:00", d.copy(roundSeconds = 60).roundLengthLabel)
        assertEquals("5:00", d.copy(roundSeconds = 300).roundLengthLabel)
        assertEquals("1:30", d.copy(roundSeconds = 90).roundLengthLabel)

        val one = d.copy(targetCollectionIds = listOf("pkt_a"))
        assertEquals("2:00 · 1 target", one.summaryLine)
        assertEquals("2:00 · 3 targets", d.copy(targetCollectionIds = listOf("a", "b", "c")).summaryLine)
        assertEquals("2:00 · 1 target · similar+", one.copy(similarity = PuzzleSettings.Similarity.STRICT).summaryLine)
        assertEquals("2:00 · 1 target · any", one.copy(similarity = PuzzleSettings.Similarity.OFF).summaryLine)
        // similarity is unsaid with no targets, whatever it is set to
        assertEquals("2:00 · free file", d.copy(similarity = PuzzleSettings.Similarity.STRICT).summaryLine)

        assertEquals("2:00 · ♥ favor · free file", d.copy(favoriteBias = PuzzleSettings.Bias.FAVOR).summaryLine)
        assertEquals("2:00 · ♥ avoid · free file", d.copy(favoriteBias = PuzzleSettings.Bias.AVOID).summaryLine)
        assertEquals("2:00 · least played · free file", d.copy(playCountBias = PuzzleSettings.Bias.AVOID).summaryLine)
        assertEquals("2:00 · recently played · free file", d.copy(recencyBias = PuzzleSettings.Bias.FAVOR).summaryLine)
        assertEquals(
            "2:00 · most played · not played lately · free file",
            d.copy(playCountBias = PuzzleSettings.Bias.FAVOR, recencyBias = PuzzleSettings.Bias.AVOID).summaryLine,
        )
    }

    @Test fun summaryYearAndMembershipClauses() {
        val d = PuzzleSettings()
        assertEquals("2:00 · 1990–1999 · free file", d.copy(yearMin = 1990, yearMax = 1999).summaryLine)
        assertEquals("2:00 · 1990+ · free file", d.copy(yearMin = 1990).summaryLine)
        assertEquals("2:00 · –1999 · free file", d.copy(yearMax = 1999).summaryLine)
        assertEquals(
            "2:00 · in 2 · free file",
            d.copy(membershipMode = PuzzleSettings.MembershipMode.IN_ANY, membershipCollectionIds = setOf("a", "b")).summaryLine,
        )
        assertEquals(
            "2:00 · not-in 1 · free file",
            d.copy(membershipMode = PuzzleSettings.MembershipMode.NOT_IN_ANY, membershipCollectionIds = setOf("a")).summaryLine,
        )
    }

    @Test fun summaryGenresFollowCanonicalGenreOrderNotAlphabetical() {
        // Genre.order: hip-hop < jazz < rock < pop < Other; alphabetical would put "jazz" first.
        val s = PuzzleSettings(genreCategories = setOf("rock", "jazz", "hip-hop", "Other"))
        assertEquals("2:00 · hip-hop+jazz+rock+Other · free file", s.summaryLine)
    }

    @Test fun fullSummaryMatchesTheDocumentedShape() {
        val s = PuzzleSettings(
            favoriteBias = PuzzleSettings.Bias.FAVOR, genreCategories = setOf("hip-hop"),
            yearMin = 1990, yearMax = 1999, targetCollectionIds = listOf("a", "b", "c"),
        )
        assertEquals("2:00 · ♥ favor · hip-hop · 1990–1999 · 3 targets", s.summaryLine)
    }

    @Test fun roundLengthLabelIsAsciiUnderArabicLocale() {
        val old = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale("ar", "EG"))
            assertEquals("2:00", PuzzleSettings().roundLengthLabel)
        } finally { java.util.Locale.setDefault(old) }
    }

    @Test fun integralFloatRoundSecondsDecodes() {
        val s = PdjJson.lenient.decodeFromString(PuzzleSettings.serializer(), """{"roundSeconds":180.0}""")
        assertEquals(180, s.roundSeconds)
    }
}
