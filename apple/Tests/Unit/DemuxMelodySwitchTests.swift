import XCTest
@testable import PocketDJ

/// F8 slice B — the comping↔melody switch's persistence + store-level re-extract.
///   • StudioTake wipe-safety: an OLD take with no demuxSourceKey/demuxMode decodes intact, and a
///     new take round-trips both fields (additive-OPTIONAL, no schemaVersion bump).
///   • DemuxTakeSwitch.switchMode: a comping take re-extracts to melody events (and back), reading
///     the demux doc's chords / cached melody notes and flipping demuxMode — with a clear error
///     when melody is requested but the source has no cached notes AND no local stems.
@MainActor
final class DemuxMelodySwitchTests: XCTestCase {

    // MARK: - StudioTake wipe-safety (additive-optional demux fields)

    func testOldTakeWithoutDemuxFieldsDecodesIntact() throws {
        // A pre-slice-B take JSON has NEITHER key — it must decode with nil demux fields, never fail.
        let json = """
        {"id":"tk_old","name":"Old","instrument":"piano","fileName":"o.m4a",\
        "wasUserFolder":false,"bpm":120,"events":[],"durationMs":1000,"createdAt":0}
        """
        let t = try JSONDecoder().decode(StudioTake.self, from: Data(json.utf8))
        XCTAssertEqual(t.id, "tk_old")
        XCTAssertNil(t.demuxSourceKey, "an old take has no demux source")
        XCTAssertNil(t.demuxMode, "an old take has no demux mode")
    }

    func testNewTakeRoundTripsDemuxFields() throws {
        let take = StudioTake(id: "tk_new", name: "New", fileName: "n.m4a",
                              demuxSourceKey: "src1", demuxMode: "melody")
        let back = try JSONDecoder().decode(StudioTake.self, from: JSONEncoder().encode(take))
        XCTAssertEqual(back.demuxSourceKey, "src1")
        XCTAssertEqual(back.demuxMode, "melody")
    }

    // MARK: - Store-level switch re-extract

    private func tempURL(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-\(UUID().uuidString).\(ext)")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func makeStores() -> (demux: DemuxStore, burns: BurnStore, studio: StudioStore, packs: InstrumentPackStore) {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-demux-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheDir) }
        let demux = DemuxStore(cacheDir: DemuxStore.defaultCacheDir(cacheDir))
        let burns = BurnStore(rips: RipsStore(), fileURL: tempURL("json"))
        let studio = StudioStore(fileURL: tempURL("json"))
        return (demux, burns, studio, InstrumentPackStore())
    }

    private func seededDoc(_ demux: DemuxStore, key: String, withMelody: Bool) -> DemuxDocument {
        var doc = demux.documentCreating(for: .file(id: key, name: "src"))
        doc.chords = [DemuxChordSegment(rootPC: 0, minor: false, startMs: 0, endMs: 1_000, confidence: 0.9)]
        doc.chordStatus = .done
        if withMelody {
            doc.melodyNotes = [DemuxMelodyNote(midi: 60, startMs: 0, endMs: 500),
                               DemuxMelodyNote(midi: 62, startMs: 500, endMs: 1_000)]
            doc.melodyStatus = .done
        }
        demux.save(doc)
        return doc
    }

    func testSwitchCompingToMelodyAndBack() async throws {
        let s = makeStores()
        let key = "melodyfix_src"
        let doc = seededDoc(s.demux, key: key, withMelody: true)
        let compingEvents = DemuxInstrumental.events(chords: doc.chords, grid: (120, 0, [])).events
        s.studio.addTake(StudioTake(id: "tk_sw", name: "x", fileName: "f.m4a", bpm: 120,
                                    events: compingEvents, durationMs: 1_000, createdAt: 0,
                                    demuxSourceKey: key, demuxMode: "comping"))

        // comping → melody: a single-voice line from the cached melody notes.
        try await DemuxTakeSwitch.switchMode(take: s.studio.take("tk_sw")!, demux: s.demux,
                                             burns: s.burns, studio: s.studio, packs: s.packs)
        let melodyTake = s.studio.take("tk_sw")!
        XCTAssertEqual(melodyTake.demuxMode, "melody")
        XCTAssertEqual(melodyTake.scoreEvents.map(\.note), [60, 62],
                       "the switch replaced the events with the monophonic melody line")

        // melody → comping: back to the full triad from the doc's chords.
        try await DemuxTakeSwitch.switchMode(take: s.studio.take("tk_sw")!, demux: s.demux,
                                             burns: s.burns, studio: s.studio, packs: s.packs)
        let compingTake = s.studio.take("tk_sw")!
        XCTAssertEqual(compingTake.demuxMode, "comping")
        XCTAssertEqual(Set(compingTake.scoreEvents.map(\.note)), [60, 64, 67],
                       "switching back re-extracts the C-major triad comping")
    }

    func testSwitchToMelodyWithoutStemsThrowsNeedStems() async throws {
        let s = makeStores()
        let key = "nostems_src"
        _ = seededDoc(s.demux, key: key, withMelody: false)   // no cached melody, no local stems
        s.studio.addTake(StudioTake(id: "tk_ns", name: "x", fileName: "f.m4a", bpm: 120,
                                    events: [], durationMs: 1_000, createdAt: 0,
                                    demuxSourceKey: key, demuxMode: "comping"))
        do {
            try await DemuxTakeSwitch.switchMode(take: s.studio.take("tk_ns")!, demux: s.demux,
                                                 burns: s.burns, studio: s.studio, packs: s.packs)
            XCTFail("switching to melody with no cached notes and no stems must throw")
        } catch DemuxTakeSwitch.SwitchError.needStems {
            // expected — the take stays comping
            XCTAssertEqual(s.studio.take("tk_ns")?.demuxMode, "comping")
        }
    }

    func testTargetModeIsOpposite() {
        let comping = StudioTake(id: "a", name: "", fileName: "", demuxSourceKey: "k", demuxMode: "comping")
        let melody = StudioTake(id: "b", name: "", fileName: "", demuxSourceKey: "k", demuxMode: "melody")
        XCTAssertEqual(DemuxTakeSwitch.targetMode(for: comping), "melody")
        XCTAssertEqual(DemuxTakeSwitch.targetMode(for: melody), "comping")
    }
}
