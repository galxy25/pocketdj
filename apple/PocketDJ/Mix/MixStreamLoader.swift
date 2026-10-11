import Foundation
import Network

/// STREAMING MODE for the Mix decks: pull a song's durable mp3 from the rip bucket into a local
/// file BYTE BY BYTE, so a deck can start playing it seconds after it's asked for instead of
/// waiting for a whole burn to land. The engine plays the growing file directly (see
/// `MixEngine.loadStreaming` — an `AVAudioFile` opened on a partial LAME mp3 reports the FULL
/// length from its Xing header and decodes exactly the frames whose bytes are present, and
/// segments chained from successive opens render bit-identical to one segment).
///
/// A completed stream IS a download: when its bytes are the song's burn file (digital per-song
/// mp3, or an analog album side) it is ADOPTED into `BurnStore` as a normal `.ready` burn —
/// `adoptStreamedFile` fires `onAnyBurnFinalized`, so the collection downloader counts it and the
/// progress bar moves exactly as if its own lane had fetched it. An analog per-song CUT stream is
/// played but not adopted (the burn ledger keys analog songs by the album side; the downloader
/// lane still burns side + cut later).
///
/// Every stream runs to completion once started — a skipped song keeps downloading, because the
/// collection run would have to fetch it anyway — capped at `maxConcurrent` live transfers (the
/// oldest stream no deck is playing is cancelled to make room). A stream that fails after
/// `maxRetries` Range-resumes is remembered for `failureCooldown` so the auto machine's
/// preload-retry can't hammer a dead song every tick; `canStream` refuses it meanwhile.
///
/// OFFLINE SAFETY: `canStream` is also false while the device has no network path
/// (`NWPathMonitor`) and for `serverDownCooldown` after a presign/HTTP failure (the rip server is
/// a Tailscale box that can be unreachable while the internet is fine) — so the resolvers stop
/// admitting undownloaded songs and an offline mix runs on what's on disk, exactly as before
/// streaming existed, instead of holding a deck on a presign timeout per track.
@MainActor
final class MixStreamLoader {

    /// One song's in-flight (or finished) stream. Read by the engine on every progress event.
    final class Stream {
        let songId: String
        /// The local file the bytes are written to (Caches/mixstream). Moves into the burn folder
        /// on adoption — `finalURL` then names its new home.
        let fileURL: URL
        let title: String
        let artist: String
        /// The response headers have arrived: `isCut`/`startMs`/`expectedBytes` are final.
        fileprivate(set) var resolved = false
        /// The bytes are the analog per-song cut (plays from 0:00; no window).
        fileprivate(set) var isCut = false
        /// Analog album-side stream: the song's offset into the side (nil for digital / cut).
        fileprivate(set) var startMs: Int?
        fileprivate(set) var bytesReceived: Int64 = 0
        /// Content-Length of the whole object (nil when the server didn't send one).
        fileprivate(set) var expectedBytes: Int64?
        fileprivate(set) var isComplete = false
        fileprivate(set) var failed = false
        /// The complete file's location: the adopted burn file, or `fileURL` when not adopted.
        fileprivate(set) var finalURL: URL?
        /// The complete file was adopted into the burn folder (`finalURL` is the burn file).
        var adopted: Bool { finalURL != nil && finalURL != fileURL }
        /// The bytes are the song's BURN audio (digital mp3 / analog side) → adopt on completion.
        fileprivate var adoptable = false
        fileprivate var taskId: Int?
        fileprivate var retries = 0
        fileprivate var startedAt = Date()
        /// Fallback source when the analog cut 404s/403s: the presigned album side.
        fileprivate var sideFallback: (() async -> URL?)?

        init(songId: String, fileURL: URL, title: String, artist: String) {
            self.songId = songId
            self.fileURL = fileURL
            self.title = title
            self.artist = artist
        }
    }

    // MARK: Tunables

