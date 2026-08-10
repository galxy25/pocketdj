import XCTest
@testable import PocketDJ

/// RECOMMENDATIONS AND ACCEPT/REJECT, ACROSS DEVICES — driven as a REAL round trip.
///
/// Owner, verbatim: *"syncing of recommendations (and accept reject) at the profile level so it is
/// synced across all devices."*
///
/// Two devices, two Application-Support directories, two `CloudSyncService` instances, one
/// in-memory stand-in for the CloudKit private database. Nothing here reaches into a store's
/// internals to fake a pull: a verdict recorded on A is pushed by A's sync engine, pulled by B's,
/// and read back through the same `partition` / `weights` the tiles use. That is the only shape in
/// which this feature can be shown to work — a unit test that calls `reloadFromDisk` by hand proves
/// the merge, never the transport.
///
/// ── THE TWO HALVES ARE MERGED DIFFERENTLY, AND THAT IS THE DESIGN ────────────────────────────
///   · VERDICTS are an append-only LOG, so they union by id: idempotent, order-free, and a device
///     that was offline for a week loses nothing. (This half already worked — `rec-feedback` was
///     registered with the union merge; what it had never had was a test that a verdict survives
///     the transport with its TIMESTAMP, which is what the seven-day expiry is evaluated against.)
///   · THE FEED is a SNAPSHOT — one indivisible ranking. Union-merging two of them would interleave
///     them into a third ranking neither engine produced, so it is whole-document last-writer-wins,
///     ordered by the REFRESH INSTANT (see `ForYouFeedStore.stampMtime`).
@MainActor
final class RecSyncRoundTripTests: XCTestCase {

    private typealias MemoryCloudDB = CloudSyncServiceTests.MemoryCloudDB

