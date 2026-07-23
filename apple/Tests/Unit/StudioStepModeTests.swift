import XCTest
import AVFoundation
@testable import PocketDJ

/// Sequencer per-step trigger modes (loop vs one-shot) + stretch spans: the additive
/// `StudioPatternRow` schema (round-trip + legacy decode + normalization), the store's mode
/// setters (bounce-dirty bookkeeping, cleared-on-step-off, row retarget), and the offline
/// tempo-fit bake's exact-frame contract (`StudioRender.stretchBuffer`). Hermetic: temp
/// document files + synthesized PCM.
@MainActor
final class StudioStepModeTests: XCTestCase {

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-stepmodes-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    // MARK: - Schema (additive, lenient)

    func testRowRoundTripKeepsModes() throws {
        var row = StudioPatternRow(targetId: "smp_a")
        row.steps[0] = true
        row.steps[8] = true
        row.loopSteps[0] = true
        row.stepSpans[8] = 4
        let back = try JSONDecoder().decode(StudioPatternRow.self,
                                            from: JSONEncoder().encode(row))
        XCTAssertEqual(back, row)
        XCTAssertTrue(back.loopSteps[0])
        XCTAssertEqual(back.stepSpans[8], 4)
    }

    func testLegacyRowDecodesToOneShotDefaults() throws {
        // A pre-step-modes document row (no loopSteps/stepSpans keys, short steps array).
        let legacy = #"{"targetId":"smp_a","steps":[true,false,true],"gainDb":-3}"#
        let row = try JSONDecoder().decode(StudioPatternRow.self, from: Data(legacy.utf8))
        XCTAssertEqual(row.steps.count, StudioPattern.defaultStepCount, "steps pad to the fixed 16")
        XCTAssertEqual(row.loopSteps, Array(repeating: false, count: StudioPattern.defaultStepCount),
                       "absent loopSteps ⇒ all one-shot")
        XCTAssertEqual(row.stepSpans, Array(repeating: 0, count: StudioPattern.defaultStepCount),
                       "absent stepSpans ⇒ all natural length")
        XCTAssertEqual(row.gainDb, -3)
    }

    func testNormalizedSpansClampsAndPads() {
        let n = StudioPatternRow.normalizedSpans([99, -3, 2])
        XCTAssertEqual(n.count, StudioPattern.defaultStepCount)
        XCTAssertEqual(n[0], StudioPattern.defaultStepCount, "over-range spans clamp to the step count")
        XCTAssertEqual(n[1], 0, "negative spans clamp to 0")
        XCTAssertEqual(n[2], 2)
        XCTAssertEqual(Array(n[3...]), Array(repeating: 0, count: StudioPattern.defaultStepCount - 3))
        XCTAssertEqual(StudioPatternRow.normalizedSpans(Array(repeating: 1, count: 40)).count,
                       StudioPattern.defaultStepCount, "over-long arrays truncate")
    }

    // MARK: - SEQ4 per-pattern step count (up to 365)

    func testPattern365RoundTripsWithoutTruncation() throws {
        var row = StudioPatternRow(targetId: "smp_a").resized(to: 365)
        row.steps[300] = true; row.loopSteps[300] = true; row.stepSpans[300] = 4
        let pattern = StudioPattern(id: "ptn_a", name: "Long", bpm: 120, stepCount: 365, rows: [row])
        XCTAssertEqual(pattern.stepCount, 365)
        XCTAssertEqual(pattern.rows[0].steps.count, 365)
        let back = try JSONDecoder().decode(StudioPattern.self, from: JSONEncoder().encode(pattern))
        XCTAssertEqual(back.stepCount, 365, "stepCount round-trips")
        XCTAssertEqual(back.rows[0].steps.count, 365, "the row keeps all 365 steps (no truncation to 16)")
        XCTAssertTrue(back.rows[0].steps[300], "step 300 survives")
        XCTAssertTrue(back.rows[0].loopSteps[300])
        XCTAssertEqual(back.rows[0].stepSpans[300], 4)
    }

    func testLegacyPatternDecodesTo16Steps() throws {
        // A pre-SEQ4 document: no stepCount key, a row with a 16-length steps array.
        let steps = (0..<16).map { $0 == 4 ? "true" : "false" }.joined(separator: ",")
        let json = #"{"id":"ptn_a","name":"Old","bpm":120,"rows":[{"targetId":"smp_a","steps":[\#(steps)]}]}"#
        let p = try JSONDecoder().decode(StudioPattern.self, from: Data(json.utf8))
        XCTAssertEqual(p.stepCount, StudioPattern.defaultStepCount, "absent stepCount ⇒ 16")
        XCTAssertEqual(p.rows[0].steps.count, 16)
        XCTAssertTrue(p.rows[0].steps[4])
    }

