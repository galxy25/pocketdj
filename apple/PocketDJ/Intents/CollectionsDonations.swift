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
            // 15s, not 2s: saves come in bursts, and the burst that matters most is a
            // play/shuffle save whose 2s-deferred reindex landed EXACTLY under the user's
            // back-navigation out of the collection. Spotlight/Siri freshness is not a
            // seconds-scale contract; the index content is unchanged.
            try? await Task.sleep(for: .seconds(15))
            guard gen == generation else { return }
            PocketDJShortcuts.updateAppShortcutParameters()
            await reindex(collections, generation: gen)
            guard gen == generation else { return }
            await schemaReindexHook?()
        }
    }

    private static func reindex(_ collections: CollectionsStore, generation gen: Int) async {
        #if os(tvOS)
        // No Spotlight on tvOS — entity donation is a no-op there.
        _ = collections
        #else
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
        #endif
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
    // ▶/🔀 donate the COLLECTION intents (1.0.4): they are the App Shortcuts + Siri AI tools that
    // replaced the per-kind Play/Shuffle Playlist/Pocket shortcuts, so predictions should learn them.
    static func playedPlaylist(_ playlist: Playlist?, shuffle: Bool) {
        guard let playlist, playlist.id != nowPlayingPlaylistId else { return }
        playedCollection(CollectionEntity(playlist: playlist), shuffle: shuffle)
    }

    static func playedPocket(_ pocket: Pocket?, shuffle: Bool) {
        guard let pocket else { return }
        playedCollection(CollectionEntity(pocket: pocket), shuffle: shuffle)
    }

    private static func playedCollection(_ entity: CollectionEntity, shuffle: Bool) {
        guard CollectionsSpotlight.donationsEnabled else { return }
        if shuffle {
            let intent = ShuffleCollectionIntent()
            intent.collection = entity
            IntentDonationManager.shared.donate(intent: intent)
        } else {
            let intent = PlayCollectionIntent()
            intent.collection = entity
            intent.shuffle = false
            IntentDonationManager.shared.donate(intent: intent)
        }
    }

    /// The Add-to sheet / context menu added a SONG to a pocket or playlist (`AddToActions.add`).
    /// Donated as "add this song to <collection>" — the collection is the predictive part.
    static func addedSong(to target: AddTarget, collections: CollectionsStore) {
        guard CollectionsSpotlight.donationsEnabled else { return }
        let entity: CollectionEntity?
        switch target.kind {
        case .pocket: entity = collections.pocket(target.id).map(CollectionEntity.init(pocket:))
        case .playlist:
            entity = target.id == nowPlayingPlaylistId ? nil
                : collections.playlist(target.id).map(CollectionEntity.init(playlist:))
        }
        guard let entity else { return }
        let intent = AddCurrentSongToCollectionIntent()
        intent.collection = entity
        IntentDonationManager.shared.donate(intent: intent)
    }

    /// The Now Playing Mix Mode capsule was switched.
    static func setMixMode(_ on: Bool) {
        guard CollectionsSpotlight.donationsEnabled else { return }
        IntentDonationManager.shared.donate(intent: SetMixModeIntent(state: on ? .on : .off))
    }

    /// A Now Playing stem pad was tapped (`muted` = the state it landed in).
    static func toggledStem(_ name: String, muted: Bool) {
        guard CollectionsSpotlight.donationsEnabled, let stem = StemPart(rawValue: name) else { return }
        if muted { IntentDonationManager.shared.donate(intent: MuteStemIntent(stem: stem)) }
        else { IntentDonationManager.shared.donate(intent: UnmuteStemIntent(stem: stem)) }
    }

    static func startedAutoMix(source: MixSource, shuffle: Bool, collections: CollectionsStore) {
        guard CollectionsSpotlight.donationsEnabled else { return }
        let entity: AutoMixSourceEntity?
        switch source {
        case .pocket(let id):   entity = collections.pocket(id).map(AutoMixSourceEntity.init(pocket:))
        case .playlist(let id): entity = collections.playlist(id).map(AutoMixSourceEntity.init(playlist:))
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
