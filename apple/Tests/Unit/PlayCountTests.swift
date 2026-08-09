import XCTest
@testable import PocketDJ

/// The lifetime play-count stack: `AMPlayBaselineStore` (Apple's snapshot), `PlayStatsStore`'s
/// source tagging, and `PlayCountService`'s combined read.
///
/// Every test here defends ONE of the invariants the design rests on. They are not coverage —
/// each of them is a bug that was specifically designed against:
///
///   • SET, never ADD — importing a snapshot twice must be byte-identical, or every re-import
///     inflates the numbers (the exact failure `PlayStatsStore`'s peer-play comment warns about).
///   • The double-count hazard — Apple counts a play PocketDJ streamed, so the naive sum counts it
///     twice the moment the next capture lands.
///   • Non-Apple plays survive a capture — no snapshot ever contained them, so no snapshot may
///     retire them.
///   • An all-zero capture must NOT clobber a good baseline — that shape is what the open iOS
///     `Song.playCount == nil` risk looks like, and it would silently destroy 56k rows.
@MainActor
final class PlayCountTests: XCTestCase {

    private typealias Entry = AMPlayBaselineStore.Entry

    private func makeBaseline() -> (store: AMPlayBaselineStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-ampc-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: AMPlayBaselineStore.provisionalURL(for: url))
        }
        return (AMPlayBaselineStore(fileURL: url), url)
    }

    private func makeStats() -> PlayStatsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-playstats-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return PlayStatsStore(fileURL: url)
    }

    private func makeService() -> (svc: PlayCountService, baseline: AMPlayBaselineStore,
                                   stats: PlayStatsStore, url: URL) {
        let (baseline, url) = makeBaseline()
        let stats = makeStats()
        return (PlayCountService(baseline: baseline, stats: stats), baseline, stats, url)
    }

    /// A snapshot in the shape the Library.xml exporter writes (`playcounts.json`).
    private func snapshotJSON(capturedAtMs: Double, counts: [String: Int]) -> Data {
        let rows = counts.map { "\"\($0.key)\":{\"n\":\($0.value),\"lastMs\":1700000000000}" }
            .sorted().joined(separator: ",")
        let json = """
        {"schemaVersion":1,"source":"library-xml","sourceName":"Apple Music (Local)",\
        "capturedAtMs":\(Int(capturedAtMs)),"counts":{\(rows)}}
        """
        return Data(json.utf8)
    }

    // MARK: - SET, never ADD

    /// THE invariant. Importing the same snapshot twice yields byte-identical state — if this
    /// ever fails, every re-import (a reinstall, a restore, an over-eager Settings tap) inflates
    /// the user's play counts permanently and there is no way back to the true numbers.
    func testImportingTheSameSnapshotTwiceIsByteIdentical() throws {
        let (store, url) = makeBaseline()
        let data = snapshotJSON(capturedAtMs: 1_000_000, counts: ["s1": 4, "s2": 12, "s3": 1])

        XCTAssertTrue(try store.importJSON(data))
        let afterFirst = try Data(contentsOf: url)
        XCTAssertEqual(store.count("s2"), 12)

        XCTAssertTrue(try store.importJSON(data))
        let afterSecond = try Data(contentsOf: url)

        XCTAssertEqual(afterFirst, afterSecond,
                       "re-importing the same snapshot must not change a single byte")
        XCTAssertEqual(store.count("s2"), 12, "counts were SET, not accumulated")
        XCTAssertEqual(store.totalPlays, 17)
    }

    /// A LATER snapshot replaces the earlier one wholesale — including DOWNWARD, and including
    /// songs that dropped out of the library entirely.
    func testLaterSnapshotReplacesRatherThanMerges() throws {
        let (store, _) = makeBaseline()
        XCTAssertTrue(try store.importJSON(snapshotJSON(capturedAtMs: 1_000, counts: ["s1": 9, "s2": 3])))
        XCTAssertTrue(try store.importJSON(snapshotJSON(capturedAtMs: 2_000, counts: ["s1": 2])))
        XCTAssertEqual(store.count("s1"), 2, "the new snapshot's value wins outright")
        XCTAssertEqual(store.count("s2"), 0, "a song absent from the new snapshot is gone")
        XCTAssertEqual(store.songCount, 1)
    }

    /// Zero rows are never stored (absent ≡ zero), so a library full of unplayed songs can't
    /// bloat the document — and no nil-derived 0 can ever be written.
    func testZeroRowsAreNotStored() {
        let (store, _) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 3, lastMs: nil),
                                                "s2": .init(n: 0, lastMs: nil)],
                                       capturedAtMs: 500))
        XCTAssertEqual(store.songCount, 1)
        XCTAssertEqual(store.count("s2"), 0)
    }

    // MARK: - The all-zero guard

    /// The iOS `Song.playCount == nil` shape (forum 739587) reads as "every song has zero plays".
    /// Letting that through would replace a 56k-row baseline with nothing.
    func testAllZeroCaptureDoesNotClobberAGoodBaseline() throws {
        let (store, url) = makeBaseline()
        XCTAssertTrue(try store.importJSON(snapshotJSON(capturedAtMs: 1_000, counts: ["s1": 7, "s2": 2])))
        let good = try Data(contentsOf: url)

        XCTAssertFalse(store.replaceAll(counts: [:], capturedAtMs: 9_999),
                       "an empty capture is REFUSED")
        XCTAssertFalse(store.replaceAll(counts: ["s1": .init(n: 0, lastMs: nil),
                                                 "s2": .init(n: 0, lastMs: nil)],
                                        capturedAtMs: 9_999),
                       "an all-zero capture is REFUSED")

        XCTAssertEqual(store.count("s1"), 7)
        XCTAssertEqual(store.capturedAtMs, 1_000, "the rejected capture didn't even move the clock")
        XCTAssertEqual(try Data(contentsOf: url), good, "nothing was written")
    }

    /// …but an all-zero capture against an EMPTY baseline is a no-op, not an error state: there
    /// is nothing to protect, and refusing loudly would make a brand-new install look broken.
    func testAllZeroCaptureAgainstAnEmptyBaselineIsAccepted() {
        let (store, _) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: [:], capturedAtMs: 42))
        XCTAssertTrue(store.isEmpty)
    }

    // MARK: - The double-count hazard

    /// An Apple Music play shows IMMEDIATELY (provisional), and the capture that absorbs it
    /// retires it — the total lands on 6, never 7.
    func testAnAppleMusicPlayFollowedByACaptureCountsOnce() {
        let (svc, baseline, _, _) = makeService()
        XCTAssertTrue(baseline.replaceAll(counts: ["s1": .init(n: 5, lastMs: 900)], capturedAtMs: 1_000))
        XCTAssertEqual(svc.combinedPlayCount("s1"), 5)

        // Played through Apple Music at t=2000. Apple's counter moves too — we just can't see it
        // until the next capture — so this is shown provisionally.
        svc.notePlayed("s1", backend: .appleMusic, at: 2_000)
        XCTAssertEqual(svc.combinedPlayCount("s1"), 6, "the badge moves the moment you press play")
        XCTAssertEqual(baseline.provisionalCount("s1"), 1)

        // The capture at t=3000 now reports 6 — it CONTAINS that play.
        XCTAssertTrue(svc.applyCapture(counts: ["s1": .init(n: 6, lastMs: 2_000)], capturedAtMs: 3_000))
        XCTAssertEqual(baseline.provisionalCount("s1"), 0, "the provisional play was retired")
        XCTAssertEqual(svc.combinedPlayCount("s1"), 6, "counted ONCE, not twice")
    }

    /// A play that lands AFTER the capture must survive it — retiring by timestamp, not
    /// wholesale, is the difference between a fresh badge and a badge that flickers backwards.
    func testAnApplePlayAfterTheCaptureSurvivesIt() {
        let (svc, baseline, _, _) = makeService()
        XCTAssertTrue(baseline.replaceAll(counts: ["s1": .init(n: 5, lastMs: 900)], capturedAtMs: 1_000))
        // Spaced beyond the 30 s re-count window so these are two genuine listens, not a seek.
        svc.notePlayed("s1", backend: .appleMusic, at: 100_000)   // absorbed by the capture below
        svc.notePlayed("s1", backend: .appleMusic, at: 200_000)   // AFTER it — must survive
        XCTAssertEqual(baseline.provisionalCount("s1"), 2)

        XCTAssertTrue(svc.applyCapture(counts: ["s1": .init(n: 6, lastMs: 100_000)], capturedAtMs: 150_000))
        XCTAssertEqual(baseline.provisionalCount("s1"), 1, "only the absorbed play was retired")
        XCTAssertEqual(svc.combinedPlayCount("s1"), 7)
    }

    /// A rip / local / Mix play is OURS ALONE. No Apple snapshot ever contained it, so no capture
    /// may retire it — not even one that reports a lower number for the same song.
    func testANonApplePlayIsNeverDroppedByACapture() {
        let (svc, baseline, stats, _) = makeService()
        XCTAssertTrue(baseline.replaceAll(counts: ["s1": .init(n: 5, lastMs: 900)], capturedAtMs: 1_000))

        svc.notePlayed("s1", backend: .ripServer, at: 2_000)
        svc.notePlayed("s2", backend: .ripServer, at: 2_000)   // vinyl-only: Apple never sees it
        XCTAssertEqual(svc.combinedPlayCount("s1"), 6)
        XCTAssertEqual(svc.combinedPlayCount("s2"), 1)

        // A capture lands. Apple's number for s1 is unchanged (it didn't see the rip play), and
        // it has never heard of s2.
        XCTAssertTrue(svc.applyCapture(counts: ["s1": .init(n: 5, lastMs: 900)], capturedAtMs: 3_000))
        XCTAssertEqual(svc.combinedPlayCount("s1"), 6, "the rip play still counts")
        XCTAssertEqual(svc.combinedPlayCount("s2"), 1, "a song Apple doesn't know keeps its plays")
        XCTAssertEqual(stats.nonApplePlayCount("s1"), 1)
        XCTAssertEqual(baseline.provisionalCount("s1"), 0, "a rip play never enters the Apple bucket")
    }

    // MARK: - The combined read

    func testCombinedPlayCountSumsTheThreeBuckets() {
        let (svc, baseline, stats, _) = makeService()
        XCTAssertTrue(baseline.replaceAll(counts: ["s1": .init(n: 10, lastMs: nil)], capturedAtMs: 1_000))
        // Spaced beyond the 30 s re-count window so each is a genuine listen.
        stats.notePlayed("s1", at: 100_000, appleCounted: false)   // non-Apple: +1
        stats.notePlayed("s1", at: 200_000, appleCounted: false)   // non-Apple: +1
        stats.notePlayed("s1", at: 300_000, appleCounted: true)    // Apple: tagged, subtractable
        baseline.noteApplePlay("s1", at: 300_000)                  // …and provisional: +1

        XCTAssertEqual(stats.playCount("s1"), 3, "this store still sees every play (LRP prune)")
        XCTAssertEqual(stats.nonApplePlayCount("s1"), 2, "but only 2 are addable")
        XCTAssertEqual(baseline.provisionalCount("s1"), 1)
        XCTAssertEqual(svc.combinedPlayCount("s1"), 13, "10 baseline + 2 non-Apple + 1 provisional")

        XCTAssertEqual(svc.snapshot()["s1"], 13, "the off-main snapshot agrees with the point read")
        XCTAssertEqual(svc.combinedPlayCount("never-played"), 0)
        XCTAssertEqual(svc.combinedPlayCount(""), 0)
    }

    /// The service is the ONE funnel, so its `notePlayed` must do both halves of an Apple play.
    func testServiceNotePlayedTagsAndRecordsProvisionally() {
        let (svc, baseline, stats, _) = makeService()
        svc.notePlayed("s1", backend: .appleMusic, at: 5_000)
        XCTAssertEqual(stats.playCount("s1"), 1)
        XCTAssertEqual(stats.nonApplePlayCount("s1"), 0, "Apple will report this one itself")
        XCTAssertEqual(baseline.provisionalCount("s1"), 1)
        XCTAssertEqual(svc.combinedPlayCount("s1"), 1, "shown once, right now")
    }

    /// A seek/restart is not a second listen — the provisional bucket honours the same 30 s
    /// window `PlayStatsStore` does, or the two would disagree about what a play is.
    func testProvisionalRecountWindow() {
        let (store, _) = makeBaseline()
        store.noteApplePlay("s1", at: 10_000)
        store.noteApplePlay("s1", at: 10_000 + AMPlayBaselineStore.recountWindowMs - 1)
        XCTAssertEqual(store.provisionalCount("s1"), 1)
        store.noteApplePlay("s1", at: 10_000 + 2 * AMPlayBaselineStore.recountWindowMs)
        XCTAssertEqual(store.provisionalCount("s1"), 2)
    }

    /// A hook that fires late for a play the current snapshot already contains must not resurrect
    /// it — that would be a double count with no capture in sight to clear it.
    func testAnApplePlayAtOrBeforeTheSnapshotIsIgnored() {
        let (store, _) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 3, lastMs: nil)], capturedAtMs: 5_000))
        store.noteApplePlay("s1", at: 4_999)
        XCTAssertEqual(store.provisionalCount("s1"), 0)
        store.noteApplePlay("s1", at: 5_001)
        XCTAssertEqual(store.provisionalCount("s1"), 1)
    }

    // MARK: - Persistence

    func testBaselinePersistsAndReloadsIncludingProvisional() throws {
        let (store, url) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 4, lastMs: 1_234)], capturedAtMs: 1_000,
                                       source: "musickit", sourceName: "Apple Music (Local)",
                                       lastPlayedHighWaterMs: 1_234))
        store.noteApplePlay("s1", at: 9_000)

        let reloaded = AMPlayBaselineStore(fileURL: url)
        XCTAssertEqual(reloaded.count("s1"), 4)
        XCTAssertEqual(reloaded.lastPlayed("s1"), 1_234)
        XCTAssertEqual(reloaded.capturedAtMs, 1_000)
        XCTAssertEqual(reloaded.lastPlayedHighWaterMs, 1_234)
        XCTAssertEqual(reloaded.provisionalCount("s1"), 1)
    }

    /// Malformed input must THROW rather than quietly leaving the old baseline in place — a
    /// silent failure here reads to the user as "the import did nothing".
    func testMalformedImportThrowsAndKeepsTheBaseline() throws {
        let (store, _) = makeBaseline()
        XCTAssertTrue(try store.importJSON(snapshotJSON(capturedAtMs: 1, counts: ["s1": 3])))
        XCTAssertThrowsError(try store.importJSON(Data("not json".utf8)))
        XCTAssertEqual(store.count("s1"), 3)
    }

    /// Decode the REAL exporter output, not a hand-written stand-in.
    ///
    /// Every other test here builds its own JSON, which proves the logic but not that the shape
    /// on disk is the shape this store reads — the one thing a synthetic fixture structurally
    /// cannot check. With the variable unset (CI, and any machine without the file) it skips, so
    /// it never turns a missing local artifact into a red build. To run it, note the
    /// `TEST_RUNNER_` prefix — xcodebuild strips it and injects the rest into the TEST process;
    /// a bare `PDJ_…=` on the xcodebuild command line reaches only xcodebuild itself and this
    /// test silently skips:
    ///
    ///     TEST_RUNNER_PDJ_PLAYCOUNTS_FIXTURE=/path/to/playcounts.json \
    ///       xcodebuild test -project PocketDJ.xcodeproj -scheme PocketDJ \
    ///       -destination 'platform=macOS,arch=arm64' \
    ///       -only-testing:PocketDJTests/PlayCountTests
    ///
    /// Verified against the owner's file: 56,224 songs / 144,517 plays, top row 244 — matching
    /// what MusicKit independently reported for the same library.
    func testDecodesTheRealExporterOutputWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["PDJ_PLAYCOUNTS_FIXTURE"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("set PDJ_PLAYCOUNTS_FIXTURE to a real playcounts.json to run this")
        }
        let (store, url) = makeBaseline()
        XCTAssertTrue(try store.importFile(at: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(store.songCount, 0)
        XCTAssertGreaterThan(store.totalPlays, store.songCount, "a real library averages >1 play/song")
        XCTAssertEqual(store.source, "library-xml")
        XCTAssertEqual(store.sourceName, "Apple Music (Local)")
        // …and the SET invariant holds on the real thing, at real scale.
        let first = try Data(contentsOf: url)
        XCTAssertTrue(try store.importFile(at: URL(fileURLWithPath: path)))
        XCTAssertEqual(try Data(contentsOf: url), first,
                       "re-importing the real snapshot must be byte-identical too")
        print("PDJ_PLAYCOUNT_IMPORT: songs=\(store.songCount) plays=\(store.totalPlays) "
              + "capturedAtMs=\(store.capturedAtMs)")

        // …and the refusal that actually protects it, at real scale. A MusicKit walk resolves a
        // library row through its Apple catalog id, and only 83.0% of these songs carry one
        // (46,664 of 56,224; 122,865 of 144,517 plays — measured against the real catalog). Model
        // that walk by keeping every 6th row out, and prove the fold loses nothing.
        let all = store.counts
        let reachable = Dictionary(uniqueKeysWithValues:
            all.keys.sorted().enumerated().filter { $0.offset % 6 != 0 }.map { ($0.element, all[$0.element]!) })
        XCTAssertLessThan(reachable.count, all.count)
        var walk = AppleMusicPlayCountCapture.Result()
        walk.isFullWalk = true
        walk.counts = reachable
        let folded = AppleMusicPlayCountCapture.countsToStore(
            walk, existing: all, existingSource: store.source, newSource: "musickit")
        XCTAssertEqual(folded.count, all.count, "a MusicKit walk must not delete what it cannot reach")
        XCTAssertEqual(folded.values.reduce(0) { $0 + $1.n }, store.totalPlays, "…nor any of the plays")

        // A high-water mark now rides the import, so that walk would have been INCREMENTAL anyway.
        XCTAssertNotNil(store.lastPlayedHighWaterMs)
        print("PDJ_PLAYCOUNT_FOLD: unreachable=\(all.count - reachable.count) "
              + "keptAfterFold=\(folded.count) highWater=\(store.lastPlayedHighWaterMs ?? -1)")
    }

    // MARK: - Incremental capture folding

    /// An incremental walk only carries recently-played rows, so folding it must keep every
    /// untouched key — and must never LOWER a count (Apple can hold several library rows for one
    /// song and the walk sees only the one that played).
    func testIncrementalCaptureFoldsOntoTheExistingSnapshot() {
        let existing: [String: AMPlayBaselineStore.Entry] = [
            "s1": .init(n: 9, lastMs: 100), "s2": .init(n: 4, lastMs: 200),
        ]
        let incremental: [String: AMPlayBaselineStore.Entry] = [
            "s1": .init(n: 11, lastMs: 300), "s3": .init(n: 1, lastMs: 400),
        ]
        let merged = AppleMusicPlayCountCapture.merged(existing: existing, incremental: incremental)
        XCTAssertEqual(merged["s1"]?.n, 11, "the played row's counter advanced")
        XCTAssertEqual(merged["s2"]?.n, 4, "an untouched song survives an incremental walk")
        XCTAssertEqual(merged["s3"]?.n, 1, "a newly-played song is added")

        // Idempotent: folding the same incremental walk again changes nothing.
        let again = AppleMusicPlayCountCapture.merged(existing: merged, incremental: incremental)
        XCTAssertEqual(again["s1"]?.n, 11)
        XCTAssertEqual(again["s2"]?.n, 4)
    }

    // MARK: - The pre-upgrade history (untagged rows)

    /// Write a `pocketdj-play-stats.json` in the shape the PREVIOUS build wrote: no `appleCount`,
    /// no `preTagPlayCount`, no migration stamp. This is the only honest way to test the upgrade
    /// path — constructing a `Stat` in code would use today's initializer and today's defaults.
    private func legacyStatsStore(_ rows: [String: (plays: Int, lastMs: Double)]) -> PlayStatsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-legacy-stats-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let body = rows.map { "\"\($0.key)\":{\"playCount\":\($0.value.plays),\"lastPlayedAt\":\(Int($0.value.lastMs))}" }
            .sorted().joined(separator: ",")
        try? Data("{\"schemaVersion\":1,\"stats\":{\(body)}}".utf8).write(to: url)
        return PlayStatsStore(fileURL: url)
    }

    /// THE upgrade bug. Every row written before this build carries no source tag, so
    /// `playCount - appleCount` reads the whole pre-upgrade history as "Apple never saw this" —
    /// and then adds it on top of an Apple snapshot that already contains its Apple share. A song
    /// Apple counted 12 times and PocketDJ streamed 3 of would read #15 forever, with no way back.
    func testImportingABaselineDoesNotDoubleCountUntaggedLegacyPlays() throws {
        let stats = legacyStatsStore(["s1": (plays: 3, lastMs: 500_000)])
        let (baseline, _) = makeBaseline()
        let svc = PlayCountService(baseline: baseline, stats: stats)
        XCTAssertEqual(svc.combinedPlayCount("s1"), 3, "with no Apple baseline the local count is all there is")

        // Apple's snapshot lands, and it already contains those plays.
        XCTAssertTrue(try baseline.importJSON(snapshotJSON(capturedAtMs: 1_000_000, counts: ["s1": 12])))
        XCTAssertEqual(svc.combinedPlayCount("s1"), 12, "Apple's number stands alone — 15 would be the bug")
        XCTAssertEqual(svc.snapshot()["s1"], 12, "the off-main snapshot agrees")
    }

    /// …but a legacy row for a song APPLE HAS NEVER HEARD OF is ours alone. Nothing can retire it,
    /// so suppressing it would silently delete a vinyl/rip history instead of a duplicate.
    func testALegacyRowForASongAppleDoesNotKnowKeepsItsPlays() throws {
        let stats = legacyStatsStore(["s1": (plays: 12, lastMs: 500_000), "vinyl": (plays: 4, lastMs: 500_000)])
        let (baseline, _) = makeBaseline()
        let svc = PlayCountService(baseline: baseline, stats: stats)
        XCTAssertTrue(try baseline.importJSON(snapshotJSON(capturedAtMs: 1_000_000, counts: ["s1": 12])))
        XCTAssertEqual(svc.combinedPlayCount("vinyl"), 4, "no snapshot ever contained this")
        XCTAssertEqual(svc.snapshot()["vinyl"], 4)
    }

    /// Plays made AFTER the upgrade are tagged, so they are trusted in full — the legacy
    /// suppression must apply to the frozen pre-upgrade share only, or every rip from here on
    /// would vanish the moment Apple learned about the song.
    func testPlaysAfterTheMigrationStillCountOnALegacyRow() throws {
        let stats = legacyStatsStore(["s1": (plays: 3, lastMs: 500_000)])
        let (baseline, _) = makeBaseline()
        let svc = PlayCountService(baseline: baseline, stats: stats)
        XCTAssertTrue(try baseline.importJSON(snapshotJSON(capturedAtMs: 1_000_000, counts: ["s1": 12])))

        svc.notePlayed("s1", backend: .ripServer, at: 2_000_000)
        XCTAssertEqual(svc.combinedPlayCount("s1"), 13, "12 Apple + the one rip play we can attribute")
        svc.notePlayed("s1", backend: .appleMusic, at: 3_000_000)
        XCTAssertEqual(svc.combinedPlayCount("s1"), 14, "…plus the provisional Apple play, once")
    }

    /// A row written by THIS build always carries `preTagPlayCount`, which is what lets the
    /// migration re-run safely (a CloudSync pull can bring untagged rows in at any time) without
    /// re-freezing plays it already attributed.
    func testMigrationIsIdempotentAcrossReloads() throws {
        let stats = legacyStatsStore(["s1": (plays: 3, lastMs: 500_000)])
        stats.notePlayed("s1", at: 2_000_000, appleCounted: false)
        XCTAssertEqual(stats.nonApplePlayCount("s1", appleKnowsSong: true), 1)
        stats.reloadFromDisk()
        XCTAssertEqual(stats.nonApplePlayCount("s1", appleKnowsSong: true), 1,
                       "a reload must not re-freeze the play recorded after the migration")
    }

    // MARK: - A capture may only retire what it OBSERVED

    /// An incremental walk sees only recently-played rows, and its catalog-id-only resolver can
    /// miss even those. Retiring provisional stamps by TIMESTAMP alone therefore deletes plays
    /// that never reached any counter — the badge silently goes backwards, permanently.
    func testAnIncrementalCaptureOnlyRetiresTheSongsItObserved() {
        let (svc, baseline, _, _) = makeService()
        XCTAssertTrue(baseline.replaceAll(counts: ["s1": .init(n: 5, lastMs: 900),
                                                   "s2": .init(n: 2, lastMs: 900)], capturedAtMs: 1_000))
        svc.notePlayed("s1", backend: .appleMusic, at: 100_000)
        svc.notePlayed("s2", backend: .appleMusic, at: 100_000)
        XCTAssertEqual(svc.combinedPlayCount("s1"), 6)
        XCTAssertEqual(svc.combinedPlayCount("s2"), 3)

        // The walk resolved s1 only — s2's Apple row carries no catalog id this app knows.
        XCTAssertTrue(svc.applyCapture(counts: ["s1": .init(n: 6, lastMs: 100_000),
                                                "s2": .init(n: 2, lastMs: 900)],
                                       capturedAtMs: 200_000, observedSongIds: ["s1"]))
        XCTAssertEqual(baseline.provisionalCount("s1"), 0, "observed ⇒ absorbed ⇒ retired")
        XCTAssertEqual(baseline.provisionalCount("s2"), 1, "unobserved ⇒ still the only record of that play")
        XCTAssertEqual(svc.combinedPlayCount("s1"), 6)
        XCTAssertEqual(svc.combinedPlayCount("s2"), 3, "the play did not evaporate")
    }

    /// A walk that resolved NOTHING retires nothing. Without this, an incremental refresh that
    /// read zero rows still advanced the clock and wiped the whole provisional bucket — while
    /// reporting success, because folding the untouched baseline back in kept the counts non-empty.
    func testACaptureThatObservedNothingRetiresNothing() {
        let (svc, baseline, _, _) = makeService()
        XCTAssertTrue(baseline.replaceAll(counts: ["s1": .init(n: 5, lastMs: 900)], capturedAtMs: 1_000))
        svc.notePlayed("s1", backend: .appleMusic, at: 100_000)
        XCTAssertTrue(svc.applyCapture(counts: ["s1": .init(n: 5, lastMs: 900)],
                                       capturedAtMs: 200_000, observedSongIds: []))
        XCTAssertEqual(baseline.provisionalCount("s1"), 1)
        XCTAssertEqual(svc.combinedPlayCount("s1"), 6, "the play PocketDJ made still shows")
    }

    /// An IMPORT is a complete snapshot of its source, so it retires by timestamp — the behaviour
    /// `observedSongIds: nil` preserves.
    func testAnImportStillRetiresByTimestamp() throws {
        let (svc, baseline, _, _) = makeService()
        svc.notePlayed("s1", backend: .appleMusic, at: 100_000)
        XCTAssertEqual(baseline.provisionalCount("s1"), 1)
        XCTAssertTrue(try baseline.importJSON(snapshotJSON(capturedAtMs: 200_000, counts: ["s1": 9])))
        XCTAssertEqual(baseline.provisionalCount("s1"), 0)
    }

    // MARK: - A read that fails is not a library that emptied

    /// The iOS `Song.playCount == nil` shape reads as "listed 90,000 songs, none ever played".
    /// It must be distinguishable from a genuinely quiet library, because the mark it would leave
    /// behind makes every later walk incremental — so the library could never be re-read.
    func testAWalkThatReadNoPlayCountsIsFlaggedAndWithholdsItsHighWaterMark() {
        var broken = AppleMusicPlayCountCapture.Result()
        broken.scanned = 90_000
        broken.withPlayCount = 0
        broken.maxLastPlayedMs = 1_700_000_000_000
        XCTAssertTrue(broken.readNothing)
        XCTAssertNil(broken.highWaterToAdopt, "a broken read must not wedge the install into incremental")

        var good = AppleMusicPlayCountCapture.Result()
        good.scanned = 90_000
        good.withPlayCount = 117
        good.maxLastPlayedMs = 1_700_000_000_000
        XCTAssertFalse(good.readNothing)
        XCTAssertEqual(good.highWaterToAdopt, 1_700_000_000_000)

        // A walk that scanned nothing at all (nothing played since the mark) is NOT broken —
        // that is the ordinary "no news" refresh.
        XCTAssertFalse(AppleMusicPlayCountCapture.Result().readNothing)
    }

    /// The mark is otherwise write-only: `lastPlayedHighWaterMs: nil` means "leave it alone", so
    /// without an explicit reset there is no way back to a full walk.
    func testResetHighWaterMakesTheNextWalkFullAgain() {
        let (store, _) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 4, lastMs: 10)], capturedAtMs: 1_000,
                                       lastPlayedHighWaterMs: 5_000))
        XCTAssertEqual(store.lastPlayedHighWaterMs, 5_000)
        store.resetHighWater()
        XCTAssertNil(store.lastPlayedHighWaterMs)
        XCTAssertEqual(store.count("s1"), 4, "non-destructive: the counts stay")

        // …and `clearHighWater` gives `replaceAll` the same escape hatch inline.
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 4, lastMs: 10)], capturedAtMs: 2_000,
                                       lastPlayedHighWaterMs: 9_000))
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 4, lastMs: 10)], capturedAtMs: 3_000,
                                       clearHighWater: true))
        XCTAssertNil(store.lastPlayedHighWaterMs)
    }

    /// An imported snapshot carries no mark of its own, so the FIRST refresh after it would be a
    /// FULL walk — the path that used to replace a 56,224-song baseline with the 46,664 songs a
    /// catalog-id-only walk can resolve. Deriving the mark from Apple's own last-played dates
    /// makes that refresh incremental instead.
    func testImportDerivesAHighWaterMarkFromApplesOwnDates() throws {
        let (store, _) = makeBaseline()
        XCTAssertTrue(try store.importJSON(snapshotJSON(capturedAtMs: 1_000_000, counts: ["s1": 4, "s2": 9])))
        XCTAssertEqual(store.lastPlayedHighWaterMs, 1_700_000_000_000,
                       "the newest lastMs in the snapshot")
        // An explicit mark in the document still wins over the derived one.
        XCTAssertEqual(AMPlayBaselineStore.derivedHighWater(["a": .init(n: 1, lastMs: nil)]), nil,
                       "no dates ⇒ no derived mark, rather than a zero")
    }

    // MARK: - A capture may not destroy coverage

    /// The all-zero guard only catches a read that returned literally nothing. A read that
    /// returns half of what is stored is the same failure and just as unrecoverable — a replace
    /// has no undo, and the status line reports it as a success.
    func testACaptureThatLosesMostOfTheBaselineIsRefused() {
        let (store, _) = makeBaseline()
        let big = Dictionary(uniqueKeysWithValues: (0..<400).map { ("s\($0)", Entry(n: 3, lastMs: nil)) })
        XCTAssertTrue(store.replaceAll(counts: big, capturedAtMs: 1_000))

        let collapsed = Dictionary(uniqueKeysWithValues: (0..<150).map { ("s\($0)", Entry(n: 3, lastMs: nil)) })
        XCTAssertFalse(store.replaceAll(counts: collapsed, capturedAtMs: 2_000))
        XCTAssertEqual(store.lastOutcome, .rejectedCoverageLoss(kept: 150, existing: 400))
        XCTAssertEqual(store.songCount, 400, "the good baseline survived")
        XCTAssertEqual(store.capturedAtMs, 1_000, "the rejected capture didn't move the clock")

        // A modest, believable shrink still applies — this guard is for collapses, not edits.
        let trimmed = Dictionary(uniqueKeysWithValues: (0..<350).map { ("s\($0)", Entry(n: 3, lastMs: nil)) })
        XCTAssertTrue(store.replaceAll(counts: trimmed, capturedAtMs: 3_000))
        XCTAssertEqual(store.songCount, 350)
    }

    /// A small baseline is never second-guessed: below the floor there is no "collapse" to detect
    /// and guarding would only block a legitimate snapshot.
    func testTheCoverageGuardIsInertBelowTheFloor() {
        let (store, _) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 9, lastMs: nil),
                                                "s2": .init(n: 3, lastMs: nil)], capturedAtMs: 1_000))
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 9, lastMs: nil)], capturedAtMs: 2_000))
        XCTAssertEqual(store.songCount, 1)
    }

    /// `.rejectedNoPlays` and `.rejectedCoverageLoss` want opposite advice from the user, so the
    /// store has to say WHICH fired rather than just returning false.
    func testTheRejectionReasonIsReported() {
        let (store, _) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 9, lastMs: nil)], capturedAtMs: 1_000))
        XCTAssertEqual(store.lastOutcome, .applied)
        XCTAssertFalse(store.replaceAll(counts: [:], capturedAtMs: 2_000))
        XCTAssertEqual(store.lastOutcome, .rejectedNoPlays)
    }

    // MARK: - A MusicKit walk may not replace a richer source

    /// The sources do not have the same reach. This walk resolves a library row through its Apple
    /// catalog id, which only 83.0% of the Library.xml baseline's songs carry (46,664 of 56,224 —
    /// 122,865 of 144,517 plays). Letting a full walk REPLACE that baseline deleted 9,560 songs
    /// and 21,652 plays and called it a success. Across sources it folds.
    func testAFullWalkFoldsOntoABaselineFromADifferentSource() {
        let existing: [String: Entry] = ["xml-only": .init(n: 40, lastMs: 100),
                                         "both": .init(n: 9, lastMs: 100)]
        var full = AppleMusicPlayCountCapture.Result()
        full.isFullWalk = true
        full.counts = ["both": .init(n: 11, lastMs: 300)]   // the walk can't see "xml-only"

        let folded = AppleMusicPlayCountCapture.countsToStore(
            full, existing: existing, existingSource: "library-xml", newSource: "musickit")
        XCTAssertEqual(folded["xml-only"]?.n, 40, "a song this walk cannot resolve is NOT deleted")
        XCTAssertEqual(folded["both"]?.n, 11, "…and the songs it can resolve still advance")

        // SAME source is still a replace — otherwise a song genuinely removed from the library, or
        // a deliberate reset in Music.app, could never propagate.
        let replaced = AppleMusicPlayCountCapture.countsToStore(
            full, existing: existing, existingSource: "musickit", newSource: "musickit")
        XCTAssertNil(replaced["xml-only"], "same-source full walk IS the snapshot")

        // An EMPTY baseline takes the walk wholesale regardless of source labels.
        XCTAssertEqual(AppleMusicPlayCountCapture.countsToStore(
            full, existing: [:], existingSource: "library-xml", newSource: "musickit").count, 1)
    }

    /// The walk's resolver: exact catalog id first, then a STRICT title+artist fallback — which is
    /// what lets it reach the 17.0% of baseline songs that carry no `appleMusicId` at all.
    func testResolverFallsBackToAStrictTitleArtistKey() {
        let index = AppleMusicPlayCountCapture.titleArtistIndex([
            (songId: "sng_a", title: "Blue Monday", artist: "New Order"),
            (songId: "sng_b", title: "Blue Monday (12\" Version)", artist: "New Order"),
            (songId: "dup1", title: "Intro", artist: "Various"),
            (songId: "dup2", title: "Intro", artist: "Various"),
        ])
        let resolve = AppleMusicPlayCountCapture.resolver(byCatalogId: ["123": "sng_catalog"],
                                                          byTitleArtist: index)
        XCTAssertEqual(resolve("123", "Anything", "Anyone"), "sng_catalog", "catalog id wins outright")
        XCTAssertEqual(resolve(nil, "blue  monday", "new order"), "sng_a", "case/spacing folded")
        XCTAssertEqual(resolve(nil, "Blue Monday (12\" Version)", "New Order"), "sng_b",
                       "the version marker is KEPT — a remix is not the original")
        XCTAssertNil(resolve(nil, "Intro", "Various"), "an ambiguous key is not an identification")
        XCTAssertNil(resolve(nil, "Unknown", "Nobody"))
        // An unresolvable catalog id must still get the fallback, not short-circuit to nil.
        XCTAssertEqual(resolve("999", "Blue Monday", "New Order"), "sng_a")
    }

    // MARK: - A play must not rewrite the whole baseline

    /// `noteApplePlay` fires at every Apple Music track change. Encoding the 56,224-row document
    /// there cost 108.7 ms on the main actor (measured on this Mac; the sidecar write is 0.185 ms)
    /// — several hundred ms per transition on a phone. The proof is that the big file does not
    /// change at all.
    func testAnApplePlayDoesNotRewriteTheBaselineDocument() throws {
        let (store, url) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 5, lastMs: 900)], capturedAtMs: 1_000))
        let before = try Data(contentsOf: url)

        store.noteApplePlay("s1", at: 100_000)
        store.noteApplePlay("s1", at: 200_000)
        XCTAssertEqual(store.provisionalCount("s1"), 2)
        XCTAssertEqual(try Data(contentsOf: url), before,
                       "a play touches the sidecar only — the baseline document is untouched")

        // …and it is still durable.
        let reloaded = AMPlayBaselineStore(fileURL: url)
        XCTAssertEqual(reloaded.provisionalCount("s1"), 2)
        XCTAssertEqual(reloaded.count("s1"), 5)
    }

    /// A document written by the PREVIOUS build carries its stamps inline. Migrate them once —
    /// and never again, or every launch would resurrect stamps a capture has since retired.
    func testLegacyInlineProvisionalStampsMigrateToTheSidecarExactlyOnce() throws {
        let (store, url) = makeBaseline()
        let legacy = """
        {"schemaVersion":1,"source":"library-xml","sourceName":"Apple Music (Local)",\
        "capturedAtMs":1000,"counts":{"s1":{"n":5}},"provisional":{"s1":[100000,200000]}}
        """
        try Data(legacy.utf8).write(to: url)
        _ = store   // the fixture store above owns teardown of `url`

        let migrated = AMPlayBaselineStore(fileURL: url)
        XCTAssertEqual(migrated.provisionalCount("s1"), 2, "the old inline stamps were adopted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AMPlayBaselineStore.provisionalURL(for: url).path))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: AMPlayBaselineStore.provisionalURL(for: url))
        }

        // A capture retires them; the stale inline copy in the OLD file must not bring them back.
        XCTAssertTrue(migrated.replaceAll(counts: ["s1": .init(n: 7, lastMs: nil)], capturedAtMs: 300_000))
        XCTAssertEqual(migrated.provisionalCount("s1"), 0)
        XCTAssertEqual(AMPlayBaselineStore(fileURL: url).provisionalCount("s1"), 0,
                       "the sidecar is authoritative once it exists")
    }

    /// Clearing must take BOTH files, or the next launch reloads the stamps of a baseline that no
    /// longer exists.
    func testClearRemovesTheSidecarToo() {
        let (store, url) = makeBaseline()
        XCTAssertTrue(store.replaceAll(counts: ["s1": .init(n: 5, lastMs: nil)], capturedAtMs: 1_000))
        store.noteApplePlay("s1", at: 100_000)
        store.clear()
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AMPlayBaselineStore.provisionalURL(for: url).path))
        let reloaded = AMPlayBaselineStore(fileURL: url)
        XCTAssertEqual(reloaded.provisionalCount("s1"), 0)
        XCTAssertTrue(reloaded.isEmpty)
    }

    /// The off-actor launch decode has to reach the UI, and the Browse feed keys on `revision` —
    /// a load that doesn't move it leaves the Browser sorted by numbers that were never read.
    func testAsyncLoadAdoptsTheDocumentAndMovesTheRevision() async throws {
        let (writer, url) = makeBaseline()
        XCTAssertTrue(writer.replaceAll(counts: ["s1": .init(n: 5, lastMs: 900)], capturedAtMs: 1_000))
        writer.noteApplePlay("s1", at: 100_000)

        let lazyStore = AMPlayBaselineStore(fileURL: url, loadNow: false)
        XCTAssertTrue(lazyStore.isEmpty, "nothing decoded on the launch path")
        let before = lazyStore.revision
        await lazyStore.loadFromDiskAsync()
        XCTAssertEqual(lazyStore.count("s1"), 5)
        XCTAssertEqual(lazyStore.provisionalCount("s1"), 1)
        XCTAssertGreaterThan(lazyStore.revision, before, "the UI's feed keys on this")

        // Idempotent: a second call must not re-adopt on top of live state.
        lazyStore.noteApplePlay("s1", at: 300_000)
        await lazyStore.loadFromDiskAsync()
        XCTAssertEqual(lazyStore.provisionalCount("s1"), 2, "the later play survived")
    }

    /// `PlayCountService.revision` must track the baseline's own, or a change made without going
    /// through the service (the async launch load, a direct import) never invalidates the memo.
    func testServiceRevisionTracksTheBaseline() {
        let (svc, baseline, _, _) = makeService()
        let before = svc.revision
        XCTAssertTrue(baseline.replaceAll(counts: ["s1": .init(n: 2, lastMs: nil)], capturedAtMs: 1))
        XCTAssertNotEqual(svc.revision, before)
    }

    /// A FULL walk is a snapshot and replaces; an INCREMENTAL walk folds. Getting this backwards
    /// would either wipe the library on every refresh or freeze the numbers forever.
    func testCountsToStoreHonoursFullVersusIncremental() {
        let existing: [String: AMPlayBaselineStore.Entry] = ["s1": .init(n: 9, lastMs: nil),
                                                            "s2": .init(n: 4, lastMs: nil)]
        var full = AppleMusicPlayCountCapture.Result()
        full.isFullWalk = true
        full.counts = ["s1": .init(n: 9, lastMs: nil)]
        XCTAssertEqual(AppleMusicPlayCountCapture.countsToStore(full, existing: existing).count, 1,
                       "a full walk IS the snapshot — s2 is genuinely gone")

        var incr = AppleMusicPlayCountCapture.Result()
        incr.isFullWalk = false
        incr.counts = ["s1": .init(n: 10, lastMs: nil)]
        let folded = AppleMusicPlayCountCapture.countsToStore(incr, existing: existing)
        XCTAssertEqual(folded.count, 2, "an incremental walk keeps what it didn't look at")
        XCTAssertEqual(folded["s1"]?.n, 10)
    }
}

