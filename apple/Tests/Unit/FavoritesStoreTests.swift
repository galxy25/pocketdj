import XCTest
@testable import PocketDJ

/// `FavoritesStore` — the per-profile ♥ document. The three doctrine rules from the type's
/// header are what these tests actually defend:
///
///   1. per-profile, never global (nothing here reaches another user's document);
///   2. Apple Music sync is somebody else's decision — this store only records intent and
///      fires `onChanged` for changes that ORIGINATE on this device;
///   3. an un-♥ is a TOMBSTONE, not an absence — the seed and the Apple Music pull both
///      have to be able to tell "deliberately removed" from "never touched".
@MainActor
final class FavoritesStoreTests: XCTestCase {

    /// A store on a private temp file. `json`, when supplied, pre-seeds the on-disk
    /// document so a test can pin timestamps instead of racing the wall clock.
    private func makeStore(_ json: String? = nil) -> FavoritesStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-favs-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        if let json { try? Data(json.utf8).write(to: url, options: .atomic) }
        return FavoritesStore(fileURL: url)
    }

    // MARK: - Toggle + durability

    func testToggleFlipsStateAndPersistsAcrossReinit() {
        let s = makeStore()
        XCTAssertFalse(s.isFavorite("sng_1"))
        XCTAssertNil(s.entry("sng_1"), "never touched")

        XCTAssertTrue(s.toggle("sng_1", appleMusicId: "111"), "toggle returns the NEW state")
        XCTAssertTrue(s.isFavorite("sng_1"))
        XCTAssertTrue(s.favoriteIds.contains("sng_1"), "the derived hot-path set tracks byId")

        let reopened = FavoritesStore(fileURL: s.syncFileURL)
        XCTAssertTrue(reopened.isFavorite("sng_1"))
        XCTAssertEqual(reopened.entry("sng_1")?.appleMusicId, "111")

        // Flip back through the reopened store, this time without re-supplying the id.
        XCTAssertFalse(reopened.toggle("sng_1", appleMusicId: nil))
        XCTAssertFalse(reopened.isFavorite("sng_1"))
        XCTAssertEqual(reopened.entry("sng_1")?.appleMusicId, "111",
                       "the catalog id is a property of the SONG — losing it would strand the un-♥ push")

        let again = FavoritesStore(fileURL: s.syncFileURL)
        XCTAssertFalse(again.isFavorite("sng_1"))
        XCTAssertEqual(again.entry("sng_1")?.favorited, false)
    }

    /// Rule 3, the load-bearing one.
    func testExplicitUnfavoriteIsATombstoneAndIsNotResurrectedByASeed() {
        let s = makeStore()
        s.toggle("sng_1", appleMusicId: "111")      // ♥
        s.toggle("sng_1", appleMusicId: "111")      // …and deliberately un-♥

        XCTAssertNotNil(s.entry("sng_1"), "an un-♥ is a ROW, not a deletion")
        XCTAssertEqual(s.entry("sng_1")?.favorited, false)
        XCTAssertFalse(s.favoriteIds.contains("sng_1"))

        // The shipped seed lists sng_1 among the owner's ♥. It must stay dead.
        let seeded = s.applySeed(songIds: ["sng_1", "sng_2"],
                                 appleMusicIds: ["sng_1": "111", "sng_2": "222"], version: 1)
        XCTAssertEqual(seeded, 1, "only the untouched song is filled")
        XCTAssertFalse(s.isFavorite("sng_1"), "a seed never resurrects something the user removed")
        XCTAssertEqual(s.entry("sng_1")?.favorited, false)
        XCTAssertTrue(s.isFavorite("sng_2"))
    }

    // MARK: - Seeding

    func testApplySeedFillsOnlyUntouchedSongsIsIdempotentAndBumpsTheVersion() {
        let s = makeStore()
        s.toggle("sng_keep", appleMusicId: "1")                     // already ♥
        s.set("sng_gone", favorited: false, appleMusicId: "2")      // explicit tombstone
        XCTAssertEqual(s.seedVersion, 0)

        XCTAssertEqual(s.applySeed(songIds: ["sng_keep", "sng_gone", "sng_new"], version: 3), 1)
        XCTAssertEqual(s.seedVersion, 3)
        XCTAssertTrue(s.isFavorite("sng_new"))
        XCTAssertTrue(s.isFavorite("sng_keep"))
        XCTAssertFalse(s.isFavorite("sng_gone"))

        // Re-running the SAME version (or an older one) is a no-op, ids and all.
        XCTAssertEqual(s.applySeed(songIds: ["sng_gone", "sng_other"], version: 3), 0)
        XCTAssertEqual(s.applySeed(songIds: ["sng_other"], version: 2), 0)
        XCTAssertNil(s.entry("sng_other"), "a same-version re-run must not sneak in new ids")
        XCTAssertEqual(s.seedVersion, 3)

        // And the watermark is durable, so a relaunch doesn't reseed.
        let reopened = FavoritesStore(fileURL: s.syncFileURL)
        XCTAssertEqual(reopened.seedVersion, 3)
        XCTAssertEqual(reopened.applySeed(songIds: ["sng_gone"], version: 3), 0)
        XCTAssertFalse(reopened.isFavorite("sng_gone"))

        // A genuinely NEWER seed generation does apply — to untouched songs only.
        XCTAssertEqual(reopened.applySeed(songIds: ["sng_gone", "sng_v4"], version: 4), 1)
        XCTAssertTrue(reopened.isFavorite("sng_v4"))
        XCTAssertFalse(reopened.isFavorite("sng_gone"))
    }

    func testSeededEntriesAreMarkedPushedSoTheyNeverWriteUpstream() {
        let s = makeStore()
        s.applySeed(songIds: ["sng_a", "sng_b"], appleMusicIds: ["sng_a": "1", "sng_b": "2"], version: 1)
        XCTAssertTrue(s.isFavorite("sng_a"))
        XCTAssertNotNil(s.entry("sng_a")?.pushedAtMs)
        XCTAssertTrue(s.pendingPushes.isEmpty,
                      "the seed describes the OWNER's Apple Music state — writing it into a tester's account would be the whole bug")
        // Still true after a relaunch, when pendingPushes is recomputed from disk.
        XCTAssertTrue(FavoritesStore(fileURL: s.syncFileURL).pendingPushes.isEmpty)
    }

    // MARK: - The outbound queue

    func testPendingPushesExcludesLocalOnlyAndAlreadyPushedButIncludesARetoggle() throws {
        let s = makeStore()
        s.toggle("sng_vinyl", appleMusicId: nil)      // vinyl / My Digital / Studio
        s.toggle("sng_am", appleMusicId: "999")

        XCTAssertTrue(s.isFavorite("sng_vinyl"), "a local-only ♥ is still a ♥")
        XCTAssertEqual(s.pendingPushes.map(\.songId), ["sng_am"],
                       "no Apple Music identity ⇒ nothing upstream to write, ever")

        let at = try XCTUnwrap(s.entry("sng_am")).atMs
        s.markPushed(songId: "sng_am", pushedAtMs: at)
        XCTAssertTrue(s.pendingPushes.isEmpty, "a mirrored entry leaves the queue")

        // Re-toggling after the push owes upstream a NEW write.
        s.toggle("sng_am", appleMusicId: "999")
        XCTAssertEqual(s.pendingPushes.map(\.songId), ["sng_am"])
        XCTAssertEqual(s.pendingPushes.first?.favorited, false, "the pending write is the un-♥")
        XCTAssertNil(s.pendingPushes.first?.pushedAtMs)
    }

    func testMarkPushedIgnoresAStaleWriteFromAnInFlightRetoggle() throws {
        let s = makeStore()
        s.toggle("sng_1", appleMusicId: "1")
        let at = try XCTUnwrap(s.entry("sng_1")).atMs

        // A push that STARTED before the current edit reports success afterwards. Accepting
        // it would mark the newer local state clean and silently never mirror it.
        s.markPushed(songId: "sng_1", pushedAtMs: at - 1)
        XCTAssertNil(s.entry("sng_1")?.pushedAtMs)
        XCTAssertEqual(s.pendingPushes.map(\.songId), ["sng_1"], "the newer edit stays pending and retries")

        // The matching (or later) push does land.
        s.markPushed(songId: "sng_1", pushedAtMs: at + 5)
        XCTAssertEqual(s.entry("sng_1")?.pushedAtMs, at + 5)
        XCTAssertTrue(s.pendingPushes.isEmpty)

        // An unknown song is simply ignored — never conjured into existence.
        s.markPushed(songId: "sng_ghost", pushedAtMs: at)
        XCTAssertNil(s.entry("sng_ghost"))
    }

    // MARK: - Inbound reconcile

    func testApplyRemoteNewerLocalEditWins() throws {
        let s = makeStore()
        s.toggle("sng_1", appleMusicId: "1")                   // ♥ made on this device
        let at = try XCTUnwrap(s.entry("sng_1")).atMs

        // The pull observed the OLD upstream state (still unrated). It must not undo us.
        XCTAssertFalse(s.applyRemote(songId: "sng_1", favorited: false,
                                     appleMusicId: "1", observedAtMs: at - 1_000))
        XCTAssertTrue(s.isFavorite("sng_1"))
        XCTAssertEqual(s.entry("sng_1")?.atMs, at, "the local edit's timestamp is untouched")
        XCTAssertNil(s.entry("sng_1")?.pushedAtMs)
        XCTAssertEqual(s.pendingPushes.map(\.songId), ["sng_1"], "and it is still owed an outbound push")
    }

    func testApplyRemoteOlderLocalEditYields() throws {
        let s = makeStore()
        s.toggle("sng_1", appleMusicId: "1")
        let observed = try XCTUnwrap(s.entry("sng_1")).atMs + 1_000   // un-♥'d in the Music app afterwards

        XCTAssertTrue(s.applyRemote(songId: "sng_1", favorited: false,
                                    appleMusicId: "1", observedAtMs: observed))
        XCTAssertFalse(s.isFavorite("sng_1"))
        XCTAssertEqual(s.entry("sng_1")?.atMs, observed)
        XCTAssertEqual(s.entry("sng_1")?.pushedAtMs, observed,
                       "adopted state is already upstream — echoing it back would loop")
        XCTAssertTrue(s.pendingPushes.isEmpty)

        // A ♥ made in the Music app on a song this device never touched lands as a new row.
        XCTAssertTrue(s.applyRemote(songId: "sng_2", favorited: true,
                                    appleMusicId: "2", observedAtMs: observed))
        XCTAssertTrue(s.isFavorite("sng_2"))
        XCTAssertEqual(s.entry("sng_2")?.appleMusicId, "2")
        XCTAssertTrue(s.pendingPushes.isEmpty)
    }

    func testApplyRemoteEqualStateMarksPushedInsteadOfRewriting() throws {
        let s = makeStore()
        s.toggle("sng_1", appleMusicId: "1")
        let at = try XCTUnwrap(s.entry("sng_1")).atMs
        XCTAssertEqual(s.pendingPushes.count, 1)

        // Upstream already agrees — another device pushed it, or our own ACK was lost.
        XCTAssertFalse(s.applyRemote(songId: "sng_1", favorited: true,
                                     appleMusicId: "1", observedAtMs: at + 500),
                       "nothing changed, so the store reports no change")
        XCTAssertTrue(s.isFavorite("sng_1"))
        XCTAssertEqual(s.entry("sng_1")?.atMs, at, "agreement doesn't restamp the user's edit")
        XCTAssertEqual(s.entry("sng_1")?.pushedAtMs, at + 500)
        XCTAssertTrue(s.pendingPushes.isEmpty, "agreement drains the queue — the write is redundant")
    }

    // MARK: - Discover-add remap

    func testRemapSongIdsMovesAFavoriteToTheIndexedId() {
        let s = makeStore()
        s.toggle("amrec_1", appleMusicId: "111")     // ♥ on a provisional Discover add
        s.remapSongIds([(from: "amrec_1", to: "sng_real1")])

        XCTAssertNil(s.entry("amrec_1"))
        XCTAssertFalse(s.favoriteIds.contains("amrec_1"))
        XCTAssertTrue(s.isFavorite("sng_real1"), "the ♥ follows the song to its indexed id")
        XCTAssertEqual(s.entry("sng_real1")?.songId, "sng_real1", "the entry's own id is rewritten too")
        XCTAssertEqual(s.entry("sng_real1")?.appleMusicId, "111")

        let reopened = FavoritesStore(fileURL: s.syncFileURL)
        XCTAssertTrue(reopened.isFavorite("sng_real1"))
        XCTAssertNil(reopened.entry("amrec_1"))

        // An empty remap and an unknown source are no-ops.
        s.remapSongIds([])
        s.remapSongIds([(from: "sng_ghost", to: "sng_real1")])
        XCTAssertTrue(s.isFavorite("sng_real1"))
    }

    func testRemapDoesNotClobberAnExplicitEntryAtTheDestination() {
        let s = makeStore()
        s.toggle("amrec_2", appleMusicId: "222")                    // ♥ on the provisional row
        s.set("sng_real2", favorited: false, appleMusicId: "222")   // …but explicitly un-♥ on the indexed one

        s.remapSongIds([(from: "amrec_2", to: "sng_real2")])

        XCTAssertEqual(s.entry("sng_real2")?.favorited, false,
                       "the user's explicit decision at the destination wins over the remapped one")
        XCTAssertFalse(s.isFavorite("sng_real2"))
        XCTAssertNil(s.entry("amrec_2"), "the superseded provisional row is retired either way")
        XCTAssertFalse(s.favoriteIds.contains("amrec_2"))
    }

    // MARK: - Cloud-pull feedback-loop guard

    func testReloadFromDiskAdoptsStateWithoutFiringOnChanged() {
        let s = makeStore()
        s.toggle("sng_1", appleMusicId: "1")
        var emitted: [FavoritesStore.Entry] = []
        s.onChanged = { emitted.append($0) }

        // CloudSyncService pulls another device's document onto the same file.
        let otherDevice = FavoritesStore(fileURL: s.syncFileURL)
        otherDevice.toggle("sng_2", appleMusicId: "2")
        s.reloadFromDisk()

        XCTAssertTrue(s.isFavorite("sng_2"), "the pulled ♥ is adopted")
        XCTAssertTrue(s.isFavorite("sng_1"))
        XCTAssertTrue(emitted.isEmpty,
                      "a pull is already-known state — re-emitting it pushes the cloud's view straight back to Apple Music in a loop")

        // …while a genuine user toggle still fires.
        s.toggle("sng_3", appleMusicId: "3")
        XCTAssertEqual(emitted.map(\.songId), ["sng_3"])
    }

    func testOnChangedFiresOnlyForUserOriginatedChanges() {
        let s = makeStore()
        var emitted: [FavoritesStore.Entry] = []
        s.onChanged = { emitted.append($0) }

        s.toggle("sng_1", appleMusicId: "1")                                  // user
        s.applySeed(songIds: ["sng_2"], version: 1)                           // not the user's act
        s.applyRemote(songId: "sng_3", favorited: true, appleMusicId: "3",
                      observedAtMs: Date().timeIntervalSince1970 * 1000)      // inbound

        XCTAssertEqual(emitted.map(\.songId), ["sng_1"])
        XCTAssertEqual(emitted.first?.favorited, true)

        // A redundant set writes nothing and emits nothing.
        s.set("sng_1", favorited: true, appleMusicId: "1")
        XCTAssertEqual(emitted.count, 1)
    }

    // MARK: - Document compatibility

    /// New persisted fields are OPTIONAL and decoded leniently — a schema bump would
    /// discard every existing user's favorites fleet-wide.
    func testDecodesADocumentMissingTheOptionalFields() {
        let s = makeStore("""
        { "schemaVersion": 1, "entries": [
            { "songId": "sng_1", "favorited": true, "atMs": 1000, "appleMusicId": "111" },
            { "songId": "sng_2", "favorited": false, "atMs": 2000 }
          ], "somethingAFutureBuildAdded": true }
        """)
        XCTAssertEqual(s.seedVersion, 0, "no seedVersion key ⇒ nothing seeded yet")
        XCTAssertTrue(s.isFavorite("sng_1"))
        XCTAssertEqual(s.entry("sng_2")?.favorited, false, "the tombstone survives")
        XCTAssertEqual(s.pendingPushes.map(\.songId), ["sng_1"],
                       "no pushedAtMs ⇒ still owed an outbound write")

        // A corrupt document degrades to empty rather than crashing the launch.
        let broken = makeStore("{ this is not json")
        XCTAssertTrue(broken.favoriteIds.isEmpty)
        XCTAssertEqual(broken.seedVersion, 0)
    }

    // MARK: - Coalesced saves (the bulk-reconcile path)

    /// `save()` rebuilds and atomically rewrites the WHOLE document, so the Apple Music
    /// reconcile calling it once per song is O(n²) encoding plus n writes — on the main
    /// actor, at launch. `withCoalescedSaves` must collapse that to exactly one write while
    /// leaving in-memory state fully current throughout.
    func testCoalescedSavesWriteOnceButKeepStateCurrent() throws {
        let s = makeStore()
        s.withCoalescedSaves {
            for i in 0 ..< 50 {
                s.applyRemote(songId: "sng_\(i)", favorited: true,
                              appleMusicId: "\(i)", observedAtMs: 1000)
            }
            // In-memory reads are correct DURING the batch — coalescing defers the write,
            // never the mutation.
            XCTAssertEqual(s.favoriteIds.count, 50)
            // Nothing on disk yet: a store opened now still sees the pre-batch document.
            XCTAssertTrue(FavoritesStore(fileURL: s.syncFileURL).favoriteIds.isEmpty,
                          "the write is deferred to the end of the batch")
        }
        XCTAssertEqual(FavoritesStore(fileURL: s.syncFileURL).favoriteIds.count, 50,
                       "exactly one trailing write persists the whole batch")
    }

    /// Re-entrancy: a nested batch must not flush early at the inner scope's exit.
    func testNestedCoalescedSavesFlushOnlyAtTheOutermostExit() {
        let s = makeStore()
        s.withCoalescedSaves {
            s.set("sng_1", favorited: true, appleMusicId: "1")
            s.withCoalescedSaves {
                s.set("sng_2", favorited: true, appleMusicId: "2")
            }
            XCTAssertTrue(FavoritesStore(fileURL: s.syncFileURL).favoriteIds.isEmpty,
                          "the inner scope closing must not flush the outer batch")
        }
        XCTAssertEqual(FavoritesStore(fileURL: s.syncFileURL).favoriteIds, ["sng_1", "sng_2"])
    }

    /// A batch that mutates nothing must not write at all.
    func testCoalescedSavesWithNoMutationsDoesNotWrite() {
        let s = makeStore()
        s.withCoalescedSaves { _ = s.isFavorite("sng_1") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.syncFileURL.path),
                       "no mutation ⇒ no document created")
    }
}
