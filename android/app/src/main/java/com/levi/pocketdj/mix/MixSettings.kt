package com.levi.pocketdj.mix

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.playback.dj.DJModeSettings
import com.levi.pocketdj.screens.mix.DeckLayout
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first

/** iOS `CueChannel`: which side the CUE / PFL bus pans to. [raw] is the persisted rawValue. */
enum class CueChannel(val raw: String, val label: String) {
    RIGHT("right", "Right (main on left)"),
    LEFT("left", "Left (main on right)");

    val onRight: Boolean get() = this == RIGHT

    companion object {
        fun fromRaw(s: String?): CueChannel = entries.firstOrNull { it.raw == s } ?: RIGHT
    }
}

/**
 * Settings ▸ Mix, an immutable snapshot (iOS `SettingsStore` mix fields). Defaults are the iOS
 * defaults; a missing key yields its default (additive-optional).
 */
data class MixSettings(
    /** Seconds BEFORE a track ends to begin crossfading to the next deck. */
    val autoMixLeadSeconds: Double = DEFAULT_LEAD,
    /** Length of the automatic crossfade. */
    val autoMixFadeSeconds: Double = DEFAULT_FADE,
    /** Crossfade length when the Skip button is tapped (double tap is always 5 s). */
    val skipFadeSeconds: Double = DEFAULT_SKIP_FADE,
    /** Mix Glide ramp length. */
    val mixGlideSeconds: Double = DEFAULT_GLIDE,
    /** Track loader hides tracks already played this session. */
    val mixAutoHidePlayed: Boolean = true,
    val cueOutputChannel: CueChannel = CueChannel.RIGHT,
    val beatPulseEnabled: Boolean = false,
    val mixDeckLayout: DeckLayout = DeckLayout.STACKED,
    /** Auto-DJ volume glide (iOS `mixVolumeGlide`); off by default. */
    val mixVolumeGlide: Boolean = false,
    /** Now Playing DJ Mode part toggles (iOS `dj*`); every part defaults on. They only MASK parts off. */
    val dj: DJModeSettings = DJModeSettings(),
) {
    companion object {
        const val DEFAULT_LEAD = 15.0
        const val DEFAULT_FADE = 3.0
        const val DEFAULT_SKIP_FADE = 15.0
        const val DEFAULT_GLIDE = 10.0

        val LEAD_RANGE = 3.0..60.0
        val FADE_RANGE = 1.0..12.0
        val SKIP_FADE_RANGE = 1.0..60.0
        val GLIDE_RANGE = 1.0..30.0
    }
}

/** Persisted DataStore keys. Names are FROZEN once shipped and equal the iOS field names. */
object MixSettingsKeys {
    val LEAD = PrefKey.double("autoMixLeadSeconds", MixSettings.DEFAULT_LEAD)
    val FADE = PrefKey.double("autoMixFadeSeconds", MixSettings.DEFAULT_FADE)
    val SKIP_FADE = PrefKey.double("skipFadeSeconds", MixSettings.DEFAULT_SKIP_FADE)
    val GLIDE = PrefKey.double("mixGlideSeconds", MixSettings.DEFAULT_GLIDE)
    val AUTO_HIDE_PLAYED = PrefKey.boolean("mixAutoHidePlayed", true)
    val CUE_CHANNEL = PrefKey.string("cueOutputChannel", CueChannel.RIGHT.raw)
    val BEAT_PULSE = PrefKey.boolean("beatPulseEnabled", false)
    val DECK_LAYOUT = PrefKey.string("mixDeckLayout", DeckLayout.STACKED.raw)
    val VOLUME_GLIDE = PrefKey.boolean("mixVolumeGlide", false)

