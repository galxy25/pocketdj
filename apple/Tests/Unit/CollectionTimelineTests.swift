import XCTest
@testable import PocketDJ

/// F8 — the Collection tab's ONE TRUE TIMELINE: the whole catalog on an add-date axis, by song or
/// by album, cut off at a date, in either direction, annotated with listening progress; plus the
/// named cue points that bookmark it.
///
/// Everything under test here is the PURE core (`CollectionTimeline`, `TimelineCueStore`) — the
/// part that must run off the main actor against ~96k rows without a view in sight.
@MainActor
final class CollectionTimelineTests: XCTestCase {

    // MARK: - Fixtures

    /// Epoch ms for a UTC-ish calendar date. Exact instant doesn't matter — only ordering does —
    /// so a plain days-since-epoch arithmetic keeps the tests timezone-independent.
    private func ms(_ daysSinceEpoch: Double) -> Double { daysSinceEpoch * 86_400_000 }

    private func song(_ id: String, name: String, artist: String = "Aria",
                      albumId: String? = nil) -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": name, "artist": artist]
        if let albumId { obj["albumId"] = albumId }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    private func album(_ id: String, name: String, artist: String = "Aria") -> IndexAlbum {
        let obj: [String: Any] = ["id": id, "name": name, "artist": artist, "trackList": []]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexAlbum.self, from: data)
    }

    /// Three songs on two albums, added on three different days, one of them played.
    private func standardInput(grain: TimelineGrain = .songs) -> CollectionTimeline.Input {
        var i = CollectionTimeline.Input()
        i.songsById = [
            "s1": song("s1", name: "First", albumId: "a1"),
            "s2": song("s2", name: "Second", albumId: "a1"),
            "s3": song("s3", name: "Third", albumId: "a2"),
        ]
        i.albumsById = ["a1": album("a1", name: "Debut"), "a2": album("a2", name: "Sophomore")]
        i.addedAt = ["s1": ms(100), "s2": ms(200), "s3": ms(300)]
        i.playCounts = ["s2": 4]
        i.grain = grain
        return i
    }

    // MARK: - Ordering + direction

    func testDescendingIsNewestFirst() {
        var i = standardInput()
        i.ascending = false
        let out = CollectionTimeline.build(i)
        XCTAssertEqual(out.rows.map(\.itemId), ["s3", "s2", "s1"])
    }

    func testAscendingIsOldestFirst() {
        var i = standardInput()
        i.ascending = true
        let out = CollectionTimeline.build(i)
        XCTAssertEqual(out.rows.map(\.itemId), ["s1", "s2", "s3"])
    }

    /// Equal add-times must produce the SAME order every build. Dictionary iteration is arbitrary
    /// and Swift's sort is unstable, so without the id tiebreak two builds of identical data can
    /// disagree — which in a paged list reads as rows randomly swapping places.
    func testEqualTimestampsAreDeterministic() {
        var i = standardInput()
        i.addedAt = ["s1": ms(100), "s2": ms(100), "s3": ms(100)]
        let a = CollectionTimeline.build(i).rows.map(\.id)
        let b = CollectionTimeline.build(i).rows.map(\.id)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, a.sorted())
    }

    // MARK: - The date cutoff

    func testAfterDateExcludesOlderRows() {
        var i = standardInput()
        i.afterMs = ms(200)
        let out = CollectionTimeline.build(i)
        XCTAssertEqual(Set(out.rows.map(\.itemId)), ["s2", "s3"])
        XCTAssertEqual(out.summary.beforeCutoff, 1)
    }

    /// The cutoff is INCLUSIVE at the boundary — "added after <day>" has to include the day itself
    /// or jumping to a cue set on that day lands past what it bookmarked.
    func testCutoffIsInclusiveOfItsOwnInstant() {
        var i = standardInput()
        i.afterMs = ms(300)
        XCTAssertEqual(CollectionTimeline.build(i).rows.map(\.itemId), ["s3"])
    }

    // MARK: - Rows without an add date

    /// ~2,511 of the owner's ~96,021 index rows have no `dateAdded`. They cannot be placed on a
    /// temporal axis, so they are EXCLUDED from the stream and COUNTED — the header states the
    /// number rather than the timeline quietly pretending to be the whole library.
    func testUndatedSongsAreExcludedAndCounted() {
        var i = standardInput()
        i.songsById["s4"] = song("s4", name: "Fourth", albumId: "a2")   // no entry in addedAt
        let out = CollectionTimeline.build(i)
        XCTAssertFalse(out.rows.contains { $0.itemId == "s4" })
        XCTAssertEqual(out.summary.undated, 1)
        XCTAssertEqual(out.summary.rows, 3)
    }

    /// The undated tally describes the LIBRARY, not the window: narrowing the date filter must not
    /// change it (those rows were never candidates in the first place).
    func testUndatedCountIsIndependentOfTheCutoff() {
        var i = standardInput()
        i.songsById["s4"] = song("s4", name: "Fourth")
        i.afterMs = ms(250)
        let out = CollectionTimeline.build(i)
        XCTAssertEqual(out.summary.undated, 1)
        XCTAssertEqual(out.rows.map(\.itemId), ["s3"])
    }

    /// A zero timestamp is "no date", not "1 January 1970".
    func testZeroTimestampCountsAsUndated() {
        var i = standardInput()
        i.addedAt["s1"] = 0
        let out = CollectionTimeline.build(i)
        XCTAssertFalse(out.rows.contains { $0.itemId == "s1" })
        XCTAssertEqual(out.summary.undated, 1)
    }

    // MARK: - Progress

    func testSongProgressCountsHeardAndPlays() {
        let out = CollectionTimeline.build(standardInput())
        XCTAssertEqual(out.summary.songs, 3)
        XCTAssertEqual(out.summary.heard, 1)
        XCTAssertEqual(out.summary.plays, 4)
        XCTAssertEqual(out.summary.progress, 1.0 / 3.0, accuracy: 0.0001)
        let heard = out.rows.first { $0.itemId == "s2" }
        XCTAssertEqual(heard?.heard, 1)
        XCTAssertEqual(heard?.plays, 4)
        XCTAssertEqual(out.rows.first { $0.itemId == "s1" }?.heard, 0)
    }

    func testProgressIsZeroForAnEmptyWindow() {
        var i = standardInput()
        i.afterMs = ms(10_000)
        let out = CollectionTimeline.build(i)
        XCTAssertTrue(out.rows.isEmpty)
        XCTAssertEqual(out.summary.progress, 0)
    }

    // MARK: - Albums grain

    /// An album sits at the NEWEST add-time among its tracks: a record he is still filling in
    /// belongs where the library actually changed, not years back at its first track.
    func testAlbumPositionIsItsNewestTrack() {
        let out = CollectionTimeline.build(standardInput(grain: .albums))
        let a1 = out.rows.first { $0.itemId == "a1" }
        XCTAssertEqual(a1?.addedAtMs, ms(200))          // max(100, 200), not 100
        XCTAssertEqual(out.rows.map(\.itemId), ["a2", "a1"])   // descending by that position
    }

    func testAlbumProgressCountsItsOwnTracks() {
        let out = CollectionTimeline.build(standardInput(grain: .albums))
        let a1 = out.rows.first { $0.itemId == "a1" }
        XCTAssertEqual(a1?.total, 2)
        XCTAssertEqual(a1?.heard, 1)                    // only s2 has plays
        XCTAssertEqual(a1?.plays, 4)
        XCTAssertEqual(a1?.fullyHeard, false)
        let a2 = out.rows.first { $0.itemId == "a2" }
        XCTAssertEqual(a2?.total, 1)
        XCTAssertEqual(a2?.heard, 0)
        // The window's song counts aggregate the album rows, not the album count.
        XCTAssertEqual(out.summary.songs, 3)
        XCTAssertEqual(out.summary.heard, 1)
        XCTAssertEqual(out.summary.rows, 2)
    }

    /// A song with no indexed album has no album row to live on. It is counted (and named in the
    /// header) rather than silently dropped.
    func testSongsWithNoAlbumAreCountedAsUngrouped() {
        var i = standardInput(grain: .albums)
        i.songsById["s9"] = song("s9", name: "Orphan")
        i.addedAt["s9"] = ms(400)
        let out = CollectionTimeline.build(i)
        XCTAssertEqual(out.summary.ungrouped, 1)
        XCTAssertFalse(out.rows.contains { $0.itemId == "s9" })
        // …and in the SONGS grain it is a first-class row.
        i.grain = .songs
        XCTAssertTrue(CollectionTimeline.build(i).rows.contains { $0.itemId == "s9" })
        XCTAssertEqual(CollectionTimeline.build(i).summary.ungrouped, 0)
    }

    /// An album ALL of whose tracks are undated has no position either.
    func testAlbumWithNoDatedTracksIsUndated() {
        var i = standardInput(grain: .albums)
        i.addedAt.removeValue(forKey: "s3")
        let out = CollectionTimeline.build(i)
        XCTAssertFalse(out.rows.contains { $0.itemId == "a2" })
        XCTAssertEqual(out.summary.undated, 1)
    }

    // MARK: - Search

    func testQueryFiltersSongsByTitleAndArtist() {
        var i = standardInput()
        i.query = "second"
        XCTAssertEqual(CollectionTimeline.build(i).rows.map(\.itemId), ["s2"])
        i.query = "aria"                                    // artist, case-insensitive
        XCTAssertEqual(CollectionTimeline.build(i).rows.count, 3)
        i.query = "nothing here"
        XCTAssertTrue(CollectionTimeline.build(i).rows.isEmpty)
    }

    func testQueryFiltersAlbumsByTitle() {
        var i = standardInput(grain: .albums)
        i.query = "debut"
        XCTAssertEqual(CollectionTimeline.build(i).rows.map(\.itemId), ["a1"])
    }

    // MARK: - Month dividers

    /// The divider flag is stamped by the builder, never derived by comparing neighbours in a view
    /// body. Three add-dates a year apart ⇒ three month openings, whatever the local timezone.
    func testEachNewMonthOpensADivider() {
        var i = standardInput()
        i.addedAt = ["s1": ms(100), "s2": ms(500), "s3": ms(900)]
        let out = CollectionTimeline.build(i)
        XCTAssertEqual(out.rows.filter(\.startsMonth).count, 3)
        XCTAssertFalse(out.rows.first?.monthLabel.isEmpty ?? true)
    }

    func testSameMonthSharesOneDivider() {
        var i = standardInput()
        // Same day, three rows: exactly one of them opens the month.
        i.addedAt = ["s1": ms(100), "s2": ms(100), "s3": ms(100)]
        XCTAssertEqual(CollectionTimeline.build(i).rows.filter(\.startsMonth).count, 1)
    }

    // MARK: - Cue jumps

    private func jumpRows(_ ascending: Bool) -> [CollectionTimeline.Row] {
        var i = standardInput()
        i.ascending = ascending
        return CollectionTimeline.build(i).rows
    }

    func testJumpLandsOnTheFirstRowAtOrPastTheCue() {
        let asc = jumpRows(true)            // s1(100) s2(200) s3(300)
        XCTAssertEqual(CollectionTimeline.jumpIndex(rows: asc, atMs: ms(200), ascending: true), 1)
        XCTAssertEqual(CollectionTimeline.jumpIndex(rows: asc, atMs: ms(150), ascending: true), 1)
        XCTAssertEqual(CollectionTimeline.jumpIndex(rows: asc, atMs: ms(50), ascending: true), 0)
    }

    func testJumpRespectsDescendingOrder() {
        let desc = jumpRows(false)          // s3(300) s2(200) s1(100)
        XCTAssertEqual(CollectionTimeline.jumpIndex(rows: desc, atMs: ms(200), ascending: false), 1)
        XCTAssertEqual(CollectionTimeline.jumpIndex(rows: desc, atMs: ms(250), ascending: false), 1)
        XCTAssertEqual(CollectionTimeline.jumpIndex(rows: desc, atMs: ms(400), ascending: false), 0)
    }

    /// A cue can outlive the window it was set in (he narrowed the date filter afterwards). Landing
    /// at the edge of the stream beats refusing to move.
    func testJumpPastTheEndClampsToTheLastRow() {
        let asc = jumpRows(true)
        XCTAssertEqual(CollectionTimeline.jumpIndex(rows: asc, atMs: ms(9_999), ascending: true), 2)
        let desc = jumpRows(false)
        XCTAssertEqual(CollectionTimeline.jumpIndex(rows: desc, atMs: ms(1), ascending: false), 2)
    }

    func testJumpOnAnEmptyStreamIsNil() {
        XCTAssertNil(CollectionTimeline.jumpIndex(rows: [], atMs: ms(100), ascending: true))
    }

    /// The binary partition search must agree with a linear scan on every position — including
    /// duplicated timestamps, where a partition point is easy to get off by one.
    func testJumpMatchesALinearScanAcrossDuplicates() {
        var i = CollectionTimeline.Input()
        var songs: [String: IndexSong] = [:]
        var added: [String: Double] = [:]
        for n in 0..<40 {
            let id = "s\(String(format: "%02d", n))"
            songs[id] = song(id, name: id)
            added[id] = ms(Double((n / 4) * 10))       // four rows share each timestamp
        }
        i.songsById = songs
        i.addedAt = added
        i.ascending = true
        let rows = CollectionTimeline.build(i).rows
        for target in stride(from: 0.0, through: 100.0, by: 5.0) {
            let expected = rows.firstIndex { $0.addedAtMs >= ms(target) } ?? rows.count - 1
            XCTAssertEqual(CollectionTimeline.jumpIndex(rows: rows, atMs: ms(target), ascending: true),
                           expected, "target \(target)")
        }
    }

    // MARK: - Scale

    /// The whole point of the pure core: 96,000 rows sorted, grouped and counted without a view.
    /// Not a benchmark — a guard that nothing in here is accidentally quadratic.
    func testBuildsAtCatalogScale() {
        var i = CollectionTimeline.Input()
        var songs: [String: IndexSong] = [:]
        var added: [String: Double] = [:]
        var albums: [String: IndexAlbum] = [:]
        songs.reserveCapacity(96_000)
        for n in 0..<96_000 {
            let sid = "s\(n)"
            let aid = "a\(n / 12)"
            songs[sid] = song(sid, name: "Song \(n)", albumId: aid)
            if albums[aid] == nil { albums[aid] = album(aid, name: "Album \(n / 12)") }
            // 2.6% carry no add date, mirroring the real index. The `+ 1` keeps every dated row
            // strictly positive — a zero timestamp IS "no date" to the builder, which would
            // otherwise quietly add 25 more undated rows to the expectation below.
            if n % 38 != 0 { added[sid] = ms(Double(n % 3_650) + 1) }
        }
        i.songsById = songs
        i.albumsById = albums
        i.addedAt = added
        let started = Date()
        let out = CollectionTimeline.build(i)
        XCTAssertEqual(out.rows.count, added.count)
        XCTAssertEqual(out.summary.undated, 96_000 - added.count)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "timeline build went superlinear")
    }
}
