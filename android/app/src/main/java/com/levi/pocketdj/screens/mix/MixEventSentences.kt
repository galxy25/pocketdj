package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.MixSessionEvent
import java.util.Locale

/** Semantic tint for a timeline card; the composable maps it onto theme/stem colors. */
enum class EventTint { ACCENT, ACCENT2, GREEN, DIM, RED, YELLOW, PURPLE }

/** Icon identity (UI maps to a vector); kept as an enum so the sentence logic stays JVM-testable. */
enum class EventIcon {
    LOAD, PLAY, PAUSE, SEEK, TEMPO, PITCH, VOLUME, CROSSFADER, COMPRESSOR, REVERB, FLANGER, FILTER, FX_GENERIC,
    VARIANT, MOD, EQ, FILTER_HP, FILTER_LP, STEMS, STEM_MUTED, STEM_UNMUTED, STEM_VOLUME, LEAD, SYNC, RESET,
    AUTO_PAUSE, AUTO_RESUME, UNKNOWN,
}

data class EventDisplay(val icon: EventIcon, val text: String, val tint: EventTint)

/** Pure port of iOS `MixEventDisplay`: event -> (icon, human sentence, tint). */
object MixEventSentences {
    fun describe(e: MixSessionEvent): EventDisplay = when (val k = e.kind) {
        MixEventKind.Load -> {
            val who = e.artist?.let { " — $it" } ?: ""
            EventDisplay(EventIcon.LOAD, "Load: ${e.title ?: "track"}$who", EventTint.ACCENT)
        }
        MixEventKind.Play -> EventDisplay(EventIcon.PLAY, "Play", EventTint.GREEN)
        MixEventKind.Pause -> EventDisplay(EventIcon.PAUSE, "Pause", EventTint.DIM)
        MixEventKind.Seek -> EventDisplay(EventIcon.SEEK, "Seek → ${mmss(e.value ?: 0.0)}", EventTint.ACCENT2)
        MixEventKind.Tempo -> EventDisplay(EventIcon.TEMPO, "Tempo → " + f("%.2f×", e.value ?: 1.0), EventTint.ACCENT)
        MixEventKind.Pitch -> EventDisplay(EventIcon.PITCH, "Pitch → " + f("%+.1f", e.value ?: 0.0), EventTint.ACCENT)
        MixEventKind.Volume -> EventDisplay(EventIcon.VOLUME, "Vol → ${pct(e.value)}", EventTint.ACCENT)
        MixEventKind.Crossfader ->
            EventDisplay(EventIcon.CROSSFADER, "Crossfader → " + f("%.2f", e.value ?: 0.5), EventTint.ACCENT2)
        MixEventKind.EffectToggle ->
            EventDisplay(fxIcon(e.param), "${cap(e.param, "FX")} " + (if (e.flag == true) "on" else "off") + slotSuffix(e), EventTint.ACCENT)
        MixEventKind.EffectStrength ->
            EventDisplay(fxIcon(e.param), "${cap(e.param, "FX")} ${pct(e.value)}" + slotSuffix(e), EventTint.ACCENT)
        MixEventKind.EffectSlot ->
            EventDisplay(fxIcon(e.param), "Slot ${slotNo(e)} → ${cap(e.param, "FX")}", EventTint.ACCENT2)
        MixEventKind.EffectVariant ->
            EventDisplay(EventIcon.VARIANT, "Slot ${slotNo(e)} → ${variantLabel(e.param)}", EventTint.ACCENT2)
        MixEventKind.EffectMod ->
            EventDisplay(EventIcon.MOD, "Slot ${slotNo(e)} mod → ${modLabel(e.param, e.value)}", EventTint.ACCENT2)
        MixEventKind.Eq ->
            EventDisplay(EventIcon.EQ, "EQ ${cap(e.param, "band")} → " + f("%+.0f dB", e.value ?: 0.0), EventTint.ACCENT)
        MixEventKind.FilterMode -> {
            val hp = e.param == "highPass"
            EventDisplay(if (hp) EventIcon.FILTER_HP else EventIcon.FILTER_LP,
                "Filter → ${if (hp) "High-pass" else "Low-pass"}", EventTint.ACCENT)
        }
        MixEventKind.StemMode ->
            EventDisplay(EventIcon.STEMS, "Stems " + (if (e.flag == true) "on" else "off"), EventTint.ACCENT2)
        MixEventKind.StemMute -> {
            val muted = e.flag == true
            EventDisplay(if (muted) EventIcon.STEM_MUTED else EventIcon.STEM_UNMUTED,
                "${cap(e.param, "Stem")} " + (if (muted) "muted" else "unmuted"), stemTint(e.param))
        }
        MixEventKind.StemVolume ->
            EventDisplay(EventIcon.STEM_VOLUME, "${cap(e.param, "Stem")} ${pct(e.value)}", stemTint(e.param))
        MixEventKind.Lead ->
            EventDisplay(EventIcon.LEAD, "Lead " + (if (e.flag == true) "set" else "cleared"), EventTint.ACCENT2)
        MixEventKind.Sync -> EventDisplay(EventIcon.SYNC, "Sync → " + f("%.2f×", e.value ?: 1.0), EventTint.ACCENT2)
        MixEventKind.ResetDeck -> EventDisplay(EventIcon.RESET, "Reset deck", EventTint.ACCENT)
        MixEventKind.AutoPause -> EventDisplay(EventIcon.AUTO_PAUSE, "Auto-mix paused", EventTint.DIM)
        MixEventKind.AutoResume -> EventDisplay(EventIcon.AUTO_RESUME, "Auto-mix resumed", EventTint.GREEN)
        MixEventKind.Glide -> glide(e)
        // A kind from a newer build: show its raw string rather than an opaque dash.
        is MixEventKind.Unknown -> EventDisplay(EventIcon.UNKNOWN, k.value, EventTint.DIM)
    }

