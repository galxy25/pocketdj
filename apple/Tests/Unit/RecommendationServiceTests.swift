import XCTest
import CryptoKit
@testable import PocketDJ

/// `RecommendationService` — the recommendation-engine orchestrator, driven against seeded
/// real stores (temp files) and a spy transport.
///
/// The property worth breaking a build over: with the Settings toggle OFF (the default), the
/// service emits literally ZERO network traffic — that gate is the entire privacy story.
@MainActor
final class RecommendationServiceTests: XCTestCase {

    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var status = 200
        var body = Data(#"{"ok":true}"#.utf8)
        /// Per-request `(status, body)` overrides, consumed FIFO before falling back to
        /// `status`/`body` — the only way to script "413 for the snapshot batch, then 200".
        var scripted: [(Int, Data)] = []
        /// Thrown INSTEAD of answering (transport-level failure, e.g. `URLError(.cancelled)`).
        var error: Error?

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
        func record(_ req: URLRequest) throws -> (Data, URLResponse) {
            lock.lock()
            _requests.append(req)
            let step = scripted.isEmpty ? nil : scripted.removeFirst()
            let err = error
            lock.unlock()
            if let err { throw err }
            let resp = HTTPURLResponse(url: req.url!, statusCode: step?.0 ?? status,
                                       httpVersion: nil, headerFields: nil)!
            return (step?.1 ?? body, resp)
        }
        /// The decoded JSON body of request #i.
        func json(_ i: Int) -> [String: Any] {
            guard requests.indices.contains(i), let data = requests[i].httpBody,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }
    }

