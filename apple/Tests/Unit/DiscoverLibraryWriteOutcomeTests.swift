import XCTest
@testable import PocketDJ

/// The Apple Music LIBRARY-WRITE outcome of a Discover "＋ Add" — the four-albums fix.
///
/// BUG (Levi, device, 2026-08-07): four New-tile album adds ("Summer of Love", "Paradise
/// - EP", "Whatchu Bringing?", "LIMBO - EP") each logged a History event reading
/// "Added … to your library" while none of them ever reached his Apple Music library.
/// `discoverAddAlbum` gated the write on `canAddToLibrary` (a silent SKIP) and swallowed
/// its throw with `try?` (a silent FAILURE), then recorded provisional entries + the
/// History event unconditionally — and even a write that returned was never CONFIRMED
/// against the library. Three silent failure modes, one lying event.
///
/// These tests pin the truthful pipeline: write → outcome (skipped/failed/unconfirmed/
/// confirmed) → provisional entry token → History wording → retry gate.
@MainActor
final class DiscoverLibraryWriteOutcomeTests: XCTestCase {

    // MARK: scaffolding

    /// A contributor whose write behavior is scriptable per test: confirm, return
    /// unconfirmed (add returned but the membership probe found nothing), report the
    /// web-API fallback's 202 (native threw, web accepted), or throw.
    @MainActor private final class WriteStub: MusicLibraryContributor {
        enum Behavior { case confirm, unconfirmed, webAccepted, throwError(Error) }
        var behavior: Behavior = .confirm
        var canAdd = true
        var tracks: [AppleMusicSongRow] = []
        private(set) var albumWrites: [String] = []
        private(set) var songWrites: [String] = []
        var kind: StreamingProviderKind { .appleMusic }
        var canContribute: Bool { true }
        var canAddToLibrary: Bool { canAdd }
        func resolveForLibrary(storeID: String?, title: String?, artist: String?) async -> AppleMusicResolution? { nil }
        @discardableResult
        func addSongToLibrary(storeID: String) async throws -> AppleMusicLibraryAddResult {
            songWrites.append(storeID); return try outcome()
        }
        @discardableResult
        func addAlbumToLibrary(storeID: String) async throws -> AppleMusicLibraryAddResult {
            albumWrites.append(storeID); return try outcome()
        }
        func albumTracks(albumStoreID: String) async -> [AppleMusicSongRow] { tracks }
        private func outcome() throws -> AppleMusicLibraryAddResult {
            switch behavior {
            case .confirm: return .confirmed
            case .unconfirmed: return .unconfirmed
            case .webAccepted: return .webAccepted
            case .throwError(let e): throw e
            }
        }
    }

    /// SERVERLESS store on purpose: no import server means no network at all on these
    /// paths (`requestRip` short-circuits to `.noServer`, the `/album-tracks` proxy is
    /// never consulted because the stub expands the tracks), so the ONLY variable in
    /// every test is the library write.
    private func makeServerlessStore() -> RipsStore {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = ""
        rips.settings = settings
        return rips
    }

