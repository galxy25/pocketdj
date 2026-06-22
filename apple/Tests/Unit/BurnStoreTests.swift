import XCTest
@testable import PocketDJ

/// Tests for the app-side BURN serial download queue (Feature 2 BURN). They drive
/// `BurnStore.burn(...)` end-to-end against a REAL burns directory + a `URLProtocol`
/// stub serving the durable mp3 bytes, covering: the serial one-by-one queue, the
/// idempotency skip (already-ready + fresh), partial success (some not-ripped / some
/// failed), the out-of-space abort, the analog shared-album-file scheme, and the
/// `buildSidecar` field order/format. The rippedAt-staleness paths live in
/// BurnStaleTests; this file covers the rest.
@MainActor
final class BurnStoreTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    // MARK: Fixtures

    private func makeRips() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BurnStubURLProtocol.self]
        return RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
    }

    private func makeBurns(_ rips: RipsStore) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burnstore-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return BurnStore(rips: rips, fileURL: url)
    }

    /// Remove any burned files this run left in the shared burns directory so repeated
    /// test runs (and the analog-shared assertions) start clean.
    private func cleanBurnedFiles(_ names: [String]) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    override func setUp() {
        super.setUp()
        BurnStubURLProtocol.body = Data("MP3-DATA".utf8)   // 8 bytes
    }

    // MARK: Empty / happy-path serial queue

    func testBurnEmptyIsNoOp() async {
        let rips = makeRips(); let burns = makeBurns(rips)
        let r = await burns.burn([])
        XCTAssertEqual(r, BurnStore.BurnResult())
        XCTAssertTrue(burns.items.isEmpty)
    }

    func testBurnDownloadsRippedSongsSerially() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_2.mp3"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest([
            "sng_1": .init(key: "rips/sng_1.mp3", source: "digital", durationMs: 200000),
            "sng_2": .init(key: "rips/sng_2.mp3", source: "digital"),
        ])
        let r = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_2", title: "Two", artist: "A"),
        ])
        XCTAssertEqual(r.burned, 2)
        XCTAssertEqual(r.total, 2)
        XCTAssertEqual(r.notRipped, 0)
        XCTAssertEqual(r.failed, 0)
        XCTAssertEqual(burns.items["sng_1"]?.state, .ready)
        XCTAssertEqual(burns.items["sng_1"]?.audioFileName, "sng_1.mp3")   // keyed by songId
        XCTAssertEqual(burns.items["sng_1"]?.bytes, 8)
        XCTAssertEqual(burns.items["sng_1"]?.durationMs, 200000)
        XCTAssertNil(burns.progress, "progress is cleared when the run finishes")
        cleanBurnedFiles(["sng_1.mp3", "sng_2.mp3"])
    }

    func testBurnDedupesRepeatedSong() async {
        cleanBurnedFiles(["sng_1.mp3"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital")])
        let r = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_1", title: "One", artist: "A"),
        ])
        XCTAssertEqual(r.total, 1, "repeated song is downloaded once")
        XCTAssertEqual(r.burned, 1)
        cleanBurnedFiles(["sng_1.mp3"])
    }

    // MARK: Idempotency — already-ready + fresh skips re-download

    func testBurnIsIdempotentForFreshItem() async {
        cleanBurnedFiles(["sng_1.mp3"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital")])
        let song = (id: "sng_1", title: "One", artist: "A")
        _ = await burns.burn([song])
        XCTAssertEqual(burns.items["sng_1"]?.bytes, 8)

        // A second burn with DIFFERENT bytes available must NOT re-download (fresh skip).
        BurnStubURLProtocol.body = Data("LONGER-MP3-DATA".utf8)
        let r = await burns.burn([song])
        XCTAssertEqual(r.burned, 1)
        XCTAssertEqual(burns.items["sng_1"]?.bytes, 8, "fresh item is not re-downloaded")
        cleanBurnedFiles(["sng_1.mp3"])
    }

    // MARK: Partial success — not-ripped songs are skipped, not failed

    func testBurnSkipsNotRippedSongs() async {
        cleanBurnedFiles(["sng_1.mp3"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital")])  // sng_2 not ripped
        let r = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_2", title: "Two", artist: "A"),
        ])
        XCTAssertEqual(r.burned, 1)
        XCTAssertEqual(r.notRipped, 1)
        XCTAssertEqual(r.failed, 0)
        XCTAssertEqual(r.total, 2)
        XCTAssertEqual(burns.items["sng_2"]?.state, .error)
        XCTAssertNotNil(burns.items["sng_2"]?.error)
        cleanBurnedFiles(["sng_1.mp3"])
    }

    // MARK: Out-of-space — the BurnResult default is false on a clean run
    //
    // The real OOS abort fires on an `NSFileWriteOutOfSpaceError` from `data.write(to:)`,
    // which cannot be forced through the (non-injectable) Application Support filesystem
    // seam without an actually-full disk, so the abort branch itself is verified by
    // inspection. What IS testable here: a successful run leaves `outOfSpace` false and
    // does not abort the remainder (both songs burn).

    func testBurnSuccessfulRunDoesNotFlagOutOfSpace() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_2.mp3"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest([
            "sng_1": .init(key: "rips/sng_1.mp3", source: "digital"),
            "sng_2": .init(key: "rips/sng_2.mp3", source: "digital"),
        ])
        let r = await burns.burn([
            (id: "sng_1", title: "One", artist: "A"),
            (id: "sng_2", title: "Two", artist: "A"),
        ])
        XCTAssertFalse(r.outOfSpace)
        XCTAssertEqual(r.burned, 2, "no abort — the whole queue drains")
        cleanBurnedFiles(["sng_1.mp3", "sng_2.mp3"])
    }

    // MARK: Analog — one shared <albumId>.mp3 across the album's songs

    func testBurnAnalogSharesAlbumFile() async {
        cleanBurnedFiles(["alb_1.mp3", "sng_a.txt", "sng_b.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        // Two songs of the same analog album share the manifest key (the album mp3).
        rips.setManifest([
            "sng_a": .init(key: "rips/alb_1.mp3", source: "analog", startMs: 0),
            "sng_b": .init(key: "rips/alb_1.mp3", source: "analog", startMs: 222000),
        ])
        let r = await burns.burn([
            (id: "sng_a", title: "A", artist: "X"),
            (id: "sng_b", title: "B", artist: "X"),
        ])
        XCTAssertEqual(r.burned, 2)
        // Both items point at the ONE shared album mp3...
        XCTAssertEqual(burns.items["sng_a"]?.audioFileName, "alb_1.mp3")
        XCTAssertEqual(burns.items["sng_b"]?.audioFileName, "alb_1.mp3")
        // ...but carry their own analog seek offset + sidecar.
        XCTAssertEqual(burns.items["sng_a"]?.startMs, 0)
        XCTAssertEqual(burns.items["sng_b"]?.startMs, 222000)
        XCTAssertEqual(burns.items["sng_a"]?.sidecarFileName, "sng_a.txt")
        XCTAssertEqual(burns.items["sng_b"]?.sidecarFileName, "sng_b.txt")
        cleanBurnedFiles(["alb_1.mp3", "sng_a.txt", "sng_b.txt"])
    }

    // MARK: localURL / totalBytes / remove / reconcile seams

    func testLocalURLAndTotalBytesAndRemove() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt"])
        let rips = makeRips(); let burns = makeBurns(rips)
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital")])
        _ = await burns.burn([(id: "sng_1", title: "One", artist: "A")])
        XCTAssertNotNil(burns.localURL(forSong: "sng_1"))
        XCTAssertEqual(burns.totalBytes, 8)
        burns.remove("sng_1")
        XCTAssertNil(burns.items["sng_1"])
        XCTAssertNil(burns.localURL(forSong: "sng_1"))
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt"])
    }

    // MARK: buildSidecar — header order + analyzed-value preference + raw JSON

    func testBuildSidecarHeaderOrderAndAnalyzedValues() throws {
        let song = IndexSong(id: "sng_1", albumId: "alb_1", artist: "Aria", name: "Neon",
                             trackNumber: 1, year: 2020, sentimentKeywords: ["night", "drive"],
                             explicit: false, bpm: 120, key: "C major", camelot: "8B",
                             length: 222000, fileType: "mp3", lyricsStatus: nil, appleMusicId: nil)
        let album = IndexAlbum(id: "alb_1", artist: "Aria", name: "Night Drive", coverArt: nil,
                               coverArtSources: nil, genre: "Electronic", year: 2020, country: "US",
                               trackList: ["sng_1"], fileType: "mp3", audioTracks: nil,
                               audioDurationSec: nil)
        // The manifest entry's analyzed bpm/key/camelot must WIN over the catalog values.
        let entry = RipsStore.ManifestEntry(key: "rips/sng_1.mp3", source: "digital",
                                            bpm: 128, musicalKey: "A minor", camelot: "8A")

        let sidecar = BurnStore.buildSidecar(
            songId: "sng_1", fallback: (id: "sng_1", title: "Fallback", artist: "Fallback"),
            song: song, album: album, entry: entry)
        let lines = sidecar.components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "Aria — Neon")                 // catalog name beats fallback
        XCTAssertTrue(lines[1].allSatisfy { $0 == "=" })        // 60-char rule
        // Header block order: BPM · Key+Camelot · Sentiment · Album.
        XCTAssertTrue(sidecar.contains("BPM:        128.0"))    // analyzed bpm wins
        XCTAssertTrue(sidecar.contains("Key:        A minor  (Camelot 8A)"))  // analyzed key/camelot win
        XCTAssertTrue(sidecar.contains("Sentiment:  night, drive"))
        XCTAssertTrue(sidecar.contains("Album:      Night Drive"))
        // Section blocks + a parseable Raw JSON object embedding the entry.
        XCTAssertTrue(sidecar.contains("-- Song metadata --"))
        XCTAssertTrue(sidecar.contains("-- Album metadata --"))
        XCTAssertTrue(sidecar.contains("-- Raw JSON --"))
        let jsonStart = sidecar.range(of: "-- Raw JSON --")!.upperBound
        let jsonText = String(sidecar[jsonStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let obj = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any])
        XCTAssertNotNil(obj["song"]); XCTAssertNotNil(obj["album"]); XCTAssertNotNil(obj["manifestEntry"])
        let me = try XCTUnwrap(obj["manifestEntry"] as? [String: Any])
        XCTAssertEqual(me["musicalKey"] as? String, "A minor")  // JSON agrees with prose header
    }

    func testBuildSidecarFallsBackWhenSongMissing() {
        let entry = RipsStore.ManifestEntry(key: "rips/sng_x.mp3", source: "digital")
        let sidecar = BurnStore.buildSidecar(
            songId: "sng_x", fallback: (id: "sng_x", title: "Mystery", artist: "Nobody"),
            song: nil, album: nil, entry: entry)
        XCTAssertTrue(sidecar.contains("Nobody — Mystery"))     // fallback used
        XCTAssertTrue(sidecar.contains("(song not found in index)"))
        XCTAssertTrue(sidecar.contains("(album not found in index)"))
        XCTAssertTrue(sidecar.contains("BPM:        —"))        // missing → em dash
    }

    // MARK: Persistence — items reload from the index file

    func testBurnIndexPersistsAcrossInstances() async {
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt"])
        let rips = makeRips()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burn-persist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital")])
        let burns1 = BurnStore(rips: rips, fileURL: url)
        _ = await burns1.burn([(id: "sng_1", title: "One", artist: "A")])

        let burns2 = BurnStore(rips: rips, fileURL: url)
        XCTAssertEqual(burns2.items["sng_1"]?.state, .ready)
        XCTAssertEqual(burns2.items["sng_1"]?.bytes, 8)
        cleanBurnedFiles(["sng_1.mp3", "sng_1.txt"])
    }
}

/// Minimal `URLProtocol` serving HTTP 200 + a fixed body for the burn download path.
private final class BurnStubURLProtocol: URLProtocol {
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
