import Foundation
import Observation

/// Rip-on-demand client — a faithful native port of the PWA's `useRipsStore`.
///
/// Two backends, exactly like the web app:
///   • the PUBLIC S3 rips manifest (`<ripsBase>/rips/manifest.json`) tells us what's
///     already ripped — fetched straight from S3, so it works even with the rip
///     server offline (the server is only needed to CREATE a rip),
///   • the iMac rip server (Tailscale) creates rips on demand and serves a live HLS
///     stream while the capture is still running.
///
/// `play(_:)` resolves a song to a playable URL: a cached song streams its durable S3
/// mp3 instantly; a miss POSTs `/rip`, polls `/jobs/<id>`, and returns the live HLS
/// URL the moment the stream is ready (then keeps polling in the background to swap the
/// manifest to the durable mp3). `download(_:)` resolves the durable mp3 bytes.
@MainActor
@Observable
final class RipsStore {
    /// Per-song rip job phase (mirrors the PWA's `RipPhase`).
    enum Phase: String, Decodable {
        case queued, searching, ripping, streaming, uploading, ready, error
    }

    /// A rip job's progress (the `progress` field of a `/jobs/<id>` view).
    struct Progress: Decodable, Equatable {
        var elapsedMs: Int?
        var totalMs: Int?
        var pct: Int?
        var indeterminate: Bool?
    }

    /// The `/rip` + `/jobs/<id>` response shape (mirrors the PWA's `JobView`).
    struct Job: Decodable, Equatable {
        var jobId: String? = nil
        var songId: String? = nil
        var phase: Phase
        var message: String? = nil
        var url: String? = nil
        var error: String? = nil
        /// Relative path to the live HLS playlist (`/hls/<songId>/index.m3u8`).
        var streamUrl: String? = nil
        var progress: Progress? = nil
    }

    /// A Stemify job's phase (its own lifecycle: rip/cut first if needed, then separate).
    /// Distinct from `Phase` because the server emits `stemming`/`ineligible`, which the rip
    /// Phase enum doesn't model (decoding a stem response with `Phase` would fail).
    enum StemPhase: String, Decodable { case queued, ripping, stemming, ready, error, ineligible }

    /// The `/stemify` + `/jobs/<id>` response shape for a stem job (extra fields ignored).
    struct StemJob: Decodable, Equatable {
        var jobId: String? = nil
        var songId: String? = nil
        var phase: StemPhase
        var error: String? = nil
    }

    /// One public-S3 manifest entry (mirrors the PWA's `ManifestEntry`). Only the
    /// fields the native client uses are modelled; unknown fields are ignored.
    struct ManifestEntry: Decodable, Equatable {
        var key: String
        var ext: String? = nil
        var source: String? = nil
        var startMs: Int? = nil
        var durationMs: Int? = nil
        var bpm: Double? = nil
        var musicalKey: String? = nil
        var camelot: String? = nil
        var waveform: String? = nil
        var analyzed: Bool? = nil
        /// Epoch-ms when this rip completed + uploaded (the server emits `Date.now()`).
        /// Optional for backward-compat with older manifest entries that predate it.
        var rippedAt: Double? = nil
        /// ANALOG only: the per-song CUT chunk (`cuts/<songId>.mp3`) sliced out of the album,
        /// for the burn's individual-track export (DJ software). nil ⇒ album-only (no cut). The
        /// album `key` + `startMs` remain the playback source (cut is burn-only).
        var cutKey: String? = nil
        var cutBytes: Int? = nil
        var cutRippedAt: Double? = nil
        // Beat-grid analysis (the mix-analysis indexer; all optional ⇒ back-compat). Measured on the
        // burned file the deck opens (digital mp3 / analog per-song cut), so `firstDownbeatMs` is
        // relative to the song's 0:00 and `beatGridBpm` is preferred over the catalog BPM for
        // beat-matching. `steady` gates whether single-ratio sync holds; `beatgrid` is the lazy
        // per-beat sidecar key (rips/analysis/<id>.json).
        var firstBeatMs: Int? = nil
        var firstDownbeatMs: Int? = nil
        var beatGridBpm: Double? = nil
        var beatsPerBar: Int? = nil
        var tempoConfidence: Double? = nil
        var tempoVar: Double? = nil
        var steady: Bool? = nil
        var beatgrid: String? = nil
        var analysisVersion: Int? = nil
        // Demucs stem separation (the Stemify indexer; all optional ⇒ back-compat). Per-song S3
        // keys under the PUBLIC rips/ prefix: rips/stems/<songId>/{vocals,drums,bass,other}.<ext>.
        // PER-SONG always: a digital song stems its own `key`; an analog song stems its per-song
        // CUT (`cutKey`), never the album side. Presence of `stemVersion` ⇒ stemmed.
        var stems: Stems? = nil
        var stemModel: String? = nil
        var stemVersion: Int? = nil           // SINGULAR — matches the JS writer (canonical)
        var stemFormat: String? = nil
        var stemmedAt: Double? = nil
        var stemBytes: Int? = nil
    }

    /// The 4 Demucs stem S3 keys (typed; matches `stemURLs`). Stored explicitly so URL
    /// resolution is format-correct (mp3 vs flac) without client-side derivation.
    struct Stems: Decodable, Equatable {
        var vocals: String
        var drums: String
        var bass: String
        var other: String
    }

    /// The "now playing" handoff to the inline player (mirrors the PWA's `NowPlaying`).
    struct NowPlaying: Equatable {
        var songId: String
        var title: String
        var artist: String
        var url: URL
        var live: Bool
        var startMs: Int?
        /// Absolute waveform image URL (nil for a live stream — there's no static art yet).
        var waveform: URL?
    }