    private func makeAdds() -> DiscoverAddsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-lwo-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return DiscoverAddsStore(fileURL: url)
    }

    private var albumHit: RipsStore.DiscoverAlbumHit {
        RipsStore.DiscoverAlbumHit(appleMusicId: "111", albumId: "amrec_album_111",
                                   title: "Summer of Love", artist: "Teddy Pendergrass")
    }

    private func row(_ id: String, _ title: String) -> AppleMusicSongRow {
        AppleMusicSongRow(storeID: id, title: title, artist: "Teddy Pendergrass",
                          albumTitle: "Summer of Love", trackNumber: nil, year: nil,
                          durationSeconds: 200, isExplicit: nil, artworkURL: nil)
    }

    // MARK: album add — the four failure modes become four distinct truths

    /// THE BUG, mode 2: the write THROWS → the outcome is `.failed` with the reason, the
    /// History event carries the annotation (never "to your library"), and the provisional
    /// add still lands in full — an Apple Music failure must not cost the in-app add.
    func testAlbumAddThrowingWriteRecordsFailureButStillAddsProvisionally() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        var logged: [(ids: [String], token: String?)] = []
        adds.onUserCatalogAdd = { items, token in logged.append((items.map(\.id), token)) }
        let lib = WriteStub()
        lib.tracks = [row("1", "T1"), row("2", "T2")]
        lib.behavior = .throwError(StreamingError.notLinked)

        let outcome = await rips.discoverAddAlbum(albumHit, library: lib, intent: .libraryOnly)

        guard case let .failed(reason) = outcome else {
            return XCTFail("a thrown write must be .failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("Sign in"), "the throw's reason survives: \(reason)")
        // Provisional add unharmed: album + both tracks recorded.
        XCTAssertEqual(adds.albums.map(\.albumId), ["amrec_album_111"])
        XCTAssertEqual(adds.entries.map(\.songId).sorted(), ["amrec_1", "amrec_2"])
        // The outcome is stamped on the entry (the retry gate reads it)…
        let token = adds.albums.first?.libraryWrite
        XCTAssertEqual(token, outcome.storageToken)
        XCTAssertTrue(token?.hasPrefix("Apple Music write failed:") == true, "\(token ?? "nil")")
        // …and rides the History event, whose wording stops lying.
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged[0].token, token)
        let headline = CollectionActivityStore.catalogAddHeadline(item: "“Summer of Love”",
                                                                  libraryWrite: logged[0].token)
        XCTAssertFalse(headline.contains("to your library"),
                       "a failed write must NEVER read as a library add: \(headline)")
        XCTAssertTrue(headline.contains("Added “Summer of Love” to PocketDJ"), headline)
        XCTAssertTrue(headline.contains("Apple Music write failed:"), headline)
        // Surfaced at the point of the tap.
        XCTAssertTrue(rips.discoverError?.contains("Apple Music library add failed") == true,
                      "\(rips.discoverError ?? "nil")")
    }

    /// THE BUG, mode 1 (nil contributor): the write is SKIPPED — recorded as such, with the
    /// provisional add intact and NO error surfaced (a caller that passes no library opted
    /// out of the write on purpose; tests and no-AM platforms do this).
    func testNilContributorIsSkippedQuietlyButRecordedTruthfully() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        // Exercised through the SONG-level add: with no library there is no MusicKit album
        // expansion (and no proxy in a serverless store), so the album flow would exit on
        // the expansion error before the part under test. Skip semantics are shared.
        let hit = RipsStore.DiscoverHit(appleMusicId: "9", title: "T", artist: "A", songId: "amrec_9")
        let outcome = await rips.discoverAdd(hit, library: nil)

        guard case let .skipped(reason) = outcome else {
            return XCTFail("nil contributor must be .skipped, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no Apple Music connection"), reason)
        XCTAssertEqual(adds.entries.map(\.songId), ["amrec_9"], "the in-app add still lands")
        XCTAssertEqual(adds.entries.first?.libraryWrite, outcome.storageToken)
        XCTAssertNil(rips.discoverError, "an opted-out write is not the user's problem")
        // But History still tells the truth about what did NOT happen.
        let headline = CollectionActivityStore.catalogAddHeadline(
            item: "“T”", libraryWrite: adds.entries.first?.libraryWrite)
        XCTAssertFalse(headline.contains("to your library"), headline)
    }

    /// THE BUG, mode 1 (unauthorized device — the most plausible read of Levi's device):
    /// a contributor is passed but cannot add → skipped, AND surfaced with the actionable
    /// auth message, because the user expected the write.
    func testAlbumAddUnauthorizedContributorSkipsAndSurfacesActionableError() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        let lib = WriteStub()
        lib.canAdd = false                      // iOS: canAddToLibrary == authorized session
        lib.tracks = [row("1", "T1")]

        let outcome = await rips.discoverAddAlbum(albumHit, library: lib, intent: .libraryOnly)

        guard case let .skipped(reason) = outcome else {
            return XCTFail("unauthorized must be .skipped, got \(outcome)")
        }
        XCTAssertTrue(lib.albumWrites.isEmpty, "no write may be attempted unauthorized")
        XCTAssertTrue(reason.contains("authorized"), reason)
        XCTAssertEqual(adds.albums.first?.libraryWrite, outcome.storageToken)
        XCTAssertTrue(rips.discoverError?.contains("authorized") == true,
                      "the tap must surface the auth heal: \(rips.discoverError ?? "nil")")
        XCTAssertTrue(rips.discoverError?.contains("Settings") == true,
                      "\(rips.discoverError ?? "nil")")
    }

    /// SUCCESS: the write returns AND the membership probe confirms → "confirmed" token,
    /// classic History wording, no error.
    func testAlbumAddConfirmedWriteKeepsClassicLibraryWording() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        var loggedToken: String? = "sentinel"
        adds.onUserCatalogAdd = { _, token in loggedToken = token }
        let lib = WriteStub()
        lib.tracks = [row("1", "T1")]

        let outcome = await rips.discoverAddAlbum(albumHit, library: lib, intent: .libraryOnly)

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(lib.albumWrites, ["111"])
        XCTAssertEqual(adds.albums.first?.libraryWrite, "confirmed")
        XCTAssertEqual(loggedToken, "confirmed")
        XCTAssertEqual(CollectionActivityStore.catalogAddHeadline(item: "“Summer of Love”",
                                                                  libraryWrite: loggedToken),
                       "Added “Summer of Love” to your library")
        XCTAssertNil(rips.discoverError)
    }

    /// THE BUG, mode 3's sharpest edge: the write RETURNS but the confirmation probe cannot
    /// find the album → NOT recorded as success anywhere (outcome, token, History, error).
    func testAlbumAddUnconfirmedWriteIsNotRecordedAsSuccess() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        let lib = WriteStub()
        lib.behavior = .unconfirmed
        lib.tracks = [row("1", "T1")]

        let outcome = await rips.discoverAddAlbum(albumHit, library: lib, intent: .libraryOnly)

        XCTAssertEqual(outcome, .unconfirmed)
        XCTAssertEqual(lib.albumWrites, ["111"], "the write WAS attempted")
        let token = adds.albums.first?.libraryWrite
        XCTAssertNotEqual(token, "confirmed")
        XCTAssertFalse(AppleMusicLibraryWriteOutcome.provenByToken(token))
        let headline = CollectionActivityStore.catalogAddHeadline(item: "“Summer of Love”",
                                                                  libraryWrite: token)
        XCTAssertFalse(headline.contains("to your library"),
                       "an unproven write must not read as a library add: \(headline)")
        XCTAssertTrue(rips.discoverError?.contains("hasn’t appeared") == true,
                      "\(rips.discoverError ?? "nil")")
        // Provisional add intact regardless.
        XCTAssertEqual(adds.entries.map(\.songId), ["amrec_1"])
    }

    // MARK: song-level twin (discoverAdd had the identical `try?` shape)

    func testSongAddThrowingWriteRecordsFailedTokenOnEntry() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        var loggedToken: String?
        adds.onUserCatalogAdd = { _, token in loggedToken = token }
        let lib = WriteStub()
        lib.behavior = .throwError(StreamingError.notLinked)
        let hit = RipsStore.DiscoverHit(appleMusicId: "5", title: "T", artist: "A", songId: "amrec_5")

        let outcome = await rips.discoverAdd(hit, library: lib)

        guard case .failed = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(lib.songWrites, ["5"])
        XCTAssertEqual(adds.entries.map(\.songId), ["amrec_5"], "provisional add survives")
        XCTAssertEqual(adds.entries.first?.libraryWrite, outcome.storageToken)
        XCTAssertTrue(loggedToken?.hasPrefix("Apple Music write failed:") == true, "\(loggedToken ?? "nil")")
        XCTAssertNotNil(rips.discoverError)
    }

    // MARK: retry — the heal for failed/skipped/legacy album writes

    /// A recorded failure retried successfully flips the stored token to "confirmed" and
    /// logs ONE truthful "Added … to your library" event (append-only log: the original
    /// annotated event remains the record of the failure).
    func testRetryAlbumLibraryWriteHealsAndLogsConfirmed() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        adds.addAlbum(albumId: "amrec_album_111", appleMusicId: "111",
                      title: "Summer of Love", artist: "Teddy Pendergrass",
                      libraryWrite: "Apple Music write failed: boom")
        var logged: [(ids: [String], token: String?)] = []
        adds.onUserCatalogAdd = { items, token in logged.append((items.map(\.id), token)) }
        let lib = WriteStub()

        let outcome = await rips.retryAlbumLibraryWrite(albumId: "amrec_album_111",
                                                        appleMusicId: "111", library: lib)

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(lib.albumWrites, ["111"])
        XCTAssertEqual(adds.albums.first?.libraryWrite, "confirmed")
        XCTAssertEqual(logged.count, 1, "exactly one heal event")
        XCTAssertEqual(logged[0].ids, ["amrec_album_111"])
        XCTAssertEqual(logged[0].token, "confirmed")
        XCTAssertNil(rips.discoverError)
    }

    /// A LEGACY entry (nil token — recorded before outcomes existed: Levi's four albums)
    /// is retryable, and a confirmed retry logs the heal exactly like a recorded failure.
    func testRetryLegacyNilTokenAlbumHealsToo() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        adds.addAlbum(albumId: "amrec_album_111", appleMusicId: "111",
                      title: "LIMBO - EP", artist: "Arin Ray")   // nil libraryWrite = legacy
        var healEvents = 0
        adds.onUserCatalogAdd = { _, token in if token == "confirmed" { healEvents += 1 } }

        let outcome = await rips.retryAlbumLibraryWrite(albumId: "amrec_album_111",
                                                        appleMusicId: "111", library: WriteStub())

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(adds.albums.first?.libraryWrite, "confirmed")
        XCTAssertEqual(healEvents, 1)
    }

    /// A retry that fails again updates the stored annotation and logs NOTHING (no heal
    /// happened), so History never gains a success event for a write that didn't land.
    func testRetryFailureUpdatesAnnotationWithoutLoggingSuccess() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        adds.addAlbum(albumId: "amrec_album_111", appleMusicId: "111",
                      title: "Paradise - EP", artist: "Elaquent",
                      libraryWrite: "Apple Music write skipped: Apple Music access isn’t authorized — enable it in Settings")
        var logged = 0
        adds.onUserCatalogAdd = { _, _ in logged += 1 }
        let lib = WriteStub()
        lib.behavior = .throwError(StreamingError.notLinked)

        let outcome = await rips.retryAlbumLibraryWrite(albumId: "amrec_album_111",
                                                        appleMusicId: "111", library: lib)

        guard case .failed = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(adds.albums.first?.libraryWrite?.hasPrefix("Apple Music write failed:") == true)
        XCTAssertEqual(logged, 0, "no heal event for a write that didn't land")
        XCTAssertNotNil(rips.discoverError)
    }

    // MARK: the pure gates + vocabulary

    /// The retry gate: owed for every un-PROVEN token (failure, skip, unconfirmed, legacy
    /// nil) — but only where the device can write the library at all.
    func testNeedsRetryGate() {
        XCTAssertTrue(AlbumLibraryWriteRetry.needsRetry(token: nil, canAddToLibrary: true),
                      "legacy entries (the four albums) must be retryable")
        XCTAssertTrue(AlbumLibraryWriteRetry.needsRetry(token: "Apple Music write failed: x",
                                                        canAddToLibrary: true))
        XCTAssertTrue(AlbumLibraryWriteRetry.needsRetry(
            token: AppleMusicLibraryWriteOutcome.unconfirmed.storageToken, canAddToLibrary: true))
        XCTAssertFalse(AlbumLibraryWriteRetry.needsRetry(token: "confirmed", canAddToLibrary: true),
                       "a PROVEN write owes no retry")
        XCTAssertFalse(AlbumLibraryWriteRetry.needsRetry(token: nil, canAddToLibrary: false),
                       "a device that can't write offers no dead button")
    }

    /// The History vocabulary in one place: classic wording ONLY for legacy-nil and
    /// confirmed; every other token is quoted as the qualifier.
    func testCatalogAddHeadlineVocabulary() {
        XCTAssertEqual(CollectionActivityStore.catalogAddHeadline(item: "“X”", libraryWrite: nil),
                       "Added “X” to your library", "legacy events keep their wording")
        XCTAssertEqual(CollectionActivityStore.catalogAddHeadline(item: "“X”", libraryWrite: "confirmed"),
                       "Added “X” to your library")
        XCTAssertEqual(
            CollectionActivityStore.catalogAddHeadline(
                item: "“X”", libraryWrite: "Apple Music write failed: boom"),
            "Added “X” to PocketDJ (Apple Music write failed: boom)")
    }

    /// Outcome → token mapping (what gets persisted + rendered).
    func testOutcomeStorageTokens() {
        XCTAssertEqual(AppleMusicLibraryWriteOutcome.confirmed.storageToken, "confirmed")
        XCTAssertEqual(AppleMusicLibraryWriteOutcome.failed(reason: "boom").storageToken,
                       "Apple Music write failed: boom")
        XCTAssertEqual(AppleMusicLibraryWriteOutcome.skipped(reason: "no Apple Music connection").storageToken,
                       "Apple Music write skipped: no Apple Music connection")
        XCTAssertTrue(AppleMusicLibraryWriteOutcome.unconfirmed.storageToken.contains("unconfirmed"))
        XCTAssertTrue(AppleMusicLibraryWriteOutcome.provenByToken("confirmed"))
        XCTAssertFalse(AppleMusicLibraryWriteOutcome.provenByToken(nil))
        XCTAssertFalse(AppleMusicLibraryWriteOutcome.provenByToken("Apple Music write failed: x"))
    }

    // MARK: persistence — the annotation must survive the activity log round trip

    func testActivityEventLibraryWriteSurvivesReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-lwo-act-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = CollectionActivityStore(fileURL: url)
        store.record(kind: .catalogAdd, itemId: "amrec_album_111", itemTitle: "Summer of Love",
                     libraryWrite: "Apple Music write failed: boom")
        store.record(kind: .catalogAdd, itemId: "amrec_album_222", itemTitle: "Whatchu Bringing?",
                     libraryWrite: "confirmed")

        let reloaded = CollectionActivityStore(fileURL: url)
        XCTAssertEqual(reloaded.events.count, 2)
        XCTAssertEqual(reloaded.events[0].libraryWrite, "Apple Music write failed: boom")
        XCTAssertEqual(reloaded.events[1].libraryWrite, "confirmed")
        // …and the provisional store round-trips its token the same way.
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-lwo-adds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        adds.addAlbum(albumId: "amrec_album_111", appleMusicId: "111", title: "T", artist: "A",
                      libraryWrite: "Apple Music write skipped: no Apple Music connection")
        let reloadedAdds = DiscoverAddsStore(fileURL: addsURL)
        XCTAssertEqual(reloadedAdds.albums.first?.libraryWrite,
                       "Apple Music write skipped: no Apple Music connection")
    }
}

