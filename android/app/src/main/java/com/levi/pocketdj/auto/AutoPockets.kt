package com.levi.pocketdj.auto

import com.levi.pocketdj.data.pockets.wheel.PocketBestMatch
import com.levi.pocketdj.data.pockets.wheel.PocketMoment
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import com.levi.pocketdj.data.pockets.wheel.PocketProfile

/** What Android Auto reads from the Pocket Wheel. Production: [com.levi.pocketdj.data.pockets.wheel.PocketWheelController]. */
interface AutoPocketsSource {
    /** The last computed best match for now (null before the first refresh). */
    fun best(): PocketBestMatch.Result?

    /** The top [count] moments within +-1 h of now across modes. */
    fun momentsNow(count: Int): List<PocketMoment>

    fun collectionNames(): Map<String, String>

    /** Recompute the answer for now with the car counted as connected (Auto only ever runs in a car). */
    suspend fun refresh()
}

/** What a pocket row starts. Resolved purely so the car glue only executes it. */
sealed interface AutoPocketPlay {
    data object ForNow : AutoPocketPlay
    data class Moment(val key: PocketMomentKey) : AutoPocketPlay
}

/**
 * The Pocket Wheel in the car (iOS `CarPlayModel+PocketWheel`, P2-POC-16). A template can't draw a wheel, so the car
 * gets the wheel's ANSWER: a top "▶ Pocket for now" row on For You (subtitle `<collection> · Tue 8 AM`) and a short
 * "Pockets right now" folder of the moments within +-1 h of now. Read-only and synchronous: [refresh] is the host's
 * job (on root fetch), never this class's.
 */
class AutoPockets(private val source: AutoPocketsSource) {

    /** "▶ Pocket for now": null when the wheel has nothing to offer (no answer yet, or a truly empty profile). */
    fun nowRow(): AutoNode? {
        val p = source.best()?.profile ?: return null
        if (p.tier == PocketProfile.Tier.EMPTY && p.collections.isEmpty()) return null
        val names = source.collectionNames()
        val name = p.dominantCollectionId?.let { names[it] }
        val whenLabel = p.key?.let { "${PocketMomentKey.weekdayAbbrev[it.dow - 1]} ${PocketMomentKey.hourLabel(it.hour)}" } ?: p.caption
        return AutoNode(
            id = AutoId.PocketNow.encoded,
            title = NOW_TITLE,
            subtitle = listOfNotNull(name, whenLabel).joinToString(" · "),
            playable = true,
        )
    }

    private fun momentNodes(): List<AutoNode> {
        val names = source.collectionNames()
        return source.momentsNow(MOMENT_COUNT).map { m ->
            AutoNode(
                id = AutoId.PocketMoment(m.key).encoded,
                title = m.key.shortLabel,
                subtitle = PocketProfile.detail(m.dominantCollectionId, m.directPlays, names),
                playable = true,
            )
        }
    }

    /** The folder row, only when at least one moment is near now. */
    fun listRow(): AutoNode? {
        val n = source.momentsNow(MOMENT_COUNT).size
        if (n == 0) return null
        return AutoNode(
            id = AutoId.PocketList.encoded,
            title = LIST_TITLE,
            subtitle = if (n == 1) "1 moment" else "$n moments",
            browsable = true,
            childPlayableStyle = AutoStyle.LIST,
            childCount = n,
        )
    }

    /** The rows above the For You tiles. */
    fun forYouRows(): List<AutoNode> = listOfNotNull(nowRow(), listRow())

    fun listChildren(): List<AutoNode> =
        momentNodes().ifEmpty { listOf(AutoNode(AutoId.Empty(AutoId.PocketList.encoded).encoded, "No pockets near now yet")) }

    fun item(id: AutoId): AutoNode? = when (id) {
        AutoId.PocketNow -> nowRow()
        AutoId.PocketList -> listRow()
        is AutoId.PocketMoment -> momentNodes().firstOrNull { it.id == id.encoded }
        else -> null
    }

    fun plan(id: AutoId): AutoPocketPlay? = when (id) {
        AutoId.PocketNow -> AutoPocketPlay.ForNow
        is AutoId.PocketMoment -> AutoPocketPlay.Moment(id.key)
        else -> null
    }

    /** Changes whenever the rows would: lets the host re-notify only on a real change. */
    fun signature(): String =
        (forYouRows() + momentNodes()).joinToString("|") { "${it.id}~${it.subtitle}" }

    companion object {
        const val NOW_TITLE = "▶ Pocket for now"
        const val LIST_TITLE = "Pockets right now"
        const val MOMENT_COUNT = 5
    }
}
