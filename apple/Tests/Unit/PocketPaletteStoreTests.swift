import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 2 — the stable, synced 12-colour palette (§2.4, W3).
@MainActor
final class PocketPaletteStoreTests: XCTestCase {

    private func tmp() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-palette-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private let day = 86_400_000.0

    func testSlotsAreAssignedInDominanceOrderAndNeverMove() {
        let store = PocketPaletteStore(fileURL: tmp())
        XCTAssertTrue(store.assign(dominantOrder: ["pot", "late", "fav"], nowMs: 1_000))
        XCTAssertEqual(store.slot(for: "pot"), 0)
        XCTAssertEqual(store.slot(for: "late"), 1)
        XCTAssertEqual(store.slot(for: "fav"), 2)
        // A later build where the order flipped and a newcomer arrived: old slots stay put.
        store.assign(dominantOrder: ["road", "fav", "pot"], nowMs: 2_000)
        XCTAssertEqual(store.slot(for: "pot"), 0)
        XCTAssertEqual(store.slot(for: "late"), 1, "not dominant this build, but not yet 30 days unseen")
        XCTAssertEqual(store.slot(for: "fav"), 2)
        XCTAssertEqual(store.slot(for: "road"), 3)
        // No change ⇒ no save/revision bump.
        let rev = store.revision
        XCTAssertFalse(store.assign(dominantOrder: ["pot"], nowMs: 2_000))
        XCTAssertEqual(store.revision, rev)
        // Persisted.
        XCTAssertEqual(PocketPaletteStore(fileURL: store.syncFileURL).slot(for: "road"), 3)
    }

    func testSlotIsFreedThirtyDaysAfterTheCollectionDisappears() {
        let store = PocketPaletteStore(fileURL: tmp())
        store.assign(dominantOrder: ["a", "b"], nowMs: 0)
        store.assign(dominantOrder: ["a"], nowMs: 29 * day)
        XCTAssertEqual(store.slot(for: "b"), 1, "29 days: still held")
        store.assign(dominantOrder: ["a", "c"], nowMs: 31 * day)
        XCTAssertNil(store.slot(for: "b"), "31 days unseen: freed")
        XCTAssertEqual(store.slot(for: "c"), 1, "…and the freed slot is reused")
        XCTAssertEqual(store.slot(for: "a"), 0)
        // Deleted collections free immediately.
        store.assign(dominantOrder: [], deleted: ["a"], nowMs: 31 * day)
        XCTAssertNil(store.slot(for: "a"))
    }

    func testOverflowBeyondTwelve() {
        let store = PocketPaletteStore(fileURL: tmp())
        let ids = (0..<14).map { "c\($0)" }
        store.assign(dominantOrder: ids, nowMs: 0)
        XCTAssertEqual(store.entries.count, 12)
        XCTAssertNil(store.slot(for: "c12"))
        guard case .overflow(let h1) = store.swatch(for: "c12"), case .overflow(let h2) = store.swatch(for: "c12") else {
            return XCTFail("a 13th collection is an overflow swatch")
        }
        XCTAssertEqual(h1, h2, "hashed hue is stable")
        XCTAssertEqual(PocketPaletteStore.overflowHue("c12"), h1)
        XCTAssertNotEqual(PocketPaletteStore.overflowHue("c12"), PocketPaletteStore.overflowHue("c13"))
        XCTAssertTrue((0..<360).contains(h1))
        XCTAssertTrue(store.swatch(for: "c12").isHatched)
        XCTAssertEqual(store.swatch(for: nil), .mixed)
        XCTAssertEqual(store.swatch(for: "c0"), .slot(0))
    }

    func testMergeIsConvergentEarlierAssignmentWins() {
        typealias E = PocketPaletteStore.Entry
        let mine: [String: E] = ["pot": E(slot: 0, assignedAtMs: 100, lastSeenMs: 500),
                                 "late": E(slot: 1, assignedAtMs: 200, lastSeenMs: 200)]
        let theirs: [String: E] = ["pot": E(slot: 3, assignedAtMs: 50, lastSeenMs: 300),     // earlier → wins
                                   "fav": E(slot: 1, assignedAtMs: 150, lastSeenMs: 150)]    // collides with late
        let ab = PocketPaletteStore.merge(mine, theirs)
        let ba = PocketPaletteStore.merge(theirs, mine)
        XCTAssertEqual(ab, ba, "order-independent")
        XCTAssertEqual(ab["pot"]?.slot, 3)
        XCTAssertEqual(ab["pot"]?.lastSeenMs, 500, "lastSeen MAX-merged")
        XCTAssertEqual(ab["fav"]?.slot, 1, "fav (assigned at 150) beats late (200) for slot 1")
        XCTAssertNotEqual(ab["late"]?.slot, 1, "late is re-seated")
        XCTAssertEqual(Set(ab.values.map(\.slot)).count, ab.count, "no slot is shared")
        XCTAssertEqual(PocketPaletteStore.merge(ab, ab), ab, "idempotent")
    }

    func testReloadFromDiskSavesOnlyWhenWeHoldMore() throws {
        let url = tmp()
        let store = PocketPaletteStore(fileURL: url)
        store.assign(dominantOrder: ["pot"], nowMs: 100)
        // Peer doc: same entry + one more.
        let peer = PocketPaletteStore.Document(entries: [
            "pot": .init(slot: 0, assignedAtMs: 100, lastSeenMs: 100),
            "late": .init(slot: 1, assignedAtMs: 120, lastSeenMs: 120),
        ])
        try JSONEncoder().encode(peer).write(to: url)
        XCTAssertFalse(store.reloadFromDisk(), "the pulled doc is a superset ⇒ no push-back")
        XCTAssertEqual(store.slot(for: "late"), 1)
        // Now we hold something it lacks.
        store.assign(dominantOrder: ["pot", "late", "fav"], nowMs: 200)
        try JSONEncoder().encode(peer).write(to: url)
        XCTAssertTrue(store.reloadFromDisk(), "we hold fav ⇒ republish")
    }