// MARK: - Failure detail carries the NSError identity (fix/am-write-error-detail)

extension DiscoverLibraryWriteOutcomeTests {
    /// MusicKit's genericized "An unknown error occurred." must arrive with the
    /// domain#code chain appended, or the surfaced reason cannot distinguish
    /// Sync-Library-off from a token or storefront failure.
    func testFailureDetailAppendsDomainCodeChain() {
        let underlying = NSError(domain: "ICError", code: -7013)
        let outer = NSError(domain: "MPErrorDomain", code: 4,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        let detail = RipsStore.libraryWriteFailureDetail(outer)
        XCTAssertTrue(detail.contains("MPErrorDomain#4"), detail)
        XCTAssertTrue(detail.contains("ICError#-7013"), detail)
        XCTAssertTrue(detail.contains("←"), detail)
    }

    func testFailureDetailSurvivesAPlainSwiftError() {
        struct Bare: Error {}
        let detail = RipsStore.libraryWriteFailureDetail(Bare())
        // A bridged Swift error still yields a domain#code; the sentence stays first.
        XCTAssertTrue(detail.contains("#"), detail)
        XCTAssertFalse(detail.hasPrefix("["), detail)
    }
}

// MARK: - Web-API fallback (fix/am-add-web-fallback)
//
// BUG (Levi, device, 2026-08-07, iOS 27.0 beta 24A5390f): Retry on two ordinary catalog
// albums (LIMBO - EP, Summer of Love) failed with MPErrorDomain#0 — no underlying chain,
// auth granted, Sync Library on. `MusicLibrary.add` is broken in the beta, so the add
// falls back to the Apple Music web API: POST /v1/me/library?ids[albums]=… (documented
// success: HTTP 202 Accepted, empty body). These tests pin the fallback runner and the
// outcome semantics: a web 202 IS "Added to your library" (token records the route), a
// double failure carries BOTH reasons, and a healthy native add never touches the web.
extension DiscoverLibraryWriteOutcomeTests {

