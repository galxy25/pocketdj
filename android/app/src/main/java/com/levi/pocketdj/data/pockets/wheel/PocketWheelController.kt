package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.games.inthepocket.InThePocketContext
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** What the centre play button / alternatives row shows for one profile (iOS `PocketWheelBestMatchSummary`). */
data class PocketWheelBestMatchSummary(val key: PocketMomentKey?, val caption: String, val detail: String, val collectionId: String?)

/**
 * The app-scoped glue between the wheel, its centre play button, Android Auto and Assistant (iOS
 * `PocketWheelController`, design §10.3): reads NOW (time, day, car projection, motion, place guess, the last 45
 * minutes) and asks [PocketBestMatch] for the pocket that fits; plays a pocket through the [play] seam (the adaptive
 * run store, P2-POC-7). Every input is a seam, so the whole thing is JVM-testable.
 */
class PocketWheelController(
    private val snapshot: () -> PocketWheelSnapshot,
    private val historyEvents: () -> List<PlayEvent>,
) {
    private val _result = MutableStateFlow<PocketBestMatch.Result?>(null)
    val result: StateFlow<PocketBestMatch.Result?> = _result.asStateFlow()

    @Volatile var computedAtMs: Double = 0.0
        private set
    @Volatile var lastNow: PocketBestMatch.Now? = null
        private set

    var clockMs: () -> Double = { System.currentTimeMillis().toDouble() }

    /** Minutes from UTC at [atMs] (the device zone, DST-aware). */
    var tzOffsetMin: (Double) -> Int = { java.util.TimeZone.getDefault().getOffset(it.toLong()) / 60_000 }

    /** Android Auto (car projection) connected right now. */
    var carConnected: () -> Boolean = { false }

    /** The motion timeline's dominant token over the last 5 min (P2-POC-11/12), null when absent / unopted. */
    var motionNow: suspend () -> String? = { null }

    /** The place engine's current place / trip guess. */
    var contextGuess: () -> ListeningContextTag? = { null }

    /** T2: the cloud's results when the pockets opt-in is on. */
    var cloudResults: () -> ListeningPocketsResults? = { null }

    /** T4: the most recently played collection, else Favorites (fav_songs), else the first collection. */
    var emptyFallback: () -> PocketProfile? = { null }

    /** Collection attribution of one play (the moment engine's rule, with live collections). */
    var attribute: (PlayEvent) -> Map<String, Double> = { e -> e.originCollectionId?.let { mapOf(it to 1.0) } ?: emptyMap() }

    /** Start a pocket (P2-POC-7: `PocketRunStore.start`). Returns whether a run actually started. */
    var play: suspend (PocketProfile) -> Boolean = { false }

    /** Recompute the best match for NOW. [carOverride] counts the car as connected (an Android Auto session is one by definition). */
    suspend fun refresh(carOverride: Boolean = false): PocketBestMatch.Result {
        val nowMs = clockMs()
        val tz = tzOffsetMin(nowMs)
        val local = PocketClock.local(nowMs, tz)
        val guess = contextGuess()
        val motion = try { motionNow() } catch (e: kotlin.coroutines.cancellation.CancellationException) { throw e } catch (e: Exception) { null }
        val (recentColls, recentSkips) = PocketBestMatch.recentActivity(historyEvents(), nowMs, attribute)
        val n = PocketBestMatch.Now(
            hour = local.fractionalHour,
            dow = local.dow,
            mode = PocketBestMatch.modeNow(carOverride || carConnected(), motion, guess),
            ctx = PocketMomentEngine.contextKey(guess).takeIf { it != "none" },
            recentCollections = recentColls,
            recentSkipRate = recentSkips,
        )
        var cloud: PocketProfile? = null
        var boosted: Set<String> = emptySet()
        val results = cloudResults()
        if (results != null && results.generatedAtMs != null) {
            val ctx = InThePocketContext.make(nowMs, tz, guess)
            val input = InThePocketScorer.Input(
                context = ctx, results = results, catalog = emptyMap(), playableIds = emptySet(), nowMs = nowMs, seed = 0uL,
            )
            InThePocketScorer.cloudProfile(input)?.let { cloud = PocketBestMatch.cloudProfile(it) }
            if ((results.roundLearning?.pocketRate ?: 0.0) >= 0.5) boosted = results.patterns.map { it.id }.toSet()
        }
        val r = PocketBestMatch.best(snapshot(), n, PocketBestMatch.Fallbacks(cloud, emptyFallback(), boosted))
        _result.value = r
        lastNow = n
        computedAtMs = nowMs
        return r
    }

    /** The best pocket for NOW with the mode forced (a run re-targeting mid-run); null when nothing fits. */
    suspend fun profileForMode(mode: PocketMode): PocketProfile? {
        refresh()
        val n = lastNow ?: return null
        val r = PocketBestMatch.best(snapshot(), n.copy(mode = mode))
        return if (r.profile.tier == PocketProfile.Tier.EMPTY) null else r.profile
    }

    /** Recompute if the answer is older than a minute (cheap; called on appear + by Android Auto). */
    suspend fun refreshIfStale() {
        if (clockMs() - computedAtMs > 60_000) refresh()
    }

    suspend fun playBest(): Boolean = play(refresh().profile)

    suspend fun playMoment(key: PocketMomentKey): Boolean {
        val snap = snapshot()
        val m = snap.index()[key] ?: return false
        return play(PocketProfile.from(m, snap.collectionNames))
    }

    suspend fun playAlternative(alternative: PocketWheelBestMatchSummary): Boolean {
        val key = alternative.key ?: return false
        return playMoment(key)
    }

    /** The top [count] moments within +-1 h of now across modes (Android Auto's "Pockets right now"). */
    fun momentsNow(count: Int = 5): List<PocketMoment> {
        val n = lastNow ?: return emptyList()
        val scored = ArrayList<Pair<PocketMoment, Double>>()
        for (m in snapshot().moments) {
            if (m.plays <= 0) continue
            // Hour cells are centred at +0.5, so +-1 h of now is a 1.5 h circular distance.
            if (PocketBestMatch.circularHours(n.hour, m.key.hour.toDouble() + 0.5) > 1.5) continue
            scored += m to PocketBestMatch.score(m, n, emptySet()).score
        }
        scored.sortWith { a, b -> if (a.second != b.second) b.second.compareTo(a.second) else a.first.key.compareTo(b.first.key) }
        return scored.take(count).map { it.first }
    }

    // View glue

    val collectionNames: Map<String, String> get() = snapshot().collectionNames
    fun collectionName(id: String): String? = snapshot().collectionNames[id]

    val bestSummary: PocketWheelBestMatchSummary? get() = _result.value?.let { summary(it.profile) }
    val alternativeSummaries: List<PocketWheelBestMatchSummary> get() = _result.value?.alternatives?.map(::summary).orEmpty()

    companion object {
        fun summary(p: PocketProfile) = PocketWheelBestMatchSummary(p.key, p.caption, p.detail, p.dominantCollectionId)
    }
}