    // MARK: Observed state

    /// What's already ripped, keyed by songId (loaded from public S3).
    private(set) var manifest: [String: ManifestEntry] = [:]
    /// Active / last rip job per songId (drives the row's live phase label).
    private(set) var jobs: [String: Job] = [:]
    /// Active / last STEM job per songId (drives the row's Stemify phase label).
    private(set) var stemJobs: [String: StemJob] = [:]
    /// The track the inline player is currently bound to.
    private(set) var nowPlaying: NowPlaying?

    /// Synchronous in-flight guard for the fire-and-forget async rip (Feature 1).
    /// Held from BEFORE the `await` until the POST resolves so back-to-back calls for
    /// the same song (popular-song spam, rapid double-taps) fire at most one POST per
    /// process. The server (manifest skip + inflight join) is the cross-process backstop;
    /// this is best-effort spam reduction at the cheapest point.
    private var requesting: Set<String> = []
    /// Same single-flight guard for fire-and-forget Stemify requests.
    private var requestingStems: Set<String> = []

    // MARK: Config

    private let ripsBase: URL
    private let session: URLSession
    /// Settings supply the rip-server URL + token (set by the app at launch).
    var settings: SettingsStore?

    /// `serverUrl`/`token` resolve from settings, exactly like the PWA reads localStorage.
    var serverUrl: String { (settings?.ripServerURL ?? "").trimmingCharacters(in: .whitespaces).trimmedTrailingSlash }
    var token: String { (settings?.ripToken ?? "").trimmingCharacters(in: .whitespaces) }
    var hasServer: Bool { !serverUrl.isEmpty }
    /// When on, rip requests ask the server to try an Apple Music (cloud) capture with
    /// analog fallback. Sent in the POST body only when true (older servers ignore it).
    var ripFromCloud: Bool { settings?.ripFromCloud ?? false }

    init(ripsBase: URL = Config.ripsBase, session: URLSession = .shared) {
        self.ripsBase = ripsBase
        self.session = session
    }

    private var manifestURL: URL { ripsBase.appendingPathComponent("rips/manifest.json") }

    // MARK: Lifecycle

