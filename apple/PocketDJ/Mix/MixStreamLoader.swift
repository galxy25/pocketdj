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

    /// A song's 4 Demucs stems streaming TOGETHER (the Mix deck's stems-while-streaming lane).
    /// Each part is an ordinary `Stream` keyed `stem:<songId>:<part>` — the same sink, Range
    /// resume and retry plumbing as a song stream. Stems are public objects (no presign), CBR
    /// mp3s WITHOUT a Xing header, so an `AVAudioFile` opened on a partial part reports the
    /// length of the bytes present — the engine reads that (and the byte count) as each part's
    /// frontier. Never adopted mid-flight: once all four land they MOVE into the burn folder as
    /// ordinary burned stems (`BurnStore.adoptStreamedStems`), so the next request is instant.
    final class StemSet {
        let songId: String
        /// Part name (`MixEngine.stemNames`) → its stream.
        let parts: [String: Stream]
        /// The four files now live in the burn folder (`finalURL` of each part names it).
        fileprivate(set) var adopted = false
        init(songId: String, parts: [String: Stream]) { self.songId = songId; self.parts = parts }
        var isComplete: Bool { !parts.isEmpty && parts.values.allSatisfy(\.isComplete) }
        var failed: Bool { parts.values.contains(where: \.failed) }
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
    /// A stem set's bytes landed / it completed (and was adopted) / it failed — the BASE song id
    /// (main actor). Part events never reach `onProgress`/`onFailed`/`onBytes`: the song lanes
    /// (engine pump, collection downloader) only ever see song ids.
    var onStemProgress: ((String) -> Void)?
    /// Further stem-set listeners (the Now Playing DSP streams stems through this same loader;
    /// `onStemProgress` stays the Mix engine's). Keyed so an owner can remove its own.
    private var stemListeners: [UUID: (String) -> Void] = [:]
    @discardableResult
    func addStemListener(_ listener: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        stemListeners[id] = listener
        return id
    }
    func removeStemListener(_ id: UUID) { stemListeners[id] = nil }
    /// Fan a stem-set event out to every listener (base song id).
    private func stemProgressed(_ base: String) {
        onStemProgress?(base)
        for l in stemListeners.values { l(base) }
    }

    // MARK: State

    private(set) var streams: [String: Stream] = [:]
    /// Stem sets by base song id (live, finished or failed — a failed set is dropped on failure).
    private(set) var stemSets: [String: StemSet] = [:]
    /// Who holds each live stem set: one token per ENGINE (`mixStemOwner` for every Mix deck —
    /// the engine de-dups its own decks — `nowPlayingStemOwner` for the Now Playing DSP). A set
    /// two engines joined is cancelled only once BOTH let go: before, Now Playing toggling its
    /// stems off cancelled the transfer a Mix deck was still waiting on (and vice versa), and
    /// since a cancel tells no one, that deck sat on "Loading stems…" for good.
    private var stemOwners: [String: Set<String>] = [:]
    nonisolated static let mixStemOwner = "mix"
    nonisolated static let nowPlayingStemOwner = "nowplaying"
    private var recentStemFailures: [String: Date] = [:]
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
        // A REJECTED token (401/403) is not "server down": the gate holds for the re-probe
        // window, then lets one attempt through; a token change (re-typed / credsync heal)
        // reopens it immediately (`RipsStore.isAuthRejected` keys on the token value).
        if rips.authHoldoff { return false }
        if let t = recentFailures[songId], Date().timeIntervalSince(t) < Self.failureCooldown { return false }
        return true
    }

    /// Is `songId` in the rip manifest (streamable in principle)? A ripped song `canStream`
    /// refuses is only TEMPORARILY unplayable (offline / server cooldown / a recent failure) —
    /// the auto machine defers it instead of dropping it from the queue.
    func isRipped(_ songId: String) -> Bool { rips.manifest[songId] != nil }

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
                if url == nil, !rips.isAuthRejected { url = try? await rips.presignedURL(for: songId, ttlSeconds: 21_600) }
                guard let self, self.streams[songId] === s else { return }
                guard let url else {
                    // 401/403 is a credential fault, not an outage: no "server down" trip (the
                    // auth holdoff gates instead and clears on a token change) — and say so.
                    if rips.isAuthRejected { self.fail(s, why: "presign rejected (401 — token)") }
                    else { self.tripServerDown("presign"); self.fail(s, why: "presign failed") }
                    return
                }
                self.start(s, url: url, offset: 0)
            }
        }
        DiagLog.shared.telemetry("mixstream", "open \(songId) cut=\(s.isCut ? 1 : 0)")
        return s
    }

    // MARK: Stems

    nonisolated static let stemKeyPrefix = "stem:"
    /// The `streams` key of one stem part.
    nonisolated static func stemKey(_ songId: String, _ part: String) -> String { "\(stemKeyPrefix)\(songId):\(part)" }
    /// The base song id of a stem-part key; nil for a song key. Pure.
    nonisolated static func stemSongId(fromKey key: String) -> String? {
        guard key.hasPrefix(stemKeyPrefix) else { return nil }
        let rest = key.dropFirst(stemKeyPrefix.count)
        guard let colon = rest.lastIndex(of: ":") else { return nil }   // part names never hold a colon
        return String(rest[..<colon])
    }

    /// Can `songId`'s stems start streaming? Stemmed in the manifest, a network path, and not
    /// failed within the cooldown. (Public objects — no rip server needed, unlike a song stream.)
    func canStreamStems(_ songId: String) -> Bool {
        if let set = stemSets[songId], !set.failed { return true }
        guard networkAvailable, rips.stemURLs(forSong: songId) != nil else { return false }
        if let t = recentStemFailures[songId], Date().timeIntervalSince(t) < Self.failureCooldown { return false }
        return true
    }

    func stemSet(for songId: String) -> StemSet? { stemSets[songId] }

    /// Begin (or join) streaming `songId`'s 4 stems, all at once (the engine can only switch
    /// once EVERY part has runway, so they must arrive together). Returns nil when it can't.
    @discardableResult
    func openStems(_ songId: String, owner: String = mixStemOwner) -> StemSet? {
        if let set = stemSets[songId], !set.failed {
            let files = set.parts.values.map { ($0.finalURL ?? $0.fileURL).path }
            if !set.isComplete || files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                stemOwners[songId, default: []].insert(owner)
                return set
            }
        }
        guard canStreamStems(songId), let remote = rips.stemURLs(forSong: songId) else { return nil }
        var parts: [String: Stream] = [:]
        var sources: [(Stream, URL)] = []
        for name in MixEngine.stemNames {
            guard let url = remote[name] else { return nil }
            // `.mp3` extension: AVAudioFile picks its decoder from it.
            let file = dir.appendingPathComponent("\(Self.safe(songId))-stem-\(name)-\(UUID().uuidString.prefix(8)).mp3")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let s = Stream(songId: Self.stemKey(songId, name), fileURL: file, title: name, artist: "")
            parts[name] = s
            sources.append((s, url))
        }
        let set = StemSet(songId: songId, parts: parts)
        stemSets[songId] = set
        stemOwners[songId] = [owner]
        recentStemFailures[songId] = nil
        for (s, url) in sources {
            streams[s.songId] = s
            start(s, url: url, offset: 0)     // public object: no presign, no bearer
        }
        DiagLog.shared.telemetry("mixstream", "stems open \(songId)")
        return set
    }

    /// Route an event for `key` to the right listener: a stem part fans out as its base song.
    private func notify(_ key: String) {
        if let base = Self.stemSongId(fromKey: key) { stemProgressed(base) } else { onProgress?(key) }
    }

    /// All four parts landed: MOVE them into the burn folder as ordinary burned stems (a deck's
    /// open `AVAudioFile`s keep reading the same inodes).
    private func adoptStemsIfComplete(_ base: String) {
        guard let set = stemSets[base], set.isComplete, !set.adopted else { return }
        var files: [String: URL] = [:]
        for (name, s) in set.parts { files[name] = s.fileURL }
        guard let moved = burns.adoptStreamedStems(songId: base, files: files) else { return }
        for (name, url) in moved { set.parts[name]?.finalURL = url }
        set.adopted = true
        DiagLog.shared.telemetry("mixstream", "stems done \(base)")
    }

    /// Stop streaming `songId`'s stems — no deck wants them any more (toggled off, track changed,
    /// ejected). Stem sets ride outside the song lane's `maxConcurrent` cap, so an abandoned set
    /// left running would compete with the on-air and next songs' streams for the whole ~32 MB.
    /// A completed set is kept (it's already adopted as burned stems); an incomplete one's files
    /// are swept (a deck still reading leftovers keeps its open handles). `owner` lets go of its
    /// claim; the transfer stops only when no other engine still holds the set.
    func cancelStems(_ songId: String, owner: String = mixStemOwner) {
        stemOwners[songId]?.remove(owner)
        if let others = stemOwners[songId], !others.isEmpty, stemSets[songId]?.isComplete == false {
            DiagLog.shared.telemetry("mixstream", "stems release \(songId) by \(owner) — still held by \(others.sorted())")
            return
        }
        stemOwners[songId] = nil
        guard let set = stemSets[songId], !set.isComplete else { return }
        for p in set.parts.values {
            cancelTransfer(p)
            streams[p.songId] = nil
            sources[p.songId] = nil
            try? FileManager.default.removeItem(at: p.fileURL)
        }
        stemSets[songId] = nil
        DiagLog.shared.telemetry("mixstream", "stems cancel \(songId)")
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
        // Stem parts yield to the song streams a deck is playing (or about to): an on-air deck
        // starved of its own bytes is Buffering… — dead air — while stems are a nice-to-have.
        if Self.stemSongId(fromKey: s.songId) != nil { task.priority = URLSessionTask.lowPriority }
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
        // Stem parts ride their own lane (a set is opened for an on-air deck only, at LOW task
        // priority, and cancelled the moment no deck wants it — `cancelStems`) — never counted
        // against, or evicted for, the song streams' cap.
        let live = streams.values.filter { !$0.isComplete && !$0.failed && Self.stemSongId(fromKey: $0.songId) == nil }
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
                        guard let url else {
                            if self.rips.isAuthRejected { self.fail(s, why: "side presign rejected (401 — token)") }
                            else { self.tripServerDown("presign"); self.fail(s, why: "side presign failed") }
                            return
                        }
                        self.start(s, url: url, offset: 0)
                    }
                } else {
                    if Self.stemSongId(fromKey: id) == nil { tripServerDown("HTTP \(status)") }
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
            notify(id)
        case let .bytes(task, total, delta):
            guard let id = byTask[task], let s = streams[id] else { return }
            s.bytesReceived = total
            if Self.stemSongId(fromKey: id) == nil { onBytes?(id, delta) }
            notify(id)
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
                    if Self.stemSongId(fromKey: id) == nil { tripServerDown("network") }
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
        if let base = Self.stemSongId(fromKey: s.songId) { adoptStemsIfComplete(base) }
        notify(s.songId)
    }

    private func fail(_ s: Stream, why: String) {
        cancelTransfer(s)
        s.failed = true
        DiagLog.shared.log("error", "mixstream FAIL \(s.songId): \(why) bytes=\(s.bytesReceived)")
        if let base = Self.stemSongId(fromKey: s.songId) {
            // One dead part sinks the set (a deck needs all four): stop its siblings, cool the
            // song down, and tell the engine — the deck keeps (or returns to) the full mix.
            recentStemFailures[base] = Date()
            if let set = stemSets[base] {
                for p in set.parts.values where p !== s && !p.isComplete {
                    cancelTransfer(p)
                    streams[p.songId] = nil
                }
                stemSets[base] = nil
            }
            stemOwners[base] = nil
            streams[s.songId] = nil
            stemProgressed(base)
            return
        }
        recentFailures[s.songId] = Date()
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
    /// The rip server stopped answering (a presign/HTTP failure): new streams refused for the cooldown.
    func tripServerDownForTesting() { tripServerDown("test") }
    func failStreamForTesting(_ songId: String) {
        guard let s = streams[songId] else { return }
        fail(s, why: "test")
    }

    /// Script a STEM set without a network: each part's pre-written file + byte count (one
    /// `expected` length for every part). `finished` completes all four (→ adoption).
    @discardableResult
    func injectStemsForTesting(songId: String, files: [String: URL], bytes: [String: Int64],
                               expected: Int64?, finished: Bool = false) -> StemSet {
        let set: StemSet
        if let existing = stemSets[songId] {
            set = existing
        } else {
            var parts: [String: Stream] = [:]
            for (name, url) in files {
                let s = Stream(songId: Self.stemKey(songId, name), fileURL: url, title: name, artist: "")
                parts[name] = s
                streams[s.songId] = s
            }
            set = StemSet(songId: songId, parts: parts)
            stemSets[songId] = set
        }
        for (name, s) in set.parts {
            s.resolved = true
            s.bytesReceived = bytes[name] ?? s.bytesReceived
            s.expectedBytes = expected
        }
        if finished {
            for s in set.parts.values where !s.isComplete { s.isComplete = true; s.finalURL = s.fileURL }
            adoptStemsIfComplete(songId)
        }
        stemProgressed(songId)
        return set
    }
    func failStemsForTesting(_ songId: String) {
        guard let s = stemSets[songId]?.parts.values.first else { return }
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
