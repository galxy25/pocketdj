import XCTest
@testable import PocketDJ

/// The Apple Music ♥ wire format — pure request construction and response parsing, driven
/// with no network, no account, and no MusicKit.
///
/// These assertions ARE the contract documented on `AppleMusicFavorites`: the ★
/// (`/v1/me/favorites`) and the love rating (`/v1/me/ratings/songs/{id}`) are two different
/// things, and only the rating half is reversible or readable. If a future edit collapses
/// them, or drops the exact rating body Apple requires, these fail.
final class AppleMusicFavoritesTests: XCTestCase {

    /// The `ids=` query value, percent-decoding handled by URLComponents.
    private func idsQuery(_ req: URLRequest, name: String = "ids") -> String? {
        guard let url = req.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    // MARK: - Ratings: the reversible, readable half

    func testLoveRequestIsAPutWithTheDocumentedBody() {
        let req = AppleMusicFavorites.loveRequest(appleMusicId: "1450330685")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://api.music.apple.com/v1/me/ratings/songs/1450330685")
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: req.httpBody ?? Data(), as: UTF8.self),
                       #"{"type":"rating","attributes":{"value":1}}"#,
                       "Apple requires this exact shape; `value: 1` is loved (never -1, which is a dislike)")
        // CATALOG ids, not library-songs — PocketDJ keys on `IndexSong.appleMusicId`.
        XCTAssertFalse(req.url?.path.contains("library-songs") ?? true)
    }

    func testUnloveRequestIsADeleteToTheSamePath() {
        let love = AppleMusicFavorites.loveRequest(appleMusicId: "1450330685")
        let unlove = AppleMusicFavorites.unloveRequest(appleMusicId: "1450330685")
        XCTAssertEqual(unlove.url, love.url, "un-♥ must address the very rating ♥ created")
        XCTAssertEqual(unlove.httpMethod, "DELETE")
        XCTAssertNil(unlove.httpBody, "a DELETE carries no rating body")
        XCTAssertNil(unlove.value(forHTTPHeaderField: "Content-Type"))
    }

    func testRatingsRequestBuildsTheBatchedGet() throws {
        let req = try XCTUnwrap(AppleMusicFavorites.ratingsRequest(appleMusicIds: ["1", "2", "3"]))
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.host, "api.music.apple.com")
        XCTAssertEqual(req.url?.path, "/v1/me/ratings/songs",
                       "the collection resource — a per-id path would read one song at a time")
        XCTAssertEqual(idsQuery(req), "1,2,3")
        XCTAssertNil(req.httpBody)
        XCTAssertNil(AppleMusicFavorites.ratingsRequest(appleMusicIds: []),
                     "no ids ⇒ no request (an empty `ids=` is a wasted round trip)")
    }

    // MARK: - ★: the irreversible half

    /// THE PARAMETER MUST BE TYPE-SCOPED. Apple documents this parameter as "the ids of the
    /// specific type", and the sibling add-to-library endpoint spells out the convention:
    /// "To indicate the type of resource to add, follow the ids with one of the allowed
    /// values." A bare `ids=` is accepted and silently does nothing — the worst possible
    /// failure here, because there is no favorites GET to read back and no delete endpoint
    /// to undo with, so a no-op ★ would be undetectable from inside the app.
    func testStarRequestPostsTypeScopedIdsAsAQueryParameter() throws {
        let reqs = AppleMusicFavorites.starRequests(appleMusicIds: ["1", "2", "3"])
        let req = try XCTUnwrap(reqs.first)
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.host, "api.music.apple.com")
        XCTAssertEqual(req.url?.path, "/v1/me/favorites")
        XCTAssertEqual(idsQuery(req, name: "ids[songs]"), "1,2,3",
                       "this endpoint takes ids on the QUERY string — a JSON body is silently ignored")
        XCTAssertNil(idsQuery(req, name: "ids"),
                     "an untyped `ids` would be accepted and silently no-op")
        XCTAssertNil(req.httpBody)
        XCTAssertTrue(AppleMusicFavorites.starRequests(appleMusicIds: []).isEmpty)

        // Chunked like the ratings read: an unbounded id list on a QUERY parameter builds a
        // URL long enough to be rejected once a first sync drains a real backlog.
        let many = (0 ..< 601).map(String.init)
        XCTAssertEqual(AppleMusicFavorites.starRequests(appleMusicIds: many).count, 3)

        // The ★ and the rating are distinct resources — collapsing them would make ♥
        // irreversible, since Apple ships no delete counterpart for /v1/me/favorites.
        XCTAssertNotEqual(req.url?.path, AppleMusicFavorites.loveRequest(appleMusicId: "1").url?.path)
    }

    // MARK: - Reading loves back

    func testLovedIdsKeepsOnlyValueOne() {
        let payload = """
        { "data": [
            { "id": "1", "type": "ratings", "attributes": { "value": 1 } },
            { "id": "2", "type": "ratings", "attributes": { "value": -1 } },
            { "id": "3", "type": "ratings", "attributes": { "value": 0 } },
            { "id": "4", "type": "ratings" },
            { "id": "5", "type": "ratings", "attributes": { "value": null } },
            { "type": "ratings", "attributes": { "value": 1 } },
            { "id": "7", "type": "ratings", "href": "/v1/me/ratings/songs/7",
              "attributes": { "value": 1, "playParams": { "id": "7", "kind": "song" } } }
          ] }
        """
        let loved = AppleMusicFavorites.lovedIds(fromRatingsPayload: Data(payload.utf8))
        XCTAssertEqual(loved, ["1", "7"])
        XCTAssertEqual(loved?.contains("2"), false, "-1 is an explicit DISLIKE, not a ♥")
        XCTAssertEqual(loved?.contains("3"), false)
        XCTAssertEqual(loved?.contains("4"), false, "no attributes ⇒ unrated")
        XCTAssertEqual(loved?.contains("5"), false, "a null value ⇒ unrated")
        // Row 7 proves the extra fields Apple sends (href, playParams) don't break parsing,
        // and the id-less row proves a row we can't attribute is skipped, not fatal.
    }

    /// THE DISTINCTION THAT PREVENTS MASS DATA LOSS. "The account loves none of these" and
    /// "I could not read the response" must not be the same value: the caller reconciles by
    /// unfavoriting every id the response omits, so an unreadable body reported as an empty
    /// set would tombstone the user's entire favorites library. Readable ⇒ a Set (possibly
    /// empty). Unreadable ⇒ nil, which makes `pull` abort the reconcile.
    func testLovedIdsSeparatesEmptyFromUnreadable() {
        XCTAssertEqual(AppleMusicFavorites.lovedIds(fromRatingsPayload: Data(#"{"data":[]}"#.utf8)), [],
                       "a well-formed empty batch IS a legitimate answer: loves nothing here")

        XCTAssertNil(AppleMusicFavorites.lovedIds(fromRatingsPayload: Data("{}".utf8)),
                     "no `data` key ⇒ not a ratings payload ⇒ unknown, not empty")
        XCTAssertNil(AppleMusicFavorites.lovedIds(fromRatingsPayload: Data("not json".utf8)),
                     "an HTML error page or truncated body ⇒ unknown")
        XCTAssertNil(AppleMusicFavorites.lovedIds(fromRatingsPayload: Data()),
                     "an empty body ⇒ unknown")
    }

    /// Rows are decoded INDIVIDUALLY, so a row whose types don't match the model (here `id`
    /// as a number) costs only that row — the surrounding 249 songs in a batch still parse.
    /// An all-or-nothing array decode would turn one odd row into a whole-batch unknown.
    func testATypeMismatchedRowCostsOnlyThatRow() {
        let payload = """
        { "data": [ { "id": "1", "attributes": { "value": 1 } },
                    { "id": 2, "attributes": { "value": 1 } },
                    { "id": "3", "attributes": { "value": 1 } } ] }
        """
        XCTAssertEqual(AppleMusicFavorites.lovedIds(fromRatingsPayload: Data(payload.utf8)), ["1", "3"])
    }

    // MARK: - Batching

    func testBatchesChunkExactlyIncludingTheRemainder() {
        let ids = (0 ..< 601).map(String.init)
        let chunks = AppleMusicFavorites.batches(ids)
        XCTAssertEqual(AppleMusicFavorites.batchSize, 250)
        XCTAssertEqual(chunks.map(\.count), [250, 250, 101], "a non-multiple leaves a short FINAL chunk")
        XCTAssertEqual(chunks.flatMap { $0 }, ids, "order preserved; nothing dropped or duplicated")

        XCTAssertTrue(AppleMusicFavorites.batches([]).isEmpty, "no ids ⇒ no requests")
        XCTAssertEqual(AppleMusicFavorites.batches(["a", "b"], size: 5), [["a", "b"]],
                       "fewer ids than a batch is one short batch, not none")
        XCTAssertEqual(AppleMusicFavorites.batches(["a", "b", "c"], size: 1), [["a"], ["b"], ["c"]])
        XCTAssertEqual(AppleMusicFavorites.batches((0 ..< 500).map(String.init)).map(\.count), [250, 250],
                       "an exact multiple leaves no empty trailing chunk")
        XCTAssertTrue(AppleMusicFavorites.batches(["a"], size: 0).isEmpty,
                      "a nonsense size returns nothing rather than striding forever")
    }
}
