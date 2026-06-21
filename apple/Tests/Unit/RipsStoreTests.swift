import XCTest
@testable import PocketDJ

/// Pure-logic tests for the rip-on-demand client: manifest parse, URL resolution
/// (cached → S3 mp3, live → HLS-with-token), job-phase label mapping, and the
/// download filename slug. AVPlayer + the inline player UI need a sim/device and are
/// exercised manually (see the PR notes), not here.
final class RipsStoreTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.example.com")!

    // MARK: Manifest parse

    func testManifestDecodesEntries() throws {
        let json = """
        {
          "sng_1": { "key": "rips/sng_1.mp3", "ext": "mp3", "source": "digital",
                     "startMs": 0, "durationMs": 210000, "bpm": 128, "musicalKey": "Am",
                     "camelot": "8A", "waveform": "rips/sng_1.png", "analyzed": true },
          "sng_2": { "key": "rips/sng_2.mp3", "source": "analog", "startMs": 12000 }
        }
        """
        let m = try JSONDecoder().decode([String: RipsStore.ManifestEntry].self, from: Data(json.utf8))
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m["sng_1"]?.key, "rips/sng_1.mp3")
        XCTAssertEqual(m["sng_1"]?.bpm, 128)
        XCTAssertEqual(m["sng_1"]?.waveform, "rips/sng_1.png")
        XCTAssertEqual(m["sng_2"]?.startMs, 12000)
        XCTAssertNil(m["sng_2"]?.waveform)   // unknown/absent fields tolerated
    }

    func testManifestIgnoresUnknownFields() throws {
        let json = #"{ "sng_x": { "key": "rips/sng_x.mp3", "futureField": 42, "nested": {"a":1} } }"#
        let m = try JSONDecoder().decode([String: RipsStore.ManifestEntry].self, from: Data(json.utf8))
        XCTAssertEqual(m["sng_x"]?.key, "rips/sng_x.mp3")
    }

    // MARK: Cached-URL resolution (cached → durable S3 mp3)

    func testCachedURLResolvesAgainstRipsBase() {
        let m: [String: RipsStore.ManifestEntry] = ["sng_1": .init(key: "rips/sng_1.mp3")]
        let url = RipsStore.cachedURL("sng_1", manifest: m, ripsBase: ripsBase)
        XCTAssertEqual(url?.absoluteString, "https://rips.example.com/rips/sng_1.mp3")
    }

    func testCachedURLNilForMiss() {
        XCTAssertNil(RipsStore.cachedURL("nope", manifest: [:], ripsBase: ripsBase))
    }

    // MARK: Live HLS URL (live → /hls/<id>/index.m3u8 with token)

    func testLiveURLAppendsToken() {
        let url = RipsStore.liveURL(serverUrl: "https://imac.ts.net",
                                    streamPath: "/hls/sng_1/index.m3u8", token: "secret123")
        XCTAssertEqual(url?.absoluteString, "https://imac.ts.net/hls/sng_1/index.m3u8?token=secret123")
    }

    func testLiveURLOmitsEmptyToken() {
        let url = RipsStore.liveURL(serverUrl: "https://imac.ts.net/",
                                    streamPath: "/hls/sng_1/index.m3u8", token: "")
        // trailing slash on serverUrl is trimmed; no ?token query
        XCTAssertEqual(url?.absoluteString, "https://imac.ts.net/hls/sng_1/index.m3u8")
    }

    func testLiveURLPercentEncodesToken() {
        let url = RipsStore.liveURL(serverUrl: "https://imac.ts.net",
                                    streamPath: "/hls/sng_1/index.m3u8", token: "a b/c")
        XCTAssertEqual(url?.absoluteString, "https://imac.ts.net/hls/sng_1/index.m3u8?token=a%20b%2Fc")
    }

    func testLiveURLIsRecognizedAsLive() {
        // The play() path treats a URL containing "/hls/" as live (mirrors the PWA).
        let url = RipsStore.liveURL(serverUrl: "https://imac.ts.net",
                                    streamPath: "/hls/sng_1/index.m3u8", token: "t")!
        XCTAssertTrue(url.absoluteString.contains("/hls/"))
        let mp3 = RipsStore.cachedURL("sng_1", manifest: ["sng_1": .init(key: "rips/sng_1.mp3")], ripsBase: ripsBase)!
        XCTAssertFalse(mp3.absoluteString.contains("/hls/"))
    }

    // MARK: Waveform URL (only for cached; nil for live)

    func testWaveformURLResolves() {
        let entry = RipsStore.ManifestEntry(key: "rips/s.mp3", waveform: "rips/s.png")
        let url = RipsStore.waveformURL(for: entry, ripsBase: ripsBase)
        XCTAssertEqual(url?.absoluteString, "https://rips.example.com/rips/s.png")
    }

    func testWaveformURLNilWhenAbsent() {
        XCTAssertNil(RipsStore.waveformURL(for: .init(key: "rips/s.mp3"), ripsBase: ripsBase))
        XCTAssertNil(RipsStore.waveformURL(for: nil, ripsBase: ripsBase))
    }

    // MARK: Download filename slug

    func testDownloadFileNameSanitizes() {
        let name = RipsStore.downloadFileName(artist: "AC/DC", title: "Who Made Who?")
        XCTAssertEqual(name, "AC_DC - Who Made Who_.mp3")
    }

    func testDownloadFileNamePlain() {
        XCTAssertEqual(RipsStore.downloadFileName(artist: "Daft Punk", title: "Aerodynamic"),
                       "Daft Punk - Aerodynamic.mp3")
    }
}
