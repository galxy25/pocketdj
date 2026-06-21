import XCTest
@testable import PocketDJ

final class CamelotTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Camelot.parse("8A")?.num, 8)
        XCTAssertEqual(Camelot.parse("8A")?.major, false)
        XCTAssertEqual(Camelot.parse("12B")?.major, true)
        XCTAssertNil(Camelot.parse("13A"))
        XCTAssertNil(Camelot.parse("xx"))
        XCTAssertNil(Camelot.parse(nil))
    }

    func testRankOrdersWheel() {
        // 1A < 1B < 2A < … (A even, B odd, contiguous)
        XCTAssertEqual(Camelot.rank("1A"), 2)
        XCTAssertEqual(Camelot.rank("1B"), 3)
        XCTAssertLessThan(Camelot.rank("7A")!, Camelot.rank("7B")!)
        XCTAssertLessThan(Camelot.rank("8B")!, Camelot.rank("9A")!)
    }

    func testKeysAreWheelOrdered() {
        XCTAssertEqual(Camelot.keys.first, "1A")
        XCTAssertEqual(Camelot.keys.last, "12B")
        XCTAssertEqual(Camelot.keys.count, 24)
    }
}

final class GenreTests: XCTestCase {
    func testCategorizeRoutesToTopTier() {
        XCTAssertEqual(Genre.category("Electronic"), "electronic")
        XCTAssertEqual(Genre.category("Jazz"), "jazz")
        XCTAssertEqual(Genre.category("Funk / Soul"), "funk")   // funk precedes soul in priority
        XCTAssertEqual(Genre.category("Hip hop"), "hip-hop")
        XCTAssertEqual(Genre.category("Synthpop"), "electronic")
        XCTAssertEqual(Genre.category("Contemporary R&B"), "r&b")
        // Priority is ordered: "soul" precedes "r&b", so a glued "r&bsoul" routes
        // to soul (matches the PWA's first-keyword-wins behaviour), not r&b.
        XCTAssertEqual(Genre.category("R&Bsoul"), "soul")
    }
    func testCategorizeUnmappableIsOther() {
        XCTAssertEqual(Genre.category(nil), "Other")
        XCTAssertEqual(Genre.category(""), "Other")
        XCTAssertEqual(Genre.category("   "), "Other")
        XCTAssertEqual(Genre.category("qwertyuiop"), "Other")
    }
    func testCategoryNames() {
        XCTAssertEqual(Genre.categoryNames.first, "hip-hop")
        XCTAssertEqual(Genre.categoryNames.last, "Other")
        XCTAssertEqual(Genre.categoryNames.count, 15)  // 14 categories + Other
    }
}

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Fmt.duration(222000), "3:42")
        XCTAssertEqual(Fmt.duration(201000), "3:21")
        XCTAssertEqual(Fmt.duration(nil), "–")
        XCTAssertEqual(Fmt.duration(0), "–")
    }
    func testBpm() {
        XCTAssertEqual(Fmt.bpm(128), "128")
        XCTAssertEqual(Fmt.bpm(127.6), "128")
        XCTAssertEqual(Fmt.bpm(nil), "–")
    }
}

final class BPMTierTests: XCTestCase {
    func testTierBuckets() {
        XCTAssertEqual(BPMTier.tier(60), 1)    // slow
        XCTAssertEqual(BPMTier.tier(89), 1)
        XCTAssertEqual(BPMTier.tier(95), 2)    // medium
        XCTAssertEqual(BPMTier.tier(119), 2)
        XCTAssertEqual(BPMTier.tier(128), 3)   // fast
        XCTAssertEqual(BPMTier.tier(159), 3)
        XCTAssertEqual(BPMTier.tier(174), 4)   // hyper
        XCTAssertEqual(BPMTier.tier(399), 4)
    }
    func testTierBoundariesAreLowerInclusive() {
        // Each boundary belongs to the HIGHER tier (upper bound exclusive).
        XCTAssertEqual(BPMTier.tier(90), 2)
        XCTAssertEqual(BPMTier.tier(120), 3)
        XCTAssertEqual(BPMTier.tier(160), 4)
    }
    func testTierNilAndZero() {
        XCTAssertNil(BPMTier.tier(nil))
        XCTAssertNil(BPMTier.tier(0))
        XCTAssertNil(BPMTier.tier(-5))
    }
}

final class FilterEngineTests: XCTestCase {
    func testGenreEqualsOnAlbums() throws {
        let items = try TestData.albumItems()
        let c = Clause(field: "genre", op: .eq, value: "Electronic")
        let out = FilterEngine.apply(items, [c])
        XCTAssertEqual(out.map(\.idString), ["alb_1"])
    }

    func testYearBetweenOnAlbums() throws {
        let items = try TestData.albumItems()
        var c = Clause(field: "year", op: .between); c.min = 1990; c.max = 2025
        let out = FilterEngine.apply(items, [c])
        XCTAssertEqual(Set(out.map(\.idString)), ["alb_1", "alb_2"])
    }

    func testBpmBetweenOnSongs() throws {
        let items = try TestData.songItems()
        var c = Clause(field: "bpm", op: .between); c.min = 100; c.max = 130
        let out = FilterEngine.apply(items, [c])
        XCTAssertEqual(Set(out.map(\.idString)), ["sng_1", "sng_2", "sng_4", "sng_6"])
    }

