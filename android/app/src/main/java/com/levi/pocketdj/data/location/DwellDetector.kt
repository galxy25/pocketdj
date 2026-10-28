package com.levi.pocketdj.data.location

/**
 * Pure dwell detector: turns a stream of raw location fixes into the [LocationVisitSample] /
 * [LocationFixSample] vocabulary the iOS CLVisit source delivers. No Android APIs, no clock (fix
 * times are passed in), so the whole state machine is JVM-testable.
 *
 * Rules:
 *  - a fix worse than [maxMovementAccuracyM] is ignored outright;
 *  - a fix worse than [maxAnchorAccuracyM] is only ever a movement hint (never anchors / extends a stay /
 *    yields a visit). With no precise anchor yet, the first coarse fix becomes a provisional HINT anchor and
 *    later coarse fixes farther than radius + both accuracies emit hints (approximate-only grants thus
 *    still produce movement hints, but never places);
 *  - the first good fix anchors a candidate stay; further good fixes within [radiusM] extend it;
 *    once stationary for >= [minDwellMs] an OPEN visit (departure = null) is emitted;
 *  - a good fix farther than radius + its accuracy closes an emitted visit (departure = last
 *    in-radius time), is offered as a movement hint, and becomes the new anchor;
 *  - fixes in the radius..radius+accuracy band are ambiguous and change nothing.
 */
class DwellDetector(
    private val radiusM: Double = 150.0,
    private val minDwellMs: Long = 5L * 60 * 1000,
    private val maxAnchorAccuracyM: Double = 200.0,
    private val maxMovementAccuracyM: Double = 3_000.0,
) {
    data class Fix(val latitude: Double, val longitude: Double, val accuracyM: Double, val atMs: Long)

    sealed interface Output {
        data class Visit(val sample: LocationVisitSample) : Output
        data class Hint(val sample: LocationFixSample) : Output
    }

    private var anchor: Fix? = null
    private var coarseAnchor: Fix? = null
    private var lastInRadiusMs: Long = 0
    private var visitEmitted = false

    /** True while an open (departure-less) visit has been emitted and not yet closed. */
    val hasOpenVisit: Boolean get() = visitEmitted

    @Synchronized
    fun onFix(f: Fix): List<Output> {
        if (!f.latitude.isFinite() || !f.longitude.isFinite() || f.accuracyM < 0 || f.accuracyM > maxMovementAccuracyM) {
            return emptyList()
        }
        val a = anchor
        if (f.accuracyM > maxAnchorAccuracyM) {
            // Coarse fix: a hint only. Offer it only when it is plausibly away from the reference.
            val ref = a ?: coarseAnchor
            if (ref == null) { coarseAnchor = f; return emptyList() }
            val d = ListeningPlaceEngine.distanceM(ref.latitude, ref.longitude, f.latitude, f.longitude)
            val slack = if (a == null) maxOf(f.accuracyM, ref.accuracyM) else f.accuracyM
            if (d <= radiusM + slack) return emptyList()
            if (a == null) coarseAnchor = f
            return listOf(hint(f))
        }
        if (a == null) {
            anchor = f; coarseAnchor = null; lastInRadiusMs = f.atMs; visitEmitted = false
            return emptyList()
        }
        if (f.atMs < lastInRadiusMs) return emptyList() // out-of-order delivery
        val d = ListeningPlaceEngine.distanceM(a.latitude, a.longitude, f.latitude, f.longitude)
        return when {
            d <= radiusM -> {
                lastInRadiusMs = f.atMs
                if (!visitEmitted && f.atMs - a.atMs >= minDwellMs) {
                    visitEmitted = true
                    listOf(Output.Visit(open(a)))
                } else emptyList()
            }
            d > radiusM + f.accuracyM -> {
                val out = ArrayList<Output>(2)
                if (visitEmitted) out += Output.Visit(open(a).copy(departureMs = lastInRadiusMs))
                out += hint(f)
                anchor = f; lastInRadiusMs = f.atMs; visitEmitted = false
                out
            }
            else -> emptyList()
        }
    }

    @Synchronized
    fun reset() { anchor = null; coarseAnchor = null; visitEmitted = false; lastInRadiusMs = 0 }

    /** The small persisted state (precise anchor + dwell bookkeeping) so a killed process resumes the stay. */
    @Synchronized
    fun snapshot(): String? = anchor?.let {
        listOf(it.latitude, it.longitude, it.accuracyM, it.atMs, lastInRadiusMs, if (visitEmitted) 1 else 0).joinToString(",")
    }

    @Synchronized
    fun restore(encoded: String?) {
        val p = encoded?.split(",") ?: return
        if (p.size != 6) return
        val lat = p[0].toDoubleOrNull(); val lon = p[1].toDoubleOrNull(); val acc = p[2].toDoubleOrNull()
        val at = p[3].toLongOrNull(); val last = p[4].toLongOrNull(); val emitted = p[5].toIntOrNull()
        if (lat == null || lon == null || acc == null || at == null || last == null || emitted == null) return
        anchor = Fix(lat, lon, acc, at); lastInRadiusMs = last; visitEmitted = emitted == 1
    }

    private fun open(a: Fix) = LocationVisitSample(a.latitude, a.longitude, a.accuracyM, arrivalMs = a.atMs, departureMs = null)
    private fun hint(f: Fix) = Output.Hint(LocationFixSample(f.latitude, f.longitude, f.accuracyM, f.atMs))
}
