import XCTest
@testable import PocketDJ

/// The transcript RUN machine in `DemuxStore.analyzeTranscript` (the "lyrics stop after a
/// snip" field fix), driven through the `transcribeHook` seam (headless CI has no on-device
/// speech models): incremental per-window persistence, `.running` + coverage stamping,
/// resume-from-coverage after an app death, force-regenerate reset, and the diag note when
/// some windows fail.
final class DemuxTranscriptRunTests: XCTestCase {

    private var dir: URL!

    @MainActor
    private func makeStore() -> DemuxStore {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-run-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
        return DemuxStore(cacheDir: DemuxStore.defaultCacheDir(dir))
    }

    override func tearDown() {
        Task { @MainActor in DemuxStore.transcribeHook = nil }
        super.tearDown()
    }

    @MainActor
    private func awaitRunEnd(_ store: DemuxStore, key: String) async throws {
        for _ in 0..<200 {
            if !store.transcriptRuns.contains(key) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("transcript run never finished")
    }

    private static func word(_ t: String, _ start: Int) -> DemuxWord {
        DemuxWord(text: t, startMs: start, endMs: start + 300)
    }

    private static func report(_ index: Int, of total: Int, start: Int, end: Int,
                               words: [DemuxWord], failure: String? = nil) -> DemuxTranscriber.WindowReport {
        DemuxTranscriber.WindowReport(index: index, total: total, startMs: start, endMs: end,
                                      words: words, failure: failure)
    }

    @MainActor
    func testWindowsLandIncrementallyAndFinishDone() async throws {
        let store = makeStore()
        let src = DemuxSource.song(id: "sng_run1", title: "T", artist: "A")
        DemuxStore.transcribeHook = { _, resumeFrom, onWindow in
            XCTAssertEqual(resumeFrom, 0, "fresh doc starts from 0")
            await onWindow?(Self.report(0, of: 2, start: 0, end: 50_000,
                                        words: [Self.word("back", 1_000)]))
            await onWindow?(Self.report(1, of: 2, start: 50_000, end: 90_000,
                                        words: [Self.word("forth", 51_000)]))
            return []
        }
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"), durationMs: 90_000)
        try await awaitRunEnd(store, key: src.key)

        let doc = try XCTUnwrap(store.document(for: src.key))
        XCTAssertEqual(doc.transcriptStatus, .done)
        XCTAssertEqual(doc.words.map(\.text), ["back", "forth"], "both windows' words, sorted")
        XCTAssertEqual(doc.transcriptCoveredMs, 90_000)
        XCTAssertNil(doc.transcriptDiag, "clean run carries no partial-failure note")
    }

    @MainActor
    func testPartialWindowFailureKeepsWordsAndSetsDiag() async throws {
        let store = makeStore()
        let src = DemuxSource.song(id: "sng_run2", title: "T", artist: "A")
        DemuxStore.transcribeHook = { _, _, onWindow in
            await onWindow?(Self.report(0, of: 3, start: 0, end: 50_000,
                                        words: [Self.word("hello", 500)]))
            await onWindow?(Self.report(1, of: 3, start: 50_000, end: 100_000,
                                        words: [], failure: "recognition timed out"))
            await onWindow?(Self.report(2, of: 3, start: 100_000, end: 150_000,
                                        words: [Self.word("world", 101_000)]))
            return []
        }
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"), durationMs: 150_000)
        try await awaitRunEnd(store, key: src.key)

        let doc = try XCTUnwrap(store.document(for: src.key))
        XCTAssertEqual(doc.transcriptStatus, .done, "words in hand — a bad window is partial, not failed")
        XCTAssertEqual(doc.words.map(\.text), ["hello", "world"])
        let diag = try XCTUnwrap(doc.transcriptDiag)
        XCTAssertTrue(diag.contains("1 of 3"), "diag names the failed-window count: \(diag)")
    }

    @MainActor
    func testAllWindowsFailedLandsFailedNotInstrumental() async throws {
        let store = makeStore()
        let src = DemuxSource.song(id: "sng_run3", title: "T", artist: "A")
        DemuxStore.transcribeHook = { _, _, onWindow in
            await onWindow?(Self.report(0, of: 1, start: 0, end: 50_000,
                                        words: [], failure: "boom"))
            throw DemuxTranscriber.TranscribeError.recognitionFailed("boom")
        }
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"), durationMs: 50_000)
        try await awaitRunEnd(store, key: src.key)

        let doc = try XCTUnwrap(store.document(for: src.key))
        XCTAssertEqual(doc.transcriptStatus, .failed, "a broken run must be retryable, never .done-empty")
        XCTAssertTrue(doc.words.isEmpty)
    }

    @MainActor
    func testInterruptedRunResumesFromCoverageKeepingWords() async throws {
        let store = makeStore()
        let src = DemuxSource.song(id: "sng_run4", title: "T", artist: "A")
        // Simulate the app having died mid-run: `.running` persisted with one window landed.
        var dead = store.documentCreating(for: src)
        dead.durationMs = 150_000
        dead.transcriptStatus = .running
        dead.words = [Self.word("kept", 1_000)]
        dead.transcriptCoveredMs = 50_000
        store.save(dead)

        DemuxStore.transcribeHook = { _, resumeFrom, onWindow in
            XCTAssertEqual(resumeFrom, 50_000, "resume starts at the coverage point")
            await onWindow?(Self.report(1, of: 3, start: 50_000, end: 100_000,
                                        words: [Self.word("new", 51_000)]))
            await onWindow?(Self.report(2, of: 3, start: 100_000, end: 150_000, words: []))
            return []
        }
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"), durationMs: 150_000)
        try await awaitRunEnd(store, key: src.key)

        let doc = try XCTUnwrap(store.document(for: src.key))
        XCTAssertEqual(doc.transcriptStatus, .done)
        XCTAssertEqual(doc.words.map(\.text), ["kept", "new"], "pre-death words survive the resume")
        XCTAssertEqual(doc.transcriptCoveredMs, 150_000)
    }

    @MainActor
    func testForceRegenerateStartsCleanEvenWhenRunning() async throws {
        let store = makeStore()
        let src = DemuxSource.song(id: "sng_run5", title: "T", artist: "A")
        var stale = store.documentCreating(for: src)
        stale.transcriptStatus = .running
        stale.words = [Self.word("stale", 1_000)]
        stale.transcriptCoveredMs = 50_000
        store.save(stale)

        DemuxStore.transcribeHook = { _, resumeFrom, onWindow in
            XCTAssertEqual(resumeFrom, 0, "force always re-runs the whole file")
            await onWindow?(Self.report(0, of: 1, start: 0, end: 40_000,
                                        words: [Self.word("fresh", 2_000)]))
            return []
        }
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"),
                                durationMs: 40_000, force: true)
        try await awaitRunEnd(store, key: src.key)

        let doc = try XCTUnwrap(store.document(for: src.key))
        XCTAssertEqual(doc.words.map(\.text), ["fresh"], "stale words cleared by the force pass")
        XCTAssertEqual(doc.transcriptStatus, .done)
    }

    @MainActor
    func testCleanEmptyRunIsInstrumentalDone() async throws {
        let store = makeStore()
        let src = DemuxSource.song(id: "sng_run6", title: "T", artist: "A")
        DemuxStore.transcribeHook = { _, _, onWindow in
            await onWindow?(Self.report(0, of: 1, start: 0, end: 40_000, words: []))
            return []
        }
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"), durationMs: 40_000)
        try await awaitRunEnd(store, key: src.key)

        let doc = try XCTUnwrap(store.document(for: src.key))
        XCTAssertEqual(doc.transcriptStatus, .done, "no words + no failures = instrumental")
        XCTAssertNil(doc.transcriptDiag)
    }
}
