import Foundation
import AppIntents
import CoreSpotlight

// "Donating your app's data and actions to the system" — the two channels that
// actually move the needle (per Apple's docs + the WWDC26 forums guidance):
//
//   • ENTITIES → Core Spotlight: playlists + pockets are indexed as AppEntities so
//     Spotlight finds them by name, tapping a result runs the matching OpenIntent,
//     and Apple Intelligence can resolve them as intent parameters. Re-indexed
//     (debounced) after every collections mutation; upsert-by-id + a full wipe of
//     our named index keeps deletions honest for these small sets.
//
//   • ACTIONS → intent donations: when the user performs the equivalent action in
//     the UI (▶/🔀 a playlist/pocket, start an auto-mix), donate a fully-
//     parameterized intent so the prediction engine can suggest it (Lock Screen /
//     Siri Suggestions / Smart Stack). Never donated from inside `perform()` — the
//     system auto-donates its own executions.

@MainActor
enum CollectionsSpotlight {
    static let indexName = "pocketdj-collections"
    private static var pending: Task<Void, Never>?

    /// Debounced full re-index (mutations often come in bursts — imports, seeds).
    static func scheduleReindex(_ collections: CollectionsStore) {
        guard donationsEnabled else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await reindex(collections)
        }
    }

    static func reindex(_ collections: CollectionsStore) async {
        let playlists = PlaylistEntity.all(in: collections)
        let pockets = PocketEntity.all(in: collections)
        let index = CSSearchableIndex(name: indexName)
        // Wipe-then-write our own named index: upserts alone would strand renamed-away
        // or deleted items; the sets are small (dozens) so a full rewrite is cheap.
        try? await index.deleteAllSearchableItems()
        if !playlists.isEmpty { try? await index.indexAppEntities(playlists) }
        if !pockets.isEmpty { try? await index.indexAppEntities(pockets) }
    }

    /// Donations/indexing are real system side effects — keep fixture-driven test
    /// runs from polluting the simulator's Spotlight index or prediction store.
    static var donationsEnabled: Bool {
        ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] == nil
    }
}

/// One-line hooks the views call at the moment the user completes the action.
/// Parameters that predict future behavior (which collection, shuffled or not) are
/// filled; sync fire-and-forget donation (failures are non-events).
@MainActor
enum IntentDonations {
    static func playedPlaylist(_ playlist: Playlist?, shuffle: Bool) {
        guard CollectionsSpotlight.donationsEnabled, let playlist else { return }
        if shuffle {
            let intent = ShufflePlaylistIntent()
            intent.playlist = PlaylistEntity(playlist)
            IntentDonationManager.shared.donate(intent: intent)
        } else {
            let intent = PlayPlaylistIntent()
            intent.playlist = PlaylistEntity(playlist)
            intent.shuffle = false
            IntentDonationManager.shared.donate(intent: intent)
        }
    }

    static func playedPocket(_ pocket: Pocket?, shuffle: Bool) {
        guard CollectionsSpotlight.donationsEnabled, let pocket else { return }
        if shuffle {
            let intent = ShufflePocketIntent()
            intent.pocket = PocketEntity(pocket)
            IntentDonationManager.shared.donate(intent: intent)
        } else {
            let intent = PlayPocketIntent()
            intent.pocket = PocketEntity(pocket)
            intent.shuffle = false
            IntentDonationManager.shared.donate(intent: intent)
        }
    }

    static func startedAutoMix(source: MixSource, shuffle: Bool, collections: CollectionsStore) {
        guard CollectionsSpotlight.donationsEnabled else { return }
        let entity: AutoMixSourceEntity?
        switch source {
        case .pocket(let id):  entity = collections.pocket(id).map(AutoMixSourceEntity.init(pocket:))
        case .setlist(let id): entity = collections.setlist(id).map(AutoMixSourceEntity.init(setlist:))
        }
        guard let entity else { return }
        let intent = StartAutoMixIntent()
        intent.source = entity
        intent.shuffle = shuffle
        IntentDonationManager.shared.donate(intent: intent)
    }
}
