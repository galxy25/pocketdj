package com.levi.pocketdj.studio

import android.content.Context
import com.levi.pocketdj.studio.demux.DemuxStore
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioStore
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.PI
import kotlin.math.sin

/**
 * Debug-only emulator fixtures (iOS PDJ_SEED_STUDIO / PDJ_SEED_DEMUX launch args -> Android intent extras):
 *
 *     adb shell am start -n com.levi.pocketdj/.MainActivity --ez PDJ_SEED_STUDIO true --ez PDJ_SEED_DEMUX true
 *
 * Both are idempotent (fixed ids / a name check) so a relaunch never duplicates rows. They are gated on
 * FLAG_DEBUGGABLE by the caller via [requested]; a release build never seeds.
 */
object StudioSeed {
    const val STUDIO_EXTRA = "PDJ_SEED_STUDIO"
    const val DEMUX_EXTRA = "PDJ_SEED_DEMUX"

    /** Bundled 1 s 440 Hz AAC fixture (app/src/main/assets). */
    const val FIXTURE_ASSET = "studio-fixture-tone.m4a"
    const val DEMUX_NAME = "Seed Tone.m4a"

    const val SAMPLE_ID = "smp_seed0000-0000-0000-0000-000000000001"
    const val LOOP_ID = "lp_seed0000-0000-0000-0000-000000000001"
    const val PATTERN_ID = "ptn_seed0000-0000-0000-0000-000000000001"

    data class Request(val studio: Boolean, val demux: Boolean)

    /** Pure gate: nothing seeds in a non-debuggable build, whatever the intent says. */
    fun requested(debuggable: Boolean, studioFlag: Boolean, demuxFlag: Boolean): Request =
        if (!debuggable) Request(false, false) else Request(studioFlag, demuxFlag)

    /**
     * One 1 s tone sample + one loop (real files in the app roots), a pattern, and two cues. Emulator
     * steps: relaunch -> rows persist; delete a tone file -> relaunch -> record pruned; revoke the SAF
     * root -> relaunch -> nothing pruned.
     */
    fun seedStudio(store: StudioStore, context: Context) {
        val sName = StudioFolders.fileName(StudioFamily.SAMPLES, SAMPLE_ID)
        val lName = StudioFolders.fileName(StudioFamily.LOOPS, LOOP_ID)
        writeTone(File(File(context.filesDir, "studio/samples").also { it.mkdirs() }, sName))
        writeTone(File(File(context.filesDir, "studio/loops").also { it.mkdirs() }, lName))
        val t = System.currentTimeMillis().toDouble()
        store.addSample(
            StudioSample(SAMPLE_ID, "Seed Tone", sName, createdAt = t, durationMs = 1000, source = StudioSource.Mic, grid = StudioGrid(120.0)),
        )
        store.addLoop(StudioLoop(LOOP_ID, "Seed Loop", SAMPLE_ID, bpm = 120.0, lengthMs = 1000, frames = 44100, fileName = lName, createdAt = t))
        store.addPattern(
            StudioPattern.of(
                PATTERN_ID, "Seed Pattern",
                rows = listOf(StudioPatternRow.of(SAMPLE_ID, steps = List(16) { it % 4 == 0 })), createdAt = t,
            ),
        )
        store.setCue("sng_1", 0, 1000, "Seed A")
        store.setCue("sng_1", 1, 2000, "Seed B")
        store.flush()
    }

    /** Imports the bundled m4a as a Demuxer source (once). Returns the source key, or null if skipped/failed. */
    fun seedDemux(store: DemuxStore, context: Context): String? {
        if (store.importedSources().any { it.second == DEMUX_NAME.substringBeforeLast('.') }) return null
        return context.assets.open(FIXTURE_ASSET).use { store.importStream(DEMUX_NAME, it) }?.id
    }

    /** 1 s 440 Hz mono 16-bit PCM WAV bytes (the seed's stand-in audio; content-sniffed by the decoder). */
    fun toneWav(rate: Int = 44100): ByteArray {
        val n = rate
        val out = java.io.ByteArrayOutputStream(44 + n * 2)
        fun le32(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte()))
        fun le16(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte()))
        out.write("RIFF".toByteArray()); le32(36 + n * 2); out.write("WAVEfmt ".toByteArray())
        le32(16); le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
        out.write("data".toByteArray()); le32(n * 2)
        for (i in 0 until n) {
            val v = (sin(2 * PI * 440.0 * i / rate) * 0.3 * Short.MAX_VALUE).toInt()
            le16(v)
        }
        return out.toByteArray()
    }

    private fun writeTone(f: File) {
        RandomAccessFile(f, "rw").use { raf -> raf.setLength(0); raf.write(toneWav()) }
    }
}
