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
        var jobId: String?
        var songId: String?
        var phase: Phase
        var message: String?
        var url: String?
        var error: String?
        /// Relative path to the live HLS playlist (`/hls/<songId>/index.m3u8`).
        var streamUrl: String?
        var progress: Progress?
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
    /// The track the inline player is currently bound to.
    private(set) var nowPlaying: NowPlaying?

    // MARK: Config

    private let ripsBase: URL
    private let session: URLSession
    /// Settings supply the rip-server URL + token (set by the app at launch).
    var settings: SettingsStore?

    /// `serverUrl`/`token` resolve from settings, exactly like the PWA reads localStorage.
    var serverUrl: String { (settings?.ripServerURL ?? "").trimmingCharacters(in: .whitespaces).trimmedTrailingSlash }
    var token: String { (settings?.ripToken ?? "").trimmingCharacters(in: .whitespaces) }
    var hasServer: Bool { !serverUrl.isEmpty }

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
        } catch { /* offline — keep whatever we have */ }
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
        post.setValue("application/json", forHTTPHeaderField: "content-type")
        applyAuth(&post, token: tok)
        post.httpBody = try JSONSerialization.data(withJSONObject: ["songId": songId])
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

    /// Resolve a song to its durable mp3 and write it to a file the user can keep
    /// (the app's Documents directory). Returns the saved file URL (for share/export).
    @discardableResult
    func download(_ song: (id: String, title: String, artist: String)) async throws -> URL {
        let url = try await ensureURL(song.id, allowLive: false)
        var request = URLRequest(url: url)
        applyAuth(&request, token: token)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RipError.serverError(nil)
        }
        let name = Self.downloadFileName(artist: song.artist, title: song.title)
        let dest = try Self.documentsDirectory().appendingPathComponent(name)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    func setNowPlaying(_ n: NowPlaying?) { nowPlaying = n }

    /// Sanitized "Artist - Title.mp3" filename (mirrors the PWA's slug).
    nonisolated static func downloadFileName(artist: String, title: String) -> String {
        let raw = "\(artist) - \(title).mp3"
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
