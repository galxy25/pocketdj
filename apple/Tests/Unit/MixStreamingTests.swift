import AVFoundation
import XCTest
@testable import PocketDJ

/// STREAMING MODE for the Mix decks: a ripped-but-not-downloaded song loads onto a deck at once
/// and plays from its GROWING file. Pure frontier math; the engine's hold → attach → append →
/// complete lifecycle over a real LAME mp3 written progressively; seek past the frontier; a
/// stream dying before audio; the downloader fetching in PLAY order and leaving streamed songs to
/// their stream; and the whole loop end-to-end through `MixStreamLoader` against a stub server
/// (presign → chunked bytes → adoption as an ordinary burn).
@MainActor
final class MixStreamingTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!

    override func setUp() {
        super.setUp()
        StreamStubURLProtocol.reset()
        CollectionMixDownloader.idleWaitMs = 10
    }

    override func tearDown() {
        CollectionMixDownloader.idleWaitMs = 500
        StreamStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    private var fixture: Data {
        get throws {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "stream-tone-12s", withExtension: "mp3"))
            return try Data(contentsOf: url)
        }
    }

    private func tempFile(_ name: String = "s") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-stream-\(name)-\(UUID().uuidString).mp3")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func stubConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StreamStubURLProtocol.self]
        return c
    }

    private func makeRips(server: Bool = true) -> RipsStore {
        let rips = RipsStore(ripsBase: ripsBase, session: URLSession(configuration: stubConfig()))
        if server {
            let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
            settings.ripServerURL = "https://server.test"
            settings.ripToken = ""
            rips.settings = settings
        }
        return rips
    }

    /// Serve `entries` as the manifest and load it into `rips`.
    private func seedManifest(_ rips: RipsStore, ids: [String]) async {
        let entries = ids.map { "\"\($0)\":{\"key\":\"rips/\($0).mp3\",\"source\":\"digital\",\"durationMs\":12000}" }
        StreamStubURLProtocol.manifestBody = Data("{\(entries.joined(separator: ","))}".utf8)
        await rips.refreshManifest()
    }

    private func wait(timeout: TimeInterval = 10, until predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func load(_ engine: MixEngine, _ id: String, on deck: MixEngine.Deck = .a, lengthMs: Int? = 12_000) {
        engine.load(songId: id, title: "T-\(id)", artist: "A", bpm: 120, camelot: "8A", key: nil,
                    albumId: nil, lengthMs: lengthMs, on: deck)
    }

    // MARK: 1 — pure frontier math

    func testBytesPerSecondTrustsOnlyAFullLengthHeader() {
        // 12 s at 44.1 kHz whose file is 384 KB: a header claiming the full 12 s ⇒ 32 KB/s.
        let bps = MixEngine.streamBytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: 384_000)
        XCTAssertEqual(bps ?? -1, 32_000, accuracy: 1)
        // A length that couldn't hold the whole object even at 320 kbps is a PARTIAL-derived
        // estimate (no Xing header) — unknowable mid-flight ⇒ nil (play once complete).
        XCTAssertNil(MixEngine.streamBytesPerSecond(totalFrames: 44_100, sampleRate: 44_100, expectedBytes: 384_000))
        // No Content-Length: the 256 kbps house rate.
        XCTAssertEqual(MixEngine.streamBytesPerSecond(totalFrames: 529_200, sampleRate: 44_100, expectedBytes: nil),
                       CollectionMixDownloader.bytesPerPlaybackSecond)
    }

    func testPlayableFramesSubtractTheTornFrameMarginAndNeverPrecedeTheWindow() {
        // 160 000 bytes at 32 000 B/s = 5 s; minus the 1.5 s margin = 3.5 s of frames.
        XCTAssertEqual(MixEngine.streamPlayableFrames(bytes: 160_000, bytesPerSecond: 32_000,
                                                      sampleRate: 44_100, startFrame: 0),
                       AVAudioFramePosition(3.5 * 44_100))
        // An analog window starting at 60 s: bytes short of it schedule nothing.
        XCTAssertEqual(MixEngine.streamPlayableFrames(bytes: 160_000, bytesPerSecond: 32_000,
                                                      sampleRate: 44_100, startFrame: 60 * 44_100),
                       60 * 44_100)
        // Headerless ⇒ nothing until complete.
        XCTAssertEqual(MixEngine.streamPlayableFrames(bytes: 160_000, bytesPerSecond: nil,
                                                      sampleRate: 44_100, startFrame: 0), 0)
    }

    // MARK: 2 — engine lifecycle over a growing real mp3

    /// The deck commits the track IMMEDIATELY (so `loadAuto` succeeds), holds its playhead while
    /// the first bytes are too few, attaches + schedules once there's runway, and becomes an
    /// ordinary file deck on completion. Every step writes the file the way the sink does.
    func testStreamingDeckHoldsThenAttachesThenCompletes() async throws {
        let data = try fixture
        let rips = makeRips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: stubConfig())
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        let file = tempFile()
        let total = Int64(data.count)

        // ~0.4 s of audio on disk — under the 1.5 s margin + 2 s start runway.
        try data.prefix(12_000).write(to: file)
        loader.injectStreamForTesting(songId: "st", file: file, bytes: 12_000, expected: total)
        load(engine, "st")
        XCTAssertEqual(engine.loaded(.a)?.songId, "st", "the track takes the deck at once — the queue never waits")
        XCTAssertTrue(engine.isStreaming(.a))
        XCTAssertFalse(engine.fileScheduledForTesting(.a), "held: nothing schedulable yet")
        XCTAssertTrue(engine.isBuffering(.a), "the deck shows Buffering… while it waits for audio")
        XCTAssertEqual(engine.duration(.a), 12, accuracy: 0.01, "catalog length is the provisional duration")

        // Half the file: attach + schedule from 0:00.
        let half = data.count / 2
        try data.prefix(half).write(to: file)
        loader.injectStreamForTesting(songId: "st", file: file, bytes: Int64(half), expected: total)
        XCTAssertTrue(engine.fileScheduledForTesting(.a), "runway arrived — the deck is scheduled")
        XCTAssertFalse(engine.isBuffering(.a), "the indicator clears the moment it can play")
        XCTAssertEqual(engine.duration(.a), 12, accuracy: 0.05, "real window from the header")
        XCTAssertTrue(engine.isStreaming(.a))

        // Complete: the deck stops being a stream deck.
        try data.write(to: file)
        loader.injectStreamForTesting(songId: "st", file: file, bytes: total, expected: total, finished: true)
        XCTAssertFalse(engine.isStreaming(.a), "complete ⇒ an ordinary file deck")
        XCTAssertFalse(engine.isBuffering(.a))
        XCTAssertEqual(engine.loaded(.a)?.songId, "st")
        engine.teardown()
    }

    /// Seeking past the downloaded frontier HOLDS at the target; the bytes arriving resume the
    /// deck exactly there (not from the frontier, not from 0:00).
    func testSeekPastFrontierHoldsAtTargetUntilBytesArrive() async throws {
        let data = try fixture
        let rips = makeRips()
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: stubConfig())
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        let file = tempFile()
        let total = Int64(data.count)

        let third = data.count / 3              // ~4 s on disk ⇒ ~2.5 s schedulable
        try data.prefix(third).write(to: file)
        loader.injectStreamForTesting(songId: "sk", file: file, bytes: Int64(third), expected: total)
        load(engine, "sk")
        XCTAssertTrue(engine.fileScheduledForTesting(.a))

        engine.seek(.a, toSeconds: 9)
        XCTAssertEqual(engine.position(.a), 9, accuracy: 0.001, "the playhead holds AT the target")
        XCTAssertFalse(engine.fileScheduledForTesting(.a), "nothing past the frontier to schedule")
        XCTAssertTrue(engine.isBuffering(.a), "a seek past the download shows Buffering…")

        try data.write(to: file)
        loader.injectStreamForTesting(songId: "sk", file: file, bytes: total, expected: total, finished: true)
        XCTAssertTrue(engine.fileScheduledForTesting(.a), "bytes arrived — resumed")
        XCTAssertEqual(engine.position(.a), 9, accuracy: 0.001, "resumed at the held target")
        XCTAssertFalse(engine.isBuffering(.a))
        engine.teardown()
    }

    /// A stream that dies before any audio drops the track (a deck never sits on silence), and
    /// the cooldown makes `canStream` refuse it — so the auto machine's preload re-check drops
    /// the song instead of re-opening a dead stream every tick.
    func testStreamFailureBeforeAudioEjectsTheDeckAndCoolsDown() async throws {
        let rips = makeRips()
        await seedManifest(rips, ids: ["dead", "other"])
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: stubConfig())
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        StreamStubURLProtocol.statusByPath["/rips/presign"] = 500

        XCTAssertTrue(engine.canStream("dead"))
        load(engine, "dead")
        XCTAssertEqual(engine.loaded(.a)?.songId, "dead")
        await wait { engine.loaded(.a) == nil }
        XCTAssertNil(engine.loaded(.a), "presign failed twice ⇒ the deck is emptied")
        XCTAssertFalse(engine.isBuffering(.a), "an emptied deck never shows a stale Buffering…")
        XCTAssertFalse(engine.canStream("dead"), "cooling down — not re-opened")
        XCTAssertFalse(engine.canStream("other"),
                       "the rip server isn't answering — NO new streams for a while, so an offline/server-down mix runs on what's on disk")
        engine.teardown()
    }

    // MARK: 3 — end to end through the loader (stub server)

    /// presign → bytes in chunks → the deck plays while they land → the finished stream is
    /// ADOPTED as an ordinary `.ready` burn (fanning out `onAnyBurnFinalized`), so the song is on
    /// disk exactly as if the collection lane had fetched it.
    func testEndToEndStreamPlaysAndIsAdoptedAsABurn() async throws {
        let data = try fixture
        let rips = makeRips()
        await seedManifest(rips, ids: ["e2e"])
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: stubConfig())
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        var finalized: [String] = []
        burns.onAnyBurnFinalized = { id, _ in finalized.append(id) }
        StreamStubURLProtocol.bodyByPath["/rips/presign"] = Data(#"{"url":"https://rips.test/rips/e2e.mp3"}"#.utf8)
        StreamStubURLProtocol.bodyByPath["/rips/e2e.mp3"] = data
        StreamStubURLProtocol.chunkBytes = 32_768
        StreamStubURLProtocol.chunkDelayMs = 60

        XCTAssertNil(burns.localURL(forSong: "e2e"), "not downloaded")
        XCTAssertTrue(engine.canStream("e2e"))
        load(engine, "e2e")
        XCTAssertEqual(engine.loaded(.a)?.songId, "e2e")
        engine.play(.a)

        await wait { engine.fileScheduledForTesting(.a) }
        XCTAssertTrue(engine.isStreaming(.a), "started BEFORE the download finished")
        await wait { !engine.isStreaming(.a) }
        XCTAssertFalse(engine.isStreaming(.a), "download completed")
        XCTAssertEqual(finalized, ["e2e"], "adoption fans out like a burn landing")
        let burned = try XCTUnwrap(burns.localURL(forSong: "e2e"), "the stream IS the burn now")
        XCTAssertEqual(try Data(contentsOf: burned), data, "byte-identical to the object")
        XCTAssertEqual(engine.loaded(.a)?.songId, "e2e")
        engine.teardown()
    }

    /// A network drop mid-body resumes with a Range request from the bytes already on disk.
    func testDroppedConnectionResumesWithRange() async throws {
        let data = try fixture
        let rips = makeRips()
        await seedManifest(rips, ids: ["rng"])
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: stubConfig())
        StreamStubURLProtocol.bodyByPath["/rips/presign"] = Data(#"{"url":"https://rips.test/rips/rng.mp3"}"#.utf8)
        StreamStubURLProtocol.bodyByPath["/rips/rng.mp3"] = data
        StreamStubURLProtocol.dropAfterBytesOnce["/rips/rng.mp3"] = 100_000

        let s = try XCTUnwrap(loader.open("rng", title: "T", artist: "A"))
        await wait { s.isComplete || s.failed }
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(StreamStubURLProtocol.rangeHeaders["/rips/rng.mp3"], ["bytes=100000-"],
                       "requests=\(StreamStubURLProtocol.requests) failed=\(s.failed) bytes=\(s.bytesReceived)")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(burns.localURL(forSong: "rng"))), data)
    }

    // MARK: 4 — downloader: play order + streamed songs left to their stream

    /// The lane fetches what the running mix will PLAY next (live slot onward) — a true shuffle's
    /// order, not collection order — and skips a song a deck is streaming.
    func testDownloaderFetchesInPlayOrderAndSkipsStreamingSongs() async throws {
        let data = try fixture
        let rips = makeRips()
        let ids = ["a1", "a2", "b1", "b2"]
        await seedManifest(rips, ids: ids)
        let burns = try MixBurnFixture.burnStore(ids: [], rips: rips)
        let engine = MixEngine(burns: burns)
        let loader = MixStreamLoader(rips: rips, burns: burns, configuration: stubConfig())
        loader.onProgress = { [weak engine] in engine?.streamProgressed($0) }
        engine.streamer = loader
        // Two decks' worth of streams already "in flight" (the deck streams own these).
        let fa = tempFile("b2"), fb = tempFile("a1")
        try data.prefix(200_000).write(to: fa); try data.prefix(200_000).write(to: fb)
        loader.injectStreamForTesting(songId: "b2", file: fa, bytes: 200_000, expected: Int64(data.count))
        loader.injectStreamForTesting(songId: "a1", file: fb, bytes: 200_000, expected: Int64(data.count))

        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: nil)
        d.resolveRipIds = { _ in ids }
        d.resolveLoadables = { _ in [] }
        d.songLengthSeconds = { _ in 12 }
        d.songTitleArtist = { (title: $0, artist: "A") }
        StreamStubURLProtocol.statusByPath["/rips/a2.mp3"] = 404     // keep the lane from finishing
        StreamStubURLProtocol.statusByPath["/rips/b1.mp3"] = 404

        // The mix plays b2, a1, b1, a2 (a shuffled union).
        let order = ["b2", "a1", "b1", "a2"]
        engine.startAutoMix(order.map {
            .init(loadable: MixLoadable(songId: $0, title: $0, artist: "A", bpm: 120, camelot: "8A",
                                        key: nil, albumId: nil, lengthMs: 12_000), durationMs: 12_000)
        }, shuffled: false, lead: 4, fade: 1, label: "mix")
        XCTAssertEqual(engine.autoUpcomingSongIds, order)
        XCTAssertEqual(engine.loaded(.a)?.songId, "b2", "the queue head streams onto deck A at once")
        XCTAssertEqual(engine.loaded(.b)?.songId, "a1", "…and the on-deck next onto B")

        d.begin(source: .pocket("p"))
        XCTAssertEqual(d.nextBurnIdForTesting, "b1",
                       "b2 + a1 are streaming (their stream is their download) — next in PLAY order is b1, not a2")
        d.cancel()
        engine.teardown()
    }
}

