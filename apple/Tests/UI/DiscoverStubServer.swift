import Foundation
import Network

/// The import ("rip") server, faked IN PROCESS, inside the XCUITest runner.
///
/// Browse ▸ Discover is a NETWORK surface: every row on it comes from the import server's
/// `/search` proxy, and the album preview's track list comes from `/album-tracks`. A UI test
/// of that path therefore needs a server, and the alternative — a real one on the LAN —
/// makes the test non-hermetic (needs Tailscale, an Apple Music subscription, and whatever
/// the catalog happens to contain today). `DiscoverAlbumPreviewUITests` used to document an
/// out-of-band stub started by the host and passed in `PDJ_STUB_URL`; nothing ever started
/// it, so all three tests died at their first Discover-row gate.
///
/// This listens on 127.0.0.1 with an OS-assigned port, and the test hands that URL to the
/// app through the `PDJ_RIP_SERVER_URL` launch-environment seam (SettingsStore reads it into
/// `ripServerURL`, which is what `RipsStore.serverUrl` returns). Loopback is exempt from ATS,
/// so plain HTTP is fine from the simulator; the runner and the app under test share one
/// network stack, so 127.0.0.1 means the same thing to both.
///
/// Network.framework rather than a socket/runloop server on purpose: `NWListener` services
/// its connections on its own dispatch queue, so it keeps answering while the test thread is
/// parked inside `waitForExistence`.
///
/// WHAT IT SERVES (exactly the endpoints these flows touch, in the shapes `RipsStore`
/// decodes — `DiscoverHit`, `DiscoverAlbumHit`, `AlbumTracksResponse`, `Job`):
///
///   GET  /search?q=…&limit=…            → one song hit  ("Blue in Green" / "Kind of Blue")
///   GET  /search?q=…&entity=album&…     → one album hit ("Kind of Blue", 5 tracks, 1959)
///   GET  /album-tracks?id=268443788     → that album row + its ordered track list
///   POST /rip                           → a QUEUED job for the posted songId
///   GET  /jobs/<jobId>                  → that job, still queued
///   GET  /health                        → a plausible server info row
///   (anything else)                     → 404 with a JSON body naming the missed route
///
/// A rip stays `queued` forever, deliberately. The tests assert that the ＋ ACKNOWLEDGED the
/// add (the row's spinner / the provisional catalog entry), never that a copy landed — and a
/// stub has no audio to hand over, so "queued" is the only honest answer. Reporting `ready`
/// with a made-up URL would send the app off to the real CDN for a manifest that doesn't
/// have the song.
final class DiscoverStubServer {

    /// The fixture, in ONE place. The tests assert against these same constants, so an id
    /// can't drift out of lock-step with the payload that produced it.
    enum Fixture {
        static let albumStoreId = "268443788"
        /// The provisional catalog id the add flow synthesizes (`amrec_album_<collectionId>`).
        static let albumId = "amrec_album_\(albumStoreId)"
        static let albumTitle = "Kind of Blue"
        static let artist = "Miles Davis"
        static let year = 1959

        /// The SONG the Discover search returns — the one the tests ＋Add.
        static let trackStoreId = "1440857781"
        static let trackSongId = "amrec_\(trackStoreId)"
        static let trackTitle = "Blue in Green"
        /// A track of the same album the user does NOT add — the preview must still list it.
        static let otherTrackTitle = "So What"

        struct Track {
            let storeId: String
            let title: String
            let number: Int
            let durationMs: Int
        }

        /// Album order (disc 1), as the real `/album-tracks` returns it: already sorted, so
        /// `album-preview-track-0` is the album's first track.
        static let tracks: [Track] = [
            Track(storeId: "1440857756", title: otherTrackTitle, number: 1, durationMs: 562_000),
            Track(storeId: "1440857779", title: "Freddie Freeloader", number: 2, durationMs: 574_000),
            Track(storeId: trackStoreId, title: trackTitle, number: 3, durationMs: 337_000),
            Track(storeId: "1440857782", title: "All Blues", number: 4, durationMs: 693_000),
            Track(storeId: "1440857783", title: "Flamenco Sketches", number: 5, durationMs: 566_000),
        ]
    }

