package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.playback.sequencer.SequencerHarness
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher

/** A real sequencer + session store + writer, the writer fed by every published state. */
@OptIn(ExperimentalCoroutinesApi::class)
class DurableHarness(val scope: TestScope, dir: File, vararg playable: String) {
    val h = SequencerHarness(scope, scope.backgroundScope, playable.toSet())
    val seq get() = h.seq
    var clockMs = 1_000_000L
    var pos = 0L
    var playing = false
    var heldPos: Long? = null
    val file = File(dir, PLAYBACK_SESSION_FILE)
    val diskWriter = VersionedJsonWriter(file)
    val store = PlaybackSessionStore(file, diskWriter, clock = { clockMs })
    val writer = SessionWriter(
        store = store,
        position = { pos },
        isPlaying = { playing },
        heldOffset = { seq.resumeOffsetMs },
    )

    fun observe() {
        scope.backgroundScope.launch(UnconfinedTestDispatcher(scope.testScheduler)) {
            seq.state.collect { writer.onState(it) }
        }
    }

    fun snapshotOnDisk() = store.load()
}
