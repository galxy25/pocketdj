package com.levi.pocketdj.shell

import com.levi.pocketdj.mix.nowplaying.NpMixMode
import kotlinx.coroutines.launch

/**
 * The four Demucs parts by every name people say for them (iOS `StemPart`, synonyms verbatim). There is deliberately
 * no "Drop the <stem>" phrase: it collides with the music sense of "drop".
 */
enum class StemPart(val stemName: String, val spoken: String, val synonyms: List<String>) {
    Vocals("vocals", "the vocals", listOf("vocal", "vocals", "voice", "voices", "singing", "singer", "lyrics", "acapella")),
    Drums("drums", "the drums", listOf("drum", "drums", "percussion", "beat", "the beat")),
    Bass("bass", "the bass", listOf("bass", "bassline", "bass line", "low end")),
    Other("other", "the other instruments", listOf("other", "others", "instruments", "instrumental", "music", "melody", "keys", "guitar"));

    /** "The vocals are" / "The bass is". */
    val verb: String get() = if (this == Bass) "is" else "are"

    companion object {
        /** A spoken / linked stem name -> part; leading "the " and case are ignored, unknown = null. */
        fun parse(raw: String?): StemPart? {
            val t = raw?.trim()?.lowercase()?.removePrefix("the ")?.trim().orEmpty()
            if (t.isEmpty()) return null
            return entries.firstOrNull { p -> p.stemName == t || t in p.synonyms || p.synonyms.any { it.removePrefix("the ") == t } }
        }
    }
}

/**
 * The facts and levers of the Now Playing mini-mix the voice doors need (iOS `SetlistPlayer` + its `dsp`). Production
 * ([AppNowPlayingVoicePort]) reads the sequencer / NpMixCoordinator / NowPlayingDspHost; tests fake it. Main thread.
 */
interface NowPlayingVoicePort {
    /** A Now Playing run exists. */
    val running: Boolean

    /** The Mix tab owns the audio (iOS `mix.isRunning || mix.autoMixing`): Now Playing's mini-mix is off. */
    val mixTabLive: Boolean

    /** The session's Mix Mode switch. */
    val mixModeEnabled: Boolean
    fun setMixMode(on: Boolean)

    /** The panel's gate (`mixAvailable(mixActive: false)`): the playing row is mixable right now. */
    val mixAvailable: Boolean

    /** The status chip's source (`mixModeIndicator`). */
    val indicator: NpMixMode.Indicator

    /** The first-touch hand-off (`engageMix`): ExoPlayer -> the DSP graph. Idempotent. */
    suspend fun engageMix()

    /** The DSP owns the playing row. */
    val mixEngaged: Boolean

    val stemMode: Boolean
    val stemsLoading: Boolean
    fun isStemMuted(stemName: String): Boolean

    /** The Stems toggle. False = refused (nothing to hand over to / no stems). */
    fun setStemMode(on: Boolean): Boolean
    fun toggleStemMute(stemName: String)
}

/**
 * Mix Mode and stems by voice (iOS `IntentServices.setNowPlayingMixMode` / `setStem`): the same order of operations
 * as the Now Playing mini-mix panel, returning the sentence the Assistant / toast says. Throws only when there is
 * nothing to act on.
 */
class NowPlayingVoiceActions(private val port: NowPlayingVoicePort) {

    /** Turn the session's Mix Mode on/off — the panel's Mix Mode switch. */
    fun setMixMode(on: Boolean): String {
        if (!port.running) throw ShellActionException.NothingPlaying
        if (port.mixModeEnabled == on) return if (on) "Mix Mode is already on." else "Mix Mode is already off."
        port.setMixMode(on)
        if (port.mixModeEnabled != on) return "Mix Mode isn't available right now."
        if (!on) return "Mix Mode is off."
        if (port.mixTabLive) return "Mix Mode is on. It starts buffering once the Mix tab stops."
        return "Mix Mode is on — buffering this song and the next ones so stems and effects work on them."
    }

