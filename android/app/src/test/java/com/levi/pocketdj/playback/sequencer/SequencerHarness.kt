package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.PlaybackMode
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent

/** Shared wiring: every id in [playable] streams; the rest are unmapped (unplayable). */
@OptIn(ExperimentalCoroutinesApi::class)
class SequencerHarness(
    val testScope: TestScope,
    scope: CoroutineScope,
    playable: Set<String>,
    var mode: PlaybackMode = PlaybackMode.CLOUD,
    extra: List<RowSourceResolver> = emptyList(),
    seed: Int = 7,
) {
    val port = FakePlayerPort()
    val resolver = MapResolver("map", Rung.MANIFEST, playable.associateWith { stream(it) })
    val registry = RowResolverRegistry(listOf(resolver) + extra)
    val logs = mutableListOf<String>()
    val seq = SetlistSequencer(
        scope = scope,
        port = port,
        registry = registry,
        modeProvider = { mode },
        random = Random(seed),
        log = { logs += it },
    )

    /** Let every queued coroutine run. */
    fun settle() = testScope.runCurrent()

    val ids: List<String> get() = seq.state.value.queue.map { it.id }
    val index: Int get() = seq.state.value.index
}
