package com.levi.pocketdj.data.games.puzzle

import kotlinx.serialization.Serializable

/**
 * The recommendation engine's puzzle-event wire row (iOS `RecPuzzleEventWire`). Field
 * names are the wire contract and never rename.
 */
@Serializable
data class RecPuzzleEventWire(
    val id: String,
    val atMs: Double,
    val gameId: String? = null,
    val songId: String? = null,
    val collectionId: String? = null,
    val action: String,
    val points: Int? = null,
)

/**
 * The Gem Collector decision log projected onto the rec engine's wire — port of iOS
 * `PuzzleRecEventBridge`.
 *
 * WHY ONLY `assigned` ROWS RIDE: the server reads every puzzle event as a POSITIVE taste
 * signal and the wire has no negative event, so uploading `skipped` / `expired` rows
 * would recommend back exactly what the player rejected. Those rows stay on-device.
 */
object PuzzleRecEventBridge {
    /** The store's action string for "filed into a collection" — the only exported decision. */
    const val ASSIGNED_ACTION = "assigned"

    /** The wire action the rec engine speaks (never rename). */
    const val WIRE_ACTION = "added"

    /** `GameKind.collectorsPuzzle.rawValue`. */
    const val GAME_ID = "collectorsPuzzle"

    /** One filing is worth one point. */
    const val POINTS_PER_ASSIGNMENT = 1

    /**
     * Pure projection: every exported row is an `assigned` decision with a collectionId at
     * or after [sinceMs], oldest first. Idempotent for a given floor.
     */
    fun events(decisions: List<PuzzleDecisionStore.Decision>, sinceMs: Double): List<RecPuzzleEventWire> =
        decisions
            .filter { it.at >= sinceMs && it.action == ASSIGNED_ACTION && it.collectionId != null }
            .sortedBy { it.at }
            .map {
                RecPuzzleEventWire(
                    id = it.id,
                    atMs = it.at,
                    gameId = GAME_ID,
                    songId = it.songId,
                    collectionId = it.collectionId,
                    action = WIRE_ACTION,
                    points = POINTS_PER_ASSIGNMENT,
                )
            }
}