    static var maxConcurrent = 3
    static var maxRetries = 3
    static var failureCooldown: TimeInterval = 120
    static var serverDownCooldown: TimeInterval = 60

    // MARK: Hooks

    /// Bytes landed / headers resolved / completed / failed for `songId` (main actor). The engine
    /// pumps every deck streaming that song.
    var onProgress: ((String) -> Void)?
    /// Raw byte deltas (the collection downloader's throughput window — streamed bytes are
    /// download bytes). Single subscriber, installed/removed with the downloader's hooks.
    var onBytes: ((String, Int64) -> Void)?
    /// A stream finished with no file (after retries). The downloader re-queues the song.
    var onFailed: ((String) -> Void)?
    /// The song ids some deck is playing right now — never cancelled to make room.
    var pinnedIds: (() -> Set<String>)?

    // MARK: State

    private(set) var streams: [String: Stream] = [:]
    private var recentFailures: [String: Date] = [:]
    /// The device has a usable network path (NWPathMonitor; optimistic until the first update).
    private(set) var networkAvailable = true
    /// Presign/HTTP to the rip infrastructure failed recently — don't start new streams until.
    private var serverDownUntil: Date?
    private let pathMonitor = NWPathMonitor()
    private var byTask: [Int: String] = [:]

    private let rips: RipsStore
    private let burns: BurnStore
    private let dir: URL
    private let sink = StreamSink()
    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: sink, delegateQueue: sink.queue)
    }()

    /// `configuration` is a test seam (stub `URLProtocol`s); production uses the default.
    init(rips: RipsStore, burns: BurnStore, directory: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        self.rips = rips
        self.burns = burns
        let cfg = configuration ?? .default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        self.configuration = cfg
        let base = directory ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                                 ?? FileManager.default.temporaryDirectory).appendingPathComponent("mixstream", isDirectory: true)
        self.dir = base
        // Partials from a previous launch are never resumed (a restored deck re-streams via the
        // normal load path) — sweep them so the cache can't grow across launches.
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // DispatchQueue.main (not a Task per event): strictly FIFO, so response → bytes → finished
        // reach `handle` in the order the delegate saw them.
        sink.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkAvailable = ok } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "pdj.mixstream.path"))
    }

    deinit { pathMonitor.cancel() }

    // MARK: Queries

    /// Can `songId` start streaming right now? It must be ripped (in the manifest), there must be
    /// a rip server to presign against, and it must not have failed within the cooldown.
    func canStream(_ songId: String) -> Bool {
        if streams[songId].map({ !$0.failed }) == true { return true }
        guard networkAvailable, rips.hasServer, rips.manifest[songId] != nil else { return false }
        if let until = serverDownUntil, Date() < until { return false }
        if let t = recentFailures[songId], Date().timeIntervalSince(t) < Self.failureCooldown { return false }
        return true
    }

    func stream(for songId: String) -> Stream? { streams[songId] }

    /// A transfer for `songId` is live (started, not complete, not failed).
    func isStreaming(_ songId: String) -> Bool {
        guard let s = streams[songId] else { return false }
        return !s.isComplete && !s.failed
    }

    // MARK: Open

    /// Begin (or join) the stream for `songId`. Returns nil when it can't stream. A finished
    /// stream whose file still exists is returned as-is (the deck plays it like a burn).
    @discardableResult
    func open(_ songId: String, title: String, artist: String) -> Stream? {
        if let s = streams[songId], !s.failed {
            let path = (s.finalURL ?? s.fileURL).path
            if !s.isComplete || FileManager.default.fileExists(atPath: path) { return s }
        }
        guard canStream(songId), let entry = rips.manifest[songId] else { return nil }
        makeRoom()
        let file = dir.appendingPathComponent("\(Self.safe(songId))-\(UUID().uuidString.prefix(8)).mp3")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let s = Stream(songId: songId, fileURL: file, title: title, artist: artist)
        streams[songId] = s
        recentFailures[songId] = nil
        // A queued/in-flight BACKGROUND burn of the same file would download it twice — the
        // stream takes over (adoption lands the same `.ready` item the burn would have).
        burns.yieldBackgroundDownload(songId: songId)
        let rips = self.rips
        if entry.source == "analog", let cutKey = entry.cutKey {
            // Prefer the per-song cut — streaming a whole album side to reach one song is the
            // expensive path. The side stays as the fallback if the cut can't be fetched.
            s.isCut = true
            s.sideFallback = { try? await rips.presignedURL(for: songId, ttlSeconds: 21_600) }
            start(s, url: rips.url(forKey: cutKey), offset: 0)
        } else {
            s.adoptable = true
            s.startMs = entry.source == "analog" ? entry.startMs : nil
            Task { [weak self] in
                var url = try? await rips.presignedURL(for: songId, ttlSeconds: 21_600)
                if url == nil { url = try? await rips.presignedURL(for: songId, ttlSeconds: 21_600) }
                guard let self, self.streams[songId] === s else { return }
                guard let url else { self.tripServerDown("presign"); self.fail(s, why: "presign failed"); return }
                self.start(s, url: url, offset: 0)
            }
        }
        DiagLog.shared.telemetry("mixstream", "open \(songId) cut=\(s.isCut ? 1 : 0)")
        return s
    }

    /// Cancel streams (collection run cancelled). Deck-pinned songs are left alone.
    func cancel(songIds: [String]) {
        let pinned = pinnedIds?() ?? []
        for id in songIds where !pinned.contains(id) {
            guard let s = streams[id], !s.isComplete, !s.failed else { continue }
            cancelTransfer(s)
            streams[id] = nil
            try? FileManager.default.removeItem(at: s.fileURL)
        }
    }

    // MARK: Transfer plumbing

    private var sources: [String: URL] = [:]

    private func start(_ s: Stream, url: URL, offset: Int64) {
        sources[s.songId] = url
        var req = URLRequest(url: url)
        // Presigned S3 GETs carry their own auth — never attach the rip bearer (the
        // double-auth 400 that poisoned burns). The public cut URL needs none either.
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: req)
        let id = task.taskIdentifier
        if offset == 0 { try? Data().write(to: s.fileURL) }
        sink.register(task: id, file: s.fileURL, offset: offset)
        byTask[id] = s.songId
        s.taskId = id
        task.resume()
    }

    private func cancelTransfer(_ s: Stream) {
        guard let id = s.taskId else { return }
        byTask[id] = nil
        s.taskId = nil
        sink.cancel(task: id, in: session)
    }

    /// Keep at most `maxConcurrent` live transfers: cancel the OLDEST one no deck is playing.
    private func makeRoom() {
        let live = streams.values.filter { !$0.isComplete && !$0.failed }
        guard live.count >= Self.maxConcurrent else { return }
        let pinned = pinnedIds?() ?? []
        if let victim = live.filter({ !pinned.contains($0.songId) }).min(by: { $0.startedAt < $1.startedAt }) {
            DiagLog.shared.telemetry("mixstream", "evict \(victim.songId) (cap \(Self.maxConcurrent))")
            cancelTransfer(victim)
            streams[victim.songId] = nil
            try? FileManager.default.removeItem(at: victim.fileURL)
            onFailed?(victim.songId)       // back to the downloader lane — it still needs the file
        }
    }

    private func handle(_ event: StreamSink.Event) {
        switch event {
        case let .response(task, status, expected, contentRangeTotal):
            guard let id = byTask[task], let s = streams[id] else { return }
            if !(200..<300).contains(status) {
                cancelTransfer(s)
                if s.isCut, let fallback = s.sideFallback {
                    // The cut isn't fetchable (private-bucket policy / missing object): stream the
                    // album side instead and window the song out of it — same as the burn fallback.
                    s.sideFallback = nil
                    s.isCut = false
                    s.adoptable = true
                    s.startMs = rips.manifest[id]?.startMs
                    DiagLog.shared.telemetry("mixstream", "cut HTTP \(status) \(id) → side fallback")
                    Task { [weak self] in
                        let url = await fallback()
                        guard let self, self.streams[id] === s else { return }
                        guard let url else { self.tripServerDown("presign"); self.fail(s, why: "side presign failed"); return }
                        self.start(s, url: url, offset: 0)
                    }
                } else {
                    tripServerDown("HTTP \(status)")
                    fail(s, why: "HTTP \(status)")
                }
                return
            }
            serverDownUntil = nil
            if status == 200, s.bytesReceived > 0 {
                // Asked for a Range, got the whole object: the sink restarted the file at 0.
                s.bytesReceived = 0
            }
            s.expectedBytes = contentRangeTotal ?? (expected > 0 ? expected + (status == 206 ? s.bytesReceived : 0) : nil)
            s.resolved = true
            onProgress?(id)
        case let .bytes(task, total, delta):
            guard let id = byTask[task], let s = streams[id] else { return }
            s.bytesReceived = total
            onBytes?(id, delta)
            onProgress?(id)
        case let .finished(task, total, error):
            guard let id = byTask[task], let s = streams[id] else { return }
            byTask[task] = nil
            s.taskId = nil
            s.bytesReceived = total
            if let error {
                if (error as NSError).code == NSURLErrorCancelled { return }
                if s.retries < Self.maxRetries, let url = sources[id] {
                    s.retries += 1
                    DiagLog.shared.telemetry("mixstream", "resume \(id) at \(total) try=\(s.retries) err=\((error as NSError).code)")
                    start(s, url: url, offset: total)
                } else {
                    tripServerDown("network")
                    fail(s, why: "network \((error as NSError).domain)#\((error as NSError).code)")
                }
                return
            }
            if let expected = s.expectedBytes, total < expected {
                fail(s, why: "short body \(total)/\(expected)")
                return
            }
            complete(s)
        }
    }

    private func complete(_ s: Stream) {
        s.isComplete = true
        s.finalURL = s.fileURL
        // Adopted: the file now lives in the burn folder (each deck re-acquires its own held
        // scope through `BurnStore.localURLForPlayback` when it swaps over).
        if s.adoptable,
           let adopted = burns.adoptStreamedFile(songId: s.songId, title: s.title, artist: s.artist, from: s.fileURL) {
            s.finalURL = adopted
        }
        let secs = Date().timeIntervalSince(s.startedAt)
        DiagLog.shared.telemetry("mixstream", "done \(s.songId) bytes=\(s.bytesReceived) secs=\(String(format: "%.1f", secs)) adopted=\(s.finalURL != s.fileURL ? 1 : 0)")
        onProgress?(s.songId)
    }

    private func fail(_ s: Stream, why: String) {
        cancelTransfer(s)
        s.failed = true
        recentFailures[s.songId] = Date()
        DiagLog.shared.log("error", "mixstream FAIL \(s.songId): \(why) bytes=\(s.bytesReceived)")
        onProgress?(s.songId)
        onFailed?(s.songId)
        // Keep a failed stream that already has bytes: a deck may be playing its prefix. Drop
        // the record so a later open (after the cooldown) starts clean.
        streams[s.songId] = nil
    }

    /// The rip infrastructure isn't answering: stop admitting new streams for a while.
    private func tripServerDown(_ why: String) {
        serverDownUntil = Date().addingTimeInterval(Self.serverDownCooldown)
        DiagLog.shared.log("warn", "mixstream server down (\(why)) — streaming paused \(Int(Self.serverDownCooldown))s")
    }

    private static func safe(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "_" })
    }

    // MARK: Test seams

    /// Script a stream without a network: registers `songId` with a pre-written file and the
    /// given progress. `finished` completes it (and adopts, when `adoptable`).
    @discardableResult
    func injectStreamForTesting(songId: String, file: URL, bytes: Int64, expected: Int64?,
                                startMs: Int? = nil, isCut: Bool = false, adoptable: Bool = false,
                                finished: Bool = false) -> Stream {
        let s = streams[songId] ?? Stream(songId: songId, fileURL: file, title: songId, artist: "")
        streams[songId] = s
        s.resolved = true
        s.bytesReceived = bytes
        s.expectedBytes = expected
        s.startMs = startMs
        s.isCut = isCut
        s.adoptable = adoptable
        if finished { complete(s) } else { onProgress?(songId) }
        return s
    }
    func failStreamForTesting(_ songId: String) {
        guard let s = streams[songId] else { return }
        fail(s, why: "test")
    }
}

