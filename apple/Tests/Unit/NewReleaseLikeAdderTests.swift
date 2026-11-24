import XCTest
@testable import PocketDJ

/// The like-adder's state machine, driven with a counting fake port — no MusicKit, no network.
@MainActor
final class NewReleaseLikeAdderTests: XCTestCase {

    private let day = 86_400_000.0
    private let hour = 3_600_000.0

    @MainActor private final class FakePort: ReleaseAddPort {
        var addCalls: [String] = []
        var writeCalls: [String] = []
        var nextReport = ReleaseAddReport(write: .confirmed, recorded: true, error: nil)
        var offline = false
        var running = 0
        var maxConcurrent = 0
        var hold: Bool = false
        var isOffline: Bool { offline }
        func add(_ r: LikedRelease) async -> ReleaseAddReport {
            addCalls.append(r.storeId)
            running += 1; maxConcurrent = max(maxConcurrent, running)
            await Task.yield()
            running -= 1
            return nextReport
        }
        func retryWrite(_ r: LikedRelease) async -> ReleaseAddReport {
            writeCalls.append(r.storeId); return nextReport
        }
    }

    private var clockMs = 1_800_000_000_000.0

    private func make(port given: FakePort? = nil) -> (NewReleaseLikeAdder, FakePort, LikedReleasesStore) {
        let port = given ?? FakePort()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-adder-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = LikedReleasesStore(fileURL: url)
        let adder = NewReleaseLikeAdder(store: store, port: port, clock: { [unowned self] in self.clockMs })
        return (adder, port, store)
    }

    private func entry(_ id: String, at: Double? = nil) -> ArtistReleaseEntry {
        ArtistReleaseEntry(artistId: Int(id) ?? 1, artistName: "A", checkedAtMs: 0, releaseId: id,
                           releaseName: "T\(id)", releaseAtMs: at ?? (clockMs - 2 * day),
                           releaseKind: "album", trackCount: 8)
    }

    private func fail(_ msg: String = "boom") -> ReleaseAddReport {
        ReleaseAddReport(write: .confirmed, recorded: false, error: msg)
    }

    // MARK: one add per 👍

    func testLikeAddsExactlyOnceAndMarksAdded() async {
        let (adder, port, store) = make()
        await adder.liked(entry("1"))?.value
        XCTAssertEqual(port.addCalls, ["1"])
        XCTAssertEqual(store.releases["1"]?.attempt?.state, .added)
        XCTAssertTrue(adder.inFlight.isEmpty)
        XCTAssertTrue(adder.queued.isEmpty)
    }

    func testDoubleTapWhileInFlightAddsOnce() async {
        let (adder, port, _) = make()
        let t1 = adder.liked(entry("1"))
        let t2 = adder.liked(entry("1"))
        await t1?.value; await t2?.value
        XCTAssertEqual(port.addCalls, ["1"])
    }

    func testRelartistEntryIsANoOp() {
        let (adder, port, store) = make()
        let e = ArtistReleaseEntry(artistId: 5, artistName: "A", checkedAtMs: 0)
        XCTAssertNil(adder.liked(e))
        XCTAssertTrue(port.addCalls.isEmpty)
        XCTAssertTrue(store.releases.isEmpty)
    }

    func testUnlikeBeforeTheQueuedAddStartsCancelsIt() async {
        let (adder, port, _) = make()
        let t = adder.liked(entry("1"))
        adder.unliked(storeId: "1")
        await t?.value
        XCTAssertTrue(port.addCalls.isEmpty, "an undone like must not add")
        XCTAssertTrue(port.writeCalls.isEmpty, "and nothing else is called — no library removal exists")
    }

    func testVerdictGoneBeforeTheAddStartsCancelsIt() async {
        let (adder, port, _) = make()
        adder.acceptedProvider = { [:] }
        await adder.liked(entry("1"))?.value
        XCTAssertTrue(port.addCalls.isEmpty)
    }

    func testAlreadyOwnedLikeDoesNotAdd() async {
        let (adder, port, _) = make()
        adder.isOwned = { _ in true }
        XCTAssertNil(adder.liked(entry("1")))
        XCTAssertTrue(port.addCalls.isEmpty)
    }

    // MARK: failure keeps everything

    func testFailureKeepsTheReleaseWithTheHonestMessage() async {
        let port = FakePort(); port.nextReport = fail("Couldn’t read the album’s tracks — try again.")
        let (adder, _, store) = make(port: port)
        await adder.liked(entry("1"))?.value
        let a = store.releases["1"]?.attempt
        XCTAssertEqual(a?.state, .failed)
        XCTAssertEqual(a?.message, "Couldn’t read the album’s tracks — try again.")
        XCTAssertEqual(a?.recorded, false)
    }

