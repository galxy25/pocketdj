package com.levi.pocketdj.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Single audio layer invariant: only `audio/core` (and the lower-level `audio/dsp`) may create an AudioTrack, a
 * MediaCodec audio DECODER or an OfflineRenderer. Everything else (Mix, Studio, Producer, Demux) goes through
 * AudioSink / AudioDecoder / OfflineRenderer as consumers. Encoders (AAC export) and AudioRecord (mic) are not
 * playback/decode layers and stay allowed.
 */
class SingleAudioLayerGuardTest {
    private val root: File = listOf("src/main/java/com/levi/pocketdj", "app/src/main/java/com/levi/pocketdj")
        .map { File(it) }.first { it.isDirectory }

    private fun sources(): List<File> = root.walkTopDown().filter { it.extension == "kt" }.toList()

    private fun isCore(f: File): Boolean {
        val rel = f.relativeTo(root).invariantSeparatorsPath
        return rel.startsWith("audio/core/") || rel.startsWith("audio/dsp/")
    }

    /** Strip line + block comments and string literals so docs that MENTION a forbidden call don't trip the guard. */
    internal fun code(text: String): String =
        text.replace(Regex("/\\*[\\s\\S]*?\\*/"), " ")
            .lines().joinToString("\n") { it.replace(Regex("//.*$"), "") }
            .replace(Regex("\"[^\"\\\\\n]*+(?:\\\\.[^\"\\\\\n]*+)*+\""), "\"\"")

    internal val forbidden: List<Pair<String, Regex>> = listOf(
        "AudioTrack constructor" to Regex("""(?<![\w.])(android\.media\.)?AudioTrack\s*\("""),
        "AudioTrack.Builder" to Regex("""\bAudioTrack\.Builder\b"""),
        "MediaCodec decoder" to Regex("""MediaCodec\.(createDecoderByType|createByCodecName)\b"""),
        "OfflineRenderer" to Regex("""(?<![\w.])OfflineRenderer\s*\("""),
    )

    private fun imports(text: String, fqn: String) = text.contains("import $fqn") || text.contains(fqn + "(")

    @Test fun noClassOutsideAudioCoreCreatesAnAudioLayer() {
        val offenders = ArrayList<String>()
        for (f in sources()) {
            if (isCore(f)) continue
            val c = code(f.readText())
            val usesAndroidTrack = imports(f.readText(), "android.media.AudioTrack") || f.readText().contains("import android.media.*") || c.contains("android.media.AudioTrack")
            for ((name, re) in forbidden) {
                if (name.startsWith("AudioTrack") && !usesAndroidTrack) continue // e.g. the catalog's own AudioTrack data class
                if (name == "MediaCodec decoder" && !c.contains("MediaCodec")) continue
                if (re.containsMatchIn(c)) offenders.add("${f.relativeTo(root)}: $name")
            }
        }
        assertEquals("audio-layer creation outside audio/core: $offenders", emptyList<String>(), offenders)
    }

    /** Existing non-core MediaPlayer sites (Studio/Demux/Mix playback chrome); a NEW one must be reviewed + added here. */
    private val mediaPlayerAllowlist = setOf(
        "studio/demux/StemPlayer.kt", "mix/recording/RecordingPlayer.kt", "screens/producer/tracks/ArtifactsSection.kt",
    )

    @Test fun mediaPlayerOnlyAtAllowlistedSitesAndEachIsGated() {
        val sites = sources().filter { !isCore(it) && Regex("""(?<![\w.])(android\.media\.)?MediaPlayer\s*\(""").containsMatchIn(code(it.readText())) }
            .map { it.relativeTo(root).invariantSeparatorsPath }.toSet()
        assertEquals("new MediaPlayer() site outside the allowlist: ${sites - mediaPlayerAllowlist}", emptySet<String>(), sites - mediaPlayerAllowlist)
        // The Studio sites must consult the mic gate (RecordingPlayer is the Mix recording review, not a Studio engine).
        for (rel in listOf("studio/demux/StemPlayer.kt", "screens/producer/tracks/ArtifactsSection.kt")) {
            assertTrue("$rel must call AudioFocusPolicy.gateStart", File(root, rel).readText().contains("gateStart(\"demux\")") || File(root, rel).readText().contains("gateStart(\"artifact\")"))
        }
    }

    @Test fun guardActuallyDetectsEachForbiddenForm() {
        val bad = mapOf(
            "AudioTrack constructor" to "val t = AudioTrack(attrs, fmt, 4096, 1, 0)",
            "AudioTrack.Builder" to "val t = AudioTrack.Builder().build()",
            "MediaCodec decoder" to "val c = MediaCodec.createDecoderByType(\"audio/mpeg\")",
            "OfflineRenderer" to "val r = OfflineRenderer(graph)",
        )
        for ((name, src) in bad) {
            val re = forbidden.first { it.first == name }.second
            assertTrue("$name should match", re.containsMatchIn(code(src)))
        }
    }

    @Test fun guardIgnoresCommentsStringsAndEncoders() {
        val ok = """
            // AudioTrack(…) is created in audio/core
            /* OfflineRenderer(x) */
            val s = "MediaCodec.createDecoderByType"
            val e = MediaCodec.createEncoderByType("audio/mp4a-latm")
            val r = AudioRecord(src, 44100, 16, 2, 4096)
            val x = renderer.OfflineRenderer
        """.trimIndent()
        forbidden.forEach { (n, re) -> assertTrue("$n must not match", !re.containsMatchIn(code(ok))) }
    }

    @Test fun coreIsWhereTheLayerLives() {
        assertTrue(sources().any { isCore(it) && forbidden.any { (_, re) -> re.containsMatchIn(code(it.readText())) } })
    }
}
