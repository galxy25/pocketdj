import XCTest
@testable import PocketDJ

/// PlayHistoryStore — the device-local, APPEND-ONLY play timeline behind History mode.
/// Unlike PlayStatsStore (aggregate), each play is its own event with source + set/mix context.
@MainActor
final class PlayHistoryStoreTests: XCTestCase {

    private func makeStore() -> (store: PlayHistoryStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-playhistory-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (PlayHistoryStore(fileURL: url), url)
    }

    private func ctx(_ source: PlayHistoryStore.PlaySource, _ name: String? = nil,
                    id: String? = nil) -> PlayHistoryStore.PlayContext {
        PlayHistoryStore.PlayContext(source: source, contextId: id, contextName: name)
    }

    func testRecordsEventWithContext() {
        let (store, _) = makeStore()
        let ev = store.record(songId: "s1", title: "Song One", artist: "Artist",
                              context: ctx(.setlist, "Friday Mix", id: "set_1"), at: 1_000)
        XCTAssertNotNil(ev)
        XCTAssertEqual(store.events.count, 1)
        let e = store.events[0]
        XCTAssertEqual(e.songId, "s1")
        XCTAssertEqual(e.playedAt, 1_000)
        XCTAssertEqual(e.source, .setlist)
        XCTAssertEqual(e.contextName, "Friday Mix")
        XCTAssertEqual(e.contextId, "set_1")
        XCTAssertEqual(e.title, "Song One")
        XCTAssertEqual(store.lastPlayedAt("s1"), 1_000)
        XCTAssertEqual(store.playCount("s1"), 1)
    }

    /// The same song played 3× (in different sets) is 3 timeline rows — NOT deduped like the
    /// aggregate stats — as long as each is outside the re-count window.
    func testSameSongMultiplePlaysAreDistinctEvents() {
        let (store, _) = makeStore()
        store.record(songId: "s1", context: ctx(.setlist, "Set A"), at: 1_000)
        store.record(songId: "s1", context: ctx(.mix, "Session 2"),
                     at: 1_000 + PlayHistoryStore.recountWindowMs)
        store.record(songId: "s1", context: ctx(.browser),
                     at: 1_000 + 2 * PlayHistoryStore.recountWindowMs)
        XCTAssertEqual(store.events.count, 3)
        XCTAssertEqual(store.playCount("s1"), 3)
        XCTAssertEqual(store.events.map(\.source), [.setlist, .mix, .browser])
        XCTAssertEqual(store.lastPlayedAt("s1"), 1_000 + 2 * PlayHistoryStore.recountWindowMs)
    }

    /// A re-note inside the 30 s window (seek/restart, or the burned-play double-hook where
    /// rips + coordinator both fire) collapses to ONE event.
    func testRecountWindowCollapsesDoubleHook() {
        let (store, _) = makeStore()
        let a = store.record(songId: "s1", context: ctx(.browser), at: 1_000)
        let b = store.record(songId: "s1", context: ctx(.browser),
                             at: 1_000 + PlayHistoryStore.recountWindowMs - 1)
        XCTAssertNotNil(a)
        XCTAssertNil(b)                      // deduped
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.playCount("s1"), 1)
    }

    /// An OLDER play of the same song (out-of-order / clock-skew) is a DISTINCT event, not a
    /// window-collapsed re-note — a negative time delta must never read as "within the window".
    func testOutOfOrderOlderPlayIsRecordedAsDistinctEvent() {
        let (store, _) = makeStore()
        store.record(songId: "s1", context: ctx(.mix, "Now"), at: 100_000)
        let older = store.record(songId: "s1", context: ctx(.browser), at: 10_000)   // long before
        XCTAssertNotNil(older)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.playCount("s1"), 2)
        XCTAssertEqual(store.lastPlayedAt("s1"), 100_000)   // last-played never regresses
    }

    func testEmptyIdIsIgnored() {
        let (store, _) = makeStore()
        XCTAssertNil(store.record(songId: "", context: ctx(.browser), at: 1_000))
        XCTAssertTrue(store.events.isEmpty)
    }

    func testPersistsAndReloadsIncludingInstallId() {
        let (store, url) = makeStore()
        store.record(songId: "s1", context: ctx(.setlist, "Set A", id: "set_1"), at: 1_000)
        store.record(songId: "s2", context: ctx(.mix, "Session 1"), at: 2_000)
        let install = store.installId
        let reloaded = PlayHistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.events.count, 2)
        XCTAssertEqual(reloaded.installId, install)          // stable identity for merge
        XCTAssertEqual(reloaded.events[0].contextName, "Set A")
        XCTAssertEqual(reloaded.playCount("s2"), 1)
        XCTAssertEqual(reloaded.lastPlayedAt("s1"), 1_000)
    }

    /// Event ids are stable + unique — the dedupe key a future cross-profile merge unions on.
    func testEventIdsAreUnique() {
        let (store, _) = makeStore()
        store.record(songId: "s1", context: ctx(.browser), at: 1_000)
        store.record(songId: "s2", context: ctx(.browser), at: 2_000)
        XCTAssertNotEqual(store.events[0].id, store.events[1].id)
    }

    func testClearWipesEventsButKeepsInstall() {
        let (store, _) = makeStore()
        store.record(songId: "s1", context: ctx(.browser), at: 1_000)
        let install = store.installId
        store.clear()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.playCount("s1"), 0)
        XCTAssertNil(store.lastPlayedAt("s1"))
        XCTAssertEqual(store.installId, install)
    }
}

