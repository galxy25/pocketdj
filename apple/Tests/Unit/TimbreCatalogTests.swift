import XCTest
@testable import PocketDJ

/// The corpus decode — `timbre.json` (fold-timbre.mjs shape) → id → vector, aliases resolved.
final class TimbreCatalogTests: XCTestCase {

    private func decode(_ json: String) -> [String: SimilarityFamilies.TimbreVector]? {
        TimbreCatalog.decode(Data(json.utf8))
    }

    func testDecodeResolvesAliasesOneHopAndNeverChains() throws {
        let doc = """
        {"v":1,"songs":{
          "sng_a":{"v":1,"f":{"bright":0.5,"punch":0.9}},
          "sng_b":{"alias":"sng_a"},
          "sng_c":{"alias":"sng_b"},
          "sng_d":{"alias":"sng_missing"}
        }}
        """
        let map = try XCTUnwrap(decode(doc))
        XCTAssertEqual(map["sng_a"]?["punch"], 0.9)
        XCTAssertEqual(map["sng_b"]?["punch"], 0.9, "an alias resolves to its target's vector")
        XCTAssertNil(map["sng_c"],
                     "an alias to an alias is a BUILD error upstream and resolves to nothing "
                     + "rather than chasing a chain (build-rec-features' timbreMap rule, mirrored)")
        XCTAssertNil(map["sng_d"], "a dangling alias must not pretend coverage exists")
    }

    func testDecodeSurvivesTheRealCorpusNullAxis() throws {
        // REAL DATA, not paranoia: the 2026-08-11 corpus carries `"punch":null` on 2 of 12,049
        // rows (analyze-timbre's norm() returns None when the HPSS energy is zero). A strict
        // [String: Double] decode throws on the first one and silently discards the WHOLE
        // corpus — the failure this test pins shut.
        let doc = """
        {"v":1,"songs":{
          "sng_null":{"v":1,"f":{"bright":0.5,"punch":null,"busy":0.7}},
          "sng_ok":{"v":1,"f":{"bright":0.2}}
        }}
        """
        let map = try XCTUnwrap(decode(doc))
        XCTAssertEqual(map["sng_null"]?["bright"], 0.5)
        XCTAssertNil(map["sng_null"]?["punch"], "the null axis drops; the row survives")
        XCTAssertEqual(map["sng_null"]?.count, 2)
        XCTAssertEqual(map["sng_ok"]?["bright"], 0.2, "…and so does the rest of the corpus")
    }

    func testDecodeRejectsGarbageWholesale() {
        XCTAssertNil(decode("<!doctype html><html>SPA shell</html>"),
                     "the CDN's SPA-fallback HTML must never be cached as a corpus")
        XCTAssertNil(decode("{\"v\":1}"), "no songs key ⇒ not a corpus")
    }
}
