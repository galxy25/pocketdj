package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlaybackController
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.SequencerState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** The audible track as the deck needs it (a thin view over [PlaybackController.NowPlayingInfo]). */
data class AudibleTrack(
    val songId: String,
    val title: String?,
    val artist: String?,
    val albumId: String?,
    val isPlaying: Boolean,
    val durationMs: Long?,
    val isLive: Boolean = false,
    val isPreview: Boolean = false,
)

fun PlaybackController.NowPlayingInfo.toAudible() = AudibleTrack(
    songId, title, artist, albumId, isPlaying, durationMs, isLive, isPreview,
)

/** Catalog + manifest facts about the current song. */
data class SongFacts(
    val catalogBpm: Double? = null,
    val manifestBeatGridBpm: Double? = null,
    val catalogLengthMs: Long? = null,
    val albumId: String? = null,
    val inCatalog: Boolean = false,
    val appleMusicId: String? = null,
)

/** The whole deck, computed purely from sequencer + player + catalog facts. */
data class NowPlayingUiState(
    val hasTrack: Boolean = false,
    val songId: String? = null,
    val title: String = "Nothing playing",
    val artist: String = "",
    val albumId: String? = null,
    val appleMusicId: String? = null,
    val inCatalog: Boolean = false,
    /** The audible track IS the deck's current row. */
    val audibleIsCurrent: Boolean = false,
    /** Record should rotate right now. */
    val spinning: Boolean = false,
    val bpm: Double? = null,
    val lengthMs: Long? = null,
    val runActive: Boolean = false,
    val repeatMode: RepeatMode = RepeatMode.OFF,
    val shuffleEnabled: Boolean = false,
    val notice: String? = null,
    val isPlaying: Boolean = false,
    val isLive: Boolean = false,
    val isPreview: Boolean = false,
    val transport: TransportInputs = TransportInputs(false, false, false, true, false),
) {
    /** Shuffle/repeat row exists only while a set runs. */
    val showModeRow: Boolean get() = runActive
    val repeatHelp: String get() = repeatHelpText(repeatMode)
}

fun repeatHelpText(mode: RepeatMode): String = when (mode) {
    RepeatMode.OFF -> "Repeat off"
    RepeatMode.ALL -> "Repeat session"
    RepeatMode.ONE -> "Repeat song"
}

object NowPlayingModel {
    fun build(
        seq: SequencerState,
        audible: AudibleTrack?,
        facts: SongFacts?,
        startPending: Boolean,
        appleMusicActive: Boolean,
        /** [com.levi.pocketdj.playback.sequencer.SetlistSequencer.currentNeverSounded]. */
        currentNeverSounded: Boolean = false,
    ): NowPlayingUiState {
        val row = seq.current
        // Deck identity: the sequencer's current row; else whatever is audible (a Browse single).
        val songId = row?.id ?: audible?.songId
        val title = row?.title?.takeIf { it.isNotBlank() } ?: audible?.title ?: songId
        val artist = row?.artist ?: audible?.artist
        val audibleIsCurrent = row != null && audible != null && row.matches(audible.songId)
        val playing = audible?.isPlaying == true
        // Real sequencer signals: the cascade breaker halted an AUTO advance, or no row ever sounded.
        val cascade = seq.isRunning && !seq.isHeldForResume &&
            (seq.pausedByCascade || (currentNeverSounded && !startPending))
        // The engine holds no item for the CURRENT row (nothing loaded, or a stale/other item).
        val engineIdle = audible == null || (row != null && !row.matches(audible.songId))
        return NowPlayingUiState(
            hasTrack = songId != null,
            songId = songId,
            title = title ?: "Nothing playing",
            artist = artist.orEmpty(),
            albumId = facts?.albumId ?: audible?.albumId,
            appleMusicId = facts?.appleMusicId,
            inCatalog = facts?.inCatalog == true,
            audibleIsCurrent = audibleIsCurrent,
            // With no set running the audible Browse single IS the deck identity, so it spins too.
            spinning = playing && (audibleIsCurrent || row == null),
            bpm = facts?.let { RecordMath.effectiveBpm(it.manifestBeatGridBpm, it.catalogBpm) },
            lengthMs = RecordMath.lengthMs(facts?.catalogLengthMs ?: row?.lengthMs, audible?.durationMs),
            runActive = seq.isRunning,
            repeatMode = seq.repeatMode,
            shuffleEnabled = seq.shuffleEnabled,
            notice = seq.playbackNotice?.takeIf { it.isNotBlank() },
            isPlaying = playing,
            isLive = audible?.isLive == true,
            isPreview = audible?.isPreview == true,
            transport = TransportInputs(
                held = seq.isRunning && seq.isHeldForResume,
                pausedByCascade = cascade,
                appleMusicActive = appleMusicActive,
                engineIdle = engineIdle,
                startPending = startPending,
            ),
        )
    }
}

