package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.games.GameKind
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.playback.FakeGameRunPlayer
import com.levi.pocketdj.playback.assertEquals
import com.levi.pocketdj.playback.assertFalse
import com.levi.pocketdj.playback.assertNotNull
import com.levi.pocketdj.playback.assertNull
import com.levi.pocketdj.playback.assertTrue
import java.io.File
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

private class FakeEnv(songCount: Int) : CollectorsPuzzleEnv {
    val allSongs = (0 until songCount).map {
        IndexSong(id = "s$it", albumId = "alb", artist = "Artist", name = "Track $it", length = 200_000)
    }
    val pockets = mutableMapOf("pkt_A" to "Crate A", "pkt_B" to "Crate B", "pkt_C" to "Crate C")
    val members = mutableMapOf<String, MutableSet<String>>()
    override fun songs() = allSongs
    override fun albumsById() = mapOf("alb" to IndexAlbum(id = "alb", artist = "Artist", name = "Alb", genre = "Electronic"))
    override fun favoriteIds() = emptySet<String>()
    override fun memberIds(collectionId: String) = members[collectionId]?.toList().orEmpty()
    override fun collectionExists(collectionId: String) = collectionId in pockets
    override fun collectionName(collectionId: String) = pockets[collectionId]
    override fun addSong(songId: String, target: AddTarget) {
        members.getOrPut(target.id) { mutableSetOf() }.add(songId)
    }
    override fun stillContains(songId: String, target: AddTarget) = members[target.id]?.contains(songId) == true
}

private class MemoryPersistence(var blob: String? = null) : PuzzleSettingsPersistence {
    override fun load() = blob
    override fun save(json: String) { blob = json }
}

@OptIn(ExperimentalCoroutinesApi::class)
class CollectorsPuzzleEngineTest {
    @get:Rule val tmp = TemporaryFolder()

    private class Stack(
        val env: FakeEnv,
        val player: FakeGameRunPlayer,
        val scoreboard: GameScoreboardStore,
        val decisions: PuzzleDecisionStore,
        val persistence: MemoryPersistence,
        val engine: CollectorsPuzzleEngine,
        val clock: LongArray,
    ) {
        var now: Long
            get() = clock[0]
            set(v) { clock[0] = v }
        val tag get() = engine.runTag
    }

    private fun TestScope.stack(
        songs: Int = 7,
        roundSeconds: Int = 120,
        targets: List<String> = listOf("pkt_A"),
        persistence: MemoryPersistence = MemoryPersistence(),
        configure: (CollectorsPuzzleEngine) -> Unit = {},
    ): Stack {
        val env = FakeEnv(songs)
        val player = FakeGameRunPlayer()
        val scoreboard = GameScoreboardStore(tmp.newFile())
        val decisions = PuzzleDecisionStore(tmp.newFile().also { it.delete() }, backgroundScope, EmptyCoroutineContext)
        val clock = longArrayOf(1_000_000L)
        var ids = 0
        val engine = CollectorsPuzzleEngine(
            env = env, player = player, scoreboard = scoreboard, decisions = decisions,
            persistence = persistence, scope = backgroundScope, computeContext = EmptyCoroutineContext,
            clockMs = { clock[0] }, newRoundId = { "ROUND-${ids++}" },
        )
        engine.countdownEnabled = false
        engine.tickerEnabled = false
        var x = 12345L
        engine.rng = { x = (x * 6364136223846793005L + 1442695040888963407L); ((x ushr 11) and 0xFFFFFFFFFFFL).toDouble() / (1L shl 44) }
        engine.updateSettings(PuzzleSettings(roundSeconds = roundSeconds, targetCollectionIds = targets, similarity = PuzzleSettings.Similarity.OFF))
        configure(engine)
        return Stack(env, player, scoreboard, decisions, persistence, engine, clock)
    }

    private fun Stack.actions(action: String) = decisions.decisions.filter { it.action == action }

    // ---- start -----------------------------------------------------------------------------
    @Test fun startRound_samplesMaxOf60AndRoundSeconds() = runTest {
        val s = stack(songs = 300, roundSeconds = 180)
        s.engine.startRound()
        assertEquals(180, s.engine.currentQueue.size)
        val short = stack(songs = 300, roundSeconds = 30)
        short.engine.startRound()
        assertEquals(60, short.engine.currentQueue.size, "never under 60")
    }

