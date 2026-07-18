import XCTest
import AVFoundation
@testable import PocketDJ

/// The Demuxer's analysis layer: chord templates + the full detect-over-a-file timeline
/// (synthesized triads — deterministic), transcript line grouping, chord naming/voicings,
/// and the DemuxStore document round-trip + file import. Hermetic: temp dirs + synthesized
/// audio; no Speech calls (SFSpeechRecognizer needs entitlements/hardware — its adapter is
/// exercised on device).
final class DemuxTests: XCTestCase {

    // MARK: - Chord template matching (pure)

    func testTemplateMatchIdentifiesTriads() {
        // A chroma with exactly the C-major pitch classes (C E G) → template 0 (C major).
        var cMaj = [Double](repeating: 0, count: 12)
        cMaj[0] = 1; cMaj[4] = 1; cMaj[7] = 1
        let m = ChordDetector.match(chroma: cMaj, rms: 1)
        XCTAssertEqual(m.index, 0, "C major is template 0")
        XCTAssertGreaterThan(m.score, 0.9)

        // A-minor pitch classes (A C E) → template 12 + 9.
        var aMin = [Double](repeating: 0, count: 12)
        aMin[9] = 1; aMin[0] = 1; aMin[4] = 1
        XCTAssertEqual(ChordDetector.match(chroma: aMin, rms: 1).index, 12 + 9)
    }

    func testTemplateMatchRejectsSilenceAndNoise() {
        var flat = [Double](repeating: 1, count: 12)   // white chroma — no triad stands out
        XCTAssertNil(ChordDetector.match(chroma: flat, rms: 1).index)
        flat[0] = 1.1
        XCTAssertNil(ChordDetector.match(chroma: flat, rms: 0.0001).index, "sub-RMS-floor frame is silence")
    }

    // MARK: - Chord timeline over a synthesized file

    /// 3 s of a C-major sine triad then 3 s of A-minor ⇒ exactly two segments with the change
    /// near 3 000 ms. Exercises the streaming decode, framewise chroma, vote, and merge.
    func testDetectTimelineOnSynthesizedTriads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-chords-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let seconds = 3.0
        let cMajor = [261.63, 329.63, 392.00]   // C4 E4 G4
        let aMinor = [220.00, 261.63, 329.63]   // A3 C4 E4
        for freqs in [cMajor, aMinor] {
            let frames = AVAudioFrameCount(sr * seconds)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            let p = buf.floatChannelData![0]
            for i in 0..<Int(frames) {
                var s: Float = 0
                for f in freqs { s += sinf(Float(2.0 * .pi * f * Double(i) / sr)) }
                p[i] = s * 0.2
            }
            try file.write(from: buf)
        }

