import XCTest
@testable import PocketDJ

/// docs/design/new-feed-all-releases.md — the feed keeps EVERY release in the window.
private let day = 86_400_000.0

private func row(_ artist: Int, _ name: String = "Artist", _ id: String, _ title: String,
                 daysAgo: Double, now: Double, kind: String = "album", tracks: Int? = nil,
                 explicit: Bool? = nil, credit: String? = nil) -> ArtistReleaseEntry {
    ArtistReleaseEntry(artistId: artist, artistName: name, checkedAtMs: now, releaseId: id,
                       releaseName: title, releaseAtMs: now - daysAgo * day,
                       releaseArtworkUrl: nil, releaseKind: kind, trackCount: tracks,
                       explicit: explicit, releaseArtistName: credit)
}

private func iso(_ daysAgo: Double, now: Double) -> String {
    let d = Date(timeIntervalSince1970: (now - daysAgo * day) / 1000)
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: d)
}

/// Answers by URL, and counts what is in flight.
private final class RoutingTransport: ReleaseFeedTransport, @unchecked Sendable {
    var canSync = true
    var batchBody = Data(); var overflowBody: Data?
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    func fetch(_ request: URLRequest) async throws -> Data {
        lock.lock(); urls.append(request.url!); lock.unlock()
        if request.url!.path.hasSuffix("/albums") {
            if let b = overflowBody { return b }
            throw ReleaseFeedTransportError.http(status: 400)
        }
        return batchBody
    }
}

@MainActor
final class ReleaseFeedAllReleasesTests: XCTestCase {
    private let now = Date().timeIntervalSince1970 * 1000

    private func tempURL() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-allrel-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    private func svc(_ rows: [ArtistReleaseEntry]) -> ReleaseFeedService {
        let s = ReleaseFeedService(transport: nil, fileURL: tempURL())
        s.seedForTesting(rows)
        return s
    }

    // ── The bug ──────────────────────────────────────────────────────────────────────────────

    func testAlbumThenNewerSingleYieldsTwoRowsAndAlbumsOnlyKeepsTheAlbum() {
        let s = svc([row(1, "A", "10", "Record", daysAgo: 10, now: now, tracks: 9),
                     row(1, "A", "11", "Hit - Single", daysAgo: 2, now: now, kind: "single", tracks: 1)])
        let items = s.feed(nowMs: now)
        XCTAssertEqual(items.map(\.feedbackId), ["rel:11", "rel:10"])
        XCTAssertEqual(items.map(\.id), items.map(\.feedbackId), "id is the release, unique per row")
        let a = NewReleaseKinds.arrange(items, mode: .albums, cls: { $0.entry.kindClass })
        XCTAssertEqual(a.flat.map(\.feedbackId), ["rel:10"])
        XCTAssertEqual(a.hiddenSingles, 1)
    }

    // ── Request + parse ──────────────────────────────────────────────────────────────────────