    @Test fun startRound_armsAudioAtIndexZeroUnderPuzzleTag() = runTest {
        val s = stack(songs = 7)
        s.engine.startRound()
        assertEquals("puzzle_${s.engine.currentRoundId}", s.tag)
        assertTrue(s.tag.startsWith("puzzle_"))
        assertEquals(s.tag, s.player.plays.single().first)
        assertEquals(s.engine.currentQueue.map { it.id }, s.player.plays.single().second.map { it.songId })
        assertTrue(s.player.ownsRun(s.tag))
        assertEquals(1_000_000L + 120_000L, s.engine.state.value.deadlineMs)
        assertEquals(120, s.engine.remainingSeconds())
        assertNotNull(s.engine.current)
        assertNull(s.engine.currentError)
    }

    @Test fun startRound_emptySample_setsErrorAndStaysIdle() = runTest {
        val s = stack()
        s.engine.updateSettings(s.engine.currentSettings.copy(yearMin = 3000))
        s.engine.startRound()
        assertEquals(PuzzleRoundState.Phase.IDLE, s.engine.currentPhase)
        assertEquals("No songs match these settings.", s.engine.currentError)
        assertTrue(s.player.plays.isEmpty())
    }

    @Test fun startRound_noTargetsStillRuns() = runTest {
        val s = stack(targets = emptyList())
        s.engine.startRound()
        assertEquals(PuzzleRoundState.Phase.RUNNING, s.engine.currentPhase)
        assertNotNull(s.engine.current)
    }

    @Test fun startRound_refusedUnlessIdleOrFinished() = runTest {
        val s = stack()
        s.engine.startRound()
        val id = s.engine.currentRoundId
        s.engine.startRound()
        assertEquals(id, s.engine.currentRoundId)
        assertEquals(1, s.player.plays.size)
    }

    @Test fun countdown_3_2_1_thenRunning_unlessDisabled() = runTest {
        val s = stack { it.countdownEnabled = true }
        val seen = mutableListOf<Int>()
        val run = backgroundScope.launch { s.engine.startRound() }
        runCurrent()
        assertEquals(PuzzleRoundState.Phase.COUNTDOWN, s.engine.currentPhase)
        seen += s.engine.state.value.countdown
        advanceTimeBy(1000); runCurrent()
        seen += s.engine.state.value.countdown
        advanceTimeBy(1000); runCurrent()
        seen += s.engine.state.value.countdown
        assertEquals(listOf(3, 2, 1), seen)
        assertTrue(s.player.plays.isEmpty(), "no audio during the countdown")
        advanceTimeBy(1000); runCurrent()
        assertEquals(PuzzleRoundState.Phase.RUNNING, s.engine.currentPhase)
        assertEquals(1, s.player.plays.size)
        run.cancel()
    }

    @Test fun cancelledStart_doesNotWedgeTheEngine() = runTest {
        val s = stack { it.countdownEnabled = true }
        val run = backgroundScope.launch { s.engine.startRound() }
        runCurrent()
        assertEquals(PuzzleRoundState.Phase.COUNTDOWN, s.engine.currentPhase)
        run.cancel() // the screen's scope died mid-countdown
        runCurrent()
        assertEquals(PuzzleRoundState.Phase.IDLE, s.engine.currentPhase)
        assertTrue(s.player.plays.isEmpty())
        s.engine.countdownEnabled = false
        s.engine.startRound()
        assertEquals(PuzzleRoundState.Phase.RUNNING, s.engine.currentPhase)
    }

    @Test fun detachedStart_survivesTheCallersScope() = runTest {
        val s = stack { it.countdownEnabled = true }
        val caller = backgroundScope.launch { s.engine.startRoundDetached() }
        runCurrent()
        caller.cancel()
        advanceTimeBy(3000); runCurrent()
        assertEquals(PuzzleRoundState.Phase.RUNNING, s.engine.currentPhase)
    }

    // ---- cloud budget ----------------------------------------------------------------------
    @Test fun cloudBudgetRace_slowProviderLosesAndRoundStartsLocalOnly() = runTest {
        var finished = false
        val s = stack { e ->
            e.updateSettings(e.currentSettings.copy(similarity = PuzzleSettings.Similarity.ON))
            e.cloudSimilarProvider = { delay(60_000); finished = true; listOf("s1") }
        }
        val t0 = testScheduler.currentTime
        s.engine.startRound()
        assertEquals(PuzzleRoundState.Phase.RUNNING, s.engine.currentPhase)
        assertEquals(CollectorsPuzzleEngine.CLOUD_BUDGET_MS, testScheduler.currentTime - t0, "waited exactly the budget")
        assertFalse(finished, "the slow provider was cancelled")
    }

    @Test fun cloudCall_happensOncePerRound_neverFromTick() = runTest {
        var calls = 0
        val s = stack(songs = 100) { e ->
            e.updateSettings(e.currentSettings.copy(similarity = PuzzleSettings.Similarity.ON))
            e.cloudSimilarProvider = { calls++; listOf("s3") }
        }
        s.engine.startRound()
        repeat(5) { s.engine.tickOnce() }
        runCurrent()
        assertEquals(1, calls)
    }

