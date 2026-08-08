import XCTest
@testable import PocketDJ

/// Games scoreboard — durable run log (best/recent queries, union merge across
/// installs, lenient decode, cap, UI-test seed). Pure store tests on temp files.
@MainActor
final class GameScoreboardStoreTests: XCTestCase {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-games-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRecordAndBestScore() {
        let store = GameScoreboardStore(fileURL: tempURL())
        XCTAssertNil(store.bestScore(.collectorsPuzzle))
        store.record(game: .collectorsPuzzle, score: 3, settingsSummary: "2:00 · 1 target")
        store.record(game: .collectorsPuzzle, score: 7, settingsSummary: nil)
        store.record(game: .collectorsPuzzle, score: 5, settingsSummary: nil)
        XCTAssertEqual(store.bestScore(.collectorsPuzzle), 7)
        XCTAssertEqual(store.bestRun(.collectorsPuzzle)?.score, 7)
        XCTAssertNil(store.bestScore(.musicWithFriends), "games are scored independently")
        // Zero-score runs record too (recent-runs history keeps them).
        store.record(game: .musicWithFriends, score: 0, settingsSummary: "theme")
        XCTAssertEqual(store.bestScore(.musicWithFriends), 0)
        XCTAssertEqual(store.recentRuns(.musicWithFriends, limit: 5).count, 1)
    }

    func testRecentRunsNewestFirst() {
        let store = GameScoreboardStore(fileURL: tempURL())
        for i in 1...6 {
            store.record(game: .collectorsPuzzle, score: i, settingsSummary: nil, at: Double(i) * 1000)
        }
        let recent = store.recentRuns(.collectorsPuzzle, limit: 5)
        XCTAssertEqual(recent.map(\.score), [6, 5, 4, 3, 2], "newest first, limited")
    }

    func testUnionMergeKeepsRunsFromBothInstalls() throws {
        let urlA = tempURL()
        let storeA = GameScoreboardStore(fileURL: urlA)
        storeA.record(game: .collectorsPuzzle, score: 1, settingsSummary: nil, at: 1000)
        storeA.record(game: .collectorsPuzzle, score: 2, settingsSummary: nil, at: 2000)
        let installA = storeA.installId

        // A peer install's document lands on disk (a CloudSync pull replaced the file).
        let peerRun = GameScoreboardStore.RunRecord(
            id: UUID(), game: "collectorsPuzzle", score: 9, at: 1500,
            settingsSummary: nil, detail: nil, originInstallId: "peer-install")
        let peerDoc = GameScoreboardStore.Document(installId: "peer-install", runs: [peerRun])
        try JSONEncoder().encode(peerDoc).write(to: urlA)

        XCTAssertTrue(storeA.reloadFromDisk(), "we hold rows the pulled doc lacks → conditional save fires")
        XCTAssertEqual(storeA.runs.count, 3, "union keeps both installs' runs")
        XCTAssertEqual(storeA.installId, installA, "own identity survives the merge")
        XCTAssertEqual(storeA.bestScore(.collectorsPuzzle), 9)
        // Idempotent: applying the merged doc again changes nothing.
        _ = storeA.reloadFromDisk()
        XCTAssertEqual(storeA.runs.count, 3, "id-keyed union never duplicates")
    }

    func testLenientDecodeDropsBadRowKeepsRest() throws {
        let url = tempURL()
        let good = GameScoreboardStore.RunRecord(
            id: UUID(), game: "collectorsPuzzle", score: 4, at: 1000,
            settingsSummary: nil, detail: nil, originInstallId: nil)
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let doc = """
        { "schemaVersion": 1, "installId": "i1",
          "runs": [ \(goodJSON), { "id": "not-a-uuid", "score": "banana" } ] }
        """
        try Data(doc.utf8).write(to: url)
        let store = GameScoreboardStore(fileURL: url)
        XCTAssertEqual(store.runs.count, 1, "the unreadable row drops; the good one survives")
        XCTAssertEqual(store.runs.first?.score, 4)
    }

