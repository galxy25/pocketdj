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
