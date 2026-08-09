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

    // MARK: - User deletion (tombstones)
    //
    // WHY TOMBSTONES AT ALL: `reloadFromDisk` UNIONS the on-disk document into the live log by
    // run id and is deliberately idempotent for ADDS. A plain row drop therefore does not
    // survive sync — a peer document that still holds the run adds it straight back and the
    // deletion silently undoes itself. Tests 3/4/6 below are that failure, pinned.

    private func decodeDoc(_ url: URL) throws -> GameScoreboardStore.Document {
        try JSONDecoder().decode(GameScoreboardStore.Document.self, from: Data(contentsOf: url))
    }

    func testDeleteGameRemovesOnlyThatGamesRunsAndTombstonesThem() {
        let store = GameScoreboardStore(fileURL: tempURL())
        store.record(game: .collectorsPuzzle, score: 3, settingsSummary: nil, at: 1000)
        store.record(game: .collectorsPuzzle, score: 8, settingsSummary: nil, at: 2000)
        store.record(game: .collectorsPuzzle, score: 5, settingsSummary: nil, at: 3000)
        store.record(game: .musicWithFriends, score: 4, settingsSummary: nil, at: 4000)

        XCTAssertEqual(store.delete(game: .collectorsPuzzle), 3, "three puzzle rows went")
        XCTAssertNil(store.bestScore(.collectorsPuzzle), "…and the game's board is empty")
        XCTAssertEqual(store.bestScore(.musicWithFriends), 4, "the other game is untouched")
        XCTAssertEqual(store.runs.count, 1)
        XCTAssertEqual(store.tombstones.count, 3, "every deleted row left a tombstone")
        XCTAssertEqual(store.delete(game: .collectorsPuzzle), 0, "deleting nothing is a no-op")
    }

    func testDeleteAllRemovesEveryRunAndTombstonesEachOne() {
        let store = GameScoreboardStore(fileURL: tempURL())
        for i in 1...3 { store.record(game: .collectorsPuzzle, score: i, settingsSummary: nil, at: Double(i)) }
        store.record(game: .musicWithFriends, score: 4, settingsSummary: nil, at: 9)
        XCTAssertEqual(store.deleteAll(), 4)
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertEqual(store.tombstones.count, 4)
        XCTAssertNil(store.bestScore(.collectorsPuzzle))
        XCTAssertNil(store.bestScore(.musicWithFriends))
    }

    /// THE LOAD-BEARING ONE: the union merge must not resurrect a deleted run. A peer's
    /// document (or our own pre-delete bytes, replayed by a CloudSync pull) still carries every
    /// row we just deleted; without tombstones `reloadFromDisk` adds them straight back.
    func testDeletedRunIsNotResurrectedByAPeerDocumentThatStillHasIt() throws {
        let url = tempURL()
        let store = GameScoreboardStore(fileURL: url)
        for i in 1...3 { store.record(game: .collectorsPuzzle, score: i, settingsSummary: nil, at: Double(i)) }
        let peerBytes = try Data(contentsOf: url)          // the doc as it stood BEFORE the delete

        store.deleteAll()
        try peerBytes.write(to: url)                       // …and a pull lands it back on disk

        XCTAssertTrue(store.reloadFromDisk(),
                      "the doc still carries runs we tombstoned ⇒ it MUST be rewritten")
        XCTAssertTrue(store.runs.isEmpty, "the union did not resurrect the deleted runs")
        let doc = try decodeDoc(url)
        XCTAssertTrue(doc.runs.isEmpty, "…and the rewritten document holds none of them")
        XCTAssertEqual(doc.deleted?.count, 3, "the tombstones are what got published")
    }

    /// THE SHARPEST CASE — exactly the state where the OLD `byId.count > doc.runs.count` save
    /// proxy reads `false` (we hold zero runs the doc lacks) yet a save is mandatory. Without
    /// an id-based `mustSave` the tombstones never publish AND the on-disk document keeps the
    /// runs, so the very next launch's `init` resurrects them: deletion DURABILITY, not just
    /// propagation, rides on this.
    func testDeletionPublishesEvenWhenWeHoldNoRunsTheDocLacks() throws {
        let url = tempURL()
        let store = GameScoreboardStore(fileURL: url)
        for i in 1...3 { store.record(game: .collectorsPuzzle, score: i, settingsSummary: nil, at: Double(i)) }
        let peerBytes = try Data(contentsOf: url)
        store.deleteAll()
        try peerBytes.write(to: url)

        // Precondition, spelled out: the union yields exactly the doc's rows and no more.
        XCTAssertTrue(store.runs.isEmpty, "we hold NO runs — the count proxy sees no difference")
        XCTAssertEqual(try decodeDoc(url).runs.count, 3)

        XCTAssertTrue(store.reloadFromDisk(), "the conditional save must still fire")
        let relaunched = GameScoreboardStore(fileURL: url)
        XCTAssertTrue(relaunched.runs.isEmpty, "the next launch does not resurrect them")
        XCTAssertEqual(relaunched.tombstones.count, 3, "…because the tombstones persisted")
    }

    func testReloadAfterDeletionIsIdempotent() throws {
        let url = tempURL()
        let store = GameScoreboardStore(fileURL: url)
        for i in 1...3 { store.record(game: .collectorsPuzzle, score: i, settingsSummary: nil, at: Double(i)) }
        let peerBytes = try Data(contentsOf: url)
        store.deleteAll()
        try peerBytes.write(to: url)
        XCTAssertTrue(store.reloadFromDisk())

        XCTAssertFalse(store.reloadFromDisk(), "our own rewritten doc needs no further save")
        XCTAssertFalse(store.reloadFromDisk())
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertEqual(store.tombstones.count, 3, "re-applying a document changes nothing")
    }

    /// The REVERSE direction: the tombstones arrive from a peer and delete OUR local rows.
    func testPeerTombstonesDeleteOurLocalRuns() throws {
        let url = tempURL()
        let store = GameScoreboardStore(fileURL: url)
        let r1 = store.record(game: .collectorsPuzzle, score: 1, settingsSummary: nil, at: 1000)
        let r2 = store.record(game: .collectorsPuzzle, score: 2, settingsSummary: nil, at: 2000)
        let r3 = store.record(game: .collectorsPuzzle, score: 3, settingsSummary: nil, at: 3000)

        let peerDoc = GameScoreboardStore.Document(
            installId: "peer-install", runs: [],
            deleted: [GameScoreboardStore.Tombstone(id: r1.id, at: 5000, byInstallId: "peer-install"),
                      GameScoreboardStore.Tombstone(id: r2.id, at: 5000, byInstallId: "peer-install")])
        try JSONEncoder().encode(peerDoc).write(to: url)

        XCTAssertTrue(store.reloadFromDisk(), "we still hold r3, which the peer doc lacks")
        XCTAssertEqual(store.runs.map(\.id), [r3.id], "the peer's deletions applied to our log")
        XCTAssertEqual(store.tombstones.count, 2)
        let relaunched = GameScoreboardStore(fileURL: url)
        XCTAssertEqual(relaunched.runs.map(\.id), [r3.id], "and they stayed deleted across a relaunch")
    }

    func testDeletionSurvivesRelaunch() {
        let url = tempURL()
        let store = GameScoreboardStore(fileURL: url)
        store.record(game: .collectorsPuzzle, score: 7, settingsSummary: nil, at: 1000)
        store.record(game: .musicWithFriends, score: 4, settingsSummary: nil, at: 2000)
        store.delete(game: .collectorsPuzzle)

        let relaunched = GameScoreboardStore(fileURL: url)
        XCTAssertNil(relaunched.bestScore(.collectorsPuzzle))
        XCTAssertEqual(relaunched.bestScore(.musicWithFriends), 4)
        XCTAssertEqual(relaunched.tombstones.count, 1, "the tombstone is part of the document")
    }

    /// THE MIGRATION PROOF for the tombstone key: a document written by the PREVIOUS build has
    /// no `deleted` key at all, and must decode with every run intact.
    func testPreTombstoneDocumentWithoutDeletedKeyStillDecodes() throws {
        let url = tempURL()
        let doc = """
        { "schemaVersion": 1, "installId": "old-install", "runs": [
          { "id": "\(UUID().uuidString)", "game": "collectorsPuzzle", "score": 12,
            "at": 1000, "settingsSummary": "2:00 · 2 targets", "originInstallId": "old-install" },
          { "id": "\(UUID().uuidString)", "game": "musicWithFriends", "score": 6, "at": 2000 }
        ] }
        """
        try Data(doc.utf8).write(to: url)
        let store = GameScoreboardStore(fileURL: url)
        XCTAssertEqual(store.runs.count, 2, "the pre-tombstone byte shape decodes unchanged")
        XCTAssertEqual(store.bestScore(.collectorsPuzzle), 12)
        XCTAssertEqual(store.bestScore(.musicWithFriends), 6)
        XCTAssertTrue(store.tombstones.isEmpty, "a missing key is 'nothing deleted', not a failure")
    }

    /// A racing peer document can legitimately carry BOTH a run and its tombstone (it deleted
    /// the row after writing it, or merged two devices' halves). The tombstone wins — on the
    /// launch decode and on a live reload.
    func testDocumentCarryingBothARunAndItsTombstoneSuppressesTheRun() throws {
        let doomed = GameScoreboardStore.RunRecord(
            id: UUID(), game: "collectorsPuzzle", score: 99, at: 1000,
            settingsSummary: nil, detail: nil, originInstallId: "peer")
        let keeper = GameScoreboardStore.RunRecord(
            id: UUID(), game: "collectorsPuzzle", score: 5, at: 2000,
            settingsSummary: nil, detail: nil, originInstallId: "peer")
        let doc = GameScoreboardStore.Document(
            installId: "peer", runs: [doomed, keeper],
            deleted: [GameScoreboardStore.Tombstone(id: doomed.id, at: 3000, byInstallId: "peer")])

        let initURL = tempURL()
        try JSONEncoder().encode(doc).write(to: initURL)
        let atLaunch = GameScoreboardStore(fileURL: initURL)
        XCTAssertEqual(atLaunch.runs.map(\.id), [keeper.id], "init filters the runs through the tombstones")
        XCTAssertEqual(atLaunch.bestScore(.collectorsPuzzle), 5, "the 99 never shows")

        let reloadURL = tempURL()
        let live = GameScoreboardStore(fileURL: reloadURL)      // empty to start
        try JSONEncoder().encode(doc).write(to: reloadURL)
        XCTAssertTrue(live.reloadFromDisk(), "the doc still carries a tombstoned run ⇒ rewrite it")
        XCTAssertEqual(live.runs.map(\.id), [keeper.id])
    }

    /// `clear()` is the ERASURE path (AccountDeletionService's 5.1.1(v) guarantee, and the
    /// authoritative fixture seed) — NOT the user's delete. It must leave no tombstones behind:
    /// 500 of them after "erase my account" is residual personal data about the user's
    /// activity, and it would make the seeded document non-byte-clean. This test is what fails
    /// if someone "unifies" `clear()` with `deleteAll()`.
    func testHardClearLeavesNoTombstones() throws {
        let url = tempURL()
        let store = GameScoreboardStore(fileURL: url)
        store.record(game: .collectorsPuzzle, score: 7, settingsSummary: nil, at: 1000)
        store.record(game: .musicWithFriends, score: 4, settingsSummary: nil, at: 2000)
        store.delete(game: .collectorsPuzzle)
        XCTAssertEqual(store.tombstones.count, 1, "precondition: a user delete DID tombstone")

        store.clear()
        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertTrue(store.tombstones.isEmpty, "erasure leaves no trace of what was played")
        XCTAssertTrue(try decodeDoc(url).runs.isEmpty)
        XCTAssertTrue(try decodeDoc(url).deleted?.isEmpty ?? true)
        // …and the BYTES are the pre-tombstone shape: `encodeIfPresent` omits the key outright,
        // so an erased store is indistinguishable from one written by the shipped build.
        let raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("\"deleted\""), "the key is omitted entirely, not written as []")
    }

    /// The `maxRuns` trim is a LOCAL DISPLAY BOUND, not a user deletion. Tombstoning there
    /// would turn "my log got long on this device" into a cross-device erase of rows the peers
    /// are still happily showing.
    func testCapTrimDoesNotTombstone() {
        let store = GameScoreboardStore(fileURL: tempURL())
        for i in 0..<(GameScoreboardStore.maxRuns + 2) {
            store.record(game: .collectorsPuzzle, score: i, settingsSummary: nil, at: Double(i))
        }
        XCTAssertEqual(store.runs.count, GameScoreboardStore.maxRuns)
        XCTAssertTrue(store.tombstones.isEmpty, "trimming for length is not deleting")
    }

    /// The tombstone list is capped, evicting OLDEST-FIRST — and this pins the accepted cost of
    /// that: an evicted id stops being suppressed, so a peer that was offline across
    /// `maxTombstones` deletions and still holds the run gets ONE stale row back (which the
    /// user deletes again). Bounded and benign; unbounded growth of a SYNCED document is not.
    func testTombstoneListIsCappedOldestFirst() throws {
        let url = tempURL()
        let overflow = GameScoreboardStore.maxTombstones + 100
        let stones = (0..<overflow).map {
            GameScoreboardStore.Tombstone(id: UUID(), at: Double($0), byInstallId: "peer")
        }
        try JSONEncoder().encode(GameScoreboardStore.Document(installId: "peer", runs: [], deleted: stones))
            .write(to: url)

        let store = GameScoreboardStore(fileURL: url)
        XCTAssertEqual(store.tombstones.count, GameScoreboardStore.maxTombstones)
        XCTAssertEqual(store.tombstones.last?.id, stones.last?.id, "the NEWEST survive")
        XCTAssertEqual(store.tombstones.first?.at, Double(overflow - GameScoreboardStore.maxTombstones),
                       "…and the oldest 100 were evicted")

        // The evicted id no longer suppresses: a peer doc still holding that run re-adds it.
        let evicted = stones[0].id
        let ghost = GameScoreboardStore.RunRecord(
            id: evicted, game: "collectorsPuzzle", score: 3, at: 10,
            settingsSummary: nil, detail: nil, originInstallId: "peer")
        try JSONEncoder().encode(GameScoreboardStore.Document(installId: "peer", runs: [ghost]))
            .write(to: url)
        store.reloadFromDisk()
        XCTAssertEqual(store.runs.map(\.id), [evicted],
                       "documented resurrection window — one stale row, not data loss")
    }
}
