import XCTest
@testable import PocketDJ

/// On-demand lyrics: the found-only gate, the correct CDN URL, the memory + on-disk
/// cache (no refetch), and graceful miss handling (network error / empty body). The
/// network is stubbed by an injected fetcher, so these run offline + deterministically.
@MainActor
final class LyricsStoreTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-lyrics-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// `IndexSong` is Decodable-only — build one with a chosen `lyricsStatus` via JSON.
    private func song(_ id: String, status: String? = "found") -> IndexSong {
        var obj: [String: Any] = ["id": id, "name": "n", "artist": "a"]
        if let status { obj["lyricsStatus"] = status }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(IndexSong.self, from: data)
    }

    func testFetchesThenCachesInMemoryAndOnDisk() async {
        let dir = tmpDir()
        var calls = 0
        let store = LyricsStore(cacheDir: dir, baseURL: { URL(string: "https://cdn")! },
                                fetch: { _ in calls += 1; return Data("la la la".utf8) })
        let first = await store.lyrics(for: song("sng_1"))
        XCTAssertEqual(first, "la la la")
        XCTAssertEqual(calls, 1)
        // In-memory cache → no refetch.
        let second = await store.lyrics(for: song("sng_1"))
        XCTAssertEqual(second, "la la la")
        XCTAssertEqual(calls, 1)
        // On disk too — a fresh store over the same dir reads it without any fetch.
        var calls2 = 0
        let store2 = LyricsStore(cacheDir: dir, baseURL: { URL(string: "https://cdn")! },
                                 fetch: { _ in calls2 += 1; return Data() })
        let cached = await store2.lyrics(for: song("sng_1"))
        XCTAssertEqual(cached, "la la la")
        XCTAssertEqual(calls2, 0)
    }

    func testRequestsCorrectURL() async {
        var requested: URL?
        let store = LyricsStore(cacheDir: tmpDir(), baseURL: { URL(string: "https://cdn.example")! },
                                fetch: { url in requested = url; return Data("x".utf8) })
        _ = await store.lyrics(for: song("sng_abc"))
        XCTAssertEqual(requested, URL(string: "https://cdn.example/lyrics/sng_abc.txt"))
    }

    func testSkipsWhenStatusNotFound() async {
        var calls = 0
        let store = LyricsStore(cacheDir: tmpDir(), baseURL: { URL(string: "https://cdn")! },
                                fetch: { _ in calls += 1; return Data("x".utf8) })
        let notFound = await store.lyrics(for: song("sng_1", status: "notfound"))
        let absent = await store.lyrics(for: song("sng_2", status: nil))
        XCTAssertNil(notFound)
        XCTAssertNil(absent)
        XCTAssertEqual(calls, 0)         // gated by lyricsStatus → never hits the network
    }

    func testNetworkErrorYieldsNilAndCachesNothing() async {
        let dir = tmpDir()
        let store = LyricsStore(cacheDir: dir, baseURL: { URL(string: "https://cdn")! },
                                fetch: { _ in throw URLError(.fileDoesNotExist) })
        let r = await store.lyrics(for: song("sng_1"))
        XCTAssertNil(r)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sng_1.txt").path))
    }

    func testEmptyBodyTreatedAsMiss() async {
        let store = LyricsStore(cacheDir: tmpDir(), baseURL: { URL(string: "https://cdn")! },
                                fetch: { _ in Data("   \n".utf8) })
        let r = await store.lyrics(for: song("sng_1"))
        XCTAssertNil(r)
    }
}