    // Now Playing DJ Mode toggles; a missing key reads true (iOS defaults).
    val DJ_TRANSITIONS = PrefKey.boolean("djTransitions", true)
    val DJ_EFFECT_SWEEPS = PrefKey.boolean("djEffectSweeps", true)
    val DJ_TEMPO_MATCH = PrefKey.boolean("djTempoMatch", true)
    val DJ_KEY_MATCH = PrefKey.boolean("djKeyMatch", true)
    val DJ_VOLUME_LEVELING = PrefKey.boolean("djVolumeLeveling", true)
    val DJ_TEMPO_WAVES = PrefKey.boolean("djTempoWaves", true)
    val DJ_POCKETS = PrefKey.boolean("djPockets", true)
}

/** Stepper clamps (iOS Settings ▸ Mix ranges), applied on write AND on read. */
object MixSettingsRules {
    fun lead(v: Double) = v.coerceIn(MixSettings.LEAD_RANGE)
    fun fade(v: Double) = v.coerceIn(MixSettings.FADE_RANGE)
    fun skipFade(v: Double) = v.coerceIn(MixSettings.SKIP_FADE_RANGE)
    fun glide(v: Double) = v.coerceIn(MixSettings.GLIDE_RANGE)

    fun clamp(s: MixSettings) = s.copy(
        autoMixLeadSeconds = lead(s.autoMixLeadSeconds),
        autoMixFadeSeconds = fade(s.autoMixFadeSeconds),
        skipFadeSeconds = skipFade(s.skipFadeSeconds),
        mixGlideSeconds = glide(s.mixGlideSeconds),
    )

    /** "15 s" stepper readout. */
    fun seconds(v: Double): String = "${v.toInt()} s"
}

/** The engine-side setters a settings change pushes into (iOS `MixView` pushes). */
interface MixSettingsSink {
    fun setCueOnRight(right: Boolean)
    fun setBeatPulseEnabled(on: Boolean)
    fun setMixGlideSeconds(seconds: Double)
    fun setSkipFadeSeconds(seconds: Double)
}

object MixSettingsPush {
    /** Everything (Mix tab first appearance / start of a headless run). */
    fun pushAll(s: MixSettings, sink: MixSettingsSink) {
        sink.setCueOnRight(s.cueOutputChannel.onRight)
        sink.setBeatPulseEnabled(s.beatPulseEnabled)
        sink.setMixGlideSeconds(s.mixGlideSeconds)
        sink.setSkipFadeSeconds(s.skipFadeSeconds)
    }

    /** Only the fields that changed (iOS `.onChange` per field). */
    fun pushChanges(old: MixSettings, new: MixSettings, sink: MixSettingsSink) {
        if (old.mixGlideSeconds != new.mixGlideSeconds) sink.setMixGlideSeconds(new.mixGlideSeconds)
        if (old.skipFadeSeconds != new.skipFadeSeconds) sink.setSkipFadeSeconds(new.skipFadeSeconds)
        if (old.cueOutputChannel != new.cueOutputChannel) sink.setCueOnRight(new.cueOutputChannel.onRight)
        if (old.beatPulseEnabled != new.beatPulseEnabled) sink.setBeatPulseEnabled(new.beatPulseEnabled)
    }
}