    func testRecordedButWriteFailedIsFailedWithLibraryNoticeAndWritesOnRetry() async {
        let port = FakePort()
        port.nextReport = ReleaseAddReport(write: .failed(reason: "nope"), recorded: true,
                                           error: RipsStore.libraryWriteNotice(.failed(reason: "nope"), noun: "album"))
        let (adder, _, store) = make(port: port)
        await adder.liked(entry("1"))?.value
        XCTAssertEqual(store.releases["1"]?.attempt?.state, .failed)
        XCTAssertTrue(store.releases["1"]?.attempt?.message?.contains("Apple Music library add failed") == true)
        // Retry on a recorded row re-runs only the write.
        port.nextReport = ReleaseAddReport(write: .confirmedWeb, recorded: true, error: nil)
        await adder.retry(storeId: "1", writeOnly: true)
        XCTAssertEqual(port.writeCalls, ["1"])
        XCTAssertEqual(port.addCalls, ["1"], "no second full add")
        XCTAssertEqual(store.releases["1"]?.attempt?.state, .added)
        XCTAssertTrue(store.releases["1"]?.attempt?.writeProven == true)
    }

    // MARK: sweep

    func testOfflineSweepRetriesOnceAndRespectsTheSixHourThrottle() async {
        let port = FakePort(); port.nextReport = fail(); port.offline = true
        let (adder, _, store) = make(port: port)
        await adder.liked(entry("1"))?.value
        XCTAssertEqual(store.releases["1"]?.attempt?.state, .offline)
        XCTAssertEqual(port.addCalls.count, 1)

        // Inside the window: nothing.
        clockMs += 5 * hour
        let swept1 = await adder.sweep()
        XCTAssertEqual(swept1, 0)
        XCTAssertEqual(port.addCalls.count, 1)

        // Past it, and now online: one retry, which lands.
        clockMs += 2 * hour
        port.offline = false
        port.nextReport = ReleaseAddReport(write: .confirmed, recorded: true, error: nil)
        let swept2 = await adder.sweep()
        XCTAssertEqual(swept2, 1)
        XCTAssertEqual(port.addCalls.count, 2)
        XCTAssertEqual(store.releases["1"]?.attempt?.state, .added)

        // Settled items are never touched again.
        clockMs += 10 * hour
        let swept3 = await adder.sweep()
        XCTAssertEqual(swept3, 0)
    }

    func testSweepNeverRetriesFailedItems() async {
        let port = FakePort(); port.nextReport = fail()
        let (adder, _, store) = make(port: port)
        await adder.liked(entry("1"))?.value
        XCTAssertEqual(store.releases["1"]?.attempt?.state, .failed)
        clockMs += 48 * hour
        let swept4 = await adder.sweep()
        XCTAssertEqual(swept4, 0)
        XCTAssertEqual(port.addCalls.count, 1)
    }

    func testSweepSkipsAnItemHeNoLongerLikes() async {
        let port = FakePort(); port.nextReport = fail(); port.offline = true
        let (adder, _, _) = make(port: port)
        await adder.liked(entry("1"))?.value
        adder.acceptedProvider = { [:] }
        clockMs += 8 * hour
        let swept5 = await adder.sweep()
        XCTAssertEqual(swept5, 0)
    }

    func testPreOrderIsAwaitingThenAddedOnReleaseDay() async {
        let port = FakePort()
        port.nextReport = ReleaseAddReport(write: .confirmedWeb, recorded: false, error: nil)
        let (adder, _, store) = make(port: port)
        let release = clockMs + 3 * day
        await adder.liked(entry("1", at: release))?.value
        XCTAssertEqual(store.releases["1"]?.attempt?.state, .awaitingRelease)
        XCTAssertTrue(store.releases["1"]?.attempt?.writeProven == true)

        // Before release day: nothing, however long since the attempt.
        clockMs += 2 * day
        let swept6 = await adder.sweep()
        XCTAssertEqual(swept6, 0)
        XCTAssertEqual(port.addCalls.count, 1)

        // Release day: the sweep re-runs the add, which now records.
        clockMs += 1.5 * day
        port.nextReport = ReleaseAddReport(write: .confirmedWeb, recorded: true, error: nil)
        let swept7 = await adder.sweep()
        XCTAssertEqual(swept7, 1)
        XCTAssertEqual(port.addCalls.count, 2)
        XCTAssertEqual(store.releases["1"]?.attempt?.state, .added)
    }

    func testSweepPrunesRowsWhoseVerdictIsGone() async {
        let (adder, _, store) = make()
        store.upsert([LikedRelease(storeId: "1"), LikedRelease(storeId: "2")])
        adder.acceptedProvider = { ["rel:2": 1] }
        await adder.sweep()
        XCTAssertEqual(Set(store.releases.keys), ["2"])
    }

    // MARK: Add all

    func testAddAllRunsOneAtATimeAndSkipsOwnedAndInFlight() async {
        let (adder, port, store) = make()
        store.upsert([LikedRelease(storeId: "1"), LikedRelease(storeId: "2"),
                      LikedRelease(storeId: "3"), LikedRelease(storeId: "4")])
        adder.isOwned = { $0.storeId == "3" }
        await adder.addAll(["1", "2", "3", "4"])
        XCTAssertEqual(port.addCalls, ["1", "2", "4"])
        XCTAssertEqual(port.maxConcurrent, 1, "never re-entered")
        XCTAssertFalse(adder.isAddingAll)
        XCTAssertTrue(adder.queued.isEmpty)
    }

