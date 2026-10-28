package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.games.GameKind
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.pockets.NoPocketsBridge
import com.levi.pocketdj.data.pockets.PocketsBridge
import com.levi.pocketdj.data.pockets.PocketsCredentials
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import com.levi.pocketdj.playback.FakeGameRunPlayer
import com.levi.pocketdj.playback.PlayContext
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Port of InThePocketStoreTests.swift: the app-scoped store end to end with no app graph - build
 * (scorer over a tiny catalog + history) -> start (FakeGameRunPlayer gets the round under its run
 * tag) -> the REAL history log's verdicts -> finalize (scoreboard run, upload row, change hook).
 */
class InThePocketStoreTest {
    private lateinit var dir: File
    private val fake = FakeGameRunPlayer()
    private var changes = 0
    private var clockMs = 1_791_945_000_000.0

    @Before fun setUp() { dir = java.nio.file.Files.createTempDirectory("itp-store").toFile() }
    @After fun tearDown() { dir.deleteRecursively() }

    private class Env(
        val store: InThePocketStore, val history: PlayHistoryStore, val scores: GameScoreboardStore, val file: File,
    )

    private fun makeEnv(
        file: File = File(dir, "rounds.json"), history: PlayHistoryStore? = null,
        bridgeProvider: (() -> PocketsBridge)? = null,
    ): Env {
        val h = history ?: PlayHistoryStore(File(dir, "history.json"))
        val scores = GameScoreboardStore(File(dir, "scores.json"))
        val store = InThePocketStore(
            history = h, scoreboard = scores, player = fake, file = file, bridgeFixed = NoPocketsBridge, bridgeProvider = bridgeProvider,
            scope = CoroutineScope(Dispatchers.Unconfined), buildDispatcher = Dispatchers.Unconfined,
            asyncPersist = false,
        )
        store.tickerEnabled = false
        store.now = { clockMs }
        val songs = (1..6).associate {
            val id = "sng_00000000000$it"
            id to IndexSong(id = id, name = "Song $it", artist = "Ada", appleMusicId = "10$it")
        }
        store.catalogSnapshot = { songs to emptyMap() }
        store.audioAvailability = { InThePocketAudio(canStreamAppleMusic = true) }
        store.appVersion = "9.9"
        store.onRoundsChanged = { changes++ }
        return Env(store, h, scores, file)
    }

    private fun seedHistory(env: Env) {
        listOf("sng_000000000001", "sng_000000000002").forEachIndexed { i, id ->
            val ev = env.history.record(
                id, artist = "Ada", context = PlayContext.BROWSER,
                nowMs = (clockMs - 4 * 86_400_000 + i * 300_000).toLong(),
            )!!
            env.history.noteListened(ev.id, 1.0)
        }
    }

    private fun builtRound(env: Env, seed: ULong = 3u): InThePocketRound = runBlocking {
        seedHistory(env)
        env.store.buildRound(seed)
        env.store.current ?: error("no round: ${env.store.buildState}")
    }

    private fun playSong(env: Env, r: InThePocketRound, i: Int, minutes: Double): PlayEvent =
        env.history.record(
            r.songs[i].id, r.songs[i].title, r.songs[i].artist,
            PlayContext.game(InThePocketStore.runTag(r.id), "In the Pocket"),
            nowMs = (r.startedAtMs!! + minutes * 60_000).toLong(),
        )!!