    func testBatchURLShape() throws {
        let url = try XCTUnwrap(ReleaseFeedService.batchURL([1, 2]))
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["ids"], "1,2")
        XCTAssertEqual(q["include"], "albums")
        XCTAssertEqual(q["limit[albums]"], "25")
        XCTAssertEqual(q["sort[albums]"], "-releaseDate")
        XCTAssertEqual(q["fields[artists]"], "name")
        XCTAssertEqual(q["fields[albums]"],
                       "name,releaseDate,artwork,trackCount,contentRating,isSingle,isCompilation,artistName")
        XCTAssertNil(q["views"])
        XCTAssertTrue(url.absoluteString.contains("limit%5Balbums%5D=25"))
    }

    func testRelationshipBodyFlattensDedupedWithCredit() throws {
        let body = """
        {"data":[{"id":"271256","attributes":{"name":"Drake"},"relationships":{"albums":{"data":[
          {"id":"3","attributes":{"name":"Ya Hit (feat. Drake) - Single","releaseDate":"2026-11-20","artistName":"Future","isSingle":true}},
          {"id":"2","attributes":{"name":"Habits - Single","releaseDate":"2026-11-10","artistName":"Drake","isSingle":true,"contentRating":"explicit"}},
          {"id":"2","attributes":{"name":"Habits - Single","releaseDate":"2026-11-10","artistName":"Drake","isSingle":true}},
          {"id":"1","attributes":{"name":"Big One","releaseDate":"2026","artistName":"Drake"}}]}},
          "views":{"latest-release":{"data":[{"id":"2","attributes":{"name":"Habits - Single"}}]}}},
          {"id":"9","attributes":{"name":"Empty"}}]}
        """
        let decoded = try JSONDecoder().decode(ArtistsCatalogResponse.self, from: Data(body.utf8))
        let rows = decoded.entries(checkedAtMs: 5)
        XCTAssertEqual(rows.filter { $0.artistId == 271256 }.compactMap(\.releaseId), ["3", "2", "1"])
        XCTAssertEqual(rows.first?.releaseArtistName, "Future")
        XCTAssertNil(rows.first(where: { $0.releaseId == "1" })?.releaseAtMs, "a bare year has no date")
        XCTAssertEqual(rows.filter { $0.artistId == 9 }.count, 1, "an empty artist is one bare row")
        XCTAssertNil(try JSONDecoder().decode(ArtistsCatalogResponse.self, from: Data("{}".utf8)).data)
    }

    // ── Dedupe ───────────────────────────────────────────────────────────────────────────────

    func testAppearsOnIsDroppedButCollabAndEmptyCreditAreKept() {
        let rows = [row(1, "Drake", "1", "Ya Hit - Single", daysAgo: 1, now: now, credit: "Future, Drake & Metro Boomin"),
                    row(1, "Drake", "2", "Own", daysAgo: 1, now: now, credit: "Drake"),
                    row(1, "Drake", "3", "Elsewhere", daysAgo: 1, now: now, credit: "Future"),
                    row(1, "Drake", "4", "Nocredit", daysAgo: 1, now: now)]
        XCTAssertEqual(ReleaseFeedDedupe.ownReleases(rows, artistName: "Drake").compactMap(\.releaseId),
                       ["1", "2", "4"])
    }

    func testOneReleaseUnderTwoArtistsKeepsTheFirstCredited() {
        let a = row(5, "Beta", "9", "Duet", daysAgo: 1, now: now, credit: "Alpha & Beta")
        let b = row(7, "Alpha", "9", "Duet", daysAgo: 1, now: now, credit: "Alpha & Beta")
        XCTAssertEqual(ReleaseFeedDedupe.acrossArtists([a, b]).map(\.artistId), [7])
        XCTAssertEqual(svc([a, b]).feed(nowMs: now).count, 1)
    }

    func testCleanAndExplicitTwinsCollapseWithPreferenceAndVerdict() {
        let clean = row(1, "A", "20", "Details", daysAgo: 8, now: now, explicit: false)
        let expl = row(1, "A", "21", "Details", daysAgo: 2, now: now, explicit: true)
        let s = svc([clean, expl])
        s.prefersExplicit = { true }
        XCTAssertEqual(s.feed(nowMs: now).map(\.feedbackId), ["rel:21"])
        XCTAssertEqual(s.feed(nowMs: now).first?.alternateReleaseIds, ["20"])
        s.prefersExplicit = { false }
        XCTAssertEqual(s.feed(nowMs: now).map(\.feedbackId), ["rel:20"])
        s.prefersExplicit = nil
        XCTAssertEqual(s.feed(nowMs: now).map(\.feedbackId), ["rel:20"], "unset prefers clean")
        s.hasVerdict = { $0 == "rel:21" }
        XCTAssertEqual(s.feed(nowMs: now).map(\.feedbackId), ["rel:21"], "a verdict beats preference")
        s.hasVerdict = nil
        s.ownsRelease = { $0.storeId == "21" }
        XCTAssertTrue(s.feed(nowMs: now).isEmpty, "owning either twin drops the record")
    }

    func testEditionsCollapseButLiveAndRemixStaySeparate() {
        let editions = svc([row(1, "A", "1", "Rec", daysAgo: 12, now: now),
                            row(1, "A", "2", "Rec (Deluxe Edition)", daysAgo: 2, now: now)])
        XCTAssertEqual(editions.feed(nowMs: now).map(\.feedbackId), ["rel:2"])
        let live = svc([row(1, "A", "1", "Rec", daysAgo: 12, now: now),
                        row(1, "A", "2", "Rec (Live)", daysAgo: 2, now: now)])
        XCTAssertEqual(live.feed(nowMs: now).count, 2)
        let remix = svc([row(1, "A", "1", "Song - Single", daysAgo: 12, now: now, kind: "single"),
                         row(1, "A", "2", "Song (X Remix) - Single", daysAgo: 2, now: now, kind: "single")])
        XCTAssertEqual(remix.feed(nowMs: now).count, 2)
    }

    func testSingleAndItsAlbumStayTwoRows() {
        let s = svc([row(1, "A", "1", "anything", daysAgo: 3, now: now, tracks: 8),
                     row(1, "A", "2", "anything - Single", daysAgo: 3, now: now, kind: "single", tracks: 1)])
        XCTAssertEqual(s.feed(nowMs: now).count, 2)
    }

    // ── Cache invariants + migration ─────────────────────────────────────────────────────────

    func testNormalizeEvictsKeepsHeadAndDropsUndated() {
        let head = row(1, "A", "1", "Head", daysAgo: 90, now: now)
        var future = row(1, "A", "2", "Soon", daysAgo: 0, now: now); future.releaseAtMs = now + 5 * day
        let rows = [head, row(1, "A", "3", "Fresh", daysAgo: 5, now: now),
                    row(1, "A", "4", "Old", daysAgo: 45, now: now), future,
                    ArtistReleaseEntry(artistId: 1, artistName: "A", checkedAtMs: now, releaseId: "5"),
                    row(1, "A", "3", "Dup", daysAgo: 5, now: now)]
        let out = ReleaseFeedCache.normalize(rows: rows, nowMs: now)
        XCTAssertEqual(Set(out.compactMap(\.releaseId)), ["2", "3"], "future + fresh; head is the newest (the pre-order)")
        XCTAssertEqual(out.first?.releaseId, "2")
        let lone = ReleaseFeedCache.normalize(rows: [head], nowMs: now)
        XCTAssertEqual(lone.compactMap(\.releaseId), ["1"], "the head is always kept")
    }

    func testV1FileLoadsWithNoFetchAndTTLClocksKept() throws {
        let url = tempURL()
        let v1 = Document(rows: [row(1, "A", "10", "Rec", daysAgo: 4, now: now),
                                 ArtistReleaseEntry(artistId: 2, artistName: "B", checkedAtMs: now - 3 * day)],
                          version: 1)
        try JSONEncoder().encode(v1).write(to: url)
        let stub = StubReleaseTransport()
        let s = ReleaseFeedService(transport: stub, fileURL: url)
        XCTAssertEqual(s.entries.count, 2)
        XCTAssertEqual(s.entries[2]?.first?.checkedAtMs ?? 0, now - 3 * day, accuracy: 1)
        XCTAssertEqual(s.pendingCountForTesting, 0)
        XCTAssertEqual(stub.requestCount, 0, "loading never fetches")
        s.playsForArtist = { _ in 2860 }       // 2-day TTL; artist 1 is fresh (checked now)
        s.noteArtistPlayed(artistId: 1, name: "A", nowMs: now)
        XCTAssertEqual(s.pendingCountForTesting, 0, "a play inside the TTL queues nothing")
    }

    func testV2RoundTripsAndOldBuildsSeeTheHead() async throws {
        let url = tempURL()
        let s = ReleaseFeedService(transport: nil, fileURL: url)
        s.seedForTesting([row(1, "A", "10", "Album", daysAgo: 8, now: now),
                          row(1, "A", "11", "Single - Single", daysAgo: 1, now: now, kind: "single")])
        // `save` is private: apply a stub batch to persist, then read it back.
        let body = """
        {"data":[{"id":"1","attributes":{"name":"A"},"relationships":{"albums":{"data":[
         {"id":"11","attributes":{"name":"Single - Single","releaseDate":"\(iso(1, now: now))","isSingle":true,"artistName":"A"}},
         {"id":"10","attributes":{"name":"Album","releaseDate":"\(iso(8, now: now))","artistName":"A"}}]}}}]}
        """
        let stub = StubReleaseTransport(body: Data(body.utf8))
        let live = ReleaseFeedService(transport: stub, fileURL: url, timeScale: 0.0001)
        live.playsForArtist = { _ in 0 }
        live.noteArtistPlayed(artistId: 1, name: "A")
        await live.drain()
        let reopened = ReleaseFeedService(transport: nil, fileURL: url)
        XCTAssertEqual(reopened.entries[1]?.compactMap(\.releaseId), ["11", "10"])
        // Downgrade simulation: the OLD load keeps the first row per artist = the head.
        let doc = try JSONDecoder().decode(ReleaseFeedService.Document.self, from: Data(contentsOf: url))
        XCTAssertEqual(doc.schemaVersion, 2)
        let old = Dictionary(doc.entries.map { ($0.artistId, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(old[1]?.releaseId, "11")
    }

    func testApplyReplacesTheListAndCarriesSimilarForward() async {
        let s = ReleaseFeedService(transport: nil, fileURL: tempURL())
        var old = row(1, "A", "gone", "Withdrawn Preorder", daysAgo: -5, now: now)
        old.similarArtistIds = [7, 8]; old.similarCheckedAtMs = now
        s.seedForTesting([old])
        let body = """
        {"data":[{"id":"1","attributes":{"name":"A"},"relationships":{"albums":{"data":[
         {"id":"new","attributes":{"name":"New","releaseDate":"\(iso(1, now: now))","artistName":"A"}}]}}}]}
        """
        let live = ReleaseFeedService(transport: StubReleaseTransport(body: Data(body.utf8)),
                                      fileURL: tempURL(), timeScale: 0.0001)
        live.seedForTesting([old])
        live.playsForArtist = { _ in 0 }
        live.noteArtistPlayed(artistId: 1, name: "A", nowMs: now + 30 * day)
        await live.drain()
        XCTAssertEqual(live.entries[1]?.compactMap(\.releaseId), ["new"])
        XCTAssertEqual(live.entries[1]?.first?.similarArtistIds, [7, 8])
        XCTAssertEqual(live.similarArtistIds(for: [1]), [7, 8])
    }

    // ── Overflow ─────────────────────────────────────────────────────────────────────────────

    private func saturatedBody(next: Bool = true) -> Data {
        let items = (1...25).map { i in
            "{\"id\":\"\(100 + i)\",\"attributes\":{\"name\":\"R\(i) - Single\",\"releaseDate\":\"\(iso(Double(i) * 0.5, now: now))\",\"isSingle\":true,\"artistName\":\"A\"}}"
        }.joined(separator: ",")
        return Data("""
        {"data":[{"id":"1","attributes":{"name":"A"},"relationships":{"albums":{"data":[\(items)]\(next ? ",\"next\":\"/v1/x?offset=25\"" : "")}}}]}
        """.utf8)
    }

    func testSaturatedArtistGetsExactlyOneFollowUp() async throws {
        let t = RoutingTransport(); t.batchBody = saturatedBody()
        t.overflowBody = Data("""
        {"data":[{"id":"200","attributes":{"name":"Older - Single","releaseDate":"\(iso(14, now: now))","isSingle":true,"artistName":"A"}}]}
        """.utf8)
        let s = ReleaseFeedService(transport: t, fileURL: tempURL(), timeScale: 0.0001)
        s.playsForArtist = { _ in 0 }
        s.noteArtistPlayed(artistId: 1, name: "A")
        await s.drain()
        XCTAssertEqual(t.urls.count, 2)
        let follow = try XCTUnwrap(t.urls.last)
        XCTAssertTrue(follow.path.hasSuffix("/artists/1/albums"))
        let q = URLComponents(url: follow, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "offset" }?.value, "25")
        XCTAssertEqual(q.first { $0.name == "sort" }?.value, "-releaseDate")
        XCTAssertEqual(s.entries[1]?.count, 26)
    }

    func testFailedFollowUpKeepsTheFirst25AndDoesNotRequeue() async {
        let t = RoutingTransport(); t.batchBody = saturatedBody()
        let s = ReleaseFeedService(transport: t, fileURL: tempURL(), timeScale: 0.0001)
        s.playsForArtist = { _ in 0 }
        s.noteArtistPlayed(artistId: 1, name: "A")
        await s.drain()
        XCTAssertEqual(s.entries[1]?.count, 25)
        XCTAssertEqual(s.pendingCountForTesting, 0)
    }

    func testNoFollowUpWithoutNext() async {
        let t = RoutingTransport(); t.batchBody = saturatedBody(next: false)
        let s = ReleaseFeedService(transport: t, fileURL: tempURL(), timeScale: 0.0001)
        s.playsForArtist = { _ in 0 }
        s.noteArtistPlayed(artistId: 1, name: "A")
        await s.drain()
        XCTAssertEqual(t.urls.count, 1)
    }
}

/// A file as an old/new build would write it.
private struct Document: Encodable {
    let schemaVersion: Int
    let entries: [ArtistReleaseEntry]
    init(rows: [ArtistReleaseEntry], version: Int) { schemaVersion = version; entries = rows }
}
