import XCTest
@testable import PocketDJ

/// The stable Discover edition re-rank: same-recording groups anchor at first appearance,
/// the preferred edition leads within a group, unclassified hits keep their order, and
/// `DiscoverHit` decodes the server's optional `explicit` field tolerantly.
@MainActor
final class DiscoverExplicitRankingTests: XCTestCase {

    private func hit(_ id: String, _ title: String, _ artist: String, explicit: Bool?) -> RipsStore.DiscoverHit {
        RipsStore.DiscoverHit(appleMusicId: id, title: title, artist: artist,
                              songId: "amrec_\(id)", explicit: explicit)
    }

    func testCleanFirstDefaultWithinGroup() {
        let hits = [
            hit("1", "Pulse", "Aria", explicit: true),
            hit("2", "Pulse", "Aria", explicit: false),
            hit("3", "Other Song", "Bento", explicit: true),
        ]
        let ranked = RipsStore.DiscoverExplicitRanking.rank(hits, preferExplicit: false)
        // Group "Pulse/Aria" anchors first; the clean edition leads it. Other group after.
        XCTAssertEqual(ranked.map(\.appleMusicId), ["2", "1", "3"])
    }

    func testExplicitFirstWhenPreferenceFlipped() {
        let hits = [
            hit("1", "Pulse", "Aria", explicit: false),
            hit("2", "Pulse", "Aria", explicit: true),
        ]
        let ranked = RipsStore.DiscoverExplicitRanking.rank(hits, preferExplicit: true)
        XCTAssertEqual(ranked.map(\.appleMusicId), ["2", "1"])
    }

    func testGroupsKeepRelativeOrderAcrossGroups() {
        let hits = [
            hit("a1", "Alpha", "X", explicit: true),
            hit("b1", "Beta", "Y", explicit: false),
            hit("a2", "Alpha", "X", explicit: false),
            hit("b2", "Beta", "Y", explicit: true),
        ]
        let ranked = RipsStore.DiscoverExplicitRanking.rank(hits, preferExplicit: false)
        // Alpha group (anchored first) reorders internally; Beta group follows intact.
        XCTAssertEqual(ranked.map(\.appleMusicId), ["a2", "a1", "b1", "b2"])
    }

    func testUnclassifiedHitsUntouched() {
        let hits = [
            hit("1", "Pulse", "Aria", explicit: nil),
            hit("2", "Pulse", "Aria", explicit: nil),
            hit("3", "Drift", "Aria", explicit: nil),
        ]
        // No classification anywhere → identical order for both preferences.
        XCTAssertEqual(RipsStore.DiscoverExplicitRanking.rank(hits, preferExplicit: false).map(\.appleMusicId),
                       ["1", "2", "3"])
        XCTAssertEqual(RipsStore.DiscoverExplicitRanking.rank(hits, preferExplicit: true).map(\.appleMusicId),
                       ["1", "2", "3"])
    }

    func testDiscoverHitDecodesWithAndWithoutExplicit() throws {
        let with = try JSONDecoder().decode(RipsStore.DiscoverHit.self, from: Data("""
        {"appleMusicId":"1","title":"T","artist":"A","songId":"amrec_1","explicit":true}
        """.utf8))
        XCTAssertEqual(with.explicit, true)
        let without = try JSONDecoder().decode(RipsStore.DiscoverHit.self, from: Data("""
        {"appleMusicId":"1","title":"T","artist":"A","songId":"amrec_1"}
        """.utf8))
        XCTAssertNil(without.explicit)   // older servers omit the key — tolerated
    }
}
