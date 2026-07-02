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
    /// Monotonic reindex generation. `deleteAllSearchableItems` / `indexAppEntities`
    /// don't honor Swift task cancellation, so a superseded reindex could otherwise
    /// finish its wipe-then-write AFTER a newer one and resurrect deleted items —
    /// each await re-checks it's still the newest before touching the index.
    private static var generation = 0

    /// The iOS 27 audio-schema layer's reindex, chained onto the same debounced hook
    /// (set by `AudioSchemaBootstrap.install` when the app is built with the 27 SDK
    /// and running on iOS/macOS 27; nil otherwise).
    static var schemaReindexHook: (@MainActor () async -> Void)?

    /// Debounced full re-donation (mutations often come in bursts — imports, seeds):
    /// re-index the Spotlight entities AND re-teach Siri the speakable names.
    static func scheduleReindex(_ collections: CollectionsStore) {
        guard donationsEnabled else { return }
        generation += 1
        let gen = generation
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard gen == generation else { return }
            PocketDJShortcuts.updateAppShortcutParameters()
            await reindex(collections, generation: gen)
            guard gen == generation else { return }
            await schemaReindexHook?()
        }
    }

    private static func reindex(_ collections: CollectionsStore, generation gen: Int) async {
        let playlists = PlaylistEntity.all(in: collections)
        let pockets = PocketEntity.all(in: collections)
        let index = CSSearchableIndex(name: indexName)
        // Wipe-then-write our own named index: upserts alone would strand renamed-away
        // or deleted items; the sets are small (dozens) so a full rewrite is cheap.
        try? await index.deleteAllSearchableItems()
        guard gen == generation else { return }   // superseded mid-wipe — the newer pass rewrites
        if !playlists.isEmpty { try? await index.indexAppEntities(playlists) }
        guard gen == generation else { return }
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
        case .setlist(let id):
            // The reserved Now Playing scratch setlist is auto-mixable from the Mix tab
            // but filtered from every entity query — donating it would teach Siri a
            // suggestion that can never resolve. Mirror the query's filter.
            guard id != nowPlayingSetlistId else { return }
            entity = collections.setlist(id).map(AutoMixSourceEntity.init(setlist:))
        }
        guard let entity else { return }
        let intent = StartAutoMixIntent()
        intent.source = entity
        intent.shuffle = shuffle
        IntentDonationManager.shared.donate(intent: intent)
    }
}
