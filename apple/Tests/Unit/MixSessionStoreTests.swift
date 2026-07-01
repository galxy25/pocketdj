import XCTest
@testable import PocketDJ

/// MixSessionStore — the app-side mix-session recorder: naming/lifecycle (reset, rename, delete),
/// the played-set, continuous-event coalescing, lenient decode, and a persistence round-trip.
@MainActor
final class MixSessionStoreTests: XCTestCase {

    // MARK: - Lifecycle / naming

    func testFreshStoreSeedsSessionOne() {
        let s = MixSessionStore(fileURL: tempURL())
        XCTAssertEqual(s.currentName, "Session 1")
        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertFalse(s.currentId.isEmpty)
    }

    func testResetFinalizesCurrentAndStartsNext() {
        let s = MixSessionStore(fileURL: tempURL())
        log(s, .tempo, deck: "A", value: 1.1)
        s.notePlayed(songId: "s1")
        XCTAssertTrue(s.hasPlayed("s1"))

        s.reset()
        XCTAssertEqual(s.currentName, "Session 2")          // auto-incremented
        XCTAssertFalse(s.hasPlayed("s1"))                   // fresh session — played-set cleared
        XCTAssertEqual(s.sessions.count, 2)
        let prev = s.sessions.first { $0.name == "Session 1" }
        XCTAssertEqual(prev?.playedSongIds, ["s1"])         // finalized session keeps its data
        XCTAssertNotNil(prev?.endedAt)
    }

    func testResetIsNoOpWhenNothingRecorded() {
        let s = MixSessionStore(fileURL: tempURL())
        s.reset()
        XCTAssertEqual(s.currentName, "Session 1")           // no empty pile-up
        XCTAssertEqual(s.sessions.count, 1)
    }

    func testRenameUpdatesCurrentNameAndKeepsCounter() {
        let s = MixSessionStore(fileURL: tempURL())
        s.rename(s.currentId, "  Warmup  ")
        XCTAssertEqual(s.currentName, "Warmup")              // trimmed
        XCTAssertEqual(s.sessions.first?.name, "Warmup")
        log(s, .play, deck: "A")
        s.reset()
        XCTAssertEqual(s.currentName, "Session 2")           // counter unaffected by the rename
    }

    func testDeleteCurrentReestablishesACurrent() {
        let s = MixSessionStore(fileURL: tempURL())
        log(s, .tempo, deck: "A", value: 1.0)
        let id1 = s.currentId
        s.delete(id1)
        XCTAssertFalse(s.sessions.contains { $0.id == id1 })
        XCTAssertFalse(s.currentId.isEmpty)                  // invariant: always a current session
        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertEqual(s.currentName, "Session 2")
    }

    // MARK: - Played set

    func testNotePlayedDeduplicates() {
        let s = MixSessionStore(fileURL: tempURL())
        s.notePlayed(songId: "x")
        s.notePlayed(songId: "x")
        s.notePlayed(songId: "y")
        XCTAssertEqual(s.playedSongIds(forSession: s.currentId), ["x", "y"])
        XCTAssertTrue(s.hasPlayed("x"))
        XCTAssertFalse(s.hasPlayed("z"))
    }

    // MARK: - Coalescing

    func testContinuousRunCoalescesButKeepsFinalValue() {
        let s = MixSessionStore(fileURL: tempURL())
        for i in 0..<50 { log(s, .tempo, deck: "A", value: Double(i) / 50) }   // tight loop → one bucket
        let evs = s.events(forSession: s.currentId)
        XCTAssertLessThanOrEqual(evs.count, 2, "a continuous run should collapse to ≤1 event/120ms bucket")
        XCTAssertEqual(evs.last?.value ?? .nan, 49.0 / 50, accuracy: 1e-9, "the final resting value must survive")
    }

    func testDiscreteEventBreaksTheCoalescedRun() {
        let s = MixSessionStore(fileURL: tempURL())
        log(s, .tempo, deck: "A", value: 0.1)
        log(s, .effectToggle, deck: "A", param: "reverb", flag: true)   // discrete → breaks the run
        log(s, .tempo, deck: "A", value: 0.2)
        XCTAssertEqual(s.events(forSession: s.currentId).count, 3)
    }