    @Test fun cloudProvider_notCalledWithoutTargetsOrWhenSimilarityOff() = runTest {
        var calls = 0
        val off = stack { it.cloudSimilarProvider = { calls++; emptyList() } }
        off.engine.startRound()
        val noTargets = stack(targets = emptyList()) { e ->
            e.updateSettings(e.currentSettings.copy(similarity = PuzzleSettings.Similarity.ON))
            e.cloudSimilarProvider = { calls++; emptyList() }
        }
        noTargets.engine.startRound()
        assertEquals(0, calls)
    }

    @Test fun cloudProvider_throwingIsTheSameAsAbsent() = runTest {
        val s = stack { e ->
            e.updateSettings(e.currentSettings.copy(similarity = PuzzleSettings.Similarity.ON))
            e.cloudSimilarProvider = { error("404") }
        }
        s.engine.startRound()
        assertEquals(PuzzleRoundState.Phase.RUNNING, s.engine.currentPhase)
    }

    // ---- scoring ---------------------------------------------------------------------------
    @Test fun assign_onePointFilesIntoTargetAdvancesAndSkipsOwnedAudio() = runTest {
        val s = stack()
        s.engine.startRound()
        val first = s.engine.current!!
        s.engine.assign(0)
        assertEquals(1, s.engine.currentScore)
        assertEquals(1, s.engine.currentQueueIndex)
        assertTrue(s.env.stillContains(first.id, AddTarget(AddTarget.Kind.POCKET, "pkt_A")))
        assertEquals(1, s.player.skips)
        val d = s.actions("assigned").single()
        assertEquals("pkt_A", d.collectionId)
        assertEquals("Crate A", d.collectionName)
        assertEquals(0, d.positionInRound)
        assertEquals("Crate A", s.engine.state.value.assigned.single().collectionName)
        s.engine.assign(7) // out of range: ignored
        assertEquals(1, s.engine.currentScore)
    }

    @Test fun assign_playlistTargetUsesPlaylistKind() = runTest {
        val s = stack(targets = listOf("pls_X"))
        s.env.pockets["pls_X"] = "List X"
        s.engine.updateSettings(s.engine.currentSettings.copy(targetCollectionIds = listOf("pls_X")))
        s.engine.startRound()
        s.engine.assign(0)
        assertTrue(s.env.stillContains(s.engine.currentQueue[0].id, AddTarget(AddTarget.Kind.PLAYLIST, "pls_X")))
    }

    @Test fun skip_logsSkippedNoPointAndAdvances() = runTest {
        val s = stack()
        s.engine.startRound()
        val song = s.engine.current!!
        s.engine.skip()
        assertEquals(0, s.engine.currentScore)
        assertEquals(1, s.engine.currentQueueIndex)
        val d = s.actions("skipped").single()
        assertEquals(song.id, d.songId)
        assertEquals(1, s.player.skips)
        assertEquals(s.engine.currentSettings, d.settings)
    }

    @Test fun onePointPerCardManyDecisionRows() = runTest {
        val s = stack(targets = emptyList())
        s.engine.startRound()
        val song = s.engine.current!!
        assertTrue(s.engine.beginFiling())
        s.engine.noteFiled(AddTarget(AddTarget.Kind.POCKET, "pkt_A"))
        s.engine.noteFiled(AddTarget(AddTarget.Kind.POCKET, "pkt_B"))
        s.engine.noteFiled(AddTarget(AddTarget.Kind.POCKET, "pkt_C"))
        for (id in listOf("pkt_A", "pkt_B", "pkt_C")) s.env.addSong(song.id, AddTarget(AddTarget.Kind.POCKET, id))
        s.engine.endFiling()
        assertEquals(1, s.engine.currentScore, "one point per card however many crates")
        assertEquals(1, s.engine.currentQueueIndex, "advanced exactly once")
        assertEquals(3, s.actions("assigned").size, "one decision row per target")
        assertEquals(1, s.engine.state.value.assigned.size)
        assertEquals("Crate A +2 more", s.engine.state.value.assigned.single().collectionName)
        assertEquals(1, s.player.skips)
    }

    // ---- filing ----------------------------------------------------------------------------
    @Test fun beginFiling_refusals() = runTest {
        val s = stack()
        assertFalse(s.engine.beginFiling(), "not running")
        s.engine.startRound()
        assertTrue(s.engine.beginFiling())
        assertFalse(s.engine.beginFiling(), "a sheet is already open")
        s.engine.endFiling()
        s.player.foreignPlay()
        assertFalse(s.engine.beginFiling(), "taken over")
        assertEquals(PuzzleRoundState.Phase.FINISHED, s.engine.currentPhase, "...and ends the round")
        assertEquals(0, s.player.stops, "without stopping the foreign run")
    }

