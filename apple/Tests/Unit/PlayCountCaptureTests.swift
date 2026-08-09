import XCTest
@testable import PocketDJ

/// THE CHECKPOINTED CAPTURE — the rebuild of a walk that used to throw away 100% of its work on
/// any interruption.
///
/// The owner's report: "when i navigate away from settings or close the app it resets to zero
/// songs with playcounts and browser still only shows on device play counts". His library is
/// ~96,000 songs, so the walk is minutes; the old design collected all of it in memory and applied
/// it ONCE at the end, so navigating away, backgrounding, a kill, a throw or a cancel discarded
/// everything and left the baseline empty.
///
/// Every test here defends one property of the fix, and each of them is a specific bug:
///   • interrupt after N batches ⇒ the store holds exactly those N batches (not zero);
///   • resume ⇒ continues at the cursor and lands on the SAME state as an uninterrupted run,
///     byte for byte — which is also the proof that resume does not double-count;
///   • an all-zero / nil walk is still REJECTED and stamps no progress (a mark would make a broken
///     read permanent);
///   • cancellation mid-walk leaves a whole, decodable document, never a half-written one;
///   • the audit says interrupted vs completed, and WHY.
///
/// All of it runs against a FAKE pager. No MusicKit, no network, no signed-in library — which is
/// the only way any of this is testable at all.
@MainActor
final class PlayCountCaptureTests: XCTestCase {

    private typealias Row = AppleMusicPlayCountCapture.LibraryRow
    private typealias Run = AppleMusicPlayCountCapture.Run

    // MARK: - Fake library

    /// A scripted library the test can interrupt at an exact page.
    ///
    /// `failAfterPages` makes `page` throw once it has served that many pages — standing in for
    /// the app being killed, MusicKit erroring, or the task being cancelled. `served` records the
    /// offsets it was asked for, which is how "resume continued from the cursor" is proved rather
    /// than assumed.
    private actor FakePager: AppleMusicPlayCountCapture.LibraryPager {
        private let rows: [Row]
        private let failAfterPages: Int?
        private let delayNanos: UInt64
        private var pagesServed = 0
        private(set) var offsetsRequested: [Int] = []

        /// `delayNanos` paces the walk so a test can cancel it while it is genuinely mid-flight
        /// instead of racing a fake library that empties in microseconds. `try?` on the sleep is
        /// deliberate: a cancelled sleep must return, not throw, so the walk observes the
        /// cancellation at its own PAGE BOUNDARY — which is the property under test.
        init(rows: [Row], failAfterPages: Int? = nil, delayNanos: UInt64 = 0) {
            self.rows = rows
            self.failAfterPages = failAfterPages
            self.delayNanos = delayNanos
        }

        struct Interrupted: Error {}

        func page(offset: Int, limit: Int) async throws -> [Row] {
            if let failAfterPages, pagesServed >= failAfterPages { throw Interrupted() }
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            pagesServed += 1
            offsetsRequested.append(offset)
            guard offset < rows.count else { return [] }
            return Array(rows[offset..<min(offset + limit, rows.count)])
        }

        func requested() -> [Int] { offsetsRequested }
    }

