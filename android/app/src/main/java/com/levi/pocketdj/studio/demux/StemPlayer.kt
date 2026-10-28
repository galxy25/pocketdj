package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoiceGroup
import com.levi.pocketdj.audio.core.VoicePump
import java.io.File
import kotlin.math.roundToLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Pure mute/solo model (iOS StemPlayer rules): solo wins over mute; muting clears solo; re-solo clears it. */
class StemMixState {
    var muted: Set<String> = emptySet(); private set
    var soloed: String? = null; private set

    fun isAudible(name: String): Boolean = soloed?.let { it == name } ?: (name !in muted)

    /** Solo ONE stem; soloing the soloed stem again clears solo (back to the mute set). */
    fun solo(name: String) { soloed = if (soloed == name) null else name }

    /** Toggle a stem's mute, independent of solo; muting clears any solo so the toggles read true. */
    fun toggleMute(name: String) {
        soloed = null
        muted = if (name in muted) muted - name else muted + name
    }

    fun reset() { muted = emptySet(); soloed = null }
}

/**
 * The Demuxer's playback surface: ONE shared player in single-mix mode (one file) or stem mode (four
 * synced files). Observers re-read state when [version] bumps; the playhead is POLLED via [currentTimeSec]
 * (deliberately not a flow — 4x/s ticks must not invalidate the surrounding controls).
 */
interface StemPlayer {
    val version: StateFlow<Int>
    val isPlaying: Boolean
    val currentTimeSec: Double
    val durationSec: Double
    val soloed: String?
    fun isAudible(name: String): Boolean

    /** Load [files] (name -> file); a repeat load of the same [id] is a no-op. Replaces any prior load. Returns false when nothing could be loaded (unplayable/corrupt audio). */
    fun load(id: String, files: Map<String, File>): Boolean
    fun togglePlayPause()
    fun seek(sec: Double)
    fun solo(name: String)
    fun toggleMute(name: String)
    fun stop()
}

/** Single-file fallback: plays one mix with android.media.MediaPlayer (any container the platform decodes). */
class SingleFileStemPlayer(private val focus: () -> Unit = {}, private val focusRelease: () -> Unit = {}) : StemPlayer {
    private val _version = MutableStateFlow(0)
    override val version: StateFlow<Int> = _version.asStateFlow()
    private var mp: android.media.MediaPlayer? = null
    private var loadedId: String? = null
    private var pausedAt = 0.0
    private val mix = StemMixState()

    override val isPlaying: Boolean get() = runCatching { mp?.isPlaying == true }.getOrDefault(false)
    override val currentTimeSec: Double get() = runCatching { mp?.currentPosition?.div(1000.0) }.getOrNull() ?: pausedAt
    override val durationSec: Double get() = runCatching { mp?.duration?.div(1000.0) }.getOrNull() ?: 0.0
    override val soloed: String? get() = mix.soloed
    override fun isAudible(name: String) = mix.isAudible(name)

    override fun load(id: String, files: Map<String, File>): Boolean {
        if (loadedId == id && mp != null) return true
        stop()
        val f = files.values.firstOrNull() ?: return false
        val player = android.media.MediaPlayer()
        val ok = runCatching {
            player.setDataSource(f.path)
            player.prepare()
            player.setOnCompletionListener { pausedAt = 0.0; focusRelease(); bump() }
        }.isSuccess
        if (!ok) { runCatching { player.release() }; return false }
        mp = player
        loadedId = id
        bump()
        return true
    }

    override fun togglePlayPause() {
        val p = mp ?: return
        if (p.isPlaying) { pausedAt = p.currentPosition / 1000.0; p.pause(); focusRelease() }
        else { focus(); if (p.currentPosition >= p.duration - 50) p.seekTo(0); p.start() }
        bump()
    }

