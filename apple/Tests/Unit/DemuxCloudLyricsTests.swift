import XCTest
@testable import PocketDJ

/// Cloud timed-lyrics ingestion: the manifest's new lyrics fields, the sidecar decode
/// (defensive, partial-tolerant), the wholesale landing on the demux document (done + full
/// coverage + provenance — the resume machinery must never "resume" a cloud transcript), and
/// DemuxDocument back-compat for all the new optional fields. Hermetic: temp demux cache.
@MainActor
final class DemuxCloudLyricsTests: XCTestCase {

    // MARK: - Manifest fields

    func testManifestEntryDecodesLyricsFields() throws {
        let json = #"{"key":"rips/sng_x.mp3","lyrics":"rips/lyrics/sng_x.json","lyricsVersion":1,"lyricsModel":"faster-whisper-small"}"#
        let e = try JSONDecoder().decode(RipsStore.ManifestEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.lyrics, "rips/lyrics/sng_x.json")
        XCTAssertEqual(e.lyricsVersion, 1)
        XCTAssertEqual(e.lyricsModel, "faster-whisper-small")
        // Back-compat: entries without the fields still decode.
        let old = try JSONDecoder().decode(RipsStore.ManifestEntry.self,
                                           from: Data(#"{"key":"rips/sng_y.mp3"}"#.utf8))
        XCTAssertNil(old.lyrics)
    }

    // MARK: - Sidecar decode (transcribe-one.py's output shape)

    func testSidecarDecodesFullAndPartial() throws {
        let full = #"{"version":1,"model":"faster-whisper-small","lang":"en","durationMs":215000,"words":[{"text":"hello","startMs":1200,"endMs":1440},{"text":"world","startMs":1500,"endMs":1800}]}"#
        let sc = try JSONDecoder().decode(RipsStore.TimedLyricsSidecar.self, from: Data(full.utf8))
        XCTAssertEqual(sc.model, "faster-whisper-small")
        XCTAssertEqual(sc.words.count, 2)
        XCTAssertEqual(sc.words[0].text, "hello")
        XCTAssertEqual(sc.words[0].startMs, 1_200)

        // Partial (older/newer writer): missing metadata decodes; malformed words → empty.
        let bare = try JSONDecoder().decode(RipsStore.TimedLyricsSidecar.self,
                                            from: Data(#"{"words":[]}"#.utf8))
        XCTAssertTrue(bare.words.isEmpty)
        XCTAssertNil(bare.model)
        let mangled = try JSONDecoder().decode(RipsStore.TimedLyricsSidecar.self,
                                               from: Data(#"{"model":"x","words":[{"text":7}]}"#.utf8))
        XCTAssertTrue(mangled.words.isEmpty, "unusable words degrade to none, never a throw")
    }

    // MARK: - Wholesale landing on the demux document

    private func makeStore() -> (DemuxStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-cloudlyrics-\(UUID().uuidString)", isDirectory: true)
        return (DemuxStore(cacheDir: DemuxStore.defaultCacheDir(dir)), dir)
    }

    func testApplyCloudTranscriptStampsDoneCoverageAndProvenance() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = DemuxSource.song(id: "sng_cl1", title: "Song", artist: "Artist")
        var doc = store.documentCreating(for: source)
        doc.durationMs = 200_000
        // Simulate stale on-device leftovers a cloud transcript must supersede wholesale.
        doc.words = [DemuxWord(text: "stale", startMs: 9, endMs: 10)]
        doc.transcriptStatus = .running
        doc.transcriptCoveredMs = 50_000
        store.save(doc)

        store.applyCloudTranscript(source: source,
                                   words: [DemuxWord(text: "world", startMs: 1_500, endMs: 1_800),
                                           DemuxWord(text: "hello", startMs: 1_200, endMs: 1_440)],
                                   model: "faster-whisper-small")
        let landed = store.document(for: source.key)!
        XCTAssertEqual(landed.transcriptStatus, .done)
        XCTAssertEqual(landed.words.map(\.text), ["hello", "world"], "words land sorted, stale ones replaced")
        XCTAssertEqual(landed.transcriptCoveredMs, 200_000,
                       "full coverage — the on-device resume machinery must never re-run")
        XCTAssertEqual(landed.transcriptEngine, "cloud")
        XCTAssertEqual(landed.transcriptDiag, "Transcribed in the cloud (faster-whisper-small).")
    }

    func testApplyCloudTranscriptEmptyWordsIsInstrumentalDone() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = DemuxSource.song(id: "sng_cl2", title: "Song", artist: "Artist")
        store.applyCloudTranscript(source: source, words: [], model: nil)
        let landed = store.document(for: source.key)!
        XCTAssertEqual(landed.transcriptStatus, .done, "empty = instrumental — done, not failed")
        XCTAssertNil(landed.transcriptDiag)
        XCTAssertEqual(landed.transcriptEngine, "cloud")
    }

    // MARK: - Document back-compat (all new fields optional)

    func testV1DocumentWithoutNewFieldsStillDecodes() throws {
        // A pre-feature cache doc: no transcriptEngine, no drumStatus/drumHits.
        let v1 = """
        {"schemaVersion":1,"sourceKey":"sng_old","displayName":"Old","durationMs":1000,
         "transcriptStatus":"done","words":[],"chordStatus":"none","chords":[]}
        """
        let doc = try JSONDecoder().decode(DemuxDocument.self, from: Data(v1.utf8))
        XCTAssertNil(doc.transcriptEngine)
        XCTAssertNil(doc.drumStatus)
        XCTAssertNil(doc.drumHits)
        // And the new fields round-trip once set.
        var d2 = doc
        d2.transcriptEngine = "cloud"
        d2.drumStatus = .done
        d2.drumHits = [DemuxDrumHit(ms: 10, kind: .kick, strength: 0.5)]
        let back = try JSONDecoder().decode(DemuxDocument.self, from: JSONEncoder().encode(d2))
        XCTAssertEqual(back, d2)
    }
}
