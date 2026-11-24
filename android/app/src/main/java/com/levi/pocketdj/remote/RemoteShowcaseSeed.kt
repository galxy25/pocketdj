package com.levi.pocketdj.remote

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * DEBUG-only store-screenshot seed (`adb shell am start -n com.levi.pocketdj/.MainActivity --es pdj.seedRemote showcase`):
 * this device becomes the Backseat controller of an in-memory session whose "Car" speaker is already playing a showcase
 * set 1:37 into track 1, so the Remote half can be captured with ONE physical device. Nothing here is reachable from a
 * release build ([wanted] requires a debuggable app).
 */
object RemoteShowcaseSeed {
    const val EXTRA = "pdj.seedRemote"
    const val VALUE = "showcase"
    const val SET_SIZE = 6
    const val POSITION_MS = 97_000L // 1:37
    const val CAR_NAME = "Car"

    /** The seed runs only for `pdj.seedRemote=showcase` on a debuggable build. */
    fun wanted(extra: String?, debuggable: Boolean): Boolean = debuggable && extra == VALUE

    /** The showcase set: the first [SET_SIZE] catalog songs, or titled placeholders when the catalog hasn't loaded. */
    fun rows(songs: List<IndexSong>): List<RemoteRow> {
        val picked = songs.take(SET_SIZE)
        if (picked.isNotEmpty()) {
            return picked.map { s ->
                RemoteRow("r-${s.id}", SessionRow(songId = s.id, title = s.name, artist = s.artist, lengthMs = s.length ?: 210_000))
            }
        }
        return PLACEHOLDERS.mapIndexed { i, (title, artist) ->
            RemoteRow("r-showcase-$i", SessionRow(songId = "showcase-$i", title = title, artist = artist, lengthMs = 210_000))
        }
    }

    /** The host's starting model: track 1 playing, [POSITION_MS] in, anchored at [nowMs]. */
    fun model(songs: List<IndexSong>, nowMs: Double): RemoteQueueModel =
        RemoteQueueModel(rows = rows(songs), index = 0, isPlaying = true, positionMs = POSITION_MS, anchor = nowMs, revision = 1, sourceName = "Showcase set")

    private val PLACEHOLDERS = listOf(
        "Midnight Drive" to "The Showcase Band", "Golden Hour" to "The Showcase Band", "Open Road" to "Sample Artist",
        "City Lights" to "Sample Artist", "Slow Burn" to "Demo Duo", "After Hours" to "Demo Duo",
    )

    /** A running seed: the loopback hub and the in-memory Car speaker. */
    class Rig internal constructor(val hub: LoopbackHub, val car: RemoteSessionController, val carTarget: InMemoryRemoteTarget) {
        fun stop() {
            runCatching { car.leave() }
            runCatching { hub.end() }
        }
    }

    @Volatile private var rig: Rig? = null

    /** True while the seed's session exists (the hub shows the Remote half regardless of [com.levi.pocketdj.ParityFlags.REMOTE]). */
    val isRunning: Boolean get() = rig != null

    private val _running = MutableStateFlow(false)

    /** Observable [isRunning], so Compose recomposes the hub when the seed starts or stops. */
    val running: StateFlow<Boolean> get() = _running

    /**
     * Attach [controller] (this device) as the Backseat host/controller and a fresh "Car" speaker as the joiner.
     * Idempotent: a second call while the first rig is alive does nothing.
     */
    @Synchronized
    fun start(controller: RemoteSessionController, songs: List<IndexSong>, scope: CoroutineScope = defaultScope()): Rig {
        rig?.let { return it }
        val hub = LoopbackHub()
        val carTarget = InMemoryRemoteTarget()
        val carClock = SharedClock()
        val car = RemoteSessionController(
            target = carTarget, resolver = RemoteSongResolver(catalogItem = { QueueItem(id = it) }),
            deviceName = { CAR_NAME }, platform = "android", clock = carClock, scope = scope,
        )
        car.speaker = RemoteReconciler(car, carTarget, carClock)
        val local = hub.join("a-this-phone")
        val carLink = hub.join("b-car")
        controller.attach(local, RemoteSessionMode.BACKSEAT, asHost = true, seed = model(songs, System.currentTimeMillis().toDouble()))
        car.attach(carLink, RemoteSessionMode.BACKSEAT, asHost = false)
        return Rig(hub, car, carTarget).also { rig = it; _running.value = true }
    }

    @Synchronized fun stop() { rig?.stop(); rig = null; _running.value = false }

    private fun defaultScope() = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
}