    override fun seek(sec: Double) { mp?.seekTo((sec.coerceIn(0.0, durationSec) * 1000).toInt()); pausedAt = sec; bump() }
    override fun solo(name: String) { if (!isPlaying) togglePlayPause() }
    override fun toggleMute(name: String) {}
    override fun stop() { runCatching { mp?.release() }; mp = null; loadedId = null; pausedAt = 0.0; focusRelease(); bump() }
    private fun bump() { _version.value = _version.value + 1 }
}

/**
 * Synced four-stem player on the Mix audio core: one [Voice] per stem in a [VoiceGroup] (started on ONE
 * render frame; the whole group HOLDS when any stem underruns so stems never drift), summed to one sink.
 * Mute/solo ride the Voice gain ramp. The sink is opened lazily on first play (loading is free).
 * Device-verified separately; the sync/solo contract is JVM-tested with an OfflineRenderer.
 */
class VoiceGroupStemPlayer(
    private val sinkFactory: () -> AudioSink,
    private val openSource: (File) -> PcmSource?,
    private val scope: CoroutineScope,
    private val focus: () -> Unit = {},
    private val focusRelease: () -> Unit = {},
) : StemPlayer {
    private val _version = MutableStateFlow(0)
    override val version: StateFlow<Int> = _version.asStateFlow()
    private val mix = StemMixState()

    private var loadedId: String? = null
    private var names: List<String> = emptyList()
    private var voices: List<Voice> = emptyList()
    private var group: VoiceGroup? = null
    private var pumps: List<VoicePump> = emptyList()
    private var sink: AudioSink? = null
    @Volatile private var rate = 44_100
    @Volatile private var totalFrames = 0L
    @Volatile private var playing = false
    @Volatile private var started = false
    @Volatile private var pausedAt = 0.0
    @Volatile private var startedFrom = 0.0
    @Volatile private var token = 0

    override val isPlaying: Boolean get() { refreshEnded(); return playing }
    override val durationSec: Double get() = if (rate > 0) totalFrames.toDouble() / rate else 0.0
    override val soloed: String? get() = mix.soloed
    override fun isAudible(name: String) = mix.isAudible(name)

    override val currentTimeSec: Double
        get() {
            refreshEnded()
            val v = voices.firstOrNull() ?: return 0.0
            return if (playing && started) v.playerFrame.toDouble() / rate else if (playing) startedFrom else pausedAt
        }

    private fun refreshEnded() {
        if (playing && started && voices.isNotEmpty() && voices.all { it.status == Voice.Status.ENDED }) {
            playing = false; started = false; pausedAt = durationSec
            group?.pauseAll(); focusRelease(); bump()
        }
    }

    override fun load(id: String, files: Map<String, File>): Boolean {
        if (loadedId == id && voices.isNotEmpty()) return true
        stop()
        val opened = files.entries.mapNotNull { (n, f) -> runCatching { openSource(f) }.getOrNull()?.let { n to it } }
        if (opened.isEmpty()) return false
        names = opened.map { it.first }
        voices = opened.map { (n, s) -> Voice(s, rate, name = n).also { it.schedule(0) } }
        rate = voices[0].sampleRate
        totalFrames = voices.minOf { it.totalFrames.takeIf { t -> t >= 0 } ?: Long.MAX_VALUE }.let { if (it == Long.MAX_VALUE) 0 else it }
        group = VoiceGroup(voices)
        pumps = voices.map { VoicePump(it, "pdj-demux-${it.name}").start() }
        loadedId = id
        mix.reset(); applyGains(); pausedAt = 0.0
        bump()
        return true
    }

    private fun applyGains() { for (i in voices.indices) voices[i].setGain(if (mix.isAudible(names[i])) 1f else 0f) }

    override fun togglePlayPause() { if (playing) pauseNow() else startSynced(if (pausedAt >= durationSec) 0.0 else pausedAt) }

    override fun seek(sec: Double) {
        val t = sec.coerceIn(0.0, durationSec)
        if (playing) startSynced(t) else { pausedAt = t; voices.forEach { it.seek((t * rate).roundToLong()) }; bump() }
    }

    override fun solo(name: String) {
        mix.solo(name); applyGains()
        if (!playing) startSynced(if (pausedAt >= durationSec) 0.0 else pausedAt)
        bump()
    }

    override fun toggleMute(name: String) { mix.toggleMute(name); applyGains(); bump() }

    private fun pauseNow() {
        if (!playing) return
        pausedAt = currentTimeSec
        token++
        group?.pauseAll(); playing = false; started = false
        focusRelease(); bump()
    }

    /** Schedule all stems from [fromSec] and start them on ONE render frame once every ring has data. */
    private fun startSynced(fromSec: Double) {
        val g = group ?: return
        val my = ++token
        g.pauseAll()
        val frame = (fromSec * rate).roundToLong()
        voices.forEach { it.schedule(frame) }
        startedFrom = fromSec; pausedAt = fromSec; started = false; playing = true
        focus()
        val s = ensureSink()
        bump()
        scope.launch {
            val need = minOf(8192L, maxOf(1L, totalFrames - frame)).toInt()
            var waited = 0
            while (token == my && !g.allReady(need) && waited < 5_000) { delay(5); waited += 5 }
            if (token != my) return@launch
            val f = g.startTogether(s.clock, minFrames = 1)
            if (f >= 0) started = true else { playing = false; focusRelease(); bump() }
        }
    }

    private fun ensureSink(): AudioSink {
        sink?.let { return it }
        val s = sinkFactory()
        sink = s
        val g = group!!
        val n = voices.size
        var outs = List(n) { FloatArray(0) }
        s.start { out, frames ->
            if (outs[0].size < frames * 2) outs = List(n) { FloatArray(frames * 2) }
            g.read(outs, frames, s.clock.now())
            java.util.Arrays.fill(out, 0, frames * 2, 0f)
            for (o in outs) for (i in 0 until frames * 2) out[i] += o[i]
        }
        return s
    }

    override fun stop() {
        token++
        group?.pauseAll()
        sink?.let { runCatching { it.stop() }; runCatching { it.release() } }
        sink = null
        pumps.forEach { it.stopAndJoin() }
        voices.forEach { runCatching { it.close() } }
        pumps = emptyList(); voices = emptyList(); group = null; names = emptyList()
        loadedId = null; playing = false; started = false; pausedAt = 0.0; totalFrames = 0
        focusRelease(); bump()
    }

    private fun bump() { _version.value = _version.value + 1 }
}

