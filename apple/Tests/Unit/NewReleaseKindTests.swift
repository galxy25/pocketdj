import XCTest
@testable import PocketDJ

/// For You ▸ New albums/singles filter — the pure module (`NewReleaseKind.swift`), its tile and
/// settings wiring. Mirrors `NewReleaseKindTest.kt` case for case.
@MainActor
final class NewReleaseKindTests: XCTestCase {

    private func cls(_ kind: String?, _ name: String?, _ tracks: Int?) -> ReleaseKindClass {
        NewReleaseKinds.classify(kind: kind, name: name, trackCount: tracks)
    }

    // MARK: classify

    func testClassifyTable() {
        XCTAssertEqual(cls("album", "Thing - Single", 9), .single, "the name wins over kind and count")
        XCTAssertEqual(cls("album", "Thing – Single", 9), .single, "en dash")
        XCTAssertEqual(cls("album", "Thing - EP", 9), .ep)
        XCTAssertEqual(cls("album", "  Thing - SINGLE  ", nil), .single, "trimmed, case-insensitive")
        XCTAssertEqual(cls("single", "Remix Bundle", 8), .single, "a remix-bundle single stays a single")
        XCTAssertEqual(cls("ep", "Thing", 12), .ep)
        XCTAssertEqual(cls(nil, "Midnight Edit", 2), .single, "no declared kind: count guesses")
        XCTAssertEqual(cls(nil, "Thing", 5), .ep)
        // Review fix: a DECLARED album/compilation is trusted over the track count.
        XCTAssertEqual(cls("album", "Short Classical Work", 2), .album)
        XCTAssertEqual(cls("album", "Lead Tracks Pre-order", 3), .album)
        XCTAssertEqual(cls("compilation", "Hits", 5), .album)
        XCTAssertEqual(NewReleaseKinds.badge(kind: "compilation", cls: cls("compilation", "Hits", 2)), "Compilation")
        XCTAssertEqual(cls("album", "Thing", 12), .album)
        XCTAssertEqual(cls("compilation", "Hits", 20), .album)
        XCTAssertEqual(cls(nil, nil, nil), .album, "unknown everything is an album")
    }

    func testBadgeFollowsTheClassAndKeepsCompilation() {
        XCTAssertEqual(NewReleaseKinds.badge(kind: "album", cls: .single), "Single")
        XCTAssertEqual(NewReleaseKinds.badge(kind: "album", cls: .ep), "EP")
        XCTAssertEqual(NewReleaseKinds.badge(kind: "compilation", cls: .album), "Compilation")
        XCTAssertEqual(NewReleaseKinds.badge(kind: nil, cls: .album), "Album")
    }

    // MARK: arrange

    private struct R: Equatable { let id: String; let c: ReleaseKindClass }
    private let input: [R] = [
        R(id: "s1", c: .single), R(id: "a1", c: .album), R(id: "e1", c: .ep),
        R(id: "s2", c: .single), R(id: "a2", c: .album),
    ]
    /// 👎 sink: a1 and s1 are rejected.
    private let sink: ([R]) -> [R] = { items in
        let bad: Set<String> = ["a1", "s1"]
        return items.filter { !bad.contains($0.id) } + items.filter { bad.contains($0.id) }
    }
    private func arrange(_ m: NewReleaseKindFilter) -> NewReleaseKinds.Arranged<R> {
        NewReleaseKinds.arrange(input, mode: m, cls: { $0.c }, sink: sink)
    }

    func testAllEqualsTheSunkInputExactly() {
        let a = arrange(.all)
        XCTAssertEqual(a.flat, sink(input))
        XCTAssertFalse(a.grouped)
        XCTAssertEqual(a.hiddenAlbums + a.hiddenSingles, 0)
    }

    func testAlbumsOnlyKeepsEPsAndCountsHiddenSingles() {
        let a = arrange(.albums)
        XCTAssertEqual(a.flat.map(\.id), ["e1", "a2", "a1"], "EPs count as albums; a 👎'd album sinks")
        XCTAssertEqual(a.hiddenSingles, 2)
        XCTAssertEqual(a.hiddenAlbums, 0)
        XCTAssertFalse(a.grouped)
    }

    func testSinglesOnlyDropsEPsAndCountsThem() {
        let a = arrange(.singles)
        XCTAssertEqual(a.flat.map(\.id), ["s2", "s1"])
        XCTAssertEqual(a.hiddenAlbums, 3)
        XCTAssertEqual(a.hiddenEPs, 1)
        XCTAssertEqual(a.hiddenSingles, 0)
    }

    func testAlbumsFirstGroupsAndSinksInsideEachGroup() {
        let a = arrange(.albumsFirst)
        XCTAssertTrue(a.grouped)
        XCTAssertEqual(a.albums.map(\.id), ["e1", "a2", "a1"])
        XCTAssertEqual(a.singles.map(\.id), ["s2", "s1"])
        XCTAssertEqual(a.flat.map(\.id), ["e1", "a2", "a1", "s2", "s1"],
                       "a 👎'd album stays above every single")
        XCTAssertEqual(a.hiddenAlbums + a.hiddenSingles, 0)
    }