// MARK: - Universal history: union merge across devices (R8)

@MainActor
final class PlayHistoryMergeTests: XCTestCase {

    private func store(_ tag: String) -> (PlayHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-hist-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (PlayHistoryStore(fileURL: url), url)
    }

    /// THE BUG: history synced whole-document last-writer-wins, so plays made on the Mac simply
    /// OVERWROTE plays made on the phone. A union keeps both.
    func testReloadUnionsPeerPlaysInsteadOfReplacingLocalOnes() throws {
        let (mine, url) = store("mine")
        mine.record(songId: "s_local", context: .browser, at: 2_000)
        XCTAssertEqual(mine.events.map(\.songId), ["s_local"])

        // A peer's document lands on disk (what CloudSyncService's pull writes).
        let peerEvent = PlayHistoryStore.PlayEvent(
            id: UUID(), songId: "s_peer", playedAt: 1_000, source: .browser,
            contextId: nil, contextName: nil, title: "Peer", artist: "A",
            originInstallId: "peer-install")
        let doc = PlayHistoryStore.Document(installId: "peer-install", events: [peerEvent])
        try JSONEncoder().encode(doc).write(to: url, options: .atomic)

        mine.reloadFromDisk()

        XCTAssertEqual(mine.events.map(\.songId), ["s_peer", "s_local"],
                       "both devices' plays survive, in chronological order")
    }

    /// The merge must be IDEMPOTENT — the same document applied twice adds nothing. This is what
    /// keeps a repeated pull (or a device restore) from double-counting plays.
    func testMergeIsIdempotent() throws {
        let (mine, url) = store("idem")
        mine.record(songId: "s_local", context: .browser, at: 2_000)
        let peerEvent = PlayHistoryStore.PlayEvent(
            id: UUID(), songId: "s_peer", playedAt: 1_000, source: .browser,
            contextId: nil, contextName: nil, title: nil, artist: nil, originInstallId: "peer")
        let doc = PlayHistoryStore.Document(installId: "peer", events: [peerEvent])
        try JSONEncoder().encode(doc).write(to: url, options: .atomic)

        mine.reloadFromDisk()
        let afterFirst = mine.events.count
        mine.reloadFromDisk()
        XCTAssertEqual(mine.events.count, afterFirst, "re-applying the same document is a no-op")
    }

    /// This install keeps its OWN identity through a merge. Adopting the peer's would misattribute
    /// every future play here to whichever device we last pulled from.
    func testMergeKeepsThisInstallsIdentity() throws {
        let (mine, url) = store("ident")
        let myId = mine.installId
        let doc = PlayHistoryStore.Document(installId: "someone-else", events: [])
        try JSONEncoder().encode(doc).write(to: url, options: .atomic)

        mine.reloadFromDisk()

        XCTAssertEqual(mine.installId, myId, "a pull does not change who this device is")
    }

