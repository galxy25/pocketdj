import XCTest
@testable import PocketDJ

/// EVENT-DRIVEN cloud timbre enrollment.
///
/// The thing under test is NOT "does a button call a function" — it is that enrollment is hung
/// off the ONE seam every membership mutation shares, so a surface added tomorrow is covered
/// without anyone remembering to wire it. `CollectionsStore.save()` is that seam; these tests
/// drive real store mutations (including the paths that BYPASS `addSongs(_:to:)`) and assert the
/// enrollment saw them.
@MainActor
final class TimbreEnrollmentTests: XCTestCase {
    private func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-timbre-\(name)-\(UUID().uuidString).json")
    }

    // MARK: the pure membership union

    func testMemberIdUnionCoversPocketsAndNestedPlaylistNodes() {
        let pocket = Pocket(id: "pkt_1", name: "P", songIds: ["sng_a", "sng_b"])
        let leaf = PlaylistNode(nodeId: "n1", kind: .song, songId: "sng_c")
        let nested = PlaylistNode(nodeId: "n2", kind: .sequence, children: [
            PlaylistNode(nodeId: "n3", kind: .song, songId: "sng_d"),
        ])
        let pl = Playlist(id: "pl_1", name: "L", sequences: [
            PlaylistNode(nodeId: "s1", kind: .sequence, children: [leaf, nested]),
        ])
        let doc = CollectionsDocument(schemaVersion: 6, pockets: [pocket], playlists: [pl],
                                      setlists: [], folders: [], lastAddTarget: nil,
                                      recentAddTargets: nil)
        XCTAssertEqual(CollectionsStore.memberIdUnion(doc), ["sng_a", "sng_b", "sng_c", "sng_d"])
    }

    func testMemberIdUnionDoesNotExpandAlbumOrPocketNodes() {
        // Membership, not resolution — matching songIdsInNodes. Expanding here would enroll songs
        // the user never actually put in a collection.
        let pl = Playlist(id: "pl_1", name: "L", sequences: [
            PlaylistNode(nodeId: "s1", kind: .sequence, children: [
                PlaylistNode(nodeId: "n1", kind: .album, albumId: "alb_x"),
                PlaylistNode(nodeId: "n2", kind: .pocket, pocketId: "pkt_x"),
            ]),
        ])
        let doc = CollectionsDocument(schemaVersion: 6, pockets: [], playlists: [pl],
                                      setlists: [], folders: [], lastAddTarget: nil, recentAddTargets: nil)
        XCTAssertTrue(CollectionsStore.memberIdUnion(doc).isEmpty)
    }

    // MARK: the enrollment itself

    func testEnrollsOnlyNewIdsAndIsANoOpForAlreadyEnrolled() async {
        let e = TimbreEnrollment(fileURL: tmpURL("new"))
        var sent: [[String]] = []
        e.send = { ids in sent.append(ids); return true }

        XCTAssertEqual(e.enroll(memberIds: ["sng_a", "sng_b"]), 2)
        XCTAssertEqual(e.enroll(memberIds: ["sng_a", "sng_b"]), 0)   // re-adding an enrolled song
        XCTAssertEqual(e.enroll(memberIds: ["sng_a", "sng_c"]), 1)   // only the genuinely new one
        await drain()
        XCTAssertEqual(sent.flatMap { $0 }.sorted(), ["sng_a", "sng_b", "sng_c"])
    }

    func testAFailedSendLEAVESTheIdsQueuedRatherThanDroppingThem() async {
        // Offline safety: an add must never be lost because the server was unreachable, and must
        // never block on it either.
        let url = tmpURL("offline")
        let e = TimbreEnrollment(fileURL: url)
        e.send = { _ in false }
        e.enroll(memberIds: ["sng_a", "sng_b"])
        await drain()
        XCTAssertEqual(e.pendingCount, 2)

        // A LATER drain (relaunch, connectivity returns) flushes the same ids.
        var sent: [String] = []
        e.send = { ids in sent.append(contentsOf: ids); return true }
        e.drain()
        await drain()
        XCTAssertEqual(sent.sorted(), ["sng_a", "sng_b"])
        XCTAssertEqual(e.pendingCount, 0)
    }

    func testQueueAndEnrollmentSurviveAReload() async {
        let url = tmpURL("reload")
        let first = TimbreEnrollment(fileURL: url)
        first.send = { _ in false }
        first.enroll(memberIds: ["sng_a"])
        await drain()

        let second = TimbreEnrollment(fileURL: url)
        XCTAssertEqual(second.pendingCount, 1)             // still queued after a relaunch
        XCTAssertEqual(second.enroll(memberIds: ["sng_a"]), 0)  // and still known as enrolled
    }

    // MARK: the store seam — including the paths that bypass addSongs(_:to:)

    func testAddingToAPocketEnrollsThroughTheStoreSaveFunnel() async {
        let store = CollectionsStore(fileURL: tmpURL("store"))
        let e = TimbreEnrollment(fileURL: tmpURL("store-enroll"))
        var sent: [String] = []
        e.send = { ids in sent.append(contentsOf: ids); return true }
        store.timbreEnrollment = e

        let pocket = store.createPocket("P")
        // addSong(_:toPocket:) is the MusicWithFriends/CarPlay bypass — it never goes through
        // addSongs(_:to:), which is exactly why a per-call-site hook would already be incomplete.
        store.addSong("sng_bypass", toPocket: pocket.id)
        await settle()
        XCTAssertTrue(sent.contains("sng_bypass"))
    }

    func testAReorderOrRenameEnrollsNothingNew() async {
        let store = CollectionsStore(fileURL: tmpURL("noop"))
        let e = TimbreEnrollment(fileURL: tmpURL("noop-enroll"))
        var calls = 0
        e.send = { _ in calls += 1; return true }
        store.timbreEnrollment = e

        let pocket = store.createPocket("P")
        store.addSong("sng_a", toPocket: pocket.id)
        await settle()
        let after = calls
        store.renamePocket(pocket.id, "P2")            // a save with no membership change
        await settle()
        XCTAssertEqual(calls, after)
    }

    /// Let the enrollment's detached send task run.
    private func drain() async { try? await Task.sleep(nanoseconds: 120_000_000) }
    /// Let the store's detached write + enrollment hop run.
    private func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }
}