    @Test fun filingHoldSuspendsTicker() = runTest {
        val s = stack(roundSeconds = 120)
        s.engine.startRound()
        val idx = s.engine.currentQueueIndex
        assertTrue(s.engine.beginFiling())
        // The audio ran on and the deadline passes behind the sheet: nothing may move.
        s.player.position = 3
        s.now += 500_000
        s.engine.tickOnce()
        assertEquals(PuzzleRoundState.Phase.RUNNING, s.engine.currentPhase, "deadline check is held")
        assertEquals(idx, s.engine.currentQueueIndex, "no drift re-sync behind the sheet")
        assertTrue(s.actions("expired").isEmpty())
        s.player.goSilent()
        s.engine.tickOnce()
        assertEquals(1, s.player.plays.size, "no watchdog re-arm behind the sheet")
    }

    @Test fun remainingSeconds_freezesWhileSheetOpen() = runTest {
        val s = stack(roundSeconds = 120)
        s.engine.startRound()
        s.now += 10_000
        assertEquals(110, s.engine.remainingSeconds())
        s.engine.beginFiling()
        s.now += 5_000
        assertEquals(110, s.engine.remainingSeconds())
    }

    @Test fun filingCreditScalesAndCaps() = runTest {
        // 1 collection: min(held, 20)
        val a = stack()
        a.engine.startRound()
        val d0 = a.engine.state.value.deadlineMs
        a.engine.beginFiling()
        a.engine.noteFiled(AddTarget(AddTarget.Kind.POCKET, "pkt_A"))
        a.env.addSong(a.engine.current!!.id, AddTarget(AddTarget.Kind.POCKET, "pkt_A"))
        a.now += 45_000
        a.engine.endFiling()
        assertEquals(d0 + 20_000, a.engine.state.value.deadlineMs, "one crate buys at most 20 s")

        // shorter than the cap: exactly the elapsed time
        val b = stack()
        b.engine.startRound()
        val bd = b.engine.state.value.deadlineMs
        b.engine.beginFiling()
        b.now += 7_000
        b.engine.endFiling() // cancel still credits the held clock
        assertEquals(bd + 7_000, b.engine.state.value.deadlineMs)

        // 3 collections: 20 + 2*10 = 40
        val c = stack(targets = emptyList())
        c.engine.startRound()
        val cd = c.engine.state.value.deadlineMs
        c.engine.beginFiling()
        for (id in listOf("pkt_A", "pkt_B", "pkt_C")) {
            c.engine.noteFiled(AddTarget(AddTarget.Kind.POCKET, id))
            c.env.addSong(c.engine.current!!.id, AddTarget(AddTarget.Kind.POCKET, id))
        }
        c.now += 100_000
        c.engine.endFiling()
        assertEquals(cd + 40_000, c.engine.state.value.deadlineMs)

        // many collections: ceilinged at 60
        val d = stack(targets = emptyList())
        d.env.pockets.putAll((1..8).associate { "pkt_$it" to "C$it" })
        d.engine.startRound()
        val dd = d.engine.state.value.deadlineMs
        d.engine.beginFiling()
        for (i in 1..8) {
            val t = AddTarget(AddTarget.Kind.POCKET, "pkt_$i")
            d.engine.noteFiled(t)
            d.env.addSong(d.engine.current!!.id, t)
        }
        d.now += 600_000
        d.engine.endFiling()
        assertEquals(dd + 60_000, d.engine.state.value.deadlineMs, "20 + 10*7 = 90 ceilinged to 60")
        assertEquals(1, d.engine.currentScore)
    }

    @Test fun endFilingIdempotentCancelIsNotSkip() = runTest {
        val s = stack()
        s.engine.startRound()
        s.engine.beginFiling()
        s.now += 3_000
        s.engine.endFiling() // cancel: nothing was noted
        val deadline = s.engine.state.value.deadlineMs
        assertEquals(0, s.engine.currentScore)
        assertEquals(0, s.engine.currentQueueIndex, "the card stays")
        assertTrue(s.decisions.decisions.isEmpty(), "cancel is NOT a skip")
        // second settle (sheet callback + onChange both fire): no double credit
        s.now += 9_000
        s.engine.endFiling()
        assertEquals(deadline, s.engine.state.value.deadlineMs)
        assertEquals(0, s.engine.currentScore)

        // a filed opening settles once
        s.engine.beginFiling()
        val song = s.engine.current!!
        s.engine.noteFiled(AddTarget(AddTarget.Kind.POCKET, "pkt_A"))
        s.env.addSong(song.id, AddTarget(AddTarget.Kind.POCKET, "pkt_A"))
        s.engine.endFiling()
        s.engine.endFiling()
        assertEquals(1, s.engine.currentScore)
        assertEquals(1, s.actions("assigned").size)
    }