/// The Browser's "Plays" field — the sort Levi asked for, plus the range filter it comes with.
///
/// It is the ONE field whose value doesn't live on the row (lifetime plays are in a device-local
/// store), so it is threaded through the pure pipeline as a snapshot. These tests pin that
/// threading: the value reaching `Fields.value`, the ordering, and — most importantly — that a
/// surface with NO play-count service behaves exactly as it did before this existed.
@MainActor
final class BrowsePlayCountFieldTests: XCTestCase {

    private func song(_ id: String, _ name: String) -> BrowseItem {
        .song(IndexSong.minimal(id: id, name: name, artist: "A"), albumName: "Alb")
    }

    private var items: [BrowseItem] {
        [song("s1", "One"), song("s2", "Two"), song("s3", "Three")]
    }

    private let counts = ["s1": 4, "s3": 41]   // s2 has never been played

    func testPlaysFieldIsOfferedForSongsOnly() {
        XCTAssertTrue(Fields.forKind(.song).contains { $0.id == "playCount" && $0.label == "Plays" })
        XCTAssertFalse(Fields.forKind(.album).contains { $0.id == "playCount" })
        XCTAssertFalse(Fields.forKind(.artist).contains { $0.id == "playCount" })
        // NOT history-only: it belongs in the ordinary Browser sheets, unlike "Last played".
        XCTAssertEqual(Fields.byID["playCount"]?.historyOnly, false)
        XCTAssertEqual(Fields.byID["playCount"]?.sortable, true)
        XCTAssertEqual(Fields.byID["playCount"]?.numeric, true)
    }