    /// Scripted `AppleMusicWebSender` (mirrors `WebAPIPlaylistWriteBackTests.FakeSender`).
    @MainActor private final class FakeWebSender: AppleMusicWebSender {
        var canSend = true
        var reply: (status: Int, body: Data) = (202, Data())
        var thrown: Error?
        private(set) var sent: [URLRequest] = []
        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            sent.append(request)
            if let thrown { throw thrown }
            return (reply.body, reply.status)
        }
    }

    private static let betaError = NSError(domain: "MPErrorDomain", code: 0,
                                           userInfo: [NSLocalizedDescriptionKey: "An unknown error occurred."])

    /// Native throw + web 202 → `.webAccepted`, and the request is the documented shape:
    /// POST /v1/me/library?ids[albums]=<storeId>. The post-202 probe runs for the LOG but
    /// its miss (scripted false here — sync lag) must not downgrade the accepted write.
    func testAlbumFallbackNativeThrowWeb202IsAcceptedDespiteProbeMiss() async throws {
        let sender = FakeWebSender()
        var diag: [String] = []

        let result = try await AppleMusicLibraryAddFallback.run(
            kind: .albums, storeID: "1786412392", sender: sender, diag: { diag.append($0) },
            native: { throw Self.betaError },
            probe: { false })

        XCTAssertEqual(result, .webAccepted)
        XCTAssertEqual(sender.sent.count, 1)
        let req = try XCTUnwrap(sender.sent.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1/me/library")
        let items = URLComponents(url: try XCTUnwrap(req.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items, [URLQueryItem(name: "ids[albums]", value: "1786412392")])
        // The debug-session story names the route and the store id.
        XCTAssertTrue(diag.contains { $0.contains("MPErrorDomain#0") && $0.contains("1786412392") },
                      "\(diag)")
        XCTAssertTrue(diag.contains { $0.contains("202") }, "\(diag)")
        XCTAssertTrue(diag.contains { $0.contains("cloud add stands") },
                      "the probe miss is logged, never a downgrade: \(diag)")
    }

    /// Song flavor: `ids[songs]`, same contract.
    func testSongFallbackNativeThrowWeb202UsesSongsKey() async throws {
        let sender = FakeWebSender()

        let result = try await AppleMusicLibraryAddFallback.run(
            kind: .songs, storeID: "555", sender: sender, diag: { _ in },
            native: { throw Self.betaError },
            probe: { true })

        XCTAssertEqual(result, .webAccepted)
        let items = URLComponents(url: try XCTUnwrap(sender.sent.first?.url),
                                  resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items, [URLQueryItem(name: "ids[songs]", value: "555")])
    }

    /// Native throw + web failure → the thrown error carries BOTH identities: the native
    /// domain#code chain (via `libraryWriteFailureDetail`) AND the web status/body summary.
    func testFallbackDoubleFailureCarriesNativeChainAndWebStatusBody() async {
        let sender = FakeWebSender()
        sender.reply = (500, Data(#"{"errors":[{"title":"Upstream Service Error"}]}"#.utf8))

        do {
            _ = try await AppleMusicLibraryAddFallback.run(
                kind: .albums, storeID: "111", sender: sender, diag: { _ in },
                native: { throw Self.betaError },
                probe: { true })
            XCTFail("a double failure must throw")
        } catch {
            let detail = RipsStore.libraryWriteFailureDetail(error)
            XCTAssertTrue(detail.contains("MPErrorDomain#0"), "native identity survives: \(detail)")
            XCTAssertTrue(detail.contains("An unknown error occurred."), detail)
            XCTAssertTrue(detail.contains("HTTP 500"), "web status named: \(detail)")
            XCTAssertTrue(detail.contains("Upstream Service Error"), "web body named: \(detail)")
            XCTAssertTrue(detail.contains("\(AppleMusicLibraryAddFallback.webFallbackErrorDomain)#500"), detail)
        }
    }

    /// A web transport that THROWS (expired user token → `notAuthorized`) still yields a
    /// both-reasons failure, not a silent loss of the native identity.
    func testFallbackWebTransportThrowStillCarriesNativeChain() async {
        let sender = FakeWebSender()
        sender.thrown = PlaylistWriteBackError.notAuthorized

        do {
            _ = try await AppleMusicLibraryAddFallback.run(
                kind: .songs, storeID: "9", sender: sender, diag: { _ in },
                native: { throw Self.betaError },
                probe: { true })
            XCTFail("must throw")
        } catch {
            let detail = RipsStore.libraryWriteFailureDetail(error)
            XCTAssertTrue(detail.contains("MPErrorDomain#0"), detail)
            XCTAssertTrue(detail.contains("couldn’t send"), detail)
        }
    }

    /// A healthy native add NEVER consults the web API — the fallback must not change the
    /// working path (or double-add). Covers confirmed AND unconfirmed native results.
    func testFallbackNativeSuccessNeverCallsSender() async throws {
        let sender = FakeWebSender()

        let confirmed = try await AppleMusicLibraryAddFallback.run(
            kind: .albums, storeID: "1", sender: sender, diag: { _ in },
            native: { true }, probe: { true })
        XCTAssertEqual(confirmed, .confirmed)

        let unconfirmed = try await AppleMusicLibraryAddFallback.run(
            kind: .songs, storeID: "2", sender: sender, diag: { _ in },
            native: { false }, probe: { true })
        XCTAssertEqual(unconfirmed, .unconfirmed)

        XCTAssertTrue(sender.sent.isEmpty, "native success/unconfirmed must never reach the web")
    }

    // MARK: outcome semantics — a web 202 IS "Added to your library", route recorded

    /// Album add whose contributor reports `.webAccepted` → the outcome is CONFIRMED
    /// (web flavor): token "confirmed (web)", classic History wording, no error, no
    /// retry owed. The truthfulness contract is not weakened — a 202 from
    /// /v1/me/library is Apple accepting the add into the cloud library.
    func testAlbumAddWebAcceptedIsConfirmedWithRouteRecorded() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        var loggedToken: String? = "sentinel"
        adds.onUserCatalogAdd = { _, token in loggedToken = token }
        let lib = WriteStub()
        lib.behavior = .webAccepted
        lib.tracks = [row("1", "T1")]

        let outcome = await rips.discoverAddAlbum(albumHit, library: lib, intent: .libraryOnly)

        XCTAssertEqual(outcome, .confirmedWeb)
        XCTAssertTrue(outcome.isConfirmed)
        XCTAssertEqual(adds.albums.first?.libraryWrite, "confirmed (web)")
        XCTAssertEqual(loggedToken, "confirmed (web)")
        XCTAssertTrue(AppleMusicLibraryWriteOutcome.provenByToken("confirmed (web)"),
                      "a web-accepted write is PROVEN")
        XCTAssertEqual(CollectionActivityStore.catalogAddHeadline(item: "“Summer of Love”",
                                                                  libraryWrite: loggedToken),
                       "Added “Summer of Love” to your library",
                       "History asserts the library add — the web 202 IS that claim")
        XCTAssertFalse(AlbumLibraryWriteRetry.needsRetry(token: "confirmed (web)", canAddToLibrary: true),
                       "a proven write owes no retry")
        XCTAssertNil(rips.discoverError)
    }

    /// Song-level twin through `discoverAdd`.
    func testSongAddWebAcceptedRecordsWebTokenOnEntry() async {
        let rips = makeServerlessStore()
        let adds = makeAdds()
        rips.discoverAdds = adds
        let lib = WriteStub()
        lib.behavior = .webAccepted
        let hit = RipsStore.DiscoverHit(appleMusicId: "5", title: "T", artist: "A", songId: "amrec_5")

        let outcome = await rips.discoverAdd(hit, library: lib)

        XCTAssertEqual(outcome, .confirmedWeb)
        XCTAssertEqual(lib.songWrites, ["5"])
        XCTAssertEqual(adds.entries.first?.libraryWrite, "confirmed (web)")
        XCTAssertNil(rips.discoverError)
    }

    /// The vocabulary additions: distinct token, proven, no annotation, notice-free.
    func testConfirmedWebVocabulary() {
        XCTAssertEqual(AppleMusicLibraryWriteOutcome.confirmedWeb.storageToken, "confirmed (web)")
        XCTAssertNil(AppleMusicLibraryWriteOutcome.confirmedWeb.annotation)
        XCTAssertTrue(AppleMusicLibraryWriteOutcome.confirmedWeb.isConfirmed)
        XCTAssertNotEqual(AppleMusicLibraryWriteOutcome.confirmedWeb.storageToken,
                          AppleMusicLibraryWriteOutcome.confirmed.storageToken,
                          "the routes must stay distinguishable in a report")
        XCTAssertNil(RipsStore.libraryWriteNotice(.confirmedWeb, noun: "album"),
                     "a confirmed write surfaces no error")
    }
}
