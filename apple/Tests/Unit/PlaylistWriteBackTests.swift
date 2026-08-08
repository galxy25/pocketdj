import XCTest
@testable import PocketDJ
#if canImport(MusicKit) && !os(macOS) && !targetEnvironment(macCatalyst)
import MusicKit
#endif

/// `PlaylistWriteBack` — the outbound half of source-playlist adds, driven end-to-end against
/// a stub transport (no MusicKit, no account, no network).
///
/// The property worth breaking a build over: THE PLAYLIST JOIN IS BY MUSICKIT ID. The name is
/// a bootstrap value only, resolved once, because an exact name match is what lost "Sweet
/// Thing" to the trailing space in `"Sap "`. So these tests pin: the id is what the write
/// uses, the expensive resolve happens once per playlist rather than once per song, the id
/// survives a relaunch, and a stale id re-resolves exactly once instead of failing.
@MainActor
final class PlaylistWriteBackTests: XCTestCase {

    /// One recorded call. Structs rather than tuples so the assertions can read them with key
    /// paths (`map(\.playlistId)`), which Swift does not offer for tuple elements.
    struct ResolveCall: Equatable {
        let name: String
        let expected: [String]
    }
    struct Write: Equatable {
        let appleMusicId: String
        let playlistId: String
    }

    /// Records every call and lets a test script resolution and failures per call.
    @MainActor
    private final class StubTransport: PlaylistWriteBackTransport {
        var isSupported = true
        var canWrite = true
        var lastResolutionNote: String?

        /// name → MusicKit id. A name with no entry resolves to nil ("no such playlist").
        var resolutions: [String: String] = [:]
        /// Ids that a write rejects as gone. Cleared entries let the retry succeed.
        var goneIds: Set<String> = []
        /// song title → on-device-resolved catalog id. A title with no entry resolves to nil,
        /// which the queue reads as `.unresolvable`. Only consulted for identity-only jobs.
        var catalogIds: [String: String] = [:]
        /// When set, `resolveCatalogId` THROWS it (a transient failure the queue should retry),
        /// distinct from a nil result (terminal `.unresolvable`).
        var resolveError: Error?

        private(set) var resolveCalls: [ResolveCall] = []
        private(set) var writes: [Write] = []
        private(set) var resolveCatalogCalls: [WriteBackSong] = []

        func resolvePlaylistId(name: String, expectedAppleMusicIds: [String]) async throws -> String? {
            resolveCalls.append(ResolveCall(name: name, expected: expectedAppleMusicIds))
            return resolutions[name]
        }

        func resolveCatalogId(for song: WriteBackSong) async throws -> String? {
            resolveCatalogCalls.append(song)
            if let resolveError { throw resolveError }
            return catalogIds[song.title]
        }

        func addSong(appleMusicId: String, toPlaylistId playlistId: String) async throws {
            if goneIds.contains(playlistId) {
                throw PlaylistWriteBackError.playlistGone(playlistId)
            }
            writes.append(Write(appleMusicId: appleMusicId, playlistId: playlistId))
        }
    }

    private func makeQueue(_ transport: StubTransport?) -> (PlaylistWriteBack, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-writeback-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (PlaylistWriteBack(fileURL: url, transport: transport), url)
    }

    // MARK: The join

    /// The write must go to the RESOLVED id, not to the name — and the name we resolve FROM is
    /// the indexed one, trailing space and all, because that is what the queue was handed.
    func testDeliversToResolvedMusicKitId() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        let (queue, _) = makeQueue(transport)