    /// Wait (bounded) for a condition on the main actor. Timing-based tests that `sleep` a fixed
    /// interval fail under load for reasons that have nothing to do with the code under test.
    private func wait(upTo seconds: Double = 5, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    /// `n` rows, newest-played first, every one of them resolvable and played `i + 1` times.
    /// Row ids and catalog ids are distinct so the resolver exercises the catalog-id path.
    private nonisolated func library(_ n: Int, playsFrom: Int = 1) -> [Row] {
        (0..<n).map { i in
            Row(rowId: "i.row\(i)", catalogId: "cat\(i)", title: "Song \(i)", artist: "Artist",
                playCount: playsFrom + i, lastPlayedMs: Double(2_000_000_000_000 - i * 1_000))
        }
    }

    /// Catalog id → songId for the library above.
    private nonisolated func resolver(_ n: Int) -> AppleMusicPlayCountCapture.Resolver {
        let byCatalogId = Dictionary(uniqueKeysWithValues: (0..<n).map { ("cat\($0)", "s\($0)") })
        return AppleMusicPlayCountCapture.resolver(byCatalogId: byCatalogId)
    }

    private func makeBaseline() -> (store: AMPlayBaselineStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-capture-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: AMPlayBaselineStore.provisionalURL(for: url))
        }
        return (AMPlayBaselineStore(fileURL: url), url)
    }

    private struct ServiceRig {
        var service: PlayCountService
        var baseline: AMPlayBaselineStore
        var baselineURL: URL
        var runURL: URL
        var auditURL: URL
    }

    private func makeService() -> ServiceRig {
        let (baseline, baselineURL) = makeBaseline()
        let stamp = UUID().uuidString
        let runURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-capture-run-\(stamp).json")
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-capture-audit-\(stamp).json")
        let statsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-capture-stats-\(stamp).json")
        addTeardownBlock {
            for u in [runURL, auditURL, statsURL] { try? FileManager.default.removeItem(at: u) }
        }
        let svc = PlayCountService(baseline: baseline, stats: PlayStatsStore(fileURL: statsURL),
                                   runURL: runURL, auditURL: auditURL)
        svc.captureAvailable = { true }
        svc.pageLimit = 10
        svc.checkpointRows = 20
        return ServiceRig(service: svc, baseline: baseline, baselineURL: baselineURL,
                          runURL: runURL, auditURL: auditURL)
    }

    /// One catalog row per fake library row, so `startCapture`'s non-empty-catalog gate passes.
    /// The resolver the service builds from these is irrelevant — the tests inject their own via
    /// the pager's catalog ids matching `IndexSong.appleMusicId`.
    private nonisolated func catalog(_ n: Int) -> [IndexSong] {
        (0..<n).map { i in
            IndexSong.minimal(id: "s\(i)", name: "Song \(i)", artist: "Artist", appleMusicId: "cat\(i)")
        }
    }

    // MARK: - 1. Interrupt after N batches ⇒ the store holds exactly those N batches

    /// THE reported bug. The old walk applied once, at 100%, so an interruption at 60% stored
    /// NOTHING. Now every checkpoint is durable: interrupt after two of them and the store holds
    /// exactly those rows — and the document on disk is a whole, decodable snapshot.
    func testInterruptAfterTwoCheckpointsStoresExactlyThoseBatches() async throws {
        let (store, url) = makeBaseline()
        let rows = library(100)
        // 10 rows per page, checkpoint every 2 pages, pager dies after 4 pages ⇒ 2 checkpoints
        // ⇒ rows 0..<40 folded, and rows 40+ never read.
        let pager = FakePager(rows: rows, failAfterPages: 4)

        var checkpoints: [Run] = []
        do {
            _ = try await AppleMusicPlayCountCapture.walk(
                pager: pager, run: .starting(since: nil, trigger: "test", nowMs: 1_000),
                // `maxCheckpointRows` pinned to `checkpointRows`: the interval is ADAPTIVE in
                // production (it grows with the accumulator so write volume stays linear in
                // library size — see `checkpointInterval`), and this test asserts exact
                // checkpoint cursors, which is a statement about durability, not about the
                // growth policy.
                resolve: resolver(100), pageLimit: 10, checkpointRows: 20, maxCheckpointRows: 20,
                checkpoint: { snap in
                    await MainActor.run {
                        checkpoints.append(snap)
                        store.mergePartial(snap.counts)
                    }
                })
            XCTFail("the fake pager was supposed to interrupt the walk")
        } catch is FakePager.Interrupted {
            // expected
        }

        // Two full checkpoints, plus the one the walk lands on its way out (which carries no new
        // rows, because the failure happened before a page was served).
        XCTAssertEqual(checkpoints.map(\.cursor), [20, 40, 40])
        XCTAssertEqual(checkpoints.last?.completed, false)
        XCTAssertEqual(checkpoints.last?.scanned, 40)

        XCTAssertEqual(store.songCount, 40, "exactly the 4 pages that were served")
        XCTAssertEqual(store.count("s0"), 1)
        XCTAssertEqual(store.count("s39"), 40)
        XCTAssertEqual(store.count("s40"), 0, "never read, so never stored")

        await store.flushPendingWrites()
        let doc = try JSONDecoder().decode(AMPlayBaselineStore.Document.self,
                                           from: try Data(contentsOf: url))
        XCTAssertEqual(doc.counts.count, 40, "the document on disk is a whole, valid partial")
        XCTAssertNil(doc.lastPlayedHighWaterMs,
                     "a partial must never stamp a mark — that is how a bad read becomes permanent")
    }

    // MARK: - 2. Resume continues from the cursor and matches an uninterrupted run

    /// Resume must CONTINUE, not restart, and must land on exactly what one clean run would have.
    /// The offsets the pager was asked for are the proof it continued.
    func testResumeContinuesFromCursorAndMatchesAnUninterruptedRun() async throws {
        let rows = library(100)

        // --- reference: one uninterrupted run -------------------------------------------------
        let clean = try await AppleMusicPlayCountCapture.walk(
            pager: FakePager(rows: rows), run: .starting(since: nil, trigger: "test", nowMs: 1_000),
            resolve: resolver(100), pageLimit: 10, checkpointRows: 20, checkpoint: { _ in })

        // --- interrupted, then resumed --------------------------------------------------------
        var banked: Run?
        let first = FakePager(rows: rows, failAfterPages: 4)
        do {
            _ = try await AppleMusicPlayCountCapture.walk(
                pager: first, run: .starting(since: nil, trigger: "test", nowMs: 1_000),
                resolve: resolver(100), pageLimit: 10, checkpointRows: 20,
                checkpoint: { snap in banked = snap })
        } catch {}
        let resumeFrom = try XCTUnwrap(banked)
        XCTAssertTrue(resumeFrom.isResumable)
        XCTAssertEqual(resumeFrom.cursor, 40)

        let second = FakePager(rows: rows)
        let resumed = try await AppleMusicPlayCountCapture.walk(
            pager: second, run: resumeFrom, resolve: resolver(100),
            pageLimit: 10, checkpointRows: 20, checkpoint: { _ in })

        let asked = await second.requested()
        XCTAssertEqual(asked.first, 40, "the resumed walk started AT the cursor, not at 0")

        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(resumed.scanned, clean.scanned)
        XCTAssertEqual(resumed.counts, clean.counts,
                       "a resumed run is indistinguishable from one that was never interrupted")
        XCTAssertEqual(resumed.maxLastPlayedMs, clean.maxLastPlayedMs)
    }

    /// SET, NEVER ADD — stated as a comment in `walk` and `mergePartial`, proved here. Two full
    /// runs through the SAME service must leave the store byte-identical: if the checkpointed
    /// design had turned the baseline into an accumulator, every refresh would inflate the owner's
    /// counts permanently with no way back to the true numbers.
    func testRunningTheCaptureTwiceIsByteIdentical() async throws {
        let rig = makeService()
        let rows = library(100)
        rig.service.pagerFactory = { FakePager(rows: rows) }

        XCTAssertTrue(rig.service.startCapture(songs: catalog(100), trigger: "manual"))
        await rig.service.awaitCapture()
        let first = try JSONDecoder().decode(AMPlayBaselineStore.Document.self,
                                             from: try Data(contentsOf: rig.baselineURL))
        XCTAssertEqual(rig.baseline.songCount, 100)
        XCTAssertEqual(rig.baseline.totalPlays, (1...100).reduce(0, +))

        // A second full read of the same library. `resetHighWater` is what the "Re-read
        // everything" button does; without it the second run would be incremental and stop at once.
        XCTAssertTrue(rig.service.recaptureEverything(songs: catalog(100)))
        await rig.service.awaitCapture()
        let second = try JSONDecoder().decode(AMPlayBaselineStore.Document.self,
                                              from: try Data(contentsOf: rig.baselineURL))

        // Byte-identical on everything the capture DERIVES. `capturedAtMs` is deliberately
        // excluded and only there: it is the wall clock the run started at, and it is what
        // provisional stamps are retired against, so it MUST move. Everything a re-run could
        // inflate is compared as encoded bytes, key order and all.
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        XCTAssertEqual(try enc.encode(first.counts), try enc.encode(second.counts),
                       "re-running the same capture must not change a single count")
        XCTAssertEqual(first.lastPlayedHighWaterMs, second.lastPlayedHighWaterMs)
        XCTAssertEqual(first.source, second.source)
        XCTAssertEqual(first.sourceName, second.sourceName)
        XCTAssertGreaterThanOrEqual(second.capturedAtMs, first.capturedAtMs)
        XCTAssertEqual(rig.baseline.totalPlays, (1...100).reduce(0, +), "counts were SET, not added")
    }

    /// The same proof one level down, where the double-count actually lurks: Apple holds SEVERAL
    /// library rows for one catalog song and their counters SUM within a walk. That sum is only
    /// safe because every row is folded exactly once — so a resume across the duplicate pair must
    /// still total 5, not 8.
    func testDuplicateLibraryRowsSumOnceAcrossAResume() async throws {
        // Two library rows for the SAME song, deliberately straddling the checkpoint boundary.
        var rows: [Row] = []
        rows.append(Row(rowId: "i.a", catalogId: "dup", title: "Dup", artist: "A",
                        playCount: 3, lastPlayedMs: 9_000))
        rows += (1..<19).map { i in
            Row(rowId: "i.f\(i)", catalogId: "cat\(i)", title: "S\(i)", artist: "A",
                playCount: 1, lastPlayedMs: Double(9_000 - i))
        }
        rows.append(Row(rowId: "i.b", catalogId: "dup", title: "Dup", artist: "A",
                        playCount: 2, lastPlayedMs: 5_000))

        var byCatalogId = ["dup": "dup-song"]
        for i in 1..<19 { byCatalogId["cat\(i)"] = "s\(i)" }
        let resolve = AppleMusicPlayCountCapture.resolver(byCatalogId: byCatalogId)

        var banked: Run?
        do {
            _ = try await AppleMusicPlayCountCapture.walk(
                pager: FakePager(rows: rows, failAfterPages: 1),
                run: .starting(since: nil, trigger: "test", nowMs: 1),
                resolve: resolve, pageLimit: 10, checkpointRows: 10,
                checkpoint: { snap in banked = snap })
        } catch {}
        XCTAssertEqual(banked?.counts["dup-song"]?.n, 3, "only the first row has been folded")

        let resumed = try await AppleMusicPlayCountCapture.walk(
            pager: FakePager(rows: rows), run: try XCTUnwrap(banked), resolve: resolve,
            pageLimit: 10, checkpointRows: 10, checkpoint: { _ in })
        XCTAssertEqual(resumed.counts["dup-song"]?.n, 5,
                       "3 + 2, summed exactly once — not 8, which is what re-folding page 1 costs")
    }

    /// The sort-drift guard. `lastPlayedDate` descending is not stable: play a song mid-walk and it
    /// jumps to row 0, shifting every later row by one, so an offset resume re-reads the row that
    /// sat just before the cursor. Without the guard its plays are added a second time.
    func testResumeIgnoresARowItAlreadyFoldedWhenTheSortDrifts() async throws {
        let original = library(30)
        var banked: Run?
        do {
            _ = try await AppleMusicPlayCountCapture.walk(
                pager: FakePager(rows: original, failAfterPages: 1),
                run: .starting(since: nil, trigger: "test", nowMs: 1),
                resolve: resolver(30), pageLimit: 10, checkpointRows: 10,
                checkpoint: { snap in banked = snap })
        } catch {}
        let resumeFrom = try XCTUnwrap(banked)
        XCTAssertEqual(resumeFrom.cursor, 10)
        XCTAssertEqual(resumeFrom.counts["s9"]?.n, 10)

        // Song 25 gets played DURING the walk: it jumps to the front and shifts everything by one,
        // so offset 10 now serves the row that used to be at 9 — a row already folded.
        var drifted = original
        let promoted = drifted.remove(at: 25)
        drifted.insert(Row(rowId: promoted.rowId, catalogId: promoted.catalogId,
                           title: promoted.title, artist: promoted.artist,
                           playCount: (promoted.playCount ?? 0) + 1,
                           lastPlayedMs: 2_100_000_000_000), at: 0)

        let resumed = try await AppleMusicPlayCountCapture.walk(
            pager: FakePager(rows: drifted), run: resumeFrom, resolve: resolver(30),
            pageLimit: 10, checkpointRows: 10, checkpoint: { _ in })

        XCTAssertEqual(resumed.counts["s9"]?.n, 10,
                       "the re-served row must be skipped, not folded a second time (20 = the bug)")
        XCTAssertEqual(resumed.scanned, 29, "one row genuinely moved out of reach; nothing doubled")
    }

    // MARK: - 3. An all-zero / nil walk is REJECTED and stamps no progress

    /// The open iOS defect (forum 739587) reads as "every song has zero plays". A walk that LISTED
    /// rows and read nil for every count is BROKEN, not empty: adopting it would stamp a
    /// high-water mark, make every later walk incremental, and the install could never re-read the
    /// library it failed to read.
    func testAllNilWalkIsRejectedAndStampsNoHighWaterMark() async throws {
        let rig = makeService()
        // Seed a good baseline so the guard has something to protect.
        rig.baseline.replaceAll(counts: (0..<200).reduce(into: [:]) { $0["s\($1)"] = .init(n: 7, lastMs: 1_000) },
                                capturedAtMs: 500, source: "library-xml")
        XCTAssertEqual(rig.baseline.songCount, 200)

        // Rows exist, and they have last-played dates — but every play count reads nil.
        let broken = (0..<50).map { i in
            Row(rowId: "i.\(i)", catalogId: "cat\(i)", title: "S\(i)", artist: "A",
                playCount: nil, lastPlayedMs: Double(9_000_000 - i))
        }
        rig.service.pagerFactory = { FakePager(rows: broken) }
        XCTAssertTrue(rig.service.startCapture(songs: catalog(50), trigger: "manual"))
        await rig.service.awaitCapture()

        XCTAssertEqual(rig.baseline.songCount, 200, "the good baseline is untouched")
        XCTAssertEqual(rig.baseline.totalPlays, 1_400)
        XCTAssertNil(rig.baseline.lastPlayedHighWaterMs,
                     "NO mark — a mark would make the broken read permanent")
        let audit = try XCTUnwrap(rig.service.lastCapture)
        XCTAssertTrue(audit.completed)
        XCTAssertEqual(audit.songsHeld, 0)
        XCTAssertTrue(audit.stopReason.contains("no play counts"), audit.stopReason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.runURL.path),
                       "the run document is dropped once it is judged")
    }

    /// `readNothing` is a WHOLE-WALK predicate and must never be evaluated per checkpoint: a
    /// descending walk's tail is all-nil by design, so a healthy walk's last chunk looks exactly
    /// like a broken read. Here the first pages carry plays and the tail does not — it must be
    /// adopted, mark and all.
    func testAHealthyWalkWhoseTailIsAllNilIsStillAdopted() async throws {
        let rig = makeService()
        var rows = library(20)
        rows += (20..<60).map { i in
            Row(rowId: "i.row\(i)", catalogId: "cat\(i)", title: "Song \(i)", artist: "Artist",
                playCount: nil, lastPlayedMs: nil)
        }
        rig.service.pagerFactory = { FakePager(rows: rows) }

        XCTAssertTrue(rig.service.startCapture(songs: catalog(60), trigger: "manual"))
        await rig.service.awaitCapture()

        XCTAssertEqual(rig.baseline.songCount, 20)
        XCTAssertEqual(rig.baseline.lastPlayedHighWaterMs, 2_000_000_000_000)
        XCTAssertEqual(rig.service.lastCapture?.completed, true)
    }

    // MARK: - 4. Cancellation leaves a whole, valid document

    /// Cancellation is checked only at a PAGE boundary, which is what makes "cancelled mid-batch"
    /// unrepresentable: the cursor is always page-aligned and every write is atomic. The run must
    /// come back decodable, resumable, and holding exactly the pages that completed.
    func testCancellationMidWalkLeavesADecodableResumableRun() async throws {
        let rig = makeService()
        let rows = library(4_000)
        // 400 pages at 1 ms apiece: long enough that the cancel below always lands mid-walk.
        rig.service.pagerFactory = { FakePager(rows: rows, delayNanos: 1_000_000) }
        rig.service.pageLimit = 10
        rig.service.checkpointRows = 10

        XCTAssertTrue(rig.service.startCapture(songs: catalog(4_000), trigger: "manual"))
        // Wait for real checkpoints rather than sleeping a fixed interval — then pull the rug.
        let banked = await wait { (rig.service.lastCapture?.checkpoints ?? 0) >= 2 }
        XCTAssertTrue(banked, "the walk should have banked checkpoints before the cancel")
        rig.service.cancelCapture()
        await rig.service.awaitCapture()

        XCTAssertFalse(rig.service.isCapturing)
        let data = try Data(contentsOf: rig.runURL)
        let run = try JSONDecoder().decode(Run.self, from: data)
        XCTAssertFalse(run.completed)
        XCTAssertTrue(run.isResumable)
        XCTAssertEqual(run.cursor % 10, 0, "the cursor is PAGE-ALIGNED — no half-read page exists")
        XCTAssertEqual(run.counts.count, run.cursor, "exactly the rows the completed pages carried")
        XCTAssertGreaterThan(run.cursor, 0, "it banked work before it was cut")
        XCTAssertLessThan(run.cursor, 4_000, "it really was cut short")

        // …and the baseline on disk is a whole valid partial, not a truncated file.
        await rig.baseline.flushPendingWrites()
        let doc = try JSONDecoder().decode(AMPlayBaselineStore.Document.self,
                                           from: try Data(contentsOf: rig.baselineURL))
        XCTAssertEqual(doc.counts.count, rig.baseline.songCount)
        XCTAssertNil(doc.lastPlayedHighWaterMs, "an unfinished run stamps nothing")

        // And it picks up where it stopped rather than starting over.
        let cursorAtCancel = run.cursor
        rig.service.pagerFactory = { FakePager(rows: rows) }
        rig.service.pageLimit = 500
        rig.service.checkpointRows = 1_000
        XCTAssertTrue(rig.service.startCapture(songs: catalog(4_000), trigger: "resume"))
        await rig.service.awaitCapture()
        XCTAssertEqual(rig.baseline.songCount, 4_000)
        XCTAssertEqual(rig.service.lastCapture?.scanned, 4_000)
        XCTAssertGreaterThan(cursorAtCancel, 0)
    }

    // MARK: - 5. The audit reports interrupted vs completed, and why

    func testAuditReportsInterruptedThenCompleted() async throws {
        let rig = makeService()
        let rows = library(60)
        rig.service.pagerFactory = { FakePager(rows: rows, failAfterPages: 3) }

        XCTAssertTrue(rig.service.startCapture(songs: catalog(60), trigger: "manual"))
        await rig.service.awaitCapture()

        let interrupted = try XCTUnwrap(rig.service.lastCapture)
        XCTAssertFalse(interrupted.completed)
        XCTAssertTrue(interrupted.isInterrupted)
        XCTAssertEqual(interrupted.cursor, 30)
        XCTAssertEqual(interrupted.scanned, 30)
        XCTAssertEqual(interrupted.songsHeld, 30)
        XCTAssertFalse(interrupted.stopReason.isEmpty, "it must say WHY it stopped")
        XCTAssertGreaterThan(interrupted.checkpoints, 0)

        // The audit survives a relaunch: a fresh service over the same files hydrates it.
        let reborn = PlayCountService(baseline: rig.baseline, stats: PlayStatsStore(fileURL:
                        FileManager.default.temporaryDirectory.appendingPathComponent("pdj-\(UUID().uuidString).json")),
                                      runURL: rig.runURL, auditURL: rig.auditURL)
        XCTAssertEqual(reborn.lastCapture?.cursor, 30)
        XCTAssertEqual(reborn.lastCapture?.isInterrupted, true)

        // Finish it. Same mechanism, same files.
        rig.service.pagerFactory = { FakePager(rows: rows) }
        XCTAssertTrue(rig.service.startCapture(songs: catalog(60), trigger: "resume"))
        await rig.service.awaitCapture()

        let done = try XCTUnwrap(rig.service.lastCapture)
        XCTAssertTrue(done.completed)
        XCTAssertFalse(done.isInterrupted)
        XCTAssertEqual(done.scanned, 60)
        XCTAssertEqual(rig.baseline.songCount, 60)
        XCTAssertTrue(done.stopReason.contains("60"), done.stopReason)
    }

    // MARK: - 6. The app-scoped in-flight guard

    /// The bug the view-local flag caused: re-entering Settings reset it, so a second full walk
    /// started over the top of the first. The guard is on the SERVICE now, so the second call is
    /// simply refused.
    func testASecondStartIsRefusedWhileOneIsInFlight() async throws {
        let rig = makeService()
        let rows = library(2_000)
        rig.service.pagerFactory = { FakePager(rows: rows) }
        rig.service.pageLimit = 5
        rig.service.checkpointRows = 5

        XCTAssertTrue(rig.service.startCapture(songs: catalog(2_000), trigger: "manual"))
        XCTAssertFalse(rig.service.startCapture(songs: catalog(2_000), trigger: "manual"),
                       "a re-entered pane must not be able to stack a second 96k-row walk")
        XCTAssertFalse(rig.service.autoCaptureIfNeverCaptured(songs: catalog(2_000)))
        rig.service.cancelCapture()
        await rig.service.awaitCapture()
    }

    /// An empty catalog resolves NOTHING: every row comes back unresolved, the walk ends with zero
    /// counts but a non-nil newest-played date, and committing that would stamp a high-water mark
    /// with nothing stored — wedging the install into incremental-only forever.
    func testCaptureRefusesToStartWithAnEmptyCatalog() {
        let rig = makeService()
        rig.service.pagerFactory = { FakePager(rows: self.library(10)) }
        XCTAssertFalse(rig.service.startCapture(songs: [], trigger: "manual"))
        XCTAssertFalse(rig.service.isCapturing)
        XCTAssertNil(rig.service.lastCapture)
    }

    /// The first-run trigger must not fire while the baseline is still decoding off-disk —
    /// `isEmpty` reads true for that whole window, which is how a spurious full walk gets started
    /// against a baseline that already exists.
    func testAutoCaptureWaitsForTheBaselineDiskLoad() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-capture-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let baseline = AMPlayBaselineStore(fileURL: url, loadNow: false)
        let svc = PlayCountService(baseline: baseline,
                                   stats: PlayStatsStore(fileURL: FileManager.default.temporaryDirectory
                                       .appendingPathComponent("pdj-\(UUID().uuidString).json")))
        svc.captureAvailable = { true }
        svc.pagerFactory = { FakePager(rows: self.library(10)) }

        XCTAssertFalse(baseline.hasLoaded)
        XCTAssertFalse(svc.autoCaptureIfNeverCaptured(songs: catalog(10)),
                       "not loaded yet ⇒ 'empty' is not an answer")

        await baseline.loadFromDiskAsync()
        XCTAssertTrue(baseline.hasLoaded)
        XCTAssertTrue(svc.autoCaptureIfNeverCaptured(songs: catalog(10)))
        await svc.awaitCapture()
        XCTAssertEqual(baseline.songCount, 10)
    }

    // MARK: - 7. mergePartial is monotone and never worse than before

    /// A checkpoint is a PREVIEW: it raises counts and never lowers them, so an interrupted walk
    /// can never leave Browse worse off than it was before the walk started. Lowering is a
    /// whole-snapshot decision and happens once, at commit.
    func testMergePartialOnlyEverRaisesAndIsIdempotent() throws {
        let (store, url) = makeBaseline()
        store.replaceAll(counts: ["a": .init(n: 50, lastMs: 100), "b": .init(n: 9, lastMs: 100)],
                         capturedAtMs: 1_000, source: "library-xml")

        XCTAssertEqual(store.mergePartial(["a": .init(n: 12, lastMs: 50),      // lower ⇒ ignored
                                           "b": .init(n: 30, lastMs: 900),     // higher ⇒ raised
                                           "c": .init(n: 4, lastMs: 900)]), 2) // new ⇒ added
        XCTAssertEqual(store.count("a"), 50, "a partial must never make Browse worse")
        XCTAssertEqual(store.count("b"), 30)
        XCTAssertEqual(store.count("c"), 4)
        XCTAssertEqual(store.lastPlayed("a"), 100)

        // Re-applying the same checkpoint changes nothing — the SET-not-ADD invariant.
        XCTAssertEqual(store.mergePartial(["a": .init(n: 12, lastMs: 50),
                                           "b": .init(n: 30, lastMs: 900),
                                           "c": .init(n: 4, lastMs: 900)]), 0)
        XCTAssertEqual(store.totalPlays, 84)

        // …and it leaves none of the whole-walk state behind.
        XCTAssertEqual(store.capturedAtMs, 1_000, "no capture stamp from a partial")
        XCTAssertNil(store.lastPlayedHighWaterMs, "no mark from a partial")
        XCTAssertEqual(store.source, "library-xml", "a partial does not re-label the source")
        _ = url
    }

    /// Provisional stamps are retired ONCE, at commit, over the union of what the run observed —
    /// never per checkpoint. A per-checkpoint retirement would delete plays that a later chunk
    /// would have absorbed, and the badge would silently go backwards.
    func testCheckpointsDoNotRetireProvisionalPlays() async throws {
        let rig = makeService()
        rig.baseline.noteApplePlay("s0", at: 10_000)
        rig.baseline.noteApplePlay("s55", at: 10_000)
        XCTAssertEqual(rig.baseline.provisionalCount("s0"), 1)

        let rows = library(60)
        rig.service.pagerFactory = { FakePager(rows: rows, failAfterPages: 2) }
        XCTAssertTrue(rig.service.startCapture(songs: catalog(60), trigger: "manual"))
        await rig.service.awaitCapture()

        XCTAssertEqual(rig.service.lastCapture?.isInterrupted, true)
        XCTAssertEqual(rig.baseline.provisionalCount("s0"), 1,
                       "an interrupted run retires nothing — the walk never finished")
        XCTAssertEqual(rig.baseline.provisionalCount("s55"), 1)

        // Finish the run: NOW the stamps retire, and only for songs the walk observed.
        rig.service.pagerFactory = { FakePager(rows: rows) }
        XCTAssertTrue(rig.service.startCapture(songs: catalog(60), trigger: "resume"))
        await rig.service.awaitCapture()
        XCTAssertEqual(rig.service.lastCapture?.completed, true)
        XCTAssertEqual(rig.baseline.provisionalCount("s0"), 0, "absorbed by the committed snapshot")
    }

    // MARK: - 8. Incremental walks still stop at the mark

    /// THE SERVICE's checkpoint path, asserted end to end. The interruption test above drives
    /// `store.mergePartial` from the TEST's own closure; this one proves `PlayCountService` itself
    /// puts a partial into the baseline, which is the exact thing the owner reported missing
    /// ("it resets to zero songs with playcounts").
    func testTheServiceItselfBanksPartialCountsIntoTheBaseline() async throws {
        let rig = makeService()
        let rows = library(60)
        rig.service.pagerFactory = { FakePager(rows: rows, failAfterPages: 3) }

        XCTAssertTrue(rig.service.startCapture(songs: catalog(60), trigger: "manual"))
        await rig.service.awaitCapture()

        // 3 pages of 10 were served, so rows 0..<30 are folded and banked — by the service, with
        // no help from the test.
        XCTAssertEqual(rig.baseline.songCount, 30, "an interrupted run leaves REAL counts behind")
        XCTAssertEqual(rig.baseline.count("s0"), 1)
        XCTAssertEqual(rig.baseline.count("s29"), 30)
        XCTAssertEqual(rig.baseline.count("s30"), 0, "never read, so never stored")
        XCTAssertEqual(rig.baseline.totalPlays, (1...30).reduce(0, +))
        // …and it is on DISK, not just in memory: this is what survives the app being killed.
        await rig.baseline.flushPendingWrites()
        let doc = try JSONDecoder().decode(AMPlayBaselineStore.Document.self,
                                           from: try Data(contentsOf: rig.baselineURL))
        XCTAssertEqual(doc.counts.count, 30)
        XCTAssertEqual(doc.counts["s29"]?.n, 30)
    }

    // MARK: - 9. The sort-drift guard survives UNBOUNDED drift

    /// The guard used to be a 1,000-id sliding window, and as a sliding window it failed OPEN: it
    /// evicted the oldest id per newly folded row, so the first duplicate past the cap evicted a
    /// still-needed id, which then also slipped through — the window collapsed from the front and
    /// the REST of the walk double-folded, committed as authoritative with no undo.
    ///
    /// Here 1,100 rows are played between an interruption at row 1,500 and the resume — more than
    /// the old cap. Every count must still be exactly what one clean run produces.
    func testResumeSurvivesDriftLargerThanTheBoundaryGuard() async throws {
        let total = 3_000
        let original = library(total)

        // Interrupt at row 1,500.
        var banked: Run?
        do {
            _ = try await AppleMusicPlayCountCapture.walk(
                pager: FakePager(rows: original, failAfterPages: 3),
                run: .starting(since: nil, trigger: "test", nowMs: 1),
                resolve: resolver(total), pageLimit: 500, checkpointRows: 500, maxCheckpointRows: 500,
                checkpoint: { snap in banked = snap })
        } catch {}
        let resumeFrom = try XCTUnwrap(banked)
        XCTAssertEqual(resumeFrom.cursor, 1_500)

        // 1,100 rows from the UNWALKED tail are played before the resume. Each jumps to the front
        // of a `lastPlayedDate`-DESC sort, so the resume's offset now points 1,100 rows BEHIND
        // where it left off — every one of those rows is served a second time.
        var drifted = original
        let playedNow = 2_100_000_000_000.0
        var promoted: [Row] = []
        for i in stride(from: total - 1, through: total - 1_100, by: -1) {
            let row = drifted.remove(at: i)
            promoted.append(Row(rowId: row.rowId, catalogId: row.catalogId, title: row.title,
                                artist: row.artist, playCount: (row.playCount ?? 0) + 1,
                                lastPlayedMs: playedNow + Double(promoted.count)))
        }
        drifted.insert(contentsOf: promoted, at: 0)
        XCTAssertEqual(drifted.count, total)

        let resumed = try await AppleMusicPlayCountCapture.walk(
            pager: FakePager(rows: drifted), run: resumeFrom, resolve: resolver(total),
            pageLimit: 500, checkpointRows: 500, maxCheckpointRows: 500, checkpoint: { _ in })

        // Not one already-folded row may be folded twice. `s400`/`s499`/`s600` are the rows the
        // old guard doubled (802 / 1000 / 1202 instead of 401 / 500 / 601).
        for i in 0..<1_500 {
            XCTAssertEqual(resumed.counts["s\(i)"]?.n, i + 1, "row \(i) was folded more than once")
        }
        XCTAssertEqual(resumed.counts["s400"]?.n, 401)
        XCTAssertEqual(resumed.counts["s499"]?.n, 500)
        XCTAssertEqual(resumed.counts["s600"]?.n, 601)
        XCTAssertLessThanOrEqual(resumed.scanned, total,
                                 "a row can be SKIPPED by drift, never counted twice")
    }

    /// Interrupt after EVERY page and resume, over and over, until the walk finishes. The result
    /// must be identical to a single clean run — the strongest statement of SET-not-ADD there is.
    func testInterruptingEveryPageStillLandsOnTheCleanResult() async throws {
        let rows = library(100)
        let clean = try await AppleMusicPlayCountCapture.walk(
            pager: FakePager(rows: rows), run: .starting(since: nil, trigger: "test", nowMs: 1),
            resolve: resolver(100), pageLimit: 10, checkpointRows: 10, checkpoint: { _ in })

        var run = Run.starting(since: nil, trigger: "test", nowMs: 1)
        var laps = 0
        while !run.completed, laps < 50 {
            laps += 1
            do {
                run = try await AppleMusicPlayCountCapture.walk(
                    pager: FakePager(rows: rows, failAfterPages: 1), run: run,
                    resolve: resolver(100), pageLimit: 10, checkpointRows: 10,
                    maxCheckpointRows: 10, checkpoint: { snap in run = snap })
            } catch {}
        }
        XCTAssertTrue(run.completed, "it finished, in \(laps) interrupted laps")
        XCTAssertEqual(run.counts, clean.counts, "11 interruptions == 0 interruptions")
        XCTAssertEqual(run.playsHeld, (1...100).reduce(0, +))
    }

    // MARK: - 10. A checkpoint can never leave a state the commit then refuses

    /// `mergePartial` skips `replaceAll`'s guards on purpose. That left a hole: a full walk that
    /// finds 50 of the 200 songs already stored is REFUSED at commit ("your existing numbers were
    /// kept") — but its checkpoints had already raised those 50 rows from 7 plays to 999, so the
    /// baseline was changed anyway and the message was false. The gate closes it.
    func testARejectedFullWalkLeavesTheBaselineExactlyAsItWas() async throws {
        let rig = makeService()
        rig.baseline.replaceAll(
            counts: (0..<200).reduce(into: [:]) { $0["s\($1)"] = .init(n: 7, lastMs: 1_000) },
            capturedAtMs: 500, source: "musickit")
        XCTAssertEqual(rig.baseline.totalPlays, 1_400)

        // A full walk that lists only 50 rows — and reports an absurd count for each of them.
        let broken = (0..<50).map { i in
            Row(rowId: "i.\(i)", catalogId: "cat\(i)", title: "Song \(i)", artist: "Artist",
                playCount: 999, lastPlayedMs: Double(9_000_000 - i))
        }
        rig.service.pagerFactory = { FakePager(rows: broken) }
        XCTAssertTrue(rig.service.startCapture(songs: catalog(50), trigger: "manual"))
        await rig.service.awaitCapture()

        XCTAssertEqual(rig.baseline.lastOutcome, .rejectedCoverageLoss(kept: 50, existing: 200))
        XCTAssertEqual(rig.baseline.songCount, 200)
        XCTAssertEqual(rig.baseline.totalPlays, 1_400,
                       "a read the app calls broken must not have touched the baseline at all")
        XCTAssertEqual(rig.baseline.count("s0"), 7)
        XCTAssertNil(rig.baseline.lastPlayedHighWaterMs)
    }

    // MARK: - 11. Forget really forgets, even mid-walk

    /// `cancelCapture()` only marks the task cancelled and returns; the walk then lands a final
    /// checkpoint UNCONDITIONALLY. That checkpoint used to re-merge the counts, rewrite the
    /// baseline document `clear()` had just deleted and recreate the run document — so the button
    /// whose confirmation says "There is no undo" silently didn't.
    func testForgetDuringAWalkIsNotUndoneByTheWalksFinalCheckpoint() async throws {
        let rig = makeService()
        let rows = library(4_000)
        rig.service.pagerFactory = { FakePager(rows: rows, delayNanos: 1_000_000) }
        rig.service.pageLimit = 10
        rig.service.checkpointRows = 10
        rig.service.maxCheckpointRows = 10

        XCTAssertTrue(rig.service.startCapture(songs: catalog(4_000), trigger: "manual"))
        let banked = await wait { rig.baseline.songCount > 0 }
        XCTAssertTrue(banked, "the walk banked something first")

        rig.service.forgetBaseline()
        await rig.service.awaitCapture()

        XCTAssertEqual(rig.baseline.songCount, 0, "forgotten means forgotten")
        XCTAssertEqual(rig.baseline.totalPlays, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.baselineURL.path),
                       "…and the document stays deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.runURL.path),
                       "…and no resumable run is left to re-bank it on the next foreground")
        // The clear is RECORDED, so the first-run auto-capture does not rebuild it on the very
        // next launch — which would make the button undo itself.
        XCTAssertNotNil(rig.service.lastCapture?.clearedByOwnerMs)
        XCTAssertFalse(rig.service.autoCaptureIfNeverCaptured(songs: catalog(4_000)))
        let reborn = PlayCountService(baseline: rig.baseline, stats: PlayStatsStore(fileURL:
                        FileManager.default.temporaryDirectory.appendingPathComponent("pdj-\(UUID().uuidString).json")),
                                      runURL: rig.runURL, auditURL: rig.auditURL)
        reborn.captureAvailable = { true }
        XCTAssertFalse(reborn.autoCaptureIfNeverCaptured(songs: catalog(10)),
                       "a relaunch must not rebuild what the owner deliberately cleared")
    }

    // MARK: - 12. "Re-read everything" refuses BEFORE it destroys anything

    /// It drops the incremental mark and the banked run, then starts a walk — but the guards used
    /// to live inside `startCapture`, below those two lines. A tap before the catalog finished
    /// loading wiped the mark, deleted a resumable cursor, started nothing, and made the button
    /// itself disappear (it renders only while a mark exists).
    func testRecaptureEverythingKeepsTheMarkAndTheRunWhenItRefuses() async throws {
        let rig = makeService()
        let rows = library(60)
        rig.service.pagerFactory = { FakePager(rows: rows, failAfterPages: 3) }
        rig.baseline.replaceAll(counts: ["s0": .init(n: 1, lastMs: 2_000_000_000_000)],
                                capturedAtMs: 1_000, source: "musickit",
                                lastPlayedHighWaterMs: 1_999_999_000_000)

        // Bank an interrupted run so there is a cursor to lose.
        XCTAssertTrue(rig.service.startCapture(songs: catalog(60), trigger: "manual"))
        await rig.service.awaitCapture()
        XCTAssertEqual(rig.service.lastCapture?.isInterrupted, true)
        let bankedCursor = try XCTUnwrap(rig.service.lastCapture?.cursor)
        XCTAssertGreaterThan(bankedCursor, 0)
        await rig.service.flushCaptureWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.runURL.path))

        // The catalog has not loaded yet.
        XCTAssertFalse(rig.service.recaptureEverything(songs: []))
        XCTAssertNotNil(rig.baseline.lastPlayedHighWaterMs, "the mark must survive a refusal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.runURL.path),
                      "…and so must the banked run")
        XCTAssertEqual(PlayCountService.loadRun(from: rig.runURL)?.cursor, bankedCursor)

        // MusicKit unavailable is the same story.
        rig.service.captureAvailable = { false }
        XCTAssertFalse(rig.service.recaptureEverything(songs: catalog(60)))
        XCTAssertNotNil(rig.baseline.lastPlayedHighWaterMs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.runURL.path))
    }

    // MARK: - 13. A MusicKit walk never re-labels a folded, cross-source baseline

    /// `countsToStore` FOLDS onto a baseline from another source rather than replacing it, because
    /// a MusicKit walk reaches only the songs carrying an `appleMusicId` (46,664 of 56,224
    /// measured). But `replaceAll` always re-labelled the source, so after ONE fold the stored
    /// label read "musickit" — and the next full walk saw the same source, REPLACED, and deleted
    /// the ~9,560 songs / 21,652 plays only the exporter could reach.
    func testAFoldedWalkLeavesTheSourceLabelAloneSoTheNextOneAlsoFolds() async throws {
        let rig = makeService()
        // A library-xml baseline: 120 songs, 20 of which no MusicKit walk can resolve.
        rig.baseline.replaceAll(
            counts: (0..<120).reduce(into: [:]) { $0["s\($1)"] = .init(n: 5, lastMs: 1_000) },
            capturedAtMs: 500, source: "library-xml", sourceName: "Apple Music (Local)")

        // A full walk that sees only the first 100 songs.
        rig.service.pagerFactory = { FakePager(rows: self.library(100, playsFrom: 10)) }
        XCTAssertTrue(rig.service.startCapture(songs: catalog(100), trigger: "manual"))
        await rig.service.awaitCapture()

        XCTAssertEqual(rig.baseline.songCount, 120, "the fold keeps the 20 it cannot see")
        XCTAssertEqual(rig.baseline.source, "library-xml",
                       "a MIXTURE must not be labelled as a snapshot of the narrower source")

        // …so a SECOND full walk still folds, and those 20 songs are still there.
        rig.service.pagerFactory = { FakePager(rows: self.library(100, playsFrom: 30)) }
        XCTAssertTrue(rig.service.recaptureEverything(songs: catalog(100)))
        await rig.service.awaitCapture()
        XCTAssertEqual(rig.baseline.songCount, 120,
                       "the second walk would have deleted 20 songs with the old label")
        XCTAssertEqual(rig.baseline.count("s119"), 5, "…including this one, which it cannot see")
    }

    /// The end-of-library exit used to `break` BEFORE the checkpoint block, unlike the incremental
    /// exit right below it — so the last interval's rows were never merged (they survived only
    /// because the commit writes everything, and a REJECTED commit writes nothing), and the
    /// "Saved so far · N checkpoints" line the owner reads was under by one on every successful
    /// full walk.
    func testTheEndOfLibraryExitAlsoLandsACheckpoint() async throws {
        var cursors: [Int] = []
        let run = try await AppleMusicPlayCountCapture.walk(
            pager: FakePager(rows: library(25)),
            run: .starting(since: nil, trigger: "test", nowMs: 1),
            resolve: resolver(25), pageLimit: 10, checkpointRows: 1_000, maxCheckpointRows: 1_000,
            checkpoint: { snap in await MainActor.run { cursors.append(snap.cursor) } })

        XCTAssertTrue(run.completed)
        XCTAssertEqual(cursors, [25], "the interval never came due — and it checkpointed anyway")
        XCTAssertEqual(run.checkpoints, 1)
        XCTAssertEqual(run.libraryRowsEstimate, 25,
                       "…and it measured the library on the way out, for the progress denominator")
    }

    // MARK: - 14. The adaptive checkpoint interval

    /// A FIXED interval does not scale: both persisted documents grow with the library, so 5,000
    /// rows means ~20 whole-document writes on a 96k library and ~100 on a 500k one — write volume
    /// quadratic in library size. The interval grows with the accumulator instead, which makes the
    /// checkpoints geometric and the total volume linear, and it is capped so worst-case loss on
    /// an interruption stays bounded.
    func testCheckpointIntervalGrowsWithTheRunAndIsCapped() {
        let f = AppleMusicPlayCountCapture.checkpointInterval
        XCTAssertEqual(f(0, 5_000, 25_000), 5_000, "the floor governs at the start")
        XCTAssertEqual(f(4_000, 5_000, 25_000), 5_000)
        XCTAssertEqual(f(20_000, 5_000, 25_000), 10_000, "…then it tracks the accumulator")
        XCTAssertEqual(f(90_000, 5_000, 25_000), 25_000, "…up to the cap")
        XCTAssertEqual(f(9_000_000, 5_000, 25_000), 25_000, "…and never past it")
        // Pinning the cap to the floor is how the exact-cursor tests above stay deterministic.
        XCTAssertEqual(f(90_000, 20, 20), 20)
    }

    /// The routine refresh: sorted newest-played first, stop at the stored mark. It must remain a
    /// handful of rows, and it must FOLD (never replace) so untouched songs survive.
    func testIncrementalWalkStopsAtTheMarkAndFolds() async throws {
        let rig = makeService()
        rig.baseline.replaceAll(counts: ["s0": .init(n: 1, lastMs: 2_000_000_000_000),
                                          "s9": .init(n: 10, lastMs: 1_999_999_991_000),
                                          "old": .init(n: 99, lastMs: 1_000)],
                                 capturedAtMs: 1_000, source: "musickit",
                                 lastPlayedHighWaterMs: 1_999_999_995_000)

        // Rows 0..<5 are newer than the mark; row 5 is not, so the walk stops there.
        rig.service.pagerFactory = { FakePager(rows: self.library(100, playsFrom: 20)) }
        XCTAssertTrue(rig.service.startCapture(songs: catalog(100), trigger: "manual"))
        await rig.service.awaitCapture()

        let audit = try XCTUnwrap(rig.service.lastCapture)
        XCTAssertTrue(audit.completed)
        XCTAssertFalse(audit.isFullWalk)
        XCTAssertEqual(audit.scanned, 5, "it stopped at the mark instead of walking 100 rows")
        XCTAssertEqual(rig.baseline.count("old"), 99, "an incremental walk FOLDS; it never replaces")
        XCTAssertEqual(rig.baseline.count("s0"), 20)
        XCTAssertEqual(rig.baseline.lastPlayedHighWaterMs, 2_000_000_000_000)
    }
}
