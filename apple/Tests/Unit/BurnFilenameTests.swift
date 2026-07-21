import XCTest
@testable import PocketDJ

/// Item 9 — descriptive BURN filenames (CRITIC-A). The audio file gets a sanitized
/// "Artist-Song-Album-Year-Genre-Camelot-Key-BPM" prefix (digital per-song) or
/// "Artist-Album-Year-Genre" (analog SHARED album file), ALWAYS suffixed with the stable
/// id (songId / albumId) + extension so keying/dedup/isFresh/finalize stay correct. The
/// sidecar is ALWAYS per-song-descriptive + songId. These tests drive the real `burn(...)`
/// with the catalog `lookup` wired so the prefix is actually built.
@MainActor
final class BurnFilenameTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    private func makeRips() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BurnFilenameStubURLProtocol.self]
        return RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
    }

    private func makeBurns(_ rips: RipsStore,
                           songs: [String: IndexSong] = [:],
                           albums: [String: IndexAlbum] = [:]) -> BurnStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-burnfn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        burns.lookup = { id in (songs[id], songs[id]?.albumId.flatMap { albums[$0] }) }
        return burns
    }

    private func cleanBurnedFiles(_ names: [String]) {
        guard let dir = try? RipsStore.burnsDirectory() else { return }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    private func song(_ id: String, album: String?, artist: String, name: String,
                      year: Int? = nil, bpm: Double? = nil, key: String? = nil, camelot: String? = nil) -> IndexSong {
        IndexSong(id: id, albumId: album, artist: artist, name: name, trackNumber: nil,
                  year: year, sentimentKeywords: nil, explicit: nil, bpm: bpm, key: key,
                  camelot: camelot, length: nil, fileType: nil, lyricsStatus: nil, appleMusicId: nil)
    }

    private func album(_ id: String, artist: String, name: String, genre: String?, year: Int?) -> IndexAlbum {
        IndexAlbum(id: id, artist: artist, name: name, coverArt: nil, coverArtSources: nil,
                   genre: genre, year: year, country: nil, trackList: [], fileType: nil,
                   audioTracks: nil, audioDurationSec: nil, appleMusicId: nil)
    }

    override func setUp() {
        super.setUp()
        BurnFilenameStubURLProtocol.body = Data("MP3".utf8)
    }

    // MARK: DIGITAL — per-song descriptive name + per-song sidecar, songId suffix preserved

    func testDigitalDescriptivePerSongName() async {
        let s = song("sng_1", album: "alb_1", artist: "Aria", name: "Neon Lights",
                     year: 2021, bpm: 128, key: "A min", camelot: "8A")
        let a = album("alb_1", artist: "Aria", name: "Night Drive", genre: "Synthwave", year: 2021)
        let rips = makeRips()
        let burns = makeBurns(rips, songs: ["sng_1": s], albums: ["alb_1": a])
        rips.setManifest(["sng_1": .init(key: "rips/sng_1.mp3", source: "digital",
                                         bpm: 128, musicalKey: "A min", camelot: "8A")])

        let r = await burns.burn([(id: "sng_1", title: "Neon Lights", artist: "Aria")])
        XCTAssertEqual(r.burned, 1)
        let audio = burns.items["sng_1"]?.audioFileName ?? ""
        // Descriptive prefix present, in order, and the songId suffix + extension are kept.
        XCTAssertEqual(audio, "Aria-Neon Lights-Night Drive-2021-Synthwave-8A-A min-128-sng_1.mp3")
        XCTAssertEqual(burns.items["sng_1"]?.sidecarFileName, "Aria-Neon Lights-Night Drive-2021-Synthwave-8A-A min-128-sng_1.txt")
        // The file actually exists on disk under the descriptive name + resolves.
        XCTAssertNotNil(burns.localURL(forSong: "sng_1"))
        cleanBurnedFiles([audio, burns.items["sng_1"]?.sidecarFileName ?? ""])
    }

    /// Manifest analyzed bpm/key/camelot take precedence over the catalog's (like the sidecar).
    func testDigitalNamePrefersManifestAnalyzedValues() async {
        let s = song("sng_2", album: "alb_2", artist: "Max", name: "Run",
                     year: 2019, bpm: 100, key: "C", camelot: "8B")
        let a = album("alb_2", artist: "Max", name: "Go", genre: "Pop", year: 2019)
        let rips = makeRips()
        let burns = makeBurns(rips, songs: ["sng_2": s], albums: ["alb_2": a])
        // Manifest carries DIFFERENT analyzed values.
        rips.setManifest(["sng_2": .init(key: "rips/sng_2.mp3", source: "digital",
                                         bpm: 132, musicalKey: "D", camelot: "10A")])
        _ = await burns.burn([(id: "sng_2", title: "Run", artist: "Max")])
        let audio = burns.items["sng_2"]?.audioFileName ?? ""
        XCTAssertTrue(audio.contains("-10A-D-132-"), "manifest bpm/key/camelot win: \(audio)")
        XCTAssertFalse(audio.contains("8B"), "the stale catalog camelot is not used")
        cleanBurnedFiles([audio, burns.items["sng_2"]?.sidecarFileName ?? ""])
    }

    /// Missing fields are simply dropped (no empty `--` placeholder runs).
    func testDigitalNameOmitsMissingFields() async {
        let s = song("sng_3", album: nil, artist: "Solo", name: "Bare")  // no album/year/bpm/key
        let rips = makeRips()
        let burns = makeBurns(rips, songs: ["sng_3": s])
        rips.setManifest(["sng_3": .init(key: "rips/sng_3.mp3", source: "digital")])
        _ = await burns.burn([(id: "sng_3", title: "Bare", artist: "Solo")])
        let audio = burns.items["sng_3"]?.audioFileName ?? ""
        XCTAssertEqual(audio, "Solo-Bare-sng_3.mp3")
        XCTAssertFalse(audio.contains("--"), "no empty placeholder runs")
        cleanBurnedFiles([audio, burns.items["sng_3"]?.sidecarFileName ?? ""])
    }

    // MARK: ANALOG — ALBUM-LEVEL audio name shared across the album, per-song sidecars

    func testAnalogAlbumLevelSharedAudioNamePerSongSidecars() async {
        let sA = song("sng_a", album: "alb_x", artist: "VinylBand", name: "Side A One")
        let sB = song("sng_b", album: "alb_x", artist: "VinylBand", name: "Side A Two")
        let a = album("alb_x", artist: "VinylBand", name: "The Record", genre: "Rock", year: 1979)
        let rips = makeRips()
        let burns = makeBurns(rips, songs: ["sng_a": sA, "sng_b": sB], albums: ["alb_x": a])
        // Both songs share the album's analog mp3 (the manifest key basename is the albumId).
        rips.setManifest([
            "sng_a": .init(key: "rips/alb_x.mp3", source: "analog", startMs: 0),
            "sng_b": .init(key: "rips/alb_x.mp3", source: "analog", startMs: 222000),
        ])
        _ = await burns.burn([
            (id: "sng_a", title: "Side A One", artist: "VinylBand"),
            (id: "sng_b", title: "Side A Two", artist: "VinylBand"),
        ])
        let audioA = burns.items["sng_a"]?.audioFileName ?? ""
        let audioB = burns.items["sng_b"]?.audioFileName ?? ""
        // ALBUM-LEVEL: both songs map to the SAME audio file (one shared album mp3), named
        // Artist-Album-Year-Genre + the albumId suffix (NO per-song title/bpm).
        XCTAssertEqual(audioA, "VinylBand-The Record-1979-Rock-alb_x.mp3")
        XCTAssertEqual(audioA, audioB, "analog songs share ONE album audio file (dedup intact)")
        // ...but each gets its OWN per-song descriptive sidecar.
        XCTAssertEqual(burns.items["sng_a"]?.sidecarFileName, "VinylBand-Side A One-The Record-1979-Rock-sng_a.txt")
        XCTAssertEqual(burns.items["sng_b"]?.sidecarFileName, "VinylBand-Side A Two-The Record-1979-Rock-sng_b.txt")
        XCTAssertNotEqual(burns.items["sng_a"]?.sidecarFileName, burns.items["sng_b"]?.sidecarFileName)
        // The analog seek offset is preserved on each item.
        XCTAssertEqual(burns.items["sng_b"]?.startMs, 222000)
        cleanBurnedFiles([audioA, burns.items["sng_a"]?.sidecarFileName ?? "", burns.items["sng_b"]?.sidecarFileName ?? ""])
    }

    // MARK: Sanitization + length — illegal chars stripped, prefix capped, id suffix kept

    func testSanitizationAndLengthCap() async {
        // Illegal filesystem chars + an absurdly long title that must be truncated.
        let longTitle = String(repeating: "X", count: 300)
        let s = song("sng_san", album: "alb_s", artist: "A/B:C*?",
                     name: "Hello\"<>|World " + longTitle, year: 2020)
        let a = album("alb_s", artist: "A/B:C*?", name: "Al/bum", genre: "Gen|re", year: 2020)
        let rips = makeRips()
        let burns = makeBurns(rips, songs: ["sng_san": s], albums: ["alb_s": a])
        rips.setManifest(["sng_san": .init(key: "rips/sng_san.mp3", source: "digital")])
        _ = await burns.burn([(id: "sng_san", title: s.name, artist: s.artist)])
        let audio = burns.items["sng_san"]?.audioFileName ?? ""

        // No illegal filesystem characters survive in the PREFIX (the id suffix is safe).
        for ch in "/\\:*?\"<>|" {
            XCTAssertFalse(audio.dropLast(".mp3".count + "sng_san".count + 1).contains(ch),
                           "illegal char \(ch) leaked into the name: \(audio)")
        }
        // The id suffix + extension are ALWAYS preserved whole, even after truncation.
        XCTAssertTrue(audio.hasSuffix("-sng_san.mp3"), "id suffix + ext preserved: \(audio)")
        // The total name is bounded (prefix cap ~150 + suffix), well under any FS limit.
        XCTAssertLessThanOrEqual(audio.count, 200, "name truncated to a safe length: \(audio.count)")
        cleanBurnedFiles([audio, burns.items["sng_san"]?.sidecarFileName ?? ""])
    }

    /// No catalog lookup (lookup returns nil) → empty prefix → bare id name (back-compat with
    /// the prior `<id>.mp3` / `<albumId>.mp3` scheme; the existing BurnStore tests rely on this).
    func testNoLookupFallsBackToBareIdName() async {
        let rips = makeRips()
        let burns = makeBurns(rips)   // lookup wired but returns nil for unknown ids
        rips.setManifest(["sng_n": .init(key: "rips/sng_n.mp3", source: "digital")])
        _ = await burns.burn([(id: "sng_n", title: "N", artist: "A")])
        XCTAssertEqual(burns.items["sng_n"]?.audioFileName, "sng_n.mp3", "no catalog → bare id name")
        XCTAssertEqual(burns.items["sng_n"]?.sidecarFileName, "sng_n.txt")
        cleanBurnedFiles(["sng_n.mp3", "sng_n.txt"])
    }
}

private final class BurnFilenameStubURLProtocol: URLProtocol {
    static var body = Data("MP3".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