        queue.enqueue(indexPlaylistId: "pl_c0835ac9b919", playlistName: "Sap ",
                      songId: "sng_4f62fe9f7efb", appleMusicId: "1440817273")
        await queue.run()

        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.LIVE-SAP"])
        XCTAssertEqual(transport.writes.map(\.appleMusicId), ["1440817273"])
        XCTAssertEqual(queue.jobs.first?.state, .delivered)
        XCTAssertEqual(queue.jobs.first?.musicKitPlaylistId, "p.LIVE-SAP")
    }

    /// The all-playlists fetch is the expensive call, so two songs added to the same playlist
    /// must cost exactly ONE resolve.
    func testResolvesOncePerPlaylist() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        let (queue, _) = makeQueue(transport)

        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                      songId: "s1", appleMusicId: "111")
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                      songId: "s2", appleMusicId: "222")
        await queue.run()

        XCTAssertEqual(transport.resolveCalls.count, 1)
        XCTAssertEqual(transport.writes.count, 2)
    }

    /// The mapping is persisted: a relaunch must not pay for the resolve again.
    func testResolutionSurvivesRelaunch() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        let (queue, url) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                      songId: "s1", appleMusicId: "111")
        await queue.run()

        let relaunch = PlaylistWriteBack(fileURL: url, transport: transport)
        relaunch.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                         songId: "s2", appleMusicId: "222")
        await relaunch.run()

        XCTAssertEqual(transport.resolveCalls.count, 1, "the relaunch re-resolved a known playlist")
        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.LIVE-SAP", "p.LIVE-SAP"])
    }

    /// A stale id (playlist deleted, or MusicKit re-minted it) re-resolves ONCE and the write
    /// still lands — the user never sees a failure for a playlist that is plainly still there.
    func testStaleIdReResolvesOnceAndSucceeds() async {
        let transport = StubTransport()
        transport.resolutions["Sap"] = "p.OLD"
        let (queue, _) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap",
                      songId: "s1", appleMusicId: "111")
        await queue.run()
        XCTAssertEqual(transport.writes.count, 1)

        // The id goes stale; the library now hands back a different one for the same name.
        transport.goneIds.insert("p.OLD")
        transport.resolutions["Sap"] = "p.NEW"
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap",
                      songId: "s2", appleMusicId: "222")
        await queue.run()

        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.OLD", "p.NEW"])
        XCTAssertEqual(queue.failed.count, 0)
        XCTAssertEqual(queue.jobs.last?.state, .delivered)
    }

    /// No such playlist ⇒ the job records an error that NAMES the playlist and burns an
    /// attempt, rather than writing somewhere else or dying quietly. (The backoff gate makes
    /// the walk to `.failed` a wall-clock affair; what matters here is the message.)
    func testUnresolvablePlaylistRecordsAnActionableError() async {
        let transport = StubTransport()
        let (queue, _) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Gone",
                      songId: "s1", appleMusicId: "111")
        await queue.run()

        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(queue.jobs.first?.attempts, 1)
        XCTAssertEqual(queue.jobs.first?.lastError?.contains("Gone"), true)
        XCTAssertEqual(queue.lastError?.contains("Gone"), true)
    }

    /// The catalog sample is what disambiguates duplicate names, so it must actually reach the
    /// transport — and be capped, since it picks between candidates rather than verifying them.
    func testPassesCappedCatalogSampleToResolve() async {
        let transport = StubTransport()
        transport.resolutions["Sap"] = "p.LIVE"
        let (queue, _) = makeQueue(transport)
        queue.appleMusicIdsForIndexPlaylist = { _ in (0..<120).map { "id\($0)" } }

        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap",
                      songId: "s1", appleMusicId: "111")
        await queue.run()

        XCTAssertEqual(transport.resolveCalls.first?.expected.count, 50)
        XCTAssertEqual(transport.resolveCalls.first?.expected.first, "id0")
    }

    /// A guess the transport had to make is recorded on the job AND surfaced on the queue, so
    /// Settings ▸ Apple Music can show it. An invisible guess is how a song ends up in the wrong place.
    func testResolutionNoteIsRecorded() async {
        let transport = StubTransport()
        transport.resolutions["Sap"] = "p.LIVE"
        transport.lastResolutionNote = "Your library has 2 playlists named “Sap”"
        let (queue, _) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap",
                      songId: "s1", appleMusicId: "111")
        await queue.run()

        XCTAssertEqual(queue.jobs.first?.resolutionNote, transport.lastResolutionNote)
        // The warning rides `resolutionWarning`, NOT `lastError`: this delivery SUCCEEDED
        // (possibly into the wrong playlist), and a clean drain clears `lastError`.
        XCTAssertEqual(queue.resolutionWarning, transport.lastResolutionNote)
        XCTAssertNil(queue.lastError, "a successful drain reports no failure")
    }

    // MARK: Lenient decode

    /// A document written BEFORE this change (no `musicKitPlaylistId`, no resolution map) must
    /// still decode into a working queue — the house rule that keeps schemaVersion at 1.
    func testDecodesPreIdDocument() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-writeback-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"schemaVersion":1,"jobs":[{"id":"wbj_1","indexPlaylistId":"pl_1","playlistName":"Sap ",
        "songId":"s1","appleMusicId":"111","queuedAtMs":1,"attempts":0,"state":"queued"}]}
        """
        try? Data(legacy.utf8).write(to: url, options: .atomic)

        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        let queue = PlaylistWriteBack(fileURL: url, transport: transport)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertNil(queue.jobs.first?.musicKitPlaylistId)

        await queue.run()
        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.LIVE-SAP"])
    }

    /// The whole ledger — states, attempts, the resolved id, the guess note — must survive a
    /// store re-init from the same file. A queue that forgets on relaunch either loses a write
    /// the user asked for or replays one that already landed (the song appears twice upstream).
    func testJobLedgerSurvivesStoreReInit() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        transport.lastResolutionNote = "picked the first of 2"
        let (queue, url) = makeQueue(transport)

        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ", songId: "s1", appleMusicId: "111")
        queue.enqueue(indexPlaylistId: "pl_2", playlistName: "Gone", songId: "s2", appleMusicId: "222")
        await queue.run()
        XCTAssertEqual(queue.jobs.count, 2)

        let reopened = PlaylistWriteBack(fileURL: url, transport: transport)
        let delivered = reopened.jobs.first { $0.songId == "s1" }
        let stuck = reopened.jobs.first { $0.songId == "s2" }
        XCTAssertEqual(delivered?.state, .delivered)
        XCTAssertEqual(delivered?.musicKitPlaylistId, "p.LIVE-SAP")
        XCTAssertEqual(delivered?.resolutionNote, "picked the first of 2")
        XCTAssertNotNil(delivered?.settledAtMs)
        XCTAssertEqual(stuck?.state, .queued, "an unresolvable playlist is still owed, not forgotten")
        XCTAssertEqual(stuck?.attempts, 1, "and its burnt attempt carries over rather than resetting")
        XCTAssertEqual(stuck?.lastError?.isEmpty, false)
    }

    /// The resolution map is device-local and can be lost (a fresh install restoring only the
    /// queue). The job carries its own copy, so a document with an id on the JOB and no map must
    /// still write without paying for the all-playlists fetch.
    func testJobCarriedIdReSeedsTheMapWithoutResolving() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-writeback-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let doc = """
        {"schemaVersion":1,"jobs":[{"id":"wbj_1","indexPlaylistId":"pl_1","playlistName":"Sap ",
        "songId":"s1","appleMusicId":"111","queuedAtMs":1,"attempts":0,"state":"queued",
        "musicKitPlaylistId":"p.LIVE-SAP"}]}
        """
        try? Data(doc.utf8).write(to: url, options: .atomic)

        let transport = StubTransport()      // resolves NOTHING: a resolve here would fail the job
        let queue = PlaylistWriteBack(fileURL: url, transport: transport)
        await queue.run()

        XCTAssertTrue(transport.resolveCalls.isEmpty)
        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.LIVE-SAP"])
        XCTAssertEqual(queue.resolvedPlaylistIds["pl_1"], "p.LIVE-SAP")
    }

    // MARK: Enqueue rules

    /// No `appleMusicId` ⇒ no such thing as adding it to an Apple Music playlist. A vinyl / My
    /// Digital / Studio song's add is purely local, and queueing it would only ever produce a
    /// job that can never be delivered and eventually shows the user a failure for nothing.
    func testSongWithoutAnAppleMusicIdentityIsNeverEnqueued() {
        let (queue, _) = makeQueue(StubTransport())

        XCTAssertNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                                   songId: "sng_vinyl", appleMusicId: nil))
        XCTAssertNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                                   songId: "sng_vinyl", appleMusicId: ""))
        XCTAssertNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                                   songId: "sng_vinyl", appleMusicId: "   "),
                     "whitespace is not an identity")
        XCTAssertNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "",
                                   songId: "s1", appleMusicId: "111"),
                     "and there is nothing to bootstrap the join from without a name")
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    /// De-dupe is on (playlist, song), because `MusicLibrary.add` is not idempotent: a
    /// double-tapped Add-to would otherwise put the song in the user's real playlist twice.
    func testEnqueueDeDupesOnPlaylistAndSong() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        let (queue, _) = makeQueue(transport)

        XCTAssertNotNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                                      songId: "s1", appleMusicId: "111"))
        XCTAssertNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                                   songId: "s1", appleMusicId: "111"),
                     "the same song into the same playlist is already owed")
        XCTAssertNotNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                                      songId: "s2", appleMusicId: "222"),
                        "a different song is a different write")
        XCTAssertNotNil(queue.enqueue(indexPlaylistId: "pl_2", playlistName: "Other",
                                      songId: "s1", appleMusicId: "111"),
                        "and so is the same song into a different playlist")
        XCTAssertEqual(queue.jobs.count, 3)

        // Delivered is just as de-duping as queued — the point is the upstream add, and it
        // has already happened.
        await queue.run()
        XCTAssertEqual(queue.jobs.first { $0.songId == "s1" && $0.indexPlaylistId == "pl_1" }?.state,
                       .delivered)
        XCTAssertNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                                   songId: "s1", appleMusicId: "111"))
        XCTAssertEqual(transport.writes.filter { $0.appleMusicId == "111" && $0.playlistId == "p.LIVE-SAP" }.count, 1)
    }

    // MARK: On-device catalog-id resolution

    /// A song our indexer never matched (no `appleMusicId`) is enqueued with its identity; the
    /// transport resolves the catalog id ON-DEVICE and the write goes out under the resolved id.
    func testIdentityOnlyJobResolvesCatalogIdOnDeviceAndDelivers() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        transport.catalogIds["The Magic Clap"] = "1620000000"   // on-device match
        let (queue, _) = makeQueue(transport)

        XCTAssertNotNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                                      songId: "sng_clap", appleMusicId: nil,
                                      title: "The Magic Clap", artist: "The Coup", durationMs: 192773))
        await queue.run()

        XCTAssertEqual(transport.resolveCatalogCalls.map(\.title), ["The Magic Clap"])
        XCTAssertEqual(transport.writes.map(\.appleMusicId), ["1620000000"])
        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.LIVE-SAP"])
        XCTAssertEqual(queue.jobs.first?.state, .delivered)
        XCTAssertFalse(queue.isUnsyncable("sng_clap"))
    }

    /// When Apple Music has no confident match, the job settles TERMINAL `.unresolvable` — no
    /// write, no retry, and `isUnsyncable` flips true so the collection row can flag it.
    func testUnresolvedIdentityJobSettlesUnresolvable() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"   // catalogIds is empty → no match
        let (queue, _) = makeQueue(transport)

        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                      songId: "sng_vinyl", appleMusicId: nil,
                      title: "Obscure B-side", artist: "Nobody", durationMs: 123000)
        await queue.run()

        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(queue.jobs.first?.state, .unresolvable)
        XCTAssertEqual(queue.jobs.first?.attempts, 1)
        XCTAssertTrue(queue.isUnsyncable("sng_vinyl"))

        // Terminal: a second drain neither re-searches nor writes.
        await queue.run()
        XCTAssertEqual(transport.resolveCatalogCalls.count, 1)
        XCTAssertTrue(transport.writes.isEmpty)
    }

    /// A TRANSIENT resolve failure (network/auth) is NOT terminal — the job stays queued to retry,
    /// exactly like an add failure. Only a nil RESULT means `.unresolvable`.
    func testTransientResolveFailureRetriesRatherThanUnresolvable() async throws {
        struct Boom: Error {}
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        transport.resolveError = Boom()
        let (queue, url) = makeQueue(transport)

        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ",
                      songId: "sng_x", appleMusicId: nil, title: "T", artist: "A")
        await queue.run()

        XCTAssertEqual(queue.jobs.first?.state, .queued)          // still owed, not terminal
        XCTAssertFalse(queue.isUnsyncable("sng_x"))
        XCTAssertTrue(transport.writes.isEmpty)

        // Recovers once the transient condition clears (clear the backoff so it's due again).
        transport.resolveError = nil
        transport.catalogIds["T"] = "999"
        try clearBackoff(queue, at: url)
        await queue.run()
        XCTAssertEqual(queue.jobs.first?.state, .delivered)
        XCTAssertEqual(transport.writes.map(\.appleMusicId), ["999"])
    }

    /// A song already settled `.unresolvable` is NOT re-enqueued by a repeat identity-only backfill
    /// (re-searching can't help) — the queue doesn't grow and no wasted search fires.
    func testUnresolvableBlocksIdentityOnlyReEnqueue() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"   // catalogIds empty → no match
        let (queue, _) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ", songId: "s1",
                      appleMusicId: nil, title: "T", artist: "A")
        await queue.run()
        XCTAssertEqual(queue.jobs.first?.state, .unresolvable)

        XCTAssertNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ", songId: "s1",
                                   appleMusicId: nil, title: "T", artist: "A"),
                     "an identity-only re-add of an unresolvable song queues nothing")
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(transport.resolveCatalogCalls.count, 1, "and does not re-hit the catalog")
        XCTAssertTrue(queue.isUnsyncable("s1"))
    }

    /// Once the catalog crawl DOES give the song a store id, a re-enqueue SUPERSEDES the stale
    /// unresolvable verdict → it delivers and `isUnsyncable` clears.
    func testCatalogIdSupersedesUnresolvableAndClearsBadge() async {
        let transport = StubTransport()
        transport.resolutions["Sap "] = "p.LIVE-SAP"
        let (queue, _) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ", songId: "s1",
                      appleMusicId: nil, title: "T", artist: "A")
        await queue.run()
        XCTAssertTrue(queue.isUnsyncable("s1"))

        XCTAssertNotNil(queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ", songId: "s1",
                                      appleMusicId: "111", title: "T", artist: "A"))
        await queue.run()
        XCTAssertEqual(transport.writes.map(\.appleMusicId), ["111"])
        XCTAssertEqual(queue.jobs.filter { $0.state == .unresolvable }.count, 0, "stale verdict dropped")
        XCTAssertFalse(queue.isUnsyncable("s1"))
    }

    /// `isUnsyncable` clears once the SAME song delivers via ANOTHER linked playlist, even though the
    /// first playlist's `.unresolvable` job persists (the badge must not lie across collections).
    func testIsUnsyncableClearsWhenSongDeliversElsewhere() async {
        let transport = StubTransport()
        transport.resolutions["A"] = "p.A"
        transport.resolutions["B"] = "p.B"
        let (queue, _) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_A", playlistName: "A", songId: "s1",
                      appleMusicId: nil, title: "T", artist: "Ar")   // unresolvable in A
        queue.enqueue(indexPlaylistId: "pl_B", playlistName: "B", songId: "s1", appleMusicId: "111") // delivers in B
        await queue.run()
        XCTAssertEqual(queue.jobs.first { $0.indexPlaylistId == "pl_A" }?.state, .unresolvable)
        XCTAssertEqual(queue.jobs.first { $0.indexPlaylistId == "pl_B" }?.state, .delivered)
        XCTAssertFalse(queue.isUnsyncable("s1"))
    }

    // MARK: Terminal failure

    /// An unresolvable playlist must SETTLE. `.failed` is a real destination: without it the
    /// job would re-resolve (an all-playlists fetch) on every launch for a playlist the user
    /// deleted months ago, forever.
    func testUnresolvablePlaylistSettlesFailedRatherThanRetryingForever() async throws {
        let transport = StubTransport()
        let (queue, url) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Gone",
                      songId: "s1", appleMusicId: "111")

        // Each pass burns one attempt and arms the backoff gate; clearing the gate on disk is
        // how the test fast-forwards wall-clock time without loosening the production rule.
        for _ in 0..<PlaylistWriteBack.maxAttempts {
            await queue.run()
            try clearBackoff(queue, at: url)
        }

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.attempts, PlaylistWriteBack.maxAttempts)
        XCTAssertEqual(job.lastError?.isEmpty, false, "a settled failure the user can act on says why")
        XCTAssertEqual(queue.lastError?.isEmpty, false)
        XCTAssertEqual(queue.failed.count, 1)
        XCTAssertTrue(queue.pending.isEmpty)

        // And it is genuinely done: further drains cost nothing at all.
        let resolvesAtRest = transport.resolveCalls.count
        await queue.run()
        await queue.run()
        XCTAssertEqual(transport.resolveCalls.count, resolvesAtRest,
                       "a failed job must not keep re-resolving on every drain")

        // An explicit user retry — "the playlist is back" — re-arms it, and it delivers.
        transport.resolutions["Gone"] = "p.BACK"
        queue.retryFailed()
        XCTAssertEqual(queue.jobs.first?.state, .queued)
        XCTAssertEqual(queue.jobs.first?.attempts, 0)
        await queue.run()
        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.BACK"])
        XCTAssertEqual(queue.jobs.first?.state, .delivered)
    }

    /// A playlist that is gone and STAYS gone re-resolves exactly once and then fails — the
    /// single retry inside an attempt must not become a loop.
    func testPersistentlyGonePlaylistReResolvesOnceThenFails() async throws {
        let transport = StubTransport()
        transport.resolutions["Sap"] = "p.OLD"
        let (queue, _) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap", songId: "s1", appleMusicId: "111")
        await queue.run()
        XCTAssertEqual(transport.resolveCalls.count, 1)

        transport.goneIds = ["p.OLD", "p.NEW"]
        transport.resolutions["Sap"] = "p.NEW"
        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap", songId: "s2", appleMusicId: "222")
        await queue.run()

        XCTAssertEqual(transport.resolveCalls.count, 2,
                       "the cached id is dropped and re-resolved ONCE, not repeatedly")
        XCTAssertEqual(transport.writes.count, 1, "no second write landed")
        let job = try XCTUnwrap(queue.jobs.last)
        XCTAssertEqual(job.state, .queued, "still retryable — one bad pass is not a verdict")
        XCTAssertEqual(job.attempts, 1)
        XCTAssertEqual(job.lastError?.contains("p.NEW"), true)
    }

    // MARK: Duplicate-name disambiguation (the transport contract)

    /// Several library playlists really do share a name, and only the tracks can tell them
    /// apart. This drives the queue against a fake library that implements the transport
    /// CONTRACT — tier the name, then prefer the candidate whose tracks overlap what the index
    /// says the playlist holds. It pins the contract end-to-end (the sample the queue supplies
    /// actually decides the answer, and the chosen id is what gets written); the production
    /// scorer's MusicKit half needs `Playlist.with([.tracks])` and a real account, so it is
    /// only reachable on device.
    func testDuplicateNamesAreDecidedByTrackOverlap() async {
        let transport = FakeLibraryTransport()
        transport.library = [
            .init(id: "p.WRONG", name: "Sap", trackIds: ["999", "998"]),
            .init(id: "p.RIGHT", name: "Sap", trackIds: ["1440817273", "42"])
        ]
        let (queue, _) = makeQueue(nil)
        queue.transport = transport
        queue.appleMusicIdsForIndexPlaylist = { _ in ["1440817273", "42", "7"] }

        queue.enqueue(indexPlaylistId: "pl_c0835ac9b919", playlistName: "Sap ",
                      songId: "sng_4f62fe9f7efb", appleMusicId: "1440817273")
        await queue.run()

        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.RIGHT"],
                       "the song lands in the playlist the index actually describes")
        XCTAssertNil(queue.jobs.first?.resolutionNote, "an arbitrated answer is not a guess")
    }

    /// Nothing to arbitrate with ⇒ the transport guesses, and the guess must be VISIBLE. A
    /// silent wrong join is the exact failure this whole change exists to end.
    func testAnUnarbitratedDuplicateIsRecordedAsAGuess() async {
        let transport = FakeLibraryTransport()
        transport.library = [
            .init(id: "p.FIRST", name: "Sap", trackIds: []),
            .init(id: "p.SECOND", name: "Sap", trackIds: [])
        ]
        let (queue, _) = makeQueue(nil)
        queue.transport = transport
        // No catalog seam wired ⇒ no expected ids ⇒ no overlap to score.

        queue.enqueue(indexPlaylistId: "pl_1", playlistName: "Sap ", songId: "s1", appleMusicId: "111")
        await queue.run()

        XCTAssertEqual(transport.writes.map(\.playlistId), ["p.FIRST"])
        XCTAssertEqual(queue.jobs.first?.resolutionNote?.contains("2"), true)
        XCTAssertEqual(queue.resolutionWarning, queue.jobs.first?.resolutionNote,
                       "and it reaches the queue's durable warning so Settings ▸ Apple Music can show it")
        XCTAssertNil(queue.lastError,
                     "a guess is not a failure — the write succeeded, so lastError stays clear")
    }

    // MARK: - Helpers

    /// Fast-forward the retry gate by stripping `nextAttemptAtMs` from the persisted document
    /// and re-decoding. Deliberately goes through the file rather than through a test hook: the
    /// backoff itself stays exactly as production writes it.
    private func clearBackoff(_ queue: PlaylistWriteBack, at url: URL) throws {
        let data = try Data(contentsOf: url)
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = doc["jobs"] as? [[String: Any]] ?? []
        for i in rows.indices { rows[i].removeValue(forKey: "nextAttemptAtMs") }
        doc["jobs"] = rows
        try JSONSerialization.data(withJSONObject: doc).write(to: url, options: .atomic)
        queue.reloadFromDisk()
    }

    // MARK: enqueueMany (the multi-select batch add path)

    private func item(_ songId: String, amId: String? = nil, title: String = "", artist: String = "",
                      playlist: String = "Mix", indexPlaylistId: String = "ipl") -> PlaylistWriteBack.EnqueueItem {
        PlaylistWriteBack.EnqueueItem(indexPlaylistId: indexPlaylistId, playlistName: playlist,
                                      songId: songId, appleMusicId: amId, title: title, artist: artist,
                                      album: nil, durationMs: nil)
    }

    /// `enqueueMany` mirrors `enqueue`'s per-item semantics — queued/delivered dedup,
    /// playlist-name and identity eligibility — plus in-batch dedup, with ONE save at the end.
    func testEnqueueManyDedupesAndFiltersLikeEnqueue() {
        let (queue, url) = makeQueue(nil)
        queue.enqueue(indexPlaylistId: "ipl", playlistName: "Mix", songId: "s1", appleMusicId: "am1")
        let queued = queue.enqueueMany([
            item("s1", amId: "am1"),                 // dup of the queued job → skipped
            item("s2", amId: "am2"),
            item("s2", amId: "am2"),                 // in-batch dup → skipped
            item("s3"),                              // no id, no identity → ineligible
            item("s4", amId: "am4", playlist: ""),   // empty playlist name → ineligible
            item("s5", title: "T", artist: "A"),     // identity-only → eligible
        ])
        XCTAssertEqual(queued, 2)
        XCTAssertEqual(queue.jobs.map(\.songId), ["s1", "s2", "s5"])
        XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .queued })
        // Persisted in the same document `enqueue` writes (one save for the whole batch).
        let reopened = PlaylistWriteBack(fileURL: url, transport: nil)
        XCTAssertEqual(reopened.jobs.map(\.songId), ["s1", "s2", "s5"])
    }

    /// The `.unresolvable` supersede rule carries over: a batch item that NOW has a real
    /// catalog id replaces the stale terminal verdict; one without stays rejected.
    func testEnqueueManySupersedesUnresolvableOnlyWithCatalogId() async {
        let transport = StubTransport()
        transport.resolutions["Mix"] = "p.MIX"       // catalogIds empty → identity resolves nil
        let (queue, _) = makeQueue(transport)
        queue.enqueue(indexPlaylistId: "ipl", playlistName: "Mix", songId: "s1", appleMusicId: nil,
                      title: "Obscure", artist: "Nobody")
        await queue.run()
        XCTAssertEqual(queue.jobs.first?.state, .unresolvable)

        XCTAssertEqual(queue.enqueueMany([item("s1", title: "Obscure", artist: "Nobody")]), 0)
        XCTAssertEqual(queue.jobs.count, 1)          // still just the terminal verdict

        XCTAssertEqual(queue.enqueueMany([item("s1", amId: "am_new")]), 1)
        XCTAssertEqual(queue.jobs.count, 1)          // stale verdict dropped, fresh job queued
        XCTAssertEqual(queue.jobs.first?.state, .queued)
        XCTAssertEqual(queue.jobs.first?.appleMusicId, "am_new")
    }

    /// A stand-in library that implements the transport contract the production MusicKit
    /// class implements against the real one: name matching in widening tiers (exact, then
    /// whitespace-trimmed, then case/diacritic-folded), then track overlap to break a tie,
    /// then "first, and say so".
    @MainActor
    private final class FakeLibraryTransport: PlaylistWriteBackTransport {
        struct Entry {
            let id: String
            let name: String
            let trackIds: [String]
        }

        var isSupported = true
        var canWrite = true
        private(set) var lastResolutionNote: String?
        var library: [Entry] = []
        private(set) var resolveCalls: [ResolveCall] = []
        private(set) var writes: [Write] = []

        func resolvePlaylistId(name: String, expectedAppleMusicIds: [String]) async throws -> String? {
            resolveCalls.append(ResolveCall(name: name, expected: expectedAppleMusicIds))
            lastResolutionNote = nil

            let candidates = Self.candidates(named: name, in: library)
            guard !candidates.isEmpty else { return nil }
            guard candidates.count > 1 else { return candidates[0].id }

            let expected = Set(expectedAppleMusicIds)
            var best = candidates[0]
            var bestOverlap = -1
            for candidate in candidates {
                let overlap = expected.isEmpty ? 0
                    : candidate.trackIds.filter(expected.contains).count
                if overlap > bestOverlap { best = candidate; bestOverlap = overlap }
            }
            if bestOverlap <= 0 {
                lastResolutionNote = "Your library has \(candidates.count) playlists named “\(name)” — "
                    + "PocketDJ picked the first one."
                best = candidates[0]
            }
            return best.id
        }

        func addSong(appleMusicId: String, toPlaylistId playlistId: String) async throws {
            guard library.contains(where: { $0.id == playlistId }) else {
                throw PlaylistWriteBackError.playlistGone(playlistId)
            }
            writes.append(Write(appleMusicId: appleMusicId, playlistId: playlistId))
        }

        static func candidates(named name: String, in library: [Entry]) -> [Entry] {
            let exact = library.filter { $0.name == name }
            if !exact.isEmpty { return exact }

            let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = library.filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == target
            }
            if !trimmed.isEmpty { return trimmed }

            let folded = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return library.filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
            }
        }
    }
}

#if canImport(MusicKit) && !os(macOS) && !targetEnvironment(macCatalyst)

/// The production name matcher itself — `MusicKitPlaylistWriteBackTransport.candidates(named:in:)`,
/// against real `MusicKit.Playlist` values.
///
/// This is where the bug was. "Sweet Thing" never reached Apple Music because the indexed name
/// is `"Sap "` (trailing space, straight out of Library.xml) and the live library playlist is
/// `"Sap"`, and the old join was `filter(matching: \.name, equalTo:)` — exact. The tiering below
/// is the fix, so it is tested against the SDK's own type rather than a re-implementation.
///
/// `MusicKit.Playlist` has no public initializer but is `Codable`, so the fixtures are decoded
/// from Apple Music resource JSON. If a future SDK stops accepting that shape the fixtures skip
/// rather than fail — a decode we can't perform is not a regression in our matcher.
@available(iOS 16.0, visionOS 1.0, *)
@MainActor
final class PlaylistWriteBackNameMatchingTests: XCTestCase {

    private func library(_ pairs: [(id: String, name: String)]) throws -> [MusicKit.Playlist] {
        let items: [MusicKit.Playlist] = pairs.compactMap { pair in
            let json = #"{"id":"\#(pair.id)","type":"library-playlists","attributes":{"name":"\#(pair.name)"}}"#
            return try? JSONDecoder().decode(MusicKit.Playlist.self, from: Data(json.utf8))
        }
        guard items.count == pairs.count,
              items.map(\.name) == pairs.map({ $0.name }),
              items.map(\.id.rawValue) == pairs.map({ $0.id }) else {
            throw XCTSkip("This SDK does not decode MusicKit.Playlist from resource JSON; the tiering is verified on device.")
        }
        return items
    }

    private func ids(_ playlists: [MusicKit.Playlist]) -> [String] {
        playlists.map(\.id.rawValue)
    }

    /// THE REGRESSION, exactly as it happened: index name `"Sap "`, library playlist `"Sap"`.
    /// Exact match found nothing and the job died silently. It must match now.
    func testTrailingSpaceInTheIndexedNameStillFindsTheLivePlaylist() throws {
        let all = try library([("p.OTHER", "Slaps"), ("p.SAP", "Sap")])
        let hit = MusicKitPlaylistWriteBackTransport.candidates(named: "Sap ", in: all)
        XCTAssertEqual(ids(hit), ["p.SAP"],
                       "“Sap ” from Library.xml is the same playlist as “Sap” in MusicKit")
    }

    /// Drift goes the other way too — the live name is what carries the stray whitespace.
    func testTrailingSpaceInTheLibraryNameAlsoMatches() throws {
        let all = try library([("p.SAP", "Sap ")])
        XCTAssertEqual(ids(MusicKitPlaylistWriteBackTransport.candidates(named: "Sap", in: all)),
                       ["p.SAP"])
    }

    /// Tier ordering: the tiers widen only as far as they must, so an EXACT name always beats a
    /// merely-trimmable one. Otherwise a user with both "Sap" and "Sap " would get a coin flip.
    func testExactNameBeatsATrimmedMatch() throws {
        let all = try library([("p.TRIMMABLE", "Sap "), ("p.EXACT", "Sap")])
        XCTAssertEqual(ids(MusicKitPlaylistWriteBackTransport.candidates(named: "Sap", in: all)),
                       ["p.EXACT"], "the exact tier matched, so the trimmed tier is never consulted")

        // And symmetrically, with the space in the query.
        XCTAssertEqual(ids(MusicKitPlaylistWriteBackTransport.candidates(named: "Sap ", in: all)),
                       ["p.TRIMMABLE"])
    }

    /// Likewise the trimmed tier beats the folded one: a same-case match is not thrown in with
    /// the case-insensitive crowd.
    func testTrimmedMatchBeatsACaseFoldedOne() throws {
        let all = try library([("p.CASE", "SAP"), ("p.TRIMMED", "Sap ")])
        XCTAssertEqual(ids(MusicKitPlaylistWriteBackTransport.candidates(named: "Sap", in: all)),
                       ["p.TRIMMED"])
    }

    /// The widest tier, for the rest of the drift between Library.xml and MusicKit.
    func testCaseAndDiacriticDriftStillMatches() throws {
        let all = try library([("p.CAFE", " Café Sessions ")])
        XCTAssertEqual(ids(MusicKitPlaylistWriteBackTransport.candidates(named: "cafe sessions", in: all)),
                       ["p.CAFE"])
    }

    /// Genuinely different playlists must NOT be collapsed together — the fuzziness buys a lost
    /// song back, and must not cost a wrongly-placed one.
    func testUnrelatedNamesDoNotMatch() throws {
        let all = try library([("p.A", "Slaps"), ("p.B", "Sappy"), ("p.C", "Sap Vol. 2")])
        XCTAssertTrue(MusicKitPlaylistWriteBackTransport.candidates(named: "Sap ", in: all).isEmpty,
                      "no candidate ⇒ resolve returns nil ⇒ the job reports an actionable error")
    }

    /// Duplicate names all reach the overlap scorer rather than being silently narrowed to one:
    /// the tie is broken by tracks (verified end-to-end against the fake library in
    /// `PlaylistWriteBackTests`), never by candidate order alone.
    func testAllSameNameCandidatesSurviveForDisambiguation() throws {
        let all = try library([("p.1", "Sap"), ("p.OTHER", "Slaps"), ("p.2", "Sap ")])
        XCTAssertEqual(ids(MusicKitPlaylistWriteBackTransport.candidates(named: "Sap ", in: all)),
                       ["p.2"], "the exact-on-trailing-space one wins its tier outright")
        XCTAssertEqual(Set(ids(MusicKitPlaylistWriteBackTransport.candidates(named: "sap", in: all))),
                       ["p.1", "p.2"], "and a folded query hands BOTH to the scorer")
    }
}

#endif

/// The on-device catalog MATCH decision (`WriteBackMatcher`) — pure, so it runs with no account.
/// These lock the wrong-add safeguards that the adversarial review flagged: never substitute a
/// version/part sibling or the base master, never accept a substring-artist match without
/// corroboration, honor the duration guard, refuse ambiguous ties, and resolve deterministically.
final class WriteBackMatcherTests: XCTestCase {
    private func song(_ title: String, _ artist: String, album: String? = nil, ms: Int? = nil) -> WriteBackSong {
        WriteBackSong(appleMusicId: "", title: title, artist: artist, album: album, durationMs: ms)
    }
    private func cand(_ id: String, _ title: String, _ artist: String,
                      album: String? = nil, sec: Double? = nil) -> WriteBackCatalogCandidate {
        WriteBackCatalogCandidate(id: id, title: title, artist: artist, album: album, durationSec: sec)
    }

    /// The core good case: exact normalized title + artist resolves even with no duration — this is
    /// "The Magic Clap" by The Coup, the very song this whole feature exists to push.
    func testExactTitleAndArtistMatchesWithoutDuration() {
        XCTAssertEqual(
            WriteBackMatcher.bestMatch(for: song("The Magic Clap", "The Coup"),
                                       among: [cand("100", "The Magic Clap", "The Coup")]),
            "100")
    }

    /// A version-marked title resolves to the SAME version, never the base master (the
    /// "Love Story (Taylor's Version)" → 2008 original trap).
    func testVersionMarkedTitlePicksTheMatchingVersionNotTheBaseMaster() {
        XCTAssertEqual(
            WriteBackMatcher.bestMatch(
                for: song("Love Story (Taylor's Version)", "Taylor Swift", ms: 235000),
                among: [cand("orig", "Love Story", "Taylor Swift", sec: 235),
                        cand("tv", "Love Story (Taylor's Version)", "Taylor Swift", sec: 235)]),
            "tv")
    }

    /// A plain title must NOT be satisfied by an unwanted live/remix variant when nothing (duration
    /// or album) corroborates that it's actually the user's recording.
    func testPlainTitleWontSubstituteAnUnwantedVariantWithoutCorroboration() {
        XCTAssertNil(
            WriteBackMatcher.bestMatch(
                for: song("The Magic Clap", "The Coup", ms: 193000),
                among: [cand("live", "The Magic Clap (Live)", "The Coup", sec: nil)]))
    }

    /// A DIFFERENT artist whose name merely contains the user's (Prince → Prince Royce) is rejected
    /// when there's no duration/album to confirm it — never add the wrong artist's song.
    func testSubstringArtistWithoutCorroborationIsRejected() {
        XCTAssertNil(
            WriteBackMatcher.bestMatch(for: song("Angel", "Prince"),
                                       among: [cand("royce", "Angel", "Prince Royce")]))
    }

    /// But genuine "feat."/"&" artist drift IS accepted when the duration confirms the recording.
    func testSubstringArtistAcceptedWhenDurationCorroborates() {
        XCTAssertEqual(
            WriteBackMatcher.bestMatch(for: song("Song", "Jay-Z", ms: 200000),
                                       among: [cand("x", "Song", "Jay-Z & Kanye West", sec: 201)]),
            "x")
    }

    /// A >12 s length gap means a different recording — rejected even with an exact artist.
    func testDurationGapBeyondToleranceIsRejected() {
        XCTAssertNil(
            WriteBackMatcher.bestMatch(for: song("Intro", "Band", ms: 60000),
                                       among: [cand("x", "Intro", "Band", sec: 200)]))
    }

    /// A top score tied across DISTINCT artists is ambiguous → refuse to guess (return nil).
    func testAmbiguousTieAcrossDistinctArtistsRefusesToGuess() {
        XCTAssertNil(
            WriteBackMatcher.bestMatch(
                for: song("Home", "X", ms: 200000),
                among: [cand("a", "Home", "X Ambassadors", sec: 200),
                        cand("b", "Home", "X Factor", sec: 200)]))
    }

    /// Same recording, two editions of the SAME artist → deterministic pick (stable min id),
    /// regardless of candidate order, so a re-resolve can't diverge into a duplicate add.
    func testDeterministicStableIdAmongSameArtistEditions() {
        let cands = [cand("z9", "Track", "Artist", sec: 180),
                     cand("a1", "Track", "Artist", sec: 180)]
        let s = song("Track", "Artist", ms: 180000)
        XCTAssertEqual(WriteBackMatcher.bestMatch(for: s, among: cands), "a1")
        XCTAssertEqual(WriteBackMatcher.bestMatch(for: s, among: cands.reversed()), "a1")
    }

    /// Nothing in the catalog → nil (settles `.unresolvable`), and a degenerate empty identity is
    /// never a match.
    func testNoCandidatesOrEmptyIdentityYieldsNil() {
        XCTAssertNil(WriteBackMatcher.bestMatch(for: song("X", "Y"), among: []))
        XCTAssertNil(WriteBackMatcher.bestMatch(for: song("", ""), among: [cand("1", "", "")]))
    }
}