    /// A peer's play must NOT suppress a real play here seconds later. The 30 s re-count window
    /// exists to collapse THIS device's double-hooks, so it has to stay local-only.
    func testAPeerPlayDoesNotSwallowALocalPlayOfTheSameSong() throws {
        let (mine, url) = store("window")
        let peerEvent = PlayHistoryStore.PlayEvent(
            id: UUID(), songId: "s_x", playedAt: 10_000, source: .browser,
            contextId: nil, contextName: nil, title: nil, artist: nil, originInstallId: "peer")
        let doc = PlayHistoryStore.Document(installId: "peer", events: [peerEvent])
        try JSONEncoder().encode(doc).write(to: url, options: .atomic)
        mine.reloadFromDisk()

        // Ten seconds after the PEER played it — inside the re-count window, but a genuine listen.
        let recorded = mine.record(songId: "s_x", context: .browser, at: 20_000)

        XCTAssertNotNil(recorded, "a play here is real even if another device just played the song")
        XCTAssertEqual(mine.events.filter { $0.songId == "s_x" }.count, 2)
    }

    /// …while this device's OWN double-hook is still collapsed.
    func testLocalDoubleHookIsStillCollapsed() {
        let (mine, _) = store("dbl")
        XCTAssertNotNil(mine.record(songId: "s_y", context: .browser, at: 10_000))
        XCTAssertNil(mine.record(songId: "s_y", context: .browser, at: 20_000),
                     "the same listen, re-noted — one row")
    }

    /// A NO-OP merge must not rewrite the file: save() re-stamps this install's id, so the bytes
    /// always differ, and an unconditional save would leave the document dirty after every pull —
    /// two devices then push the whole log back and forth forever (the Stage 3 lesson).
    func testNoOpMergeDoesNotRewriteTheFile() throws {
        let (mine, url) = store("noop")
        mine.record(songId: "s_a", context: .browser, at: 1_000)
        let before = try Data(contentsOf: url)

        XCTAssertFalse(mine.reloadFromDisk(), "the disk doc holds exactly what we hold")
        XCTAssertEqual(try Data(contentsOf: url), before, "a no-op merge leaves the file untouched")
    }

    /// One unreadable event must not take the whole log with it. Without a lenient decode the log
    /// reads as EMPTY and the next record() saves and pushes that emptiness to every device.
    func testAnUnknownSourceDropsOneEventNotTheDocument() throws {
        let (mine, url) = store("lenient")
        let good = UUID().uuidString
        let json = """
        {"schemaVersion":1,"installId":"peer","events":[
          {"id":"\(good)","songId":"s_ok","playedAt":1000,"source":"browser"},
          {"id":"\(UUID().uuidString)","songId":"s_bad","playedAt":2000,"source":"teleportation"}
        ]}
        """
        try Data(json.utf8).write(to: url, options: .atomic)

        mine.reloadFromDisk()

        XCTAssertEqual(mine.events.map(\.songId), ["s_ok"],
                       "the readable event survives; the unknown one is dropped, not the log")
    }

    /// Attribution drives the "on another device" hint.
    func testOriginAttribution() throws {
        let (mine, url) = store("attr")
        mine.record(songId: "s_here", context: .browser, at: 1_000)
        let local = mine.events[0]
        XCTAssertFalse(mine.isFromAnotherDevice(local))

        let peer = PlayHistoryStore.PlayEvent(
            id: UUID(), songId: "s_there", playedAt: 2_000, source: .browser,
            contextId: nil, contextName: nil, title: nil, artist: nil, originInstallId: "peer")
        XCTAssertTrue(mine.isFromAnotherDevice(peer))

        // A LEGACY event (recorded before attribution existed) reads as local, not foreign.
        var legacy = peer
        legacy.originInstallId = nil
        XCTAssertFalse(mine.isFromAnotherDevice(legacy))
        _ = url
    }
}