    @Test fun uncheckedRowsNotFiled() = runTest {
        val s = stack()
        s.engine.startRound()
        val song = s.engine.current!!
        s.engine.beginFiling()
        val a = AddTarget(AddTarget.Kind.POCKET, "pkt_A")
        val b = AddTarget(AddTarget.Kind.POCKET, "pkt_B")
        s.engine.noteFiled(a)
        s.engine.noteFiled(b)
        // The picker's rows are toggles: A stays added, B was added then UNCHECKED.
        s.env.addSong(song.id, a)
        s.engine.endFiling()
        assertEquals(listOf("pkt_A"), s.actions("assigned").map { it.collectionId }, "only live membership files")
        assertEquals("Crate A", s.engine.state.value.assigned.single().collectionName)

        // unchecking everything is a cancel
        val t = stack()
        t.engine.startRound()
        t.engine.beginFiling()
        t.engine.noteFiled(a)
        t.engine.endFiling()
        assertEquals(0, t.engine.currentScore)
        assertEquals(0, t.engine.currentQueueIndex)
    }

    @Test fun noteFiled_dedupesAndIsIgnoredOutsideAnOpening() = runTest {
        val s = stack()
        s.engine.startRound()
        val a = AddTarget(AddTarget.Kind.POCKET, "pkt_A")
        s.engine.noteFiled(a) // no sheet
        assertTrue(s.engine.state.value.filedTargets.isEmpty())
        s.engine.beginFiling()
        s.engine.noteFiled(a)
        s.engine.noteFiled(a.copy(sequenceId = "other"))
        assertEquals(1, s.engine.state.value.filedTargets.size)
    }

    @Test fun staleFilingAfterRoundEndedFilesNothing() = runTest {
        val s = stack()
        s.engine.startRound()
        val song = s.engine.current!!
        s.engine.beginFiling()
        val a = AddTarget(AddTarget.Kind.POCKET, "pkt_A")
        s.engine.noteFiled(a)
        s.env.addSong(song.id, a)
        s.engine.endRound()
        s.engine.endFiling()
        assertEquals(0, s.actions("assigned").size)
        assertEquals(0, s.engine.currentScore)
    }

    @Test fun endFiling_reArmsAudioWhenPositionDrifted() = runTest {
        val s = stack(songs = 20)
        s.engine.startRound()
        s.engine.beginFiling()
        s.player.position = 4 // audio ran on behind the sheet
        s.engine.endFiling() // cancel: card still 0
        assertEquals(2, s.player.plays.size)
        assertEquals(s.engine.current!!.id, s.player.plays.last().second.first().songId, "re-armed from the card on screen")
    }

    // ---- ticker ----------------------------------------------------------------------------
    @Test fun deadlineEndsRound_recordsScoreboardAndHighScore() = runTest {
        val s = stack()
        s.engine.startRound()
        s.engine.assign(0)
        s.engine.assign(0)
        s.now += 120_000
        s.engine.tickOnce()
        assertEquals(PuzzleRoundState.Phase.FINISHED, s.engine.currentPhase)
        assertEquals(1, s.player.stops, "own audio stopped")
        val rec = s.engine.state.value.lastRunRecord!!
        assertEquals(2, rec.score)
        assertEquals(GameKind.CollectorsPuzzle.token, rec.game)
        assertEquals(s.engine.currentSettings.summaryLine, rec.settingsSummary)
        assertEquals(mapOf("assigned" to "2", "roundSeconds" to "120"), rec.detail)
        assertTrue(s.engine.state.value.isNewHighScore)
        // second round with the same score is not a new high score
        s.engine.reset()
        assertEquals(PuzzleRoundState.Phase.IDLE, s.engine.currentPhase)
        s.engine.startRound()
        s.engine.assign(0)
        s.engine.assign(0)
        s.engine.endRound()
        assertFalse(s.engine.state.value.isNewHighScore)
        assertEquals(2, s.scoreboard.recentRuns(GameKind.CollectorsPuzzle, 10).size)
    }

    @Test fun reset_onlyFromFinished() = runTest {
        val s = stack()
        s.engine.reset()
        s.engine.startRound()
        s.engine.reset()
        assertEquals(PuzzleRoundState.Phase.RUNNING, s.engine.currentPhase)
        s.engine.endRound()
        s.engine.reset()
        assertEquals(PuzzleRoundState.Phase.IDLE, s.engine.currentPhase)
    }

