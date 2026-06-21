import XCTest
@testable import PocketDJ

/// Tests the pure Shazam → catalog matcher: the `norm()` folding rules and the
/// title+artist resolution against a fixture catalog (`TestData`). No ShazamKit.
final class ShazamCatalogMatchTests: XCTestCase {

    private func songs() throws -> [IndexSong] { try TestData.index().songs }

    // MARK: norm()

    func testNormLowercasesAndFoldsDiacritics() {
        XCTAssertEqual(ShazamCatalogMatch.norm("Café"), "cafe")
        XCTAssertEqual(ShazamCatalogMatch.norm("MÖTLEY"), "motley")
    }

    func testNormDropsParentheticalAndBracketTails() {
        XCTAssertEqual(ShazamCatalogMatch.norm("Neon (feat. Someone)"), "neon")
        XCTAssertEqual(ShazamCatalogMatch.norm("Neon [Remastered]"), "neon")
        XCTAssertEqual(ShazamCatalogMatch.norm("Café (Remastered 2011)"), "cafe")
    }

    func testNormDropsDashEditionClause() {
        XCTAssertEqual(ShazamCatalogMatch.norm("Pulse - Remastered 2019"), "pulse")
        XCTAssertEqual(ShazamCatalogMatch.norm("Drift - Live"), "drift")
        // A dash that ISN'T an edition clause is kept (punctuation stripped).
        XCTAssertEqual(ShazamCatalogMatch.norm("Get Down - Pt. 2"), "get down pt 2")
    }

    func testNormStripsPunctuationAndCollapsesSpace() {
        XCTAssertEqual(ShazamCatalogMatch.norm("  Get   Down!! "), "get down")
    }

    // MARK: resolve()

    func testResolveExactInCatalog() throws {
        let info = ShazamHitInfo(title: "Neon", artist: "Aria", artworkURL: nil, appleMusicID: nil)
        guard case .inCatalog(let song, _) = ShazamCatalogMatch.resolve(info, in: try songs()) else {
            return XCTFail("expected in-catalog match")
        }
        XCTAssertEqual(song.id, "sng_1")
    }

    func testResolveMatchesThroughEditionNoise() throws {
        // Store edition + diacritic noise still lands on "Pulse" / "Aria".
        let info = ShazamHitInfo(title: "Pulse (Remastered 2019)", artist: "Aria",
                                 artworkURL: nil, appleMusicID: "12345")
        guard case .inCatalog(let song, let hit) = ShazamCatalogMatch.resolve(info, in: try songs()) else {
            return XCTFail("expected in-catalog match")
        }
        XCTAssertEqual(song.id, "sng_2")
        XCTAssertEqual(hit.appleMusicID, "12345")  // bridge info is carried through
    }

    func testResolveArtistContainmentCompatible() throws {
        // Shazam "Aria" vs our "Aria" — and a feat. variant still matches.
        let info = ShazamHitInfo(title: "Neon", artist: "Aria feat. Guest",
                                 artworkURL: nil, appleMusicID: nil)
        guard case .inCatalog(let song, _) = ShazamCatalogMatch.resolve(info, in: try songs()) else {
            return XCTFail("expected in-catalog match")
        }
        XCTAssertEqual(song.id, "sng_1")
    }

    func testResolveWrongArtistFallsThrough() throws {
        // Same title, incompatible artist → not in catalog.
        let info = ShazamHitInfo(title: "Neon", artist: "Completely Different",
                                 artworkURL: nil, appleMusicID: nil)
        guard case .notInCatalog = ShazamCatalogMatch.resolve(info, in: try songs()) else {
            return XCTFail("expected not-in-catalog")
        }
    }

    func testResolveUnknownTitleNotInCatalog() throws {
        let info = ShazamHitInfo(title: "Nonexistent Track", artist: "Aria",
                                 artworkURL: nil, appleMusicID: "999")
        guard case .notInCatalog(let hit) = ShazamCatalogMatch.resolve(info, in: try songs()) else {
            return XCTFail("expected not-in-catalog")
        }
        XCTAssertEqual(hit.appleMusicID, "999")  // appleMusicID preserved for the bridge
    }

    func testResolveMissingTitleIsNotInCatalog() throws {
        let info = ShazamHitInfo(title: nil, artist: "Aria", artworkURL: nil, appleMusicID: nil)
        guard case .notInCatalog = ShazamCatalogMatch.resolve(info, in: try songs()) else {
            return XCTFail("expected not-in-catalog for missing title")
        }
    }

    func testResolveNoArtistMatchesOnTitleAlone() throws {
        let info = ShazamHitInfo(title: "Slow Burn", artist: nil, artworkURL: nil, appleMusicID: nil)
        guard case .inCatalog(let song, _) = ShazamCatalogMatch.resolve(info, in: try songs()) else {
            return XCTFail("expected in-catalog match on title alone")
        }
        XCTAssertEqual(song.id, "sng_7")
    }
}