// MARK: - Stub server: manifest, presign, and audio bytes delivered in timed chunks (Range-aware)

private final class StreamStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var manifestBody = Data("{}".utf8)
    nonisolated(unsafe) static var bodyByPath: [String: Data] = [:]
    nonisolated(unsafe) static var statusByPath: [String: Int] = [:]
    nonisolated(unsafe) static var chunkBytes = 1 << 20
    nonisolated(unsafe) static var chunkDelayMs = 0
    nonisolated(unsafe) static var dropAfterBytesOnce: [String: Int] = [:]
    nonisolated(unsafe) static var rangeHeaders: [String: [String]] = [:]
    nonisolated(unsafe) static var requests: [String: Int] = [:]
    private static let lock = NSLock()
    private var stopped = false

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        manifestBody = Data("{}".utf8)
        bodyByPath = [:]
        statusByPath = [:]
        chunkBytes = 1 << 20
        chunkDelayMs = 0
        dropAfterBytesOnce = [:]
        rangeHeaders = [:]
        requests = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped = true }

    override func startLoading() {
        let url = request.url!
        let path = url.path
        Self.lock.lock()
        let status = Self.statusByPath[path] ?? 200
        var body = path.hasSuffix("manifest.json") ? Self.manifestBody : (Self.bodyByPath[path] ?? Data())
        let range = request.value(forHTTPHeaderField: "Range")
        Self.requests[path, default: 0] += 1
        if let range { Self.rangeHeaders[path, default: []].append(range) }
        let dropAt = range == nil ? Self.dropAfterBytesOnce.removeValue(forKey: path) : nil
        let chunk = Self.chunkBytes, delay = Self.chunkDelayMs
        Self.lock.unlock()

        let total = body.count
        var offset = 0
        if let range, range.hasPrefix("bytes="), let from = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            offset = from
            body = body.subdata(in: from..<total)
        }
        var headers = ["Content-Length": "\(body.count)"]
        if range != nil { headers["Content-Range"] = "bytes \(offset)-\(total - 1)/\(total)" }
        let code = status == 200 && range != nil ? 206 : status
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard (200..<300).contains(code) else { client?.urlProtocolDidFinishLoading(self); return }

        let client = self.client
        DispatchQueue.global().async { [self] in
            var sent = 0
            while sent < body.count {
                if self.stopped { return }
                let n = min(chunk, body.count - sent)
                if let dropAt, sent + n > dropAt {
                    client?.urlProtocol(self, didLoad: body.subdata(in: sent..<dropAt))
                    Thread.sleep(forTimeInterval: 0.2)   // the bytes reach the delegate before the stall
                    // .timedOut, not .networkConnectionLost: URLSession silently re-sends a GET on a lost connection.
                    client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                    return
                }
                client?.urlProtocol(self, didLoad: body.subdata(in: sent..<(sent + n)))
                sent += n
                if delay > 0 { Thread.sleep(forTimeInterval: Double(delay) / 1000) }
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
