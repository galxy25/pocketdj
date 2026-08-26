import XCTest
@testable import PocketDJ

/// The corpus decode — `timbre.json` (fold-timbre.mjs shape) → id → vector, aliases resolved.
final class TimbreCatalogTests: XCTestCase {

    private func decode(_ json: String) -> [String: SimilarityFamilies.TimbreVector]? {
        TimbreCatalog.decode(Data(json.utf8))
    }

    /// A REALISTIC row body — all 14 axes, spread across the range, none of them 0.
    ///
    /// `decode` quarantines anything failing `isUsableTimbreRow`, so the two-axis stand-in these
    /// tests used to carry is no longer a corpus row at all: it sits below the 8-axis
    /// comparability floor and is thrown away exactly like the junk it resembles. A fixture the
    /// code under test would discard proves nothing. Built from `timbreAxes` rather than typed
    /// out, so adding an axis cannot leave a fixture silently one short of the floor.
    private static func body(_ base: Double, override: [String: String] = [:]) -> String {
        SimilarityFamilies.timbreAxes.enumerated().map { i, axis in
            "\"\(axis)\":" + (override[axis] ?? String(format: "%.4f", base + Double(i) * 0.05))
        }.joined(separator: ",")
    }

    func testDecodeResolvesAliasesOneHopAndNeverChains() throws {
        let doc = """
        {"v":1,"songs":{
          "sng_a":{"v":1,"f":{\(Self.body(0.1))}},
          "sng_b":{"alias":"sng_a"},
          "sng_c":{"alias":"sng_b"},
          "sng_d":{"alias":"sng_missing"}
        }}
        """
        let map = try XCTUnwrap(decode(doc))
        XCTAssertEqual(map["sng_a"]?["punch"], 0.4)
        XCTAssertEqual(map["sng_b"]?["punch"], 0.4, "an alias resolves to its target's vector")
        XCTAssertNil(map["sng_c"],
                     "an alias to an alias is a BUILD error upstream and resolves to nothing "
                     + "rather than chasing a chain (build-rec-features' timbreMap rule, mirrored)")
        XCTAssertNil(map["sng_d"], "a dangling alias must not pretend coverage exists")
    }

    func testDecodeSurvivesTheRealCorpusNullAxis() throws {
        // REAL DATA, not paranoia: the shipping corpus carries `"punch":null` on 2 of 15,489 rows
        // (analyze-timbre's norm() returned None when the HPSS energy was zero). A strict
        // [String: Double] decode THROWS on the first one and silently discards the whole corpus —
        // that is the failure this test pins shut, and it is unchanged.
        //
        // What changed is the row's own fate: a present-but-null axis means the extractor could
        // not produce the value, so the 14-finite-numbers contract is violated and the row is a
        // failed capture, not a partial one. It is quarantined; the DOCUMENT still decodes.
        let doc = """
        {"v":1,"songs":{
          "sng_null":{"v":1,"f":{\(Self.body(0.1, override: ["punch": "null"]))}},
          "sng_ok":{"v":1,"f":{\(Self.body(0.2))}}
        }}
        """
        let map = try XCTUnwrap(decode(doc))
        XCTAssertNil(map["sng_null"], "a null axis is a failed capture, not a partial one")
        XCTAssertEqual(map["sng_ok"]?["bright"], 0.2, "…and the rest of the corpus survives it")
    }

    /// THE FAKE SIMILARITY CLUSTER. 30 rows of the shipping corpus carry 7+ axes at exactly 0.0.
    /// They are all the SAME POINT, so they are each other's nearest neighbours and get
    /// recommended in a little self-referential clump with no explanation a listener could
    /// recognise. That is strictly worse than having no vector — a missing vector makes the term
    /// fail open and the row ranks on metadata instead.
    ///
    /// Quarantined at the READER as well as at the fold, because a corpus published before the
    /// fold learned this check is already cached on devices.
    func testDecodeQuarantinesDegenerateRows() throws {
        let zeroed = Dictionary(uniqueKeysWithValues:
            SimilarityFamilies.timbreAxes.prefix(9).map { ($0, "0") })
        let doc = """
        {"v":1,"songs":{
          "sng_zeros":{"v":1,"f":{\(Self.body(0.1, override: zeroed))}},
          "sng_thin":{"v":1,"f":{"bright":0.5,"punch":0.9}},
          "sng_ok":{"v":1,"f":{\(Self.body(0.1))}},
          "sng_twin":{"alias":"sng_zeros"}
        }}
        """
        let map = try XCTUnwrap(decode(doc))
        XCTAssertNil(map["sng_zeros"], "7+ axes pinned at exactly 0.0 is a failed capture")
        XCTAssertNil(map["sng_thin"], "below the 8-axis floor it cannot be compared to anything")
        XCTAssertNil(map["sng_twin"], "…and an alias must not resurrect what was quarantined")
        XCTAssertEqual(map["sng_ok"]?["punch"], 0.4)
        XCTAssertEqual(map.count, 1)
    }

    /// The predicate itself, pinned — the fold (`scripts/lib/timbre-hygiene.mjs`), the Lambda and
    /// `analyze-timbre.py` all carry the same rule, and a drift in any one of them shows up as a
    /// corpus whose rows mean different things to different readers.
    func testIsUsableTimbreRowPinsTheThresholds() {
        var good = SimilarityFamilies.TimbreVector()
        for (i, a) in SimilarityFamilies.timbreAxes.enumerated() { good[a] = 0.1 + Double(i) * 0.05 }
        XCTAssertTrue(SimilarityFamilies.isUsableTimbreRow(good))

        var sevenZeros = good
        for a in SimilarityFamilies.timbreAxes.prefix(7) { sevenZeros[a] = 0 }
        XCTAssertFalse(SimilarityFamilies.isUsableTimbreRow(sevenZeros), "7 zeros is the bar")

        var sixZeros = good
        for a in SimilarityFamilies.timbreAxes.prefix(6) { sixZeros[a] = 0 }
        XCTAssertTrue(SimilarityFamilies.isUsableTimbreRow(sixZeros),
                      "…and 6 is not — a dark, quiet record is still a record")

        var thin = SimilarityFamilies.TimbreVector()
        for a in SimilarityFamilies.timbreAxes.prefix(7) { thin[a] = 0.5 }
        XCTAssertFalse(SimilarityFamilies.isUsableTimbreRow(thin), "7 axes is below the floor")
        thin[SimilarityFamilies.timbreAxes[7]] = 0.5
        XCTAssertTrue(SimilarityFamilies.isUsableTimbreRow(thin), "…8 is the floor")

        var nonFinite = good
        nonFinite["punch"] = .nan
        XCTAssertFalse(SimilarityFamilies.isUsableTimbreRow(nonFinite))
    }

    func testDecodeRejectsGarbageWholesale() {
        XCTAssertNil(decode("<!doctype html><html>SPA shell</html>"),
                     "the CDN's SPA-fallback HTML must never be cached as a corpus")
        XCTAssertNil(decode("{\"v\":1}"), "no songs key ⇒ not a corpus")
    }
}