    func testExplicitTrue() throws {
        let items = try TestData.songItems()
        let c = Clause(field: "explicit", op: .eq, value: "true")
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.idString)), ["sng_2", "sng_6"])
    }

    func testCamelotInList() throws {
        let items = try TestData.songItems()
        var c = Clause(field: "camelot", op: .inList); c.values = ["8A", "8B"]
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.idString)), ["sng_1", "sng_2"])
    }

    func testSentimentInList() throws {
        let items = try TestData.songItems()
        var c = Clause(field: "sentiment", op: .inList); c.values = ["drive"]
        XCTAssertEqual(FilterEngine.apply(items, [c]).map(\.idString), ["sng_1"])
    }

    func testIncompleteClauseIsNoOp() throws {
        let items = try TestData.songItems()
        let c = Clause(field: "bpm", op: .eq, value: "")   // no operand yet
        XCTAssertEqual(FilterEngine.apply(items, [c]).count, items.count)
    }

    func testAndComposition() throws {
        let items = try TestData.songItems()
        var bpm = Clause(field: "bpm", op: .between); bpm.min = 100; bpm.max = 130
        let expl = Clause(field: "explicit", op: .eq, value: "true")
        XCTAssertEqual(FilterEngine.apply(items, [bpm, expl]).map(\.idString), ["sng_2", "sng_6"])
    }

    // MARK: Source clause (matches the origin source threaded onto each item)

    func testSourceEqualsOnSongs() throws {
        // Tag sng_1..3 with "My Vinyl" and the rest with "Apple Music (Local)".
        let items = try TestData.songItems().map { item -> BrowseItem in
            guard case .song(let s, let an, _) = item else { return item }
            let src = ["sng_1", "sng_2", "sng_3"].contains(s.id) ? "My Vinyl" : "Apple Music (Local)"
            return .song(s, albumName: an, source: src)
        }
        let c = Clause(field: "source", op: .eq, value: "My Vinyl")
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.idString)), ["sng_1", "sng_2", "sng_3"])
    }

    func testSourceInListOnAlbums() throws {
        let items = [
            BrowseItem.album(try TestData.index().albums[0], source: "My Vinyl"),       // alb_1
            BrowseItem.album(try TestData.index().albums[1], source: "Apple Music (Local)"), // alb_2
            BrowseItem.album(try TestData.index().albums[2], source: "Web"),            // alb_3
        ]
        var c = Clause(field: "source", op: .inList); c.values = ["My Vinyl", "Web"]
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.idString)), ["alb_1", "alb_3"])
    }

    func testSourceNotEquals() throws {
        let items = try TestData.albumItemsTagged(source: "My Vinyl")
        // None match "is not My Vinyl"; all match "is not Web".
        let none = Clause(field: "source", op: .neq, value: "My Vinyl")
        XCTAssertTrue(FilterEngine.apply(items, [none]).isEmpty)
        let all = Clause(field: "source", op: .neq, value: "Web")
        XCTAssertEqual(FilterEngine.apply(items, [all]).count, items.count)
    }
}

final class SortEngineTests: XCTestCase {
    func testBpmAscending() throws {
        let items = try TestData.songItems()
        let out = SortEngine.apply(items, [SortKey(field: "bpm", dir: .asc)])
        XCTAssertEqual(out.first?.idString, "sng_7")  // 72
        XCTAssertEqual(out.last?.idString, "sng_1")   // 128
    }

    func testYearDescendingOnAlbums() throws {
        let items = try TestData.albumItems()
        let out = SortEngine.apply(items, [SortKey(field: "year", dir: .desc)])
        XCTAssertEqual(out.map(\.idString), ["alb_1", "alb_2", "alb_3"])
    }

    func testCamelotSortsByWheelNotAlpha() throws {
        let items = try TestData.songItems()
        let out = SortEngine.apply(items, [SortKey(field: "camelot", dir: .asc)])
        // ranks: 7A,7B,8A,8B,9A,9B,10A  → not "10A" first as a string sort would give
        XCTAssertEqual(out.first?.idString, "sng_5")  // 7A
        XCTAssertEqual(out.last?.idString, "sng_7")   // 10A
    }

    func testMultiKeyStable() throws {
        let items = try TestData.songItems()
        // primary artist asc, secondary bpm desc
        let out = SortEngine.apply(items, [SortKey(field: "artist", dir: .asc),
                                           SortKey(field: "bpm", dir: .desc)])
        // Aria block first (bpm desc): 128,124,90 → sng_1,sng_2,sng_3
        XCTAssertEqual(out.prefix(3).map(\.idString), ["sng_1", "sng_2", "sng_3"])
    }

    func testEmptyKeysReturnsInput() throws {
        let items = try TestData.songItems()
        XCTAssertEqual(SortEngine.apply(items, []).map(\.idString), items.map(\.idString))
    }
}

final class DecodingTests: XCTestCase {
    func testDecodesFixture() throws {
        let idx = try TestData.index()
        XCTAssertEqual(idx.albums.count, 3)
        XCTAssertEqual(idx.songs.count, 7)
        XCTAssertEqual(idx.manifest.sourceName, "Test Crate")
        XCTAssertEqual(idx.albums[0].trackList.count, 3)
        XCTAssertEqual(idx.songs[0].camelot, "8A")
    }
}