    func testAddAllSkipsRowsUnlikedWhileWaiting() async {
        let (adder, port, store) = make()
        store.upsert([LikedRelease(storeId: "1"), LikedRelease(storeId: "2")])
        adder.acceptedProvider = { ["rel:1": 1] }
        await adder.addAll(["1", "2"])
        XCTAssertEqual(port.addCalls, ["1"])
    }

    // MARK: persistence

    func testInterruptedAddingBecomesOfflineAfterReload() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-adder-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let a = LikedReleasesStore(fileURL: url)
        a.upsert(LikedRelease(storeId: "1"))
        a.setAttempt(LikeAddAttempt(atMs: 1, state: .adding, message: nil, writeToken: nil, recorded: nil), for: "1")
        a.flush()
        let b = LikedReleasesStore(fileURL: url)
        XCTAssertEqual(b.releases["1"]?.attempt?.state, .offline)
        XCTAssertEqual(b.releases["1"]?.attempt?.message, NewReleaseLikeAdder.offlineMessage)
    }

    // MARK: hydration

    private struct StubTransport: ReleaseFeedTransport {
        var canSync = true
        var body: String
        func fetch(_ request: URLRequest) async throws -> Data { Data(body.utf8) }
    }

    func testHydrateMissingFetchesOnlyUnknownIdsAndTombstonesTheRest() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-adder-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = LikedReleasesStore(fileURL: url)
        store.upsert(LikedRelease(storeId: "1"))
        let t = StubTransport(body: #"{"data":[{"id":"2","attributes":{"name":"Two","artistName":"B"}}]}"#)
        let adder = NewReleaseLikeAdder(store: store, port: FakePort(), transport: t, clock: { 5 })
        let n = await adder.hydrateMissing(accepted: ["rel:1": 1, "rel:2": 2, "rel:3": 3, "relartist:9": 4])
        XCTAssertEqual(n, 2)
        XCTAssertEqual(store.releases["2"]?.title, "Two")
        XCTAssertEqual(store.releases["2"]?.likedAtMs, 2)
        XCTAssertEqual(store.releases["3"]?.tombstoned, true)
        XCTAssertNil(store.releases["9"])
    }

    func testHydrateIsInertWithoutAuthorizedTransport() async {
        let (adder, _, store) = make()
        let n = await adder.hydrateMissing(accepted: ["rel:5": 1])
        XCTAssertEqual(n, 0)
        XCTAssertTrue(store.releases.isEmpty)
    }

    // MARK: the outcome table (pure)

    func testOutcomeTableEveryRow() {
        let now = 1_000.0
        let past = 500.0, future = 5_000.0
        func s(_ r: ReleaseAddReport, at: Double? = past, offline: Bool = false, canWrite: Bool = true)
            -> NewReleaseLikeAdder.Outcome {
            NewReleaseLikeAdder.state(for: r, releaseAtMs: at, nowMs: now, offline: offline, canWrite: canWrite)
        }
        // recorded + proven
        XCTAssertEqual(s(.init(write: .confirmed, recorded: true, error: nil)).state, .added)
        XCTAssertEqual(s(.init(write: .confirmedWeb, recorded: true, error: nil)).state, .added)
        // recorded + macOS skip
        XCTAssertEqual(s(.init(write: .skipped(reason: "mac"), recorded: true, error: nil), canWrite: false).state, .added)
        // recorded + unproven (failed / unconfirmed / skipped-but-could-write)
        for w in [AppleMusicLibraryWriteOutcome.failed(reason: "x"), .unconfirmed, .skipped(reason: "auth")] {
            let o = s(.init(write: w, recorded: true, error: "notice"))
            XCTAssertEqual(o.state, .failed); XCTAssertEqual(o.message, "notice")
        }
        // nothing recorded: pre-order (write landed or not)
        XCTAssertEqual(s(.init(write: .confirmed, recorded: false, error: nil), at: future).state, .awaitingRelease)
        XCTAssertEqual(s(.init(write: .failed(reason: "x"), recorded: false, error: "e"), at: future).state, .awaitingRelease)
        // nothing recorded: offline
        let off = s(.init(write: .skipped(reason: "n"), recorded: false, error: "e"), offline: true)
        XCTAssertEqual(off.state, .offline); XCTAssertEqual(off.message, NewReleaseLikeAdder.offlineMessage)
        // nothing recorded: real failure
        let bad = s(.init(write: .confirmed, recorded: false, error: "Couldn’t read the album’s tracks — try again."))
        XCTAssertEqual(bad.state, .failed); XCTAssertEqual(bad.message, "Couldn’t read the album’s tracks — try again.")
        // an unknown release date is not a pre-order
        XCTAssertEqual(s(.init(write: .confirmed, recorded: false, error: nil), at: nil).state, .failed)
    }
}