    private func number(_ v: FieldValue) -> Double? {
        if case .number(let n) = v { return n }
        return nil
    }

    func testValueReadsTheSnapshotAndTreatsZeroAsAbsent() {
        XCTAssertEqual(number(Fields.value(song("s1", "One"), "playCount", playCounts: counts)), 4)
        // Unplayed reads `.none`, NOT `.number(0)` — that is what puts it last in either
        // direction instead of pretending it's the least-played song.
        guard case .none = Fields.value(song("s2", "Two"), "playCount", playCounts: counts) else {
            return XCTFail("an unplayed song must read .none")
        }
        guard case .none = Fields.value(song("s1", "One"), "playCount") else {
            return XCTFail("with no snapshot every song must read .none")
        }
    }

    func testSortByPlaysDescendingPutsTheMostPlayedFirstAndUnplayedLast() {
        let keys = [SortKey(field: "playCount", dir: .desc)]
        let out = SortEngine.apply(items, keys, playCounts: counts).map(\.id)
        XCTAssertEqual(out, ["s3", "s1", "s2"], "41, then 4, then never-played (nulls last)")

        let asc = SortEngine.apply(items, [SortKey(field: "playCount", dir: .asc)],
                                   playCounts: counts).map(\.id)
        XCTAssertEqual(asc, ["s1", "s3", "s2"], "nulls stay LAST even ascending")
    }

