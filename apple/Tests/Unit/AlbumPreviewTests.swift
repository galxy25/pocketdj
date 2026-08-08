import XCTest
@testable import PocketDJ

/// The album PREVIEW screen's decisions, taken OFF the view so they can be checked without
/// driving the UI: how much of an album you already own, why a preview has nothing to show,
/// and the ref ⇄ add-hit mapping the giant ＋ depends on.
///
/// `AlbumPreviewView` renders these types and does not re-derive any of them — a button that
/// says "Add album" when you already own it is a defect no existence assertion would catch.
@MainActor
final class AlbumPreviewTests: XCTestCase {

    // MARK: - Ownership reducer

    func testOwnershipNoneWhenNothingIsOwned() {
        let s = AlbumOwnership.of(trackStoreIDs: ["1", "2", "3"],
                                  catalogSongIds: [], catalogAppleMusicIds: [], rippedSongIds: [])
        XCTAssertEqual(s, .none(total: 3))
        XCTAssertEqual(s.addTitle, "Add album to your library")
        XCTAssertFalse(s.isFullyOwned)
    }

    /// The three independent routes a track can already be yours by. Each ALONE must count.
    func testOwnershipCountsAdHocIdAppleMusicIdAndRipManifestIndependently() {
        // Track 1: the provisional catalog id. Track 2: a REAL indexed song claiming the
        // Apple Music id (post-supersede). Track 3: only a prepared rip. Track 4: none.
        let s = AlbumOwnership.of(trackStoreIDs: ["1", "2", "3", "4"],
                                  catalogSongIds: ["amrec_1"],
                                  catalogAppleMusicIds: ["2"],
                                  rippedSongIds: ["amrec_3"])
        XCTAssertEqual(s, .partial(owned: 3, total: 4))
        XCTAssertEqual(s.addTitle, "Add remaining (1)", "the ＋ must not offer to re-add what you have")
        XCTAssertTrue(AlbumOwnership.owns(storeID: "1", catalogSongIds: ["amrec_1"],
                                          catalogAppleMusicIds: [], rippedSongIds: []))
        XCTAssertTrue(AlbumOwnership.owns(storeID: "2", catalogSongIds: [],
                                          catalogAppleMusicIds: ["2"], rippedSongIds: []))
        XCTAssertTrue(AlbumOwnership.owns(storeID: "3", catalogSongIds: [],
                                          catalogAppleMusicIds: [], rippedSongIds: ["amrec_3"]))
        XCTAssertFalse(AlbumOwnership.owns(storeID: "4", catalogSongIds: ["amrec_1"],
                                           catalogAppleMusicIds: ["2"], rippedSongIds: ["amrec_3"]))
    }

    func testOwnershipOwnedWhenEveryTrackIsAccountedFor() {
        let s = AlbumOwnership.of(trackStoreIDs: ["1", "2"],
                                  catalogSongIds: ["amrec_1", "amrec_2"],
                                  catalogAppleMusicIds: [], rippedSongIds: [])
        XCTAssertEqual(s, .owned(total: 2))
        XCTAssertTrue(s.isFullyOwned)
        XCTAssertEqual(s.addTitle, "In your library")
    }

    /// An album we could not EXPAND (offline / no server / not in the catalog) has zero known
    /// tracks. "You own all zero of them" would hide the ＋ on exactly the album the user is
    /// there to add — so an empty tracklist is `.none`, never `.owned`.
    func testOwnershipOfAnUnexpandedAlbumIsNoneNotOwned() {
        let s = AlbumOwnership.of(trackStoreIDs: [], catalogSongIds: [],
                                  catalogAppleMusicIds: [], rippedSongIds: [])
        XCTAssertEqual(s, .none(total: 0))
        XCTAssertFalse(s.isFullyOwned, "an album with no known tracks is NOT owned")
    }

    // MARK: - "Nothing to show" always names its reason

    func testUnavailableReasonNamesTheActualCause() {
        XCTAssertEqual(AlbumPreviewUnavailable.reason(isOffline: true, hasServer: false,
                                                      canUseMusicKit: false), .offline)
        XCTAssertEqual(AlbumPreviewUnavailable.reason(isOffline: false, hasServer: false,
                                                      canUseMusicKit: false), .noServer)
        // A reachable tier that simply had no answer is NOT "offline" and NOT "no server".
        XCTAssertEqual(AlbumPreviewUnavailable.reason(isOffline: false, hasServer: true,
                                                      canUseMusicKit: false), .notFound)
        XCTAssertEqual(AlbumPreviewUnavailable.reason(isOffline: false, hasServer: false,
                                                      canUseMusicKit: true), .notFound)
        // Every case is actionable text, never an empty screen.
        for r in [AlbumPreviewUnavailable.offline, .noServer, .notFound] {
            XCTAssertFalse(r.title.isEmpty)
            XCTAssertFalse(r.message.isEmpty)
            XCTAssertFalse(r.systemImage.isEmpty)
        }
        XCTAssertTrue(AlbumPreviewUnavailable.noServer.message.contains("Settings"),
                      "a missing server must point at where to fix it")
    }

    // MARK: - ref ⇄ add-hit round trip (the giant ＋ reuses the Discover album add)

