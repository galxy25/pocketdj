import XCTest
@testable import PocketDJ

/// The platter long-press follow-ups: the Apple Music LIBRARY affordance reducer +
/// amrec_ store-id recovery, and the Up Next header's setlist-view materialization
/// (a restored session's Now Playing doc is dropped at launch — the button rebuilds
/// it from the live queue).
@MainActor
final class PlatterDetailLibraryTests: XCTestCase {

    // MARK: SongLibraryAffordance

    private func resolution(inLibrary: Bool, url: URL? = nil) -> AppleMusicResolution {
        AppleMusicResolution(songStoreID: "12345", title: "T", artist: "A",
                             inLibrary: inLibrary, album: nil, songURL: url)
    }

    func testAffordanceTruthTable() {
        XCTAssertEqual(SongLibraryAffordance.decide(resolution: nil, canAdd: true), .none)
        XCTAssertEqual(SongLibraryAffordance.decide(resolution: resolution(inLibrary: true), canAdd: true),
                       .inLibrary)
        XCTAssertEqual(SongLibraryAffordance.decide(resolution: resolution(inLibrary: false), canAdd: true),
                       .add(storeID: "12345"))
        let link = URL(string: "https://music.apple.com/song/12345")!
        XCTAssertEqual(SongLibraryAffordance.decide(resolution: resolution(inLibrary: false, url: link),
                                                    canAdd: false),
                       .openLink(link))
        XCTAssertEqual(SongLibraryAffordance.decide(resolution: resolution(inLibrary: false), canAdd: false),
                       .none)
    }

    func testAdHocStoreIDRecovery() {
        XCTAssertEqual(SongLibraryAffordance.adHocStoreID("amrec_944459436"), "944459436")
        XCTAssertNil(SongLibraryAffordance.adHocStoreID("sng_x"))
        XCTAssertNil(SongLibraryAffordance.adHocStoreID("amrec_"))
        XCTAssertNil(SongLibraryAffordance.adHocStoreID("amrec_not-a-number"))
    }

    // MARK: materializeNowPlayingSetlist

    private func store() -> CollectionsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-platter-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return CollectionsStore(fileURL: url)
    }

    private let queue: [(id: String, title: String, artist: String, lengthMs: Int?, repeatCount: Int?)] = [
        (id: "sng_a", title: "Alpha", artist: "Artist A", lengthMs: 120_000, repeatCount: nil),
        (id: "amrec_555", title: "Found It", artist: "Artist B", lengthMs: 200_000, repeatCount: 2),
    ]

    func testMaterializeBuildsFromQueueRows() {
        let s = store()
        let set = s.materializeNowPlayingSetlist(name: "Friday Set", queue: queue)
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.name, "Friday Set")
        XCTAssertEqual(set?.tracks.count, 2)
        // Snapshot rides the queue rows, not the catalog (an amrec_ id resolves nowhere).
        XCTAssertEqual(set?.tracks[1].name, "Found It")
        XCTAssertEqual(set?.tracks[1].lengthMs, 200_000)
        XCTAssertEqual(CollectionMembership.normalizedRepeat(set?.tracks[1].repeatCount), 2)
        // Repeats count toward the total (120s + 2×200s).
        XCTAssertEqual(set?.totalMs, 120_000 + 400_000)
        // And it persisted as the reserved Now Playing setlist.
        XCTAssertNotNil(s.nowPlayingSetlist())
    }

    func testMaterializeIsIdempotentWhenDocExists() {
        let s = store()
        let first = s.materializeNowPlayingSetlist(name: "One", queue: queue)
        let second = s.materializeNowPlayingSetlist(name: "Two",
                                                    queue: [(id: "sng_z", title: "Z", artist: "Z",
                                                             lengthMs: nil, repeatCount: nil)])
        // The existing doc wins untouched — no rebuild, no rename, no duplicate.
        XCTAssertEqual(second?.id, first?.id)
        XCTAssertEqual(second?.name, "One")
        XCTAssertEqual(second?.tracks.count, 2)
        XCTAssertEqual(s.setlists.filter { $0.id == first?.id }.count, 1)
    }

    func testMaterializeEmptyQueueIsNil() {
        XCTAssertNil(store().materializeNowPlayingSetlist(name: nil, queue: []))
    }
}
