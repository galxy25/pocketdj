package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.mix.nowplaying.NetworkClass
import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher
import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher.Track
import com.levi.pocketdj.mix.nowplaying.NpMixModeState
import com.levi.pocketdj.mix.nowplaying.StemLockState
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.health.PlaybackRipWindow
import com.levi.pocketdj.data.rips.PlayAction
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** P2-MM-9: the preferLocalAudio resolver ladder matrix, plus the rip-ahead gate. */
class PreferLocalAudioTest {
    private val item = QueueItem("sng_1")
    private val rip = StreamSource(PlayAction.Stream("https://rips/sng_1.mp3"))

    private class Marker(override val id: String, override val rung: Rung, val out: RowSource?, val ctxSeen: MutableList<ResolveContext>) : RowSourceResolver {
        override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? { ctxSeen += ctx; return out }
    }

    private fun registry(
        prefer: Boolean, sourced: Boolean = true, instant: Boolean = false, ripped: Boolean = true, canPlayAm: Boolean = true,
        seen: MutableList<ResolveContext> = mutableListOf(),
    ) = RowResolverRegistry(
        initial = listOf(
            Marker("manifest", Rung.MANIFEST, if (ripped) rip else null, seen),
            AppleMusicRowResolver(appleMusicIdFor = { "am1" }, canPlayFullTrack = { canPlayAm }),
            CloudRowResolver(),
        ),
        manifestHit = { ripped },
        ripServerConfigured = { true },
        preferLocalAudio = { prefer },
        isAppleMusicSourced = { sourced },
        localCopyInstant = { instant },
    )

    private suspend fun RowResolverRegistry.backend() = resolve(item, PlaybackMode.CLOUD).backend

    @Test fun mixModeOffKeepsTheOldLadder_ripFirst() = runTest {
        assertEquals("rip", registry(prefer = false, instant = false).backend())
    }

    @Test fun mixModeBuffering_instantLocalCopy_playsTheRip() = runTest {
        assertEquals("rip", registry(prefer = true, instant = true).backend())
    }

    @Test fun mixModeBuffering_slowPresign_keepsTheInstantAppleMusicStart() = runTest {
        // dead-air rule: never trade an instant AM start for a slow presign
        assertEquals("appleMusic", registry(prefer = true, instant = false).backend())
    }

    @Test fun slowPresignButAppleMusicCannotPlay_fallsBackToTheRip() = runTest {
        assertEquals("rip", registry(prefer = true, instant = false, canPlayAm = false).backend())
    }

    @Test fun notAppleMusicSourced_isNeverReordered() = runTest {
        assertEquals("rip", registry(prefer = true, sourced = false, instant = false).backend())
    }

    @Test fun unrippedAppleMusicRow_playsAppleMusic_asBefore() = runTest {
        assertEquals("appleMusic", registry(prefer = true, ripped = false).backend())
        assertEquals("appleMusic", registry(prefer = false, ripped = false).backend())
    }

    @Test fun theContextCarriesTheDecisionToTheRungs() = runTest {
        val seen = mutableListOf<ResolveContext>()
        registry(prefer = true, instant = false, seen = seen).resolve(item, PlaybackMode.CLOUD)
        assertTrue(seen.isEmpty()) // AM went first and won: the manifest rung was never walked
        registry(prefer = true, instant = true, seen = seen).resolve(item, PlaybackMode.CLOUD)
        val c = seen.single()
        assertTrue(c.preferLocalAudio); assertTrue(c.localCopyInstant); assertFalse(c.appleMusicFirst)
    }

    @Test fun amRungDefersToAnInstantCopyEvenWhenWalkedFirst() = runTest {
        val r = AppleMusicRowResolver({ "1" }, { true }, isAppleMusicSourced = { true })
        val ctx = ResolveContext(PlaybackMode.CLOUD, true, ripStartsNow = true, preferLocalAudio = true, localCopyInstant = true, appleMusicFirst = true)
        assertEquals(null, r.resolve(item, ctx))
        assertEquals(AppleMusicSource("1", "sng_1"), r.resolve(item, ctx.copy(localCopyInstant = false)))
    }