    func testDifferentParamsDoNotCoalesceTogether() {
        let s = MixSessionStore(fileURL: tempURL())
        log(s, .stemVolume, deck: "A", param: "bass", value: 0.4)
        log(s, .stemVolume, deck: "A", param: "vocals", value: 0.6)   // different param → its own event
        XCTAssertEqual(s.events(forSession: s.currentId).count, 2)
    }

    // MARK: - Decode resilience

    func testUnknownEventKindDecodesLenientlyAndRoundTrips() throws {
        let json = #"{"id":"e1","tMs":0,"kind":"frobnicate"}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(MixSessionEvent.self, from: json)
        XCTAssertEqual(ev.kind, .unknown("frobnicate"))           // lenient: a future kind never throws
        // …and it round-trips: re-encoding preserves the original rawValue (no lossy flatten).
        let reencoded = try JSONDecoder().decode(MixSessionEvent.self, from: JSONEncoder().encode(ev))
        XCTAssertEqual(reencoded.kind, .unknown("frobnicate"))
    }

    // MARK: - Resume across relaunch

    /// A session resumed after the app was closed must NOT bake the offline wall-clock gap into the
    /// timeline: the first new action lands just after the last saved event's tMs, not hours later.
    func testResumedSessionDoesNotBakeInTheOfflineGap() throws {
        let url = tempURL()
        // Hand-write a session that "started an hour ago" with one event at tMs 1000, then was closed.
        let started = Date().timeIntervalSince1970 * 1000 - 3_600_000   // 1h ago
        let ev = MixSessionEvent(id: "e1", tMs: 1000, kind: .tempo, deck: "A", songId: nil, title: nil,
                                 artist: nil, bpm: nil, camelot: nil, param: nil, value: 1.1, flag: nil, posMs: nil)
        let s = MixSession(id: "mses_old", name: "Old", startedAt: started, endedAt: nil,
                           events: [ev], playedSongIds: [])
        let doc = MixSessionsDocument(schemaVersion: mixSessionsSchemaVersion, sessions: [s],
                                      currentId: "mses_old", counter: 1)
        try JSONEncoder().encode(doc).write(to: url)

        let store = MixSessionStore(fileURL: url)
        XCTAssertEqual(store.currentName, "Old")                 // resumed, not a fresh session
        log(store, .tempo, deck: "A", value: 1.2)                // first action after relaunch
        let evs = store.events(forSession: store.currentId)
        XCTAssertEqual(evs.count, 2)
        XCTAssertGreaterThanOrEqual(evs.last!.tMs, 1000, "new event stays after the last saved one")
        XCTAssertLessThan(evs.last!.tMs, 60_000, "the hour-long offline gap must NOT be embedded in tMs")
    }

    // MARK: - Persistence round-trip

    func testPersistenceRoundTrip() async throws {
        let url = tempURL()
        let s = MixSessionStore(fileURL: url)
        log(s, .load, deck: "A", value: nil)
        s.notePlayed(songId: "s1")
        s.rename(s.currentId, "Friday Set")
        s.flush()
        // The write is off-main + versioned; wait for the latest snapshot to land on disk.
        try await waitUntil {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(MixSessionsDocument.self, from: data) else { return false }
            return doc.sessions.first?.name == "Friday Set"
        }
        let reloaded = MixSessionStore(fileURL: url)
        XCTAssertEqual(reloaded.currentName, "Friday Set")          // resumed across "relaunch"
        XCTAssertTrue(reloaded.hasPlayed("s1"))
        XCTAssertEqual(reloaded.events(forSession: reloaded.currentId).count, 1)
    }

    // MARK: - Recordings (captured mix audio metadata)