    private var root: URL!
    private var identityKeys: [String] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-recsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        // The install identity lives in UserDefaults (so a pulled document cannot overwrite it),
        // which is process-global and outlives a test run on a simulator.
        identityKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        identityKeys = []
    }

    // MARK: - Rigging

    /// One simulated device: its own directory, its own sync engine, its own install identity.
    @MainActor private struct Device {
        let dir: URL
        let sync: CloudSyncService
        let feedback: RecFeedbackStore
        let feed: ForYouFeedStore
        var feedbackURL: URL { feedback.syncFileURL }
        var feedURL: URL { feed.syncFileURL }
    }

    private func makeDevice(_ name: String, db: MemoryCloudDB) throws -> Device {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = "PDJTestRecInstall-\(name)-\(UUID().uuidString)"
        identityKeys.append(key)
        let feedback = RecFeedbackStore(fileURL: dir.appendingPathComponent("rec-feedback.json"),
                                        identityKey: key)
        let feed = ForYouFeedStore(fileURL: dir.appendingPathComponent("foryou-feed.json"))
        let sync = CloudSyncService(database: db, enabled: { true },
                                    stateURL: dir.appendingPathComponent("cloudsync-state.json"))
        // EXACTLY the wiring PocketDJApp.init installs — the point of this file is that the app's
        // registry works, not that some other registry would.
        sync.register("rec-feedback", fileURL: feedback.syncFileURL,
                      reload: { _ = feedback.reloadFromDisk() },
                      applyPayload: { feedback.applyPulledPayload($0) })
        sync.register("foryou-feed", fileURL: feed.syncFileURL,
                      reload: { _ = feed.reloadFromDisk() },
                      applyPayload: { feed.applyPulledPayload($0) })
        return Device(dir: dir, sync: sync, feedback: feedback, feed: feed)
    }

    private func mtimeMs(_ url: URL) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    private func setMtime(_ url: URL, _ ms: Double) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: ms / 1000)], ofItemAtPath: url.path)
    }

    private func snapshot(_ zone: [String], at ms: Double) -> ForYouFeedSnapshot {
        ForYouFeedSnapshot(refreshedAtMs: ms, zoneIds: zone, zoneBuriedIds: [], crates: [])
    }

    private let day: Double = 86_400_000

    // ========================================================================
    // MARK: - Accept / reject: the round trip the owner described
    // ========================================================================

    /// THE HEADLINE CASE. Device A thumbs a song down on a collection tile; device B pulls; the row
    /// is sunk on B; and seven days later it is live again — ON BOTH — because the expiry is
    /// evaluated from the stamp that rode across, not from when each device happened to hear about
    /// it. A transport that re-stamped the verdict on arrival would give B its own private seven
    /// days, so the two devices would disagree about when the row comes back.
    func testRejectOnDeviceASinksOnDeviceBAndExpiresOnScheduleOnBoth() async throws {
        let db = MemoryCloudDB()
        let a = try makeDevice("A", db: db)
        let b = try makeDevice("B", db: db)
        let scope = "pkt_gym"
        let offered = ["s1", "s2", "s3"]
        let rejectedAt = Date().timeIntervalSince1970 * 1000 - 3 * day

        a.feedback.record(songId: "s2", scope: scope, verdict: .rejected, surface: .tile,
                          at: rejectedAt)
        a.feedback.flush()
        setMtime(a.feedbackURL, rejectedAt)

        await a.sync.syncNow()      // publish
        await b.sync.syncNow()      // B has no file at all ⇒ pull

        // The verdict is on B, with A's stamp — not B's clock.
        XCTAssertEqual(b.feedback.verdict(songId: "s2", scope: scope), .rejected)
        XCTAssertEqual(b.feedback.activeTombstones(scope: scope, nowMs: rejectedAt + day)["s2"],
                       rejectedAt, "the reject stamp must survive the transport verbatim")

        // Sunk on B, in the same place it is sunk on A.
        let onB = b.feedback.partition(offered, scope: scope, nowMs: rejectedAt + day)
        XCTAssertEqual(onB.live, ["s1", "s3"])
        XCTAssertEqual(onB.sunk, ["s2"])
        let onA = a.feedback.partition(offered, scope: scope, nowMs: rejectedAt + day)
        XCTAssertEqual(onA.live, onB.live)
        XCTAssertEqual(onA.sunk, onB.sunk)

        // …and it expires on the SAME instant on both, seven days after the reject.
        let afterExpiry = rejectedAt + RecFeedbackStore.tombstoneMs + 1
        XCTAssertTrue(a.feedback.partition(offered, scope: scope, nowMs: afterExpiry).sunk.isEmpty)
        XCTAssertTrue(b.feedback.partition(offered, scope: scope, nowMs: afterExpiry).sunk.isEmpty)
        // Suppression is SCOPED — it must never have leaked into another tile on the way over.
        XCTAssertFalse(b.feedback.isSuppressed(songId: "s2", scope: "zone",
                                               nowMs: rejectedAt + day))
    }

    /// The GLOBAL half of a reject — taste — is not scoped and does not expire; it DECAYS from the
    /// original stamp. So the same song must carry the same weight on both devices at the same
    /// instant. (Re-stamping on arrival would make a two-year-old opinion look like this morning's
    /// on every device that pulled it late.)
    func testTasteWeightIsIdenticalOnBothDevicesBecauseTheStampRodeAcross() async throws {
        let db = MemoryCloudDB()
        let a = try makeDevice("A", db: db)
        let b = try makeDevice("B", db: db)
        let long = Date().timeIntervalSince1970 * 1000 - 200 * day

        a.feedback.record(songId: "s9", scope: "zone", verdict: .rejected, surface: .nowPlaying,
                          at: long)
        a.feedback.flush()
        setMtime(a.feedbackURL, long)
        await a.sync.syncNow()
        await b.sync.syncNow()

        let now = Date().timeIntervalSince1970 * 1000
        let wA = a.feedback.weights(.rejected, nowMs: now)["s9"]
        let wB = b.feedback.weights(.rejected, nowMs: now)["s9"]
        XCTAssertNotNil(wB)
        XCTAssertEqual(wA ?? -1, wB ?? -2, accuracy: 1e-9)
        XCTAssertLessThan(wB ?? 1, 1.0, "a 200-day-old opinion must arrive already decayed")
        XCTAssertGreaterThanOrEqual(wB ?? 0, 0.05, "…but floored, not zeroed")
    }

    /// Both devices thumbed something while apart. A LOG unions, so neither loses its own rows —
    /// and the superset publishes back, so the device that was ahead ends up with both too.
    func testEachDeviceKeepsItsOwnVerdictsAndGainsThePeers() async throws {
        let db = MemoryCloudDB()
        let a = try makeDevice("A", db: db)
        let b = try makeDevice("B", db: db)
        let base = Date().timeIntervalSince1970 * 1000 - 2 * day

        a.feedback.record(songId: "s1", scope: "zone", verdict: .rejected, surface: .tile, at: base)
        a.feedback.flush()
        setMtime(a.feedbackURL, base)
        b.feedback.record(songId: "s2", scope: "zone", verdict: .accepted, surface: .carPlay,
                          at: base - 60_000)
        b.feedback.flush()
        setMtime(b.feedbackURL, base - 60_000)

        await a.sync.syncNow()   // A publishes s1
        await b.sync.syncNow()   // B pulls, unions, re-saves the superset (s1 + s2)
        await b.sync.syncNow()   // …which then publishes
        await a.sync.syncNow()   // A pulls it back

        XCTAssertEqual(a.feedback.verdict(songId: "s2", scope: "zone"), .accepted,
                       "A must gain the peer's row")
        XCTAssertEqual(a.feedback.verdict(songId: "s1", scope: "zone"), .rejected,
                       "…without losing its own")
        XCTAssertEqual(b.feedback.verdict(songId: "s1", scope: "zone"), .rejected)
        XCTAssertEqual(b.feedback.verdict(songId: "s2", scope: "zone"), .accepted)
    }

    /// A pulled document describes what a PEER had queued. Adopting its `playing` scope would file
    /// the next lock-screen 👎 given here against a tile that is playing on the other device — the
    /// one cross-device way this feature could attach a verdict to the wrong list.
    func testAPeersPlayingScopeIsNotAdoptedAsOurs() async throws {
        let db = MemoryCloudDB()
        let a = try makeDevice("A", db: db)
        let b = try makeDevice("B", db: db)
        let base = Date().timeIntervalSince1970 * 1000 - day

        a.feedback.beginPlayback(scope: "pkt_gym", songIds: ["s1", "s2"], at: base)
        a.feedback.flush()
        setMtime(a.feedbackURL, base)
        await a.sync.syncNow()
        await b.sync.syncNow()

        // Relaunch each device against the file that is now on its disk.
        let aKey = identityKeys[0], bKey = identityKeys[1]
        let aReborn = RecFeedbackStore(fileURL: a.feedbackURL, identityKey: aKey)
        let bReborn = RecFeedbackStore(fileURL: b.feedbackURL, identityKey: bKey)
        XCTAssertEqual(aReborn.scope(forPlaying: "s1"), "pkt_gym",
                       "our OWN persisted scope must still survive a cold launch")
        XCTAssertNil(bReborn.scope(forPlaying: "s1"),
                     "a peer's queue is not this device's queue")
        XCTAssertEqual(bReborn.installId, b.feedback.installId,
                       "a pulled document must not rewrite this install's identity")
    }

    // ========================================================================
    // MARK: - The feed: a snapshot, ordered by REFRESH INSTANT
    // ========================================================================

    /// The ranking itself follows the Apple ID. This is the half that did not exist: For You was
    /// computed per device, so the phone and the Mac showed different recommendations and each ran
    /// its own 4:20 sweep.
    func testTheCachedRankingReachesTheOtherDevice() async throws {
        let db = MemoryCloudDB()
        let a = try makeDevice("A", db: db)
        let b = try makeDevice("B", db: db)
        let now = Date().timeIntervalSince1970 * 1000
        let older = now - 4 * 3_600_000, newer = now - 3_600_000

        b.feed.commit(snapshot(["b1", "b2"], at: older))
        a.feed.commit(snapshot(["a1", "a2", "a3"], at: newer))

        await a.sync.syncNow()
        await b.sync.syncNow()

        XCTAssertEqual(b.feed.snapshot.zoneIds, ["a1", "a2", "a3"])
        // B inherits the REFRESH INSTANT, not just the ids — and that is what makes the 4:20
        // schedule fire once per ACCOUNT instead of once per device. `ForYouRefreshSchedule.isDue`
        // is evaluated against `refreshedAtMs`, so two devices carrying the same stamp answer it
        // identically; before this, B's stamp was its own older sweep and it would have re-ranked.
        XCTAssertEqual(b.feed.snapshot.refreshedAtMs, newer)
        XCTAssertEqual(b.feed.snapshot.refreshedAtMs, a.feed.snapshot.refreshedAtMs)
    }

    /// THE REGRESSION THIS DESIGN EXISTS FOR, and it is invisible without the mtime stamp.
    ///
    /// A pull WRITES the feed file, so with a raw mtime the receiving device is stamped *now* while
    /// its contents are from whenever the peer last refreshed. It then (a) looks newer than a
    /// genuinely fresher ranking the peer pushes moments later and refuses to pull it, and (b)
    /// cannot push either, because its own watermark equals that mtime. It sits on a stale feed
    /// forever, with no symptom. Stamping the file with `refreshedAtMs` makes the engine's LWW a
    /// comparison of refresh recency: PULLING NEVER COUNTS AS REFRESHING.
    func testPullingDoesNotMakeADeviceLookFresherThanTheRankingItReceived() async throws {
        let db = MemoryCloudDB()
        let a = try makeDevice("A", db: db)
        let b = try makeDevice("B", db: db)
        let now = Date().timeIntervalSince1970 * 1000
        let first = now - 3_600_000        // A's ranking from an hour ago
        let second = now - 1_800_000       // …and its next one, half an hour ago

        a.feed.commit(snapshot(["a1"], at: first))
        await a.sync.syncNow()
        await b.sync.syncNow()             // B pulls the HOUR-OLD ranking, right now

        XCTAssertEqual(b.feed.snapshot.zoneIds, ["a1"])
        XCTAssertEqual(mtimeMs(b.feedURL) ?? 0, first, accuracy: 1_000,
                       "the pulled file is stamped with the REFRESH instant, not the pull instant")
        XCTAssertLessThan(mtimeMs(b.feedURL) ?? .infinity, now - 60_000)

        // A re-ranks at an instant that is still in B's past. Under raw-mtime LWW B would ignore it.
        a.feed.commit(snapshot(["a9", "a8"], at: second))
        await a.sync.syncNow()
        await b.sync.syncNow()

        XCTAssertEqual(b.feed.snapshot.zoneIds, ["a9", "a8"],
                       "the more recently REFRESHED ranking wins, whenever the pull happened")
        XCTAssertEqual(b.feed.snapshot.refreshedAtMs, second)
    }

    /// A snapshot is replaced, never merged — but only ever by a FRESHER one. `restoreForOnboarding`
    /// applies every cloud document unconditionally, so the guard has to live in the store too, and
    /// an undecodable payload has to leave the grid alone rather than blank it.
    func testAStalerOrCorruptPayloadLeavesTheLocalRankingAlone() throws {
        let dir = root.appendingPathComponent("solo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ForYouFeedStore(fileURL: dir.appendingPathComponent("feed.json"))
        let now = Date().timeIntervalSince1970 * 1000
        store.commit(snapshot(["mine1", "mine2"], at: now - 60_000))

        let stale = try JSONEncoder().encode(snapshot(["theirs"], at: now - 600_000))
        store.applyPulledPayload(stale)
        XCTAssertEqual(store.snapshot.zoneIds, ["mine1", "mine2"], "a stale ranking must not land")
        XCTAssertEqual(mtimeMs(store.syncFileURL) ?? 0, now - 60_000, accuracy: 1_000,
                       "…and the file must still describe OUR refresh, or the watermark lies")

        store.applyPulledPayload(Data("{ not json".utf8))
        XCTAssertEqual(store.snapshot.zoneIds, ["mine1", "mine2"])
        XCTAssertFalse(store.reloadFromDisk(),
                       "nothing fresher on disk ⇒ no reload, no revision churn")
    }

    /// A cold install has `refreshedAtMs == 0`, which stamps epoch 0 — so it can PULL a real
    /// ranking but can never overwrite one with its empty snapshot. And a pull must not ping-pong:
    /// the reload does not re-save, so the next pass has nothing to publish.
    func testAnEmptyFeedNeverOverwritesARealOneAndAPullDoesNotPingPong() async throws {
        let db = MemoryCloudDB()
        let a = try makeDevice("A", db: db)
        let b = try makeDevice("B", db: db)
        let now = Date().timeIntervalSince1970 * 1000

        b.feed.commit(ForYouFeedSnapshot())              // never refreshed, but the file exists
        XCTAssertEqual(mtimeMs(b.feedURL) ?? -1, 0, accuracy: 1_000)
        a.feed.commit(snapshot(["a1", "a2"], at: now - 120_000))

        await a.sync.syncNow()
        await b.sync.syncNow()
        XCTAssertEqual(b.feed.snapshot.zoneIds, ["a1", "a2"])

        let saves = await db.saveCount
        await b.sync.syncNow()
        await a.sync.syncNow()
        let after = await db.saveCount
        XCTAssertEqual(after, saves, "a settled pair must transfer nothing further")
        XCTAssertEqual(a.feed.snapshot.zoneIds, ["a1", "a2"], "and A must not have been clobbered")
    }

    /// The deletion registry has to stay in lockstep with the sync registry, or a document's cloud
    /// copy outlives the account. `rec-feedback` was registered and never listed — every 👍/👎 the
    /// user ever gave survived deletion in his private database.
    func testBothRecommendationDocumentsAreErasedOnAccountDeletion() {
        XCTAssertTrue(AccountDeletionService.cloudDocKeys.contains("rec-feedback"))
        XCTAssertTrue(AccountDeletionService.cloudDocKeys.contains("foryou-feed"))
    }
}
