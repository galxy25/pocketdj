package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher.Input
import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher.Step
import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher.Track
import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher.Track.Source
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class NowPlayingPrefetcherTest {
    private val lock = StemLockState(enabled = true, stemsOn = true)
    private val off = StemLockState()
    private val on = NpMixModeState(enabled = true)

    private fun t(id: String, local: Boolean = false, fetchable: Boolean = true, parts: Set<String> = emptySet(),
                  remote: Boolean = true, source: Source = Source.RIPPED) =
        Track(id, id, id, "a", local, fetchable, parts, remote, source)

    private fun names(p: NowPlayingPrefetcher.Plan) = p.steps.map { it.toString() }
    private val all4 = listOf("vocals", "drums", "other", "bass")
    private fun stemsOf(id: String) = all4.map { "$it:$id" }
    private fun rows(n: Int) = (1..n).map { t("r$it") }

    // ---- Mix Mode OFF == Stem Lock plan ------------------------------------------------------------

    @Test fun mixModeOffIsExactlyTheStemLockPlanForEveryWindowNetworkAndSource() {
        val upcoming = listOf(
            t("a"), t("b", local = true, parts = setOf("vocals")), t("c", fetchable = false, remote = false),
            t("d", source = Source.APPLE_MUSIC_ONLY, fetchable = false), t("e", remote = false), t("f"),
        )
        val cur = t("cur", local = true, parts = setOf("vocals"))
        for (net in NetworkClass.entries) for (w in listOf(1, 3, 5, 10)) for (carry in listOf(lock, lock.copy(muted = listOf("bass")), off)) {
            for (cell in NpMixCellularPolicy.entries) for (partial in listOf(true, false)) {
                val legacy = NowPlayingPrefetcher.plan(if (partial) cur else null, upcoming.take(w), carry, net, w)
                val viaInput = NowPlayingPrefetcher.plan(
                    Input(cur, upcoming, carry, NpMixModeState(false), net, window = 7, stemLockWindow = w, cellular = cell,
                        currentStemsPartial = partial, isRipServerConfigured = true),
                )
                assertEquals("net=$net w=$w carry=$carry", legacy, viaInput)
            }
        }
    }

    @Test fun stemLockGoldenOrderIsUnchanged() {
        val p = NowPlayingPrefetcher.plan(null, listOf(t("n")), lock, NetworkClass.UNMETERED, 3)
        assertEquals(listOf("song:n") + stemsOf("n"), names(p))
        assertEquals(emptyList<String>(), p.rips)
    }

    // ---- Mix Mode ON goldens -----------------------------------------------------------------------

    private fun run(
        window: Int, net: NetworkClass = NetworkClass.UNMETERED, cell: NpMixCellularPolicy = NpMixCellularPolicy.NEXT_SONG,
        carry: StemLockState = off, current: Track? = null, up: List<Track> = rows(10), wanted: Boolean = false,
        rip: Boolean = false, fx: Boolean = false, lockWindow: Int = 3,
    ) = NowPlayingPrefetcher.plan(
        Input(current, up, carry, on, net, window, lockWindow, cell, currentStemsWanted = wanted, isRipServerConfigured = rip, fxLockSongs = fx),
    )

    private fun expectedRows(n: Int) = (1..n).flatMap { listOf("song:r$it") + stemsOf("r$it") }
    private val curLocal = t("cur", local = true, parts = all4.toSet())

    @Test fun wifiWindowGoldensForEveryAheadOption() {
        for (w in NpMixSettings.AHEAD_OPTIONS) {
            assertEquals("window $w", expectedRows(w), names(run(w, current = curLocal)))
        }
    }

    @Test fun unmeteredAndCellularFullAreTheSamePlan() {
        for (w in listOf(1, 3, 5, 10)) {
            assertEquals(
                names(run(w, current = curLocal)),
                names(run(w, net = NetworkClass.EXPENSIVE, cell = NpMixCellularPolicy.FULL, current = curLocal)),
            )
        }
    }

    @Test fun currentRippedButNotLocalLeadsWithItsSongThenItsStems() {
        val cur = t("cur")
        assertEquals(listOf("song:cur") + stemsOf("cur") + listOf("song:r1") + stemsOf("r1"), names(run(1, current = cur)))
    }

    @Test fun currentLocalWithMissingPartsFetchesOnlyTheMissingOnes() {
        val cur = t("cur", local = true, parts = setOf("vocals", "bass"))
        assertEquals(listOf("drums:cur", "other:cur", "song:r1") + stemsOf("r1"), names(run(1, current = cur)))
    }

    @Test fun cellularNextSongFetchesOnlyTheNextSongWhenNoStemsAreAsked() {
        for (w in listOf(1, 3, 5, 10)) {
            assertEquals(listOf("song:r1"), names(run(w, net = NetworkClass.EXPENSIVE, current = curLocal)))
        }
    }

    @Test fun cellularNextSongStemsFollowTheLockForTheNextRowAndTheCurrentRowWhenAsked() {
        val muted = lock.copy(muted = listOf("bass"))
        val cur = t("cur", local = true)
        assertEquals(
            listOf("vocals:cur", "drums:cur", "other:cur", "song:r1", "vocals:r1", "drums:r1", "other:r1", "bass:cur", "bass:r1"),
            names(run(5, net = NetworkClass.EXPENSIVE, carry = muted, current = cur)),
        )
        // the Stems toggle without a lock: the current row's four parts, the next row stays song-only
        assertEquals(stemsOf("cur") + "song:r1", names(run(5, net = NetworkClass.EXPENSIVE, current = cur, wanted = true)))
    }

    @Test fun cellularOffAddsNothingBeyondTheStemLock() {
        assertEquals(emptyList<String>(), names(run(5, net = NetworkClass.EXPENSIVE, cell = NpMixCellularPolicy.OFF, current = curLocal)))
        assertEquals(
            listOf("song:r1") + listOf("vocals", "drums", "other", "bass").map { "$it:r1" },
            names(run(5, net = NetworkClass.EXPENSIVE, cell = NpMixCellularPolicy.OFF, carry = lock, current = curLocal)),
        )
    }

    @Test fun dataSaverAddsNothingButTheLockStillGetsItsNextSongAndEnabledStems() {
        assertEquals(emptyList<String>(), names(run(5, net = NetworkClass.CONSTRAINED, current = curLocal)))
        val muted = lock.copy(muted = listOf("bass"))
        assertEquals(listOf("song:r1", "vocals:r1", "drums:r1", "other:r1"), names(run(5, net = NetworkClass.CONSTRAINED, carry = muted, current = curLocal)))
    }

    @Test fun offlinePlansNothing() {
        assertEquals(emptyList<String>(), names(run(5, net = NetworkClass.OFFLINE, carry = lock, current = t("cur"))))
    }

    @Test fun mutedPartsComeLastAcrossTheWholeMixWindow() {
        val muted = lock.copy(muted = listOf("drums"))
        val p = names(run(2, carry = muted, current = curLocal, lockWindow = 2))
        assertEquals(
            listOf("song:r1", "vocals:r1", "other:r1", "bass:r1", "song:r2", "vocals:r2", "other:r2", "bass:r2", "drums:r1", "drums:r2"),
            p,
        )
    }

    @Test fun mixWindowReachesPastTheStemLockWindowButNeverShrinksBelowIt() {
        val p = names(run(5, carry = lock, current = curLocal, lockWindow = 3))
        assertEquals(expectedRows(5), p)
        // a Mix window smaller than the lock's: the lock's rows are still appended
        val q = names(run(1, carry = lock, current = curLocal, lockWindow = 3))
        assertEquals(expectedRows(3), q)
    }

    @Test fun unfetchableRowsAreSkippedWholeAndSourceKindsDoNotChangeStepOrder() {
        val up = listOf(t("a", fetchable = false), t("b", source = Source.LIVE, fetchable = false), t("c", local = true, parts = setOf("vocals")), t("d", source = Source.LOCAL, local = true, remote = false))
        assertEquals(listOf("drums:c", "other:c", "bass:c"), names(run(4, up = up, current = curLocal)))
    }

    @Test fun ripsAreStepZeroSideListForAppleMusicOnlyRowsAndNeedARipServer() {
        val up = listOf(t("x"), t("am1", source = Source.APPLE_MUSIC_ONLY, fetchable = false), t("am2", source = Source.APPLE_MUSIC_ONLY, fetchable = false),
            t("am3", source = Source.APPLE_MUSIC_ONLY, fetchable = false))
        assertEquals(emptyList<String>(), run(5, up = up, current = curLocal).rips)
        assertEquals(listOf("am1", "am2"), run(5, up = up, current = curLocal, rip = true).rips)
        // narrow cellular window still looks RIP_AHEAD (2) rows deep: [x, am1] only
        val narrow = run(1, net = NetworkClass.EXPENSIVE, up = up, current = curLocal, rip = true)
        assertEquals(listOf("am1"), narrow.rips)
        assertFalse(narrow.steps.any { it.songId.startsWith("am") })
        // an AM row that is already local is never ripped
        assertEquals(listOf("am2"), run(5, up = listOf(t("am1", source = Source.APPLE_MUSIC_ONLY, local = true), t("am2", source = Source.APPLE_MUSIC_ONLY, fetchable = false)), rip = true).rips)
    }

    @Test fun mixModeAsksForCloudSeparationOnlyWithAServerAndOnlyForRowsThatCanPlayLocally() {
        val up = listOf(t("s1", remote = false), t("s2", remote = false, fetchable = false), t("s3", remote = false, source = Source.CATALOG_ONLY))
        assertEquals(emptyList<String>(), run(3, up = up, current = curLocal).stemify)
        assertEquals(listOf("s1"), run(3, up = up, current = curLocal, rip = true).stemify)
    }

    @Test fun fxLockAddsTheWindowsWholeSongsWithoutStems() {
        val p = NowPlayingPrefetcher.plan(Input(curLocal, rows(4), off, NpMixModeState(false), NetworkClass.UNMETERED, stemLockWindow = 2, fxLockSongs = true))
        assertEquals(listOf("song:r1", "song:r2"), names(p))
    }

    // ---- the worker + disk guard + cooldowns -------------------------------------------------------

    private fun lane(clock: () -> Long = { 0L }): Pair<TestScope, NowPlayingPrefetcher> {
        val scope = TestScope(StandardTestDispatcher())
        return scope to NowPlayingPrefetcher(scope, now = clock)
    }

    @Test fun diskGuardRunsBeforeEveryStepAndAnUnadmittedStepIsSkippedWithCooldown() {
        var clock = 0L
        val (scope, pf) = lane { clock }
        val asked = ArrayList<String>()
        val fetched = ArrayList<String>()
        val finished = ArrayList<Pair<String, Boolean>>()
        pf.diskGuard = { s -> asked += s.toString(); s.toString() != "drums:n" }
        pf.fetchSong = { fetched += it.toString(); true }
        pf.fetchStemPart = { id, part -> fetched += "$part:$id"; true }
        pf.onStepFinished = { s, ok -> finished += s.toString() to ok }
        val plan = NowPlayingPrefetcher.plan(null, listOf(t("n")), lock, NetworkClass.UNMETERED, 1)
        pf.apply(plan); scope.advanceUntilIdle()
        assertEquals(listOf("song:n") + stemsOf("n"), asked)
        assertEquals(listOf("song:n", "vocals:n", "other:n", "bass:n"), fetched)
        assertTrue("drums skipped, reported not-ok", finished.contains("drums:n" to false))
        assertFalse(pf.startedLog.any { it.toString() == "drums:n" })
        // blocked: not retried inside the cooldown, retried after
        asked.clear()
        pf.apply(plan); scope.advanceUntilIdle()
        assertFalse(asked.contains("drums:n"))
        clock += pf.blockedCooldownMs
        pf.apply(plan); scope.advanceUntilIdle()
        assertTrue(asked.contains("drums:n"))
    }

    @Test fun blockedSongReadsAsStorageFullForTheCooldownOnly() {
        var clock = 0L
        val (scope, pf) = lane { clock }
        pf.diskGuard = { false }
        pf.apply(NowPlayingPrefetcher.plan(null, listOf(t("n")), lock, NetworkClass.UNMETERED, 1)); scope.advanceUntilIdle()
        assertTrue(pf.songBlockedRecently("n"))
        assertFalse(pf.songFailedRecently("n"))
        assertFalse(pf.songBlockedRecently("other"))
        clock += pf.blockedCooldownMs
        assertFalse(pf.songBlockedRecently("n"))
    }

    @Test fun failedSongReadsAsDownloadFailedAndInFlightIsActive() {
        val (scope, pf) = lane()
        val gate = CompletableDeferred<Boolean>()
        pf.fetchSong = { gate.await() }
        pf.fetchStemPart = { _, _ -> true }
        pf.apply(NowPlayingPrefetcher.plan(null, listOf(t("n")), lock, NetworkClass.UNMETERED, 1)); scope.runCurrent()
        assertTrue(pf.isFetchingSong("n"))
        assertTrue(pf.isPlannedSong("n"))
        assertEquals(setOf("n"), pf.activeSongIds)
        gate.complete(false); scope.runCurrent()
        assertTrue(pf.songFailedRecently("n"))
    }

    @Test fun ripRequestsAreDedupedUntilTheRetryWindow() {
        var clock = 0L
        val (_, pf) = lane { clock }
        val asked = ArrayList<String>()
        pf.requestRip = { asked += it }
        val plan = NowPlayingPrefetcher.Plan(rips = listOf("am1"))
        pf.apply(plan); pf.apply(plan)
        assertEquals(listOf("am1"), asked)
        clock += pf.ripRetryMs
        pf.apply(plan)
        assertEquals(listOf("am1", "am1"), asked)
        assertEquals(listOf("am1", "am1"), pf.ripLog)
    }

    // ---- never cancel an explicit download ---------------------------------------------------------

    @Test fun awaitPendingDownloadReturnsWhenTheDownloadLandsAndGivesUpAtTheCap() = runTest {
        var polls = 0
        val ok = NowPlayingPrefetcher.awaitPendingDownload(
            state = { if (++polls < 5) NowPlayingPrefetcher.PendingDownload.DOWNLOADING else NowPlayingPrefetcher.PendingDownload.READY },
            nowMs = { testScheduler.currentTime },
        )
        assertTrue(ok); assertEquals(5, polls)
        assertEquals(1000L, testScheduler.currentTime)

        val t0 = testScheduler.currentTime
        val timedOut = NowPlayingPrefetcher.awaitPendingDownload(
            state = { NowPlayingPrefetcher.PendingDownload.DOWNLOADING }, nowMs = { testScheduler.currentTime },
        )
        assertFalse(timedOut)
        assertTrue("waits the full 90 s", testScheduler.currentTime - t0 >= 90_000)

        assertFalse(NowPlayingPrefetcher.awaitPendingDownload({ NowPlayingPrefetcher.PendingDownload.OTHER }, nowMs = { testScheduler.currentTime }))
    }

    // ---- DiskGuard + NetworkClass ------------------------------------------------------------------

    @Test fun diskVerdictPureTable() {
        val gb = 1_000_000_000L
        val step = DiskGuard.ESTIMATED_STEP_BYTES
        assertEquals(DiskGuard.Verdict.Ok, DiskGuard.verdict(5 * gb, 0, 2 * gb))
        // free-space floor: need = floor + step - free
        assertEquals(DiskGuard.Verdict.Evict(gb + step - (gb + 1)), DiskGuard.verdict(gb + 1, 0, 2 * gb))
        // cap overshoot
        assertEquals(DiskGuard.Verdict.Evict(5), DiskGuard.verdict(50 * gb, 2 * gb + 5 - step, 2 * gb))
        // the larger of the two
        assertEquals(DiskGuard.Verdict.Evict(gb + step - 100), DiskGuard.verdict(100, 0, 2 * gb))
        // unreadable volume checks only the cap
        assertEquals(DiskGuard.Verdict.Ok, DiskGuard.verdict(null, 0, 2 * gb))
        assertEquals(DiskGuard.Verdict.Evict(step), DiskGuard.verdict(null, 1, 1))
    }

    @Test fun admitSweepsOnceThenRechecksAndSkipsWhenStillFull() = runTest {
        val gb = 1_000_000_000L
        var free = 500_000_000L
        var footprint = 800_000_000L
        val overrides = ArrayList<Long>()
        val g = DiskGuard({ free }, { footprint }, { 2 * gb }, sweep = { cap -> overrides += cap; free += gb; footprint = cap }, io = kotlinx.coroutines.Dispatchers.Unconfined)
        assertTrue(g.admit())
        assertEquals(1, overrides.size)
        assertTrue("override is below the old footprint", overrides[0] < 800_000_000L)
        // a sweep that frees nothing: skipped
        val stuck = DiskGuard({ 100L }, { 0L }, { 2 * gb }, sweep = { overrides += it }, io = kotlinx.coroutines.Dispatchers.Unconfined)
        assertFalse(stuck.admit())
        assertEquals(2, overrides.size)
        // plenty free: no sweep at all
        val fine = DiskGuard({ 9 * gb }, { 0L }, { 2 * gb }, sweep = { error("no sweep") }, io = kotlinx.coroutines.Dispatchers.Unconfined)
        assertTrue(fine.admit())
    }

    @Test fun networkClassMapping() {
        assertEquals(NetworkClass.OFFLINE, NetworkClass.classify(hasNetwork = false, metered = true, dataSaver = true))
        assertEquals(NetworkClass.UNMETERED, NetworkClass.classify(true, metered = false, dataSaver = false))
        assertEquals(NetworkClass.UNMETERED, NetworkClass.classify(true, metered = false, dataSaver = true))
        assertEquals(NetworkClass.EXPENSIVE, NetworkClass.classify(true, metered = true, dataSaver = false))
        assertEquals(NetworkClass.CONSTRAINED, NetworkClass.classify(true, metered = true, dataSaver = true))
        assertEquals("constrained", NetworkClass.CONSTRAINED.raw)
    }
}