    @Test fun buildStartTrackFinalize() {
        val env = makeEnv()
        val built = builtRound(env)
        assertEquals("no cloud results => a three-song round", 3, built.songs.size)
        assertTrue(built.mode == InThePocketMode.HISTORY || built.mode == InThePocketMode.COLD)
        assertEquals("3", built.seed)
        assertEquals(1, built.algoVersion)
        assertEquals("9.9", built.appVersion)
        assertNull(built.startedAtMs)

        env.store.start()
        assertEquals(1, fake.plays.size)
        assertEquals(InThePocketStore.runTag(built.id), fake.plays[0].first)
        assertEquals(built.songs.map { it.id }, fake.plays[0].second.map { it.songId })
        val round = env.store.current!!
        assertNotNull(env.store.activeRound)
        assertEquals(clockMs, round.startedAtMs!!, 0.0)
        assertEquals(clockMs, round.updatedAtMs, 0.0)

        val e0 = playSong(env, round, 0, 0.1)
        clockMs = round.startedAtMs!! + 60_000
        env.store.evaluate()
        assertEquals(0, env.store.currentSongIndex)
        assertEquals(
            listOf(InThePocketSongState.PLAYING, InThePocketSongState.PENDING, InThePocketSongState.PENDING),
            env.store.current!!.songs.map { it.state },
        )

        env.history.noteListened(e0.id, 1.0)
        playSong(env, round, 1, 4.0)
        val e2 = playSong(env, round, 2, 8.0)
        clockMs = round.startedAtMs!! + 9 * 60_000
        env.store.evaluate()
        assertNull(env.store.current!!.outcome)
        assertTrue("an unfinished round never uploads", env.store.uploadWires("I").isEmpty())

        env.history.noteListened(e2.id, 0.96)
        env.store.evaluate()
        val done = env.store.current!!
        assertEquals(InThePocketOutcome.Pocket, done.outcome)
        assertTrue(done.songs.all { it.state == InThePocketSongState.COMPLETED })
        assertNull(env.store.activeRound)
        assertEquals("a finished round asks for an upload", 1, changes)
        val run = env.scores.recentRuns(GameKind.InThePocket, 1).first()
        assertEquals(3, run.score)
        assertEquals("pocket", run.detail?.get("outcome"))
        assertEquals(done.id.toString().uppercase(), run.detail?.get("roundId"))
        assertEquals("3", run.detail?.get("songs"))
        assertEquals(env.store.chips(done).joinToString(" · "), run.settingsSummary)
        assertEquals(1, env.scores.inThePocketStats().pockets)
        val wires = env.store.uploadWires("INSTALL")
        assertEquals(1, wires.size)
        assertEquals("pocket", wires[0].outcome)
        assertEquals(listOf("completed", "completed", "completed"), wires[0].songs.map { it.outcome })
        assertEquals("coarse time on the wire", 0L, wires[0].startedAtMs % 60_000)
        // Evaluating again changes nothing (no second scoreboard row).
        env.store.evaluate()
        assertEquals(1, env.scores.recentRuns(GameKind.InThePocket, 5).size)
        assertEquals(1, changes)
    }

    @Test fun skipBreaksTheRoundAndRecordsIt() {
        val env = makeEnv()
        builtRound(env)
        env.store.start()
        val round = env.store.current!!
        val e0 = playSong(env, round, 0, 0.1)
        env.history.markSkipped(e0.id)
        playSong(env, round, 1, 1.0)
        clockMs = round.startedAtMs!! + 1.1 * 60_000
        env.store.evaluate()
        assertEquals(InThePocketOutcome.Broke(1), env.store.current!!.outcome)
        assertEquals("broke", env.scores.recentRuns(GameKind.InThePocket, 1).first().detail?.get("outcome"))
        assertEquals(1, env.store.uploadWires("I").first().brokeAt)
    }