    @Test fun driftExpiredBatchSinglePersist() = runTest {
        val s = stack(songs = 30)
        s.engine.startRound()
        val rev = s.decisions.revision
        s.player.position = 3 // the audio advanced 3 cards on its own
        s.engine.tickOnce()
        assertEquals(3, s.engine.currentQueueIndex)
        val expired = s.actions("expired")
        assertEquals(listOf(0, 1, 2), expired.map { it.positionInRound })
        assertEquals(s.engine.currentQueue.take(3).map { it.id }, expired.map { it.songId })
        assertEquals(rev + 1, s.decisions.revision, "one batch = one revision (one persist)")
        // a second tick at the same position records nothing more
        s.engine.tickOnce()
        assertEquals(3, s.actions("expired").size)
    }

    @Test fun driftAddsBackTheWatchdogBase() = runTest {
        val s = stack(songs = 30)
        s.engine.startRound()
        s.engine.skip(); s.engine.skip()                  // cards 0,1 skipped; queueIndex 2
        s.player.goSilent()
        s.engine.tickOnce()                                // watchdog re-hands the tail from card 2
        assertEquals(2, s.player.plays.size)
        assertEquals(s.engine.currentQueue[2].id, s.player.plays.last().second.first().songId)
        s.player.position = 1                              // the re-armed run advanced one card
        s.engine.tickOnce()
        assertEquals(3, s.engine.currentQueueIndex, "audioBaseIndex(2) + position(1)")
        assertEquals(listOf(2), s.actions("expired").map { it.positionInRound })
    }

    @Test fun watchdogOncePerCard() = runTest {
        val s = stack(songs = 30)
        s.engine.startRound()
        // The start arm already counts as card 0's attempt: silence on it never loops.
        s.player.goSilent()
        repeat(3) { s.engine.tickOnce() }
        assertEquals(1, s.player.plays.size, "the arm at start is the one try for card 0")
        // Card 1 arrives (audio advanced by the engine's own skip), then dies: ONE re-arm.
        s.engine.skip()
        s.player.goSilent()
        s.engine.tickOnce()
        assertEquals(2, s.player.plays.size, "re-armed once from the current card")
        assertEquals(s.engine.current!!.id, s.player.plays.last().second.first().songId)
        s.player.goSilent() // the card's audio genuinely cannot start
        repeat(5) { s.engine.tickOnce() }
        assertEquals(2, s.player.plays.size, "never a loop on the same card")
        s.engine.skip() // a NEW card earns one more retry
        s.player.goSilent()
        s.engine.tickOnce()
        assertEquals(3, s.player.plays.size)
    }

    @Test fun takeoverEndsWithoutStoppingForeignAudio() = runTest {
        val s = stack(songs = 30)
        s.engine.startRound()
        s.player.foreignPlay("set_browse")
        s.player.position = 5
        s.engine.tickOnce()
        assertEquals(PuzzleRoundState.Phase.FINISHED, s.engine.currentPhase)
        assertEquals(0, s.player.stops)
        assertTrue(s.player.isRunning)
        assertEquals("set_browse", s.player.runningTag)
        assertTrue(s.actions("expired").isEmpty(), "the foreign index never corrupts the decision log")
        assertNotNull(s.engine.state.value.lastRunRecord, "the round is still recorded")
    }

    @Test fun assignAndSkipAfterTakeoverNeverTouchTheForeignRun() = runTest {
        val s = stack(songs = 30)
        s.engine.startRound()
        s.player.foreignPlay()
        s.engine.assign(0)
        assertEquals(PuzzleRoundState.Phase.FINISHED, s.engine.currentPhase)
        assertEquals(0, s.engine.currentScore)
        assertEquals(0, s.player.skips)

        val t = stack(songs = 30)
        t.engine.startRound()
        t.player.foreignPlay()
        t.engine.skip()
        assertEquals(PuzzleRoundState.Phase.FINISHED, t.engine.currentPhase)
        assertEquals(0, t.player.skips)
        assertTrue(t.decisions.decisions.isEmpty())
    }

    @Test fun endRound_stopsOnlyItsOwnRun() = runTest {
        val s = stack()
        s.engine.startRound()
        s.engine.endRound()
        assertEquals(1, s.player.stops)
        val t = stack()
        t.engine.startRound()
        t.player.foreignPlay()
        t.engine.endRound()
        assertEquals(0, t.player.stops)
        assertTrue(t.player.isRunning)
    }

    @Test fun advance_skipsOnlyAnOwnedRun() = runTest {
        val s = stack(songs = 30)
        s.engine.startRound()
        s.player.goSilent() // nothing owns the player
        s.engine.skip()
        assertEquals(0, s.player.skips, "no owned run to advance")
        assertEquals(1, s.engine.currentQueueIndex, "the card still advances")
    }

