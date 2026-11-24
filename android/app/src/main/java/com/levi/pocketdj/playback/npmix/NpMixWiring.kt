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

    // ---- P2-MM-8: the growing-file start (np-mix-mode phase 3) ---------------------------------------------

    private var progressRegistered = false

    private fun com.levi.pocketdj.mix.stream.MixStreamLoader.Stream.info(): StreamInfo = StreamInfo(
        audioId = songId, file = file, finalFile = finalFile?.takeIf { it != file }, bytesReceived = bytesReceived,
        expectedBytes = expectedBytes, isComplete = isComplete, failed = failed, resolved = resolved, isCut = isCut, startMs = startMs,
    )

    private val growingEnv = object : GrowingEnv {
        private val mixGraph get() = app.mixGraph
        private val loader get() = mixGraph.mixStreamLoader
        private val engine get() = mixGraph.npDspEngine

        override val dsp = object : GrowingDsp {
            override val engagedSongId: String? get() = engine.engagedSongId
            override val isBuffering: Boolean get() = engine.isBuffering
            override val awaitingFirstAudio: Boolean get() = !engine.producedAudio
            override val currentTimeSec: Double get() = engine.currentTimeSec
        }
        override val buffering: Boolean get() = coordinator.buffering
        override val generation: Long get() = seq.state.value.playGeneration
        override fun currentRow() = seq.state.value.current
        override val interruptionOpen: Boolean get() = seq.discriminator.interruptionOpen
        override val startPending: Boolean get() = seq.isStartPending

        override suspend fun rowFacts(item: com.levi.pocketdj.playback.sequencer.QueueItem): GrowingRules.RowFacts {
            val id = item.resolveId
            val local = withContext(Dispatchers.IO) { controller.localFiles.localUrlForPlayback(item) != null }
            val entry = app.ripsRepository.entry(id)
            val analog = entry?.source == "analog"
            val cfg = settingsMirror
            val net = NetworkClass.current(app.appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
            return GrowingRules.RowFacts(
                buffering = coordinator.buffering,
                mixTabActive = NowPlayingSeams.mixSessionActive,
                deviceMode = deviceModeMirror,
                local = local,
                studioOrProfile = com.levi.pocketdj.data.rips.PlayResolver.isStudioId(item.id) ||
                    com.levi.pocketdj.data.profile.ProfileSourceStore.isProfileSongId(item.id),
                catalogOnly = com.levi.pocketdj.data.jukebox.JukeboxAppleMusicMatch.storeIdOf(item.id) != null,
                ripped = entry != null,
                // Android's ladder never starts a RIPPED row on Apple Music (AppleMusicRowResolver defers on ripStartsNow);
                // the Apple-Music-sourced distinction is P2-MM-9's.
                appleMusicFirst = com.levi.pocketdj.playback.sequencer.PreferLocalAudio.appleMusicFirst(
                    com.levi.pocketdj.playback.sequencer.PreferLocalAudio.Facts(
                        preferLocalAudio = true,
                        appleMusicSourced = app.catalogRepository.state.value.catalog?.songsById?.get(item.id)?.appleMusicId?.isNotBlank() == true,
                        ripped = entry != null,
                        localCopyInstant = local || !app.playbackController.ripServerConfigured ||
                            app.presignCache.cached(id) != null,
                    ),
                ) && controller.canPlayFullTrackWarming(),
                analogSide = analog && entry?.cutKey == null,
                analogStartMs = if (analog) (app.ripsRepository.effectiveStartMs(id) ?: entry?.startMs ?: 0L) else 0L,
                networkAllows = com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher.mixReach(net, cfg.cellular, cfg.bufferAhead) != null,
            )
        }

        private fun ensureProgressListener() {
            if (progressRegistered) return
            progressRegistered = true
            loader.addProgressListener { id -> growing.onStreamProgress(id) }
        }

        override fun openStream(item: com.levi.pocketdj.playback.sequencer.QueueItem): StreamInfo? {
            ensureProgressListener()
            return loader.open(item.resolveId, item.title, item.artist.orEmpty(), origin = com.levi.pocketdj.data.burns.AssetOrigin.Buffer)?.info()
        }

        override fun stream(audioId: String): StreamInfo? = loader.stream(audioId)?.info()

        /** The FILE's duration for the byte-fraction estimate: a whole per-song file (digital / cut) is the song; an album side's is unknown here. */
        override fun fileDurationSeconds(item: com.levi.pocketdj.playback.sequencer.QueueItem, s: StreamInfo): Double? =
            if (!s.isCut && (s.startMs ?: 0L) > 0) null else item.lengthMs?.let { it / 1000.0 }

        override suspend fun touchFacts(item: com.levi.pocketdj.playback.sequencer.QueueItem): GrowingRules.TouchFacts? {
            if (!coordinator.buffering) return null
            val p = controller.handOffPlaying()
            val onStream = p != null && !p.isFile && !p.live && p.hasLoadedItem && !p.trackEnded &&
                (p.songId == item.id || p.songId == item.resolveId)
            val s = loader.stream(item.resolveId)?.info()
            return GrowingRules.TouchFacts(
                buffering = coordinator.buffering,
                refused = false,
                onPlainStream = onStream,
                dspEngaged = engine.isEngaged,
                interruptionOpen = seq.discriminator.interruptionOpen,
                startPending = seq.isStartPending,
                stream = s,
                songRelSeconds = p?.let { SwapOnLand.songRelMs(it) / 1000.0 } ?: 0.0,
                fileDurationSeconds = s?.let { fileDurationSeconds(item, it) },
            )
        }

        override fun touchReadyChanged() { runCatching { mixGraph.npDspHost.refresh() } }

        override suspend fun quietOutgoing() = controller.claimForDsp()

        private fun windowLengthMs(item: com.levi.pocketdj.playback.sequencer.QueueItem, s: StreamInfo): Long {
            val len = item.lengthMs ?: 0L
            val start = s.startMs ?: 0L
            if (s.isCut || start <= 0L) return len
            // An analog song ends at its end on the record, not startMs + catalog length (the host's own rule).
            val end = app.ripsRepository.analogEndMs(item.resolveId, start, len) ?: return len
            return if (end > start) end - start else len
        }

        override fun engage(item: com.levi.pocketdj.playback.sequencer.QueueItem, s: StreamInfo, atSeconds: Double): Boolean {
            mixGraph.stageGrowingMeta(item, seq.contextFor(item))
            val e = engine
            e.onStreamFailed = { at -> growing.onStreamFailed(at) }
            val ok = e.engageStreaming(
                file = s.finalFile ?: s.file, expectedBytes = s.expectedBytes, atSeconds = atSeconds, play = false,
                startMs = if (s.isCut) 0L else (s.startMs ?: 0L), lengthMs = windowLengthMs(item, s),
                bytesReceived = s.bytesReceived, complete = s.isComplete,
            )
            mixGraph.clearStagedGrowingMeta() // onEngaged fires inside engage: anything left over belongs to no engagement
            if (ok) e.bindSong(item.id)
            return ok
        }

        override fun resume() = engine.play()

        override fun disengage(): Double? {
            val at = engine.disengage()
            mixGraph.clearStagedGrowingMeta()
            runCatching { mixGraph.npDspHost.refresh() }
            return at
        }

        override fun feed(s: StreamInfo) = engine.streamProgressed(s.bytesReceived, s.isComplete, s.failed, s.finalFile)

        override fun completeClaimedStart(gen: Long): Boolean =
            seq.completeClaimedStart(gen, com.levi.pocketdj.playback.sequencer.StartPath.GROWING, backend = GrowingRules.BACKEND)

        override fun noteFirstAudio(songId: String, source: String) = seq.onFirstAudio(songId, source)

        override fun restartPlain(uid: String, atMs: Long): Boolean {
            // The row's History play was recorded at the growing start: its plain re-load must not record a second one.
            seq.state.value.current?.takeIf { it.uid == uid }?.let { com.levi.pocketdj.playback.PlaybackService.armSuppressHistory(it.id) }
            val ok = seq.restartCurrentRow(uid, atMs)
            if (!ok) com.levi.pocketdj.playback.PlaybackService.armSuppressHistory(null)
            return ok
        }

        override suspend fun resumeLeftStream(songId: String, atMs: Long): Boolean = controller.resumeStreamAt(songId, atMs)

        override fun meterBegan(cause: String) { seq.meter?.transitionBegan(cause) }
        override fun meterTrackStarting(backend: String) { seq.meter?.trackStarting(backend) }
        override fun meterFirstAudio(backend: String) { seq.meter?.firstAudio(backend) }

        override fun replan() = coordinator.scheduleReplan()
        override fun log(line: String) = SwapOnLand.laneLog(line)
    }

    // ---- P2-MM-9: the Apple Music -> local touch hand-off (np-mix-mode phase 4) -----------------------------

    private val amHandOffEnv = object : AppleMusicHandOffEnv {
        private val mixGraph get() = app.mixGraph
        override val buffering: Boolean get() = coordinator.buffering
        override val generation: Long get() = seq.state.value.playGeneration
        override fun currentRowUid(): String? = seq.state.value.current?.uid
        override fun currentRowId(): String? = seq.state.value.current?.id

        override suspend fun facts(): AppleMusicHandOffRules.Facts? {
            val item = seq.state.value.current ?: return null
            if (!controller.isAppleMusicActive) return null
            return AppleMusicHandOffRules.Facts(
                buffering = coordinator.buffering,
                appleMusicActive = true,
                dspEngaged = mixGraph.npDspEngine.isEngaged,
                mixTabActive = NowPlayingSeams.mixSessionActive,
                deviceMode = deviceModeMirror,
                localCopyComplete = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { mixGraph.npDspHost.hasLocalCopy(item.id) }, // reads burn/beat-grid JSON: off Main
                interruptionOpen = seq.discriminator.interruptionOpen,
                appleMusicPlaying = controller.appleMusicAudiblyPlaying,
                pauseIntentional = seq.discriminator.pausedByListener,
                startPending = seq.isStartPending,
                lengthMs = item.lengthMs,
            )
        }

        override suspend fun appleMusicPositionMs(): Long? = runCatching { controller.appleMusicPositionMsOrNull() }.getOrNull()

        override suspend fun engagePaused(atSeconds: Double): Boolean {
            val id = seq.state.value.current?.id ?: return false
            return mixGraph.npDspHost.engageLocalPaused(id, atSeconds)
        }

        // The controller becomes the sequencer's own again (single owner), exactly as for a growing start.
        override suspend fun stopAppleMusic() = controller.claimForDsp()
        override fun resume() = mixGraph.npDspEngine.play()
        override fun disengage() { mixGraph.npDspEngine.disengage(); runCatching { mixGraph.npDspHost.refresh() } }
        override fun readyChanged() { runCatching { mixGraph.npDspHost.refresh() } }
        override fun meterBegan(cause: String) { seq.meter?.transitionBegan(cause) }
        override fun meterTrackStarting(backend: String) { seq.meter?.trackStarting(backend) }
        override fun meterFirstAudio(backend: String) { seq.meter?.firstAudio(backend) }
        override fun meterAbandoned(reason: String) { seq.meter?.transitionAbandoned(reason) }
        override fun log(line: String) = SwapOnLand.laneLog(line)
    }

    /** The touch hand-off of an Apple Music row onto its local copy (never automatic). */
    val appleMusicHandOff: AppleMusicHandOff = AppleMusicHandOff(amHandOffEnv)

    /** Recompute the hand-off's cached availability (a local copy landed / the row changed). Main-thread. */
    fun refreshAppleMusicHandOff() {
        if (!coordinator.buffering && !appleMusicHandOff.ready()) return
        scope.launch { appleMusicHandOff.refresh() }
    }

    /** The growing-file start (a sequencer StartInterceptor) and its touch hand-off / fallback ledger. */
    val growing: GrowingStart = GrowingStart(growingEnv, scope)

    val coordinator: NpMixCoordinator = NpMixCoordinator(
        ports,
        object : NpMixCoordinator.HandOff {
            override fun attempt(reason: String) { scope.launch { runner.attempt(reason) } }
            override fun retryOwed(trigger: String) { scope.launch { runner.retryOwed(trigger, ports.currentUid) } }
            override fun rowChanged(currentUid: String?) { runner.rowChanged(currentUid); growing.rowChanged(currentUid); appleMusicHandOff.rowChanged(currentUid); refreshAppleMusicHandOff() }
            override fun sessionEnded() { runner.sessionEnded(); growing.sessionEnded(); appleMusicHandOff.sessionEnded() }
        },
    )

    private var installed = false

    /** Register on the sequencer and observe the settings / Mix tab / network. Idempotent; main thread. */
    fun install() {
        if (installed) return
        installed = true
        seq.hooks.add(coordinator)
        seq.sessionExtras.register(coordinator)
        controller.preferLocalAudioProvider = { coordinator.buffering } // P2-MM-9: Mix Mode buffering reorders the AM ladder
        seq.addStartInterceptor(growing) // P2-MM-8: Mix Mode starts eligible rows on the growing buffer
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