    @Test fun endRoundAndTakeoverAbandon() {
        val env = makeEnv()
        builtRound(env)
        env.store.start()
        val round = env.store.current!!
        val e0 = playSong(env, round, 0, 0.1)
        env.history.noteListened(e0.id, 0.2)
        clockMs = round.startedAtMs!! + 60_000
        env.store.endActiveRound()
        assertEquals(InThePocketOutcome.Abandoned, env.store.current!!.outcome)
        assertEquals(
            listOf(InThePocketSongState.PLAYING, InThePocketSongState.NOT_PLAYED, InThePocketSongState.NOT_PLAYED),
            env.store.current!!.songs.map { it.state },
        )
        assertEquals("partial", env.store.uploadWires("I").first().songs.first().outcome)

        // A second round taken over by another surface (the sequencer runs something else).
        env.store.dismissCurrent()
        runBlocking { env.store.buildRound(11u) }
        env.store.start()
        val r2 = env.store.current!!
        fake.foreignPlay()
        clockMs = r2.startedAtMs!! + 1_000
        env.store.evaluate() // first sight of the loss: settling
        assertNull(env.store.current!!.outcome)
        clockMs += InThePocketRoundEvaluator.SETTLE_MS
        env.store.evaluate()
        assertEquals(InThePocketOutcome.Abandoned, env.store.current!!.outcome)
    }

    @Test fun feedbackIsCappedSavedAndAFinishedRoundsEditAsksForUpload() {
        val env = makeEnv()
        builtRound(env)
        env.store.start()
        val id = env.store.currentRoundId!!
        env.store.saveFeedback(id, "  " + "é".repeat(2500) + "  ", 9)
        val r = env.store.current!!
        assertEquals(InThePocketRound.MAX_FEEDBACK_CHARS, r.feedback?.length)
        assertNull("out-of-range rating is dropped", r.rating)
        assertEquals("during the round nothing uploads yet", 0, changes)
        env.store.endActiveRound()
        assertEquals(1, changes)
        val before = env.store.current!!.updatedAtMs
        env.store.saveFeedback(id, "funkier please", 4)
        assertEquals("a finished round's edit re-uploads", 2, changes)
        assertTrue(env.store.current!!.updatedAtMs > before)
        env.store.saveFeedback(id, "funkier please  ", 4)
        assertEquals("no change, no upload", 2, changes)
        assertEquals("funkier please", env.store.uploadWires("I").first().feedback)
        assertEquals(4, env.store.uploadWires("I").first().rating)
    }

    @Test fun updatedAtIsMonotonicEvenWithAFrozenClock() {
        val env = makeEnv()
        builtRound(env)
        env.store.start()
        val id = env.store.currentRoundId!!
        env.store.saveFeedback(id, "a", null)
        val first = env.store.current!!.updatedAtMs
        env.store.saveFeedback(id, "b", null) // same clock reading
        assertTrue(env.store.current!!.updatedAtMs > first)
    }

    @Test fun roundsPersistAcrossRelaunchTrackingResumesAndClearLocalDeletesTheFile() {
        val env = makeEnv()
        builtRound(env)
        env.store.start()
        val id = env.store.currentRoundId!!
        val relaunched = makeEnv(env.file, env.history)
        assertEquals(id, relaunched.store.currentRoundId)
        assertNotNull("a playing round is still active after a relaunch", relaunched.store.activeRound)
        assertTrue(env.file.exists())
        relaunched.store.clearLocal()
        assertTrue(relaunched.store.rounds.isEmpty())
        assertFalse(env.file.exists())
    }

    @Test fun buildFailsGracefullyWithNothingPlayable() {
        val env = makeEnv()
        env.store.audioAvailability = { InThePocketAudio() }
        runBlocking { env.store.buildRound(1u) }
        assertNull(env.store.current)
        val st = env.store.buildState
        assertTrue(st is InThePocketStore.BuildState.Failed)
        assertTrue((st as InThePocketStore.BuildState.Failed).message.startsWith("Nothing can play right now"))
    }

    @Test fun notEnoughCandidatesMessage() {
        val env = makeEnv()
        env.store.catalogSnapshot = {
            mapOf("sng_000000000001" to IndexSong(id = "sng_000000000001", name = "Only", artist = "Ada", appleMusicId = "1")) to emptyMap()
        }
        runBlocking { env.store.buildRound(1u) }
        val st = env.store.buildState as InThePocketStore.BuildState.Failed
        assertTrue(st.message.startsWith("Not enough fresh, playable songs"))
    }