/** Observe the whole Mix settings snapshot (any key change re-emits; equal snapshots are dropped). */
fun AppSettingsStore.mixSettingsFlow(): Flow<MixSettings> = combine(
    listOf<Flow<Any>>(
        flow(MixSettingsKeys.LEAD), flow(MixSettingsKeys.FADE), flow(MixSettingsKeys.SKIP_FADE),
        flow(MixSettingsKeys.GLIDE), flow(MixSettingsKeys.AUTO_HIDE_PLAYED), flow(MixSettingsKeys.CUE_CHANNEL),
        flow(MixSettingsKeys.BEAT_PULSE), flow(MixSettingsKeys.DECK_LAYOUT),
        flow(MixSettingsKeys.VOLUME_GLIDE),
        flow(MixSettingsKeys.DJ_TRANSITIONS), flow(MixSettingsKeys.DJ_EFFECT_SWEEPS),
        flow(MixSettingsKeys.DJ_TEMPO_MATCH), flow(MixSettingsKeys.DJ_KEY_MATCH),
        flow(MixSettingsKeys.DJ_VOLUME_LEVELING), flow(MixSettingsKeys.DJ_TEMPO_WAVES),
        flow(MixSettingsKeys.DJ_POCKETS),
    ),
) { v ->
    MixSettingsRules.clamp(
        MixSettings(
            autoMixLeadSeconds = v[0] as Double,
            autoMixFadeSeconds = v[1] as Double,
            skipFadeSeconds = v[2] as Double,
            mixGlideSeconds = v[3] as Double,
            mixAutoHidePlayed = v[4] as Boolean,
            cueOutputChannel = CueChannel.fromRaw(v[5] as String),
            beatPulseEnabled = v[6] as Boolean,
            mixDeckLayout = DeckLayout.fromRaw(v[7] as String),
            mixVolumeGlide = v[8] as Boolean,
            dj = DJModeSettings(
                transitions = v[9] as Boolean, effectSweeps = v[10] as Boolean, tempoMatch = v[11] as Boolean,
                keyMatch = v[12] as Boolean, volumeLeveling = v[13] as Boolean, tempoWaves = v[14] as Boolean,
                pockets = v[15] as Boolean,
            ),
        ),
    )
}.distinctUntilChanged()

suspend fun AppSettingsStore.mixSettings(): MixSettings = mixSettingsFlow().first()

suspend fun AppSettingsStore.setMixLeadSeconds(v: Double) = set(MixSettingsKeys.LEAD, MixSettingsRules.lead(v))
suspend fun AppSettingsStore.setMixFadeSeconds(v: Double) = set(MixSettingsKeys.FADE, MixSettingsRules.fade(v))
suspend fun AppSettingsStore.setMixSkipFadeSeconds(v: Double) = set(MixSettingsKeys.SKIP_FADE, MixSettingsRules.skipFade(v))
suspend fun AppSettingsStore.setMixGlideSeconds(v: Double) = set(MixSettingsKeys.GLIDE, MixSettingsRules.glide(v))
suspend fun AppSettingsStore.setMixAutoHidePlayed(on: Boolean) = set(MixSettingsKeys.AUTO_HIDE_PLAYED, on)
suspend fun AppSettingsStore.setMixCueChannel(c: CueChannel) = set(MixSettingsKeys.CUE_CHANNEL, c.raw)
suspend fun AppSettingsStore.setMixBeatPulse(on: Boolean) = set(MixSettingsKeys.BEAT_PULSE, on)
suspend fun AppSettingsStore.setMixDeckLayout(l: DeckLayout) = set(MixSettingsKeys.DECK_LAYOUT, l.raw)
suspend fun AppSettingsStore.setMixVolumeGlide(on: Boolean) = set(MixSettingsKeys.VOLUME_GLIDE, on)
suspend fun AppSettingsStore.setDjTransitions(on: Boolean) = set(MixSettingsKeys.DJ_TRANSITIONS, on)
suspend fun AppSettingsStore.setDjEffectSweeps(on: Boolean) = set(MixSettingsKeys.DJ_EFFECT_SWEEPS, on)
suspend fun AppSettingsStore.setDjTempoMatch(on: Boolean) = set(MixSettingsKeys.DJ_TEMPO_MATCH, on)
suspend fun AppSettingsStore.setDjKeyMatch(on: Boolean) = set(MixSettingsKeys.DJ_KEY_MATCH, on)
suspend fun AppSettingsStore.setDjVolumeLeveling(on: Boolean) = set(MixSettingsKeys.DJ_VOLUME_LEVELING, on)
suspend fun AppSettingsStore.setDjTempoWaves(on: Boolean) = set(MixSettingsKeys.DJ_TEMPO_WAVES, on)
suspend fun AppSettingsStore.setDjPockets(on: Boolean) = set(MixSettingsKeys.DJ_POCKETS, on)