    /// Load the public manifest (cached songs). Safe to call repeatedly.
    func refreshManifest() async {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            manifest = try JSONDecoder().decode([String: ManifestEntry].self, from: data)
            pruneFinishedStemJobs()
        } catch { /* offline — keep whatever we have */ }
    }

    /// Drop stem-job entries whose song is now stemmed (the collection-stemify batch seeds
    /// per-song `.queued` jobs but never per-row updates them; once the manifest shows the song
    /// stemmed, the stale job must be cleared so the row stops showing "Queued…" forever).
    private func pruneFinishedStemJobs() {
        for id in stemJobs.keys where isStemmed(id) { stemJobs[id] = nil }
    }

    func setManifest(_ m: [String: ManifestEntry]) { manifest = m }   // test seam

    // MARK: Public-URL helpers (pure)

    /// Absolute public-S3 mp3 URL for a cached song (nil if not in the manifest).
    func cachedURL(_ songId: String) -> URL? {
        Self.cachedURL(songId, manifest: manifest, ripsBase: ripsBase)
    }

    /// Pure: the durable mp3 URL for a manifest entry, or nil when absent.
    nonisolated static func cachedURL(_ songId: String, manifest: [String: ManifestEntry], ripsBase: URL) -> URL? {
        guard let e = manifest[songId] else { return nil }
        return ripsBase.appendingPathComponent(e.key)
    }

    /// Pure: the live HLS URL = `<serverUrl><streamPath>?token=<token>` (token omitted
    /// when empty). Mirrors the PWA's `liveUrl` builder.
    nonisolated static func liveURL(serverUrl: String, streamPath: String, token: String) -> URL? {
        let base = serverUrl.trimmedTrailingSlash
        var s = base + streamPath
        if !token.isEmpty {
            let q = token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? token
            s += "?token=\(q)"
        }
        return URL(string: s)
    }

    /// Pure: absolute waveform image URL for a cached entry (nil if none).
    nonisolated static func waveformURL(for entry: ManifestEntry?, ripsBase: URL) -> URL? {
        guard let w = entry?.waveform, !w.isEmpty else { return nil }
        return ripsBase.appendingPathComponent(w)
    }

    // MARK: Stem (Demucs) helpers — read-only ingestion (creation lives on the rip server)

    /// True once a song has been separated into stems (presence of the version stamp).
    func isStemmed(_ songId: String) -> Bool { manifest[songId]?.stemVersion != nil }

    /// Public stem URLs for a song (nil when not stemmed). Built off the same ripsBase as
    /// `cachedURL`, so they resolve server-offline (pure public-S3 reads). Keys are stored
    /// explicitly, so the URL is correct regardless of mp3/flac format.
    func stemURLs(forSong songId: String) -> [String: URL]? {
        Self.stemURLs(for: manifest[songId], ripsBase: ripsBase)
    }
    nonisolated static func stemURLs(for entry: ManifestEntry?, ripsBase: URL) -> [String: URL]? {
        guard let s = entry?.stems else { return nil }
        return ["vocals": ripsBase.appendingPathComponent(s.vocals),
                "drums":  ripsBase.appendingPathComponent(s.drums),
                "bass":   ripsBase.appendingPathComponent(s.bass),
                "other":  ripsBase.appendingPathComponent(s.other)]
    }
    func stemURL(forSong songId: String, _ stem: String) -> URL? { stemURLs(forSong: songId)?[stem] }

    /// True once the indexer has produced a per-beat analysis SIDECAR for the song (the burnable
    /// beat-grid artifact, distinct from the scalar summary mirrored into the manifest entry).
    func hasBeatgridSidecar(_ songId: String) -> Bool { !((manifest[songId]?.beatgrid ?? "").isEmpty) }

    /// Public URL of the per-beat analysis sidecar (`rips/analysis/<songId>.json`), nil when none.
    /// Built off the same public ripsBase as stems/cuts, so it resolves server-offline.
    func beatgridSidecarURL(forSong songId: String) -> URL? {
        guard let key = manifest[songId]?.beatgrid, !key.isEmpty else { return nil }
        return ripsBase.appendingPathComponent(key)
    }

    /// The per-beat analysis sidecar (`rips/analysis/<songId>.json`) the indexer ships to S3 — the
    /// full beat grid beyond the scalar summary in the manifest entry. All fields optional/defaulted
    /// so a partial/older sidecar still decodes. `beatsMs` are ms from the song's 0:00 (the cut for
    /// analog); `downbeatsMs` ⊆ `beatsMs` are the bar starts.
    struct BeatGridSidecar: Decodable, Equatable {
        var beatGridBpm: Double?
        var firstDownbeatMs: Int?
        var steady: Bool?
        var beatsMs: [Int]
        var downbeatsMs: [Int]
        private enum CodingKeys: String, CodingKey { case beatGridBpm, firstDownbeatMs, steady, beatsMs, downbeatsMs }
        init(beatGridBpm: Double? = nil, firstDownbeatMs: Int? = nil, steady: Bool? = nil,
             beatsMs: [Int] = [], downbeatsMs: [Int] = []) {
            self.beatGridBpm = beatGridBpm; self.firstDownbeatMs = firstDownbeatMs; self.steady = steady
            self.beatsMs = beatsMs; self.downbeatsMs = downbeatsMs
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            beatGridBpm = try c.decodeIfPresent(Double.self, forKey: .beatGridBpm)
            firstDownbeatMs = try c.decodeIfPresent(Int.self, forKey: .firstDownbeatMs)
            steady = try c.decodeIfPresent(Bool.self, forKey: .steady)
            beatsMs = try c.decodeIfPresent([Int].self, forKey: .beatsMs) ?? []
            downbeatsMs = try c.decodeIfPresent([Int].self, forKey: .downbeatsMs) ?? []
        }
    }

    // MARK: Errors

    enum RipError: LocalizedError {
        case noServer, ripFailed(Int), didNotStart(String?), serverError(String?), timedOut
        var errorDescription: String? {
            switch self {
            case .noServer:           return "No rip server configured (Settings ▸ Rip server)."
            case .ripFailed(let s):   return "Rip failed (\(s))."
            case .didNotStart(let m): return m ?? "Rip did not start."
            case .serverError(let m): return m ?? "Rip failed."
            case .timedOut:           return "Rip timed out."
            }
        }
    }

    // MARK: Resolve a playable URL

    /// Ensure a song is ripped + return a playable URL. With `allowLive`, resolves as
    /// soon as the live HLS stream is available and keeps polling in the background to
    /// swap the manifest to the durable S3 mp3; without it, waits for the finished mp3.
    @discardableResult
    func ensureURL(_ songId: String, allowLive: Bool) async throws -> URL {
        if let cached = cachedURL(songId) { return cached }
        guard hasServer else { throw RipError.noServer }
        let base = serverUrl, tok = token

        // POST /rip {songId} (creates or joins the single-flight job).
        var post = URLRequest(url: URL(string: "\(base)/rip")!)
        post.httpMethod = "POST"
        // Short connect/request timeout (matches RipServerService.health's 12s) so a CONFIGURED
        // but unreachable rip server (e.g. an asleep Tailscale/home server while on venue wifi)
        // fails in seconds — letting Play-All SKIP an un-burned track promptly rather than
        // stalling on URLSession.shared's 60s default before advancing.
        post.timeoutInterval = 12
        post.setValue("application/json", forHTTPHeaderField: "content-type")
        applyAuth(&post, token: tok)
        let body: [String: Any] = ripFromCloud ? ["songId": songId, "ripFromCloud": true] : ["songId": songId]
        post.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: post)
        guard let http = response as? HTTPURLResponse else { throw RipError.ripFailed(0) }
        guard (200..<300).contains(http.statusCode) else { throw RipError.ripFailed(http.statusCode) }

        var view = try JSONDecoder().decode(Job.self, from: data)
        jobs[songId] = view
        if view.phase == .ready, let u = view.url, let url = URL(string: u) {
            await refreshManifest(); return url
        }
        guard let jobId = view.jobId else { throw RipError.didNotStart(view.error) }
        if allowLive, let stream = view.streamUrl, let live = Self.liveURL(serverUrl: base, streamPath: stream, token: tok) {
            pollToReady(songId: songId, jobId: jobId)
            return live
        }

        // Poll /jobs/<id> until ready (or the live stream appears).
        for _ in 0..<1800 {
            try await Self.sleep1s()
            guard let v = try? await fetchJob(jobId, base: base, token: tok) else { continue }
            view = v
            jobs[songId] = v
            if v.phase == .ready, let u = v.url, let url = URL(string: u) { await refreshManifest(); return url }
            if allowLive, let stream = v.streamUrl,
               let live = Self.liveURL(serverUrl: base, streamPath: stream, token: tok) {
                pollToReady(songId: songId, jobId: jobId); return live
            }
            if v.phase == .error { throw RipError.serverError(v.error) }
        }
        throw RipError.timedOut
    }

    /// After handing back a live URL, keep polling so the manifest swaps to the durable
    /// (seekable + analysed) S3 mp3 for the next play.
    private func pollToReady(songId: String, jobId: String) {
        let base = serverUrl, tok = token
        Task { [weak self] in
            for _ in 0..<1800 {
                try? await Self.sleep(ms: 2000)
                guard let self else { return }
                guard let v = try? await self.fetchJob(jobId, base: base, token: tok) else { continue }
                self.jobs[songId] = v
                if v.phase == .ready, v.url != nil { await self.refreshManifest(); return }
                if v.phase == .error { return }
            }
        }
    }

    private func fetchJob(_ jobId: String, base: String, token: String) async throws -> Job {
        var request = URLRequest(url: URL(string: "\(base)/jobs/\(jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId)")!)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RipError.serverError(nil)
        }
        return try JSONDecoder().decode(Job.self, from: data)
    }

    // MARK: Play / Download

    /// Resolve a song and arm the inline player (cached → S3 mp3; else live HLS).
    /// Returns the resolved `NowPlaying` handoff so the caller can load the shared
    /// `PlayerEngine` directly off this single explicit play — the inline panel must
    /// NOT load the engine in its lifecycle (it recycles in the LazyVStack and would
    /// auto-play / fight a user pause). The caller owns the one-and-only `player.load`.
    @discardableResult
    func play(_ song: (id: String, title: String, artist: String), startMs: Int? = nil) async throws -> NowPlaying {
        let url = try await ensureURL(song.id, allowLive: true)
        let live = url.absoluteString.contains("/hls/")
        let entry = manifest[song.id]
        let resolvedStart = live ? nil : (startMs ?? entry?.startMs)
        let np = NowPlaying(
            songId: song.id, title: song.title, artist: song.artist, url: url, live: live,
            startMs: resolvedStart,
            waveform: live ? nil : Self.waveformURL(for: entry, ripsBase: ripsBase))
        nowPlaying = np
        return np
    }

    /// Resolve a song to its durable mp3 and return the raw bytes. The caller decides
    /// where they go — the row hands these to a `.fileExporter` so the user picks the
    /// save location. If the song isn't ripped yet this kicks off the rip and waits for
    /// the finished mp3 (driving the row's live rip-phase label off `jobs[...]`).
    func downloadData(_ song: (id: String, title: String, artist: String)) async throws -> Data {
        let url = try await ensureURL(song.id, allowLive: false)
        var request = URLRequest(url: url)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RipError.serverError(nil)
        }
        return data
    }

    /// Resolve a song to its durable mp3 and write it to a file the user can keep
    /// (the app's Documents directory). Returns the saved file URL (for share/export).
    @discardableResult
    func download(_ song: (id: String, title: String, artist: String)) async throws -> URL {
        let data = try await downloadData(song)
        let name = Self.downloadFileName(artist: song.artist, title: song.title)
        let dest = try Self.documentsDirectory().appendingPathComponent(name)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    func setNowPlaying(_ n: NowPlaying?) { nowPlaying = n }

    // MARK: Analog cut export (burn-only)

    /// The public URL for a manifest key (e.g. an analog `cutKey` = "cuts/<songId>.mp3").
    func url(forKey key: String) -> URL { ripsBase.appendingPathComponent(key) }

    /// HEAD `url` → its Last-Modified as epoch-ms (nil offline / missing). Drives the burn's
    /// analog-cut auto-repull: re-download when the S3 cut is newer than the device's copy (so a
    /// MANUALLY re-uploaded cut is picked up without any manifest change).
    func remoteLastModifiedMs(_ url: URL) async -> Double? {
        var req = URLRequest(url: url); req.httpMethod = "HEAD"; req.timeoutInterval = 12
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let lm = http.value(forHTTPHeaderField: "Last-Modified"),
              let date = Self.httpDateFormatter.date(from: lm) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    /// GET raw bytes from a public URL (the analog cut chunk). Throws offline / on non-2xx.
    func downloadBytes(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url); req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RipError.serverError(nil)
        }
        return data
    }

    /// RFC-1123 HTTP-date parser for the `Last-Modified` header (fixed POSIX/GMT).
    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    // MARK: Feature 1 — stream-through-ripping (fire-and-forget async rip)

    /// Phases that mean a rip is already in progress for a song (a non-terminal job).
    /// `nonisolated` so the nonisolated `batchStatus(for:)` can read this immutable
    /// constant without a MainActor hop (and to stay clean under the Swift 6 language mode).
    nonisolated private static let inFlightPhases: Set<Phase> = [.queued, .searching, .ripping, .streaming, .uploading]

    /// FIRE-AND-FORGET async rip request (Feature 1). Called the moment a streamable
    /// Apple Music song STARTS playing so the durable rip is likely ready shortly after
    /// the user finishes streaming. NEVER throws (errors are swallowed) and NEVER blocks
    /// playback — the caller fires it in an unawaited `Task`.
    ///
    /// IDEMPOTENT at three layers:
    ///   1. cheap MainActor guard — already cached, an in-flight job, or already requesting
    ///      this process → return immediately (no network),
    ///   2. the synchronous `requesting` Set is inserted BEFORE the `await` so two near-
    ///      simultaneous calls collapse to one POST,
    ///   3. the server's manifest skip + single-flight inflight join is the exact-once
    ///      cross-process / restart backstop.
    func requestRipIfNeeded(_ songId: String) async {
        // (1) cheap guard — cut popular-song spam at the cheapest point, before any network.
        if cachedURL(songId) != nil { return }
        if let phase = jobs[songId]?.phase, Self.inFlightPhases.contains(phase) { return }
        if requesting.contains(songId) { return }
        guard hasServer else { return }

        // (2) reserve synchronously BEFORE the first suspension so the guard is single-flight.
        requesting.insert(songId)
        defer { requesting.remove(songId) }

        let base = serverUrl, tok = token
        do {
            var post = URLRequest(url: URL(string: "\(base)/rip")!)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "content-type")
            applyAuth(&post, token: tok)
            let body: [String: Any] = ripFromCloud ? ["songId": songId, "ripFromCloud": true] : ["songId": songId]
            post.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: post)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let view = try JSONDecoder().decode(Job.self, from: data)
            jobs[songId] = view
        } catch {
            // Fire-and-forget: a failed request must be silent to playback.
        }
    }

    /// Outcome of an explicit, metadata-carrying rip request (`requestRip`).
    enum RipRequestOutcome: Equatable {
        case ready          // already in the S3 manifest — nothing to capture
        case queued         // newly enqueued on the rip server
        case inflight       // joined an in-progress capture for the same resource
        case unknown        // server doesn't know this song (old server / no ad-hoc support)
        case noServer       // no rip server configured
        case failed         // network / decode error
    }

    /// Request a rip for a song the catalog may NOT contain yet — the recognizer "add to
    /// Apple Music + burn" path. Unlike `requestRipIfNeeded` (which posts only `songId`,
    /// so the server must already know the track), this carries `title`/`artist` so the
    /// server can synthesize an ad-hoc catalog row and the digital worker (which captures
    /// by artist+title) can find it. Returns the server's classification so the caller can
    /// decide whether to poll for completion. Idempotent-ish: a cached song short-circuits
    /// to `.ready`.
    @discardableResult
    func requestRip(songId: String, title: String, artist: String,
                    appleMusicId: String? = nil, lengthMs: Int? = nil) async -> RipRequestOutcome {
        if cachedURL(songId) != nil { return .ready }
        guard hasServer else { return .noServer }
        let base = serverUrl, tok = token
        do {
            var post = URLRequest(url: URL(string: "\(base)/rip")!)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "content-type")
            applyAuth(&post, token: tok)
            var body: [String: Any] = ["songId": songId, "title": title, "artist": artist]
            if ripFromCloud { body["ripFromCloud"] = true }
            if let appleMusicId, !appleMusicId.isEmpty { body["appleMusicId"] = appleMusicId }
            if let lengthMs, lengthMs > 0 { body["lengthMs"] = lengthMs }
            post.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: post)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 404 { return .unknown }
            guard (200..<300).contains(http.statusCode) else { return .failed }
            let view = try JSONDecoder().decode(Job.self, from: data)
            if view.phase == .ready { return .ready }
            jobs[songId] = view
            return view.phase == .queued ? .queued : .inflight
        } catch {
            return .failed
        }
    }

    /// Refresh a single song's job from `/jobs/<id>` (used by the recognizer rip→burn poll
    /// so a server-side capture failure short-circuits instead of waiting out the timeout).
    /// Returns the latest phase, or the last-known phase when there's no job/the fetch fails.
    @discardableResult
    func refreshJob(_ songId: String) async -> Phase? {
        guard let jobId = jobs[songId]?.jobId else { return jobs[songId]?.phase }
        guard let v = try? await fetchJob(jobId, base: serverUrl, token: token) else {
            return jobs[songId]?.phase
        }
        jobs[songId] = v
        return v.phase
    }

    // MARK: Feature 2 RIP — batch enqueue a collection to be ripped + uploaded to S3

    /// One song's outcome from a batch rip (mirrors the server's per-song result).
    struct BatchRipItem: Decodable, Equatable {
        var songId: String
        /// "ready" | "queued" | "inflight" | "unknown".
        var status: String
        var jobId: String?
        var url: String?
    }

    /// The aggregate result of a `ripCollection` call — per-song outcomes + counts for the
    /// partial-success UI (next stage).
    struct BatchRipResult: Equatable {
        var results: [BatchRipItem] = []
        var ready = 0, queued = 0, inflight = 0, unknown = 0, total = 0
    }

    /// The `/rip-collection` response envelope.
    private struct BatchRipResponse: Decodable {
        struct Counts: Decodable { var ready = 0; var queued = 0; var inflight = 0; var unknown = 0; var total = 0 }
        var results: [BatchRipItem]
        var counts: Counts
    }

    /// Batch-enqueue every song in a collection to be ripped + uploaded to S3 (Feature 2
    /// RIP), reusing the server's durable queue. Deduplicates `songIds`. Returns per-song
    /// outcomes + counts. If the server is older and 404s `/rip-collection`, falls back to
    /// a per-song loop and synthesizes the counts. Empty input is a no-op (zero counts).
    func ripCollection(_ songIds: [String]) async -> BatchRipResult {
        let ids = orderedUnique(songIds)
        guard !ids.isEmpty else { return BatchRipResult() }
        guard hasServer else { return await ripCollectionFallback(ids) }

        let base = serverUrl, tok = token
        do {
            var post = URLRequest(url: URL(string: "\(base)/rip-collection")!)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "content-type")
            applyAuth(&post, token: tok)
            let body: [String: Any] = ripFromCloud ? ["songIds": ids, "ripFromCloud": true] : ["songIds": ids]
            post.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: post)
            guard let http = response as? HTTPURLResponse else { return await ripCollectionFallback(ids) }
            // Older server without the batch endpoint → fall back to a per-song loop.
            if http.statusCode == 404 { return await ripCollectionFallback(ids) }
            guard (200..<300).contains(http.statusCode) else { return BatchRipResult() }

            let decoded = try JSONDecoder().decode(BatchRipResponse.self, from: data)
            // Record the queued/inflight jobs so the row's phase label updates.
            for item in decoded.results where item.status == "queued" || item.status == "inflight" {
                if let jobId = item.jobId {
                    jobs[item.songId] = Job(jobId: jobId, songId: item.songId, phase: .queued)
                }
            }
            return BatchRipResult(
                results: decoded.results,
                ready: decoded.counts.ready, queued: decoded.counts.queued,
                inflight: decoded.counts.inflight, unknown: decoded.counts.unknown,
                total: decoded.counts.total)
        } catch {
            return await ripCollectionFallback(ids)
        }
    }

    /// Per-song fallback when `/rip-collection` is unavailable: loop `requestRipIfNeeded`
    /// and synthesize counts from what we can observe. Classifies each song by the ACTUAL
    /// job phase the per-song `/rip` returned (queued vs an already-in-flight phase) rather
    /// than labeling everything "queued" off jobId presence — so the counts match the batch
    /// path's ready/queued/inflight/unknown buckets. Best-effort; never throws.
    private func ripCollectionFallback(_ ids: [String]) async -> BatchRipResult {
        var result = BatchRipResult()
        for id in ids {
            if cachedURL(id) != nil {
                result.results.append(BatchRipItem(songId: id, status: "ready", jobId: nil,
                                                   url: cachedURL(id)?.absoluteString))
                result.ready += 1
            } else if hasServer {
                await requestRipIfNeeded(id)
                let job = jobs[id]
                let status = Self.batchStatus(for: job?.phase)
                result.results.append(BatchRipItem(songId: id, status: status, jobId: job?.jobId, url: nil))
                switch status {
                case "ready":    result.ready += 1
                case "queued":   result.queued += 1
                case "inflight": result.inflight += 1
                default:         result.unknown += 1
                }
            } else {
                result.results.append(BatchRipItem(songId: id, status: "unknown", jobId: nil, url: nil))
                result.unknown += 1
            }
            result.total += 1
        }
        return result
    }

    /// One song's outcome from a batch cancel (mirrors the server's per-song result).
    struct CancelItem: Decodable, Equatable {
        var songId: String
        /// "canceled" | "notFound" | "alreadyDone".
        var status: String
    }

    /// The `/rip-cancel` response envelope.
    private struct CancelResponse: Decodable {
        var results: [CancelItem]
        var counts: [String: Int]?
    }

    /// STOP an in-flight collection RIP (Feature 1): POST `/rip-cancel` so the server removes
    /// still-queued matching jobs (+ their durable queue files) and KILLS the in-flight capture
    /// worker for a currently-running match, marking each canceled. Idempotent — a second call
    /// for the same song reports `notFound`. Deduplicates `ids`. No-op when there's no server.
    /// An older server that 404s `/rip-cancel` is a silent no-op (forward-compatible). After a
    /// successful cancel, the canceled songs' local job entries are cleared so the row's phase
    /// label resets. Mirrors `ripCollection`'s request/decode structure.
    @discardableResult
    func cancelCollection(_ songIds: [String]) async -> [CancelItem] {
        let ids = Self.orderedUnique(songIds)
        guard !ids.isEmpty, hasServer else { return [] }

        let base = serverUrl, tok = token
        var post = URLRequest(url: URL(string: "\(base)/rip-cancel")!)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "content-type")
        applyAuth(&post, token: tok)
        post.httpBody = try? JSONSerialization.data(withJSONObject: ["songIds": ids])

        guard let (data, response) = try? await session.data(for: post),
              let http = response as? HTTPURLResponse else { return [] }
        // Older server without the cancel endpoint → silent no-op.
        if http.statusCode == 404 { return [] }
        guard (200..<300).contains(http.statusCode) else { return [] }

        if let decoded = try? JSONDecoder().decode(CancelResponse.self, from: data) {
            for item in decoded.results where item.status == "canceled" { jobs[item.songId] = nil }
            return decoded.results
        }
        // Couldn't decode but the server accepted it — best-effort reset of the requested ids.
        for id in ids { jobs[id] = nil }
        return ids.map { CancelItem(songId: $0, status: "canceled") }
    }

    /// Map an observed per-song job phase to the batch endpoint's status vocabulary
    /// ("ready" | "queued" | "inflight" | "unknown") so the fallback's counts line up with
    /// the `/rip-collection` path. A nil phase (no/failed response) is "unknown".
    nonisolated static func batchStatus(for phase: Phase?) -> String {
        switch phase {
        case .ready:  return "ready"
        case .queued: return "queued"
        // `.queued` is already handled above, so any remaining in-flight phase is "inflight".
        case .some(let p) where inFlightPhases.contains(p): return "inflight"
        default:      return "unknown"
        }
    }

    // MARK: Stemify — separate a song (or collection) into stems on the rip server

    /// Phases that mean a stem job is already working (queued / ripping-first / separating).
    nonisolated private static let stemInFlightPhases: Set<StemPhase> = [.queued, .ripping, .stemming]

    /// FIRE-AND-FORGET Stemify request for ONE song. Idempotent at three layers (mirrors
    /// `requestRipIfNeeded`): already-stemmed / in-flight job / requesting this process → no
    /// network; the server's manifest skip + per-song single-flight is the cross-process
    /// backstop. Stores the returned job and (if it's still working) polls to completion in a
    /// detached task so the row flips to "stemmed" without blocking the caller. Never throws.
    func stemify(_ songId: String) async {
        if isStemmed(songId) { return }
        if let p = stemJobs[songId]?.phase, Self.stemInFlightPhases.contains(p) { return }
        if requestingStems.contains(songId) { return }
        guard hasServer else { return }

        requestingStems.insert(songId)
        defer { requestingStems.remove(songId) }

        let base = serverUrl, tok = token
        do {
            var post = URLRequest(url: URL(string: "\(base)/stemify")!)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "content-type")
            applyAuth(&post, token: tok)
            let body: [String: Any] = ripFromCloud ? ["songId": songId, "ripFromCloud": true] : ["songId": songId]
            post.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: post)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let view = try JSONDecoder().decode(StemJob.self, from: data)
            stemJobs[songId] = view
            if view.phase == .ready { await refreshManifest(); return }
            if view.phase == .ineligible || view.phase == .error { return }
            if let jobId = view.jobId {
                Task { [weak self] in await self?.pollStemReady(songId, jobId: jobId) }
            }
        } catch { /* fire-and-forget: silent */ }
    }

    /// Poll a stem job to a terminal phase. Demucs is minutes/song (Docker-CPU can be far
    /// longer), so the ceiling is generous; on `ready` we refresh the manifest so the row
    /// flips to the accent-tinted "stemmed" state. Best-effort; never throws.
    private func pollStemReady(_ songId: String, jobId: String) async {
        guard hasServer else { return }
        let base = serverUrl, tok = token
        let deadline = Date().addingTimeInterval(4 * 60 * 60)   // 4 h — well past the slowest run
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var req = URLRequest(url: URL(string: "\(base)/jobs/\(jobId)")!)
            applyAuth(&req, token: tok)
            guard let (data, response) = try? await session.data(for: req),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let view = try? JSONDecoder().decode(StemJob.self, from: data) else { continue }
            stemJobs[songId] = view
            switch view.phase {
            case .ready: await refreshManifest(); return
            case .error, .ineligible: return
            default: break   // queued / ripping / stemming — keep polling
            }
        }
    }

    /// One song's outcome from a batch Stemify (server per-song result).
    struct BatchStemItem: Decodable, Equatable {
        var songId: String
        /// "ready"|"queued"|"inflight"|"ripping"|"needsCut"|"ineligible"|"unknown".
        var status: String
        var jobId: String?
    }

    /// Aggregate result of `stemifyCollection` — per-song outcomes + counts (with the rip-first
    /// `ripping` and terminal `ineligible` buckets), plus the server's `needsConfirm` envelope
    /// for an over-cap collection (the UI shows an "N songs, long job — proceed?" alert).
    struct BatchStemResult: Equatable {
        var results: [BatchStemItem] = []
        var ready = 0, queued = 0, inflight = 0, ripping = 0, needsCut = 0, ineligible = 0, unknown = 0, total = 0
        var needsConfirm = false, count = 0, cap = 0
    }

    /// The `/stemify-collection` response envelope (results+counts OR a needsConfirm gate).
    private struct BatchStemResponse: Decodable {
        struct Counts: Decodable { var ready = 0; var queued = 0; var inflight = 0; var ripping = 0; var needsCut = 0; var ineligible = 0; var unknown = 0; var total = 0 }
        var results: [BatchStemItem]?
        var counts: Counts?
        var needsConfirm: Bool?
        var count: Int?
        var cap: Int?
    }

    /// Batch-Stemify a collection, reusing the server's durable queue + rip→stem chain.
    /// Deduplicates. On an over-cap collection the server returns `needsConfirm` (re-call with
    /// `confirmLarge: true`). An older server that 404s falls back to a per-song loop. Empty
    /// input is a no-op.
    func stemifyCollection(_ songIds: [String], confirmLarge: Bool = false) async -> BatchStemResult {
        let ids = Self.orderedUnique(songIds)
        guard !ids.isEmpty else { return BatchStemResult() }
        guard hasServer else { return await stemifyCollectionFallback(ids) }

        let base = serverUrl, tok = token
        do {
            var post = URLRequest(url: URL(string: "\(base)/stemify-collection")!)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "content-type")
            applyAuth(&post, token: tok)
            var body: [String: Any] = ["songIds": ids]
            if ripFromCloud { body["ripFromCloud"] = true }
            if confirmLarge { body["confirmLarge"] = true }
            post.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: post)
            guard let http = response as? HTTPURLResponse else { return await stemifyCollectionFallback(ids) }
            if http.statusCode == 404 { return await stemifyCollectionFallback(ids) }
            guard (200..<300).contains(http.statusCode) else { return BatchStemResult() }

            let decoded = try JSONDecoder().decode(BatchStemResponse.self, from: data)
            if decoded.needsConfirm == true {
                var r = BatchStemResult()
                r.needsConfirm = true; r.count = decoded.count ?? ids.count; r.cap = decoded.cap ?? 0
                return r
            }
            for item in (decoded.results ?? []) where item.status == "queued" || item.status == "inflight" || item.status == "ripping" || item.status == "needsCut" {
                if let jobId = item.jobId { stemJobs[item.songId] = StemJob(jobId: jobId, songId: item.songId, phase: .queued) }
            }
            let c = decoded.counts ?? BatchStemResponse.Counts()
            return BatchStemResult(results: decoded.results ?? [], ready: c.ready, queued: c.queued,
                                   inflight: c.inflight, ripping: c.ripping, needsCut: c.needsCut,
                                   ineligible: c.ineligible, unknown: c.unknown, total: c.total)
        } catch {
            return await stemifyCollectionFallback(ids)
        }
    }

    /// Per-song fallback when `/stemify-collection` is unavailable. Mirrors the rip fallback
    /// but synthesizes counts from the STEM job phases (not the rip `jobs` dict).
    private func stemifyCollectionFallback(_ ids: [String]) async -> BatchStemResult {
        var result = BatchStemResult()
        for id in ids {
            if isStemmed(id) {
                result.results.append(BatchStemItem(songId: id, status: "ready", jobId: nil)); result.ready += 1
            } else if hasServer {
                await stemify(id)
                let status = Self.stemBatchStatus(for: stemJobs[id]?.phase)
                result.results.append(BatchStemItem(songId: id, status: status, jobId: stemJobs[id]?.jobId))
                switch status {
                case "ready":      result.ready += 1
                case "queued":     result.queued += 1
                case "ripping":    result.ripping += 1
                case "ineligible": result.ineligible += 1
                default:           result.unknown += 1
                }
            } else {
                result.results.append(BatchStemItem(songId: id, status: "unknown", jobId: nil)); result.unknown += 1
            }
            result.total += 1
        }
        return result
    }

    /// Map a stem job phase to the collection status vocabulary (fallback count synthesis).
    nonisolated static func stemBatchStatus(for phase: StemPhase?) -> String {
        switch phase {
        case .ready:             return "ready"
        case .stemming, .queued: return "queued"
        case .ripping:           return "ripping"
        case .ineligible:        return "ineligible"
        case .error, .none:      return "unknown"
        }
    }

    /// STOP an in-flight collection Stemify: POST `/stemify-cancel` so the server cancels the
    /// queued/active stem jobs AND tears down any chained rip. Idempotent; older-server 404 is a
    /// silent no-op. Clears the local stem job entries for canceled songs. Mirrors `cancelCollection`.
    @discardableResult
    func cancelStemCollection(_ songIds: [String]) async -> [CancelItem] {
        let ids = Self.orderedUnique(songIds)
        guard !ids.isEmpty, hasServer else { return [] }

        let base = serverUrl, tok = token
        var post = URLRequest(url: URL(string: "\(base)/stemify-cancel")!)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "content-type")
        applyAuth(&post, token: tok)
        post.httpBody = try? JSONSerialization.data(withJSONObject: ["songIds": ids])

        guard let (data, response) = try? await session.data(for: post),
              let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode == 404 { return [] }
        guard (200..<300).contains(http.statusCode) else { return [] }

        if let decoded = try? JSONDecoder().decode(CancelResponse.self, from: data) {
            for item in decoded.results where item.status == "canceled" { stemJobs[item.songId] = nil }
            return decoded.results
        }
        for id in ids { stemJobs[id] = nil }
        return ids.map { CancelItem(songId: $0, status: "canceled") }
    }

    // MARK: Feature 2 BURN — non-blocking download primitive + managed storage

    /// NON-BLOCKING download for Burn: returns the durable mp3 bytes + the manifest entry
    /// ONLY when the song is already ripped (in the manifest). Returns nil otherwise —
    /// Burn must NEVER block on the 30-min rip-on-demand `ensureURL` path, so a not-yet-
    /// ripped song is simply skipped (and optionally enqueued via `ripCollection`).
    func downloadDataIfCached(_ song: (id: String, title: String, artist: String)) async throws -> (data: Data, entry: ManifestEntry)? {
        guard let url = cachedURL(song.id), let entry = manifest[song.id] else { return nil }
        var request = URLRequest(url: url)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RipError.serverError(nil)
        }
        return (data, entry)
    }

    /// App-managed storage for burned audio + sidecars (NOT user-visible Documents —
    /// these are app-managed offline files the future offline player / live-mixer reads).
    /// Mirrors `documentsDirectory()` but in Application Support, under `burns/`.
    nonisolated static func burnsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("burns", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pure: stable de-dupe preserving first-seen order (the batch must not reorder a
    /// collection, and must not double-enqueue a song that appears twice).
    nonisolated static func orderedUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for id in ids where !id.isEmpty && seen.insert(id).inserted { out.append(id) }
        return out
    }
    private func orderedUnique(_ ids: [String]) -> [String] { Self.orderedUnique(ids) }

    /// Sanitized "Artist - Title.mp3" filename (mirrors the PWA's slug).
    nonisolated static func downloadFileName(artist: String, title: String) -> String {
        downloadBaseName(artist: artist, title: title) + ".mp3"
    }

    /// Sanitized "Artist - Title" base name (no extension) — the `.fileExporter`'s
    /// `defaultFilename`, which appends the `.mp3` from the document's content type.
    nonisolated static func downloadBaseName(artist: String, title: String) -> String {
        let raw = "\(artist) - \(title)"
        let bad = CharacterSet(charactersIn: "/\\?%*:|\"<>")
        return String(raw.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
    }

    static func documentsDirectory() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    // MARK: Helpers

    private func applyAuth(_ request: inout URLRequest, token: String) {
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    static func sleep1s() async throws { try await sleep(ms: 1000) }
    static func sleep(ms: Int) async throws { try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
}

private extension String {
    /// Trim a single trailing slash (matches the PWA's `replace(/\/$/, '')`).
    var trimmedTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

extension CharacterSet {
    /// Query-value-safe set: alphanumerics + a few unreserved marks, matching JS
    /// `encodeURIComponent` closely enough for opaque tokens.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
