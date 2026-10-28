package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.location.ListeningContextLookup
import com.levi.pocketdj.data.location.ListeningContextProviding
import com.levi.pocketdj.data.location.ListeningPlaceLabel
import com.levi.pocketdj.data.location.ListeningTripLabel
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.ListeningPocketFeature
import com.levi.pocketdj.data.pockets.ListeningPocketNumeric
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ListeningPocketLabelerTest {
    private val results = ListeningPocketsResults.parse(
        """{"v":1,"generatedAtMs":5,"labels":{"places":[{"id":"pl1","rank":1,"label":"Home (cloud)"}],
            "trips":[{"id":"tr1","origin":"pl1","label":"Commute (cloud)"}]},
            "pockets":[{"id":"a","startMs":1,"features":[
              {"dim":"collection","value":"pkt_1","label":"x","share":0.5,"lift":2,"score":1},
              {"dim":"collection","value":"pkt_gone","label":"y","share":0.5,"lift":2,"score":1}]}],
            "patterns":[]}""",
    )!!

    private class Provider(val labels: Map<String, String>, override val isActive: Boolean = true) : ListeningContextProviding {
        override val isSupported = true
        override fun context(atMs: Double): ListeningContextLookup = ListeningContextLookup.Unavailable
        override fun placeLabels(): List<ListeningPlaceLabel> = emptyList()
        override fun tripLabels(): List<ListeningTripLabel> = emptyList()
        override fun label(tag: ListeningContextTag): String? = labels[tag.placeId ?: tag.tripId]
    }

    private fun feat(dim: String, value: String, label: String = value) =
        ListeningPocketFeature(dim, value, label, 0.4, null, 2.0, 1.0)

    @Test fun devicePrecedence() {
        val l = ListeningPocketLabeler(results, Provider(mapOf("pl1" to "Studio")))
        assertEquals("Studio", l.label(feat("place", "pl1", "Home")))
        // device authoritative: an id it pruned is "Earlier place" even if the cloud knows it
        assertEquals("Earlier place", l.label(feat("place", "pl1x")))
        assertEquals("Earlier place", ListeningPocketLabeler(results, Provider(emptyMap())).label(feat("place", "pl1")))
    }

    @Test fun cloudFallback() {
        val l = ListeningPocketLabeler(results, provider = null)
        assertEquals("Home (cloud)", l.label(feat("place", "pl1", "Home")))
        assertEquals("Commute (cloud)", l.label(feat("trip", "tr1")))
        // inactive provider behaves like none
        assertEquals("Home (cloud)", ListeningPocketLabeler(results, Provider(mapOf("pl1" to "X"), isActive = false)).label(feat("place", "pl1")))
        // not in the snapshot: the feature's own label
        assertEquals("Gym", l.label(feat("place", "plZ", "Gym")))
    }

    @Test fun earlierPlace() {
        val l = ListeningPocketLabeler(results, null)
        assertEquals("Earlier place", l.contextLabel(ListeningContextTag.place("nope")))
        // an empty feature label stays empty (iOS behaves the same)
        assertEquals("", ListeningPocketLabeler(null, null).label(feat("genre", "t", "").copy(label = "")))
    }

    @Test fun collectionNamesLocalOnly() {
        val names = ListeningPocketLabeler.collectionNames(
            results,
            pockets = listOf("pkt_1" to "Gym pocket", "pkt_other" to "Not mentioned"),
            playlists = listOf("pkt_1" to "Shadowed"),
            sources = listOf("pkt_1" to "Source", "src" to "Unreferenced"),
        )
        // only ids the results mention; playlists overwrite pockets, sources never override (iOS order)
        assertEquals(mapOf("pkt_1" to "Shadowed"), names)
        val l = ListeningPocketLabeler(results, null, names)
        assertEquals("Shadowed", l.label(feat("collection", "pkt_1", "server id")))
        assertEquals("Earlier collection", l.label(feat("collection", "pkt_gone")))
        assertTrue(ListeningPocketLabeler.collectionNames(null, emptyList(), emptyList(), emptyList()).isEmpty())
        val none = ListeningPocketsResults.parse("""{"v":1,"pockets":[],"patterns":[]}""")
        assertTrue(ListeningPocketLabeler.collectionNames(none, listOf("a" to "b"), emptyList(), emptyList()).isEmpty())
    }

    @Test fun chipsPutDefiningBpmFirstAndDedupe() {
        val bpm = ListeningPocketNumeric(120.0, 118.4, 124.6, 0.9, 0.3, null, true)
        val l = ListeningPocketLabeler(results, null)
        val chips = l.chips(listOf(feat("genre", "House"), feat("genre", "House"), feat("mood", "Happy"), feat("artist", "A"), feat("artist", "B")), mapOf("bpm" to bpm))
        assertEquals(listOf("118–125 BPM", "House", "Happy", "A"), chips)
        assertEquals("120 BPM", ListeningPocketLabeler.bpmText(bpm.copy(lo = 119.6, hi = 120.4)))
        assertEquals(listOf("House"), l.chips(listOf(feat("genre", "House")), mapOf("bpm" to bpm.copy(defining = false))))
    }

    @Test fun usLocalizedDatesAndClockPreference() {
        val oldDay = ListeningPocketLabeler.dayPattern; val old24 = ListeningPocketLabeler.is24Hour
        try {
            ListeningPocketLabeler.dayPattern = { _, skel -> if (skel == "EEEdMMM") "EEE, MMM d" else "MMM d" }
            val ms = java.time.Instant.parse("2026-10-10T14:40:00Z").toEpochMilli().toDouble()
            assertTrue(ListeningPocketLabeler.whenText(ms, -420, Locale.US, ZoneId.of("UTC")).startsWith("Sat, Oct 10 · 7:40"))
            assertEquals("last Oct 10", ListeningPocketLabeler.lastText(ms, ms + 10 * 86_400_000.0, Locale.US, ZoneId.of("UTC")))
            ListeningPocketLabeler.is24Hour = { true }
            assertEquals("Sat, Oct 10 · 07:40", ListeningPocketLabeler.whenText(ms, -420, Locale.US, ZoneId.of("UTC")))
        } finally { ListeningPocketLabeler.dayPattern = oldDay; ListeningPocketLabeler.is24Hour = old24 }
    }

    @Test fun corruptOffsetFallsBackToDeviceZone() {
        val ms = java.time.Instant.parse("2026-10-10T14:40:00Z").toEpochMilli().toDouble()
        assertEquals(null, ListeningPocketLabeler.zoneFor(25200))
        assertEquals(null, ListeningPocketLabeler.zoneFor(-1081))
        val s = ListeningPocketLabeler.whenText(ms, 25200, Locale.US, ZoneId.of("UTC"))
        assertTrue(s, s.contains("2:40"))
    }

    @Test fun answeredMigration() {
        val ps = com.levi.pocketdj.data.pockets.PocketsSettings
        assertTrue(ps.needsAnsweredMigration(answered = false, enabledStored = true))   // said "Not now" on COL-17
        assertEquals(false, ps.needsAnsweredMigration(answered = false, enabledStored = false))  // never asked
        assertEquals(false, ps.needsAnsweredMigration(answered = true, enabledStored = true))
    }

    @Test fun androidLedgerRowIsNotPlanned() {
        var d: java.io.File? = java.io.File("").absoluteFile
        var f: java.io.File? = null
        while (d != null && f == null) { f = java.io.File(d, "docs/ARCHITECTURE-ANDROID.md").takeIf { it.exists() }; d = d.parentFile }
        org.junit.Assume.assumeTrue(f != null)
        val row = f!!.readLines().first { it.startsWith("| COL-18 ") }
        assertTrue(row, "Planned" !in row && "PARTIAL" in row)
    }

    @Test fun whenTextUsesThePocketsOwnOffset() {
        // 2026-10-10 14:40 UTC = 07:40 at -07:00
        val ms = java.time.Instant.parse("2026-10-10T14:40:00Z").toEpochMilli().toDouble()
        val s = ListeningPocketLabeler.whenText(ms, -420, Locale.US, ZoneId.of("UTC"))
        assertTrue(s, s.startsWith("Sat, 10 Oct · 7:40"))
        val dev = ListeningPocketLabeler.whenText(ms, null, Locale.US, ZoneId.of("UTC"))
        assertTrue(dev, dev.contains("2:40"))
    }

    @Test fun lastTextWeekdayWithinAWeekElseDate() {
        val ms = java.time.Instant.parse("2026-10-06T12:00:00Z").toEpochMilli().toDouble()  // Tuesday
        val z = ZoneId.of("UTC")
        assertEquals("last Tue", ListeningPocketLabeler.lastText(ms, ms + 2 * 86_400_000.0, Locale.US, z))
        assertEquals("last 6 Oct", ListeningPocketLabeler.lastText(ms, ms + 10 * 86_400_000.0, Locale.US, z))
        assertEquals(null, ListeningPocketLabeler.lastText(null))
    }

    @Test fun detailTextMatchesIos() {
        val h = com.levi.pocketdj.data.pockets.ListeningPocketHarmonic(0.7, 0.4, 10, true)
        assertEquals("Keys flow: 70 % of changes go to a neighbouring key vs 40 % usually", PocketDetailText.harmonicLine(h))
        val l = ListeningPocketLabeler(results, null)
        assertEquals("House: 40 % of this pocket", PocketDetailText.featureLine(feat("genre", "House"), l))
        assertEquals("House: 40 % of this pocket vs 12 % of your listening",
            PocketDetailText.featureLine(feat("genre", "House").copy(baselineShare = 0.12), l))
        val e = ListeningPocketNumeric(0.7, 0.6, 0.8, 1.0, 0.2, null, true)
        assertEquals(listOf("High energy, much tighter than usual"), PocketDetailText.numericLines(mapOf("energy" to e)))
        assertEquals(emptyList<String>(), PocketDetailText.numericLines(mapOf("energy" to e.copy(defining = false))))
        assertEquals("a steady range", ListeningPocketLabeler.tightness(e.copy(dispersionRatio = null)))
    }
}
