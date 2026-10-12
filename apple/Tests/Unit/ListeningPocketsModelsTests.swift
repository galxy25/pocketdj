import XCTest
@testable import PocketDJ

/// Results v1 decode against the CLOUD's own generated `results.sample.json` (copied verbatim
/// from `scripts/lambda/listening-pockets/fixtures/` into `Tests/Fixtures/listening-pockets-
/// results.json`), plus the leniency contract: unknown dims kept raw, extra keys ignored, a bad
/// element drops alone, the empty shape decodes.
final class ListeningPocketsModelsTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "listening-pockets-results",
                                                            withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testDecodesTheCloudFixture() throws {
        let r = try JSONDecoder().decode(ListeningPocketsResults.self, from: try fixture())
        XCTAssertEqual(r.v, 1)
        XCTAssertNotNil(r.generatedAtMs)
        XCTAssertFalse(r.stale)
        XCTAssertEqual(r.algoVersion, 1)
        XCTAssertEqual(r.baseline?.thin, false)
        XCTAssertFalse(r.pockets.isEmpty)
        XCTAssertFalse(r.patterns.isEmpty)
        // Count parity with the raw JSON — no element silently dropped.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture()) as? [String: Any])
        XCTAssertEqual(r.pockets.count, (raw["pockets"] as? [Any])?.count)
        XCTAssertEqual(r.patterns.count, (raw["patterns"] as? [Any])?.count)

        let p = try XCTUnwrap(r.pockets.first)
        XCTAssertTrue(p.id.hasPrefix("pk_"))
        XCTAssertGreaterThanOrEqual(p.memberCount, 3)
        XCTAssertEqual(p.members.count, p.memberCount)
        XCTAssertFalse(p.title.isEmpty)
        XCTAssertFalse(p.features.isEmpty)
        XCTAssertNotNil(p.dayType)
        XCTAssertNotNil(p.timeBucket)
        for pocket in r.pockets {
            XCTAssertGreaterThanOrEqual(pocket.endMs, pocket.startMs)
            XCTAssertEqual(pocket.songIds.count, pocket.members.count)
        }

        // Direction of travel survives the round trip: a trip-keyed pattern carries its ctx.
        let trip = try XCTUnwrap(r.patterns.first { $0.ctx?.isTrip == true })
        XCTAssertTrue(trip.id.hasPrefix("pt_"))
        XCTAssertGreaterThanOrEqual(trip.occurrences, 2)
        XCTAssertFalse(trip.topSongs.isEmpty)
        XCTAssertEqual(trip.ctx?.tripId.map { $0.hasPrefix("trp_") }, true)
        // Its trip feature names the same id, and the label snapshot resolves it.
        let tf = try XCTUnwrap(trip.features.first { $0.kind == .trip })
        XCTAssertEqual(tf.contextTag?.tripId, trip.ctx?.tripId)
        XCTAssertNotNil(r.snapshotLabel(for: try XCTUnwrap(tf.contextTag)))
        // A defining BPM range.
        let bpm = try XCTUnwrap(trip.numeric["bpm"])
        XCTAssertTrue(bpm.defining)
        XCTAssertLessThanOrEqual(bpm.lo, bpm.hi)
    }

    func testUnknownDimAndExtraKeysAreTolerated() throws {
        let json = """
        {"v":1,"generatedAtMs":1760100300000,"stale":true,"futureTopLevel":{"x":1},
         "algo":{"version":2,"params":{"anything":[1,2]}},
         "pockets":[
          {"id":"pk_000000000001","startMs":1,"endMs":2.0,"memberCount":3.0,"skippedCount":0,
           "members":[{"eventId":"E1","songId":"sng_1","atMs":1},{"eventId":"E2","atMs":2},
                      {"eventId":"E3","songId":"sng_3","atMs":3,"extra":true}],
           "ctx":{"kind":"wormhole"},
           "features":[{"dim":"weather","value":"rain","label":"Rain","share":0.8,"lift":3,"score":0.9,"newKey":1},
                       {"dim":"genre","label":"no value"}],
           "numeric":{"bpm":{"center":120,"lo":118,"hi":124,"coverage":1,"dispersionRatio":null,"defining":true},
                      "tempoFeel":{"foo":"bar"}},
           "harmonic":{"rate":"bad"},
           "title":"T","patternId":null},
          {"noId":true},
          "not even an object"
         ],
         "patterns":[{"id":"pt_000000000001","title":"P","pocketIds":["pk_000000000001","pk_unknown"],
                      "features":[],"numeric":{},"topSongs":[{"songId":"sng_1","plays":2},{"plays":1}]}]}
        """
        let r = try JSONDecoder().decode(ListeningPocketsResults.self, from: Data(json.utf8))
        XCTAssertTrue(r.stale)
        XCTAssertEqual(r.algoVersion, 2)
        XCTAssertEqual(r.pockets.count, 1, "malformed pockets drop alone")
        let p = try XCTUnwrap(r.pockets.first)
        XCTAssertEqual(p.memberCount, 3, "a 3.0 still reads as an Int")
        XCTAssertEqual(p.members.map(\.songId), ["sng_1", "sng_3"], "a member without a songId drops alone")
        XCTAssertNil(p.ctx, "an unknown ctx kind reads as no context")
        XCTAssertEqual(p.features.count, 1)
        XCTAssertEqual(p.features.first?.dim, "weather", "unknown dims are kept as raw strings")
        XCTAssertNil(p.features.first?.kind)
        XCTAssertEqual(p.numeric.keys.sorted(), ["bpm"])
        XCTAssertNil(p.numeric["bpm"]?.dispersionRatio)
        XCTAssertNil(p.harmonic)
        let pt = try XCTUnwrap(r.patterns.first)
        XCTAssertEqual(pt.occurrences, 2, "defaults to pocketIds.count")
        XCTAssertEqual(pt.songIds, ["sng_1"])
        XCTAssertEqual(pt.key, pt.id)
    }

    func testEmptyShapeDecodes() throws {
        let json = #"{"v":1,"generatedAtMs":null,"stale":false,"algo":{"version":1,"params":{}},"pockets":[],"patterns":[]}"#
        let r = try JSONDecoder().decode(ListeningPocketsResults.self, from: Data(json.utf8))
        XCTAssertNil(r.generatedAtMs)
        XCTAssertTrue(r.pockets.isEmpty)
        XCTAssertTrue(r.patterns.isEmpty)
        XCTAssertEqual(r, ListeningPocketsResults.empty.with(algoVersion: 1))
    }

    /// The app's bundled UI fixture (`PDJ_POCKETS_FIXTURE`) must decode with the same decoder.
    @MainActor
    func testBundledAppFixtureDecodes() throws {
        let r = try XCTUnwrap(ListeningPocketsService.fixtureResults(), "listening-pockets-fixture.json is in the app bundle")
        XCTAssertEqual(r.pockets.count, 2)
        XCTAssertEqual(r.patterns.count, 1)
    }

    /// Upload rows encode the §5.1 shape — nullable fields as explicit nulls.
    func testUploadEventEncodesExplicitNulls() throws {
        let e = ListeningPocketsUploadEvent(id: "ID", songId: "sng_1", atMs: 60_000, ord: 0,
                                            tzOffsetMin: nil, source: "mix", outcome: "unknown",
                                            fraction: nil, originInstallId: nil, artist: nil,
                                            carPlay: nil, ctx: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        for key in ["tzOffsetMin", "fraction", "originInstallId", "artist", "carPlay", "ctx"] {
            XCTAssertTrue(obj[key] is NSNull, "\(key) must be an explicit null")
        }
        XCTAssertEqual(obj["outcome"] as? String, "unknown")
    }
}

private extension ListeningPocketsResults {
    func with(algoVersion: Int?) -> ListeningPocketsResults {
        var copy = self
        copy.algoVersion = algoVersion
        return copy
    }
}
