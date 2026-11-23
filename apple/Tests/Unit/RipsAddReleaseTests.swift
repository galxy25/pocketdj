import XCTest
@testable import PocketDJ

/// `RipsStore.addRelease` — the ONE add shared by the album page and the For You ▸ New 👍 — and
/// the regression check that `discoverAddAlbum` still echoes its failure into `discoverError`.
@MainActor
final class RipsAddReleaseTests: XCTestCase {

    @MainActor private final class Lib: MusicLibraryContributor {
        var tracks: [AppleMusicSongRow] = []
        var shouldThrow = false
        private(set) var albumWrites: [String] = []
        var kind: StreamingProviderKind { .appleMusic }
        var canContribute: Bool { true }
        var canAddToLibrary: Bool { true }
        func resolveForLibrary(storeID: String?, title: String?, artist: String?) async -> AppleMusicResolution? { nil }
        @discardableResult
        func addSongToLibrary(storeID: String) async throws -> AppleMusicLibraryAddResult { .confirmed }
        @discardableResult
        func addAlbumToLibrary(storeID: String) async throws -> AppleMusicLibraryAddResult {
            albumWrites.append(storeID)
            if shouldThrow { throw StreamingError.notLinked }
            return .confirmed
        }
        func albumTracks(albumStoreID: String) async -> [AppleMusicSongRow] { tracks }
    }

    private func rips() -> (RipsStore, DiscoverAddsStore) {
        let r = RipsStore(ripsBase: URL(string: "https://rips.test")!, session: URLSession(configuration: .ephemeral))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.ripServerURL = ""
        r.settings = settings
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-rel-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let adds = DiscoverAddsStore(fileURL: url)
        r.discoverAdds = adds
        return (r, adds)
    }

    private let ref = AppleMusicAlbumRef(storeID: "42", title: "Rec", artist: "Art", year: nil,
                                         artworkURL: nil, url: nil)

    private func row(_ id: String) -> AppleMusicSongRow {
        AppleMusicSongRow(storeID: id, title: "T\(id)", artist: "Art", albumTitle: "Rec", albumStoreID: "42",
                          trackNumber: 1, year: nil, durationSeconds: 100, isExplicit: nil, artworkURL: nil)
    }

    func testEmptyExpansionReportsNotRecordedWithTheTracksError() async {
        let (r, adds) = rips()
        let lib = Lib()
        let report = await r.addRelease(ref: ref, trackCount: nil, library: lib)
        XCTAssertFalse(report.recorded)
        XCTAssertEqual(report.error, "Couldn’t read the album’s tracks — try again.")
        XCTAssertTrue(report.write.isConfirmed, "the library write still ran and is reported honestly")
        XCTAssertTrue(adds.albums.isEmpty)
        // The shared field still carries it for the album page's existing readers.
        XCTAssertEqual(r.discoverError, report.error)
    }

    func testSuccessRecordsTheAlbumLibraryOnlyAndReportsClean() async {
        let (r, adds) = rips()
        let lib = Lib(); lib.tracks = [row("1"), row("2")]
        let report = await r.addRelease(ref: ref, trackCount: 2, library: lib)
        XCTAssertTrue(report.recorded)
        XCTAssertNil(report.error)
        XCTAssertEqual(lib.albumWrites, ["42"])
        XCTAssertEqual(adds.albums.map(\.albumId), ["amrec_album_42"])
        XCTAssertEqual(adds.albums.first?.preparedCopies, false, "a like captures NO audio")
    }

    func testWriteFailureIsInTheReportAndTheAddStillRecords() async {
        let (r, adds) = rips()
        let lib = Lib(); lib.tracks = [row("1")]; lib.shouldThrow = true
        let report = await r.addRelease(ref: ref, trackCount: 1, library: lib)
        XCTAssertTrue(report.recorded)
        XCTAssertTrue(report.error?.contains("Apple Music library add failed") == true, "\(report.error ?? "nil")")
        XCTAssertEqual(adds.albums.count, 1)
    }

    func testDiscoverAddAlbumStillSetsDiscoverErrorForExistingCallers() async {
        let (r, _) = rips()
        let hit = RipsStore.DiscoverAlbumHit(appleMusicId: "42", albumId: "amrec_album_42", title: "Rec", artist: "Art")
        await r.discoverAddAlbum(hit, library: Lib(), intent: .libraryOnly)
        XCTAssertEqual(r.discoverError, "Couldn’t read the album’s tracks — try again.")
    }

    func testConcurrentReportsKeepTheirOwnErrors() async {
        // The point of the report: two adds, two reasons — no shared-field trampling.
        let (r, _) = rips()
        let bad = Lib()                      // no tracks → "couldn't read"
        let good = Lib(); good.tracks = [row("9")]
        async let a = r.addRelease(ref: ref, trackCount: nil, library: bad)
        async let b = r.addRelease(ref: AppleMusicAlbumRef(storeID: "43", title: "B", artist: "Art", year: nil,
                                                          artworkURL: nil, url: nil),
                                   trackCount: 1, library: good)
        let (ra, rb) = await (a, b)
        XCTAssertFalse(ra.recorded); XCTAssertNotNil(ra.error)
        XCTAssertTrue(rb.recorded); XCTAssertNil(rb.error)
    }
}
