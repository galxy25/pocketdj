import Foundation

/// The WS-D → WS-E seam: the Collector's Puzzle decision log projected onto the
/// recommendation engine's `RecPuzzleEventWire`.
///
/// The two workstreams shipped it open on purpose — `RecommendationService` declares
/// `puzzleEventsProvider` and must never reference a Games type beyond the wire struct, and
/// `PuzzleDecisionStore` owns the decisions. This file is the ONLY place the two meet, and
/// `PocketDJApp` installs it.
///
/// WHY ONLY `assigned` DECISIONS RIDE (the load-bearing decision here): the server treats a
/// puzzle event as a POSITIVE taste signal in both places it reads one —
/// `scripts/lambda/rec-engine/index.mjs` gives any song named by a puzzle event a flat +0.5
/// seed bonus, and it credits a collection that received one with "Matches your Collector's
/// Puzzle picks". The wire has no notion of a negative event. So uploading `skipped` /
/// `expired` rows — songs the player explicitly PASSED ON, or let play out — would invert
/// their meaning and recommend back exactly what was rejected. Those rows stay on-device
/// (they are still synced + kept for the game's own summaries); only a decision that FILED a
/// song into a collection leaves the device, as `action: "added"`.
enum PuzzleRecEventBridge {

    /// The store's action string for "filed into a collection" — the only exported decision.
    static let assignedAction = "assigned"
    /// The wire action the rec engine's ingest + suggestion code speaks (never rename: the
    /// wire-value doctrine in `RecModels.swift`).
    static let wireAction = "added"
    /// One filing is worth one point in `CollectorsPuzzleEngine.assign(toTargetIndex:)`.
    static let pointsPerAssignment = 1

    /// Pure projection — every exported row is an `assigned` decision at/after `sinceMs`,
    /// oldest first (the order `RecommendationService` batches + advances its cursor in).
    ///
    /// `sinceMs` is the engine's cursor floor, NOT a state this seam keeps: the cursor lives
    /// in `RecommendationService.SyncState.lastPuzzleAtMs` (advanced only on a 2xx, with a
    /// trailing overlap window + an ack list so a CloudKit-merged peer row that arrives
    /// "behind" the cursor still gets one chance to upload). The projection is therefore
    /// idempotent and safe to call repeatedly with the same floor.
    static func events(from decisions: [PuzzleDecisionStore.Decision],
                       sinceMs: Double) -> [RecPuzzleEventWire] {
        decisions
            .filter { $0.at >= sinceMs && $0.action == assignedAction && $0.collectionId != nil }
            .sorted { $0.at < $1.at }
            .map {
                RecPuzzleEventWire(id: $0.id.uuidString,
                                   atMs: $0.at,
                                   gameId: GameKind.collectorsPuzzle.rawValue,
                                   songId: $0.songId,
                                   collectionId: $0.collectionId,
                                   action: wireAction,
                                   points: pointsPerAssignment)
            }
    }
}

extension PuzzleDecisionStore {
    /// This store's decisions as recommendation-engine events since the engine's cursor.
    /// Installed on `RecommendationService.puzzleEventsProvider` in `PocketDJApp`.
    func recPuzzleEvents(sinceMs: Double) -> [RecPuzzleEventWire] {
        PuzzleRecEventBridge.events(from: decisions, sinceMs: sinceMs)
    }
}