    /// Holds a transport suspended until `release()` — the only way to drive the "cancelled
    /// mid-`postEvents`" race deterministically.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            for w in waiters { w.resume() }
            waiters = []
        }
    }

    private struct Env {
        let svc: RecommendationService
        let spy: Spy
        let settings: SettingsStore
        let history: PlayHistoryStore
        let favorites: FavoritesStore
        let activity: CollectionActivityStore
        let collections: CollectionsStore
        let keyURL: URL
    }

    /// Poll a condition on the MainActor (every await yields, letting the other task run).
    private func waitUntil(_ label: String, timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(label)")
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-rec-\(name)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeEnv(enabled: Bool, keyURL: URL? = nil, stateURL: URL? = nil,
                         shared: Env? = nil, gate: Gate? = nil) -> Env {
        let spy = Spy()
        let client = RecEngineClient(base: URL(string: "https://rec.test")!,
                                     transport: { req in
                                         // Record FIRST, then park: that is the "cancelled while
                                         // the POST is in flight" state the re-arm race needs.
                                         let out = try spy.record(req)
                                         if let gate { await gate.wait() }
                                         return out
                                     })
        let settings: SettingsStore
        let history: PlayHistoryStore
        let favorites: FavoritesStore
        let activity: CollectionActivityStore
        let collections: CollectionsStore
        if let shared {
            settings = shared.settings; history = shared.history; favorites = shared.favorites
            activity = shared.activity; collections = shared.collections
        } else {
            let suite = "pdj.rec.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            settings = SettingsStore(defaults: defaults)
            history = PlayHistoryStore(fileURL: tempURL("history"))
            favorites = FavoritesStore(fileURL: tempURL("favorites"))
            activity = CollectionActivityStore(fileURL: tempURL("activity"))
            collections = CollectionsStore(fileURL: tempURL("collections"))
        }
        settings.recEngineEnabled = enabled
        let key = keyURL ?? tempURL("key")
        let svc = RecommendationService(
            client: client, settings: settings, history: history, favorites: favorites,
            activity: activity, collections: collections,
            profileIdProvider: { "profile-test-1234" },
            keyFileURL: key, stateFileURL: stateURL ?? tempURL("sync"))
        return Env(svc: svc, spy: spy, settings: settings, history: history,
                   favorites: favorites, activity: activity, collections: collections,
                   keyURL: key)
    }

    // MARK: - The privacy gate

    func testDisabledSendsNothing() async {
        let env = makeEnv(enabled: false)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        env.favorites.set("sng_a", favorited: true, appleMusicId: nil)
        await env.svc.flushNow()
        await env.svc.refreshForYou()
        _ = await env.svc.collectionSuggestions(for: "sng_a")
        _ = await env.svc.rawCollectionSuggestions(for: "sng_a")
        // The account-deletion retry is the one toggle-independent call, and with no pending
        // deletion tombstone it must also stay silent.
        await env.svc.retryPendingCloudDelete()
        XCTAssertFalse(env.svc.hasPendingCloudDelete)
        XCTAssertEqual(env.spy.requests.count, 0,
                       "toggle OFF means literally zero network calls — the whole privacy story")
        XCTAssertTrue(env.svc.forYou.isEmpty)
    }

    // MARK: - Flush + cursors

    func testFlushSendsOnlyEventsPastCursorsAndAdvancesOnSuccess() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", title: "A", artist: "Aria", context: .browser, at: 1_000)
        env.history.record(songId: "sng_b", title: "B", artist: "Bea", context: .browser, at: 2_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 1)
        XCTAssertEqual(env.spy.requests[0].url?.path, "/events")
        let first = env.spy.json(0)
        XCTAssertEqual((first["plays"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(first["collectionsSnapshot"], "first flush carries the snapshot")
        XCTAssertNotNil(env.svc.lastSyncedAtMs)

        // Only the NEW event rides the second flush (cursors advanced on the 2xx).
        env.history.record(songId: "sng_c", title: "C", artist: "Cy", context: .browser, at: 3_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2)
        let second = env.spy.json(1)
        let plays = second["plays"] as? [[String: Any]]
        XCTAssertEqual(plays?.count, 1)
        XCTAssertEqual(plays?.first?["songId"] as? String, "sng_c")
        XCTAssertNil(second["collectionsSnapshot"], "unchanged membership sends no snapshot")

        // Nothing new pending → no third request at all.
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2)
    }

    func testFlushDoesNotAdvanceCursorOn403() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        env.spy.status = 403
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 1)
        XCTAssertNotNil(env.svc.syncError, "the key mismatch is surfaced")

        // Same events are re-sent once the key works again — the cursor never moved.
        env.spy.status = 200
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2)
        let retried = env.spy.json(1)
        XCTAssertEqual((retried["plays"] as? [[String: Any]])?.first?["songId"] as? String, "sng_a")
    }

    // MARK: - The WS-D puzzle seam (PuzzleRecEventBridge)

    /// The Games ↔ rec-engine seam, wired exactly as `PocketDJApp` wires it: a Collector's
    /// Puzzle FILING rides the wire as `action: "added"`, a SKIP never does (the server reads
    /// every puzzle event as a positive taste signal), and the engine's puzzle cursor advances
    /// on the 2xx so the same filing is never re-sent.
    func testPuzzleProviderYieldsFilingsAndAdvancesTheCursor() async throws {
        let stateURL = tempURL("sync-puzzle")
        let env = makeEnv(enabled: true, stateURL: stateURL)
        let puzzle = PuzzleDecisionStore(fileURL: tempURL("puzzle-decisions"))
        env.svc.puzzleEventsProvider = { [weak puzzle] sinceMs in
            puzzle?.recPuzzleEvents(sinceMs: sinceMs) ?? []
        }

        let round = UUID()
        let filed = puzzle.record(roundId: round, songId: "sng_a", action: "assigned",
                                  collectionId: "pkt_warmup", collectionName: "Warmup",
                                  positionInRound: 0, at: 1_000)
        _ = puzzle.record(roundId: round, songId: "sng_skipped", action: "skipped",
                          positionInRound: 1, at: 1_500)

        await env.svc.flushNow()
        let rows = try XCTUnwrap(env.spy.json(0)["puzzle"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1, "a skip is not a positive signal — it must not ride")
        XCTAssertEqual(rows[0]["id"] as? String, filed.id.uuidString)
        XCTAssertEqual(rows[0]["atMs"] as? Double, 1_000)
        XCTAssertEqual(rows[0]["songId"] as? String, "sng_a")
        XCTAssertEqual(rows[0]["collectionId"] as? String, "pkt_warmup")
        XCTAssertEqual(rows[0]["action"] as? String, "added")
        XCTAssertEqual(rows[0]["gameId"] as? String, GameKind.collectorsPuzzle.rawValue)
        XCTAssertEqual(rows[0]["points"] as? Int, 1)

        // The cursor moved to the filing's timestamp and its ack was remembered.
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
                                as? [String: Any])
        XCTAssertEqual(doc["lastPuzzleAtMs"] as? Double, 1_000)
        XCTAssertEqual((doc["uploadedPuzzle"] as? [String])?.count, 1)

        // …so only a NEW filing rides the next flush.
        let later = puzzle.record(roundId: round, songId: "sng_b", action: "assigned",
                                  collectionId: "pls_set", collectionName: "Set", at: 2_000)
        await env.svc.flushNow()
        let rows2 = try XCTUnwrap(env.spy.json(1)["puzzle"] as? [[String: Any]])
        XCTAssertEqual(rows2.count, 1, "the acked filing must not be re-sent")
        XCTAssertEqual(rows2[0]["id"] as? String, later.id.uuidString)

        // The projection's own floor, independent of the engine's bookkeeping.
        XCTAssertEqual(puzzle.recPuzzleEvents(sinceMs: 0).map(\.id),
                       [filed.id.uuidString, later.id.uuidString])
        XCTAssertEqual(puzzle.recPuzzleEvents(sinceMs: 1_500).map(\.id), [later.id.uuidString])
        XCTAssertTrue(puzzle.recPuzzleEvents(sinceMs: 3_000).isEmpty)
    }

    func testCollectionsSnapshotSentOnlyWhenHashChanges() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        XCTAssertNotNil(env.spy.json(0)["collectionsSnapshot"])

        env.history.record(songId: "sng_b", context: .browser, at: 2_000)
        await env.svc.flushNow()
        XCTAssertNil(env.spy.json(1)["collectionsSnapshot"], "same membership → no snapshot")

        // Membership changed → the next flush carries a fresh snapshot.
        _ = env.collections.createPocket("Warmup")
        env.history.record(songId: "sng_c", context: .browser, at: 3_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 3)
        let snap = env.spy.json(2)["collectionsSnapshot"] as? [String: Any]
        XCTAssertNotNil(snap)
        let entries = snap?["collections"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?["kind"] as? String, "pocket")
    }

    func testKeyMintedOnceAndStableAcrossReload() async throws {
        let keyURL = tempURL("shared-key")
        let env = makeEnv(enabled: true, keyURL: keyURL)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        let auth1 = try XCTUnwrap(env.spy.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth1.hasPrefix("Bearer "))
        XCTAssertEqual(auth1.count, "Bearer ".count + 64, "32 random bytes hex-encoded")

        // A second service constructed over the SAME key file (a relaunch / another store
        // reload) presents the SAME key. Fresh cursor file so its flush actually sends.
        let env2 = makeEnv(enabled: true, keyURL: keyURL, stateURL: tempURL("sync2"), shared: env)
        await env2.svc.flushNow()
        let auth2 = env2.spy.requests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth2, auth1)
    }

    /// THE cross-device case the pure high-water cursor got wrong: the Mac has the engine OFF
    /// (settings are device-local), so it never uploads; its plays reach this device through the
    /// CloudKit UNION merge carrying their ORIGINAL, older timestamps — BELOW this device's
    /// cursor. With a strict `atMs > cursor` filter nobody ever uploaded them.
    func testCloudMergedPeerEventsBelowTheCursorStillUpload() async throws {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_local", context: .browser, at: 5_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 1)

        // A peer's play, made EARLIER, lands via a CloudKit pull: the sync writes the peer's
        // document over the store's file and the store UNIONs it in.
        let peer = PlayHistoryStore.PlayEvent(
            id: UUID(), songId: "sng_peer", playedAt: 3_000, source: .browser,
            contextId: nil, contextName: nil, title: "Peer", artist: "Mac",
            originInstallId: "peer-install")
        let doc = PlayHistoryStore.Document(installId: "peer-install", events: [peer])
        try JSONEncoder().encode(doc).write(to: env.history.syncFileURL, options: .atomic)
        env.history.reloadFromDisk()
        XCTAssertTrue(env.history.events.contains { $0.songId == "sng_peer" })

        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2, "the merged peer play must upload")
        let plays = try XCTUnwrap(env.spy.json(1)["plays"] as? [[String: Any]])
        XCTAssertEqual(plays.map { $0["songId"] as? String }, ["sng_peer"],
                       "exactly the peer play — the already-acknowledged local play is not re-sent")

        // …and it is not re-sent forever: the ack list closes the window behind it.
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2, "a quiet flush stays silent")
    }

    /// An off→on toggle while a flush is in flight used to leave the cancelled loop's tail
    /// wiping the REPLACEMENT loop's handle — after which `startAutoFlush` armed a second,
    /// uncancellable loop.
    func testCancelledAutoFlushDoesNotDetachTheReplacementLoop() async {
        let gate = Gate()
        let env = makeEnv(enabled: true, gate: gate)
        env.svc.autoFlushDelayNs = 0
        env.svc.autoFlushPeriodNs = 5 * 1_000_000
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)

        env.svc.startAutoFlush()                      // task A → blocks inside postEvents
        await waitUntil("the first flush to be in flight") { env.spy.requests.count == 1 }

        env.settings.recEngineEnabled = false
        env.svc.enabledDidChange()                    // cancels A, detaches the handle
        XCTAssertFalse(env.svc.isAutoFlushArmed)
        env.settings.recEngineEnabled = true
        env.svc.enabledDidChange()                    // arms B
        XCTAssertTrue(env.svc.isAutoFlushArmed)

        await gate.release()                          // A unwinds and runs its tail
        try? await Task.sleep(nanoseconds: 50 * 1_000_000)
        XCTAssertTrue(env.svc.isAutoFlushArmed,
                      "the cancelled loop must not nil the handle of the loop that replaced it")

        // …so a later toggle-off really does cancel the ONE live loop.
        env.settings.recEngineEnabled = false
        env.svc.enabledDidChange()
        XCTAssertFalse(env.svc.isAutoFlushArmed)
    }

    // MARK: - The play-count sub-gate

    /// Lifetime play counts include the Apple Music baseline — a decade of listening imported
    /// wholesale, far older and more complete than the 30-day event stream beside it. It gets its
    /// own switch, and the Play counts settings copy promises that switch works.
    func testLifetimePlayCountsRespectTheirOwnOptOut() async {
        let env = makeEnv(enabled: true)
        env.svc.playCountsProvider = { ["sng_a": 41, "sng_b": 4] }
        env.settings.shareLifetimePlayCounts = false
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()

        XCTAssertEqual(env.spy.requests.count, 1, "the listening history still goes")
        XCTAssertNil(env.spy.json(0)["playCounts"],
                     "…but the imported Apple baseline stays on the device")

        // …and turning it back on sends them, so the switch is a switch and not a placebo.
        env.settings.shareLifetimePlayCounts = true
        env.history.record(songId: "sng_b", context: .browser, at: 2_000)
        await env.svc.flushNow()
        let wire = env.spy.json(1)["playCounts"] as? [String: Any]
        XCTAssertEqual((wire?["counts"] as? [String: Any])?["sng_a"] as? Int, 41)
    }

    /// Default ON — a considered choice, and one the settings copy states outright. If this ever
    /// flips silently the footer becomes a lie in the other direction.
    func testLifetimePlayCountsDefaultToBeingShared() async {
        let env = makeEnv(enabled: true)
        XCTAssertTrue(env.settings.shareLifetimePlayCounts)
        env.svc.playCountsProvider = { ["sng_a": 7] }
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        XCTAssertNotNil(env.spy.json(0)["playCounts"])
    }

    /// Account deletion must not silently orphan the server-side state: the DELETE that failed
    /// leaves a tombstone CARRYING the credential so a later launch can finish. The key file
    /// itself goes immediately — the tombstone is its only afterlife, so a re-enable in the
    /// meantime mints a FRESH identity instead of resurrecting the one being erased.
    func testFailedAccountDeleteTombstonesAndRetries() async throws {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.keyURL.path))
        let boundAuth = env.spy.requests.first?.value(forHTTPHeaderField: "Authorization")
        let boundProfile = env.spy.requests.first?.value(forHTTPHeaderField: "X-PocketDJ-Profile")

        // Offline / 503 at deletion time.
        env.spy.status = 503
        let deleted = await env.svc.deleteCloudData()
        XCTAssertFalse(deleted)
        env.svc.clearLocal(cloudDeleted: deleted)
        XCTAssertTrue(env.svc.hasPendingCloudDelete, "the owed deletion is remembered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.keyURL.path),
                       "the key file goes NOW — the tombstone carries the credential")

        // A later launch, still failing → still owed, and the retry presents the TOMBSTONE'S
        // credential + the exact profile id the original delete targeted.
        let sent = env.spy.requests.count
        await env.svc.retryPendingCloudDelete()
        XCTAssertEqual(env.spy.requests.count, sent + 1)
        let retry = try XCTUnwrap(env.spy.requests.last)
        XCTAssertEqual(retry.httpMethod, "DELETE")
        XCTAssertEqual(retry.value(forHTTPHeaderField: "Authorization"), boundAuth)
        XCTAssertEqual(retry.value(forHTTPHeaderField: "X-PocketDJ-Profile"), boundProfile)
        XCTAssertTrue(env.svc.hasPendingCloudDelete)

        // Meanwhile a re-enable must NOT wedge onto the dying identity: the next flush mints a
        // FRESH key (the old one lives only in the tombstone now).
        env.spy.status = 200
        env.spy.body = Data(#"{"ok":true}"#.utf8)
        env.history.record(songId: "sng_b", context: .browser, at: 2_000)
        await env.svc.flushNow()
        let freshAuth = env.spy.requests.last?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(env.spy.requests.last?.httpMethod, "POST")
        XCTAssertNotEqual(freshAuth, boundAuth, "a re-enable mints a fresh identity")

        // Network back: the retry lands and the tombstone finally goes — without touching the
        // NEW identity's key file.
        env.spy.body = Data(#"{"deleted":true}"#.utf8)
        await env.svc.retryPendingCloudDelete()
        XCTAssertFalse(env.svc.hasPendingCloudDelete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.keyURL.path),
                      "the re-enabled profile's fresh key survives the old retry's cleanup")

        // Idempotent: nothing owed → no further requests.
        let after = env.spy.requests.count
        await env.svc.retryPendingCloudDelete()
        XCTAssertEqual(env.spy.requests.count, after)
    }

    /// The happy path keeps the old contract: a successful cloud delete wipes the key too.
    func testSuccessfulAccountDeleteRemovesTheKeyAndLeavesNoTombstone() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        env.spy.body = Data(#"{"deleted":true}"#.utf8)
        let deleted = await env.svc.deleteCloudData()
        XCTAssertTrue(deleted)
        env.svc.clearLocal(cloudDeleted: deleted)
        XCTAssertFalse(env.svc.hasPendingCloudDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.keyURL.path))
    }

    func testDeleteCloudDataResetsCursors() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 1)

        env.spy.body = Data(#"{"deleted":true}"#.utf8)
        let ok = await env.svc.deleteCloudData()
        XCTAssertTrue(ok)
        XCTAssertEqual(env.spy.requests.last?.httpMethod, "DELETE")

        // Cursors reset → the next flush re-uploads history from the top.
        env.spy.body = Data(#"{"ok":true}"#.utf8)
        await env.svc.flushNow()
        let resent = env.spy.json(env.spy.requests.count - 1)
        XCTAssertEqual((resent["plays"] as? [[String: Any]])?.first?["songId"] as? String, "sng_a")
    }

    // MARK: - Delete-path identity (R1) + deletion vs in-flight flush (R2)

    /// The account-deletion path on a machine where the feature was never on: it must return
    /// success with ZERO network and ZERO minted identity. The old unconditional `ensureKey()`
    /// manufactured + persisted a brand-new key (and a server call) out of thin air.
    func testNeverEnabledAccountDeletionStaysOfflineAndMintsNothing() async {
        let env = makeEnv(enabled: false)
        let deleted = await env.svc.deleteCloudData()
        XCTAssertTrue(deleted, "nothing owed IS success")
        env.svc.clearLocal(cloudDeleted: deleted)
        XCTAssertEqual(env.spy.requests.count, 0, "zero network")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.keyURL.path), "no key minted")
        XCTAssertFalse(env.svc.hasPendingCloudDelete, "no tombstone invented")
    }

    /// "Delete cloud data" landing MID-DRAIN: the delete awaits the in-flight batch (so no
    /// upload can re-create the state after the DELETE), and the abandoned drain must not
    /// resurrect cursors past batches the server no longer has — the next flush re-uploads
    /// everything from the top.
    func testDeleteMidDrainAbandonsTheFlushWithoutResurrectingCursors() async {
        let gate = Gate()
        let env = makeEnv(enabled: true, gate: gate)
        for i in 0..<501 {   // two batches: 500 + 1
            env.history.record(songId: "sng_\(i)", context: .browser, at: Double(1_000 + i))
        }
        let flush = Task { await env.svc.flushNow() }
        await waitUntil("first batch in flight") { env.spy.requests.count == 1 }
        let delete = Task { await env.svc.deleteCloudData() }
        await Task.yield()
        await gate.release()   // batch 1 answers; the drain must now abandon
        _ = await flush.value
        let deleted = await delete.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(env.spy.requests.map(\.httpMethod), ["POST", "DELETE"],
                       "batch 2 was never sent — the drain abandoned at the epoch check")

        // Cursors reset by the delete and NOT resurrected by the drain's bookkeeping: the next
        // flush starts over with the full first batch.
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 4, "two fresh batches")
        let first = env.spy.json(2)["plays"] as? [[String: Any]]
        XCTAssertEqual(first?.count, 500)
        XCTAssertEqual(first?.first?["songId"] as? String, "sng_0",
                       "re-upload starts from the very first event")
    }

    // MARK: - Tombstone lifecycle bounds (R3)

    /// The device-local tombstone file next to the key doc (mirrors the service's own layout).
    private func pendingDeleteURL(for keyURL: URL) -> URL {
        keyURL.deletingLastPathComponent()
            .appendingPathComponent(keyURL.deletingPathExtension().lastPathComponent
                                    + "-pending-delete.json")
    }

    /// A 403 on the retry is TERMINAL — key-mismatch and enrollment-required alike mean the
    /// stored credential can never succeed — so the tombstone goes and a notice surfaces
    /// instead of a dead request retrying forever.
    func testTerminal403RemovesTheTombstone() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        env.spy.status = 503
        let deleted = await env.svc.deleteCloudData()
        env.svc.clearLocal(cloudDeleted: deleted)
        XCTAssertTrue(env.svc.hasPendingCloudDelete)

        env.spy.status = 403
        env.spy.body = Data(#"{"error":"key-mismatch"}"#.utf8)
        let sent = env.spy.requests.count
        await env.svc.retryPendingCloudDelete()
        XCTAssertEqual(env.spy.requests.count, sent + 1, "exactly one terminal attempt")
        XCTAssertFalse(env.svc.hasPendingCloudDelete, "a 403 can never start succeeding")
        XCTAssertNotNil(env.svc.syncError, "the give-up is surfaced once")

        // …and nothing retries after cleanup.
        await env.svc.retryPendingCloudDelete()
        XCTAssertEqual(env.spy.requests.count, sent + 1)
    }

    /// Transient failures are bounded too: after the attempt ceiling the tombstone gives up
    /// and cleans up rather than dialing a dead server monthly forever.
    func testRetryCeilingGivesUpAndCleansUp() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        env.spy.status = 503
        let deleted = await env.svc.deleteCloudData()
        env.svc.clearLocal(cloudDeleted: deleted)

        for _ in 0..<20 {   // 20 transient failures = the ceiling
            await env.svc.retryPendingCloudDelete()
        }
        XCTAssertTrue(env.svc.hasPendingCloudDelete, "still owed at exactly the ceiling")
        let sent = env.spy.requests.count
        await env.svc.retryPendingCloudDelete()   // 21st: gives up WITHOUT a request
        XCTAssertEqual(env.spy.requests.count, sent)
        XCTAssertFalse(env.svc.hasPendingCloudDelete)
    }

    /// The 30-day wall clock bound, independent of attempt count.
    func testStaleTombstoneGivesUpByAge() async throws {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        env.spy.status = 503
        let deleted = await env.svc.deleteCloudData()
        env.svc.clearLocal(cloudDeleted: deleted)

        // Age the tombstone 31 days.
        let url = pendingDeleteURL(for: env.keyURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        doc["requestedAtMs"] = Date().timeIntervalSince1970 * 1000 - 31 * 24 * 3600 * 1000
        try JSONSerialization.data(withJSONObject: doc).write(to: url)

        let sent = env.spy.requests.count
        await env.svc.retryPendingCloudDelete()
        XCTAssertEqual(env.spy.requests.count, sent, "no request for an expired tombstone")
        XCTAssertFalse(env.svc.hasPendingCloudDelete)
    }

    // MARK: - 403 disambiguation (R4)

    /// A rotated server secret must NOT masquerade as a key mismatch: the key-mismatch advice
    /// ("Delete cloud data") can never fix it, only an app update can — and the flush path is
    /// where a real device hits it first.
    func testFlushSurfacesEnrollmentRequiredDistinctly() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        env.spy.status = 403
        env.spy.body = Data(#"{"error":"enrollment-required"}"#.utf8)
        await env.svc.flushNow()
        let err = env.svc.syncError ?? ""
        XCTAssertTrue(err.contains("Update the app"), "actionable: \(err)")
        XCTAssertFalse(err.contains("Delete cloud data"),
                       "must not point at the reset that cannot help")
    }

    // MARK: - Client snapshot budget (R5)

    func testSnapshotTotalSongIdBudgetIsCapped() async throws {
        let env = makeEnv(enabled: true)
        for p in 0..<25 {   // 25 × 5000 = 125k memberships — 25k past the server's total cap
            _ = env.collections.createPocket("P\(p)", songIds: (0..<5_000).map { "s\(p)_\($0)" })
        }
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        let snap = try XCTUnwrap(env.spy.json(0)["collectionsSnapshot"] as? [String: Any])
        let entries = try XCTUnwrap(snap["collections"] as? [[String: Any]])
        let total = entries.reduce(0) { $0 + (($1["songIds"] as? [String])?.count ?? 0) }
        XCTAssertEqual(total, 100_000, "mirrors the server's MAX_SNAPSHOT_SONGIDS")
        XCTAssertEqual(entries.count, 25, "collections keep appearing; only ids are shed")
    }

    /// A snapshot that ENCODES past the body budget is dropped — events must never become
    /// undeliverable because the membership happens to be huge.
    func testOversizedSnapshotIsDroppedEventsStillFlow() async throws {
        let env = makeEnv(enabled: true)
        let longId = String(repeating: "x", count: 300)
        for p in 0..<3 {   // 3 × 5000 × ~300 B ≈ 4.6 MB encoded > the 3.5 MB guard
            _ = env.collections.createPocket("P\(p)",
                                             songIds: (0..<5_000).map { "\(longId)_\(p)_\($0)" })
        }
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 1)
        let body = env.spy.json(0)
        XCTAssertNil(body["collectionsSnapshot"], "the oversized snapshot is dropped")
        XCTAssertEqual((body["plays"] as? [[String: Any]])?.count, 1, "the play still uploads")
    }

    /// The server answering 413 on a snapshot-carrying batch: drop the SNAPSHOT, deliver the
    /// events — and leave the membership hash un-advanced so the snapshot re-attempts on a
    /// later flush instead of silently never uploading again.
    func test413DropsTheSnapshotAndResendsEventsOnly() async throws {
        let env = makeEnv(enabled: true)
        _ = env.collections.createPocket("Warmup", songIds: ["sng_a"])
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        env.spy.scripted = [(413, Data(#"{"error":"body-too-large"}"#.utf8))]
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2)
        XCTAssertNotNil(env.spy.json(0)["collectionsSnapshot"], "first attempt carried it")
        XCTAssertNil(env.spy.json(1)["collectionsSnapshot"], "retry is events-only")
        XCTAssertEqual((env.spy.json(1)["plays"] as? [[String: Any]])?.count, 1)

        // Events are acked (no re-send), but the snapshot re-attempts on the next flush.
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 3)
        let retry = env.spy.json(2)
        XCTAssertNotNil(retry["collectionsSnapshot"], "hash was not advanced by the 413")
        XCTAssertNil(retry["plays"], "the delivered events are not re-sent")
    }

    // MARK: - Ack eviction (R7)

    /// The cap must evict by TIMESTAMP, newest kept — `suffix()` of append order evicted the
    /// newest LOCAL acks whenever a batch of older peer events appended after them, and every
    /// evicted ack is a permanent re-send next flush (evict → re-send → re-ack → evict).
    func testAckEvictionKeepsNewestByTimestampNotAppendOrder() {
        // Append order: newest first, oldest last — the pathological case for suffix().
        let existing = ["9000|new-a", "8000|new-b", "7000|new-c"]
        let added = ["1000|peer-x", "2000|peer-y", "3000|peer-z"]
        let kept = RecommendationService.remember(existing, added, floor: 0, cap: 4)
        XCTAssertEqual(Set(kept), ["9000|new-a", "8000|new-b", "7000|new-c", "3000|peer-z"],
                       "the four NEWEST survive regardless of append position")

        // The floor still prunes below-window entries before the cap even matters.
        let pruned = RecommendationService.remember(existing, added, floor: 7_500, cap: 4)
        XCTAssertEqual(Set(pruned), ["9000|new-a", "8000|new-b"])
    }

    // MARK: - Cancellation is not an error (R10)

    /// A transport torn down mid-flight (app background, task cancelled) is NOT a sync failure:
    /// it must never paint the "couldn't reach" banner.
    func testCancelledTransportSurfacesNoError() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        env.spy.error = URLError(.cancelled)
        await env.svc.flushNow()
        XCTAssertNil(env.svc.syncError, "URLError.cancelled is swallowed")

        env.spy.error = CancellationError()
        await env.svc.flushNow()
        XCTAssertNil(env.svc.syncError, "CancellationError is swallowed")

        // A REAL failure still surfaces.
        env.spy.error = URLError(.notConnectedToInternet)
        await env.svc.flushNow()
        XCTAssertNotNil(env.svc.syncError)
    }

    /// Toggle-off lands while a failing flush is in flight: `enabledDidChange` cleared the
    /// error state, and the late failure must NOT repaint it (the stale-error half of the
    /// epoch guard).
    func testToggleOffMidFlightLeavesNoStaleError() async {
        let gate = Gate()
        let env = makeEnv(enabled: true, gate: gate)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        env.spy.status = 500
        let flush = Task { await env.svc.flushNow() }
        await waitUntil("request in flight") { env.spy.requests.count == 1 }
        env.settings.recEngineEnabled = false
        env.svc.enabledDidChange()
        await gate.release()
        _ = await flush.value
        XCTAssertNil(env.svc.syncError, "a flush the toggle-off outlived must stay silent")
    }

    // MARK: - Scoped profile id (R11)

    /// What HMAC the service must derive (mirrors `scopedProfileId`).
    private func scoped(_ profileId: String, key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(profileId.utf8),
                                                  using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// The rec server must never see the broadcast profile id — that same header goes to
    /// user-configured third-party jukebox/rip servers, any of which could otherwise address
    /// this profile's rec state for DELETE/rebind. The scoped id is HMAC(profileId, key):
    /// computable only with the bearer key, stable across flushes and devices sharing the key.
    func testRecCallsCarryTheScopedProfileIdNotTheBroadcastOne() async throws {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        let req = try XCTUnwrap(env.spy.requests.first)
        let auth = try XCTUnwrap(req.value(forHTTPHeaderField: "Authorization"))
        let key = String(auth.dropFirst("Bearer ".count))
        let header = try XCTUnwrap(req.value(forHTTPHeaderField: "X-PocketDJ-Profile"))
        XCTAssertNotEqual(header, "profile-test-1234", "the broadcast id must not ride")
        XCTAssertEqual(header, scoped("profile-test-1234", key: key))
        XCTAssertEqual(header.count, 64)

        // Stable on the next call.
        env.history.record(songId: "sng_b", context: .browser, at: 2_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.last?.value(forHTTPHeaderField: "X-PocketDJ-Profile"),
                       header)
    }

    /// A profile that uploaded under an OLD build (raw broadcast id) migrates exactly once:
    /// DELETE the old object, then everything re-enrolls under the scoped id. Transient
    /// failure retries next flush; a fresh install never issues the DELETE at all.
    func testLegacyProfileMigratesOnceAndFreshInstallsDoNot() async throws {
        // Legacy evidence: a sync doc with uploads recorded but no migration flag.
        let stateURL = tempURL("sync-legacy")
        try Data(#"{"schemaVersion":1,"lastSyncedAtMs":5}"#.utf8).write(to: stateURL)
        let env = makeEnv(enabled: true, stateURL: stateURL)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)

        // First flush: the migration DELETE fails transiently → flush aborts, retries later.
        env.spy.scripted = [(503, Data(#"{"error":"internal"}"#.utf8))]
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.map(\.httpMethod), ["DELETE"])
        XCTAssertEqual(env.spy.requests[0].value(forHTTPHeaderField: "X-PocketDJ-Profile"),
                       "profile-test-1234", "the migration targets the RAW id")

        // Next flush: DELETE lands, upload follows under the scoped id.
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.map(\.httpMethod), ["DELETE", "DELETE", "POST"])
        let post = try XCTUnwrap(env.spy.requests.last)
        XCTAssertNotEqual(post.value(forHTTPHeaderField: "X-PocketDJ-Profile"), "profile-test-1234")

        // Once done, never again.
        env.history.record(songId: "sng_b", context: .browser, at: 2_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.map(\.httpMethod), ["DELETE", "DELETE", "POST", "POST"])

        // And a genuinely fresh install (second env, fresh files) skips the DELETE entirely.
        let fresh = makeEnv(enabled: true)
        fresh.history.record(songId: "sng_c", context: .browser, at: 3_000)
        await fresh.svc.flushNow()
        XCTAssertEqual(fresh.spy.requests.map(\.httpMethod), ["POST"])
    }

    /// The migration DELETES the object that held everything this device had already acked, so
    /// it must also RESET the cursors — otherwise the ack list suppressed exactly that history
    /// and the scoped-id object stayed empty forever (the whole profile's server-side data,
    /// silently discarded by the security fix meant to protect it).
    func testMigrationReUploadsTheHistoryTheDeletedObjectHeld() async throws {
        // Build the legacy state the honest way: let a pre-migration build upload + ack.
        let stateURL = tempURL("sync-legacy-acked")
        let keyURL = tempURL("key-legacy-acked")
        let seed = makeEnv(enabled: true, keyURL: keyURL, stateURL: stateURL)
        seed.history.record(songId: "sng_a", context: .browser, at: 1_000)
        seed.history.record(songId: "sng_b", context: .browser, at: 2_000)
        await seed.svc.flushNow()
        XCTAssertEqual((seed.spy.json(0)["plays"] as? [[String: Any]])?.count, 2)

        // Rewind the persisted doc to what an OLD build wrote: same cursors + acks, no flag.
        var doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
                                as? [String: Any])
        XCTAssertEqual(doc["didMigrateScopedProfile"] as? Bool, true, "the seed did migrate")
        XCTAssertEqual((doc["uploadedPlays"] as? [String])?.count, 2, "…and remembered its acks")
        doc["didMigrateScopedProfile"] = false
        try JSONSerialization.data(withJSONObject: doc).write(to: stateURL)

        // A build carrying the fix opens the same files: DELETE the raw-id object, then re-send
        // BOTH acked plays under the scoped id.
        let env = makeEnv(enabled: true, keyURL: keyURL, stateURL: stateURL, shared: seed)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.map(\.httpMethod), ["DELETE", "POST"])
        let resent = env.spy.json(1)["plays"] as? [[String: Any]]
        XCTAssertEqual(resent?.count, 2, "the migration re-uploads what the deleted object held")
        XCTAssertEqual(resent?.compactMap { $0["songId"] as? String }, ["sng_a", "sng_b"])
    }

    /// Losing the two-devices key race: the pulled (winning) key replaces ours — the state we
    /// uploaded lives under OUR key's derived id, which nothing will ever read again. The
    /// rebind must reset the cursors (everything re-uploads under the winner's id) and erase
    /// the orphaned object while the old key still authorizes it.
    func testKeyRebindResetsCursorsAndDeletesTheOrphan() async throws {
        let keyURL = tempURL("rebind-key")
        let keyA = String(repeating: "a", count: 64)
        let keyB = String(repeating: "b", count: 64)
        try Data(#"{"schemaVersion":1,"key":"\#(keyA)"}"#.utf8).write(to: keyURL)
        let env = makeEnv(enabled: true, keyURL: keyURL)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests[0].value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(keyA)")

        // CloudSync pulls the winner's doc.
        try Data(#"{"schemaVersion":1,"key":"\#(keyB)"}"#.utf8).write(to: keyURL)
        env.svc.reloadKeyFromDisk()
        await waitUntil("orphan delete") { env.spy.requests.count == 2 }
        let orphan = try XCTUnwrap(env.spy.requests.last)
        XCTAssertEqual(orphan.httpMethod, "DELETE")
        XCTAssertEqual(orphan.value(forHTTPHeaderField: "Authorization"), "Bearer \(keyA)")
        XCTAssertEqual(orphan.value(forHTTPHeaderField: "X-PocketDJ-Profile"),
                       scoped("profile-test-1234", key: keyA))

        // The next flush re-uploads EVERYTHING under the winner's identity.
        await env.svc.flushNow()
        let resent = try XCTUnwrap(env.spy.requests.last)
        XCTAssertEqual(resent.httpMethod, "POST")
        XCTAssertEqual(resent.value(forHTTPHeaderField: "Authorization"), "Bearer \(keyB)")
        XCTAssertEqual(resent.value(forHTTPHeaderField: "X-PocketDJ-Profile"),
                       scoped("profile-test-1234", key: keyB))
        let plays = resent.httpBody.flatMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["plays"] as? [[String: Any]]
        }
        XCTAssertEqual(plays?.first?["songId"] as? String, "sng_a", "the cursor reset re-sends it")

        // An unchanged re-read (the common pull) stays a no-op.
        let count = env.spy.requests.count
        env.svc.reloadKeyFromDisk()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(env.spy.requests.count, count)
    }

    // MARK: - Fixture seam

    func testFixtureSeamServesCannedForYou() async {
        let env = makeEnv(enabled: false)
        env.svc.fixtureForTesting = true
        await env.svc.refreshForYou()
        // The canned ids are the BUNDLED FIXTURE CATALOG'S own, because this list is now the cloud
        // ranking for In Da Zone and the device drops ids it cannot resolve — ids from nowhere
        // would make every UI run silently exercise the fallback instead of the cloud path.
        XCTAssertEqual(env.svc.forYou.map(\.songId), ["sng_5", "sng_7", "sng_2", "sng_6"])
        XCTAssertEqual(env.svc.forYou.first?.name, "Blue Note")

        // Canned collection suggestions come from the live collections (first playlists + pocket).
        _ = env.collections.createPocket("Soul")
        _ = env.collections.createPlaylist("Warmup")
        let sugs = await env.svc.collectionSuggestions(for: "sng_x")
        XCTAssertEqual(sugs.count, 2)
        XCTAssertTrue(sugs.contains { $0.kind == "playlist" && $0.name == "Warmup" })
        XCTAssertTrue(sugs.contains { $0.kind == "pocket" && $0.name == "Soul" })

        XCTAssertEqual(env.spy.requests.count, 0, "the fixture seam never touches the network")
    }

    // ========================================================================
    // MARK: - The cloud ranking for In Da Zone
    // ========================================================================
    //
    // Owner, verbatim: "new and in da zone should use the recommendation engine if available,
    // only doing on device when not enabled." `cloudZoneRanking` is the "if available" test, and
    // its whole contract is that it answers with A LIST OR NOTHING — the caller must never have to
    // interpret an error to decide whether to fall back.

    func testCloudZoneRankingIsSilentAndEmptyWhileTheEngineIsOff() async {
        let env = makeEnv(enabled: false)
        let ids = await env.svc.cloudZoneRanking()
        XCTAssertTrue(ids.isEmpty, "no answer ⇒ the caller keeps its on-device ranking")
        XCTAssertEqual(env.spy.requests.count, 0,
                       "and the default-OFF install still makes literally zero requests")
    }

    func testCloudZoneRankingReturnsTheServersOrderedIds() async {
        let env = makeEnv(enabled: true)
        env.spy.body = Data(#"""
        {"songs":[{"songId":"sng_c","reasons":["Often played together","BPM near 120"]},
                  {"songId":"sng_a","reasons":[]},
                  {"songId":"sng_b"}]}
        """#.utf8)
        let ids = await env.svc.cloudZoneRanking()
        XCTAssertEqual(ids.map(\.songId), ["sng_c", "sng_a", "sng_b"], "server order, untouched")
        // The Lambda's why rides each row VERBATIM — first reason wins (the server's own
        // precedence), and a row it sent without one arrives as nil, never "".
        XCTAssertEqual(ids[0].why, "Often played together")
        XCTAssertNil(ids[1].why, "an empty reasons array is no reason")
        XCTAssertNil(ids[2].why, "a missing reasons key is no reason")
        let get = env.spy.requests.last
        XCTAssertEqual(get?.httpMethod, "GET")
        XCTAssertTrue(get?.url?.path.hasSuffix("/recs/songs") ?? false)
        // The tile caps at 90 songs but the device then drops unresolvable ids, cooldowns,
        // tombstones and everything over the 3-per-artist cap — so the fetch has to over-ask.
        XCTAssertEqual(get?.url?.query?.contains("limit=\(RecommendationService.forYouFetchLimit)"),
                       true)
        XCTAssertGreaterThan(RecommendationService.forYouFetchLimit,
                             ZoneEngine.Tuning().maxSongs)
    }

    /// An unreachable server, a 5xx and a wedged key are all the SAME answer to the caller: none.
    /// Anything else — a throw, a partial list, a sentinel — would make a cloud outage visible as
    /// an empty For You tile, which is the failure this shape exists to prevent.
    func testEveryServerFailureIsAnEmptyAnswerRatherThanAnError() async {
        let cases: [(String, (Spy) -> Void)] = [
            ("offline", { $0.error = URLError(.notConnectedToInternet) }),
            ("5xx", { $0.status = 503 }),
            ("wedged key", { $0.status = 403; $0.body = Data(#"{"error":"key-mismatch"}"#.utf8) }),
            ("empty list", { $0.body = Data(#"{"songs":[]}"#.utf8) }),
        ]
        for (label, apply) in cases {
            let env = makeEnv(enabled: true)
            apply(env.spy)
            let ids = await env.svc.cloudZoneRanking()
            XCTAssertTrue(ids.isEmpty, "\(label): the caller falls back rather than erroring")
        }
    }
}