    @Test fun deviceModeStillWalksOnlyLocalRungs() = runTest {
        val s = registry(prefer = true, instant = false).resolve(item, PlaybackMode.DEVICE)
        assertTrue(s is UnplayableSource)
    }

    @Test fun pureDecisionTable() {
        fun f(p: Boolean, s: Boolean, r: Boolean, i: Boolean) = PreferLocalAudio.appleMusicFirst(PreferLocalAudio.Facts(p, s, r, i))
        assertTrue(f(true, true, true, false))
        assertFalse(f(false, true, true, false))
        assertFalse(f(true, false, true, false))
        assertFalse(f(true, true, false, false))
        assertFalse(f(true, true, true, true))
    }

    // ---- rip-ahead gate ------------------------------------------------------------------------------

    private fun t(id: String, src: Track.Source, local: Boolean = false) =
        Track(id, id, id, "a", songLocal = local, songFetchable = src == Track.Source.RIPPED, stemsLocal = emptySet(), stemsRemote = false, source = src)

    private fun input(rip: Boolean, mix: Boolean = true, upcoming: List<Track>, current: Track? = t("cur", Track.Source.APPLE_MUSIC_ONLY)) =
        NowPlayingPrefetcher.Input(
            current = current, upcoming = upcoming, stemLock = StemLockState(),
            mixMode = NpMixModeState(enabled = mix), network = NetworkClass.UNMETERED, window = 5, isRipServerConfigured = rip,
        )

    private val ups = listOf(
        t("a", Track.Source.APPLE_MUSIC_ONLY), t("b", Track.Source.RIPPED), t("c", Track.Source.APPLE_MUSIC_ONLY),
        t("d", Track.Source.APPLE_MUSIC_ONLY),
    )

    @Test fun ripAheadAsksForTheNextTwoAppleMusicOnlyRows_neverThePlayingOne() {
        val plan = NowPlayingPrefetcher.plan(input(rip = true, upcoming = ups))
        assertEquals(listOf("a", "c"), plan.rips)
    }

    @Test fun noRipServerConfigured_noRipAhead_rowsStayAppleMusicOnly() {
        assertEquals(emptyList<String>(), NowPlayingPrefetcher.plan(input(rip = false, upcoming = ups)).rips)
    }

    @Test fun mixModeOff_noRipAhead() {
        assertEquals(emptyList<String>(), NowPlayingPrefetcher.plan(input(rip = true, mix = false, upcoming = ups)).rips)
    }

    @Test fun aRowAlreadyLocalIsNotRippedAgain() {
        val plan = NowPlayingPrefetcher.plan(input(rip = true, upcoming = listOf(t("a", Track.Source.APPLE_MUSIC_ONLY, local = true), t("c", Track.Source.APPLE_MUSIC_ONLY))))
        assertEquals(listOf("c"), plan.rips)
    }

    @Test fun allowsAhead_isInsideTheWindowAndNeverThePlayingRow() {
        val rows = (0..14).map { PlaybackRipWindow.Row("s$it", "s${it}_v") }
        assertFalse(PlaybackRipWindow.allowsAhead("s3", rows, 3))
        assertFalse(PlaybackRipWindow.allowsAhead("s3_v", rows, 3))
        assertTrue(PlaybackRipWindow.allowsAhead("s4", rows, 3))
        assertTrue(PlaybackRipWindow.allowsAhead("s13", rows, 3))
        assertFalse(PlaybackRipWindow.allowsAhead("s14", rows, 3))
        assertFalse(PlaybackRipWindow.allowsAhead("s2", rows, 3))
        assertFalse(PlaybackRipWindow.allowsAhead("s1", emptyList(), 0))
    }
}