        let segments = ChordDetector.detect(url: url)
        XCTAssertEqual(segments.count, 2, "one C block then one Am block, got \(segments.map(\.name))")
        XCTAssertEqual(segments.first?.name, "C")
        XCTAssertEqual(segments.last?.name, "Am")
        // The change lands near 3 000 ms (± the smoothing window).
        if let boundary = segments.last?.startMs {
            XCTAssertEqual(Double(boundary), 3_000, accuracy: 600)
        }
        // Segments cover most of their halves.
        XCTAssertLessThan(segments[0].startMs, 500)
        XCTAssertGreaterThan(segments[1].endMs, 5_000)
        XCTAssertGreaterThan(segments[0].confidence, 0.8, "pure triads match their template strongly")
    }

    // MARK: - Chord voicings + naming

    func testChordNamesAndVoicings() {
        let c = DemuxChordSegment(rootPC: 0, minor: false, startMs: 0, endMs: 1, confidence: 1)
        XCTAssertEqual(c.name, "C")
        XCTAssertEqual(c.pitchClasses, [0, 4, 7])
        XCTAssertEqual(c.midiNotes(base: 60), [60, 64, 67])          // C4 E4 G4
        XCTAssertEqual(c.midiNotes(base: 48), [48, 52, 55])          // bass-clef voicing
        XCTAssertEqual(c.guitarFrets, [8, 10, 10, 9, 8, 8], "C via the E-form barre at fret 8")
        XCTAssertEqual(c.tabText, "8-10-10-9-8-8")

        let fSharpM = DemuxChordSegment(rootPC: 6, minor: true, startMs: 0, endMs: 1, confidence: 1)
        XCTAssertEqual(fSharpM.name, "F♯m")
        XCTAssertEqual(fSharpM.pitchClasses, [6, 9, 1])
        XCTAssertEqual(fSharpM.guitarFrets, [2, 4, 4, 2, 2, 2], "F♯m via the Em-form barre at fret 2")

        let e = DemuxChordSegment(rootPC: 4, minor: false, startMs: 0, endMs: 1, confidence: 1)
        XCTAssertEqual(e.guitarFrets, [0, 2, 2, 1, 0, 0], "E major is the open E shape")
    }

    // MARK: - Transcript line grouping

    func testLineGroupingSplitsOnGapsAndCaps() {
        func w(_ t: String, _ s: Int, _ e: Int) -> DemuxWord { DemuxWord(text: t, startMs: s, endMs: e) }
        // A 2 s gap between "day" and "when" splits the lines.
        let words = [w("oh", 0, 300), w("what", 350, 600), w("a", 650, 800), w("day", 850, 1_200),
                     w("when", 3_500, 3_800), w("night", 3_900, 4_300)]
        let lines = DemuxLine.lines(from: words, gapMs: 1_200)
        XCTAssertEqual(lines.map(\.text), ["oh what a day", "when night"])
        XCTAssertEqual(lines[0].startMs, 0)
        XCTAssertEqual(lines[0].endMs, 1_200)
        XCTAssertEqual(lines[1].startMs, 3_500)

        // A run with no gaps still wraps at maxWords.
        let dense = (0..<10).map { w("w\($0)", $0 * 100, $0 * 100 + 80) }
        XCTAssertEqual(DemuxLine.lines(from: dense, gapMs: 1_200, maxWords: 4).count, 3)
        XCTAssertTrue(DemuxLine.lines(from: [], gapMs: 1_200).isEmpty)
    }

    // MARK: - DemuxStore persistence

    @MainActor
    func testDocumentRoundTripAndReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DemuxStore(cacheDir: DemuxStore.defaultCacheDir(dir))
        let source = DemuxSource.song(id: "sng_test1", title: "Song", artist: "Artist")
        XCTAssertNil(store.document(for: source.key), "nothing analyzed yet")

        var doc = store.documentCreating(for: source)
        doc.durationMs = 180_000
        doc.chordStatus = .done
        doc.chords = [DemuxChordSegment(rootPC: 7, minor: false, startMs: 0, endMs: 4_000, confidence: 0.9)]
        doc.transcriptStatus = .done
        doc.words = [DemuxWord(text: "hello", startMs: 100, endMs: 500)]
        store.save(doc)

        // A FRESH store (new memory tier) reloads the persisted document from disk.
        let reloaded = DemuxStore(cacheDir: DemuxStore.defaultCacheDir(dir))
        let got = try XCTUnwrap(reloaded.document(for: "sng_test1"))
        XCTAssertEqual(got.chords.first?.name, "G")
        XCTAssertEqual(got.words.first?.text, "hello")
        XCTAssertEqual(got.transcriptStatus, .done)
        XCTAssertEqual(got.durationMs, 180_000)
        XCTAssertEqual(got.schemaVersion, demuxSchemaVersion)
    }

    @MainActor
    func testImportFileCopiesAudioAndMintsSource() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent("My Jam.wav")
        try Data([1, 2, 3, 4]).write(to: picked)
        defer { try? FileManager.default.removeItem(at: picked) }

        let store = DemuxStore(cacheDir: DemuxStore.defaultCacheDir(dir))
        let source = try XCTUnwrap(store.importFile(from: picked))
        guard case .file(let id, let name) = source else { return XCTFail("expected .file source") }
        XCTAssertTrue(id.hasPrefix("dmx_"))
        XCTAssertEqual(name, "My Jam")
        // The audio was COPIED into the cache (durable past the picker's scope) …
        let localURL = try XCTUnwrap(store.importedAudioURL(for: id))
        XCTAssertEqual(try Data(contentsOf: localURL), Data([1, 2, 3, 4]))
        // … and the document already exists, carrying the imported filename.
        XCTAssertEqual(store.document(for: id)?.displayName, "My Jam")
    }
}
