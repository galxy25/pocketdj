import XCTest
@testable import PocketDJ

/// The listening-pockets outcome fields on `PlayHistoryStore.PlayEvent` — additive-optional (no
/// schema bump), so an OLD log must decode untouched and a GARBAGE new field must never cost the
/// play; `noteListened` max-merges; `stampContexts` is write-once + local-only; and the CloudKit
/// union (`reloadFromDisk`) converges on the fields without ping-pong saves.
@MainActor
final class PlayHistoryOutcomeTests: XCTestCase {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-outcome-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func event(_ id: UUID = UUID(), song: String = "sng_a", at: Double = 1_000,
                       origin: String? = nil) -> PlayHistoryStore.PlayEvent {
        PlayHistoryStore.PlayEvent(id: id, songId: song, playedAt: at, source: .playlist,
                                   contextId: nil, contextName: nil, title: nil, artist: nil,
                                   originInstallId: origin)
    }

    // MARK: Back-compat decode

    func testOldDocumentWithoutNewFieldsDecodesAsUnknown() throws {
        let url = tempURL()
        let json = """
        {"schemaVersion":1,"installId":"INSTALL-1","events":[
          {"id":"0B7E0A52-1C1E-4F5B-9A11-2D3C4B5A6F70","songId":"sng_old","playedAt":1000,"source":"mix"},
          {"id":"0B7E0A52-1C1E-4F5B-9A11-2D3C4B5A6F71","songId":"sng_old2","playedAt":2000,"source":"playlist","wasSkipped":true}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let store = PlayHistoryStore(fileURL: url)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events[0].outcome, .unknown)
        XCTAssertNil(store.events[0].listenedFraction)
        XCTAssertNil(store.events[0].tzOffsetMin)
        XCTAssertNil(store.events[0].listeningContext)
        XCTAssertNil(store.events[0].carPlay)
        XCTAssertEqual(store.events[1].outcome, .skipped)
    }

    func testGarbageOrUnknownContextKeepsTheEvent() throws {
        let url = tempURL()
        let json = """
        {"schemaVersion":1,"installId":"INSTALL-1","events":[
          {"id":"0B7E0A52-1C1E-4F5B-9A11-2D3C4B5A6F70","songId":"sng_1","playedAt":1000,"source":"mix",
           "listeningContext":{"kind":"teleport","placeId":42}},
          {"id":"0B7E0A52-1C1E-4F5B-9A11-2D3C4B5A6F71","songId":"sng_2","playedAt":2000,"source":"mix",
           "listeningContext":"garbage","listenedFraction":"lots","tzOffsetMin":[1],"carPlay":"yes"},
          {"id":"0B7E0A52-1C1E-4F5B-9A11-2D3C4B5A6F72","songId":"sng_3","playedAt":3000,"source":"mix",
           "listeningContext":{"kind":"place","placeId":"plc_0123456789abcdef"},"listenedFraction":0.8,
           "tzOffsetMin":-420,"carPlay":true}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let store = PlayHistoryStore(fileURL: url)
        XCTAssertEqual(store.events.map(\.songId), ["sng_1", "sng_2", "sng_3"], "no play was dropped")
        // Unknown kind decodes leniently (reads as "no usable context").
        XCTAssertEqual(store.events[0].listeningContext?.kind, "teleport")
        XCTAssertNil(store.events[0].listeningContext?.placeId)
        XCTAssertFalse(store.events[0].listeningContext?.isPlace ?? true)
        // Wrong-typed fields read as nil instead of throwing the row out.
        XCTAssertNil(store.events[1].listeningContext)
        XCTAssertNil(store.events[1].listenedFraction)
        XCTAssertNil(store.events[1].tzOffsetMin)
        XCTAssertNil(store.events[1].carPlay)
        XCTAssertEqual(store.events[2].listeningContext, .place("plc_0123456789abcdef"))
        XCTAssertEqual(store.events[2].outcome, .completed)
        XCTAssertEqual(store.events[2].tzOffsetMin, -420)
        XCTAssertEqual(store.events[2].carPlay, true)
    }

    func testNewFieldsRoundTripThroughDisk() {
        let url = tempURL()
        let store = PlayHistoryStore(fileURL: url)
        let ev = store.record(songId: "sng_rt", context: .browser, at: 1_000)!
        store.noteListened(eventId: ev.id, fraction: 0.73)
        store.stampContexts([ev.id: .trip("trp_0123456789abcdef", origin: "plc_aaaaaaaaaaaaaaaa",
                                          destination: "plc_bbbbbbbbbbbbbbbb")])
        let reread = PlayHistoryStore(fileURL: url)
        XCTAssertEqual(reread.events.first?.listenedFraction, 0.73)
        XCTAssertEqual(reread.events.first?.listeningContext?.tripId, "trp_0123456789abcdef")
        XCTAssertEqual(reread.events.first?.tzOffsetMin, ev.tzOffsetMin)
    }

    // MARK: Outcome derivation

    func testOutcomeDerivationTable() {
        var e = event()
        XCTAssertEqual(e.outcome, .unknown)
        e.listenedFraction = 0.49
        XCTAssertEqual(e.outcome, .partial)
        e.listenedFraction = 0.5
        XCTAssertEqual(e.outcome, .completed, "exactly half is completed (the skip rule is strict <)")
        e.listenedFraction = 1
        XCTAssertEqual(e.outcome, .completed)
        e.wasSkipped = true
        XCTAssertEqual(e.outcome, .skipped, "the skip flag wins over any fraction")
        e.listenedFraction = nil
        XCTAssertEqual(e.outcome, .skipped)
    }

    // MARK: record stamps

    func testRecordStampsTzOffsetAndCarPlay() {
        let store = PlayHistoryStore(fileURL: tempURL())
        store.carPlayProbe = { true }
        let at = 1_760_000_000_000.0
        let ev = store.record(songId: "sng_tz", context: .browser, at: at)!
        let expected = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: at / 1000)) / 60
        XCTAssertEqual(ev.tzOffsetMin, expected)
        XCTAssertEqual(ev.carPlay, true)
        store.carPlayProbe = nil
        let ev2 = store.record(songId: "sng_tz2", context: .browser, at: at + 60_000)!
        XCTAssertNil(ev2.carPlay, "no probe ⇒ unknown, never false")
    }

