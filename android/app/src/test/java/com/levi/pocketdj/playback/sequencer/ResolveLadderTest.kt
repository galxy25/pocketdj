package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.playback.PlaybackMode
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class ResolveLadderTest {
    private fun item(id: String) = QueueItem(id)

    private fun local(url: String = "file:///x.mp3") = LocalFileSource(LocalFile(url))

    private fun defaultRegistry(
        files: LocalFileResolver = LocalFileResolver.None,
        manifest: Map<String, RipManifestEntry> = emptyMap(),
        extra: List<RowSourceResolver> = emptyList(),
        ripConfigured: Boolean = false,
    ) = RowResolverRegistry(
        initial = listOf(LocalFileRowResolver(files), ManifestRowResolver { manifest[it] }) + extra,
        manifestHit = { manifest.containsKey(it) },
        ripServerConfigured = { ripConfigured },
    )

    private fun RowResolverRegistry.run(id: String, mode: PlaybackMode = PlaybackMode.CLOUD) =
        runBlocking { resolve(item(id), mode) }

    @Test
    fun defaultLadder_isLocalFileThenManifest_andNoPreviewRung() {
        assertEquals(listOf("local-file", "manifest"), defaultRegistry().ladder().map { it.id })
        assertTrue(defaultRegistry().ladder().none { it.rung == Rung.APPLE_MUSIC })
    }

    @Test
    fun burnedFileBeatsTheManifestRip() {
        val reg = defaultRegistry(
            files = LocalFileResolver { LocalFile("file:///b.mp3", 1_000, 61_000) },
            manifest = mapOf("a" to RipManifestEntry(key = "rips/a.mp3")),
        )
        val src = reg.run("a") as LocalFileSource
        assertEquals(1_000L, src.file.startMs)
        assertEquals("burned", src.backend)
    }

    @Test
    fun manifestHit_streamsWithAnalogClipWindow() {
        val reg = defaultRegistry(
            manifest = mapOf("a" to RipManifestEntry(key = "rips/alb.mp3", startMs = 90_000, durationMs = 200_000)),
        )
        val src = reg.run("a") as StreamSource
        assertEquals(90_000L, src.action.clipStartMs)
        assertEquals(290_000L, src.action.clipEndMs)
        assertEquals("rip", src.backend)
    }

    @Test
    fun noRung_isMetadataOnly_inCloudMode_notOnDevice_inDeviceMode() {
        val reg = defaultRegistry()
        assertEquals(UnplayableSource.Reason.METADATA_ONLY, (reg.run("a") as UnplayableSource).reason)
        assertEquals(UnplayableSource.Reason.NOT_ON_DEVICE, (reg.run("a", PlaybackMode.DEVICE) as UnplayableSource).reason)
    }

    @Test
    fun studioIds_neverResolveThroughTheDefaultLadder_evenWithAManifestEntry() {
        val reg = defaultRegistry(
            manifest = mapOf("smp_1" to RipManifestEntry(key = "rips/smp_1.mp3")),
            ripConfigured = true,
        )
        for (id in listOf("smp_1", "lp_2", "ptn_3", "tk_4")) {
            assertEquals(UnplayableSource.Reason.STUDIO_LOCAL, (reg.run(id) as UnplayableSource).reason)
        }
    }

    @Test
    fun registeredStudioRung_resolvesStudioIds_beforeTheManifestFence() {
        val studio = MapResolver("studio", Rung.STUDIO_LOCAL, mapOf("smp_1" to local("file:///studio/smp_1.wav")))
        val reg = defaultRegistry(extra = listOf(studio))
        assertEquals("file:///studio/smp_1.wav", (reg.run("smp_1") as LocalFileSource).file.url)
        assertEquals(listOf("local-file", "studio", "manifest"), reg.ladder().map { it.id })
    }

    @Test
    fun deviceMode_consultsOnlyLocalRungs() {
        val manifestOnly = defaultRegistry(manifest = mapOf("a" to RipManifestEntry(key = "rips/a.mp3")))
        assertTrue(manifestOnly.run("a", PlaybackMode.DEVICE) is UnplayableSource)
        val studio = MapResolver("studio", Rung.STUDIO_LOCAL, mapOf("smp_1" to local()))
        assertTrue(defaultRegistry(extra = listOf(studio)).run("smp_1", PlaybackMode.DEVICE) is LocalFileSource)
    }

    @Test
    fun ripStartsNow_isPassedToRungs_soAppleMusicCanDeferToAnInstantRip() {
        class AppleMusicRung : RowSourceResolver {
            override val id = "apple-music"
            override val rung = Rung.APPLE_MUSIC
            val seen = mutableListOf<Boolean>()
            override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? {
                seen += ctx.ripStartsNow
                return if (ctx.ripStartsNow) null else object : RowSource { override val backend = "appleMusic" }
            }
        }
        val am = AppleMusicRung()
        val reg = defaultRegistry(
            manifest = mapOf("ripped" to RipManifestEntry(key = "rips/ripped.mp3")),
            extra = listOf(am),
        )
        // Manifest hit: streams instantly; the AM rung (after the manifest) is never even asked.
        assertTrue(reg.run("ripped") is StreamSource)
        assertTrue(am.seen.isEmpty())
        // No rip: the AM rung runs, told the rip does not start now.
        assertEquals("appleMusic", reg.run("am-only").backend)
        assertEquals(listOf(false), am.seen)
        assertEquals(listOf("local-file", "manifest", "apple-music"), reg.ladder().map { it.id })
    }

    @Test
    fun aRungBeforeTheManifest_seesRipStartsNowTrue_whenAnInstantRipExists() {
        val probe = MapResolver("probe", Rung.LOCAL_FILE, emptyMap())
        val reg = defaultRegistry(
            manifest = mapOf("a" to RipManifestEntry(key = "rips/a.mp3")),
            extra = listOf(probe),
            ripConfigured = true,
        )
        reg.run("a"); reg.run("b")
        assertEquals(listOf(true, false), probe.seenContexts.map { it.ripStartsNow })
        assertTrue(probe.seenContexts.all { it.ripServerConfigured })
    }

    @Test
    fun ladderOrder_isByRung_thenRegistrationOrder() {
        val reg = RowResolverRegistry(
            listOf(
                MapResolver("rip", Rung.RIP_ON_DEMAND, emptyMap()),
                MapResolver("am", Rung.APPLE_MUSIC, emptyMap()),
                MapResolver("m1", Rung.MANIFEST, emptyMap()),
                MapResolver("m2", Rung.MANIFEST, emptyMap()),
                MapResolver("burn", Rung.LOCAL_FILE, emptyMap()),
            ),
        )
        assertEquals(listOf("burn", "m1", "m2", "am", "rip"), reg.ladder().map { it.id })
    }

    @Test
    fun aThrowingRung_passesTheRowDown_neverCrashesTheSet() {
        val boom = object : RowSourceResolver {
            override val id = "boom"
            override val rung = Rung.LOCAL_FILE
            override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? = error("burn store exploded")
        }
        val reg = defaultRegistry(
            manifest = mapOf("a" to RipManifestEntry(key = "rips/a.mp3")),
            extra = listOf(boom),
        )
        assertTrue(reg.run("a") is StreamSource)
    }

    @Test
    fun duplicateResolverId_failsFast() {
        val reg = defaultRegistry()
        assertThrows(IllegalArgumentException::class.java) {
            reg.register(MapResolver("manifest", Rung.MANIFEST, emptyMap()))
        }
    }

    @Test
    fun substitutedEditionRow_resolvesUnderItsStorageId() {
        val reg = defaultRegistry(manifest = mapOf("sng_1_clean" to RipManifestEntry(key = "rips/sng_1_clean.mp3")))
        val row = QueueItem(id = "sng_1", resolveId = "sng_1_clean", variant = "clean")
        assertTrue(runBlocking { reg.resolve(row, PlaybackMode.CLOUD) } is StreamSource)
        assertTrue(row.matches("sng_1") && row.matches("sng_1_clean") && !row.matches("sng_2"))
    }

    @Test
    fun editionDecider_unchangedIsInactiveAndIdentity() {
        val row = item("a")
        assertTrue(EditionDecider.Unchanged.decide(row, true) === row)
        assertEquals(false, EditionDecider.Unchanged.isActive())
    }
}
