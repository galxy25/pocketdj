import XCTest
@testable import PocketDJ

/// The Demuxer's LYRIC-GENERATION trigger (the "Generate/Regenerate lyrics" button over the
/// VOCALS stem). Two seams:
///   • `DemuxLyricButton.state` — the pure initial-vs-retry-vs-resume + vocals-stem gating the
///     button renders from (the `DemuxTakeSwitch.targetMode` pure-projection idiom);
///   • the run-state end-to-end through `DemuxStore.analyzeTranscript` driven by the
///     `transcribeHook` seam (headless CI has no on-device speech models), asserting the button
///     state the store's persisted document projects to before / during / after a run.
@MainActor
final class DemuxLyricGenerationTests: XCTestCase {

    private var dir: URL!

    private func makeStore() -> DemuxStore {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-lyricbtn-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
        return DemuxStore(cacheDir: DemuxStore.defaultCacheDir(dir))
    }

    override func tearDown() {
        Task { @MainActor in DemuxStore.transcribeHook = nil }
        super.tearDown()
    }

    private func awaitRunEnd(_ store: DemuxStore, key: String) async throws {
        for _ in 0..<200 {
            if !store.transcriptRuns.contains(key) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("lyric run never finished")
    }

    private static func word(_ t: String, _ start: Int) -> DemuxWord {
        DemuxWord(text: t, startMs: start, endMs: start + 300)
    }

    private static func report(_ index: Int, of total: Int, start: Int, end: Int,
                               words: [DemuxWord], failure: String? = nil) -> DemuxTranscriber.WindowReport {
        DemuxTranscriber.WindowReport(index: index, total: total, startMs: start, endMs: end,
                                      words: words, failure: failure)
    }

    // MARK: - Pure button-state machine (gating + initial-vs-retry)

    func testStateNeedsStemsWhenNoVocals() {
        // No vocals stem ⇒ nothing to trigger, no matter what the doc says.
        XCTAssertEqual(DemuxLyricButton.state(status: nil, hasWords: false,
                                              running: false, hasVocals: false), .needsStems)
        XCTAssertEqual(DemuxLyricButton.state(status: .done, hasWords: true,
                                              running: false, hasVocals: false), .needsStems,
                       "even with landed words, no stem = no vocals-stem trigger")
    }

    func testStateInitialIsGenerate() {
        XCTAssertEqual(DemuxLyricButton.state(status: nil, hasWords: false,
                                              running: false, hasVocals: true), .generate)
        XCTAssertEqual(DemuxLyricButton.state(status: DemuxArtifactStatus.none, hasWords: false,
                                              running: false, hasVocals: true), .generate)
    }

    func testStateRegenerateWhenLyricsExist() {
        XCTAssertEqual(DemuxLyricButton.state(status: .done, hasWords: true,
                                              running: false, hasVocals: true), .regenerate)
    }

    func testStateRetryForFailedAndForDoneEmptyInstrumental() {
        XCTAssertEqual(DemuxLyricButton.state(status: .failed, hasWords: false,
                                              running: false, hasVocals: true), .retry)
        XCTAssertEqual(DemuxLyricButton.state(status: .done, hasWords: false,
                                              running: false, hasVocals: true), .retry,
                       "done-empty is a (retryable) instrumental verdict, not a dead end")
    }

    func testStateResumeForPersistedRunningWithNoLiveRun() {
        XCTAssertEqual(DemuxLyricButton.state(status: .running, hasWords: true,
                                              running: false, hasVocals: true), .resume)
    }

    func testStateUnavailable() {
        XCTAssertEqual(DemuxLyricButton.state(status: .unavailable, hasWords: false,
                                              running: false, hasVocals: true), .unavailable)
    }

    func testLiveRunWinsOverEverything() {
        // A run in flight is the spinner regardless of persisted status or stem presence.
        XCTAssertEqual(DemuxLyricButton.state(status: .done, hasWords: true,
                                              running: true, hasVocals: true), .running)
        XCTAssertEqual(DemuxLyricButton.state(status: .failed, hasWords: false,
                                              running: true, hasVocals: false), .running)
    }

    // MARK: - End-to-end: the store's persisted doc projects the expected button state

    /// Helper mirroring the view: project the button state off the store's persisted document.
    private func buttonState(_ store: DemuxStore, _ src: DemuxSource, hasVocals: Bool) -> DemuxLyricButtonState {
        let doc = store.document(for: src.key)
        return DemuxLyricButton.state(status: doc?.transcriptStatus,
                                      hasWords: !(doc?.words.isEmpty ?? true),
                                      running: store.transcriptRuns.contains(src.key),
                                      hasVocals: hasVocals)
    }

    func testTriggerGeneratesThenProjectsRegenerate() async throws {
        let store = makeStore()
        let src = DemuxSource.song(id: "sng_lyr1", title: "T", artist: "A")

        // INITIAL: never transcribed, vocals stem present ⇒ the button offers "Generate".
        XCTAssertEqual(buttonState(store, src, hasVocals: true), .generate)

        DemuxStore.transcribeHook = { _, resumeFrom, onWindow in
            XCTAssertEqual(resumeFrom, 0, "a first run starts from 0")
            await onWindow?(Self.report(0, of: 2, start: 0, end: 50_000,
                                        words: [Self.word("let", 1_000)]))
            await onWindow?(Self.report(1, of: 2, start: 50_000, end: 90_000,
                                        words: [Self.word("go", 51_000)]))
            return []
        }
        // The button's action drives the SAME run-machine the transcript panel uses.
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"), durationMs: 90_000)
        try await awaitRunEnd(store, key: src.key)

        // POST-RUN: words landed ⇒ the button now offers "Regenerate".
        let doc = try XCTUnwrap(store.document(for: src.key))
        XCTAssertEqual(doc.transcriptStatus, .done)
        XCTAssertEqual(doc.words.map(\.text), ["let", "go"])
        XCTAssertEqual(buttonState(store, src, hasVocals: true), .regenerate)
    }

    func testFailedRunProjectsRetryAndRegenerateForcesCleanRerun() async throws {
        let store = makeStore()
        let src = DemuxSource.song(id: "sng_lyr2", title: "T", artist: "A")

        // A run where every window fails hard ⇒ persisted `.failed` ⇒ the button offers "Retry".
        DemuxStore.transcribeHook = { _, _, onWindow in
            await onWindow?(Self.report(0, of: 1, start: 0, end: 40_000, words: [], failure: "boom"))
            throw DemuxTranscriber.TranscribeError.recognitionFailed("boom")
        }
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"), durationMs: 40_000)
        try await awaitRunEnd(store, key: src.key)
        XCTAssertEqual(store.document(for: src.key)?.transcriptStatus, .failed)
        XCTAssertEqual(buttonState(store, src, hasVocals: true), .retry)

        // Retry (force) re-runs the whole file clean and lands words ⇒ back to "Regenerate".
        DemuxStore.transcribeHook = { _, resumeFrom, onWindow in
            XCTAssertEqual(resumeFrom, 0, "a forced retry re-runs from 0, never resumes the failed run")
            await onWindow?(Self.report(0, of: 1, start: 0, end: 40_000,
                                        words: [Self.word("back", 2_000)]))
            return []
        }
        store.analyzeTranscript(source: src, url: URL(fileURLWithPath: "/dev/null"),
                                durationMs: 40_000, force: true)
        try await awaitRunEnd(store, key: src.key)
        XCTAssertEqual(store.document(for: src.key)?.words.map(\.text), ["back"])
        XCTAssertEqual(buttonState(store, src, hasVocals: true), .regenerate)
    }
}