    // MARK: noteListened

    func testNoteListenedMaxMergesAndIgnoresDecreases() {
        let store = PlayHistoryStore(fileURL: tempURL())
        let ev = store.record(songId: "sng_f", context: .browser, at: 1_000)!
        let r0 = store.revision
        store.noteListened(eventId: ev.id, fraction: 0.4)
        XCTAssertEqual(store.events[0].listenedFraction, 0.4)
        XCTAssertEqual(store.revision, r0 + 1)
        store.noteListened(eventId: ev.id, fraction: 0.2)
        XCTAssertEqual(store.events[0].listenedFraction, 0.4, "never decreases")
        store.noteListened(eventId: ev.id, fraction: 0.405)
        XCTAssertEqual(store.events[0].listenedFraction, 0.4, "sub-1% churn is dropped")
        XCTAssertEqual(store.revision, r0 + 1, "no-ops don't bump the revision")
        store.noteListened(eventId: ev.id, fraction: 1.7)
        XCTAssertEqual(store.events[0].listenedFraction, 1, "clamped to 1")
        store.noteListened(eventId: UUID(), fraction: 0.9)   // unknown id — no-op, no crash
    }

    func testNoteListenedDoesNotFireOnRecord() {
        let store = PlayHistoryStore(fileURL: tempURL())
        let ev = store.record(songId: "sng_q", context: .browser, at: 1_000)!
        var fired = 0
        store.onRecord = { _ in fired += 1 }
        store.noteListened(eventId: ev.id, fraction: 0.9)
        XCTAssertEqual(fired, 0)
    }

    // MARK: stampContexts

    func testStampContextsFillsOnlyNilAndLocalEvents() {
        let store = PlayHistoryStore(fileURL: tempURL())
        let local = event(song: "sng_l", at: 1_000, origin: store.installId)
        let legacy = event(song: "sng_legacy", at: 2_000, origin: nil)
        let peer = event(song: "sng_p", at: 3_000, origin: "OTHER-DEVICE")
        var already = event(song: "sng_done", at: 4_000, origin: store.installId)
        already.listeningContext = .place("plc_1111111111111111")
        store.replaceAll([local, legacy, peer, already])
        let tag = ListeningContextTag.place("plc_2222222222222222")
        store.stampContexts([local.id: tag, legacy.id: tag, peer.id: tag, already.id: tag])
        let byId = Dictionary(uniqueKeysWithValues: store.events.map { ($0.id, $0) })
        XCTAssertEqual(byId[local.id]?.listeningContext, tag)
        XCTAssertEqual(byId[legacy.id]?.listeningContext, tag, "nil origin = this device's own")
        XCTAssertNil(byId[peer.id]?.listeningContext, "a peer's play is never tagged with OUR place")
        XCTAssertEqual(byId[already.id]?.listeningContext, .place("plc_1111111111111111"), "write-once")
    }