/**
 * Screen-scoped holder (a plain class: the deck state is derived from app-scoped flows, so there is
 * nothing to survive configuration changes). Owns the 1 Hz position poll for the tonearm.
 */
class NowPlayingViewModel(
    private val graph: AppGraph,
    private val scope: CoroutineScope,
) {
    private val controller get() = graph.playbackController
    private val sequencer get() = graph.playbackGraph.sequencer

    private val _positionMs = MutableStateFlow(0L)
    val positionMs: StateFlow<Long> = _positionMs.asStateFlow()

    private val _showPlayed = MutableStateFlow(false)
    val showPlayed: StateFlow<Boolean> = _showPlayed.asStateFlow()

    private var pollJob: Job? = null

    fun startPolling() {
        if (pollJob?.isActive == true) return
        pollJob = scope.launch {
            while (isActive) {
                _positionMs.value = runCatching { controller.currentPositionMs() }.getOrDefault(0L)
                delay(1000)
            }
        }
    }

    fun stopPolling() { pollJob?.cancel(); pollJob = null }

    fun togglePlayed() { _showPlayed.value = !_showPlayed.value }

    fun facts(songId: String?): SongFacts? {
        songId ?: return null
        val song = graph.catalogRepository.state.value.catalog?.songsById?.get(songId)
        val entry = graph.ripsRepository.entry(songId)
        return SongFacts(
            catalogBpm = song?.bpm,
            manifestBeatGridBpm = entry?.beatGridBpm,
            catalogLengthMs = song?.length,
            albumId = song?.albumId,
            inCatalog = song != null,
            appleMusicId = song?.appleMusicId,
        )
    }

    fun inputsStartPending(): Boolean = sequencer.isStartPending
    fun appleMusicActive(): Boolean = controller.isAppleMusicActive
    fun currentNeverSounded(): Boolean = sequencer.currentNeverSounded

    private val port = object : TransportPort {
        override fun resumeFromHold() { sequencer.resumeFromHold() }
        override fun startCurrent() { sequencer.startCurrent() }
        override fun toggleAppleMusic() = togglePlayPauseEngine()
        override fun togglePlayPauseEngine() {
            scope.launch {
                if (controller.nowPlaying.value?.isPlaying == true) controller.pause() else controller.resume()
            }
        }
        override fun log(line: String) = NPLog.lane(NPLog.PLAYBACK, line)
    }

    fun togglePlayPause(current: TransportInputs): TransportVerdict =
        NowPlayingTransport.togglePlayPause(current, port)

    /** Live ladder inputs (the mini bar has no composed state of its own). */
    fun currentInputs(): TransportInputs = NowPlayingModel.build(
        seq = sequencer.state.value,
        audible = controller.nowPlaying.value?.toAudible(),
        facts = null,
        startPending = sequencer.isStartPending,
        appleMusicActive = controller.isAppleMusicActive,
        currentNeverSounded = sequencer.currentNeverSounded,
    ).transport

    fun next() { scope.launch { controller.next() } }
    fun previous() { scope.launch { controller.previous() } }
    fun cycleRepeat() = sequencer.cycleRepeatMode()
    fun toggleShuffle() = sequencer.toggleShuffle()
}
