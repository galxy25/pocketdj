import SwiftUI

/// What the wheel's buttons do — supplied by the app graph (Phase 4/5: best match + runs). nil
/// closures hide/disable the matching control, so the wheel renders standalone (previews, tests).
struct PocketWheelActions {
    /// The centre ▶ caption + colour, when a best match exists.
    var bestMatch: PocketWheelBestMatchSummary?
    var playBest: (() -> Void)?
    /// Long-press alternatives on the centre ▶.
    var alternatives: [PocketWheelBestMatchSummary] = []
    var playAlternative: ((PocketWheelBestMatchSummary) -> Void)?
    /// ▶ Play this pocket on a cell's card.
    var playMoment: ((PocketMomentKey) -> Void)?
    /// A run is playing: its progress (played-through / 100) and moment.
    var runProgress: (done: Int, total: Int, key: PocketMomentKey?)?
    var pauseRun: (() -> Void)?
    /// Past runs of a moment (card's "learning" strip): (date label, songs played through, skip rate).
    var runHistory: ((PocketMomentKey) -> [PocketRunHistoryRow])?

    static let none = PocketWheelActions()
}

/// One centre-button target.
struct PocketWheelBestMatchSummary: Equatable, Identifiable {
    var id: String { key?.token ?? caption }
    var key: PocketMomentKey?
    /// Line 1: "Tue 8 AM · CarPlay" (or a tier phrase: "Weekday mornings").
    var caption: String
    /// Line 2: "Potential · 23 plays".
    var detail: String
    var collectionId: String?
}

struct PocketRunHistoryRow: Equatable, Identifiable {
    var id: UUID
    var label: String
    var playedThrough: Int
    var skipRate: Double
}

private struct PocketWheelActionsKey: EnvironmentKey {
    static let defaultValue = PocketWheelActions.none
}
extension EnvironmentValues {
    var pocketWheelActions: PocketWheelActions {
        get { self[PocketWheelActionsKey.self] }
        set { self[PocketWheelActionsKey.self] = newValue }
    }
}