    /**
     * Mute or unmute one stem: a mute first turns Mix Mode on (when off), engages the DSP, puts the Stems toggle on,
     * then mutes the pad. An unmute only ever touches a stem that IS muted.
     */
    suspend fun setStem(stem: StemPart, muted: Boolean): String {
        if (!port.running) throw ShellActionException.NothingPlaying
        // One DSP surface at a time: the Mix tab live means the Now Playing mini-mix is off.
        if (port.mixTabLive) throw ShellActionException.MixTabLive
        val name = stem.stemName
        val said = stem.spoken
        val cap = said.replaceFirstChar { it.uppercase() }

        fun alreadyMuted() = port.mixEngaged && (port.stemMode || port.stemsLoading) && port.isStemMuted(name)

        if (!muted) {
            if (!alreadyMuted()) return "$cap ${stem.verb} already playing."
            port.toggleStemMute(name)
            return "Unmuted $said."
        }

        if (alreadyMuted()) return "$cap ${stem.verb} already muted."
        var turnedOn = false
        if (!port.mixModeEnabled) {
            port.setMixMode(true) // the NP switch: buffers this + upcoming
            if (!port.mixModeEnabled) return "Mix Mode isn't available right now, so I can't mute $said."
            turnedOn = true
        }
        val lead = if (turnedOn) "Mix Mode is on, but " else ""
        if (!port.mixAvailable) {
            // Why the panel's controls aren't live yet: its own status chip, in words.
            val why = port.indicator.chipText ?: "this song isn't on the device"
            return when (port.indicator) {
                is NpMixMode.Indicator.Buffering, is NpMixMode.Indicator.Holding, NpMixMode.Indicator.Waiting,
                NpMixMode.Indicator.Ripping, is NpMixMode.Indicator.RippingEdition ->
                    "${lead}I can't mute $said yet — this song is still downloading ($why). Ask again in a moment."
                else -> "${lead}I can't mute $said on this song: $why."
            }
        }
        port.engageMix()
        if (!port.mixEngaged) return "${lead}I couldn't open this song for mixing, so $said can't be muted."
        if (!port.stemMode && !port.stemsLoading) {
            if (!port.setStemMode(true)) return "${lead}this song has no stems yet, so $said can't be muted."
        }
        if (!port.isStemMuted(name)) port.toggleStemMute(name)
        val done = if (turnedOn) "Turned on Mix Mode and muted $said" else "Muted $said"
        return if (port.stemsLoading) "$done — the stems are loading, so it takes effect in a moment." else "$done."
    }
}

/** Production [NowPlayingVoicePort] over the app graphs (the facts the panel and its status chip read). */
class AppNowPlayingVoicePort(private val app: com.levi.pocketdj.di.AppGraph) : NowPlayingVoicePort {
    private val coordinator get() = app.playbackGraph.npMix.coordinator
    private val host get() = app.mixGraph.npDspHost
    private val engine get() = app.mixGraph.npDspEngine

    /** Device playback mode, mirrored off the setting (the lane never downloads into it; shapes the chip). */
    @Volatile private var deviceMode = false

    init {
        app.appScope.launch {
            app.settings.flow(com.levi.pocketdj.playback.PlaybackPrefKeys.PLAYBACK_MODE).collect {
                deviceMode = com.levi.pocketdj.playback.PlaybackMode.fromToken(it) == com.levi.pocketdj.playback.PlaybackMode.DEVICE
            }
        }
    }

    override val running: Boolean get() = app.playbackGraph.sequencer.state.value.isRunning
    override val mixTabLive: Boolean get() = com.levi.pocketdj.screens.nowplaying.NowPlayingSeams.mixSessionActive
    override val mixModeEnabled: Boolean get() = coordinator.enabled
    override fun setMixMode(on: Boolean) = coordinator.setMixMode(on)
    override val mixAvailable: Boolean get() = host.available()
    override val indicator: NpMixMode.Indicator
        get() = com.levi.pocketdj.screens.nowplaying.NpMixIndicatorReader.read(app, deviceMode)
    override suspend fun engageMix() { host.engage() }
    override val mixEngaged: Boolean
        get() = engine.isEngaged && engine.engagedSongId == app.playbackGraph.sequencer.state.value.current?.id
    override val stemMode: Boolean get() = engine.stemMode
    override val stemsLoading: Boolean get() = engine.stemsLoading
    override fun isStemMuted(stemName: String): Boolean = stemName in engine.mutedStems
    override fun setStemMode(on: Boolean): Boolean = engine.setStemMode(on)
    override fun toggleStemMute(stemName: String) = engine.setStemMuted(stemName, stemName !in engine.mutedStems)
}
