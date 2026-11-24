package com.levi.pocketdj.playback.npmix

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.nowplaying.NetworkClass
import com.levi.pocketdj.mix.nowplaying.NpMixSettings
import com.levi.pocketdj.mix.nowplaying.npMixSettingsFlow
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.PlaybackPrefKeys
import com.levi.pocketdj.playback.health.RunwayLock
import com.levi.pocketdj.screens.nowplaying.NowPlayingSeams
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Production assembly of Now Playing Mix Mode (P2-MM-5): the [NpMixCoordinator] (sequencer listener + durable
 * `npMixMode` extra), the [SwapOnLand.Runner] and their seams onto the controller, the sequencer, the DSP host and
 * the download lane. Lives in the playback graph (`app.playbackGraph.npMix`); [install] is called once from
 * `PlaybackGraph.wire()` and registers nothing that arms before a session exists.
 */
class NpMixWiring(private val app: AppGraph) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private val seq get() = app.playbackGraph.sequencer
    private val controller get() = app.playbackController

    @Volatile private var settingsMirror = NpMixSettings()
    @Volatile private var deviceModeMirror = false

    /** The settings snapshot (Settings flows into it; the lane reads it synchronously on Main). */
    fun settings(): NpMixSettings = settingsMirror

    /** Mix Mode planned the lane at the last re-plan: the one that must run again to take its steps OFF the lane. */
    private var lanePlannedForMix = false

    private val ports = object : NpMixCoordinator.Ports {
        override fun settings() = settingsMirror
        override val mixTabActive: Boolean get() = NowPlayingSeams.mixSessionActive
        override val deviceMode: Boolean get() = deviceModeMirror
        override val running: Boolean get() = seq.isRunning
        override val held: Boolean get() = seq.isHeldForResume
        override val sessionId: String? get() = seq.sessionId
        override val currentSongId: String? get() = seq.currentSongId
        override val currentUid: String? get() = seq.state.value.current?.uid

        override fun currentAndNextResolveIds(): List<String> {
            val st = seq.state.value
            if (!st.isRunning) return emptyList()
            return st.queue.drop(st.index).take(2).map { it.resolveId }
        }

        override fun replanLane() {
            // Idle and never planned for Mix Mode: nothing to do (the Stem Lock re-plans through its own paths).
            val buffering = coordinator.buffering
            if (!buffering && !lanePlannedForMix) return
            lanePlannedForMix = buffering
            app.mixGraph.replanStemLock()
        }

        override fun persist() = seq.sessionExtras.notifyChanged()
        override fun onModeOff() = app.servicesGraph.storageManager.scheduleCapSweepIfNeeded()
        override fun post(block: () -> Unit) { handler.post(block) }
    }

    private val env = object : SwapOnLand.Env {
        override suspend fun facts(): SwapOnLand.Facts? {
            val st = seq.state.value
            val item = st.current ?: return null
            val playing = controller.handOffPlaying()
            // The file lookup touches the disk: off-main, and only when there is a stream to hand off.
            val target = if (playing != null && !playing.isFile) {
                withContext(Dispatchers.IO) { controller.localFiles.localUrlForPlayback(item) }?.let {
                    SwapOnLand.Target(it.url, it.startMs, it.endMs, item.resolveId)
                }
            } else null
            val d = seq.discriminator
            return SwapOnLand.Facts(
                mixEnabled = coordinator.enabled,
                running = st.isRunning,
                held = st.isHeldForResume,
                dspEngaged = app.mixGraph.npDspEngine.let { it.isEngaged && it.engagedSongId == item.id },
                mixTabActive = NowPlayingSeams.mixSessionActive,
                pausedByCascade = seq.isPausedByCascade,
                appleMusicActive = controller.isAppleMusicActive,
                startPending = seq.isStartPending,
                rowUid = item.uid,
                rowId = item.id,
                rowResolveId = item.resolveId,
                rowLengthMs = item.lengthMs,
                generation = st.playGeneration,
                playing = playing,
                target = target,
                interruptionOpen = d.interruptionOpen,
                listenerPaused = d.pausedByListener,
                intentPlaying = d.intentPlaying,
                enginePlayWhenReady = controller.enginePlayWhenReady(),
            )
        }

        override val lockCarriesStems: Boolean get() = app.mixGraph.stemLockSession.current.wantsStems
        override suspend fun engageDsp(songId: String, atMs: Long) = app.mixGraph.npDspHost.engageForHandOff(songId, atMs)
        override fun replan() = coordinator.scheduleReplan()
        override val runwayLock: RunwayLock? get() = seq.runwayLock
        override fun log(line: String) = SwapOnLand.laneLog(line)
    }

    private val engine = object : SwapOnLand.Engine {
        override suspend fun reload(songId: String, url: String, clipStartMs: Long?, clipEndMs: Long?, atMs: Long) =
            controller.swapCurrentItem(songId, url, clipStartMs, clipEndMs, atMs)

        override suspend fun awaitAudio(timeoutMs: Long) = controller.awaitHandOffAudio(timeoutMs)
    }

    val runner = SwapOnLand.Runner(env, engine, scope)

    val coordinator: NpMixCoordinator = NpMixCoordinator(
        ports,
        object : NpMixCoordinator.HandOff {
            override fun attempt(reason: String) { scope.launch { runner.attempt(reason) } }
            override fun retryOwed(trigger: String) { scope.launch { runner.retryOwed(trigger, ports.currentUid) } }
            override fun rowChanged(currentUid: String?) = runner.rowChanged(currentUid)
            override fun sessionEnded() = runner.sessionEnded()
        },
    )

    private var installed = false

    /** Register on the sequencer and observe the settings / Mix tab / network. Idempotent; main thread. */
    fun install() {
        if (installed) return
        installed = true
        seq.hooks.add(coordinator)
        seq.sessionExtras.register(coordinator)
        // A swap-on-land local file that fails reverts once onto the stream (the sequencer advances on a second failure).
        controller.handOffFailed = { songId, url, pos ->
            val st = seq.state.value
            runner.onFailed(st.current?.uid, songId, url, pos)
        }
        scope.launch {
            app.settings.npMixSettingsFlow().collect { settingsMirror = it; coordinator.scheduleReplan() }
        }
        scope.launch {
            app.settings.flow(PlaybackPrefKeys.PLAYBACK_MODE).collect {
                deviceModeMirror = PlaybackMode.fromToken(it) == PlaybackMode.DEVICE
                coordinator.scheduleReplan()
            }
        }
        // Mix Mode is SUSPENDED while the Mix tab runs and retries an owed hand-off when it goes idle again.
        scope.launch {
            NowPlayingSeams.mixSessionActiveFlow.collect { coordinator.onMixTabChanged(it) }
        }
        runCatching { registerNetworkWatch() }
        if (com.levi.pocketdj.BuildConfig.DEBUG) runCatching { registerDebugReceiver() }
    }

    private fun registerNetworkWatch() {
        val cm = app.appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        var last = NetworkClass.current(cm)
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            private fun changed() {
                val now = NetworkClass.current(cm)
                if (now == last) return
                last = now
                handler.post { coordinator.onNetworkChanged(now.raw) }
            }
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = changed()
        })
    }

    /** DEBUG builds only: `adb shell am broadcast -a com.levi.pocketdj.DEBUG --es npmix on|off|toggle`. */
    private fun registerDebugReceiver() {
        ContextCompat.registerReceiver(
            app.appContext,
            object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    // `--es playsong sng_x`: play one song alone (emulator verification of lone-song windows).
                    i?.getStringExtra("playsong")?.let { id ->
                        scope.launch { controller.playQueue(listOf(com.levi.pocketdj.playback.QueuePlan.QueueEntry(id))) }
                    }
                    // `--es palette id1,id2`: first palette assignment through the store (P2-POC-4 emulator step).
                    i?.getStringExtra("palette")?.let { ids ->
                        scope.launch(Dispatchers.IO) {
                            val ok = app.servicesGraph.pocketPalette.assign(ids.split(','), nowMs = System.currentTimeMillis().toDouble())
                            com.levi.pocketdj.diag.NPLog.lane(com.levi.pocketdj.diag.NPLog.PLAYBACK, "palette assign changed=$ok")
                        }
                    }
                    when (i?.getStringExtra("npmix")) {
                        "on" -> coordinator.setMixMode(true)
                        "off" -> coordinator.setMixMode(false)
                        "toggle" -> coordinator.toggleMixMode()
                        // Emulator verification: presign rips from the public bucket (no rip server), then re-plan the lane.
                        "publicrips" -> { com.levi.pocketdj.di.MixDebug.publicRips = true; coordinator.replan() }
                        else -> Unit
                    }
                }
            },
            IntentFilter(DEBUG_ACTION),
            ContextCompat.RECEIVER_EXPORTED,
        )
    }

    companion object {
        const val DEBUG_ACTION = "com.levi.pocketdj.DEBUG"
    }
}
