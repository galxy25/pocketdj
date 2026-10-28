package com.levi.pocketdj.studio.model

import com.levi.pocketdj.data.PdjJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StudioModelsCodecTest {

    private fun fixtureText(): String =
        javaClass.getResourceAsStream("/studio/ios-studio-v1.json")!!.bufferedReader().readText()

    /** Canonical form: numbers compared as doubles (`120` == `120.0`), objects as key-sorted maps. */
    private fun norm(e: JsonElement): Any? = when (e) {
        is JsonNull -> null
        is JsonObject -> e.entries.sortedBy { it.key }.associate { it.key to norm(it.value) }
        is JsonArray -> e.map { norm(it) }
        is JsonPrimitive -> if (e.isString) e.content else (e.content.toDoubleOrNull() ?: e.content)
    }

    private fun parse(s: String) = PdjJson.lenient.parseToJsonElement(s)

    @Test fun iosFixtureRoundTripsWithZeroFieldLoss() {
        val text = fixtureText()
        val doc = StudioDocument.decode(text)!!
        assertEquals(norm(parse(text)), norm(parse(doc.encode())))
        // ...and the re-encoded doc decodes back to an equal model.
        assertEquals(doc, StudioDocument.decode(doc.encode()))
    }

    @Test fun fixtureDecodesEveryFamily() {
        val d = StudioDocument.decode(fixtureText())!!
        assertEquals(1, d.schemaVersion)
        assertEquals(5, d.samples.size)
        assertEquals(2, d.loops.size)
        assertEquals(2, d.patterns.size)
        assertEquals(1, d.takes.size)
        assertEquals(2, d.cues.size)
        assertEquals(2, d.slices.size)
        assertEquals(1, d.arrangements.size)
        assertEquals(1, d.arrangementFolders.size)
        assertEquals(1, d.arrangementArtifacts.size)
        assertEquals(mapOf("smp_aaaa1111-0000-4000-8000-000000000001" to "8A", "tk_bbbb" to "5B"), d.keys)

        val s = d.samples[0]
        assertEquals(StudioSource.Track("sng_42", 62000, 63820), s.source)
        assertEquals(124.5, s.grid!!.bpm, 0.0)
        assertEquals(listOf(230, 713, 1196, 1679), s.grid!!.beatsMs)
        assertEquals(1.5, s.edit.rate, 0.0)
        assertTrue(s.isRenderFresh)
        assertEquals("sfld_f1", s.folderId)
        assertEquals(LoopBeats.HALF, d.loops[0].beats)
        assertEquals(10630L, d.loops[0].frames)

        val t = d.takes[0]
        assertEquals(InstrumentKey.PIANO, t.instrument)
        assertEquals(Accidental.SHARP, t.events[1].accidental)
        assertEquals(2, t.staffCount)
        assertEquals(InstrumentKey.HARP, t.extraStaffs!![0].instrument)
        assertEquals(1500, t.extraStaffs!![0].scoreEvents[0].offMs)
        assertEquals(listOf(0, 1000), t.allScoreEvents.map { it.onMs })   // edited primary + edited staff, onset-sorted
    }

    @Test fun allFiveSourceCasesDiscriminateAndRoundTrip() {
        val cases = listOf(
            StudioSource.Track("sng_1", 5, 99), StudioSource.Mic, StudioSource.Take("tk_x"),
            StudioSource.File("a.wav"), StudioSource.LineIn("TX-6"), StudioSource.LineIn(null),
        )
        val types = listOf("track", "mic", "take", "file", "lineIn", "lineIn")
        cases.forEachIndexed { i, c ->
            val j = StudioSourceSerializer.encode(c)
            assertEquals(types[i], (j["type"] as JsonPrimitive).content)
            assertEquals(c, StudioSourceSerializer.decode(j))
        }
        // lineIn(null) omits inputName entirely (encodeIfPresent).
        assertFalse(StudioSourceSerializer.encode(StudioSource.LineIn(null)).containsKey("inputName"))
    }

    @Test fun unknownOrMalformedSourceDegradesToMic() {
        assertEquals(StudioSource.Mic, StudioSourceSerializer.decode(parse("""{"type":"holographic","x":1}""")))
        assertEquals(StudioSource.Mic, StudioSourceSerializer.decode(parse("""{"songId":"s"}""")))
        assertEquals(StudioSource.Mic, StudioSourceSerializer.decode(parse(""""track"""")))
        assertEquals(StudioSource.Mic, StudioSourceSerializer.decode(null))
        // A track with missing fields keeps the discriminator and defaults the rest.
        assertEquals(StudioSource.Track("", 0, 0), StudioSourceSerializer.decode(parse("""{"type":"track"}""")))
    }

    @Test fun lossyDropAtDocumentDepth() {
        val text = """{"schemaVersion":1,"samples":[
            {"id":"smp_ok","name":"ok","fileName":"a"}, "garbage", 7, null, [1,2],
            {"id":"smp_ok2","name":"ok2","fileName":"b"}],
            "loops":"not-an-array","cues":[{"id":"cue_1","songId":"s","slot":0,"positionMs":5}]}"""
        val d = StudioDocument.decode(text)!!
        assertEquals(listOf("smp_ok", "smp_ok2"), d.samples.map { it.id })   // per-element, not per-array
        assertTrue(d.loops.isEmpty())                                         // wrong container type => []
        assertEquals(1, d.cues.size)                                          // sibling lists untouched
    }

    @Test fun lossyDropAtPatternRowDepth() {
        val text = """{"patterns":[{"id":"ptn_1","name":"P","rows":[
            {"targetId":"smp_a","steps":[true]}, "bad", 12, {"targetId":"smp_b"}]},
            {"id":"ptn_2","name":"Q","rows":"nope"}]}"""
        val d = StudioDocument.decode(text)!!
        assertEquals(2, d.patterns.size)
        assertEquals(listOf("smp_a", "smp_b"), d.patterns[0].rows.map { it.targetId })
        assertTrue(d.patterns[1].rows.isEmpty())
    }

    @Test fun lossyDropAtTakeStaffEventDepth() {
        val text = """{"takes":[{"id":"tk_1","name":"T","fileName":"f","events":[
              {"onMs":1,"offMs":2,"note":60,"velocity":90}, "x", {"onMs":3,"offMs":4,"note":62,"velocity":80}],
            "extraStaffs":[ {"id":"stf_1","instrument":"violin","events":[{"onMs":0,"offMs":9,"note":70,"velocity":1}, null, 4]}, "junk" ]}]}"""
        val t = StudioDocument.decode(text)!!.takes.single()
        assertEquals(listOf(1, 3), t.events.map { it.onMs })
        val staffs = t.extraStaffs!!
        assertEquals(1, staffs.size)                       // "junk" staff dropped, not the list
        assertEquals(InstrumentKey.VIOLIN, staffs[0].instrument)
        assertEquals(1, staffs[0].events.size)             // null/4 events dropped, not the staff
    }

    @Test fun unknownFieldsIgnoredAndWrongTypesDefault() {
        val text = """{"futureTop":{"a":1},"samples":[{"id":"smp_1","name":5,"fileName":"f.m4a","durationMs":"long",
            "wasUserFolder":"yes","createdAt":"now","edit":"neutral","grid":[],"hologram":true,"renderedRevision":"x"}]}"""
        val s = StudioDocument.decode(text)!!.samples.single()
        assertEquals("", s.name)                // wrong type => default, element survives
        assertEquals("f.m4a", s.fileName)
        assertEquals(0, s.durationMs)
        assertFalse(s.wasUserFolder)
        assertEquals(0.0, s.createdAt, 0.0)
        assertEquals(StudioSampleEdit.NEUTRAL, s.edit)
        assertNull(s.grid)
        assertNull(s.renderedRevision)
    }

    @Test fun missingIdsAreMintedWithTheRightPrefix() {
        val d = StudioDocument.decode("""{"samples":[{}],"loops":[{}],"patterns":[{}],"takes":[{}],"cues":[{}],"slices":[{}],
            "folders":[{}],"loopFolders":[{}],"patternFolders":[{}],"takeFolders":[{}],"arrangements":[{}],"arrangementFolders":[{}],
            "arrangementArtifacts":[{}]}""")!!
        assertTrue(d.samples[0].id.startsWith("smp_"))
        assertTrue(d.loops[0].id.startsWith("lp_"))
        assertTrue(d.patterns[0].id.startsWith("ptn_"))
        assertTrue(d.takes[0].id.startsWith("tk_"))
        assertTrue(d.cues[0].id.startsWith("cue_"))
        assertTrue(d.slices[0].id.startsWith("slc_"))
        assertTrue(d.folders[0].id.startsWith("sfld_"))
        assertTrue(d.loopFolders[0].id.startsWith("lpfld_"))
        assertTrue(d.patternFolders[0].id.startsWith("ptnfld_"))
        assertTrue(d.takeFolders[0].id.startsWith("tkfld_"))
        assertTrue(d.arrangements[0].id.startsWith("arr_"))
        assertTrue(d.arrangementFolders[0].id.startsWith("arrfld_"))
        assertTrue(d.arrangementArtifacts[0].id.startsWith("art_"))
    }

    @Test fun nonObjectDocumentIsNullAndEmptyObjectIsDefaults() {
        assertNull(StudioDocument.decode("[1,2]"))
        assertNull(StudioDocument.decode("not json at all"))
        assertNull(StudioDocument.decode(""))
        val d = StudioDocument.decode("{}")!!
        assertEquals(0, d.schemaVersion)     // iOS: absent schemaVersion => 0
        assertTrue(d.samples.isEmpty() && d.keys.isEmpty())
    }

    @Test fun patternRowsNormalizeToAtLeast16AndNeverTruncateLongPatterns() {
        // Legacy 1-step row pads to 16.
        val short = StudioPatternRow.fromJson(parse("""{"targetId":"smp_a","steps":[true]}""") as JsonObject)
        assertEquals(16, short.steps.size)
        assertEquals(16, short.loopSteps.size)
        assertEquals(16, short.stepSpans.size)
        assertTrue(short.steps[0])

        // A 40-step row in a 40-step pattern keeps every step (SEQ4 data-loss guard).
        val steps = List(40) { it % 3 == 0 }
        val raw = """{"id":"ptn_l","name":"L","stepCount":40,"rows":[{"targetId":"smp_a","steps":${steps.joinToString(",", "[", "]")}}]}"""
        val p = StudioPattern.fromJson(parse(raw) as JsonObject)
        assertEquals(40, p.stepCount)
        assertEquals(steps, p.rows[0].steps)
        assertEquals(40, p.rows[0].loopSteps.size)

        // The row decode itself preserves >16 even when the pattern has no stepCount (then the
        // pattern's authoritative 16 resizes it — exactly the iOS behaviour).
        val noCount = StudioPattern.fromJson(parse(raw.replace("\"stepCount\":40,", "")) as JsonObject)
        assertEquals(16, noCount.stepCount)
        assertEquals(16, noCount.rows[0].steps.size)
        val rowOnly = StudioPatternRow.fromJson(parse("""{"targetId":"t","steps":${steps.joinToString(",", "[", "]")}}""") as JsonObject)
        assertEquals(40, rowOnly.steps.size)
    }

    @Test fun stepCountClampsAndSpansClamp() {
        assertEquals(1, StudioPattern.clampStepCount(0))
        assertEquals(1, StudioPattern.clampStepCount(-5))
        assertEquals(StudioPattern.MAX_STEP_COUNT, StudioPattern.clampStepCount(1_000_000))
        assertEquals(8192, StudioPattern.MAX_STEP_COUNT)
        val r = StudioPatternRow.of("t", steps = List(16) { true }, stepSpans = listOf(-3, 99, 4)).resized(16)
        assertEquals(listOf(0, 16, 4), r.stepSpans.take(3))
        assertEquals(StudioPattern.barMs(120.0) * 2, StudioPattern.of("ptn_x", "x", stepCount = 32).lengthMs)
        assertEquals(2000, StudioPattern.barMs(120.0))
        assertEquals(StudioPattern.barMs(120.0), StudioPattern.barMs(0.0))   // 0 bpm doc guarded
    }

    @Test fun sampleEditClampsAndEffectiveDuration() {
        val e = StudioSampleEdit(trimStartMs = -5, trimEndMs = 10, gainDb = 99.0, rate = 50.0, pitchSemitones = -40.0, reverbWet = 2.0, compWet = -1.0, filterAmt = 3.0).clamped()
        assertEquals(0, e.trimStartMs)
        assertEquals(12.0, e.gainDb, 0.0)
        assertEquals(10.0, e.rate, 0.0)
        assertEquals(-12.0, e.pitchSemitones, 0.0)
        assertEquals(1.0, e.reverbWet, 0.0)
        assertEquals(0.0, e.compWet, 0.0)
        assertEquals(1.0, e.filterAmt, 0.0)
        assertEquals(StudioSampleEdit(trimStartMs = 50, trimEndMs = 50), StudioSampleEdit(trimStartMs = 50, trimEndMs = 20).clamped())
        assertTrue(StudioSampleEdit.NEUTRAL.isNeutral)
        val s = StudioSample("smp_1", "s", "f", durationMs = 30_000, edit = StudioSampleEdit(trimStartMs = 1000, trimEndMs = 3000, rate = 2.0))
        assertEquals(1000, s.effectiveDurationMs)            // (3000-1000)/2
    }

    @Test fun legacyEditWithoutMixerDeckKeysDecodesFxOff() {
        val e = StudioSampleEdit.fromJson(parse("""{"trimStartMs":5,"gainDb":-3}"""))!!
        assertEquals(0.0, e.compWet, 0.0)
        assertEquals(0.0, e.filterAmt, 0.0)
        assertEquals(1.0, e.rate, 0.0)
    }

    @Test fun loopBeatsUnknownValueIsFourAndSixAreOk() {
        assertEquals(LoopBeats.FOUR, LoopBeats.fromBeatCount(3.0))
        assertEquals(LoopBeats.FOUR, LoopBeats.fromBeatCount(null))
        assertEquals(LoopBeats.THIRTY_TWO, LoopBeats.fromBeatCount(32.0))
        assertEquals("½", LoopBeats.HALF.label)
        assertEquals("16", LoopBeats.SIXTEEN.label)
        val l = StudioLoop.fromJson(parse("""{"id":"lp_1","name":"x","sampleId":"s","beats":7,"fileName":"f"}""") as JsonObject)
        assertEquals(LoopBeats.FOUR, l.beats)
    }

    @Test fun keysMapIsAllOrNothingLikeFoundation() {
        assertEquals(mapOf("a" to "1A"), StudioDocument.decode("""{"keys":{"a":"1A"}}""")!!.keys)
        assertTrue(StudioDocument.decode("""{"keys":{"a":"1A","b":5}}""")!!.keys.isEmpty())
    }

    @Test fun takeRenderFreshnessTreatsMissingRevisionAsZero() {
        val legacy = StudioTake("tk_1", "t", fileName = "f", renderedFileName = "r.m4a", renderRevision = 0, renderedRevision = null)
        assertTrue(legacy.isRenderFresh)
        assertFalse(legacy.copy(renderRevision = 1).isRenderFresh)
        assertFalse(legacy.copy(renderedFileName = null).isRenderFresh)
    }

    @Test fun cueMirrorDocIsLossyAndRoundTrips() {
        val doc = StudioCueDoc(cues = listOf(StudioCue("cue_1", "sng_1", 2, 1234, "Drop"), StudioCue("cue_2", "sng_1", 3, 9)))
        assertEquals(doc, StudioCueDoc.decode(doc.encode()))
        val lossy = StudioCueDoc.decode("""{"schemaVersion":1,"cues":[{"id":"cue_a","songId":"s","slot":1,"positionMs":2},"x",3]}""")!!
        assertEquals(1, lossy.cues.size)
        assertNull(StudioCueDoc.decode("nope"))
    }

    @Test fun studioIdFence() {
        listOf("smp_", "lp_", "ptn_", "tk_").forEach { assertTrue(StudioFactory.isStudioId(it + "abc")) }
        // Container-internal prefixes must NEVER be routable studio ids.
        listOf("cue_", "slc_", "sfld_", "lpfld_", "ptnfld_", "tkfld_", "stf_", "arr_", "trk_", "clip_", "arrfld_", "art_")
            .forEach { assertFalse(it, StudioFactory.isStudioId(it + "abc")) }
        assertFalse(StudioFactory.isStudioId("sng_1"))
        assertTrue(StudioFactory.newSampleId() != StudioFactory.newSampleId())
    }

    @Test fun clipStripAndMasterFxLenientDecode() {
        val strip = StudioChannelStrip.fromJson(parse("""{"pitchSemitones":99,"reverb":-1}"""))!!
        assertEquals(99.0, strip.pitchSemitones, 0.0)       // raw decode keeps; track decode clamps
        val t = StudioTrack.fromJson(parse("""{"id":"trk_1","name":"t","strip":{"pitchSemitones":99,"reverb":-1,"tempoRatio":0}}""") as JsonObject)
        assertEquals(12.0, t.strip.pitchSemitones, 0.0)
        assertEquals(0.0, t.strip.reverb, 0.0)
        assertEquals(0.1, t.strip.tempoRatio, 0.0)
        val fx = StudioMasterFX.fromJson(parse("""{"freezeEnabled":true}"""))!!
        assertFalse(fx.anyEffectEnabled)                      // stale freeze reads as dry
        assertEquals(StudioClipSource.RECORDING, StudioClip.fromJson(parse("""{"id":"c","source":"warp"}""") as JsonObject).source)
    }
}
