package com.levi.pocketdj.data.location

/**
 * Pure dwell detector: turns a stream of raw location fixes into the [LocationVisitSample] /
 * [LocationFixSample] vocabulary the iOS CLVisit source delivers. No Android APIs, no clock (fix
 * times are passed in), so the whole state machine is JVM-testable.
 *
 * Rules:
 *  - a fix worse than [maxMovementAccuracyM] is ignored outright;
 *  - a fix worse than [maxAnchorAccuracyM] is only ever a movement hint (never anchors / extends a stay);
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
            // Coarse fix: a hint only. Offer it only when it is plausibly away from the anchor.
            if (a == null) return emptyList()
            val d = ListeningPlaceEngine.distanceM(a.latitude, a.longitude, f.latitude, f.longitude)
            return if (d > radiusM + f.accuracyM) listOf(hint(f)) else emptyList()
        }
        if (a == null) {
            anchor = f; lastInRadiusMs = f.atMs; visitEmitted = false
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
    fun reset() { anchor = null; visitEmitted = false; lastInRadiusMs = 0 }

    private fun open(a: Fix) = LocationVisitSample(a.latitude, a.longitude, a.accuracyM, arrivalMs = a.atMs, departureMs = null)
    private fun hint(f: Fix) = Output.Hint(LocationFixSample(f.latitude, f.longitude, f.accuracyM, f.atMs))
}