    // MARK: copy

    func testHiddenNote() {
        XCTAssertNil(NewReleaseKinds.hiddenNote(albums: 0, eps: 0, singles: 0))
        XCTAssertEqual(NewReleaseKinds.hiddenNote(albums: 0, eps: 0, singles: 1), "1 single hidden")
        XCTAssertEqual(NewReleaseKinds.hiddenNote(albums: 0, eps: 0, singles: 3), "3 singles hidden")
        XCTAssertEqual(NewReleaseKinds.hiddenNote(albums: 1, eps: 0, singles: 0), "1 album hidden")
        XCTAssertEqual(NewReleaseKinds.hiddenNote(albums: 2, eps: 0, singles: 0), "2 albums hidden")
        XCTAssertEqual(NewReleaseKinds.hiddenNote(albums: 2, eps: 1, singles: 0), "2 albums & EPs hidden")
        XCTAssertEqual(NewReleasesView.kindEmptyDetail(mode: .albums, hiddenNote: "3 singles hidden"),
                       "3 singles hidden. Your New filter is set to Albums only.")
    }

    // MARK: settings

    func testSettingsRoundTripAndUpgradeSafety() {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.newReleaseKindFilter, .all, "default is today's behaviour")
        s.newReleaseKindFilter = .albumsFirst
        s.persist()
        XCTAssertEqual(SettingsStore(defaults: defaults).newReleaseKindFilter, .albumsFirst)
        XCTAssertEqual(NewReleaseKindFilter.from("nonsense"), .all)
        XCTAssertEqual(NewReleaseKindFilter.from(nil), .all)
        XCTAssertEqual(NewReleaseKindFilter.allCases.map(\.rawValue), ["all", "albums", "singles", "albumsFirst"])
    }

    // MARK: tiles + the shared out-now list

    private let now = 1_000_000_000_000.0
    private func rig() -> (ReleaseFeedService, CollectionsStore, ForYouFeedStore) {
        let releases = ReleaseFeedService(transport: nil, fileURL: tmp("rel"))
        releases.seedForTesting(ReleaseFeedService.uiFixtureEntries(nowMs: now)
                                + ReleaseFeedService.uiFixtureKindEntries(nowMs: now))
        return (releases, CollectionsStore(fileURL: tmp("col")), ForYouFeedStore(fileURL: tmp("feed")))
    }
    private func tmp(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-nk-\(tag)-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func newTile(_ kind: NewReleaseKindFilter, _ r: (ReleaseFeedService, CollectionsStore, ForYouFeedStore)) -> ForYouTile {
        ForYouGrid.tiles(snapshot: r.2.snapshot, collections: r.1, feedback: nil, releaseFeed: r.0,
                         newKind: kind, nowMs: now)[0]
    }

    func testTileCountsOnlyShownReleases() {
        let r = rig()   // out now: 900001 album, 900002 single, 900005 single, 900006 1-track album; soon: 900003 EP
        XCTAssertEqual(newTile(.all, r).count, 5)
        XCTAssertEqual(newTile(.albumsFirst, r).count, 5, "albumsFirst hides nothing")
        XCTAssertEqual(newTile(.albums, r).count, 2, "album + EP")
        XCTAssertEqual(newTile(.singles, r).count, 3)
        XCTAssertTrue(newTile(.albums, r).subtitle.hasPrefix("Albums from"))
        XCTAssertTrue(newTile(.singles, r).subtitle.hasPrefix("Singles from"))
        XCTAssertTrue(newTile(.all, r).subtitle.hasPrefix("From"))
    }

    func testFilterEmptyNoteBeatsTheReasonNote() {
        let releases = ReleaseFeedService(transport: nil, fileURL: tmp("rel2"))
        releases.seedForTesting([ReleaseFeedService.uiFixtureKindEntries(nowMs: now)[0]])  // one single
        let tile = ForYouGrid.tiles(snapshot: ForYouFeedStore(fileURL: tmp("f2")).snapshot,
                                    collections: CollectionsStore(fileURL: tmp("c2")), feedback: nil,
                                    releaseFeed: releases, newKind: .albums, nowMs: now)[0]
        XCTAssertEqual(tile.count, 0)
        XCTAssertEqual(tile.subtitle, "No new albums · 1 single hidden")
    }

    func testLiveOutNowOrderFeedsStreamingAlbumsFirst() {
        let r = rig()
        let ids = { (m: NewReleaseKindFilter) in
            NewReleaseKinds.liveOutNow(outNow: r.0.outNow(nowMs: self.now), feedback: nil, scope: "new",
                                       mode: m, nowMs: self.now).compactMap(\.entry.releaseId) }
        XCTAssertEqual(ids(.albums), ["9000000001"])
        XCTAssertEqual(ids(.singles), ["9000000005", "9000000006", "9000000002"])
        XCTAssertEqual(ids(.albumsFirst), ["9000000001", "9000000005", "9000000006", "9000000002"])
        XCTAssertEqual(ids(.all), ["9000000005", "9000000001", "9000000006", "9000000002"], "date order")
    }
}
