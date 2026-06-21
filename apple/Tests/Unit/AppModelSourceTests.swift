import XCTest
@testable import PocketDJ

/// Source-tagging on AppModel: each album/song id keeps the name of the FIRST
/// source that carried it (same dedup order as `merge`), and `availableSources`
/// lists the distinct source names in first-seen order.
@MainActor
final class AppModelSourceTests: XCTestCase {

    func testSourceTagsFirstSeenWinsAcrossTwoIndexes() throws {
        // "Test Crate" first, then "Apple Music (Local)" which re-uses alb_1/sng_1.
        let a = try TestData.index()       // sourceName: "Test Crate"
        let b = try TestData.index2()      // sourceName: "Apple Music (Local)"
        let tags = AppModel.sourceTags([a, b])

        // Shared ids resolve to the FIRST source.
        XCTAssertEqual(tags.albums["alb_1"], "Test Crate")
        XCTAssertEqual(tags.songs["sng_1"], "Test Crate")
        // Ids unique to the second source resolve to it.
        XCTAssertEqual(tags.albums["alb_9"], "Apple Music (Local)")
        XCTAssertEqual(tags.songs["sng_9"], "Apple Music (Local)")
        // Ids unique to the first source resolve to it.
        XCTAssertEqual(tags.albums["alb_2"], "Test Crate")
        XCTAssertEqual(tags.songs["sng_4"], "Test Crate")
        // Distinct names in first-seen order.
        XCTAssertEqual(tags.names, ["Test Crate", "Apple Music (Local)"])
    }

    func testSourceTagsHonorsMergeOrder() throws {
        // Reverse the order: now Apple Music is first and wins the shared ids.
        let a = try TestData.index()
        let b = try TestData.index2()
        let tags = AppModel.sourceTags([b, a])
        XCTAssertEqual(tags.albums["alb_1"], "Apple Music (Local)")
        XCTAssertEqual(tags.songs["sng_1"], "Apple Music (Local)")
        XCTAssertEqual(tags.names, ["Apple Music (Local)", "Test Crate"])
    }

    func testLoadedAppExposesSourceAccessors() async throws {
        // Single-source load via the stub loader tags everything with the manifest.
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        XCTAssertEqual(app.availableSources, ["Test Crate"])
        XCTAssertEqual(app.source(ofAlbum: "alb_1"), "Test Crate")
        XCTAssertEqual(app.source(ofSong: "sng_1"), "Test Crate")
        XCTAssertNil(app.source(ofAlbum: "nope"))
    }
}