    func testCapTrimsOldest() {
        let store = GameScoreboardStore(fileURL: tempURL())
        for i in 0..<(GameScoreboardStore.maxRuns + 2) {
            store.record(game: .collectorsPuzzle, score: i, settingsSummary: nil, at: Double(i))
        }
        XCTAssertEqual(store.runs.count, GameScoreboardStore.maxRuns)
        XCTAssertEqual(store.runs.first?.score, 2, "oldest trimmed first")
    }

    func testSeedFixture() {
        let store = GameScoreboardStore(fileURL: tempURL())
        store.seedFixture()
        XCTAssertEqual(store.runs.count, 4)
        XCTAssertEqual(store.bestScore(.collectorsPuzzle), 9)
        XCTAssertEqual(store.bestScore(.musicWithFriends), 4)
        store.seedFixture()
        XCTAssertEqual(store.runs.count, 4, "seed is a no-op when runs already exist")
    }

    /// REGRESSION — the scoreboard is the one fixture seam backed by a FILE rather than the
    /// isolated launch UserDefaults, so a run saved by an EARLIER launch (or landed by a
    /// CloudSync pull on `syncFileURL`) is still there when the seed runs, and the old bare
    /// `runs.isEmpty` gate let it silently veto the seed: the scoreboard rendered the stale
    /// best, and a UI test hunting `games-best-collectorsPuzzle` found no element at all.
    /// Under the fixture flag the seed is authoritative — it replaces the log AND the document.
    func testSeedReplacesPreExistingSavedRunUnderFixture() {
        let url = tempURL()
        let earlierLaunch = GameScoreboardStore(fileURL: url)
        earlierLaunch.record(game: .collectorsPuzzle, score: 42, settingsSummary: "yesterday's run")

        // A fresh store over the SAME file is exactly what the next launch constructs.
        let store = GameScoreboardStore(fileURL: url)
        XCTAssertEqual(store.runs.count, 1, "precondition: the saved run survives into this launch")
        XCTAssertEqual(store.bestScore(.collectorsPuzzle), 42)

        store.seedFixture(replaceExisting: true)
        XCTAssertEqual(store.runs.count, 4, "the pre-existing run no longer suppresses the seed")
        XCTAssertEqual(store.bestScore(.collectorsPuzzle), 9, "deterministic seeded best — not the stale 42")
        XCTAssertEqual(store.bestScore(.musicWithFriends), 4)
        XCTAssertEqual(store.recentRuns(.collectorsPuzzle, limit: 9).count, 3, "only the seeded rows remain")

        // …and the stale run does not resurrect from disk on the launch after that.
        let reloaded = GameScoreboardStore(fileURL: url)
        XCTAssertEqual(reloaded.runs.count, 4, "the replace persisted — the doc holds the seed alone")
        XCTAssertEqual(reloaded.bestScore(.collectorsPuzzle), 9)
    }

    /// The replace stays OPT-IN: outside the isolated fixture container (a demo build seeding
    /// against `defaultURL()`) the seed must never eat a real player's history.
    func testSeedWithoutReplaceStillYieldsToExistingRuns() {
        let store = GameScoreboardStore(fileURL: tempURL())
        store.record(game: .collectorsPuzzle, score: 42, settingsSummary: "a real run")
        store.seedFixture()
        XCTAssertEqual(store.runs.count, 1, "default seed still defers to existing runs")
        XCTAssertEqual(store.bestScore(.collectorsPuzzle), 42)
    }

    /// The lockstep invariant AccountDeletionService documents: every games doc registered
    /// with CloudSyncService in PocketDJApp.init must be in `cloudDocKeys`, or its cloud
    /// copy survives an account deletion (the 5.1.1(v) erasure guarantee).
    func testAccountDeletionCloudDocKeysCoverTheGamesDocs() {
        XCTAssertTrue(AccountDeletionService.cloudDocKeys.contains("game-scores"))
        XCTAssertTrue(AccountDeletionService.cloudDocKeys.contains("puzzle-decisions"))
    }

    // MARK: - The rename guard ("Collector's Puzzle" → "Gem Collector", display only)