/// The URLSession delegate: writes each task's bytes straight to its file on a private serial
/// queue and reports throttled progress. Nonisolated by construction — the main-actor loader only
/// ever sees `Event`s.
private final class StreamSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event {
        case response(task: Int, status: Int, expected: Int64, contentRangeTotal: Int64?)
        case bytes(task: Int, total: Int64, delta: Int64)
        case finished(task: Int, total: Int64, error: Error?)
    }

    let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "pdj.mixstream"
        return q
    }()
    var onEvent: (@Sendable (Event) -> Void)?

    private struct Sink {
        let file: URL
        var handle: FileHandle?
        var total: Int64
        var unreported: Int64 = 0
        var lastReport = Date.distantPast
    }
    private let lock = NSLock()
    private var sinks: [Int: Sink] = [:]

    func register(task: Int, file: URL, offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        sinks[task] = Sink(file: file, handle: nil, total: offset)
    }

    func cancel(task: Int, in session: URLSession) {
        lock.lock()
        let sink = sinks.removeValue(forKey: task)
        lock.unlock()
        try? sink?.handle?.close()
        session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == task }?.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        var rangeTotal: Int64?
        if let cr = http?.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") {
            rangeTotal = Int64(cr[cr.index(after: slash)...])
        }
        lock.lock()
        if var s = sinks[dataTask.taskIdentifier], (200..<300).contains(status) {
            if status == 200 { s.total = 0 }          // full body: (re)write from byte 0
            if let h = try? FileHandle(forWritingTo: s.file) {
                if status == 200 { try? h.truncate(atOffset: 0) } else { _ = try? h.seekToEnd() }
                s.handle = h
            }
            sinks[dataTask.taskIdentifier] = s
        }
        lock.unlock()
        onEvent?(.response(task: dataTask.taskIdentifier, status: status,
                           expected: response.expectedContentLength, contentRangeTotal: rangeTotal))
        completionHandler((200..<300).contains(status) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var s = sinks[dataTask.taskIdentifier], let h = s.handle else { lock.unlock(); return }
        do { try h.write(contentsOf: data) } catch { lock.unlock(); dataTask.cancel(); return }
        s.total += Int64(data.count)
        s.unreported += Int64(data.count)
        let now = Date()
        // ~4 Hz or every 256 KB — enough for the deck to extend its schedule promptly without
        // flooding the main actor.
        let report = now.timeIntervalSince(s.lastReport) >= 0.25 || s.unreported >= 262_144
        var delta: Int64 = 0
        if report { delta = s.unreported; s.unreported = 0; s.lastReport = now }
        sinks[dataTask.taskIdentifier] = s
        let total = s.total
        lock.unlock()
        if report { onEvent?(.bytes(task: dataTask.taskIdentifier, total: total, delta: delta)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let s = sinks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let s else { return }                  // cancelled through `cancel(task:)`
        try? s.handle?.synchronize()
        try? s.handle?.close()
        if s.unreported > 0 { onEvent?(.bytes(task: task.taskIdentifier, total: s.total, delta: s.unreported)) }
        onEvent?(.finished(task: task.taskIdentifier, total: s.total, error: error))
    }
}
