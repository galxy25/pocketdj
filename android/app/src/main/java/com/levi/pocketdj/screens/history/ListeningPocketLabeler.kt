package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.location.ListeningContextProviding
import com.levi.pocketdj.data.pockets.ListeningPocketFeature
import com.levi.pocketdj.data.pockets.ListeningPocketNumeric
import com.levi.pocketdj.data.pockets.ListeningPocketDim
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Turns result features into display text (port of iOS `ListeningPocketLabeler`): on-device
 * place/trip labels, chip selection, and the local date/time a pocket happened at (in ITS OWN
 * UTC offset, not the device's). PURE (no Android deps).
 *
 * Place / trip chips are RE-LABELLED ON DEVICE: the cloud titled them with the labels uploaded
 * at the time, but ranks move, and only this device knows today's. With a location engine ACTIVE
 * it is the authority (an id it no longer knows reads "Earlier place"); with none (Android ships
 * a Noop provider) the cloud's last uploaded snapshot, then the feature's own label, names it.
 */
class ListeningPocketLabeler(
    private val results: ListeningPocketsResults?,
    private val provider: ListeningContextProviding? = null,
    /** Collection id -> LOCAL name, for `collection` features (the server only knows ids). */
    private val collectionNames: Map<String, String> = emptyMap(),
) {
    fun contextLabel(tag: ListeningContextTag, fallback: String? = null): String {
        val p = provider
        if (p != null && p.isSupported && p.isActive) return p.label(tag) ?: EARLIER_PLACE
        return results?.snapshotLabel(tag) ?: fallback ?: EARLIER_PLACE
    }

    fun label(f: ListeningPocketFeature): String {
        f.contextTag?.let { return contextLabel(it, fallback = f.label) }
        if (f.kind == ListeningPocketDim.COLLECTION) return collectionNames[f.value] ?: EARLIER_COLLECTION
        return f.label
    }

    /** Up to [limit] chips: the defining BPM range first, then categorical features in score order. */
    fun chips(features: List<ListeningPocketFeature>, numeric: Map<String, ListeningPocketNumeric>, limit: Int = 4): List<String> {
        val out = ArrayList<String>()
        numeric["bpm"]?.takeIf { it.defining }?.let { out += bpmText(it) }
        for (f in features) {
            if (out.size >= limit) break
            val text = label(f)
            if (text !in out) out += text
        }
        return out.take(limit)
    }

    companion object {
        const val EARLIER_PLACE = "Earlier place"
        const val EARLIER_COLLECTION = "Earlier collection"

        /**
         * Names for just the collection ids [results] mentions (pockets, playlists, then source
         * playlists without overriding) - empty when it mentions none. Names stay LOCAL.
         */
        fun collectionNames(
            results: ListeningPocketsResults?,
            pockets: List<Pair<String, String>>,
            playlists: List<Pair<String, String>>,
            sources: List<Pair<String, String>>,
        ): Map<String, String> {
            if (results == null) return emptyMap()
            val wanted = HashSet<String>()
            for (p in results.pockets) for (f in p.features) if (f.kind == ListeningPocketDim.COLLECTION) wanted += f.value
            for (p in results.patterns) for (f in p.features) if (f.kind == ListeningPocketDim.COLLECTION) wanted += f.value
            if (wanted.isEmpty()) return emptyMap()
            val out = LinkedHashMap<String, String>()
            for ((id, n) in pockets) if (id in wanted) out[id] = n
            for ((id, n) in playlists) if (id in wanted) out[id] = n
            for ((id, n) in sources) if (id in wanted && id !in out) out[id] = n
            return out
        }

        fun bpmText(n: ListeningPocketNumeric): String {
            val lo = n.lo.roundToInt(); val hi = n.hi.roundToInt()
            return if (lo == hi) "$lo BPM" else "$lo–$hi BPM"
        }

        /** The pocket's own offset, or null when absent/out of range (java rejects beyond +-18h; iOS falls back to current). */
        internal fun zoneFor(tzOffsetMin: Int?): ZoneOffset? =
            tzOffsetMin?.takeIf { kotlin.math.abs(it) <= 18 * 60 }?.let { runCatching { ZoneOffset.ofTotalSeconds(it * 60) }.getOrNull() }

        /** Localized day pattern (iOS "EEEdMMM" template), e.g. "EEE, MMM d" in en_US. Injectable for pure tests. */
        var dayPattern: (Locale, String) -> String = { loc, skel -> bestPattern(loc, skel) }
        /** 24h clock preference; null = follow the locale. Set from the system setting by the app. */
        var is24Hour: () -> Boolean? = { null }

        private fun bestPattern(loc: Locale, skel: String): String =
            runCatching { android.text.format.DateFormat.getBestDateTimePattern(loc, skel) }.getOrNull()
                ?: if (skel == "EEEdMMM") "EEE, d MMM" else "d MMM"

        /** "Fri, 10 Oct · 7:40 AM" in the pocket's own offset (device zone when unknown). */
        fun whenText(ms: Double, tzOffsetMin: Int?, locale: Locale = Locale.getDefault(), deviceZone: ZoneId = ZoneId.systemDefault()): String {
            val zone: ZoneId = zoneFor(tzOffsetMin) ?: deviceZone
            val at = Instant.ofEpochMilli(ms.toLong()).atZone(zone)
            val day = DateTimeFormatter.ofPattern(dayPattern(locale, "EEEdMMM"), locale).format(at)
            val h24 = is24Hour()
            val time = if (h24 == null) DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).format(at)
            else DateTimeFormatter.ofPattern(if (h24) "HH:mm" else "h:mm a", locale).format(at)
            return "$day · $time"
        }

        /** "last Tue" within 6.5 days, else "last 3 Oct". */
        fun lastText(ms: Double?, nowMs: Double = System.currentTimeMillis().toDouble(),
                     locale: Locale = Locale.getDefault(), zone: ZoneId = ZoneId.systemDefault()): String? {
            if (ms == null) return null
            val at = Instant.ofEpochMilli(ms.toLong()).atZone(zone)
            val pattern = if ((nowMs - ms) / 1000.0 < 6.5 * 86_400) "EEE" else dayPattern(locale, "dMMM")
            return "last " + DateTimeFormatter.ofPattern(pattern, locale).format(at)
        }

        fun pct(x: Double): String = "${(x * 100).roundToInt()} %"

        /** Dispersion vs the baseline spread -> plain words. */
        fun tightness(n: ListeningPocketNumeric): String {
            val r = n.dispersionRatio ?: return "a steady range"
            return when {
                r <= 0.25 -> "much tighter than usual"
                r <= 0.5 -> "tighter than usual"
                else -> "about as varied as usual"
            }
        }
    }
}