    func testPaletteColoursAreDistinctAndValid() {
        for dark in [true, false] {
            let colours = (0..<12).map { PocketSwatch.slot($0).rgb(dark: dark) }
            for c in colours {
                XCTAssertTrue([c.0, c.1, c.2].allSatisfy { (0...1).contains($0) })
            }
            // Adjacent slots are perceptually far apart (cheap sRGB distance check).
            for i in 0..<11 {
                let a = colours[i], b = colours[i + 1]
                let d = sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
                XCTAssertGreaterThan(d, 0.25, "slots \(i) and \(i + 1) are too close (\(dark ? "dark" : "light"))")
            }
        }
        // The OKLCH converter reproduces the table.
        let c = PocketSwatch.oklchToSRGB(L: 0.72, C: 0.15, h: 25)
        XCTAssertEqual(c.0, 0.9574, accuracy: 0.001)
        XCTAssertEqual(c.1, 0.4822, accuracy: 0.001)
    }

    func testLenientDecode() throws {
        let json = #"{"schemaVersion":1,"entries":{"good":{"slot":2,"assignedAtMs":1,"lastSeenMs":1},"bad":{"slot":"x"}}}"#
        let doc = try JSONDecoder().decode(PocketPaletteStore.Document.self, from: Data(json.utf8))
        XCTAssertEqual(doc.entries.keys.sorted(), ["good"])
    }

    func testRegisteredForSyncAndDeletion() {
        XCTAssertTrue(AccountDeletionService.cloudDocKeys.contains("pocket-palette"),
                      "every CloudSync'd doc must be erased by account deletion")
    }
}

/// The app-scoped cache: off-main build from history, palette fold, disk cache, debounce.
@MainActor
final class PocketMomentCacheTests: XCTestCase {

    private func tmp(_ s: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-wheelcache-\(s)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRebuildFromHistoryAssignsPaletteAndCaches() async throws {
        let history = PlayHistoryStore(fileURL: tmp("hist"))
        let palette = PocketPaletteStore(fileURL: tmp("pal"))
        let cacheURL = tmp("cache")
        let cache = PocketMomentCache(history: history, palette: palette, fileURL: cacheURL)
        let now = 1_793_115_000_000.0
        cache.now = { Date(timeIntervalSince1970: now / 1000) }
        var events: [PlayHistoryStore.PlayEvent] = []
        for i in 0..<4 {
            events.append(.init(id: UUID(), songId: "s\(i)", playedAt: now - Double(i) * 86_400_000 * 7, source: .playlist,
                                contextId: "set_now_playing", contextName: nil, title: nil, artist: nil, originInstallId: nil,
                                tzOffsetMin: -420, carPlay: true, originCollectionId: "pl_pot"))
        }
        history.replaceAll(events)
        cache.collectionsInput = { .init(source: .init(sourcePlaylists: [(id: "pl_pot", name: "Potential", songIds: ["s0", "s1"])])) }
        await cache.rebuildNow()
        let cell = cache.snapshot.index()[PocketMomentKey(hour: 8, dow: 2, mode: .carPlay)]
        XCTAssertEqual(cell?.dominantCollectionId, "pl_pot")
        XCTAssertEqual(cell?.distinctDays, 4)
        XCTAssertEqual(cache.snapshot.collectionNames["pl_pot"], "Potential")
        XCTAssertEqual(palette.slot(for: "pl_pot"), 0, "the build seated the palette")
        // The disk cache paints the next launch instantly.
        let reopened = PocketMomentCache(history: history, palette: palette, fileURL: cacheURL)
        XCTAssertEqual(reopened.snapshot, cache.snapshot)
    }

    func testHistoryDidChangeDebouncesAndSkipsWhenCurrent() async throws {
        let history = PlayHistoryStore(fileURL: tmp("hist2"))
        let cache = PocketMomentCache(history: history, palette: PocketPaletteStore(fileURL: tmp("pal2")), fileURL: tmp("cache2"))
        cache.debounceSeconds = 0.05
        history.record(songId: "s1", context: .browser, at: Date().timeIntervalSince1970 * 1000 - 3_600_000)
        let rev = cache.revision
        cache.historyDidChange()
        cache.historyDidChange()   // coalesced
        let deadline = Date().addingTimeInterval(10)
        while cache.revision == rev, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(cache.revision, rev, "the debounced rebuild landed")
        XCTAssertFalse(cache.snapshot.isEmpty)
        let after = cache.revision
        cache.historyDidChange()   // same history revision ⇒ no rebuild
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(cache.revision, after)
    }

    func testClearLocalEmptiesAndRemovesTheFile() async {
        let url = tmp("cache3")
        let history = PlayHistoryStore(fileURL: tmp("hist3"))
        let cache = PocketMomentCache(history: history, palette: PocketPaletteStore(fileURL: tmp("pal3")), fileURL: url)
        history.record(songId: "s1", context: .browser, at: Date().timeIntervalSince1970 * 1000 - 3_600_000)
        await cache.rebuildNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        cache.clearLocal()
        XCTAssertTrue(cache.snapshot.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