    @Test fun buildReplacesAnUnstartedRound() {
        val env = makeEnv()
        val first = builtRound(env, 3u)
        runBlocking { env.store.buildRound(99u) }
        val second = env.store.current!!
        assertTrue(first.id != second.id)
        assertEquals("the unstarted round is replaced, not kept", 1, env.store.rounds.size)
        assertEquals("99", second.seed)
        assertEquals(InThePocketStore.BuildState.Idle, env.store.buildState)
    }

    @Test fun buildIsRefusedWhileARoundIsActive() {
        val env = makeEnv()
        val first = builtRound(env)
        env.store.start()
        runBlocking { env.store.buildRound(5u) }
        assertEquals(first.id, env.store.currentRoundId)
        assertEquals(1, env.store.rounds.size)
    }

    @Test fun startIsIgnoredWhenAlreadyStarted() {
        val env = makeEnv()
        builtRound(env)
        env.store.start()
        env.store.start()
        assertEquals(1, fake.plays.size)
    }

    @Test fun roundCarriesBpmTargetAndChipsAreRebuiltAfterRelaunch() {
        val env = makeEnv()
        val r = builtRound(env)
        val chips = env.store.chips(r)
        assertEquals(r.context.timePhrase, chips.first())
        val relaunched = makeEnv(env.file, env.history)
        val rebuilt = relaunched.store.chips(relaunched.store.current!!)
        assertEquals(r.context.timePhrase, rebuilt.first())
        r.targets.firstOrNull { it.dim == "bpm" }?.let { assertTrue(rebuilt.contains(it.label)) }
    }

    @Test fun trimKeepsActiveAndCurrentDroppingTheOldest() {
        val rounds = (0 until 305).map { i ->
            TestRounds.round(listOf("a$i"), InThePocketOutcome.Pocket)
        }.toMutableList()
        val active = TestRounds.round(listOf("act"), null)
        rounds[0] = active
        val current = rounds[1]
        val kept = InThePocketStore.trim(rounds, current.id)
        assertEquals(InThePocketStore.MAX_ROUNDS, kept.size)
        assertTrue("the oldest round is active, so it survives", kept.any { it.id == active.id })
        assertTrue(kept.any { it.id == current.id })
        assertFalse("oldest finished non-current rounds go first", kept.any { it.id == rounds[2].id })
        assertTrue(kept.any { it.id == rounds.last().id })
        assertEquals(rounds.size, InThePocketStore.trim(rounds.take(300), null).size + 5)
    }

    @Test fun uploadWiresReturnsFinishedRoundsOnly() {
        val env = makeEnv()
        val doc = InThePocketStore.Document(
            rounds = listOf(
                TestRounds.round(listOf("a", "b", "c"), InThePocketOutcome.Pocket),
                TestRounds.round(listOf("d", "e", "f"), null),
                TestRounds.round(listOf("g", "h", "i"), InThePocketOutcome.Broke(2)),
            ),
        )
        val file = File(dir, "wires.json")
        file.writeText(kotlinx.serialization.json.Json { encodeDefaults = true }.encodeToString(InThePocketStore.Document.serializer(), doc))
        val s = makeEnv(file, env.history).store
        assertEquals(listOf("pocket", "broke"), s.uploadWires("I").map { it.outcome })
        assertEquals(listOf(null, 2), s.uploadWires("I").map { it.brokeAt })
    }

    @Test fun documentDecodeDropsOneUnreadableRoundNotTheRest() {
        val good = TestRounds.round(listOf("a", "b", "c"), InThePocketOutcome.Pocket)
        val enc = kotlinx.serialization.json.Json { encodeDefaults = true }
        val goodJson = enc.encodeToString(InThePocketRound.serializer(), good)
        val text = """{"schemaVersion":2,"currentRoundId":"${good.id.toString().uppercase()}",
            "rounds":[{"id":"not-a-uuid"},$goodJson,17]}"""
        val doc = InThePocketStore.decodeDocument(text)!!
        assertEquals(2, doc.schemaVersion)
        assertEquals(listOf(good.id), doc.rounds.map { it.id })
        assertEquals(good.id, doc.currentRoundId)
        assertNull(InThePocketStore.decodeDocument("[1,2]"))
        assertNull(InThePocketStore.decodeDocument("garbage"))
    }