    /// The persisted TOKEN and the DISPLAY name are different things. The game is now shown
    /// as "Gem Collector", but its rawValue stays `collectorsPuzzle` because that string is
    /// written into `pocketdj-game-scores.json`, into CloudKit-merged peer rows, and into
    /// already-uploaded `RecPuzzleEventWire.gameId` — renaming it orphans every existing high
    /// score and splits the scoreboard across devices with no repair path. It also silently
    /// breaks the a11y ids `games-best-<rawValue>` / `games-run-<rawValue>-<i>` the UI suite
    /// hunts. If someone "finishes" the rename later, THIS is the test that fails.
    func testGameKindTokensAreFrozenWhileLabelsAreFree() {
        XCTAssertEqual(GameKind.collectorsPuzzle.rawValue, "collectorsPuzzle",
                       "persisted token — the display name is `label`")
        XCTAssertEqual(GameKind.musicWithFriends.rawValue, "musicWithFriends")
        XCTAssertEqual(GameKind.collectorsPuzzle.label, "Gem Collector")
        XCTAssertEqual(GameKind.musicWithFriends.label, "Music with Friends")
    }

    /// THE MIGRATION PROOF: a scoreboard document written by the PREVIOUS build — rows
    /// carrying `"game":"collectorsPuzzle"` — still resolves through the renamed enum. This is
    /// the assertion that actually fails if the case is ever renamed; the label test above
    /// only catches the symbol, this one catches the DATA.
    func testHighScoresWrittenBeforeTheRenameStillResolve() throws {
        let url = tempURL()
        // Byte-for-byte what the shipped build wrote: the token, not the display name.
        let doc = """
        { "schemaVersion": 1, "installId": "old-install", "runs": [
          { "id": "\(UUID().uuidString)", "game": "collectorsPuzzle", "score": 11,
            "at": 1000, "settingsSummary": "2:00 · 3 targets", "originInstallId": "old-install" },
          { "id": "\(UUID().uuidString)", "game": "collectorsPuzzle", "score": 4,
            "at": 2000, "settingsSummary": "1:00 · 1 target", "originInstallId": "old-install" },
          { "id": "\(UUID().uuidString)", "game": "musicWithFriends", "score": 6, "at": 3000 }
        ] }
        """
        try Data(doc.utf8).write(to: url)
        let store = GameScoreboardStore(fileURL: url)
        XCTAssertEqual(store.bestScore(.collectorsPuzzle), 11,
                       "pre-rename high score survives — the token never moved")
        XCTAssertEqual(store.bestRun(.collectorsPuzzle)?.settingsSummary, "2:00 · 3 targets")
        XCTAssertEqual(store.recentRuns(.collectorsPuzzle, limit: 5).count, 2)
        XCTAssertEqual(store.bestScore(.musicWithFriends), 6)
        // …and the a11y ids the UI suite hunts are still derived from that same token.
        XCTAssertEqual("games-best-\(GameKind.collectorsPuzzle.rawValue)", "games-best-collectorsPuzzle")
    }

    /// The rec-engine bridge stamps the same token into every uploaded puzzle event. Rows
    /// already sitting in S3 carry `"collectorsPuzzle"`; new rows must stay homogeneous with
    /// them (the server stores `gameId` and never reads it, so a rename would be pure churn
    /// with a split-token cost).
    func testRecPuzzleEventsStillCarryTheFrozenGameToken() {
        let decision = PuzzleDecisionStore.Decision(
            id: UUID(), roundId: UUID(), at: 5000, songId: "sng_1", action: "assigned",
            collectionId: "pkt_a", collectionName: "Crate A", positionInRound: 0,
            settings: nil, originInstallId: nil)
        let events = PuzzleRecEventBridge.events(from: [decision], sinceMs: 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.gameId, "collectorsPuzzle")
    }

    /// Account deletion wipes the scoreboard: state resets AND the persisted document no
    /// longer resurrects the old runs on a reload.
    func testClearResetsStateAndPersistedDocument() {
        let url = tempURL()
        let store = GameScoreboardStore(fileURL: url)
        store.record(game: .collectorsPuzzle, score: 7, settingsSummary: nil)
        store.clear()
        XCTAssertTrue(store.runs.isEmpty)
        let reloaded = GameScoreboardStore(fileURL: url)
        XCTAssertTrue(reloaded.runs.isEmpty, "the persisted doc is empty too")
    }
}