    private fun glide(e: MixSessionEvent): EventDisplay {
        val from = e.fromValue ?: 0.0
        val to = e.value ?: 0.0
        return when (e.param) {
            "crossfader" -> EventDisplay(EventIcon.CROSSFADER, "Glide · Crossfader " + f("%.2f→%.2f", from, to), EventTint.ACCENT2)
            "tempo" -> EventDisplay(EventIcon.TEMPO, "Glide · Tempo " + f("%.2f×→%.2f×", from, to), EventTint.ACCENT)
            "pitch" -> EventDisplay(EventIcon.PITCH, "Glide · Pitch " + f("%+.1f→%+.1f", from, to), EventTint.ACCENT)
            else -> EventDisplay(fxIcon(e.param), "Glide · ${cap(e.param, "FX")} ${pct(from)}→${pct(to)}", EventTint.ACCENT)
        }
    }

    /** ms -> "m:ss.S" (the session-relative timeline stamp). */
    fun clock(ms: Int): String {
        val v = maxOf(0, ms)
        return String.format(Locale.US, "%d:%02d.%d", v / 60000, (v / 1000) % 60, (v % 1000) / 100)
    }

    /** seconds -> "m:ss" (a seek target; rounds half away from zero like Swift). */
    fun mmss(sec: Double): String {
        val t = Math.round(maxOf(0.0, sec)).toInt()
        return String.format(Locale.US, "%d:%02d", t / 60, t % 60)
    }

    fun fxIcon(name: String?): EventIcon = when (name) {
        "compressor" -> EventIcon.COMPRESSOR
        "reverb" -> EventIcon.REVERB
        "flanger" -> EventIcon.FLANGER
        "filter" -> EventIcon.FILTER
        else -> EventIcon.FX_GENERIC
    }

    fun stemTint(name: String?): EventTint = when (name) {
        "bass" -> EventTint.RED
        "drums" -> EventTint.YELLOW
        "other" -> EventTint.GREEN
        "vocals" -> EventTint.PURPLE
        else -> EventTint.ACCENT
    }

    private fun f(fmt: String, vararg a: Double) = String.format(Locale.US, fmt, *a.toTypedArray())
    private fun pct(v: Double?) = "${Math.round((v ?: 0.0) * 100)}%"

    /** Swift `.capitalized`: first letter of each word up, rest down. */
    internal fun cap(s: String?, fallback: String): String =
        (s ?: fallback).split(" ").joinToString(" ") { w ->
            w.lowercase(Locale.US).replaceFirstChar { it.uppercase(Locale.US) }
        }

    private fun slotNo(e: MixSessionEvent) = "${(e.slot ?: 0) + 1}"
    private fun slotSuffix(e: MixSessionEvent) = e.slot?.let { " (slot ${it + 1})" } ?: ""

    private fun variantLabel(raw: String?): String {
        if (raw == null) return "variant"
        return EffectVariant.fromRaw(raw)?.longLabel ?: cap(raw, "variant")
    }

    /** "lfo:quarter:saw" + depth -> "LFO 1/4 Saw +60%"; "off:..." -> "Off". Unknown pieces pass raw. */
    internal fun modLabel(raw: String?, depth: Double?): String {
        val parts = (raw ?: "").split(":").filter { it.isNotEmpty() }
        val source = ModSource.fromRaw(parts.firstOrNull())
        if (source == null || source == ModSource.OFF) return "Off"
        var out = source.label
        if (source == ModSource.LFO && parts.size > 1) out += " " + (ModRate.fromRaw(parts[1])?.label ?: parts[1])
        if (parts.size > 2) out += " " + (ModShape.fromRaw(parts[2])?.label ?: parts[2])
        if (depth != null) out += f(" %+.0f%%", depth * 100)
        return out
    }
}