    func testDiscoverAlbumHitRoundTripsAnAlbumRef() {
        let ref = AppleMusicAlbumRef(storeID: "268443788", title: "Kind of Blue",
                                     artist: "Miles Davis", year: 1959,
                                     artworkURL: URL(string: "https://art/c.jpg"),
                                     url: URL(string: "https://music/268443788"))
        let hit = RipsStore.DiscoverAlbumHit(ref: ref, trackCount: 5)

        XCTAssertEqual(hit.appleMusicId, "268443788")
        XCTAssertEqual(hit.albumId, "amrec_album_268443788",
                       "the ＋ must mint the SAME provisional id the Discover row does")
        XCTAssertEqual(hit.title, "Kind of Blue")
        XCTAssertEqual(hit.artist, "Miles Davis")
        XCTAssertEqual(hit.year, 1959)
        XCTAssertEqual(hit.trackCount, 5)
        XCTAssertEqual(hit.artworkUrl, "https://art/c.jpg")
        XCTAssertEqual(hit.url, "https://music/268443788")
        // …and back again, unchanged.
        XCTAssertEqual(hit.albumRef, ref)
        // The Discover ▸ Albums row's mapper now delegates here — they cannot drift.
        XCTAssertEqual(DiscoverAlbumSearchModel.hit(from: ref).albumId, hit.albumId)
    }

    // MARK: - Catalog lookup by Apple Music album id (the "already yours" probe)

    private func album(id: String, appleMusicId: String?) -> IndexAlbum {
        var obj: [String: Any] = ["id": id, "name": "N", "artist": "A", "trackList": [String]()]
        if let appleMusicId { obj["appleMusicId"] = appleMusicId }
        return try! JSONDecoder().decode(IndexAlbum.self,
                                         from: try! JSONSerialization.data(withJSONObject: obj))
    }

    func testAppModelResolvesAlbumIdFromAppleMusicId() {
        let app = AppModel()
        app.injectDiscoverAlbumBatch(songs: [], album: album(id: "alb_x", appleMusicId: "268443788"))
        XCTAssertEqual(app.albumId(forAppleMusicId: "268443788"), "alb_x")
        XCTAssertNil(app.albumId(forAppleMusicId: "999"), "an unknown id resolves to nothing")
        // The memo must FOLLOW the catalog, not freeze at the first revision it saw.
        app.injectDiscoverAlbumBatch(songs: [], album: album(id: "alb_y", appleMusicId: "999"))
        XCTAssertEqual(app.albumId(forAppleMusicId: "999"), "alb_y",
                       "the memo is keyed on catalogRevision — a later add must be visible")
        XCTAssertEqual(app.albumId(forAppleMusicId: "268443788"), "alb_x")
    }

    /// An album with no Apple Music id can never be matched by one (and must not crash the memo).
    func testAppModelAlbumIdIgnoresAlbumsWithoutAnAppleMusicId() {
        let app = AppModel()
        app.injectDiscoverAlbumBatch(songs: [], album: album(id: "alb_plain", appleMusicId: nil))
        XCTAssertNil(app.albumId(forAppleMusicId: "alb_plain"))
    }

    // MARK: - A route that can't resolve still goes somewhere

    /// An `IntentRoute.album` for an album the catalog no longer holds used to no-op — the
    /// user tapped and NOTHING happened, which is the same experience as the blank screen.
    /// A provisional `amrec_album_<id>` is now recovered into a preview instead.
    func testAlbumPreviewRefRecoveredFromProvisionalAlbumId() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-route-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let adds = DiscoverAddsStore(fileURL: url)
        adds.addAlbum(albumId: "amrec_album_268443788", appleMusicId: "268443788",
                      title: "Kind of Blue", artist: "Miles Davis",
                      artworkUrl: "https://art/c.jpg", year: 1959,
                      url: "https://music/268443788")

        let ref = RootView.albumPreviewRef(forAlbumId: "amrec_album_268443788", discoverAdds: adds)
        XCTAssertEqual(ref?.storeID, "268443788")
        XCTAssertEqual(ref?.title, "Kind of Blue")
        XCTAssertEqual(ref?.artist, "Miles Davis")
        XCTAssertEqual(ref?.year, 1959)

        // Even with NO recorded entry, the id convention alone is enough to open a preview
        // (the screen resolves the rest from its data tiers).
        let bare = RootView.albumPreviewRef(forAlbumId: "amrec_album_999", discoverAdds: adds)
        XCTAssertEqual(bare?.storeID, "999")

        // A plain catalog album id carries no Apple Music identity → nothing to recover, and
        // the caller must surface a message rather than silently do nothing.
        XCTAssertNil(RootView.albumPreviewRef(forAlbumId: "alb_1", discoverAdds: adds))
        XCTAssertNil(RootView.albumPreviewRef(forAlbumId: "amrec_album_", discoverAdds: adds))
    }

    // MARK: - Runtime formatting (album totals cross the hour mark)

    func testRuntimeFormatsMinutesAndHours() {
        XCTAssertEqual(AlbumPreviewView.runtime(337), "5:37")
        XCTAssertEqual(AlbumPreviewView.runtime(59), "0:59")
        XCTAssertEqual(AlbumPreviewView.runtime(3_661), "1:01:01", "an album total can pass an hour")
        XCTAssertEqual(AlbumPreviewView.runtime(0), "")
    }
}
