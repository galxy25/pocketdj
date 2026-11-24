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
import kotlinx.coroutines.flow.StateFlow

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

    /** DJ Mode's suspension input: a session is attached. */
    val probe: RemoteSessionProbe by lazy {
        object : RemoteSessionProbe {
            override val active: Boolean get() = controller.isActive.value
            override val activeFlow: StateFlow<Boolean> get() = controller.isActive
        }
    }

    private var wired = false

    /** Bind the gate + DJ Mode probe. Idempotent; Main thread, after the playback wire. */
    fun wire() {
        if (wired) return
        wired = true
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
    }
}