    func testStepCountClampAndLengthMs() {
        XCTAssertEqual(StudioPattern.clampStepCount(999), StudioPattern.maxStepCount)
        XCTAssertEqual(StudioPattern.clampStepCount(0), 1)
        // 32 steps at 120 BPM = 2 bars.
        let p = StudioPattern(id: "p", name: "n", bpm: 120, stepCount: 32)
        XCTAssertEqual(p.lengthMs, StudioPattern.barMs(bpm: 120) * 2)
    }

    /// Resizing a pattern DOWN then back UP preserves within-range steps and zero-fills the gap.
    func testResizePreservesInRangeStepsAndPadsGrowth() {
        var row = StudioPatternRow(targetId: "smp_a").resized(to: 32)
        row.steps[5] = true; row.steps[20] = true
        let grown = row.resized(to: 48)
        XCTAssertEqual(grown.steps.count, 48)
        XCTAssertTrue(grown.steps[5]); XCTAssertTrue(grown.steps[20])
        XCTAssertFalse(grown.steps[40], "grown tail is off")
        let shrunk = row.resized(to: 16)
        XCTAssertEqual(shrunk.steps.count, 16)
        XCTAssertTrue(shrunk.steps[5])
        // step 20 is beyond 16 ⇒ dropped
        XCTAssertEqual(shrunk.steps.filter { $0 }.count, 1)
    }

    // MARK: - Store setters (mutatePattern discipline)

    private func makePattern(_ store: StudioStore) -> String {
        let p = store.addPattern(StudioPattern(id: StudioFactory.newPatternId(), name: "P",
                                               rows: [StudioPatternRow(targetId: "smp_a")]))
        return p.id
    }

    func testModeSettersPersistAndDirtyTheBounce() {
        let store = StudioStore(fileURL: storeURL)
        let id = makePattern(store)
        store.setPatternStep(id, row: 0, col: 3, on: true)
        store.setPatternBounced(id, fileName: "pattern-x.m4a", wasUserFolder: false)
        XCTAssertFalse(store.pattern(id)!.bounceDirty)

        store.setPatternStepLoop(id, row: 0, col: 3, loop: true)
        XCTAssertTrue(store.pattern(id)!.rows[0].loopSteps[3])
        XCTAssertTrue(store.pattern(id)!.bounceDirty, "a loop-mode edit re-dirties the bounce")

        store.setPatternBounced(id, fileName: "pattern-x.m4a", wasUserFolder: false)
        store.setPatternStepSpan(id, row: 0, col: 3, span: 8)
        XCTAssertEqual(store.pattern(id)!.rows[0].stepSpans[3], 8)
        XCTAssertTrue(store.pattern(id)!.bounceDirty, "a span edit re-dirties the bounce")

        store.setPatternStepSpan(id, row: 0, col: 3, span: 99)
        XCTAssertEqual(store.pattern(id)!.rows[0].stepSpans[3], StudioPattern.defaultStepCount,
                       "spans clamp at the setter too")
    }

    func testClearingAStepShedsItsModes() {
        let store = StudioStore(fileURL: storeURL)
        let id = makePattern(store)
        store.setPatternStep(id, row: 0, col: 5, on: true)
        store.setPatternStepLoop(id, row: 0, col: 5, loop: true)
        store.setPatternStepSpan(id, row: 0, col: 5, span: 4)
        store.setPatternStep(id, row: 0, col: 5, on: false)
        let row = store.pattern(id)!.rows[0]
        XCTAssertFalse(row.loopSteps[5], "a cleared step drops loop mode")
        XCTAssertEqual(row.stepSpans[5], 0, "a cleared step drops its span")
    }