    func testAddRecordingAttachesAndAllocatesIds() {
        let s = MixSessionStore(fileURL: tempURL())
        let id = s.currentId
        XCTAssertTrue(s.recordings(forSession: id).isEmpty)
        let r1 = s.addRecording(toSession: id, fileName: "recording-1.m4a", startedAt: 1000,
                                durationMs: 5000, wasUserFolder: false)
        let r2 = s.addRecording(toSession: id, fileName: "recording-2.m4a", startedAt: 2000,
                                durationMs: 6000, wasUserFolder: true)
        XCTAssertEqual(r1, "rec1")
        XCTAssertEqual(r2, "rec2")                              // monotonic within a session
        let recs = s.recordings(forSession: id)
        XCTAssertEqual(recs.map(\.fileName), ["recording-1.m4a", "recording-2.m4a"])
        XCTAssertEqual(recs.last?.wasUserFolder, true)
        XCTAssertEqual(recs.first?.durationMs, 5000)
    }

    /// A recording filed against a session that has since been finalized (Reset) still attaches to it
    /// — mirrors a recording that spans a Reset, filed on Stop against the session it began in.
    func testAddRecordingToAPreviousSession() {
        let s = MixSessionStore(fileURL: tempURL())
        let first = s.currentId
        log(s, .play, deck: "A")                                // give the session activity so Reset takes
        s.reset()
        XCTAssertNotEqual(s.currentId, first)
        s.addRecording(toSession: first, fileName: "recording-1.m4a", startedAt: 10, durationMs: 100, wasUserFolder: false)
        XCTAssertEqual(s.recordings(forSession: first).count, 1)
        XCTAssertTrue(s.recordings(forSession: s.currentId).isEmpty)   // not the current one
    }

    func testRecordingsPersistAcrossReload() async throws {
        let url = tempURL()
        let s = MixSessionStore(fileURL: url)
        let id = s.currentId
        s.addRecording(toSession: id, fileName: "recording-1.m4a", startedAt: 1, durationMs: 42, wasUserFolder: true)
        s.flush()
        try await waitUntil {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(MixSessionsDocument.self, from: data) else { return false }
            return doc.sessions.first?.recordings?.first?.fileName == "recording-1.m4a"
        }
        let reloaded = MixSessionStore(fileURL: url)
        let recs = reloaded.recordings(forSession: reloaded.currentId)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.durationMs, 42)
        XCTAssertEqual(recs.first?.wasUserFolder, true)
    }

    /// A recording whose session was DELETED mid-capture is recovered (not lost): the original session
    /// id — which matches the on-disk folder — is revived as a finalized session holding the take.
    func testRecoverRecordingRevivesDeletedSession() {
        let s = MixSessionStore(fileURL: tempURL())
        let orphanId = "mses_orphan"
        s.recoverRecording(sessionId: orphanId, name: "Recovered recording", fileName: "recording-1.m4a",
                           startedAt: 1000, durationMs: 5000, wasUserFolder: false)
        XCTAssertNotNil(s.session(orphanId))
        XCTAssertEqual(s.session(orphanId)?.name, "Recovered recording")
        XCTAssertNotNil(s.session(orphanId)?.endedAt)                 // finalized
        XCTAssertEqual(s.recordings(forSession: orphanId).map(\.fileName), ["recording-1.m4a"])
        // A second recovered take for the same id appends rather than duplicating the session.
        s.recoverRecording(sessionId: orphanId, name: "Recovered recording", fileName: "recording-2.m4a",
                           startedAt: 2000, durationMs: 3000, wasUserFolder: false)
        XCTAssertEqual(s.sessions.filter { $0.id == orphanId }.count, 1)
        XCTAssertEqual(s.recordings(forSession: orphanId).count, 2)
    }

    // MARK: - Helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mixsess-\(UUID().uuidString).json")
    }

    private func log(_ store: MixSessionStore, _ kind: MixEventKind, deck: String? = nil,
                     param: String? = nil, value: Double? = nil, flag: Bool? = nil) {
        store.logEvent(kind, deck: deck, songId: nil, title: nil, artist: nil, bpm: nil,
                       camelot: nil, param: param, value: value, flag: flag, posMs: nil)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return XCTFail("timed out waiting for condition") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
