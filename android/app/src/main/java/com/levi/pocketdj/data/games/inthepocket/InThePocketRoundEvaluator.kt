package com.levi.pocketdj.data.games.inthepocket

import java.util.UUID

/**
 * IN THE POCKET — the round outcome state machine (port of InThePocketRoundEvaluator.swift).
 * PURE: what the play-history log says happened since ▶ (plus whether the sequencer still runs
 * this round, and the clock) → each song's state and the round's verdict.
 *
 * It invents NO skip detection of its own: every verdict comes from the app's one skip machinery
 * (`wasSkipped` / `listenedFraction` on the history events).
 *
 * Song k STARTS when the next history event (after ▶) is song k. An event for a song the round
 * already played (⏮, a replay) is ignored; any OTHER song is FOREIGN. A song is SKIPPED when its
 * event carries the skip verdict (the first one decides the round). COMPLETED when a later round
 * song started and it was not skipped, or its fraction ≥ 90 %, or — once the round has ENDED —
 * ≥ 50 %, or its fraction is unknown after a foreign play / timeout. SETTLING: an end signal only
 * counts once it is [SETTLE_MS] old (a skip verdict can land one track late).
 */
object InThePocketRoundEvaluator {

    /** One history event, reduced. */
    data class Observation(
        val eventId: UUID,
        val songId: String,
        val playedAtMs: Double,
        val wasSkipped: Boolean,
        val fraction: Double?,
    )

    data class Verdict(
        val states: List<InThePocketSongState>,
        val eventIds: List<UUID?>,
        val fractions: List<Double?>,
        /** null = still in progress. */
        val outcome: InThePocketOutcome?,
        /** Index of the song playing now (null before song 1 / after the end). */
        val currentIndex: Int?,
    )

    const val COMPLETE_FRACTION = 0.9
    const val PLAYED_THROUGH_FRACTION = 0.5
    /** How old an end signal must be before it ends the round. */
    const val SETTLE_MS = 8_000.0
    /** No round activity for this long → abandoned. */
    const val IDLE_TIMEOUT_MS = 3 * 3_600_000.0
    /** ▶ is pressed a beat before the first `record` — events this close before it still count. */
    const val START_TOLERANCE_MS = 2_000.0

    private val VARIANT_SUFFIXES = listOf("_clean", "_explicit")

    /**
     * The base (catalog) song id behind a possibly-variant id (`sng_<12 lowercase hex>_clean|explicit`);
     * identity for plain ids (SongVariant.baseId).
     */
    fun baseId(id: String): String {
        for (suffix in VARIANT_SUFFIXES) {
            if (!id.endsWith(suffix)) continue
            val base = id.dropLast(suffix.length)
            if (!base.startsWith("sng_")) return id
            val hex = base.drop(4)
            if (hex.length != 12 || !hex.all { it in '0'..'9' || it in 'a'..'f' }) return id
            return base
        }
        return id
    }

    /**
     * @param songIds the round's songs, in order.
     * @param events this install's history events (any order; filtered + sorted here).
     * @param ownershipLostAtMs when the sequencer stopped running THIS round (null = still does).
     */
    fun evaluate(
        songIds: List<String>, startedAtMs: Double, events: List<Observation>,
        ownershipLostAtMs: Double?, nowMs: Double,
    ): Verdict {
        val n = songIds.size
        val base = songIds.map(::baseId)
        val after = events.filter { it.playedAtMs >= startedAtMs - START_TOLERANCE_MS }
            .sortedWith(compareBy<Observation> { it.playedAtMs }.thenBy { it.eventId.toString().uppercase() })

        val matched = arrayOfNulls<Observation>(n)
        var cursor = 0
        var foreignAtMs: Double? = null
        var lastActivityMs = startedAtMs
        for (e in after) {
            val id = baseId(e.songId)
            if (cursor < n && id == base[cursor]) {
                matched[cursor] = e
                cursor += 1
                lastActivityMs = maxOf(lastActivityMs, e.playedAtMs)
            } else if (base.subList(0, cursor).contains(id)) {
                lastActivityMs = maxOf(lastActivityMs, e.playedAtMs)   // ⏮ / a replay — not foreign
            } else {
                foreignAtMs = e.playedAtMs
                break
            }
        }

        val endSignal = listOfNotNull(foreignAtMs, ownershipLostAtMs).minOrNull()
        val ended = endSignal?.let { nowMs - it >= SETTLE_MS } ?: false
        val timedOut = nowMs - lastActivityMs >= IDLE_TIMEOUT_MS
        val over = ended || timedOut

        val states = MutableList(n) { InThePocketSongState.PENDING }
        for (k in 0 until cursor) {
            val e = matched[k] ?: continue
            if (e.wasSkipped) { states[k] = InThePocketSongState.SKIPPED; continue }
            if (k < cursor - 1) { states[k] = InThePocketSongState.COMPLETED; continue }
            // The latest-started song.
            val f = e.fraction
            if (f != null && f >= COMPLETE_FRACTION) { states[k] = InThePocketSongState.COMPLETED; continue }
            states[k] = if (over) {
                if (f != null) {
                    if (f >= PLAYED_THROUGH_FRACTION) InThePocketSongState.COMPLETED else InThePocketSongState.PLAYING
                } else if (foreignAtMs != null || timedOut) {
                    InThePocketSongState.COMPLETED   // unknown is a play (pocket detection's rule)
                } else {
                    InThePocketSongState.PLAYING     // the stop checkpoint hasn't landed — never guess "done"
                }
            } else InThePocketSongState.PLAYING
        }

        var outcome: InThePocketOutcome? = null
        val skippedAt = states.indexOf(InThePocketSongState.SKIPPED)
        if (skippedAt >= 0) {
            outcome = InThePocketOutcome.Broke(skippedAt + 1)
        } else if (n > 0 && states.all { it == InThePocketSongState.COMPLETED }) {
            outcome = InThePocketOutcome.Pocket
        } else if (over) {
            // The stop checkpoint can lag the stop itself: an ended round whose last song has no
            // fraction yet waits (bounded by the idle timeout) rather than calling it abandoned.
            val waitingOnCheckpoint = !timedOut && foreignAtMs == null && cursor > 0 && matched[cursor - 1]?.fraction == null
            if (!waitingOnCheckpoint) outcome = InThePocketOutcome.Abandoned
        }
        if (outcome != null) {
            for (k in states.indices) if (states[k] == InThePocketSongState.PENDING) states[k] = InThePocketSongState.NOT_PLAYED
        }
        val current = if (outcome == null && cursor > 0 && states[cursor - 1] == InThePocketSongState.PLAYING) cursor - 1 else null
        return Verdict(states, matched.map { it?.eventId }, matched.map { it?.fraction }, outcome, current)
    }
}