    enum StubError: Error, CustomStringConvertible {
        case didNotStart(String)
        var description: String {
            switch self {
            case let .didNotStart(why): return "Discover stub server never came up: \(why)"
            }
        }
    }

    private var listener: NWListener
    private let queue = DispatchQueue(label: "pdj.discover-stub", qos: .userInitiated)
    private let lock = NSLock()
    private var log: [String] = []

    /// The port the OS assigned. Valid once `start()` has returned.
    private(set) var port: UInt16 = 0

    /// What to put in `PDJ_RIP_SERVER_URL`.
    var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Every request line served, in order — attach it to a failure when a Discover gate
    /// times out and you need to know whether the app ever asked.
    var served: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    /// Bind + start, and don't return until the listener is ready and its port is known (the
    /// app launches immediately after, and a race here would read as "no Discover hit
    /// rendered — is the stub server up?").
    static func start(timeout: TimeInterval = 10) throws -> DiscoverStubServer {
        try DiscoverStubServer(timeout: timeout)
    }

    private init(timeout: TimeInterval) throws {
        listener = try Self.makeListener(loopbackOnly: true)
        do {
            try run(timeout: timeout)
        } catch {
            // A listener pinned to 127.0.0.1 via `requiredLocalEndpoint` is the tidy bind —
            // unreachable from off-device, and macOS raises no "accept incoming connections?"
            // firewall prompt for it. If that route ever comes up without publishing the port
            // it was assigned, fall back to the plain ephemeral bind rather than failing the
            // test for a detail neither the app nor the assertions care about.
            listener.cancel()
            listener = try Self.makeListener(loopbackOnly: false)
            try run(timeout: timeout)
        }
    }

