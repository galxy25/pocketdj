package com.levi.pocketdj.di

import com.levi.pocketdj.playback.dj.RemoteSessionProbe
import com.levi.pocketdj.remote.RemoteControllerGate
import com.levi.pocketdj.remote.MixTogetherBlock
import com.levi.pocketdj.remote.RemoteDevice
import com.levi.pocketdj.remote.RemoteReconciler
import com.levi.pocketdj.remote.RemotePlaybackTarget
import com.levi.pocketdj.remote.RemoteSessionController
import com.levi.pocketdj.remote.RemoteSongResolver
import com.levi.pocketdj.remote.SequencerRemoteTarget
import com.levi.pocketdj.remote.SharedClock
import com.levi.pocketdj.shell.FeatureModule
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/**
 * Sidecar graph for the Remote area (P2-REM-5): the app-scoped [RemoteSessionController] and its collaborators.
 * Everything is lazy; [wire] (Main thread, after the sequencer exists) binds the controller to the transport gate
 * (a Backseat controller's local transport forwards to the session) and to DJ Mode's suspension probe.
 */
class RemoteGraph(private val app: AppGraph) : FeatureModule {
    override val area: String = "remote"

    /** The session ticks on Main (the sequencer, the sessions and the Mix decks are Main-confined). */
    private val mainScope: CoroutineScope by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }

    val clock: SharedClock by lazy { SharedClock() }

    val resolver: RemoteSongResolver by lazy {
        RemoteSongResolver.forCatalog(
            songs = { app.catalogRepository.state.value.catalog?.songsById?.values?.toList().orEmpty() },
            revision = { System.identityHashCode(app.catalogRepository.state.value.catalog) },
            appleMusicAvailable = { app.playbackController.isAppleMusicActive },
        )
    }

    /** The local player a speaker session drives. */
    val target: RemotePlaybackTarget by lazy { 
        SequencerRemoteTarget(
            app.playbackGraph.sequencer, mainScope,
            systemPaused = { com.levi.pocketdj.remote.SystemPauseState.isSystemPaused },
        )
    }

    /** "<profile>’s <Build.MODEL>" (iOS `RemoteDevice.name`). */
    fun deviceName(): String =
        RemoteDevice.name(app.studioGraph.profileSource.sourceName, android.os.Build.MODEL ?: "Android")

    val controller: RemoteSessionController by lazy {
        RemoteSessionController(
            target = target, resolver = resolver,
            deviceName = ::deviceName, platform = "android",
            clock = clock, scope = mainScope,
        )
    }

    /** P2-REM-9: the Nearby Connections starter the Remote screen drives. */
    val nearbyStarter: com.levi.pocketdj.remote.NearbyRemoteStarter by lazy {
        com.levi.pocketdj.remote.NearbyRemoteStarter(app.appContext, controller, mainScope, ::deviceName)
    }

    /** The configured jukebox server (url, account token), kept hot so the broker starter can answer `available` synchronously. */
    val brokerServer: StateFlow<Pair<String, String>> by lazy {
        app.settings.settings.map { it.jukeboxServerUrl.trim() to it.jukeboxToken }
            .stateIn(mainScope, SharingStarted.Eagerly, "" to "")
    }

    /** P2-REM-10: the optional "Over the internet" starter (jukebox server `/remote` relay); offered only when a server URL is set. */
    val brokerStarter: com.levi.pocketdj.remote.BrokerRemoteStarter by lazy {
        com.levi.pocketdj.remote.BrokerRemoteStarter(
            controller, mainScope,
            com.levi.pocketdj.remote.BrokerApi(app.httpClient, { brokerServer.value.first }, { brokerServer.value.second }),
            serverConfigured = { brokerServer.value.first.isNotBlank() }, deviceName = ::deviceName,
        )
    }

    /** DJ Mode's suspension input: a session is attached. */
    val probe: RemoteSessionProbe by lazy {
        object : RemoteSessionProbe {
            override val active: Boolean get() = controller.isActive.value
            override val activeFlow: StateFlow<Boolean> get() = controller.isActive
        }
    }

    private var mixSyncRef: com.levi.pocketdj.remote.mix.MixSync? = null

    /** The Mix Together driver (P2-REM-13). Main thread; built the first time a session needs it (builds the Mix graph). */
    val mixSync: com.levi.pocketdj.remote.mix.MixSync
        get() = mixSyncRef ?: buildMixSync().also { mixSyncRef = it }

    /** The driver if a session already built it; never constructs it. */
    val mixSyncIfBuilt: com.levi.pocketdj.remote.mix.MixSync? get() = mixSyncRef

    private fun buildMixSync(): com.levi.pocketdj.remote.mix.MixSync {
        val mix = app.mixGraph
        return com.levi.pocketdj.remote.mix.MixSync(
            session = com.levi.pocketdj.remote.mix.RemoteControllerMixSession(controller),
            clock = com.levi.pocketdj.remote.mix.ControllerClockPort(controller),
            engine = com.levi.pocketdj.remote.mix.MixEnginePort(mix.mixEngine),
            resolve = com.levi.pocketdj.remote.mix.MixTogetherInstaller.resolver(
                loadables = { ids -> mix.mixResolver.loadables(ids) },
                resolve = { row -> resolver.resolve(row) },
            ),
            appleMusicIdForSong = { id -> resolver.appleMusicIdForSong(id) },
            onMixStarted = { controller.send(com.levi.pocketdj.remote.RemoteCommand.SetPlaying(false)) },
            logSink = { com.levi.pocketdj.diag.NPLog.lane(com.levi.pocketdj.diag.NPLog.REMOTE, it) },
            scope = mainScope,
        )
    }

    private var wired = false

    /** Bind the gate + DJ Mode probe. Idempotent; Main thread, after the playback wire. */
    fun wire() {
        if (wired) return
        wired = true
        com.levi.pocketdj.screens.remote.RemoteStarters.current = nearbyStarter // P2-REM-9
        val gate = RemoteControllerGate.shared
        gate.isController = { controller.isActive.value && controller.localRole.value == com.levi.pocketdj.remote.RemoteDeviceRole.CONTROLLER }
        gate.forwarder = { controller.interceptLocalTransport(it) }
        app.playbackGraph.djMode.bindRemote(probe)
        // The speaker half (P2-REM-6): reconcile + drift + local-change diffing.
        RemoteReconciler.bind(controller, target, clock)
        // A controller keeps EVERY local audio engine silent (the Mix decks, the NP DSP host), re-asserted each tick.
        // Never constructs the Mix graph: a controller-only user who never opens Mix pays nothing per tick. Main thread (the tick).
        controller.registerControllerSilencer { app.mixGraphIfBuilt?.silenceForRemoteController() }
        // Mixing together owns the decks: a running Auto-DJ ends and a new one is refused.
        MixTogetherBlock.onChanged = { app.mixGraph.autoDj.onAutoBlocked() }
        // P2-REM-13: Mix Together (hello caps ["mix"], mix.* routing, live-mix election activity, the 250 ms tick), behind ParityFlags.MIX_TOGETHER.
        com.levi.pocketdj.remote.mix.MixTogetherInstaller.install(controller, build = { mixSync }, ifBuilt = { mixSyncIfBuilt })
    }
}
