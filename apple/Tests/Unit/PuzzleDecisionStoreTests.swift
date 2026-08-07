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

        let reloaded = PuzzleDecisionStore(fileURL: url)
        XCTAssertEqual(reloaded.decisions.first?.settings, settings,
                       "the full weighting snapshot survives the disk round-trip")
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