    private static func makeListener(loopbackOnly: Bool) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard loopbackOnly else { return try NWListener(using: params, on: .any) }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        return try NWListener(using: params)
    }

    private func run(timeout: TimeInterval) throws {
        let ready = DispatchSemaphore(value: 0)
        let failure = Failure()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case let .failed(error): failure.set("\(error)"); ready.signal()
            case let .waiting(error): failure.set("waiting: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            listener.cancel()
            throw StubError.didNotStart(failure.value ?? "timed out after \(Int(timeout))s")
        }
        if let why = failure.value { listener.cancel(); throw StubError.didNotStart(why) }
        guard let assigned = listener.port?.rawValue, assigned != 0 else {
            throw StubError.didNotStart("ready, but no port was assigned")
        }
        port = assigned
    }

    /// The state handler runs on the listener's queue while `run` waits on the test thread.
    private final class Failure {
        private let lock = NSLock()
        private var reason: String?
        func set(_ why: String) { lock.lock(); reason = reason ?? why; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return reason }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// One request per connection (every response says `connection: close`), so this reads
    /// until the head — and any declared body — is complete, answers, and hangs up.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if error != nil { connection.cancel(); return }
            if let request = Request(buffer) {
                let response = self.response(for: request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if isComplete { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    /// Just enough HTTP: the request line, the headers we care about (content-length), and
    /// the body. `nil` while the message is still incomplete.
    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data

        init?(_ raw: Data) {
            let terminator = Data("\r\n\r\n".utf8)
            guard let headEnd = raw.range(of: terminator) else { return nil }
            guard let head = String(data: raw[raw.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            method = parts[0].uppercased()

            var declaredLength = 0
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2, pair[0].lowercased() == "content-length" else { continue }
                declaredLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let available = raw[headEnd.upperBound...]
            guard available.count >= declaredLength else { return nil }   // body still arriving
            body = Data(available.prefix(declaredLength))

            // `URLComponents` splits the target; a bare path parses fine as a relative URL.
            let target = parts[1]
            let components = URLComponents(string: target)
            path = components?.path ?? target
            var items: [String: String] = [:]
            for item in components?.queryItems ?? [] { items[item.name] = item.value ?? "" }
            query = items
        }
    }

    // MARK: - Routes

    private func response(for request: Request) -> Data {
        let params = request.query.map { key, value in "\(key)=\(value)" }.sorted()
        lock.lock()
        log.append("\(request.method) \(request.path)"
                   + (params.isEmpty ? "" : "?" + params.joined(separator: "&")))
        lock.unlock()

        switch (request.method, request.path) {
        case ("GET", "/search"):
            let albums = (request.query["entity"] ?? "").lowercased() == "album"
            return json(200, ["results": albums ? [Self.albumRow] : [Self.songRow]])

        case ("GET", "/album-tracks"):
            // Faithful to the real proxy: only the album we know about expands.
            guard request.query["id"] == Fixture.albumStoreId else {
                return json(200, ["tracks": [[String: Any]]()])
            }
            return json(200, ["album": Self.albumRow, "tracks": Self.trackRows])

        case ("POST", "/rip"):
            let posted = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let songId = (posted?["songId"] as? String) ?? Fixture.trackSongId
            return json(200, Self.job(songId: songId))

        case ("GET", let path) where path.hasPrefix("/jobs/"):
            let jobId = String(path.dropFirst("/jobs/".count)).removingPercentEncoding
                ?? String(path.dropFirst("/jobs/".count))
            return json(200, Self.job(songId: Self.songId(fromJobId: jobId)))

        case ("GET", "/health"):
            return json(200, ["version": 2, "hls": true, "cached": 0,
                              "catalog": ["songs": 0, "albums": 0]])

        default:
            return json(404, ["error": "stub: no route for \(request.method) \(request.path)"])
        }
    }

    // MARK: - Payloads (the shapes RipsStore decodes)

    /// `RipsStore.DiscoverHit`. `albumAppleMusicId` is the load-bearing field: without it the
    /// added song reaches the catalog with no album, and there is no `album-hotlink` to tap.
    /// `year` rides along because the album the ＋ later adds inherits it from this hit (via
    /// the provisional entry → the preview's `AppleMusicAlbumRef`) — that's the "1959" the
    /// album screen must show. No artwork URLs: nothing should reach out to the network.
    private static let songRow: [String: Any] = [
        "appleMusicId": Fixture.trackStoreId,
        "title": Fixture.trackTitle,
        "artist": Fixture.artist,
        "album": Fixture.albumTitle,
        "durationMs": 337_000,
        "songId": Fixture.trackSongId,
        "ripped": false,
        "explicit": false,
        "albumAppleMusicId": Fixture.albumStoreId,
        "trackNumber": 3,
        "discNumber": 1,
        "year": Fixture.year,
    ]

    /// `RipsStore.DiscoverAlbumHit`. `albumId` is REQUIRED by the decoder, and it is the id
    /// the added album carries in the catalog (`album-amrec_album_268443788`). No `url`: a
    /// non-nil one makes the macOS ＋ deep-link into Music.app mid-test.
    private static let albumRow: [String: Any] = [
        "appleMusicId": Fixture.albumStoreId,
        "albumId": Fixture.albumId,
        "title": Fixture.albumTitle,
        "artist": Fixture.artist,
        "trackCount": Fixture.tracks.count,
        "year": Fixture.year,
    ]

    /// `RipsStore.AlbumTrack` rows, in album order — each becomes `amrec_<id>` in the catalog.
    private static let trackRows: [[String: Any]] = Fixture.tracks.map { track -> [String: Any] in
        [
            "id": track.storeId,
            "title": track.title,
            "artist": Fixture.artist,
            "discNumber": 1,
            "trackNumber": track.number,
            "durationMs": track.durationMs,
        ]
    }

    /// `RipsStore.Job`, always queued (see the type comment).
    private static func job(songId: String) -> [String: Any] {
        ["jobId": jobId(forSongId: songId), "songId": songId,
         "phase": "queued", "message": "Queued (stub)"]
    }

    private static func jobId(forSongId songId: String) -> String { "stub-job-\(songId)" }

    private static func songId(fromJobId jobId: String) -> String {
        jobId.hasPrefix("stub-job-") ? String(jobId.dropFirst("stub-job-".count)) : jobId
    }

    // MARK: - Wire format

    private func json(_ status: Int, _ payload: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
        head += "content-type: application/json; charset=utf-8\r\n"
        head += "content-length: \(body.count)\r\n"
        head += "connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