    func testLastLocalEventSkipsPeers() {
        let store = PlayHistoryStore(fileURL: tempURL())
        let mine = event(song: "sng_x", at: 1_000, origin: store.installId)
        let peer = event(song: "sng_x", at: 2_000, origin: "OTHER")
        store.replaceAll([mine, peer])
        XCTAssertEqual(store.lastLocalEvent(forSongId: "sng_x")?.id, mine.id)
        XCTAssertNil(store.lastLocalEvent(forSongId: "sng_none"))
    }

    // MARK: reloadFromDisk merge

    private func writeDoc(_ events: [PlayHistoryStore.PlayEvent], installId: String, to url: URL) throws {
        let doc = PlayHistoryStore.Document(installId: installId, events: events)
        try JSONEncoder().encode(doc).write(to: url, options: .atomic)
    }

    func testReloadAdoptsPeerFractionAndContextAndResavesWhenWeHoldMore() throws {
        let url = tempURL()
        let store = PlayHistoryStore(fileURL: url)
        let id1 = UUID(), id2 = UUID()
        var a = event(id1, song: "sng_1", at: 1_000, origin: store.installId)
        a.listenedFraction = 0.3
        var b = event(id2, song: "sng_2", at: 2_000, origin: store.installId)
        b.tzOffsetMin = -420
        store.replaceAll([a, b])

        // The peer's copy: a higher fraction + a ctx for row 1; row 2 lacks our tz.
        var peerA = event(id1, song: "sng_1", at: 1_000, origin: store.installId)
        peerA.listenedFraction = 0.9
        peerA.listeningContext = .place("plc_3333333333333333")
        peerA.carPlay = true
        let peerB = event(id2, song: "sng_2", at: 2_000, origin: store.installId)
        try writeDoc([peerA, peerB], installId: "PEER", to: url)

        XCTAssertTrue(store.reloadFromDisk(), "we hold tz the doc lacks → re-publish")
        let byId = Dictionary(uniqueKeysWithValues: store.events.map { ($0.id, $0) })
        XCTAssertEqual(byId[id1]?.listenedFraction, 0.9, "max-merged")
        XCTAssertEqual(byId[id1]?.listeningContext, .place("plc_3333333333333333"))
        XCTAssertEqual(byId[id1]?.carPlay, true)
        XCTAssertEqual(byId[id2]?.tzOffsetMin, -420, "ours kept")
        // The re-saved document now carries the union.
        let reread = PlayHistoryStore(fileURL: url)
        XCTAssertEqual(reread.events.first { $0.id == id2 }?.tzOffsetMin, -420)
        XCTAssertEqual(reread.events.first { $0.id == id1 }?.listenedFraction, 0.9)
    }

    func testReloadDoesNotResaveWhenEqual() throws {
        let url = tempURL()
        let store = PlayHistoryStore(fileURL: url)
        var a = event(song: "sng_eq", at: 1_000, origin: store.installId)
        a.listenedFraction = 0.6
        a.tzOffsetMin = 60
        a.listeningContext = .place("plc_4444444444444444")
        a.carPlay = false
        store.replaceAll([a])
        try writeDoc([a], installId: "PEER", to: url)
        XCTAssertFalse(store.reloadFromDisk(), "identical rows + fields ⇒ no save (no ping-pong)")
    }

    func testReloadKeepsOurContextOverPeers() throws {
        let url = tempURL()
        let store = PlayHistoryStore(fileURL: url)
        var a = event(song: "sng_c", at: 1_000, origin: store.installId)
        a.listeningContext = .place("plc_5555555555555555")
        store.replaceAll([a])
        var theirs = a
        theirs.listeningContext = .place("plc_6666666666666666")
        try writeDoc([theirs], installId: "PEER", to: url)
        store.reloadFromDisk()
        XCTAssertEqual(store.events[0].listeningContext, .place("plc_5555555555555555"), "first writer wins")
    }
}
