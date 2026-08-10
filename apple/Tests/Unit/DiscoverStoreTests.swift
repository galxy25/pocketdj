import XCTest
@testable import PocketDJ

/// Browse ▸ Discover client plumbing (RipsStore):
///   • `discoverSearch` GETs the rip server's `/search` proxy (q + limit, bearer auth),
///     decodes the results envelope into `DiscoverHit`s (id = songId), and surfaces
///     failures via `discoverError` instead of throwing — a 401 must point the user at
///     Settings ▸ Rip server token.
///   • `discoverAdd` rides the EXISTING ad-hoc `/rip` path (`requestRip`), carrying the
///     `amrec_` songId + title/artist/appleMusicId/lengthMs so the server can synthesize
///     its ad-hoc catalog row; the queued job is recorded so the row shows progress.
///
/// A scriptable `URLProtocol` stands in for the server (no real network).
@MainActor
final class DiscoverStoreTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    override func setUp() {
        super.setUp()
        DiscoverURLProtocol.reset()
    }

    private func makeStore(serverURL: String = "https://imac.test", token: String = "tok") -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoverURLProtocol.self]
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = serverURL
        settings.ripToken = token
        rips.settings = settings
        return rips
    }

    // MARK: /search — request shape + DiscoverHit decoding

    func testDiscoverSearchDecodesHitsAndSendsAuthorizedGet() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/search"] = Data("""
        { "results": [
            { "appleMusicId": "123", "title": "Take On Me", "artist": "a-ha",
              "album": "Hunting High and Low", "artworkUrl": "https://art.test/123.jpg",
              "durationMs": 225000, "songId": "amrec_123", "ripped": false },
            { "appleMusicId": "456", "title": "Hunting High and Low", "artist": "a-ha",
              "durationMs": 0, "songId": "amrec_456", "ripped": true,
              "url": "https://rips.test/rips/amrec_456.mp3" }
          ] }
        """.utf8)

        let hits = await rips.discoverSearch("take on me", limit: 25)

        XCTAssertEqual(hits.count, 2)
        XCTAssertNil(rips.discoverError)
        // Identity = songId (the ad-hoc rip id), and the decoded fields round-trip.
        XCTAssertEqual(hits[0].id, "amrec_123")
        XCTAssertEqual(hits[0].appleMusicId, "123")
        XCTAssertEqual(hits[0].title, "Take On Me")
        XCTAssertEqual(hits[0].album, "Hunting High and Low")
        XCTAssertEqual(hits[0].artworkUrl, "https://art.test/123.jpg")
        XCTAssertEqual(hits[0].durationMs, 225000)
        XCTAssertEqual(hits[0].ripped, false)
        XCTAssertNil(hits[0].url)
        XCTAssertEqual(hits[1].ripped, true)
        XCTAssertEqual(hits[1].url, "https://rips.test/rips/amrec_456.mp3")
        XCTAssertNil(hits[1].album, "optional fields decode as nil when absent")
        // Request shape: GET /search?q=…&limit=… with the bearer token.
        let req = DiscoverURLProtocol.last(path: "/search")
        XCTAssertEqual(req?.httpMethod, "GET")
        let query = req?.url?.query ?? ""
        XCTAssertTrue(query.contains("q=take%20on%20me"), "query is percent-encoded: \(query)")
        XCTAssertTrue(query.contains("limit=25"))
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testDiscoverSearch401PointsAtToken() async {
        let rips = makeStore()
        DiscoverURLProtocol.statusCodeByPath["/search"] = 401
        let hits = await rips.discoverSearch("abba")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertTrue(rips.discoverError?.contains("token") == true,
                      "401 must mention the rip-server token: \(rips.discoverError ?? "nil")")
    }

    /// Serverless proxy search is a BENIGN SKIP (public-user audit fix): MusicKit covers Discover
    /// metadata search, so a missing rip server is NOT an error — it must not fire a /search
    /// request nor set discoverError (which would mask a genuine "No matches").
    func testDiscoverSearchNoServerIsBenignSkip() async {
        let rips = makeStore(serverURL: "")
        let hits = await rips.discoverSearch("abba")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertNil(rips.discoverError, "serverless proxy search is not an error")
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/search"), 0)
    }

    func testDiscoverSearchEmptyQueryNoRequest() async {
        let rips = makeStore()
        let hits = await rips.discoverSearch("   ")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertNil(rips.discoverError, "an empty query is a healthy no-op")
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/search"), 0)
    }

    /// A failed search sets the error; the next healthy search clears it.
    func testDiscoverSearchRecoversAfterFailure() async {
        let rips = makeStore()
        DiscoverURLProtocol.statusCodeByPath["/search"] = 500
        _ = await rips.discoverSearch("abba")
        XCTAssertNotNil(rips.discoverError)
        DiscoverURLProtocol.statusCodeByPath["/search"] = 200
        DiscoverURLProtocol.bodyByPath["/search"] = Data(#"{ "results": [] }"#.utf8)
        let hits = await rips.discoverSearch("abba")
        XCTAssertTrue(hits.isEmpty)
        XCTAssertNil(rips.discoverError)
    }

    // MARK: discoverAdd — the ad-hoc /rip descriptor + job tracking

    private var hit: RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: "123", title: "Take On Me", artist: "a-ha",
                              album: "Hunting High and Low", artworkUrl: nil,
                              durationMs: 225000, songId: "amrec_123", ripped: false, url: nil)
    }

    func testDiscoverAddPostsAdHocRipDescriptor() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/rip"] =
            Data(#"{"jobId":"job_1","songId":"amrec_123","phase":"queued"}"#.utf8)

        await rips.discoverAdd(hit)

        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 1)
        let sent = DiscoverURLProtocol.lastBodyJSON(path: "/rip")
        XCTAssertEqual(sent?["songId"] as? String, "amrec_123")
        XCTAssertEqual(sent?["title"] as? String, "Take On Me")
        XCTAssertEqual(sent?["artist"] as? String, "a-ha")
        XCTAssertEqual(sent?["appleMusicId"] as? String, "123")
        XCTAssertEqual(sent?["lengthMs"] as? Int, 225000)
        // The queued job is recorded so the Discover row shows live progress.
        XCTAssertEqual(rips.jobs["amrec_123"]?.jobId, "job_1")
        XCTAssertEqual(rips.jobs["amrec_123"]?.phase, .queued)
        XCTAssertNil(rips.discoverError)
    }

    func testDiscoverAddAlreadyCachedSkipsNetwork() async {
        let rips = makeStore()
        rips.setManifest(["amrec_123": .init(key: "rips/amrec_123.mp3")])
        await rips.discoverAdd(hit)
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 0, "cached song must not re-POST /rip")
    }

    func testDiscoverAddFailureSurfacesError() async {
        let rips = makeStore()
        DiscoverURLProtocol.statusCodeByPath["/rip"] = 500
        await rips.discoverAdd(hit)
        XCTAssertNotNil(rips.discoverError)
        XCTAssertNil(rips.jobs["amrec_123"])
    }

    // MARK: Discover-tab term building + artist refine (pure DiscoverSearchModel math)

    private func hit(_ artist: String) -> RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: "1", title: "T", artist: artist, songId: "amrec_1")
    }

    func testTermJoinsTitleAndArtist() {
        XCTAssertEqual(DiscoverSearchModel.term(title: "one more time", artist: ""), "one more time")
        XCTAssertEqual(DiscoverSearchModel.term(title: "", artist: "daft punk"), "daft punk")
        XCTAssertEqual(DiscoverSearchModel.term(title: " one more time ", artist: " daft punk "),
                       "one more time daft punk")
        XCTAssertNil(DiscoverSearchModel.term(title: "  ", artist: ""))
    }

    // MARK: Add = library-first (the iMac captures by playing — recognizer doctrine)

    @MainActor private final class StubLibrary: MusicLibraryContributor {
        var added: [String] = []
        var canAdd = true
        var kind: StreamingProviderKind { .appleMusic }
        var canContribute: Bool { true }
        var canAddToLibrary: Bool { canAdd }
        func resolveForLibrary(storeID: String?, title: String?, artist: String?) async -> AppleMusicResolution? { nil }
        func addSongToLibrary(storeID: String) async throws { added.append(storeID) }
        func addAlbumToLibrary(storeID: String) async throws {}
        func albumTracks(albumStoreID: String) async -> [AppleMusicSongRow] { [] }
    }

    func testDiscoverAddAddsToLibraryFirst() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/rip"] = Data("""
        { "jobId": "j1", "songId": "amrec_123", "phase": "queued", "url": null }
        """.utf8)
        let lib = StubLibrary()
        let hit = RipsStore.DiscoverHit(appleMusicId: "123", title: "T", artist: "A", songId: "amrec_123")
        await rips.discoverAdd(hit, library: lib)
        XCTAssertEqual(lib.added, ["123"], "library add precedes the rip request")
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 1, "rip still enqueued")
    }

    func testDiscoverAddSkipsLibraryWhenPlatformCannot() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/rip"] = Data("""
        { "jobId": "j2", "songId": "amrec_9", "phase": "queued", "url": null }
        """.utf8)
        let lib = StubLibrary(); lib.canAdd = false
        let hit = RipsStore.DiscoverHit(appleMusicId: "9", title: "T", artist: "A", songId: "amrec_9")
        await rips.discoverAdd(hit, library: lib)
        XCTAssertTrue(lib.added.isEmpty, "macOS-style contributor: no library write")
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 1)
    }

    // MARK: MusicKit merge (the "Witchy" coverage fix — catalog leads, proxy annotates)

    private func track(_ id: String, _ title: String) -> StreamingTrack {
        StreamingTrack(id: "appleMusic:\(id)", kind: .appleMusic, providerTrackID: id,
                       title: title, artist: "KAYTRANADA",
                       artworkURL: URL(string: "https://x/a.jpg"), durationSeconds: 61)
    }

    private func serverHit(_ id: String, ripped: Bool) -> RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: id, title: "S\(id)", artist: "Server Artist",
                              songId: "amrec_\(id)", ripped: ripped,
                              url: ripped ? "https://s3/x.mp3" : nil)
    }

    func testHitMappingFromStreamingTrack() {
        let mapped = DiscoverSearchModel.hit(from: track("1747040108", "Witchy"),
                                             ripURL: URL(string: "https://s3/w.mp3"))
        XCTAssertEqual(mapped.songId, "amrec_1747040108")
        XCTAssertEqual(mapped.appleMusicId, "1747040108")
        XCTAssertEqual(mapped.durationMs, 61_000)
        XCTAssertEqual(mapped.ripped, true)
        XCTAssertEqual(mapped.url, "https://s3/w.mp3")
        let unripped = DiscoverSearchModel.hit(from: track("2", "T"), ripURL: nil)
        XCTAssertEqual(unripped.ripped, false)
        XCTAssertNil(unripped.url)
    }

    func testMergeCatalogLeadsServerAnnotatesAndDedupes() {
        let catalog = [DiscoverSearchModel.hit(from: track("1", "Vocal"), ripURL: nil),
                       DiscoverSearchModel.hit(from: track("2", "Deep Cut"), ripURL: nil)]
        let server = [serverHit("3", ripped: false), serverHit("1", ripped: true)]
        let merged = DiscoverSearchModel.merge(catalog: catalog, server: server)
        // Catalog ranking first, then proxy-only hits; no duplicate of id 1.
        XCTAssertEqual(merged.map(\.appleMusicId), ["1", "2", "3"])
        // Where both know the track, the SERVER row wins (ripped/url authority).
        XCTAssertEqual(merged[0].ripped, true)
        XCTAssertEqual(merged[0].url, "https://s3/x.mp3")
        // Catalog-only hits keep their mapped shape.
        XCTAssertEqual(merged[1].title, "Deep Cut")
    }

    func testMergeWithNoCatalogIsServerPassthrough() {
        let server = [serverHit("9", ripped: false)]
        XCTAssertEqual(DiscoverSearchModel.merge(catalog: [], server: server).map(\.appleMusicId), ["9"])
    }

    func testRefineNarrowsByArtistCaseInsensitively() {
        let hits = [hit("Daft Punk"), hit("Pendulum"), hit("daft punk & friends")]
        XCTAssertEqual(DiscoverSearchModel.refine(hits, artist: "").count, 3, "empty refine passes through")
        let narrowed = DiscoverSearchModel.refine(hits, artist: "DAFT")
        XCTAssertEqual(narrowed.map(\.artist), ["Daft Punk", "daft punk & friends"])
        XCTAssertTrue(DiscoverSearchModel.refine(hits, artist: "prodigy").isEmpty)
    }

    // MARK: ＋Add help wording — capability-aware, honest on macOS (F7); shared song+album helper

    func testDiscoverAddHelpWordingByCapability() {
        // Library-writable device (iOS/iPadOS w/ subscription): save to library + prepare a copy.
        XCTAssertEqual(
            DiscoverAddWording.addHelp(noun: "song", canAddToLibrary: true, opensInMusic: false),
            "Save this song to your Apple Music library and prepare your copy")
        XCTAssertEqual(
            DiscoverAddWording.addHelp(noun: "album", canAddToLibrary: true, opensInMusic: false),
            "Save this album to your Apple Music library and prepare your copy")

        // macOS album: can't write the library → opens in Music (deep-link). Must NOT overstate
        // a library write — the exact F7 finding.
        let macAlbum = DiscoverAddWording.addHelp(noun: "album", canAddToLibrary: false, opensInMusic: true)
        XCTAssertEqual(macAlbum, "Open this album in Music and prepare your copy")
        XCTAssertFalse(macAlbum.contains("library"), "macOS help must not claim a library write (F7)")

        // macOS song: no deep link available for an unripped hit → just prepares the copy.
        let macSong = DiscoverAddWording.addHelp(noun: "song", canAddToLibrary: false, opensInMusic: false)
        XCTAssertEqual(macSong, "Prepare your copy")
        XCTAssertFalse(macSong.contains("library"), "macOS help must not claim a library write (F7)")
    }

    // MARK: Discover ▸ ALBUMS — search decode (entity=album) + add fan-out

    func testDiscoverSearchAlbumsDecodesAndSendsEntityAlbum() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/search"] = Data("""
        { "results": [
            { "appleMusicId": "111", "albumId": "amrec_album_111", "title": "Random Access Memories",
              "artist": "Daft Punk", "artworkUrl": "https://art/111.jpg", "trackCount": 13,
              "year": 2013, "url": "https://music.apple.com/album/111" }
          ] }
        """.utf8)
        let hits = await rips.discoverSearchAlbums("random access", limit: 25)
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(rips.discoverError)
        XCTAssertEqual(hits[0].id, "amrec_album_111")
        XCTAssertEqual(hits[0].appleMusicId, "111")
        XCTAssertEqual(hits[0].title, "Random Access Memories")
        XCTAssertEqual(hits[0].trackCount, 13)
        XCTAssertEqual(hits[0].year, 2013)
        XCTAssertEqual(hits[0].url, "https://music.apple.com/album/111")
        // Request shape: GET /search?q=…&entity=album&limit=… with the bearer token.
        let req = DiscoverURLProtocol.last(path: "/search")
        XCTAssertEqual(req?.httpMethod, "GET")
        let query = req?.url?.query ?? ""
        XCTAssertTrue(query.contains("entity=album"), "album search must set entity=album: \(query)")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testDiscoverAddAlbumFansOutPerTrackRips() async {
        let rips = makeStore()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        rips.discoverAdds = adds
        // No library contributor → the server /album-tracks expansion drives the fan-out.
        DiscoverURLProtocol.bodyByPath["/album-tracks"] = Data("""
        { "id": "111", "tracks": [
            { "id": "1", "title": "T1", "artist": "Daft Punk", "trackNumber": 1, "durationMs": 200000 },
            { "id": "2", "title": "T2", "artist": "Daft Punk", "trackNumber": 2, "durationMs": 210000 }
          ] }
        """.utf8)
        DiscoverURLProtocol.bodyByPath["/rip"] =
            Data(#"{"jobId":"j","songId":"x","phase":"queued"}"#.utf8)
        let hit = RipsStore.DiscoverAlbumHit(appleMusicId: "111", albumId: "amrec_album_111",
                                             title: "RAM", artist: "Daft Punk", year: 2013)
        await rips.discoverAddAlbum(hit, intent: .andPrepareCopies)
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/album-tracks"), 1, "expands once via the proxy")
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 2, "one rip per track")
        // Provisional album + its per-track songs recorded.
        XCTAssertEqual(adds.albums.map(\.albumId), ["amrec_album_111"])
        XCTAssertEqual(adds.albums.first?.trackIds, ["amrec_1", "amrec_2"])
        XCTAssertEqual(adds.albums.first?.appleMusicId, "111")
        XCTAssertEqual(adds.entries.map(\.songId).sorted(), ["amrec_1", "amrec_2"])
        XCTAssertNil(rips.discoverError)
    }

    /// FIX 1 (perf): a fanned-out album add records the album + every accepted track in a
    /// SINGLE batched inject — the per-row `onAdded`/`onAlbumAdded` arms must NOT fire (each
    /// would drive a full catalog rebuild), only `onAlbumBatchAdded` fires exactly once with
    /// the complete set.
    func testDiscoverAddAlbumBatchesInOneInject() async {
        let rips = makeStore()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        rips.discoverAdds = adds
        var perRowSongInjects = 0, perRowAlbumInjects = 0, batchInjects = 0
        var batchedSongIds: [String] = []
        var batchedAlbumId: String?
        adds.onAdded = { _ in perRowSongInjects += 1 }
        adds.onAlbumAdded = { _ in perRowAlbumInjects += 1 }
        adds.onAlbumBatchAdded = { songs, album in
            batchInjects += 1
            batchedSongIds = songs.map(\.id)
            batchedAlbumId = album?.id
        }
        DiscoverURLProtocol.bodyByPath["/album-tracks"] = Data("""
        { "id": "111", "tracks": [
            { "id": "1", "title": "T1", "artist": "Daft Punk", "trackNumber": 1, "durationMs": 200000 },
            { "id": "2", "title": "T2", "artist": "Daft Punk", "trackNumber": 2, "durationMs": 210000 },
            { "id": "3", "title": "T3", "artist": "Daft Punk", "trackNumber": 3, "durationMs": 220000 }
          ] }
        """.utf8)
        DiscoverURLProtocol.bodyByPath["/rip"] =
            Data(#"{"jobId":"j","songId":"x","phase":"queued"}"#.utf8)
        let hit = RipsStore.DiscoverAlbumHit(appleMusicId: "111", albumId: "amrec_album_111",
                                             title: "RAM", artist: "Daft Punk", year: 2013)
        await rips.discoverAddAlbum(hit, intent: .andPrepareCopies)

        XCTAssertEqual(batchInjects, 1, "exactly ONE batched inject for the whole album")
        XCTAssertEqual(perRowSongInjects, 0, "no per-track song inject (that would rebuild per track)")
        XCTAssertEqual(perRowAlbumInjects, 0, "no per-row album inject")
        // The single settle carries the COMPLETE set — album + all three accepted tracks.
        XCTAssertEqual(batchedAlbumId, "amrec_album_111")
        XCTAssertEqual(batchedSongIds.sorted(), ["amrec_1", "amrec_2", "amrec_3"])
        XCTAssertEqual(adds.albums.first?.trackIds, ["amrec_1", "amrec_2", "amrec_3"])
        XCTAssertEqual(adds.entries.map(\.songId).sorted(), ["amrec_1", "amrec_2", "amrec_3"])
    }

    /// SERVERLESS album add (public-user audit fix): with NO rip server every track comes back
    /// `.noServer` — the album + tracks are STILL recorded as streamable catalog rows (they
    /// carry Apple Music catalog ids and play via the user's subscription; only the rip isn't
    /// owed), in ONE batched inject, with no error surfaced.
    func testDiscoverAddAlbumNoServerRecordsStreamableRows() async {
        let rips = makeStore(serverURL: "")   // no rip server → every requestRip → .noServer
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        rips.discoverAdds = adds
        var batchInjects = 0
        adds.onAlbumBatchAdded = { _, _ in batchInjects += 1 }
        // The library expands the tracklist (so descs is non-empty) even with no server.
        let lib = AlbumTracksStub()
        lib.tracks = [songRow("10", "A"), songRow("11", "B")]
        let hit = RipsStore.DiscoverAlbumHit(appleMusicId: "111", albumId: "amrec_album_111",
                                             title: "RAM", artist: "Daft Punk")
        await rips.discoverAddAlbum(hit, library: lib, intent: .andPrepareCopies)

        XCTAssertEqual(adds.entries.map(\.songId).sorted(), ["amrec_10", "amrec_11"],
                       "serverless tracks are recorded — they stream via their catalog ids")
        XCTAssertEqual(adds.albums.first?.albumId, "amrec_album_111")
        XCTAssertEqual(batchInjects, 1, "one batched inject for the whole album")
        XCTAssertNil(rips.discoverError, "a serverless add is not an error")
    }

    /// REGRESSION (Levi, device, 2026-08-07): "I added the album X by Roy Woods from pocketdj in
    /// the new tile and it is ripping the whole album, I dont think it should do that, it should
    /// add the items to the users apple music library but not rip unless they hit download."
    ///
    /// `.libraryOnly` — what the album PREVIEW's giant ＋ passes — must issue ZERO `/rip`
    /// requests while still doing everything an add owes: the Apple Music library write, the
    /// provisional album, and every track as a streamable catalog citizen. Before the fix this
    /// fired one real-time capture per track (13 on a full album) off a button that only ever
    /// promised "Add album to your library".
    func testDiscoverAddAlbumLibraryOnlyRipsNothingButStillAdds() async {
        let rips = makeStore()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        rips.discoverAdds = adds
        DiscoverURLProtocol.bodyByPath["/album-tracks"] = Data("""
        { "id": "111", "tracks": [
            { "id": "1", "title": "T1", "artist": "Roy Woods", "trackNumber": 1, "durationMs": 200000 },
            { "id": "2", "title": "T2", "artist": "Roy Woods", "trackNumber": 2, "durationMs": 210000 },
            { "id": "3", "title": "T3", "artist": "Roy Woods", "trackNumber": 3, "durationMs": 220000 }
          ] }
        """.utf8)
        DiscoverURLProtocol.bodyByPath["/rip"] =
            Data(#"{"jobId":"j","songId":"x","phase":"queued"}"#.utf8)
        let lib = AlbumTracksStub()
        lib.canAddToLibrary = true          // an iOS device that CAN write the AM library
        let hit = RipsStore.DiscoverAlbumHit(appleMusicId: "111", albumId: "amrec_album_111",
                                             title: "Say Less", artist: "Roy Woods")
        await rips.discoverAddAlbum(hit, library: lib, intent: .libraryOnly)

        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 0,
                       "＋ Add must capture NOTHING — ripping is the download button's job")
        XCTAssertEqual(lib.addedAlbumStoreIDs, ["111"], "the Apple Music library write still happens")
        // …and the album is fully a catalog citizen: every track recorded, streamable via its
        // Apple Music id, in ONE batched inject.
        XCTAssertEqual(adds.entries.map(\.songId).sorted(), ["amrec_1", "amrec_2", "amrec_3"])
        XCTAssertEqual(adds.entries.map(\.appleMusicId).sorted(), ["1", "2", "3"],
                       "each row carries its catalog id, so it streams with no local file")
        XCTAssertEqual(adds.albums.first?.albumId, "amrec_album_111")
        XCTAssertEqual(adds.albums.first?.trackIds, ["amrec_1", "amrec_2", "amrec_3"])
        XCTAssertNil(rips.discoverError, "a library-only add is not an error")
    }

    /// The two album-add surfaces mean different things, and the parameter is what keeps them
    /// from drifting: the Discover search row (`.andPrepareCopies`) still fans rips out — its
    /// whole trailing control is per-track rip progress and it has no download button of its own.
    func testDiscoverAddAlbumPrepareCopiesStillFansOutRips() async {
        let rips = makeStore()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        rips.discoverAdds = DiscoverAddsStore(fileURL: addsURL)
        DiscoverURLProtocol.bodyByPath["/album-tracks"] = Data("""
        { "id": "111", "tracks": [
            { "id": "1", "title": "T1", "artist": "Roy Woods", "trackNumber": 1 },
            { "id": "2", "title": "T2", "artist": "Roy Woods", "trackNumber": 2 }
          ] }
        """.utf8)
        DiscoverURLProtocol.bodyByPath["/rip"] =
            Data(#"{"jobId":"j","songId":"x","phase":"queued"}"#.utf8)
        let hit = RipsStore.DiscoverAlbumHit(appleMusicId: "111", albumId: "amrec_album_111",
                                             title: "Say Less", artist: "Roy Woods")
        await rips.discoverAddAlbum(hit, intent: .andPrepareCopies)
        XCTAssertEqual(DiscoverURLProtocol.count(path: "/rip"), 2, "the download intent still rips")
    }

    /// The progress capsule must SETTLE for a library-only add. `preparedCopies` records whether
    /// there is any capture to wait on; without it the n/m readout sits at 0/3 forever, because
    /// no rip was ever queued so no track can become ready.
    func testLibraryOnlyAddRecordsPreparedCopiesFalseAndSettlesImmediately() async {
        let rips = makeStore()
        let addsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadds-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: addsURL) }
        let adds = DiscoverAddsStore(fileURL: addsURL)
        rips.discoverAdds = adds
        let lib = AlbumTracksStub()
        lib.tracks = [songRow("1", "T1"), songRow("2", "T2"), songRow("3", "T3")]
        let hit = RipsStore.DiscoverAlbumHit(appleMusicId: "111", albumId: "amrec_album_111",
                                             title: "Say Less", artist: "Roy Woods")
        await rips.discoverAddAlbum(hit, library: lib, intent: .libraryOnly)

        let entry = try! XCTUnwrap(adds.albums.first)
        XCTAssertEqual(entry.preparedCopies, false)
        // NOTHING is ready (no rips exist) and nothing errored — the old reducer would call that
        // `.adding(0, 3)`, an eternal spinner. The entry-aware one settles.
        XCTAssertEqual(DiscoverAlbumAddState.of(trackIds: entry.trackIds ?? [],
                                                readyIds: [], erroredIds: []),
                       .adding(ready: 0, total: 3), "the raw reducer still spins — that's the trap")
        XCTAssertEqual(DiscoverAlbumAddState.of(entry: entry, readyIds: [], erroredIds: []),
                       .added, "a library-only add has nothing to wait on")
        // A prepare-copies album keeps the progress readout…
        var ripped = entry
        ripped.preparedCopies = true
        XCTAssertEqual(DiscoverAlbumAddState.of(entry: ripped, readyIds: ["amrec_1"], erroredIds: []),
                       .adding(ready: 1, total: 3))
        // …and so does a LEGACY row written before the split (nil), which really was ripping.
        var legacy = entry
        legacy.preparedCopies = nil
        XCTAssertEqual(DiscoverAlbumAddState.of(entry: legacy, readyIds: ["amrec_1"], erroredIds: []),
                       .adding(ready: 1, total: 3))
    }

    /// FIX 4 (UX): an album settles when every track is TERMINAL (ready OR errored) — a
    /// permanently-failed track yields a PARTIAL result (n/m), never an eternal spinner.
    func testDiscoverAlbumAddStateTerminalSettling() {
        let ids = ["a", "b", "c"]
        // Still working: b/c neither ready nor errored → adding.
        XCTAssertEqual(DiscoverAlbumAddState.of(trackIds: ids, readyIds: ["a"], erroredIds: []),
                       .adding(ready: 1, total: 3))
        // All ready → added.
        XCTAssertEqual(DiscoverAlbumAddState.of(trackIds: ids, readyIds: ["a", "b", "c"], erroredIds: []),
                       .added)
        // 2 ready + 1 permanently errored → settled PARTIAL (no spinner), not adding.
        XCTAssertEqual(DiscoverAlbumAddState.of(trackIds: ids, readyIds: ["a", "b"], erroredIds: ["c"]),
                       .partial(ready: 2, total: 3))
        // Every track errored → partial 0/3 (settled, distinct from an in-flight 0/3).
        XCTAssertEqual(DiscoverAlbumAddState.of(trackIds: ids, readyIds: [], erroredIds: ["a", "b", "c"]),
                       .partial(ready: 0, total: 3))
        // Legacy album with no recorded tracks → added (nothing to wait on, no eternal spinner).
        XCTAssertEqual(DiscoverAlbumAddState.of(trackIds: [], readyIds: [], erroredIds: []), .added)
    }

    /// A library contributor that expands an album into a fixed tracklist (for the
    /// no-server fan-out test — the proxy `/album-tracks` needs a server, the library doesn't).
    @MainActor private final class AlbumTracksStub: MusicLibraryContributor {
        var tracks: [AppleMusicSongRow] = []
        var kind: StreamingProviderKind { .appleMusic }
        var canContribute: Bool { true }
        /// Stored (default false, as before) so a test can turn the library write ON and assert
        /// that ＋ Add still performs it — the half of the add that must SURVIVE dropping the rip.
        var canAddToLibrary: Bool = false
        private(set) var addedAlbumStoreIDs: [String] = []
        func resolveForLibrary(storeID: String?, title: String?, artist: String?) async -> AppleMusicResolution? { nil }
        func addSongToLibrary(storeID: String) async throws {}
        func addAlbumToLibrary(storeID: String) async throws { addedAlbumStoreIDs.append(storeID) }
        func albumTracks(albumStoreID: String) async -> [AppleMusicSongRow] { tracks }
    }

    private func songRow(_ id: String, _ title: String) -> AppleMusicSongRow {
        AppleMusicSongRow(storeID: id, title: title, artist: "Daft Punk", albumTitle: "RAM",
                          trackNumber: nil, year: nil, durationSeconds: 200, isExplicit: nil,
                          artworkURL: nil)
    }

    // MARK: Album search-model math (merge/dedup-by-collectionId, refine, ref→hit mapping)

    private func albumRef(_ id: String, _ artist: String) -> AppleMusicAlbumRef {
        AppleMusicAlbumRef(storeID: id, title: "Album\(id)", artist: artist, year: 2013,
                           artworkURL: URL(string: "https://a/\(id).jpg"),
                           url: URL(string: "https://music/\(id)"))
    }

    private func serverAlbum(_ id: String) -> RipsStore.DiscoverAlbumHit {
        RipsStore.DiscoverAlbumHit(appleMusicId: id, albumId: "amrec_album_\(id)",
                                   title: "S\(id)", artist: "Srv")
    }

    func testAlbumHitMappingFromRef() {
        let h = DiscoverAlbumSearchModel.hit(from: albumRef("111", "Daft Punk"))
        XCTAssertEqual(h.appleMusicId, "111")
        XCTAssertEqual(h.albumId, "amrec_album_111")
        XCTAssertEqual(h.title, "Album111")
        XCTAssertEqual(h.artist, "Daft Punk")
        XCTAssertEqual(h.year, 2013)
        XCTAssertEqual(h.artworkUrl, "https://a/111.jpg")
        XCTAssertEqual(h.url, "https://music/111")
    }

    func testAlbumMergeDedupesByCollectionId() {
        let catalog = [DiscoverAlbumSearchModel.hit(from: albumRef("1", "A")),
                       DiscoverAlbumSearchModel.hit(from: albumRef("2", "A"))]
        let server = [serverAlbum("2"), serverAlbum("3")]
        let merged = DiscoverAlbumSearchModel.merge(catalog: catalog, server: server)
        XCTAssertEqual(merged.map(\.appleMusicId), ["1", "2", "3"], "catalog leads, proxy-only follows, no dupes")
        XCTAssertEqual(merged[1].title, "Album2", "catalog row wins on a collectionId tie")
        XCTAssertEqual(DiscoverAlbumSearchModel.merge(catalog: [], server: server).map(\.appleMusicId), ["2", "3"])
    }

    func testAlbumRefineNarrowsByArtist() {
        let hits = [DiscoverAlbumSearchModel.hit(from: albumRef("1", "Daft Punk")),
                    DiscoverAlbumSearchModel.hit(from: albumRef("2", "Pendulum"))]
        XCTAssertEqual(DiscoverAlbumSearchModel.refine(hits, artist: "daft").map(\.appleMusicId), ["1"])
        XCTAssertEqual(DiscoverAlbumSearchModel.refine(hits, artist: "").count, 2, "empty refine passes through")
    }

    // MARK: Album identity on the wire
    //
    // The `/search` proxy mapped `album: collectionName` and THREW AWAY iTunes'
    // `collectionId`, so an added song could never resolve its album. These pin the
    // decoded shape (new keys present) AND the back-compat shape (server without them).

    func testDiscoverSearchDecodesAlbumAppleMusicIdAndTrackMetadata() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/search"] = Data("""
        { "results": [
            { "appleMusicId": "1440857781", "title": "Blue in Green", "artist": "Miles Davis",
              "album": "Kind of Blue", "artworkUrl": "https://art/t.jpg",
              "durationMs": 337000, "songId": "amrec_1440857781", "ripped": false,
              "explicit": false,
              "albumAppleMusicId": "268443788", "albumArtworkUrl": "https://art/c.jpg",
              "trackNumber": 3, "discNumber": 1, "year": 1959 }
          ] }
        """.utf8)

        let hits = await rips.discoverSearch("blue in green")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].albumAppleMusicId, "268443788",
                       "the album's IDENTITY, not just its name — the whole point")
        XCTAssertEqual(hits[0].albumArtworkUrl, "https://art/c.jpg")
        XCTAssertEqual(hits[0].trackNumber, 3)
        XCTAssertEqual(hits[0].discNumber, 1)
        XCTAssertEqual(hits[0].year, 1959)
    }

    /// An OLD rip server (Levi's iMac until it's redeployed) emits none of the new keys.
    /// It must still decode — every added field is optional-with-default and APPENDED.
    func testDiscoverSearchToleratesServerWithoutNewFields() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/search"] = Data("""
        { "results": [
            { "appleMusicId": "123", "title": "Take On Me", "artist": "a-ha",
              "album": "Hunting High and Low", "durationMs": 225000,
              "songId": "amrec_123", "ripped": false }
          ] }
        """.utf8)

        let hits = await rips.discoverSearch("take on me")

        XCTAssertEqual(hits.count, 1, "an old server's response must still decode")
        XCTAssertNil(rips.discoverError)
        XCTAssertEqual(hits[0].album, "Hunting High and Low")
        XCTAssertNil(hits[0].albumAppleMusicId)
        XCTAssertNil(hits[0].trackNumber)
        XCTAssertNil(hits[0].year)
    }

    /// A MusicKit hit carries the album NAME through `StreamingTrack` (the id is resolved
    /// lazily on the detail screen — a per-row `with([.albums])` would be 25 round trips
    /// per keystroke). Before, the MusicKit branch set no album at all.
    func testHitMappingCarriesAlbumFromStreamingTrack() {
        var t = track("777", "Instant Crush")
        t.albumTitle = "Random Access Memories"
        t.albumStoreID = "617154241"
        let mapped = DiscoverSearchModel.hit(from: t, ripURL: nil)
        XCTAssertEqual(mapped.album, "Random Access Memories")
        XCTAssertEqual(mapped.albumAppleMusicId, "617154241")
        // And a track with no album info degrades to nil, not to an empty string.
        let bare = DiscoverSearchModel.hit(from: track("2", "T"), ripURL: nil)
        XCTAssertNil(bare.album)
        XCTAssertNil(bare.albumAppleMusicId)
    }

    /// `discoverAdd` must hand the album identity to the provisional store — otherwise the
    /// wire carries it and the catalog still loses it.
    func testDiscoverAddStampsAlbumIdentityOnTheProvisionalEntry() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/rip"] = Data("""
        { "jobId": "j1", "songId": "amrec_5", "phase": "queued", "url": null }
        """.utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dadd-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let adds = DiscoverAddsStore(fileURL: url)
        rips.discoverAdds = adds

        var hit = RipsStore.DiscoverHit(appleMusicId: "5", title: "T", artist: "A",
                                        album: "Kind of Blue", songId: "amrec_5")
        hit.albumAppleMusicId = "268443788"
        hit.albumArtworkUrl = "https://art/c.jpg"
        hit.trackNumber = 3
        hit.year = 1959
        hit.explicit = false
        await rips.discoverAdd(hit)

        let entry = adds.entry(forSongId: "amrec_5")
        XCTAssertEqual(entry?.albumAppleMusicId, "268443788")
        XCTAssertEqual(entry?.albumArtworkUrl, "https://art/c.jpg")
        XCTAssertEqual(entry?.trackNumber, 3)
        XCTAssertEqual(entry?.year, 1959)
        XCTAssertEqual(entry?.explicit, false)
    }

    /// The ALBUM add had `hit.albumId` in scope and still built its per-track entries
    /// without it, so a track of an album you JUST added had no album to open.
    func testDiscoverAddAlbumStampsAlbumIdOnEachTrackEntry() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/album-tracks"] = Data("""
        { "id": "268443788",
          "album": { "appleMusicId": "268443788", "albumId": "amrec_album_268443788",
                     "title": "Kind of Blue", "artist": "Miles Davis", "year": 1959,
                     "trackCount": 2, "url": "https://music/268443788" },
          "tracks": [
            { "id": "10", "title": "So What", "artist": "Miles Davis",
              "discNumber": 1, "trackNumber": 1, "durationMs": 545000 },
            { "id": "11", "title": "Blue in Green", "artist": "Miles Davis",
              "discNumber": 1, "trackNumber": 3, "durationMs": 337000 }
          ] }
        """.utf8)
        DiscoverURLProtocol.bodyByPath["/rip"] = Data("""
        { "jobId": "j", "songId": "x", "phase": "queued", "url": null }
        """.utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dalb-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let adds = DiscoverAddsStore(fileURL: url)
        rips.discoverAdds = adds

        let hit = RipsStore.DiscoverAlbumHit(appleMusicId: "268443788",
                                             albumId: "amrec_album_268443788",
                                             title: "Kind of Blue", artist: "Miles Davis",
                                             artworkUrl: "https://art/c.jpg",
                                             trackCount: 2, year: 1959)
        await rips.discoverAddAlbum(hit, intent: .andPrepareCopies)

        XCTAssertEqual(adds.entries.count, 2)
        XCTAssertEqual(adds.entries.map(\.albumId),
                       ["amrec_album_268443788", "amrec_album_268443788"],
                       "each track links to the album that was just added")
        XCTAssertEqual(adds.entries.map(\.albumAppleMusicId), ["268443788", "268443788"])
        XCTAssertEqual(adds.entries.map(\.trackNumber), [1, 3])
        XCTAssertEqual(adds.entries.map(\.discNumber), [1, 1])
        XCTAssertEqual(adds.entries.map(\.year), [1959, 1959])
        // …and the synthesized catalog rows carry it through to the browser.
        XCTAssertEqual(adds.entries.map { DiscoverAddsStore.indexSong($0).albumId },
                       ["amrec_album_268443788", "amrec_album_268443788"])
    }

    /// The subscription-free tier the album preview is built on: `/album-tracks` now hands
    /// back the COLLECTION row it used to drop, so a preview can be built from an id alone.
    func testFetchAlbumReturnsRefFromProxy() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/album-tracks"] = Data("""
        { "id": "268443788",
          "album": { "appleMusicId": "268443788", "albumId": "amrec_album_268443788",
                     "title": "Kind of Blue", "artist": "Miles Davis",
                     "artworkUrl": "https://art/c.jpg", "trackCount": 5, "year": 1959,
                     "url": "https://music/268443788" },
          "tracks": [ { "id": "10", "title": "So What", "artist": "Miles Davis" } ] }
        """.utf8)

        let expansion = await rips.fetchAlbumExpansion(collectionId: "268443788")
        XCTAssertEqual(expansion.tracks.count, 1)
        let ref = expansion.album?.albumRef
        XCTAssertEqual(ref?.storeID, "268443788")
        XCTAssertEqual(ref?.title, "Kind of Blue")
        XCTAssertEqual(ref?.artist, "Miles Davis")
        XCTAssertEqual(ref?.year, 1959)
        XCTAssertEqual(ref?.artworkURL?.absoluteString, "https://art/c.jpg")
        XCTAssertEqual(ref?.url?.absoluteString, "https://music/268443788")
        // Same request, single round trip — both accessors read one response.
        let alone = await rips.fetchAlbum(collectionId: "268443788")
        XCTAssertEqual(alone?.title, "Kind of Blue")
    }

    /// An OLD server omits `album` entirely; the tracks half must be unaffected.
    func testFetchAlbumIsNilForServerWithoutTheCollectionRow() async {
        let rips = makeStore()
        DiscoverURLProtocol.bodyByPath["/album-tracks"] = Data("""
        { "id": "1", "tracks": [ { "id": "10", "title": "T", "artist": "A" } ] }
        """.utf8)
        let album = await rips.fetchAlbum(collectionId: "1")
        XCTAssertNil(album)
        let tracks = await rips.fetchAlbumTracks(collectionId: "1")
        XCTAssertEqual(tracks.count, 1)
    }
}

/// Scriptable, request-recording `URLProtocol` standing in for the rip server —
/// per-path bodies + status overrides, full request capture (URL/method/headers/body).
private final class DiscoverURLProtocol: URLProtocol {
    static var bodyByPath: [String: Data] = [:]
    static var statusCodeByPath: [String: Int] = [:]

    private static let lock = NSLock()
    private static var requests: [(request: URLRequest, body: Data?)] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        bodyByPath = [:]; statusCodeByPath = [:]; requests = []
    }

    static func count(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.request.url?.path == path }.count
    }

    static func last(path: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last { $0.request.url?.path == path }?.request
    }

    static func lastBodyJSON(path: String) -> [String: Any]? {
        lock.lock()
        let data = requests.last { $0.request.url?.path == path }?.body
        lock.unlock()
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data?
        if let stream = request.httpBodyStream {
            body = Self.read(stream)
        } else {
            body = request.httpBody
        }
        Self.lock.lock()
        Self.requests.append((request, body))
        let status = Self.statusCodeByPath[path] ?? 200
        let payload = Self.bodyByPath[path] ?? Data("{}".utf8)
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data(); let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
