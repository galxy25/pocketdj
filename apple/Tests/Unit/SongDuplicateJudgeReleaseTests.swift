import XCTest
@testable import PocketDJ

/// The SAME-RELEASE duplicate tier (Levi 2026-10-19): one track on one album indexed twice with
/// its feat. credit moved between title and artist, or a respelt artist — invisible to the
/// exact name+artist key. Cases are the real twins found in Levi's collections.
@MainActor
final class SongDuplicateJudgeReleaseTests: XCTestCase {
    private typealias J = SongDuplicateJudge
    private func id(_ n: String, _ a: String, _ al: String?, am: String? = nil) -> J.Identity {
        .init(name: n, artist: a, album: al, appleMusicId: am)
    }

    func testFeatCreditMovedBetweenTitleAndArtist() {
        XCTAssertTrue(J.isSameReleaseDuplicate(
            id("Never Let Me Down", "Kanye West, Jay-Z & J-Ivy", "The College Dropout"),
            id("Never Let Me Down (feat. JAŸ-Z & J. Ivy)", "Kanye West", "The College Dropout")))
        XCTAssertTrue(J.isSameReleaseDuplicate(
            id("Juicy (feat. Static Major)", "Pretty Ricky", "Bluestars"),
            id("Juicy Featuring Static Major", "Pretty Ricky", "Bluestars")))
        XCTAssertTrue(J.isSameReleaseDuplicate(
            id("Rather Be feat. Jess Glynne", "Clean Bandit, Jess Glynne", "New Eyes"),
            id("Rather Be (feat. Jess Glynne)", "Clean Bandit", "New Eyes")))
    }

    func testRespeltArtist() {
        XCTAssertTrue(J.isSameReleaseDuplicate(
            id("All I Need", "JAY Z", "The Blueprint"), id("All I Need", "JAŸ-Z", "The Blueprint")))
        XCTAssertTrue(J.isSameReleaseDuplicate(
            id("Hood Hop", "J Kwon", "Hood Hop"), id("Hood Hop", "J-Kwon", "Hood Hop")))
    }

    func testDifferentRecordingsStayDistinct() {
        // Different album ⇒ never this tier.
        XCTAssertFalse(J.isSameReleaseDuplicate(
            id("Never Let Me Down", "Kanye West", "The College Dropout"),
            id("Never Let Me Down", "Kanye West", "Late Registration")))
        // Both catalogued, ids differ ⇒ distinct catalog recordings.
        XCTAssertFalse(J.isSameReleaseDuplicate(
            id("E.T.", "Katy Perry", "Teenage Dream", am: "716084374"),
            id("E.T. (feat. Kanye West)", "Katy Perry", "Teenage Dream", am: "716085557")))
        // Both credit features, none shared ⇒ a different version.
        XCTAssertFalse(J.isSameReleaseDuplicate(
            id("Goodies (feat. Petey Pablo)", "Ciara", "Goodies"),
            id("Goodies (feat. T.I. & Jazze Pha)", "Ciara", "Goodies")))
        // Version markers stay in the title.
        XCTAssertFalse(J.isSameReleaseDuplicate(
            id("Sap (Live)", "A", "Album"), id("Sap", "A", "Album")))
        // Non-Latin titles keep their letters (an ASCII strip made every Korean title "").
        XCTAssertFalse(J.isSameReleaseDuplicate(
            id("희생양", "Epik High", "Remapping the Human Soul"),
            id("거미줄", "Epik High", "Remapping the Human Soul")))
        // No album ⇒ not comparable at this tier.
        XCTAssertFalse(J.isSameReleaseDuplicate(id("X", "A", nil), id("X (feat. B)", "A", nil)))
    }

    func testSeenCatchesBothTiers() {
        var seen = J.Seen()
        XCTAssertTrue(seen.insert(id("Never Let Me Down", "Kanye West, Jay-Z & J-Ivy", "The College Dropout")))
        XCTAssertFalse(seen.insert(id("Never Let Me Down (feat. JAŸ-Z & J. Ivy)", "Kanye West", "The College Dropout")))
        XCTAssertFalse(seen.insert(id("never let me down", "kanye west, jay-z & j-ivy", nil)))   // exact tier
        XCTAssertTrue(seen.insert(id("All Falls Down", "Kanye West", "The College Dropout")))
    }

    /// Survivor = first twin with a catalog id, moved into the group's earliest slot.
    func testCollapsePlanPrefersCatalogCopy() {
        let table: [String: J.Identity] = [
            "a": id("Never Let Me Down", "Kanye West, Jay-Z & J-Ivy", "The College Dropout"),
            "b": id("All Falls Down", "Kanye West", "The College Dropout"),
            "c": id("Never Let Me Down (feat. JAŸ-Z & J. Ivy)", "Kanye West", "The College Dropout", am: "1"),
            "d": id("Never Let Me Down", "Kanye West, Jay-Z & J-Ivy", "The College Dropout"),
        ]
        let plan = J.collapsePlan(["a", "b", "c", "d", "zz"]) { table[$0] }
        XCTAssertEqual(plan.rename, ["a": "c"])
        XCTAssertEqual(plan.drop, ["c", "d"])
    }

    /// End to end through the store: pocket + playlist, survivor in the earliest slot, and an
    /// unknown id untouched.
    func testStoreRemovesDuplicates() {
        let app = AppModel()
        func song(_ sid: String, _ n: String, _ a: String, am: String? = nil) -> IndexSong {
            var o: [String: Any] = ["id": sid, "name": n, "artist": a, "albumId": "alb_cd"]
            if let am { o["appleMusicId"] = am }
            return try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(withJSONObject: o))
        }
        app.injectDiscoverAlbumAdd(try! JSONDecoder().decode(IndexAlbum.self, from: try! JSONSerialization.data(
            withJSONObject: ["id": "alb_cd", "artist": "Kanye West", "name": "The College Dropout", "trackList": []])))
        app.injectDiscoverAdd(song("s1", "Never Let Me Down", "Kanye West, Jay-Z & J-Ivy"))
        app.injectDiscoverAdd(song("s2", "All Falls Down", "Kanye West"))
        app.injectDiscoverAdd(song("s3", "Never Let Me Down (feat. JAŸ-Z & J. Ivy)", "Kanye West", am: "9"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-dedupe-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let collections = CollectionsStore(fileURL: url)
        collections.app = app

        let p = collections.createPocket("🏋🏾‍♀️", songIds: ["s1", "s2", "s3", "ghost"])
        XCTAssertEqual(collections.removeDuplicates(inPocket: p.id), 1)
        XCTAssertEqual(collections.pocket(p.id)?.songIds, ["s3", "s2", "ghost"])
        XCTAssertEqual(collections.removeDuplicates(inPocket: p.id), 0)   // idempotent

        let pl = collections.createPlaylist("Mix", songIds: ["s1", "s2", "s3"])
        XCTAssertEqual(collections.removeDuplicatesEverywhere(), 1)
        XCTAssertEqual(collections.playableIds(forPlaylist: pl.id), ["s3", "s2"])
    }
}
