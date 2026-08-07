import XCTest
@testable import PocketDJ

/// The pure clean-versions-only resolution (`CleanOnly`): non-explicit and unclassified
/// pass; explicit-with-clean-id substitutes; explicit-without drops; studio/profile/
/// unknown ids pass through; ripIds produces variant-suffixed ids for substitutions.
final class CleanOnlyResolveTests: XCTestCase {

    private func song(_ json: String) -> IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: Data(json.utf8))
    }

    /// sng_c clean · sng_u unclassified · sng_s explicit WITH a clean id ·
    /// sng_k explicit WITHOUT one · sng_p explicit whose PRIMARY is its own clean proof-case.
    private var songsById: [String: IndexSong] {
        [
            "sng_00000000000c": song(#"{"id":"sng_00000000000c","artist":"A","name":"Clean","explicit":false}"#),
            "sng_00000000000u": song(#"{"id":"sng_00000000000u","artist":"A","name":"Unclassified"}"#),
            "sng_00000000000d": song(#"{"id":"sng_00000000000d","artist":"A","name":"Sub","explicit":true,"appleMusicId":"P","appleMusicIdClean":"C"}"#),
            "sng_00000000000e": song(#"{"id":"sng_00000000000e","artist":"A","name":"Skip","explicit":true,"appleMusicId":"P"}"#),
        ]
    }

    func testNonExplicitAndUnclassifiedPassThrough() {
        let r = CleanOnly.resolve(ids: ["sng_00000000000c", "sng_00000000000u"], songsById: songsById)
        XCTAssertEqual(r.ids, ["sng_00000000000c", "sng_00000000000u"])
        XCTAssertTrue(r.variants.isEmpty)
    }

    func testExplicitWithCleanIdSubstitutesVariant() {
        let r = CleanOnly.resolve(ids: ["sng_00000000000d"], songsById: songsById)
        XCTAssertEqual(r.ids, ["sng_00000000000d"])
        XCTAssertEqual(r.variants["sng_00000000000d"], .clean)
    }

    func testExplicitWithoutCleanIdDrops() {
        let r = CleanOnly.resolve(ids: ["sng_00000000000c", "sng_00000000000e"], songsById: songsById)
        XCTAssertEqual(r.ids, ["sng_00000000000c"])   // the skip case is GONE, not substituted
        XCTAssertTrue(r.variants.isEmpty)
        XCTAssertTrue(CleanOnly.isSkipped(songsById["sng_00000000000e"]))
        XCTAssertFalse(CleanOnly.isSkipped(songsById["sng_00000000000c"]))
        XCTAssertFalse(CleanOnly.isSkipped(nil))
    }

    /// An explicit==false primary is ALREADY clean — never substituted (no variant stamp).
    func testExplicitPrimaryCleanFlagFalseUsesPrimaryAsClean() {
        let s = song(#"{"id":"sng_00000000000f","artist":"A","name":"P","explicit":false,"appleMusicId":"P"}"#)
        let r = CleanOnly.resolve(ids: [s.id], songsById: [s.id: s])
        XCTAssertEqual(r.ids, [s.id])
        XCTAssertNil(r.variants[s.id])
    }

    func testStudioProfileUnknownIdsPassThrough() {
        let ids = ["smp_abc", "lp_def", "pdj_xyz", "sng_unknown_id00"]
        let r = CleanOnly.resolve(ids: ids, songsById: songsById)
        XCTAssertEqual(r.ids, ids)                 // not in songsById → pass untouched
        XCTAssertTrue(r.variants.isEmpty)
    }

    func testRipIdsProduceVariantSuffixedIds() {
        let out = CleanOnly.ripIds(
            ids: ["sng_00000000000c", "sng_00000000000d", "sng_00000000000e"],
            songsById: songsById)
        XCTAssertEqual(out, ["sng_00000000000c", "sng_00000000000d_clean"])
    }
}
