import XCTest
@testable import PocketDJ

/// Collectors Puzzle decision log — the recommendation-readable assigned/skipped/expired
/// rows with per-round settings snapshots. Same durable-JSON contract as the scoreboard.
@MainActor
final class PuzzleDecisionStoreTests: XCTestCase {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-puzzledec-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRecordAssignSkipExpired() {
        let store = PuzzleDecisionStore(fileURL: tempURL())
        let round = UUID()
        store.record(roundId: round, songId: "sng_1", action: "assigned",
                     collectionId: "pkt_x", collectionName: "Crate", positionInRound: 0)
        store.record(roundId: round, songId: "sng_2", action: "skipped", positionInRound: 1)
        store.record(roundId: round, songId: "sng_3", action: "expired", positionInRound: 2)
        store.record(roundId: UUID(), songId: "sng_9", action: "assigned")
        let rows = store.decisions(forRound: round)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.action), ["assigned", "skipped", "expired"])
        XCTAssertEqual(rows[0].collectionId, "pkt_x")
        XCTAssertEqual(rows[0].collectionName, "Crate")
        XCTAssertNil(rows[1].collectionId, "skip carries no target")
    }

    func testUnionMerge() throws {
        let url = tempURL()
        let store = PuzzleDecisionStore(fileURL: url)
        let round = UUID()
        store.record(roundId: round, songId: "sng_1", action: "assigned", at: 1000)
        let peer = PuzzleDecisionStore.Decision(
            id: UUID(), roundId: round, at: 500, songId: "sng_2", action: "skipped",
            collectionId: nil, collectionName: nil, positionInRound: nil,
            settings: nil, originInstallId: "peer")
        let doc = PuzzleDecisionStore.Document(installId: "peer", decisions: [peer])
        try JSONEncoder().encode(doc).write(to: url)
        XCTAssertTrue(store.reloadFromDisk())
        XCTAssertEqual(store.decisions.count, 2, "union keeps both installs' rows")
        _ = store.reloadFromDisk()
        XCTAssertEqual(store.decisions.count, 2, "idempotent")
    }

    func testSettingsSnapshotRoundTrips() {
        let url = tempURL()
        let store = PuzzleDecisionStore(fileURL: url)
        var settings = PuzzleSettings()
        settings.roundSeconds = 300
        settings.favoriteBias = .favor
        settings.genreCategories = ["hip-hop", "jazz"]
        settings.yearMin = 1990
        settings.yearMax = 1999
        settings.membershipMode = .notInAny
        settings.membershipCollectionIds = ["pls_a"]
        settings.targetCollectionIds = ["pkt_x", "pls_b"]
        store.record(roundId: UUID(), songId: "sng_1", action: "assigned", settings: settings)
        store.flush()   // gameplay-rate saves coalesce; flush lands them synchronously

        let reloaded = PuzzleDecisionStore(fileURL: url)
        XCTAssertEqual(reloaded.decisions.first?.settings, settings,
                       "the full weighting snapshot survives the disk round-trip")
    }

    // MARK: Coalesced, off-main persistence (gameplay-rate records)

    func testRecordBatchWritesOnceAndFlushLands() throws {
        let url = tempURL()
        let store = PuzzleDecisionStore(fileURL: url)
        let round = UUID()
        var settings = PuzzleSettings()
        settings.roundSeconds = 90
        // The drift re-sync's burst: one persist for the whole run of expired songs.
        let made = store.recordBatch([(songId: "sng_1", action: "expired", positionInRound: 0),
                                      (songId: "sng_2", action: "expired", positionInRound: 1),
                                      (songId: "sng_3", action: "expired", positionInRound: 2)],
                                     roundId: round, settings: settings)
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(store.decisions(forRound: round).map(\.positionInRound), [0, 1, 2])
        XCTAssertEqual(store.decisions.last?.settings, settings)
        XCTAssertTrue(store.hasUnsavedChanges, "the write is coalesced, not per-row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "…and nothing hit the disk on the main actor yet")
        store.flush()
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(PuzzleDecisionStore(fileURL: url).decisions.count, 3, "flush lands every row")
    }

    func testBurstOfRecordsCoalescesIntoOneDocument() async throws {
        let url = tempURL()
        let store = PuzzleDecisionStore(fileURL: url)
        let round = UUID()
        for i in 0..<20 { store.record(roundId: round, songId: "sng_\(i)", action: "skipped") }
        XCTAssertTrue(store.hasUnsavedChanges)
        // The debounced save lands off the main actor without any flush.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(PuzzleDecisionStore(fileURL: url).decisions.count, 20,
                       "the coalesced write carries the whole burst")
    }

    /// A cloud pull merges peer rows in while a gameplay save is still coalescing — the
    /// pre-merge snapshot must never land on top of the merged document.
    func testPendingSaveNeverClobbersACloudMerge() async throws {
        let url = tempURL()
        let store = PuzzleDecisionStore(fileURL: url)
        let round = UUID()
        store.record(roundId: round, songId: "sng_mine", action: "assigned", at: 2000)
        XCTAssertTrue(store.hasUnsavedChanges, "the local row is still coalescing")
        // CloudSync pulls a peer document over the file, then calls reloadFromDisk.
        let peer = PuzzleDecisionStore.Decision(
            id: UUID(), roundId: round, at: 500, songId: "sng_peer", action: "skipped",
            collectionId: nil, collectionName: nil, positionInRound: nil,
            settings: nil, originInstallId: "peer")
        try JSONEncoder().encode(PuzzleDecisionStore.Document(installId: "peer", decisions: [peer]))
            .write(to: url)
        _ = store.reloadFromDisk()
        XCTAssertEqual(store.decisions.count, 2)
        try await Task.sleep(for: .milliseconds(1200))   // every scheduled write lands
        let onDisk = PuzzleDecisionStore(fileURL: url)
        XCTAssertEqual(Set(onDisk.decisions.map(\.songId)), ["sng_mine", "sng_peer"],
                       "the pulled row survives the in-flight local save")
    }

    /// The RESIDUAL of the 35abdeb fix: task cancellation cannot retract a block already
    /// handed to the write queue, so a stale pre-merge snapshot could land AFTER the pull
    /// (dropping the peer's rows locally, then LWW-pushing the loss to the cloud). The
    /// write-generation check inside the queued block + the `applyPulledPayload` ordering
    /// seam close it: the stale block must skip itself.
    func testStaleEnqueuedWriteSkipsAfterAnOrderedPullMerge() async throws {
        let url = tempURL()
        let store = PuzzleDecisionStore(fileURL: url)
        let round = UUID()
        store.record(roundId: round, songId: "sng_mine", action: "assigned", at: 2000)
        XCTAssertTrue(store.hasUnsavedChanges, "the pre-merge snapshot is scheduled")
        // CloudSync pulls a peer document through the ORDERED seam, then merges.
        let peer = PuzzleDecisionStore.Decision(
            id: UUID(), roundId: round, at: 500, songId: "sng_peer", action: "skipped",
            collectionId: nil, collectionName: nil, positionInRound: nil,
            settings: nil, originInstallId: "peer")
        let payload = try JSONEncoder().encode(
            PuzzleDecisionStore.Document(installId: "peer", decisions: [peer]))
        store.applyPulledPayload(payload)
        XCTAssertTrue(store.reloadFromDisk(), "we hold a row the pulled doc lacks → merge-save")
        XCTAssertEqual(store.decisions.count, 2)
        // Let the stale coalesced block fire (debounce is 600 ms) — it must write NOTHING.
        try await Task.sleep(for: .milliseconds(1200))
        let onDisk = PuzzleDecisionStore(fileURL: url)
        XCTAssertEqual(Set(onDisk.decisions.map(\.songId)), ["sng_mine", "sng_peer"],
                       "the stale snapshot never clobbers the merged document")
    }

    /// Round end uses `flushAsync()`: the rows land promptly (no 600 ms debounce) but the
    /// main actor never blocks on the MB-scale encode while the summary presents.
    func testFlushAsyncLandsImmediatelyWithoutTheDebounce() async throws {
        let url = tempURL()
        let store = PuzzleDecisionStore(fileURL: url)
        store.record(roundId: UUID(), songId: "sng_1", action: "assigned")
        store.flushAsync()
        // Well inside the 600 ms debounce window: a debounced save could not have landed.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(PuzzleDecisionStore(fileURL: url).decisions.count, 1,
                       "the async flush skips the debounce entirely")
    }

    /// A synchronous write right after `flushAsync()` supersedes it — the async block must
    /// skip itself rather than resurrect the pre-clear rows.
    func testSaveAfterFlushAsyncWinsTheRace() async throws {
        let url = tempURL()
        let store = PuzzleDecisionStore(fileURL: url)
        store.record(roundId: UUID(), songId: "sng_1", action: "assigned")
        store.flushAsync()
        store.clear()   // bumps the generation + writes the empty doc synchronously
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(PuzzleDecisionStore(fileURL: url).decisions.isEmpty,
                      "the in-flight async flush never lands on top of the clear")
    }

    func testLenientDecode() throws {
        let url = tempURL()
        let good = PuzzleDecisionStore.Decision(
            id: UUID(), roundId: UUID(), at: 1000, songId: "sng_1", action: "assigned",
            collectionId: nil, collectionName: nil, positionInRound: nil,
            settings: nil, originInstallId: nil)
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let doc = """
        { "schemaVersion": 1, "installId": "i1",
          "decisions": [ \(goodJSON), { "id": 42 } ] }
        """
        try Data(doc.utf8).write(to: url)
        let store = PuzzleDecisionStore(fileURL: url)
        XCTAssertEqual(store.decisions.count, 1)
        XCTAssertEqual(store.decisions.first?.songId, "sng_1")
    }
}