    @Test fun runTagUsesTheUppercaseUuid() {
        val id = UUID.fromString("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")
        assertEquals("itp_0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", InThePocketStore.runTag(id))
    }

    @Test fun bridgeRoundsProviderIsWiredToUploadWires() {
        val env = makeEnv()
        assertNotNull(NoPocketsBridge.roundsProvider)
        assertTrue(NoPocketsBridge.roundsProvider!!.invoke("I").isEmpty())
        assertEquals(env.store.uploadWires("I"), NoPocketsBridge.roundsProvider!!.invoke("I"))
    }

    private class CountingBridge : PocketsBridge {
        var enabledReads = 0
        override val isEnabled: StateFlow<Boolean> = object : StateFlow<Boolean> {
            private val inner = MutableStateFlow(false)
            override val replayCache get() = inner.replayCache
            override val value: Boolean get() { enabledReads++; return false }
            override suspend fun collect(collector: kotlinx.coroutines.flow.FlowCollector<Boolean>): Nothing = inner.collect(collector)
        }
        override val results: StateFlow<ListeningPocketsResults?> = MutableStateFlow(null)
        override suspend fun refreshIfStale() = Unit
        override fun flushSoon() = Unit
        override var roundsProvider: ((String) -> List<InThePocketRoundWire>)? = null
        override suspend fun credentials(): PocketsCredentials? = null
        override val installId: String = "X"
    }

    @Test fun bridgeAssignedAfterConstructionIsTheOneTheBuildConsults() {
        var live: PocketsBridge = NoPocketsBridge
        val late = CountingBridge()
        val env = makeEnv(bridgeProvider = { live })
        live = late // the services wave assigns its bridge after the store exists
        builtRound(env)
        assertTrue("privacy gate read the LATE bridge", late.enabledReads > 0)
    }

    @Test fun anyBuildExceptionFailsTheBuildInsteadOfWedgingBuilding() {
        val env = makeEnv()
        seedHistory(env)
        var boom = true
        env.store.audioAvailability = { if (boom) throw IllegalStateException("io") else InThePocketAudio(canStreamAppleMusic = true) }
        runBlocking { env.store.buildRound(3u) }
        assertTrue(env.store.buildState is InThePocketStore.BuildState.Failed)
        boom = false
        runBlocking { env.store.buildRound(3u) }
        assertNotNull("a later build is not refused", env.store.current)
    }

    @Test fun restoredRoundSurvivesWhenThePlayerOnlyKnowsTheRestoredTag() {
        val env = makeEnv()
        builtRound(env)
        env.store.start()
        val round = env.store.current!!
        val relaunched = makeEnv(env.file, env.history)
        // Process restart: the restored sequencer session is the itp_ run; nothing else is known.
        fake.foreignPlay(InThePocketStore.runTag(round.id))
        clockMs = round.startedAtMs!! + 1_000
        relaunched.store.evaluate()
        clockMs += InThePocketRoundEvaluator.SETTLE_MS * 3
        relaunched.store.evaluate()
        assertNull("still the game's queue: not abandoned", relaunched.store.current!!.outcome)
    }

    @Test fun clearLocalDuringABuildDropsTheBuildResult() {
        val env = makeEnv()
        seedHistory(env)
        env.store.collectionsInput = { env.store.clearLocal(); emptyList() }
        runBlocking { env.store.buildRound(3u) }
        assertTrue(env.store.rounds.isEmpty())
        assertFalse(env.file.exists())
    }
}