    /// A host with no play-count service must sort exactly as it did before the field existed:
    /// every value null ⇒ the stable input order is preserved.
    func testSortByPlaysWithNoSnapshotPreservesInputOrder() {
        let out = SortEngine.apply(items, [SortKey(field: "playCount", dir: .desc)]).map(\.id)
        XCTAssertEqual(out, ["s1", "s2", "s3"])
    }

    func testRangeFilterOnPlays() {
        var clause = Clause(field: "playCount", op: .between)
        clause.min = 10
        let kept = FilterEngine.apply(items, [clause], playCounts: counts).map(\.id)
        XCTAssertEqual(kept, ["s3"], "only the 41-play song clears a floor of 10")
    }

    /// The whole pipeline, the way the Browser actually calls it.
    func testFilterSortThreadsPlayCountsEndToEnd() {
        let keys = ["one a alb", "two a alb", "three a alb"]
        let out = BrowseState.filterSort(base: items, searchKeys: keys, query: "", clauses: [],
                                         sortKeys: [SortKey(field: "playCount", dir: .desc)],
                                         playCounts: counts).map(\.id)
        XCTAssertEqual(out, ["s3", "s1", "s2"])
    }

    /// The results memo is keyed on a revision, not on the counts themselves — without that a
    /// capture would leave a sorted-by-plays list showing the pre-capture order until some
    /// unrelated input changed.
    func testPlayCountsRevisionMovesTheResultsMemoKey() async {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let browse = BrowseState(defaults: UserDefaults(suiteName: "pdj.test.\(UUID().uuidString)")!)
        browse.kind = .song
        browse.sortKeys = [SortKey(field: "playCount", dir: .desc)]
        let before = browse.resultsKey(app)
        browse.applyPlayCounts(["s1": 3], revision: 7)
        XCTAssertNotEqual(browse.resultsKey(app), before, "a new snapshot invalidates the memo")
        // …and re-applying the SAME revision is a no-op, so the memo isn't churned per render.
        let after = browse.resultsKey(app)
        browse.applyPlayCounts(["s1": 99], revision: 7)
        XCTAssertEqual(browse.resultsKey(app), after)
        XCTAssertEqual(browse.playCounts["s1"], 3, "the no-op didn't adopt the new map either")
    }
}
