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

    // MARK: Stem (Demucs) ingestion — decode + URL resolution

    func testManifestDecodesStems() throws {
        let json = """
        {
          "sng_s": { "key": "rips/sng_s.mp3", "source": "digital",
                     "stems": { "vocals": "rips/stems/sng_s/vocals.mp3", "drums": "rips/stems/sng_s/drums.mp3",
                                "bass": "rips/stems/sng_s/bass.mp3", "other": "rips/stems/sng_s/other.mp3" },
                     "stemModel": "htdemucs", "stemVersion": 1, "stemFormat": "mp3",
                     "stemmedAt": 1750000000000, "stemBytes": 31000000 },
          "sng_plain": { "key": "rips/sng_plain.mp3", "source": "digital" }
        }
        """
        let m = try JSONDecoder().decode([String: RipsStore.ManifestEntry].self, from: Data(json.utf8))
        // Stemmed entry: version stamp + the 4 typed keys present.
        XCTAssertEqual(m["sng_s"]?.stemVersion, 1)
        XCTAssertEqual(m["sng_s"]?.stemModel, "htdemucs")
        XCTAssertEqual(m["sng_s"]?.stems?.vocals, "rips/stems/sng_s/vocals.mp3")
        XCTAssertEqual(m["sng_s"]?.stems?.other, "rips/stems/sng_s/other.mp3")
        // Plain entry: no stems ⇒ nil version (the isStemmed predicate is false).
        XCTAssertNil(m["sng_plain"]?.stemVersion)
        XCTAssertNil(m["sng_plain"]?.stems)
    }

    func testStemURLsResolveAgainstRipsBase() {
        let entry = RipsStore.ManifestEntry(key: "rips/sng_s.mp3")
        var stemmed = entry
        stemmed.stems = .init(vocals: "rips/stems/sng_s/vocals.mp3", drums: "rips/stems/sng_s/drums.mp3",
                              bass: "rips/stems/sng_s/bass.mp3", other: "rips/stems/sng_s/other.mp3")
        stemmed.stemVersion = 1
        let urls = RipsStore.stemURLs(for: stemmed, ripsBase: ripsBase)
        XCTAssertEqual(urls?["vocals"]?.absoluteString, "https://rips.example.com/rips/stems/sng_s/vocals.mp3")
        XCTAssertEqual(urls?["drums"]?.absoluteString, "https://rips.example.com/rips/stems/sng_s/drums.mp3")
        XCTAssertEqual(urls?["bass"]?.absoluteString, "https://rips.example.com/rips/stems/sng_s/bass.mp3")
        XCTAssertEqual(urls?["other"]?.absoluteString, "https://rips.example.com/rips/stems/sng_s/other.mp3")
        XCTAssertEqual(urls?.count, 4)
    }

    func testStemURLsNilWhenNotStemmed() {
        XCTAssertNil(RipsStore.stemURLs(for: .init(key: "rips/s.mp3"), ripsBase: ripsBase))
        XCTAssertNil(RipsStore.stemURLs(for: nil, ripsBase: ripsBase))
    }

    func testStemJobDecodesAllPhases() throws {
        // The server emits phases the rip Phase enum doesn't model (stemming/ineligible/ripping).
        for raw in ["queued", "ripping", "stemming", "ready", "error", "ineligible"] {
            let json = #"{"jobId":"j1","songId":"sng_s","phase":"\#(raw)"}"#
            let job = try JSONDecoder().decode(RipsStore.StemJob.self, from: Data(json.utf8))
            XCTAssertEqual(job.phase.rawValue, raw)
        }
        // The idempotent-skip + ineligible responses carry a null jobId.
        let skip = try JSONDecoder().decode(RipsStore.StemJob.self,
            from: Data(#"{"jobId":null,"songId":"sng_s","phase":"ready"}"#.utf8))
        XCTAssertNil(skip.jobId)
        XCTAssertEqual(skip.phase, .ready)
    }

    func testBatchStemItemDecodesStatuses() throws {
        // A /stemify-collection results array spans the rip-first + terminal buckets.
        let json = """
        [ {"songId":"a","status":"ready"},
          {"songId":"b","status":"ripping","jobId":"jb"},
          {"songId":"c","status":"ineligible"},
          {"songId":"d","status":"needsCut","jobId":"jd"} ]
        """
        let items = try JSONDecoder().decode([RipsStore.BatchStemItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.map(\.status), ["ready", "ripping", "ineligible", "needsCut"])
        XCTAssertEqual(items[1].jobId, "jb")
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

    // MARK: Save-picker base name (no extension — the .fileExporter appends ".mp3")

    func testDownloadBaseNameOmitsExtension() {
        XCTAssertEqual(RipsStore.downloadBaseName(artist: "Daft Punk", title: "Aerodynamic"),
                       "Daft Punk - Aerodynamic")
    }

    func testDownloadBaseNameSanitizes() {
        XCTAssertEqual(RipsStore.downloadBaseName(artist: "AC/DC", title: "Who Made Who?"),
                       "AC_DC - Who Made Who_")
    }

    func testDownloadFileNameIsBaseNamePlusMp3() {
        let base = RipsStore.downloadBaseName(artist: "AC/DC", title: "Who Made Who?")
        XCTAssertEqual(RipsStore.downloadFileName(artist: "AC/DC", title: "Who Made Who?"),
                       base + ".mp3")
    }

    // MARK: Export document carries the mp3 bytes for the save picker

    func testRippedAudioFileCarriesBytes() throws {
        let payload = Data("ID3-fake-mp3-bytes".utf8)
        let doc = RippedAudioFile(data: payload)
        XCTAssertEqual(doc.data, payload)
        // The exporter's content type resolves to an mp3-flavoured UTType.
        XCTAssertTrue(RippedAudioFile.readableContentTypes.contains(RippedAudioFile.mp3Type))
        XCTAssertTrue(RippedAudioFile.mp3Type.conforms(to: .audio))
    }

    /// Song rows and the song detail screen read BPM/key/camelot through ONE overlay: the rip's
    /// measured analysis wins, the catalog value fills in (the "U" on the detail screen bug).
    @MainActor
    func testAnalysisOverlayPrefersRipAnalysisAndFallsBackToCatalog() {
        let rips = RipsStore()
        rips.setManifest(["sng_eyes": .init(key: "rips/sng_eyes.mp3", bpm: 117.5, musicalKey: "D minor", camelot: "7A"),
                          "sng_partial": .init(key: "rips/sng_partial.mp3", bpm: 90)])
        let a = rips.analysis(songId: "sng_eyes", bpm: nil, key: nil, camelot: nil)
        XCTAssertEqual(a.bpm, 117.5); XCTAssertEqual(a.key, "D minor"); XCTAssertEqual(a.camelot, "7A")
        let b = rips.analysis(songId: "sng_partial", bpm: 88, key: "C major", camelot: "8B")
        XCTAssertEqual(b.bpm, 90); XCTAssertEqual(b.key, "C major"); XCTAssertEqual(b.camelot, "8B")
        let c = rips.analysis(songId: "sng_unripped", bpm: 120, key: nil, camelot: nil)
        XCTAssertEqual(c.bpm, 120); XCTAssertNil(c.camelot)
    }
}