    // ---- top-up ----------------------------------------------------------------------------
    private fun Stack.advanceUntilRemaining(n: Int) {
        while (engine.currentQueue.size - engine.currentQueueIndex > n) engine.skip()
    }

    @Test fun topUpAppendsToQueueAndAudio_whenOwned() = runTest {
        val s = stack(songs = 130)
        s.engine.startRound()
        assertEquals(120, s.engine.currentQueue.size)
        s.advanceUntilRemaining(9)
        s.engine.tickOnce()
        runCurrent()
        assertEquals(130, s.engine.currentQueue.size, "10 left in the pool joined")
        assertEquals(10, s.player.appended.size)
        assertEquals(s.engine.currentQueue.takeLast(10).map { it.id }, s.player.appended.map { it.songId })
        assertEquals(s.engine.currentQueue.map { it.id }.toSet().size, s.engine.currentQueue.size, "no duplicates")
    }

    @Test fun topUpIsSingleFlight() = runTest {
        val gate = CompletableDeferred<Unit>()
        var samples = 0
        val s = stack(songs = 130) { e ->
            val real = e.sampler
            e.sampler = { n, st, i, ex -> if (n == CollectorsPuzzleEngine.TOP_UP_COUNT) { samples++; gate.await() }; real(n, st, i, ex) }
        }
        s.engine.startRound()
        s.advanceUntilRemaining(9)
        repeat(4) { s.engine.tickOnce() }
        runCurrent()
        assertEquals(1, samples)
        gate.complete(Unit)
        runCurrent()
        assertEquals(130, s.engine.currentQueue.size)
    }

    @Test fun topUpRoundGuard_staleRoundMutatesNothing() = runTest {
        val gate = CompletableDeferred<Unit>()
        val s = stack(songs = 130) { e ->
            val real = e.sampler
            e.sampler = { n, st, i, ex -> if (n == CollectorsPuzzleEngine.TOP_UP_COUNT) gate.await(); real(n, st, i, ex) }
        }
        s.engine.startRound()
        s.advanceUntilRemaining(9)
        s.engine.tickOnce()
        runCurrent() // round A's top-up is now suspended in the sampler
        s.engine.endRound()
        s.engine.reset()
        s.engine.startRound() // round B; startRound reset toppingUp
        val roundB = s.engine.currentRoundId
        val queueB = s.engine.currentQueue
        val appendedBefore = s.player.appended.size
        gate.complete(Unit)
        runCurrent()
        assertEquals(roundB, s.engine.currentRoundId)
        assertEquals(queueB, s.engine.currentQueue, "round A's songs never land in round B's queue")
        assertEquals(appendedBefore, s.player.appended.size)
        assertFalse(s.engine.isPoolExhausted)
        // ...and the stale continuation did not clear round B's single-flight flag: B can still top up exactly once
    }

    @Test fun topUpAppendsOnlyWhenOwned() = runTest {
        val gate = CompletableDeferred<Unit>()
        val s = stack(songs = 130) { e ->
            val real = e.sampler
            e.sampler = { n, st, i, ex -> if (n == CollectorsPuzzleEngine.TOP_UP_COUNT) gate.await(); real(n, st, i, ex) }
        }
        s.engine.startRound()
        s.advanceUntilRemaining(9)
        s.engine.tickOnce()
        runCurrent()
        s.player.foreignPlay("set_browse") // someone plays over it while the sample is in flight
        gate.complete(Unit)
        runCurrent()
        assertEquals(130, s.engine.currentQueue.size, "the ROUND queue still grows")
        assertTrue(s.player.appended.isEmpty(), "but the foreign audio queue is never extended")
        s.engine.tickOnce()
        assertEquals(PuzzleRoundState.Phase.FINISHED, s.engine.currentPhase, "the next tick ends the taken-over round")
    }

    @Test fun roundQueueGrowsEvenWhenAudioWasLost() = runTest {
        val s = stack(songs = 130)
        s.engine.startRound()
        s.advanceUntilRemaining(9)
        s.player.goSilent()
        s.engine.tickOnce() // watchdog consumes this tick
        s.engine.tickOnce()
        runCurrent()
        assertEquals(130, s.engine.currentQueue.size)
    }

    @Test fun poolExhausted() = runTest {
        val s = stack(songs = 60)
        s.engine.startRound()
        assertEquals(60, s.engine.currentQueue.size)
        s.advanceUntilRemaining(9)
        s.engine.tickOnce()
        runCurrent()
        assertTrue(s.engine.isPoolExhausted)
        assertEquals(60, s.engine.currentQueue.size)
        val calls = s.player.appended.size
        s.engine.tickOnce()
        runCurrent()
        assertEquals(calls, s.player.appended.size, "an exhausted pool is not re-sampled every tick")
        s.engine.endRound(); s.engine.reset()
        assertFalse(s.engine.isPoolExhausted)
    }