/** Picks the right engine per load: one file -> [single] (any container), several -> synced [multi]. */
class RoutingStemPlayer(
    private val single: StemPlayer,
    private val multi: StemPlayer,
    scope: CoroutineScope,
) : StemPlayer {
    @Volatile private var active: StemPlayer = single
    private val _version = MutableStateFlow(0)
    override val version: StateFlow<Int> = _version.asStateFlow()

    init {
        scope.launch { single.version.collect { _version.value = _version.value + 1 } }
        scope.launch { multi.version.collect { _version.value = _version.value + 1 } }
    }

    override val isPlaying get() = active.isPlaying
    override val currentTimeSec get() = active.currentTimeSec
    override val durationSec get() = active.durationSec
    override val soloed get() = active.soloed
    override fun isAudible(name: String) = active.isAudible(name)

    override fun load(id: String, files: Map<String, File>): Boolean {
        val next = if (files.size >= 2) multi else single
        if (next !== active) active.stop()
        active = next
        return next.load(id, files)
    }

    override fun togglePlayPause() = active.togglePlayPause()
    override fun seek(sec: Double) = active.seek(sec)
    override fun solo(name: String) = active.solo(name)
    override fun toggleMute(name: String) = active.toggleMute(name)
    override fun stop() { single.stop(); multi.stop() }
}