    func testRowRetargetKeepsStepsModesAndGain() {
        let store = StudioStore(fileURL: storeURL)
        let id = makePattern(store)
        store.setPatternStep(id, row: 0, col: 0, on: true)
        store.setPatternStepLoop(id, row: 0, col: 0, loop: true)
        store.setPatternRowGain(id, row: 0, gainDb: -6)
        store.setPatternBounced(id, fileName: "pattern-x.m4a", wasUserFolder: false)

        store.setPatternRowTarget(id, row: 0, targetId: "smp_other")
        let row = store.pattern(id)!.rows[0]
        XCTAssertEqual(row.targetId, "smp_other")
        XCTAssertTrue(row.steps[0], "retarget keeps the steps")
        XCTAssertTrue(row.loopSteps[0], "retarget keeps the modes")
        XCTAssertEqual(row.gainDb, -6, "retarget keeps the gain")
        XCTAssertTrue(store.pattern(id)!.bounceDirty, "retarget re-dirties the bounce")

        store.setPatternRowTarget(id, row: 0, targetId: "")
        XCTAssertEqual(store.pattern(id)!.rows[0].targetId, "smp_other",
                       "empty target ids are refused")
    }

    // MARK: - Stretch bake (exact frames)

    private func makeCanonicalBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: StudioAudio.canonicalFormat, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<Int(buf.format.channelCount) {
            let p = buf.floatChannelData![c]
            for i in 0..<Int(frames) {
                p[i] = sinf(Float(i) * 2 * .pi * 220 / 44_100) * 0.5
            }
        }
        return buf
    }

    func testStretchBufferHitsExactTargetFrames() async throws {
        let src = makeCanonicalBuffer(frames: 44_100)
        let half = try await StudioRender.shared.stretchBuffer(src, toFrames: 22_050)
        XCTAssertEqual(Int64(half.frameLength), 22_050, "compress lands bit-exactly on target")
        XCTAssertTrue(StudioAudio.isCanonical(half.format))
        let double = try await StudioRender.shared.stretchBuffer(src, toFrames: 88_200)
        XCTAssertEqual(Int64(double.frameLength), 88_200, "stretch lands bit-exactly on target")
        let same = try await StudioRender.shared.stretchBuffer(src, toFrames: 44_100)
        XCTAssertEqual(Int64(same.frameLength), 44_100)
    }

    // MARK: - Bounce ≡ live (loop wrap steady state)

    /// One row, a LOOP trigger at col 4 only: live playback rings across the bar wrap into
    /// cols 0–3 of every following pass, so the bounced bar must carry that steady-state audio
    /// BEFORE the trigger too — a silent bar head would be a dropout live playback never has.
    func testBounceLoopStepFillsBarWrapSteadyState() async throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bounce-wrap-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: dest) }
        var row = StudioPatternRow(targetId: "smp_loop")
        row.steps[4] = true
        row.loopSteps[4] = true
        let pattern = StudioPattern(id: "ptn_wrap", name: "wrap", bpm: 120, rows: [row])
        let buf = makeCanonicalBuffer(frames: 11_025)   // 0.25 s tone — fill windows carry energy
        _ = try await StudioRender.shared.bouncePattern(pattern, buffers: ["smp_loop": buf], to: dest)
        let decoded = try await StudioRender.shared.decodeBuffer(url: dest)
        let stepF = Int(StudioEngine.stepFrames(bpm: 120, sampleRate: 44_100))
        func rms(_ range: Range<Int>) -> Float {
            guard let p = decoded.floatChannelData?[0] else { return 0 }
            let hi = min(range.upperBound, Int(decoded.frameLength))
            let lo = min(range.lowerBound, hi)
            guard hi > lo else { return 0 }
            var sum: Float = 0
            for i in lo..<hi { sum += p[i] * p[i] }
            return (sum / Float(hi - lo)).squareRoot()
        }
        XCTAssertGreaterThan(rms(stepF..<(stepF * 3)), 0.05,
                             "bar head carries the wrapped loop (steady state, not silence)")
        XCTAssertGreaterThan(rms((stepF * 5)..<(stepF * 7)), 0.05,
                             "loop rings after its trigger to the bar end")
    }

    func testStretchBufferRefusesBadInput() async {
        let src = makeCanonicalBuffer(frames: 1_000)
        do {
            _ = try await StudioRender.shared.stretchBuffer(src, toFrames: 0)
            XCTFail("zero-frame target must throw")
        } catch { /* expected */ }
        let mono = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
            frameCapacity: 100)!
        mono.frameLength = 100
        do {
            _ = try await StudioRender.shared.stretchBuffer(mono, toFrames: 50)
            XCTFail("non-canonical source must throw (the row players are canonical-pinned)")
        } catch { /* expected */ }
    }
}