    // ---- audio resolvability -------------------------------------------------------------------
    @Test fun unresolvableSongsAreDroppedBeforeDisplay_andNeverResampled() = runTest {
        val s = stack(songs = 130)
        s.player.unresolvable += (0 until 130 step 2).map { "s$it" }
        s.engine.startRound()
        assertTrue(s.engine.currentQueue.none { it.id in s.player.unresolvable })
        assertEquals(s.engine.currentQueue.map { it.id }, s.player.plays.single().second.map { it.songId })
        s.advanceUntilRemaining(9)
        s.engine.tickOnce()
        runCurrent()
        val ids = s.engine.currentQueue.map { it.id }
        assertTrue(ids.none { it in s.player.unresolvable }, "top-up also drops them")
        assertEquals(ids.toSet().size, ids.size)
    }

    @Test fun allSongsUnresolvable_isTheNoSongsError() = runTest {
        val s = stack(songs = 7)
        s.player.unresolvable += s.env.allSongs.map { it.id }
        s.engine.startRound()
        assertEquals(PuzzleRoundState.Phase.IDLE, s.engine.currentPhase)
        assertEquals("No songs match these settings.", s.engine.currentError)
    }

    // ---- settings --------------------------------------------------------------------------
    @Test fun settingsPruneDeletedCollections() = runTest {
        val blob = PuzzleSettings(
            targetCollectionIds = listOf("pkt_A", "pkt_gone", "pkt_B"),
            membershipCollectionIds = setOf("pkt_C", "pls_gone"),
            membershipMode = PuzzleSettings.MembershipMode.IN_ANY,
        ).toJson()
        val s = stack(persistence = MemoryPersistence(blob))
        // stack() applies updateSettings after construction, so build a bare engine to see the load
        val env = FakeEnv(7)
        val e = CollectorsPuzzleEngine(env, FakeGameRunPlayer(), s.scoreboard, s.decisions, MemoryPersistence(blob), backgroundScope, EmptyCoroutineContext)
        assertEquals(listOf("pkt_A", "pkt_B"), e.currentSettings.targetCollectionIds)
        assertEquals(setOf("pkt_C"), e.currentSettings.membershipCollectionIds)
    }

    @Test fun updateSettingsPersists_andReloads() = runTest {
        val p = MemoryPersistence()
        val s = stack(persistence = p)
        s.engine.updateSettings(s.engine.currentSettings.copy(roundSeconds = 300, yearMin = 1990))
        val env = FakeEnv(7)
        val e2 = CollectorsPuzzleEngine(env, FakeGameRunPlayer(), s.scoreboard, s.decisions, p, backgroundScope, EmptyCoroutineContext)
        assertEquals(300, e2.currentSettings.roundSeconds)
        assertEquals(1990, e2.currentSettings.yearMin)
    }

    @Test fun corruptPersistedSettingsFallBackToDefaults() = runTest {
        val e = CollectorsPuzzleEngine(FakeEnv(3), FakeGameRunPlayer(), GameScoreboardStore(tmp.newFile()),
            PuzzleDecisionStore(tmp.newFile().also { it.delete() }, backgroundScope, EmptyCoroutineContext),
            MemoryPersistence("{not json"), backgroundScope, EmptyCoroutineContext)
        assertEquals(PuzzleSettings(), e.currentSettings)
    }

    @Test fun filedLabelSummarizesTheCollections() {
        assertEquals("Collection", CollectorsPuzzleEngine.filedLabel(emptyList()))
        assertEquals("Crate A", CollectorsPuzzleEngine.filedLabel(listOf("Crate A")))
        assertEquals("Crate A +2 more", CollectorsPuzzleEngine.filedLabel(listOf("Crate A", "B", "C")))
    }

    @Test fun scoringAndFilingCreditConstantsArePinned() {
        assertEquals(1, CollectorsPuzzleEngine.POINTS_PER_FILED_CARD)
        assertEquals(20.0, CollectorsPuzzleEngine.MAX_FILING_CREDIT_SECONDS)
        assertEquals(10.0, CollectorsPuzzleEngine.FILING_CREDIT_PER_EXTRA_TARGET)
        assertEquals(60.0, CollectorsPuzzleEngine.MAX_FILING_CREDIT_CEILING_SECONDS)
        assertEquals(2_500L, CollectorsPuzzleEngine.CLOUD_BUDGET_MS)
    }
}
