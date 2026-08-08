import XCTest
@testable import PocketDJ

/// MwF wire models — lenient decode of the broker's state payloads (the JukeboxGuest
/// doctrine: partial/older/newer payloads must never break the app) + the score helper.
final class MwFModelsTests: XCTestCase {

    func testStateDecodesLeniently() throws {
        // Minimal payload: missing fields, an unknown field, empty arrays.
        let json = """
        { "v": 1, "sessionId": "abcd2345", "theme": "90s bangers",
          "someFutureField": { "x": 1 },
          "members": [], "suggestions": [],
          "settings": { "turnSeconds": 60 } }
        """
        let st = try JSONDecoder().decode(MwFState.self, from: Data(json.utf8))
        XCTAssertEqual(st.sessionId, "abcd2345")
        XCTAssertEqual(st.theme, "90s bangers")
        XCTAssertEqual(st.members, [])
        XCTAssertEqual(st.settings?.turnSeconds, 60)
        XCTAssertNil(st.settings?.acceptOutsideTurn)
        XCTAssertNil(st.ended)
        XCTAssertNil(st.turn)
        XCTAssertNil(st.collection)
        XCTAssertNil(st.you)

        // A fuller payload round-trips the nested rows.
        let full = """
        { "sessionId": "abcd2345", "ended": false, "expiresAt": 123.0,
          "members": [ { "memberId": "mb_1", "name": "Ada", "score": 3, "isLeader": true } ],
          "turn": { "memberId": "mb_1", "index": 4, "deadline": 999.0 },
          "suggestions": [ { "id": "sg_1", "memberId": "mb_1", "title": "T", "status": "accepted",
                             "plusOnes": ["mb_2"], "match": { "songId": "sng_1", "lengthMs": 1000 } } ],
          "collection": [ { "appleMusicId": "42", "title": "T", "suggestedBy": "mb_1" } ],
          "you": { "memberId": "mb_2" }, "apiBase": "https://broker.test" }
        """
        let st2 = try JSONDecoder().decode(MwFState.self, from: Data(full.utf8))
        XCTAssertEqual(st2.members?.first?.score, 3)
        XCTAssertEqual(st2.turn?.index, 4)
        XCTAssertEqual(st2.suggestions?.first?.plusOnes, ["mb_2"])
        XCTAssertEqual(st2.suggestions?.first?.match?.songId, "sng_1")
        XCTAssertEqual(st2.collection?.first?.appleMusicId, "42")
        XCTAssertEqual(st2.you?.memberId, "mb_2")
        XCTAssertEqual(st2.apiBase, "https://broker.test")
    }

    func testScoreDerivationHelper() throws {
        let json = """
        { "sessionId": "abcd2345",
          "members": [ { "memberId": "mb_1", "score": 5 }, { "memberId": "mb_2", "score": 2 } ] }
        """
        let st = try JSONDecoder().decode(MwFState.self, from: Data(json.utf8))
        XCTAssertEqual(st.score(of: "mb_1"), 5)
        XCTAssertEqual(st.score(of: "mb_2"), 2)
        XCTAssertEqual(st.score(of: "mb_unknown"), 0)
        XCTAssertEqual(st.score(of: nil), 0)
    }

    func testSessionEntryPersistsAndFlagsLeader() throws {
        let leader = MwFSessionEntry(id: "abcd2345", memberId: "mb_1", memberKey: "mk",
                                     leaderKey: "lk", name: "S", theme: "T", url: nil,
                                     apiBase: nil, expiresAt: nil, pocketId: nil, joinedAt: 1)
        XCTAssertTrue(leader.isLeader)
        let member = MwFSessionEntry(id: "abcd2346", memberId: "mb_2", memberKey: "mk2",
                                     leaderKey: nil, name: nil, theme: nil, url: nil,
                                     apiBase: nil, expiresAt: nil, pocketId: nil, joinedAt: 2)
        XCTAssertFalse(member.isLeader)
        let data = try JSONEncoder().encode([leader, member])
        let back = try JSONDecoder().decode([MwFSessionEntry].self, from: data)
        XCTAssertEqual(back, [leader, member])
    }
}
