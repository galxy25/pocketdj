import Foundation
import Observation
import os                  // rips Logger — studio-id guard + cue diagnostics

/// Import-on-demand client — a faithful native port of the PWA's `useRipsStore`.
///
/// EVERYTHING this client asks for is the user's OWN media, held in their own cloud
/// library. A song the user does not own is simply a MISS: the server returns nothing
/// and never goes looking for that audio anywhere else. Apple Music is a playback
/// surface only — nothing here captures, records or downloads audio from it.
///
/// Two backends, exactly like the web app:
///   • the rips manifest (`<ripsBase>/rips/manifest.json`) says which of the user's songs
///     are already prepared — fetched straight from object storage, so it works even with
///     the import server offline (the server is only needed to PREPARE a song),
///   • the import server prepares a song on demand from the user's own cloud library and
///     serves a live HLS stream while it is still being prepared.
///
/// `play(_:)` resolves a song to a playable URL: a prepared song streams its durable
/// mp3 instantly; a miss POSTs `/rip`, polls `/jobs/<id>`, and returns the live HLS
/// URL the moment the stream is ready (then keeps polling in the background to swap the
/// manifest to the durable mp3). `download(_:)` resolves the durable mp3 bytes.
///
/// #TOUPDATE: "the user's OWN media / their own copy" is the TARGET, not today's storage.
/// The manifest and every object it names sit under a PUBLIC-READ, FLAT `rips/<songId>.mp3`
/// namespace SHARED by all users — no per-user copies, no per-user access control. Honest
/// only once rips are written under a per-user prefix and reads are access-controlled. The
/// "public S3 / public ripsBase / PUBLIC rips/ prefix" notes further down this file are
/// accurate TODAY and describe exactly what has to change; sweep them in the same pass.
///
/// #TOUPDATE: "accesses only theirs" also needs request auth. The server's `authed()` and
/// `adminAuthed()` FAIL OPEN — with no token configured EVERY request is authorized, and
/// `/health` reports `auth:false`. Honest only once the server authenticates the requester
/// and rejects unauthenticated reads and writes.
///
/// #TOUPDATE: "prepares from the user's own cloud library" is the TARGET. Today the server
/// routes every DIGITAL-source song to a real-time Apple Music CAPTURE unconditionally
/// (rip-server.mjs — "Digital songs always capture from Apple Music"), and analog songs
/// capture on an exact library match; the `ripFromCloud` flag below is NOT the gate. Honest
/// only once capture is deleted and the server FAILS CLOSED on any song the requester does
/// not own in their cloud library.
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
    /// `stems`/`stemFormat` ride only CUSTOM (uploaded-audio) jobs, whose S3 keys have no
    /// manifest entry to live in (see `stemifyCustom`).
    struct StemJob: Decodable, Equatable {
        var jobId: String? = nil
        var songId: String? = nil
        var phase: StemPhase
        var error: String? = nil
        var stems: [String: String]? = nil
        var stemFormat: String? = nil
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
        /// ANALOG only: the per-song CUT chunk (`rips/<songId>.cut.mp3`) sliced out of the album,
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
        // Cloud timed-lyrics transcription (faster-whisper over the VOCALS stem; all optional ⇒
        // back-compat). `lyrics` is the sidecar KEY (`rips/lyrics/<songId>.json` — the beatgrid
        // key convention); word timestamps inside are ms from the SONG's 0:00 (the cut for
        // analog, because the vocals stem is cut-derived). Presence ⇒ transcribed.
        var lyrics: String? = nil
        var lyricsModel: String? = nil
        var lyricsVersion: Int? = nil
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
        /// The SONG's start within a shared analog album mp3 (nil for per-song files /
        /// live HLS). This stays the song's TRUE start even on a cue play — it is the
        /// anchor `SetlistPlayer.sharedFileEndBoundaryMs` (+ its now-playing adoption)
        /// computes `startMs + lengthMs` from; folding a cue offset in here would push a
        /// shared-album track's advance boundary INTO the next song on the album side.
        var startMs: Int?
        /// The absolute file position playback should actually START at (spec §9): equal
        /// to `startMs` on a plain play; `startMs`-shifted by the requested cue offset on
        /// a cue play (`RipsStore.cueSeekMs`); nil for live HLS (unseekable — the cue is
        /// dropped and the caller is told via `live`). `PlayerEngine.load(startMs:)`
        /// consumes THIS, boundary math consumes `startMs` — the split is load-bearing.
        var seekMs: Int? = nil
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
    /// Fired when playback moves to a DIFFERENT song (every `nowPlaying` transition —
    /// single rows, set lists, burned local files, rip streaming). Wired at app init to
    /// `PlayStatsStore.notePlayed` (the storage manager's LRP prune signal); nil in tests.
    /// STATS IDENTITY: always fires the BASE song id — a variant play ("sng_…_clean")
    /// resolves audio under the variant id but the play belongs to the real song, and a
    /// variant-keyed record would be a ghost row no catalog can title (plus a stats
    /// double-count: the coordinator's own hook fires the base id, and the 30s per-id
    /// re-count window can only dedupe SAME ids). `nowPlaying.songId` itself keeps the
    /// variant id — the ownership guards depend on it.
    @ObservationIgnored var onPlay: ((String) -> Void)?

    /// A rip reached READY and its file is now in the manifest. Wired at app init to
    /// `BurnStore.drainPendingAfterRip` so a download the user asked for BEFORE the song existed
    /// finishes by itself, without them coming back to tap anything.
    @ObservationIgnored var onRipReady: ((String) -> Void)?

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
    /// The signed-in profile's durable id, read FRESH per request (it can change under a cloud
    /// pull or an account-deletion reset). Wired from `ProfileStore.id` in the app; the default
    /// empty source ⇒ no profile header until wired. Rides as `X-PocketDJ-Profile` (see applyAuth).
    @ObservationIgnored var profileIdProvider: () -> String = { "" }

    /// `serverUrl`/`token` resolve from settings, exactly like the PWA reads localStorage.
    var serverUrl: String { (settings?.ripServerURL ?? "").trimmingCharacters(in: .whitespaces).trimmedTrailingSlash }
    var token: String { (settings?.ripToken ?? "").trimmingCharacters(in: .whitespaces) }
    var hasServer: Bool { !serverUrl.isEmpty }
    /// When on, requests ask the server to prefer the user's CLOUD-library copy of a song
    /// over their local/analog one. Sent in the POST body only when true (older servers
    /// ignore it).
    ///
    /// #TOUPDATE: this flag should not exist. All preparation is meant to run against the
    /// user's owned media in their cloud library, so there is nothing to toggle. Today it
    /// still maps to the server's `preferCloud`, and the server captures DIGITAL songs from
    /// Apple Music whether or not it is set — so the toggle does NOT gate capture. Delete it
    /// (this property, the POST bodies below, the server's `preferCloud`, the persisted
    /// `SettingsStore.ripFromCloud` and its Settings toggle) once capture is gone. Left in
    /// place for now because removing it would change behaviour and strand a stored setting.
    var ripFromCloud: Bool { settings?.ripFromCloud ?? false }

    /// Studio-id guard + cue diagnostics (spec §8/§9) — one info line per fenced request;
    /// invisible cost unless collected:
    ///   log stream --predicate 'subsystem == "com.levi.pocketdj"' --info
    @ObservationIgnored private static let diag = Logger(subsystem: "com.levi.pocketdj", category: "rips")
    private func dlog(_ s: String) { Self.diag.info("\(s, privacy: .public)") }

    init(ripsBase: URL = Config.ripsBase, session: URLSession = .shared) {
        self.ripsBase = ripsBase
        self.session = session
    }

    // MARK: Studio-id fence (spec §8 defense-in-depth)

    /// Pure: drop studio-namespaced ids (`smp_`/`lp_`/`ptn_`/`tk_` — `StudioFactory.studioPrefixes`,
    /// the single source of truth). Studio items ride collections' string arrays, so ANY
    /// collection-shaped id list handed to rip/stemify may contain them — and a studio id
    /// reaching the import server would trigger a live-search rip of a garbage title into the
    /// public bucket. The server rejects them too (`rip-server.mjs`); this client mirror keeps
    /// the requests from ever leaving the device. (`cue_` ids pass through on purpose: cues
    /// never ride collection arrays — see `StudioFactory.newCueId`.)
    nonisolated static func excludingStudioIds(_ ids: [String]) -> [String] {
        // Also drops "Pocket DJ" profile ids (pdj_) — device-local custom audio must never leave the
        // device for a rip (kept under the studio-named helper; both are device-local fences).
        ids.filter { !StudioFactory.isStudioId($0) && !ProfileSourceStore.isProfileSongId($0) }
    }

    /// Guard-return check for the SINGLE-song rip/stemify entry points: true (and one log line)
    /// when `id` is DEVICE-LOCAL (studio OR "Pocket DJ" profile) and the caller must bail before any
    /// network. Mirrors the batch `excludingStudioIds` fence so single-song + batch fail SAFE alike.
    private func fencedStudioId(_ id: String, path: String) -> Bool {
        guard StudioFactory.isStudioId(id) || ProfileSourceStore.isProfileSongId(id) else { return false }
        dlog("\(path): skipped device-local id \(id) — studio + Pocket DJ items never rip (spec §8)")
        return true
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

    // MARK: Stem (Demucs) helpers — read-only ingestion (creation lives on the import server)

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

    // MARK: Cloud lyrics sidecar (timed words — the Demuxer's transcript source for songs)

    /// True once the cloud pipeline has produced a timed-lyrics sidecar for the song.
    func hasLyricsSidecar(_ songId: String) -> Bool { !((manifest[songId]?.lyrics ?? "").isEmpty) }

    /// Public URL of the timed-lyrics sidecar (`rips/lyrics/<songId>.json`), nil when none.
    /// Built off the same public ripsBase as stems/beatgrids, so it resolves server-offline.
    func lyricsSidecarURL(forSong songId: String) -> URL? {
        guard let key = manifest[songId]?.lyrics, !key.isEmpty else { return nil }
        return ripsBase.appendingPathComponent(key)
    }

    /// The timed-lyrics sidecar the cloud worker ships to S3 (`transcribe-one.py`'s output):
    /// whisper words over the vocals stem, ms from the song's 0:00 — a drop-in for `DemuxWord`.
    /// Defensive decode (the `BeatGridSidecar` style) so a partial/older sidecar still lands.
    struct TimedLyricsSidecar: Decodable, Equatable {
        struct Word: Decodable, Equatable {
            var text: String
            var startMs: Int
            var endMs: Int
        }
        /// Per-element lossy box: ONE malformed word drops that word only — never the whole
        /// transcript (an all-or-nothing decode would land "instrumental" as done+cloud and
        /// the fetched-once dedup would never retry it).
        private struct LossyWord: Decodable {
            let value: Word?
            init(from decoder: Decoder) { value = try? Word(from: decoder) }
        }
        var version: Int?
        var model: String?
        var lang: String?
        var durationMs: Int?
        var words: [Word]
        private enum CodingKeys: String, CodingKey { case version, model, lang, durationMs, words }
        init(version: Int? = nil, model: String? = nil, lang: String? = nil,
             durationMs: Int? = nil, words: [Word] = []) {
            self.version = version; self.model = model; self.lang = lang
            self.durationMs = durationMs; self.words = words
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            lang = try c.decodeIfPresent(String.self, forKey: .lang)
            durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
            words = ((try? c.decode([LossyWord].self, forKey: .words)) ?? []).compactMap(\.value)
        }
    }

    // MARK: Errors

    enum RipError: LocalizedError {
        case noServer, ripFailed(Int), didNotStart(String?), serverError(String?), timedOut
        /// A studio-namespaced id reached a rip path (spec §8) — these play from their own
        /// local files and must NEVER hit the import server (defense-in-depth; the server
        /// rejects them too). Surfacing an explicit error beats a confusing server 4xx.
        case studioItem

        /// NOTE: the "Settings ▸ Import server" pointers here and in the `discoverError`
        /// strings below name a REAL section — SettingsView's `Text("Import server")` header
        /// and its "Import server URL" / token fields. Rename them together or the pointers
        /// dangle. (The `settings-rip-*` accessibility ids are NOT user-visible and stay.)
        var errorDescription: String? {
            switch self {
            case .noServer:           return "No import server configured (Settings ▸ Import server)."
            case .ripFailed(let s):   return "Rip failed (\(s))."
            case .didNotStart(let m): return m ?? "Rip did not start."
            case .serverError(let m): return m ?? "Rip failed."
            case .timedOut:           return "Rip timed out."
            case .studioItem:         return "Studio items play from their own files — they can’t be ripped."
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
        // Spec §8: the play/download choke point that POSTs `/rip` — a studio id here
        // (a stale collection row, an old caller) must fail loudly, not live-search rip.
        if fencedStudioId(songId, path: "ensureURL") { throw RipError.studioItem }
        guard hasServer else { throw RipError.noServer }
        let base = serverUrl, tok = token

        // POST /rip {songId} (creates or joins the single-flight job).
        var post = URLRequest(url: URL(string: "\(base)/rip")!)
        post.httpMethod = "POST"
        // Short connect/request timeout (matches RipServerService.health's 12s) so a CONFIGURED
        // but unreachable import server (asleep, or venue wifi that can't reach it) fails in
        // seconds — letting Play-All SKIP an un-burned track promptly rather than stalling on
        // URLSession.shared's 60s default before advancing.
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
                if v.phase == .ready, v.url != nil {
                    await self.refreshManifest()
                    self.onRipReady?(songId)
                    return
                }
                // Do NOT stop on .error: the server's auto-heal re-queues failed
                // jobs (retry N/6 with backoff), flipping error → queued — a poll
                // that bailed here left the row stuck on ＋ Add while the server was
                // still working. The 1-hour cap above is the terminal condition.
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
    ///
    /// `startMs` (pre-existing) is an ABSOLUTE override of the manifest entry's shared-
    /// analog-album start. `atMs` (spec §9) is a CUE offset in ms from the SONG's 0:00:
    /// the returned `NowPlaying.seekMs` becomes `(startMs ?? entry.startMs ?? 0) + atMs`
    /// — the song's position inside a shared analog album file plus the cue, or the cue
    /// directly for a per-song digital file — while `NowPlaying.startMs` keeps the song's
    /// TRUE start for end-boundary math (see the `NowPlaying` field docs). A LIVE HLS
    /// stream cannot seek, so both come back nil there: the caller detects the dropped
    /// cue via `live == true` (the coordinator's rip provider records `lastCueDropped`).
    @discardableResult
    func play(_ song: (id: String, title: String, artist: String), startMs: Int? = nil,
              atMs: Int? = nil) async throws -> NowPlaying {
        let url = try await ensureURL(song.id, allowLive: true)
        let live = url.absoluteString.contains("/hls/")
        let entry = manifest[song.id]
        let resolvedStart = live ? nil : (startMs ?? entry?.startMs)
        let np = NowPlaying(
            songId: song.id, title: song.title, artist: song.artist, url: url, live: live,
            startMs: resolvedStart,
            seekMs: Self.cueSeekMs(sharedFileStartMs: resolvedStart, atMs: atMs, live: live),
            waveform: live ? nil : Self.waveformURL(for: entry, ripsBase: ripsBase))
        let prev = nowPlaying?.songId
        nowPlaying = np
        if np.songId != prev { onPlay?(SongVariant.baseId(np.songId)) }
        return np
    }

    /// Pure (spec §9): the absolute file position playback should START at for an optional
    /// cue. `sharedFileStartMs` = the song's start within a shared analog album mp3 (nil
    /// for per-song digital files); `atMs` = cue offset from the SONG's 0:00 (negative
    /// values clamp to 0 — a cue can't precede the song). Rules:
    ///   • live HLS → nil ALWAYS (an in-flight rip stream can't seek; the cue is dropped
    ///     and callers must surface that, never silently seek-to-0),
    ///   • no cue → the shared-file start unchanged (the pre-cue behavior, bit-for-bit),
    ///   • cue → `(sharedFileStartMs ?? 0) + atMs` — analog offsets ADD, digital is direct.
    nonisolated static func cueSeekMs(sharedFileStartMs: Int?, atMs: Int?, live: Bool) -> Int? {
        if live { return nil }
        guard let atMs else { return sharedFileStartMs }
        return (sharedFileStartMs ?? 0) + max(0, atMs)
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

    func setNowPlaying(_ n: NowPlaying?) {
        let prev = nowPlaying?.songId
        nowPlaying = n
        if let id = n?.songId, id != prev { onPlay?(SongVariant.baseId(id)) }
    }

    // MARK: Analog cut export (burn-only)

    /// The public URL for a manifest key (e.g. an analog `cutKey` = "rips/<songId>.cut.mp3" —
    /// always under the `rips/*` public-bucket-policy prefix; consume the manifest's key
    /// verbatim, never derive one).
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

    /// FIRE-AND-FORGET import request (Feature 1). Called the moment a streamable song
    /// STARTS playing, so the user's durable copy is likely ready shortly after. This is an
    /// independent request for the user's own copy — the Apple Music stream the user may be
    /// hearing is not recorded, reused, or otherwise involved. NEVER throws (errors are
    /// swallowed) and NEVER blocks playback — the caller fires it in an unawaited `Task`.
    ///
    /// #TOUPDATE: "the stream is not recorded" is the TARGET — the request the client sends
    /// carries only the song id, but the server still fulfils it by capturing the track from
    /// Apple Music in real time. True once the server's capture path is deleted (see the
    /// capture marker at the top of this file).
    ///
    /// IDEMPOTENT at three layers:
    ///   1. cheap MainActor guard — already cached, an in-flight job, or already requesting
    ///      this process → return immediately (no network),
    ///   2. the synchronous `requesting` Set is inserted BEFORE the `await` so two near-
    ///      simultaneous calls collapse to one POST,
    ///   3. the server's manifest skip + single-flight inflight join is the exact-once
    ///      cross-process / restart backstop.
    /// LAZY RIP ON MISS — the on-demand half of edition-keyed storage. When the edition the
    /// user actually wants isn't stored yet, enqueue a rip for THAT edition, one song, at the
    /// moment something asks for it. There is deliberately NO bulk re-rip: everything outside
    /// a collection is served by this path alone.
    ///
    /// It is the SAME mechanism as every other rip, not a second one: it delegates to
    /// `requestRipIfNeeded` under the VARIANT song id (`<base>_explicit` / `<base>_clean`),
    /// which the rip server already understands (`resolveVariantRow` synthesizes the row from
    /// the base + that edition's catalog id and captures with `--explicitness`), stores as a
    /// distinct object (`rips/<base>_<edition>.mp3` — the clean rip is never overwritten), and
    /// dedups through the same durable queue + single-flight. Idempotence therefore comes for
    /// free at all three layers, so repeated misses while a rip is in flight enqueue ONCE.
    ///
    /// Returns the variant id it enqueued under, or nil when nothing was enqueued: no edition
    /// substitution, the edition is already stored, or — importantly — that edition's CATALOG
    /// ID IS UNKNOWN (`EditionPolicy.lazyRipId`'s hard gate).
    @discardableResult
    func requestEditionRipIfNeeded(base: String, decision: EditionPolicy.Decision) async -> String? {
        guard let variantId = EditionPolicy.lazyRipId(base: base, decision: decision,
                                                      isStored: { self.cachedURL($0) != nil })
        else { return nil }
        await requestRipIfNeeded(variantId)
        return variantId
    }

    func requestRipIfNeeded(_ songId: String) async {
        // (0) spec §8 — a studio id NEVER rips (fire-and-forget path: silent guard-return).
        if fencedStudioId(songId, path: "requestRipIfNeeded") { return }
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

    /// Outcome of an explicit, metadata-carrying import request (`requestRip`).
    enum RipRequestOutcome: Equatable {
        case ready          // already in the manifest — nothing to prepare
        case queued         // newly enqueued on the import server
        case inflight       // joined an in-progress job for the same resource
        case unknown        // server has nothing to prepare for this song — a MISS, not a failure
        case noServer       // no import server configured
        case failed         // network / decode error
    }

    /// Request the user's own copy of a song the catalog may NOT contain yet — the
    /// recognizer's ＋ Add path (save to the user's Apple Music library, then prepare their
    /// own copy). Unlike `requestRipIfNeeded` (which posts only `songId`, so the server must
    /// already know the track), this carries `title`/`artist` so the server can synthesize an
    /// ad-hoc catalog row and resolve the song by artist+title. Returns the server's
    /// classification so the caller can decide whether to poll for completion; a song the user
    /// does not own comes back `.unknown` — a miss, and the end of it. Idempotent-ish: an
    /// already-prepared song short-circuits to `.ready`.
    ///
    /// #TOUPDATE: "a song the user does not own comes back `.unknown`" is the TARGET. Today
    /// the server treats an unowned song as work to do — it synthesizes the ad-hoc row and
    /// captures the track from Apple Music — so this path currently returns `.queued`, not
    /// `.unknown`. True once the server fails closed on media the requester does not own in
    /// their cloud library and reports the miss as a 404.
    @discardableResult
    func requestRip(songId: String, title: String, artist: String,
                    appleMusicId: String? = nil, lengthMs: Int? = nil) async -> RipRequestOutcome {
        // Spec §8 — a studio id NEVER rips. `.unknown` is the honest outcome ("not a
        // rippable catalog song") and stops every caller's completion polling.
        if fencedStudioId(songId, path: "requestRip") { return .unknown }
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

    // MARK: Discover — Apple Music catalog search (the import server's /search proxy)

    /// One `GET /search` result: an Apple Music catalog hit — METADATA only (title, artist,
    /// artwork). Finding a song here grants no access to its audio; see `discoverAdd` for what
    /// ＋ Add actually does. `songId` is the ad-hoc id (`amrec_<storeId>`); `ripped`/`url`
    /// reflect the rips manifest at search time (the user's copy may already be prepared).
    struct DiscoverHit: Decodable, Identifiable, Equatable {
        var appleMusicId: String
        var title: String
        var artist: String
        var album: String? = nil
        var artworkUrl: String? = nil
        var durationMs: Int? = nil
        var songId: String
        var ripped: Bool? = nil
        var url: String? = nil
        /// iTunes `trackExplicitness` mapped server-side (`/search`): true = explicit,
        /// false = clean/notExplicit, nil = unclassified (older servers omit the key).
        var explicit: Bool? = nil

        // ── Album identity + richer metadata ────────────────────────────────────────
        // ALL optional-with-default and APPENDED (never inserted): an older rip server
        // that doesn't emit these keys still decodes, and every existing memberwise-init
        // call site keeps compiling. Without `albumAppleMusicId` a Discover ＋Add lands a
        // catalog song with no album at all — no cover art, no "Album" row, and no
        // `album-hotlink` to tap. That was half of the "tapping the album shows a blank
        // screen" report; the other half was the hotlink's routing (SongDetailView).
        /// iTunes `collectionId` of the album this track belongs to.
        var albumAppleMusicId: String? = nil
        /// Album cover URL (iTunes `artworkUrl100`) — the preview screen's art when the
        /// track's own artwork is absent.
        var albumArtworkUrl: String? = nil
        var trackNumber: Int? = nil
        var discNumber: Int? = nil
        var year: Int? = nil
        var id: String { songId }
    }

    /// The `/search` response envelope.
    private struct DiscoverResponse: Decodable { var results: [DiscoverHit] }

    /// Edition-preference re-rank for Discover results (pure, order-stable). Hits sharing
    /// a normalized (title, artist) form a GROUP anchored at the group's first appearance;
    /// within a group the preferred edition sorts first (unclassified hits keep their
    /// original relative order after the classified preference winners). Groups keep
    /// their overall relative order, so relevance ranking survives the re-rank.
    enum DiscoverExplicitRanking {
        static func rank(_ hits: [DiscoverHit], preferExplicit: Bool) -> [DiscoverHit] {
            var order: [String] = []                     // group keys, first-appearance order
            var groups: [String: [DiscoverHit]] = [:]
            for h in hits {
                let key = ShazamCatalogMatch.norm(h.title) + "\u{0}" + ShazamCatalogMatch.norm(h.artist)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(h)
            }
            var out: [DiscoverHit] = []
            for key in order {
                let g = groups[key] ?? []
                // Stable partition: preferred-edition hits first, everyone else after,
                // both halves in original order (nil explicit is never "preferred").
                out.append(contentsOf: g.filter { $0.explicit == preferExplicit })
                out.append(contentsOf: g.filter { $0.explicit != preferExplicit })
            }
            return out
        }
    }

    /// Why the last Discover search/add failed (nil = healthy) — the Browse ▸ Discover
    /// inline notice. Strings already name the Settings pane to fix (URL vs token).
    private(set) var discoverError: String?

    /// Search the ENTIRE Apple Music catalog via the import server's `/search` proxy — a
    /// METADATA lookup, for finding out what exists. Returns [] on ANY failure, surfacing the
    /// reason via `discoverError` (a 401/403 points at the Settings ▸ Import server token) —
    /// Discover is a browse surface, so errors inform rather than throw. An empty/whitespace
    /// query is a no-op.
    func discoverSearch(_ query: String, limit: Int = 25) async -> [DiscoverHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { discoverError = nil; return [] }
        guard hasServer else {
            // Serverless is a benign skip for the metadata search — MusicKit covers Discover
            // search + AM-library add (public-user audit fix). Clear the error so a genuine
            // zero-hit result reads "No matches", not "No import server".
            discoverError = nil
            return []
        }
        guard var comps = URLComponents(string: "\(serverUrl)/search") else {
            discoverError = "Invalid import server URL (Settings ▸ Import server)."
            return []
        }
        comps.queryItems = [URLQueryItem(name: "q", value: q),
                            URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps.url else {
            discoverError = "Invalid import server URL (Settings ▸ Import server)."
            return []
        }
        var req = URLRequest(url: url)
        // Same short timeout as `ensureURL`'s POST: an unreachable import server must
        // fail in seconds, not URLSession's 60 s default, so the notice appears promptly.
        req.timeoutInterval = 12
        applyAuth(&req, token: token)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                discoverError = "Search failed."; return []
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                discoverError = "The import server rejected the request — check Settings ▸ Import server token."
                return []
            }
            guard (200..<300).contains(http.statusCode) else {
                discoverError = "Search failed (\(http.statusCode))."; return []
            }
            let hits = try JSONDecoder().decode(DiscoverResponse.self, from: data).results
            discoverError = nil
            return hits
        } catch {
            discoverError = "Import server unreachable (Settings ▸ Import server)."
            return []
        }
    }

    /// "＋ Add" for a Discover hit — two INDEPENDENT app-side actions, in order:
    ///
    ///   1. Add the song to the user's own Apple Music library (when this device can write
    ///      it). This is a complete user-facing action on its own: the user found something
    ///      and saved it to their library. It does not exist to enable step 2.
    ///   2. Ask the import server to prepare the user's own copy, via the metadata-carrying
    ///      `/rip` path (`requestRip`), then follow the job with the same background poll
    ///      single-song imports use (`pollToReady`) so the manifest — and the row — flips when
    ///      the job lands. In-flight state is readable per song via `jobs[hit.songId]?.phase`.
    ///      Never throws; failures land in `discoverError`.
    ///
    /// ＋ Add is NOT an exception to the ownership rule. Step 1 stands on its own. Step 2 only
    /// ever succeeds for media the user already OWNS in their cloud library; a song they don't
    /// own is a MISS, and the server acquires the audio from nowhere to fill the gap.
    ///
    /// This code is AGNOSTIC to how the server fulfils step 2, and must stay that way. The
    /// app states an intent ("prepare this user's copy") and the server decides what it can
    /// honour — its contract is that it processes ONLY media the user owns in their own cloud
    /// library, and a song outside that is simply a miss. Do not reintroduce assumptions about
    /// the server's mechanism here, or sequence app-side work to accommodate one: that couples
    /// the client to a server implementation it cannot see, and it misdescribes the app's
    /// behaviour to anyone reading this source.
    ///
    /// #TOUPDATE: the server contract described above is the TARGET, not current behaviour —
    /// the server does not yet restrict itself to media the user owns (it captures Discover
    /// adds from Apple Music), and does not yet authenticate the requester or serve per-user
    /// copies. Remove this marker once it does all three.
    ///
    /// Provisional-catalog store (eventual consistency — wired at app init). An accepted
    /// add lands the song in the on-device catalog IMMEDIATELY; the nightly indexer's
    /// real entry supersedes it later.
    @ObservationIgnored var discoverAdds: DiscoverAddsStore?

    /// The Apple Music write's outcome rides back to the caller (and onto the provisional
    /// entry + History event) — the FOUR-ALBUMS bug was this method asserting a library
    /// write it may never have made. Failure of the write must NOT abort the provisional
    /// add (the in-app add stands on its own, offline included), but it must be truthful.
    @discardableResult
    func discoverAdd(_ hit: DiscoverHit,
                     library: (any MusicLibraryContributor)? = nil) async -> AppleMusicLibraryWriteOutcome {
        let write = await Self.attemptLibraryWrite(library) {
            try await $0.addSongToLibrary(storeID: hit.appleMusicId)
        }
        await discoverAddRip(hit)
        // Eventual consistency: once the server has ACCEPTED the request (or already holds
        // the media), the song is a catalog citizen — collections/burn/stem key off the
        // amrec_ id and retry safely against the queued job.
        // SERVERLESS (public-user audit fix): with NO import server configured the add is
        // STILL a catalog citizen — the entry carries its Apple Music catalog id, so it
        // streams via the user's subscription; only the rip capture isn't owed.
        if (jobs[hit.songId].map { $0.phase != .error } ?? false)
            || manifest[hit.songId] != nil
            || !hasServer {
            discoverAdds?.add(songId: hit.songId, appleMusicId: hit.appleMusicId,
                              title: hit.title, artist: hit.artist, album: hit.album,
                              artworkUrl: hit.artworkUrl ?? hit.albumArtworkUrl,
                              durationMs: hit.durationMs,
                              // The album IDENTITY (not just its name) is what makes the added
                              // song's album tappable — see DiscoverHit's note. A song-scope add
                              // records NO provisional album row (albumId stays nil): the album
                              // screen for it is the PREVIEW, reached via albumAppleMusicId.
                              albumAppleMusicId: hit.albumAppleMusicId,
                              albumArtworkUrl: hit.albumArtworkUrl,
                              trackNumber: hit.trackNumber, discNumber: hit.discNumber,
                              year: hit.year, explicit: hit.explicit,
                              libraryWrite: write.storageToken)
        }
        surfaceLibraryWriteOutcome(write, noun: "song", hadLibrary: library != nil)
        return write
    }

    /// The import-request half of `discoverAdd` (split so tests can drive it without a
    /// library contributor).
    private func discoverAddRip(_ hit: DiscoverHit) async {
        let outcome = await requestRip(songId: hit.songId, title: hit.title, artist: hit.artist,
                                       appleMusicId: hit.appleMusicId, lengthMs: hit.durationMs)
        switch outcome {
        case .ready:
            await refreshManifest()
        case .queued, .inflight:
            if let jobId = jobs[hit.songId]?.jobId { pollToReady(songId: hit.songId, jobId: jobId) }
        case .noServer:
            // NOT an error anymore (public-user audit fix): a serverless add is legitimate —
            // the caller records the streamable catalog entry; there is simply no rip to queue.
            break
        case .unknown, .failed:
            discoverError = "Add failed — the import server didn’t accept the request."
        }
    }

    // MARK: Discover — Apple Music ALBUM search + add (entity=album / per-track fan-out)

    /// One `GET /search?entity=album` result: an Apple Music catalog ALBUM hit — metadata
    /// only. `appleMusicId` is the iTunes collectionId; `albumId` is the provisional catalog
    /// album id (`amrec_album_<collectionId>`) the add flow synthesizes. No ripped/url: an
    /// album is a bag of per-track `amrec_` rips, tracked per song, not per album.
    struct DiscoverAlbumHit: Decodable, Identifiable, Equatable {
        var appleMusicId: String
        var albumId: String
        var title: String
        var artist: String
        var artworkUrl: String? = nil
        var trackCount: Int? = nil
        var year: Int? = nil
        /// Apple Music deep link (`collectionViewUrl`) — the macOS "add" fallback opens this.
        var url: String? = nil
        var id: String { albumId }
    }

    private struct DiscoverAlbumResponse: Decodable { var results: [DiscoverAlbumHit] }


    /// One track from `GET /album-tracks` — the subscription-free expansion source. The
    /// server returns tracks already ordered by (discNumber, trackNumber); `discNumber` is
    /// carried for faithfulness (multi-disc albums), though the app consumes server order.
    struct AlbumTrack: Decodable, Equatable {
        var id: String
        var title: String
        var artist: String
        var discNumber: Int? = nil
        var trackNumber: Int? = nil
        var durationMs: Int? = nil
    }

    /// `GET /album-tracks` envelope. `album` is OPTIONAL: the server started returning the
    /// collection row alongside the tracks so a PREVIEW can be built from an id alone
    /// (subscription-free tier 2); a server that predates it simply omits the key.
    private struct AlbumTracksResponse: Decodable {
        var tracks: [AlbumTrack]
        var album: DiscoverAlbumHit? = nil
    }

    /// One `/album-tracks` round trip, both halves. The preview screen needs the album row
    /// AND its tracks, and asking twice would double the latency for no reason.
    struct AlbumExpansion: Equatable {
        var album: DiscoverAlbumHit?
        var tracks: [AlbumTrack]
        static let empty = AlbumExpansion(album: nil, tracks: [])
    }

    /// Search the Apple Music catalog for ALBUMS via `/search?entity=album`. Same error
    /// doctrine as `discoverSearch` (returns [] + sets `discoverError`, never throws).
    func discoverSearchAlbums(_ query: String, limit: Int = 25) async -> [DiscoverAlbumHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { discoverError = nil; return [] }
        guard hasServer else {
            // Serverless is a benign skip for the metadata search — MusicKit covers Discover
            // search + AM-library add (public-user audit fix). Clear the error so a genuine
            // zero-hit result reads "No matches", not "No import server".
            discoverError = nil
            return []
        }
        guard var comps = URLComponents(string: "\(serverUrl)/search") else {
            discoverError = "Invalid import server URL (Settings ▸ Import server)."
            return []
        }
        comps.queryItems = [URLQueryItem(name: "q", value: q),
                            URLQueryItem(name: "entity", value: "album"),
                            URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps.url else {
            discoverError = "Invalid import server URL (Settings ▸ Import server)."
            return []
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        applyAuth(&req, token: token)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { discoverError = "Search failed."; return [] }
            if http.statusCode == 401 || http.statusCode == 403 {
                discoverError = "The import server rejected the request — check Settings ▸ Import server token."
                return []
            }
            guard (200..<300).contains(http.statusCode) else {
                discoverError = "Search failed (\(http.statusCode))."; return []
            }
            let hits = try JSONDecoder().decode(DiscoverAlbumResponse.self, from: data).results
            discoverError = nil
            return hits
        } catch {
            discoverError = "Import server unreachable (Settings ▸ Import server)."
            return []
        }
    }

    /// Expand an album into its ordered tracks via `GET /album-tracks?id=<collectionId>` —
    /// the subscription-free fallback used when MusicKit `albumTracks` isn't available.
    /// Returns [] on any failure (the caller decides how to surface an empty expansion).
    func fetchAlbumTracks(collectionId: String) async -> [AlbumTrack] {
        await fetchAlbumExpansion(collectionId: collectionId).tracks
    }

    /// The album ROW alone, by collection id — tier 2 of the album PREVIEW (no Apple Music
    /// subscription needed). nil when there's no server, the lookup fails, or the server is
    /// old enough not to return the collection row.
    func fetchAlbum(collectionId: String) async -> DiscoverAlbumHit? {
        await fetchAlbumExpansion(collectionId: collectionId).album
    }

    /// One request, both halves (see `AlbumExpansion`). Returns `.empty` on any failure —
    /// the callers decide how to surface an empty expansion, exactly as before.
    func fetchAlbumExpansion(collectionId: String) async -> AlbumExpansion {
        let id = collectionId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, hasServer,
              var comps = URLComponents(string: "\(serverUrl)/album-tracks") else { return .empty }
        comps.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = comps.url else { return .empty }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        applyAuth(&req, token: token)
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .empty }
            let decoded = try JSONDecoder().decode(AlbumTracksResponse.self, from: data)
            return AlbumExpansion(album: decoded.album, tracks: decoded.tracks)
        } catch { return .empty }
    }

    /// What an album add owes BEYOND the Apple Music library write. Stated by the CALLER, with
    /// no default, because the two surfaces that add an album mean genuinely different things
    /// and a defaulted parameter is how one of them silently inherited the other's promise.
    ///
    /// BUG (Levi, device, 2026-08-07): "I added the album X by Roy Woods from pocketdj in the new
    /// tile and it is ripping the whole album, I dont think it should do that, it should add the
    /// items to the users apple music library but not rip unless they hit download." The album
    /// PREVIEW screen inherited `AlbumPreviewView`'s ancestry — the Shazam recognizer's
    /// add-then-rip-and-burn screen — so a ＋ that says "Add album to your library" started a
    /// real-time capture of all 12 tracks. Adding and downloading are different promises.
    enum AlbumAddIntent: Equatable {
        /// Library write + catalog citizenship, and NOTHING else. No audio is captured; the
        /// tracks stream through the user's Apple Music subscription until they ask for a copy.
        /// This is what "＋ Add" means on the album preview screen.
        case libraryOnly
        /// Library write + catalog citizenship + a per-track `amrec_` rip fan-out (the DOWNLOAD
        /// intent). The Discover search album row is built around this: its whole trailing UI is
        /// live per-track rip progress (n/m ready), and it has no separate download affordance.
        case andPrepareCopies
    }

    /// "＋ Add" for a Discover ALBUM — three app-side actions:
    ///   1. Add the album to the user's own Apple Music library when this device can write it
    ///      (on macOS `canAddToLibrary` is false — the caller opens the Music.app deep link
    ///      instead, mirroring the Shazam macOS fallback; this method just skips the write).
    ///   2. Expand the album into tracks — MusicKit `albumTracks` when authorized, else the
    ///      subscription-free `/album-tracks` proxy.
    ///   3. Record a PROVISIONAL album (+ each track as a provisional song) in
    ///      `DiscoverAddsStore` so the album + its songs are browsable/collectable NOW.
    /// `intent == .andPrepareCopies` adds a fourth: fan each track out as a per-song `amrec_`
    /// rip through the EXISTING single-flight `requestRip` queue. `.libraryOnly` captures NO
    /// audio — see `AlbumAddIntent`.
    /// Never throws; failures land in `discoverError`. Split out from the view like `discoverAdd`.
    /// Returns the Apple Music library write's REAL outcome (the four-albums bug: this
    /// method used to `try?` the write and then record History as if it had succeeded).
    @discardableResult
    func discoverAddAlbum(_ hit: DiscoverAlbumHit,
                          library: (any MusicLibraryContributor)? = nil,
                          intent: AlbumAddIntent) async -> AppleMusicLibraryWriteOutcome {
        // 1) Library write (non-macOS only — canAddToLibrary is false on macOS), with a
        //    real outcome: skipped (no contributor / platform / unauthorized), failed
        //    (the throw is no longer swallowed), unconfirmed (add returned but the
        //    membership probe couldn't find it), or confirmed. Whatever it is, the
        //    provisional add below still proceeds — the outcome just stops lying.
        let write = await Self.attemptLibraryWrite(library) {
            try await $0.addAlbumToLibrary(storeID: hit.appleMusicId)
        }

        // 2) Expand tracks — MusicKit first (needs auth), else the free proxy. `trackNumber`
        //    / `discNumber` ride along so each provisional song lands with its POSITION on
        //    the album, not just its title (the metadata the detail screen shows).
        var descs: [AlbumTrackDesc] = []
        if let library, library.canContribute {
            let rows = await library.albumTracks(albumStoreID: hit.appleMusicId)
            descs = rows.map { r in
                AlbumTrackDesc(songId: "amrec_\(r.storeID)", title: r.title, artist: r.artist,
                               appleMusicId: r.storeID,
                               lengthMs: r.durationSeconds.map { Int(($0 * 1000).rounded()) },
                               trackNumber: r.trackNumber, discNumber: nil,
                               explicit: r.isExplicit)
            }
        }
        if descs.isEmpty {
            let tracks = await fetchAlbumTracks(collectionId: hit.appleMusicId)
            descs = tracks.map { t in
                AlbumTrackDesc(songId: "amrec_\(t.id)", title: t.title, artist: t.artist,
                               appleMusicId: t.id, lengthMs: t.durationMs,
                               trackNumber: t.trackNumber, discNumber: t.discNumber,
                               explicit: nil)
            }
        }
        guard !descs.isEmpty else {
            discoverError = "Couldn’t read the album’s tracks — try again."
            return write
        }

        // 3) `.andPrepareCopies` ONLY: fan out the per-track rips on the shared queue FIRST,
        //    collecting ONLY the tracks whose rip was ACCEPTED (ready / queued / inflight). A
        //    track the server can't prepare (.noServer / .unknown / .failed) is dropped —
        //    recording it would leave a permanent unplayable row (mirrors discoverAdd's gating).
        //    Nothing is written to the provisional store inside this loop, so the catalog is NOT
        //    rebuilt per track.
        //
        //    `.libraryOnly` requests NOTHING: every expanded track is recorded as-is, exactly
        //    like the serverless branch below — it carries its Apple Music catalog id, so it
        //    streams through the subscription immediately, and the download button prepares a
        //    copy later if the user asks for one.
        var accepted: [DiscoverAddsStore.Entry] = []
        var trackIds: [String] = []
        let addedAt = Date().timeIntervalSince1970 * 1000
        for d in descs {
            if intent == .andPrepareCopies {
                let outcome = await requestRip(songId: d.songId, title: d.title, artist: d.artist,
                                               appleMusicId: d.appleMusicId, lengthMs: d.lengthMs)
                switch outcome {
                case .ready:
                    await refreshManifest()
                case .queued, .inflight:
                    if let jobId = jobs[d.songId]?.jobId { pollToReady(songId: d.songId, jobId: jobId) }
                case .noServer:
                    // SERVERLESS (public-user audit fix): with no import server the track is STILL
                    // recorded — it streams via its Apple Music catalog id; only the rip isn't owed.
                    break
                case .unknown, .failed:
                    continue   // a per-track miss records nothing — no dead row
                }
            }
            trackIds.append(d.songId)
            accepted.append(DiscoverAddsStore.Entry(
                songId: d.songId, appleMusicId: d.appleMusicId, title: d.title, artist: d.artist,
                album: hit.title, artworkUrl: hit.artworkUrl, durationMs: d.lengthMs,
                addedAtMs: addedAt,
                // The album's identity, on EVERY track. `albumId` is the provisional catalog
                // album this batch also records, so each track's detail screen resolves a real
                // `IndexAlbum` and its album hotlink opens the album we just added — the album
                // add used to drop this even though `hit.albumId` was right here in scope.
                albumId: hit.albumId, albumAppleMusicId: hit.appleMusicId,
                albumArtworkUrl: hit.artworkUrl,
                trackNumber: d.trackNumber, discNumber: d.discNumber,
                year: hit.year, explicit: d.explicit))
        }

        // 4) ZERO tracks accepted (no server / all-miss) → record NOTHING: no dead album row,
        //    no dead song rows. Surface why (unless a per-track step already set the reason).
        guard !accepted.isEmpty else {
            if discoverError == nil {
                discoverError = "Add failed — the import server didn’t accept the request."
            }
            return write
        }

        // 5) Record the provisional album + its ACCEPTED track songs in ONE batched inject so
        //    the live catalog rebuilds exactly once for the whole album (FIX: was one rebuild
        //    per track — 13+ synchronous ~90k-row rebuilds on a full album).
        discoverAdds?.addAlbumBatch(albumId: hit.albumId, appleMusicId: hit.appleMusicId,
                                    title: hit.title, artist: hit.artist, trackIds: trackIds,
                                    artworkUrl: hit.artworkUrl, year: hit.year,
                                    trackCount: hit.trackCount ?? trackIds.count, url: hit.url,
                                    // Recorded so the progress capsule knows whether there is
                                    // any capture to wait on — a library-only add settles to
                                    // "In your library" at once instead of spinning on rips
                                    // that were never requested.
                                    preparedCopies: intent == .andPrepareCopies,
                                    // The write outcome rides onto the AlbumEntry (retry gate)
                                    // and the .catalogAdd History event (truthful wording).
                                    libraryWrite: write.storageToken,
                                    songs: accepted)
        surfaceLibraryWriteOutcome(write, noun: "album", hadLibrary: library != nil)
        return write
    }

    // MARK: Discover — the Apple Music LIBRARY-WRITE half, with a REAL outcome

    /// Run the library-write half of a Discover add and REPORT what actually happened.
    /// No `try?` on this path — the four-albums bug was three silent failure modes
    /// (skipped gate, swallowed throw, blind trust in a non-throwing `add`) all being
    /// recorded as success. `attempt` returns the post-write membership confirmation.
    static func attemptLibraryWrite(
        _ library: (any MusicLibraryContributor)?,
        attempt: (any MusicLibraryContributor) async throws -> Bool
    ) async -> AppleMusicLibraryWriteOutcome {
        guard let library else {
            return .skipped(reason: "no Apple Music connection")
        }
        guard library.canAddToLibrary else {
            #if os(macOS)
            // Platform truth, not an error: the caller's open-in-Music fallback covers it.
            return .skipped(reason: "adding isn’t available on Mac — opened in the Music app instead")
            #else
            // iOS/visionOS: canAddToLibrary == canContribute == an authorized MusicKit
            // session. The reason names the heal (the app's existing auth vocabulary).
            return .skipped(reason: "Apple Music access isn’t authorized — enable it in Settings")
            #endif
        }
        do {
            return try await attempt(library) ? .confirmed : .unconfirmed
        } catch {
            return .failed(reason: Self.libraryWriteFailureDetail(error))
        }
    }

    /// MusicKit launders most library-write failures into "An unknown error occurred.",
    /// which is useless for deciding between Sync-Library-off, a stale user token, and a
    /// storefront mismatch. Keep the human sentence, but append the NSError identity —
    /// domain, code, and the underlying chain — which DOES distinguish them
    /// (e.g. ICError -7013 = iCloud Music Library disabled).
    static func libraryWriteFailureDetail(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain)#\(ns.code)"]
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        var hops = 0
        while let u = underlying, hops < 3 {
            parts.append("\(u.domain)#\(u.code)")
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
            hops += 1
        }
        return "\(error.localizedDescription) [\(parts.joined(separator: " ← "))]"
    }

    /// Surface a non-confirmed write in `discoverError` at the point of the tap — but only
    /// where it is genuinely the user's problem to act on:
    ///   • never override an earlier, more fundamental error from the same add;
    ///   • a SKIP with no contributor passed is the caller opting out (tests, platforms
    ///     with no Apple Music) — silent;
    ///   • a SKIP on macOS is the designed open-in-Music fallback — silent.
    private func surfaceLibraryWriteOutcome(_ outcome: AppleMusicLibraryWriteOutcome,
                                            noun: String, hadLibrary: Bool) {
        guard discoverError == nil else { return }
        switch outcome {
        case .confirmed:
            return
        case .skipped:
            #if os(macOS)
            return
            #else
            guard hadLibrary else { return }
            #endif
        case .failed, .unconfirmed:
            break
        }
        discoverError = Self.libraryWriteNotice(outcome, noun: noun)
    }

    /// The user-facing message for a write that didn't land (pure → unit-testable).
    static func libraryWriteNotice(_ outcome: AppleMusicLibraryWriteOutcome, noun: String) -> String? {
        switch outcome {
        case .confirmed:
            return nil
        case .unconfirmed:
            return "Added to PocketDJ, but the \(noun) hasn’t appeared in your Apple Music library yet"
                + " — use “Add to Apple Music again” if it doesn’t show up."
        case let .failed(reason):
            return "Added to PocketDJ, but the Apple Music library add failed: \(reason)"
        case let .skipped(reason):
            return "Added to PocketDJ only — \(reason)."
        }
    }

    /// RETRY the Apple Music library write for an ALREADY-RECORDED provisional album —
    /// the heal for adds whose write failed/was skipped (and for LEGACY entries recorded
    /// before outcomes existed, which can't prove their write ever landed: Levi's four
    /// albums). Re-adding an album already in the library is idempotent on Apple's side.
    /// Updates the stored outcome; a newly CONFIRMED write logs a truthful
    /// "Added … to your library" History event (the log is append-only — the original
    /// annotated event stays as the record of the failure).
    @discardableResult
    func retryAlbumLibraryWrite(albumId: String, appleMusicId: String,
                                library: (any MusicLibraryContributor)?) async -> AppleMusicLibraryWriteOutcome {
        let outcome = await Self.attemptLibraryWrite(library) {
            try await $0.addAlbumToLibrary(storeID: appleMusicId)
        }
        discoverAdds?.recordAlbumLibraryWrite(albumId: albumId, token: outcome.storageToken)
        discoverError = nil
        surfaceLibraryWriteOutcome(outcome, noun: "album", hadLibrary: library != nil)
        return outcome
    }

    /// One expanded album track, from either expansion tier (MusicKit or the `/album-tracks`
    /// proxy). A named struct rather than a tuple so the two tiers can't silently drift.
    private struct AlbumTrackDesc {
        var songId: String
        var title: String
        var artist: String
        var appleMusicId: String
        var lengthMs: Int?
        var trackNumber: Int?
        var discNumber: Int?
        var explicit: Bool?
    }

    /// Refresh a single song's job from `/jobs/<id>` (used by the recognizer rip→burn poll
    /// so a server-side failure short-circuits instead of waiting out the timeout).
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
        // Spec §8 — collections may carry studio ids (samples/loops/patterns ride the same
        // string arrays); fence them out BEFORE the POST so the batch body never leaves the
        // device with one. The consumer boundary (songIds resolvers) excludes them too —
        // this is the belt-AND-suspenders layer, mirrored server-side in rip-server.mjs.
        let kept = Self.excludingStudioIds(songIds)
        if kept.count != songIds.count {
            dlog("ripCollection: skipped \(songIds.count - kept.count) studio id(s) — studio items never rip (spec §8)")
        }
        let ids = orderedUnique(kept)
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
    /// still-queued matching jobs (+ their durable queue files) and KILLS the in-flight worker
    /// for a currently-running match, marking each canceled. Idempotent — a second call
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

    // MARK: Stemify — separate a song (or collection) into stems on the import server

    /// Phases that mean a stem job is already working (queued / ripping-first / separating).
    nonisolated private static let stemInFlightPhases: Set<StemPhase> = [.queued, .ripping, .stemming]

    /// FIRE-AND-FORGET Stemify request for ONE song. Idempotent at three layers (mirrors
    /// `requestRipIfNeeded`): already-stemmed / in-flight job / requesting this process → no
    /// network; the server's manifest skip + per-song single-flight is the cross-process
    /// backstop. Stores the returned job and (if it's still working) polls to completion in a
    /// detached task so the row flips to "stemmed" without blocking the caller. Never throws.
    func stemify(_ songId: String) async {
        // Spec §8 — a studio id NEVER stems (the server would rip-first, i.e. live-search
        // a garbage title). Fire-and-forget path: silent guard-return, one log line.
        if fencedStudioId(songId, path: "stemify") { return }
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
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Fire-and-forget, but never INVISIBLE: a refused stemify (e.g. the old
                // adhoc-eviction 404) must leave a trace for Settings ▸ Debug / Console.
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog("stemify \(songId) refused: HTTP \(code)")
                return
            }
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

    /// Stem DEVICE-LOCAL audio the catalog has never seen (the Demuxer's imported files and
    /// performance media): STREAM the file to the import server's `/stemify-custom`, await the
    /// Demucs job, and return the four public-S3 stem URLs. Deliberately NOT behind the
    /// studio-id fence — that fence stops /stemify's rip chain (live-searching a garbage
    /// title); here the audio is uploaded, so studio ids are exactly the intended clients.
    /// Returns nil on any failure (no server / upload rejected / job error / timeout).
    func stemifyCustom(id: String, fileURL: URL) async -> [String: URL]? {
        guard hasServer else { return nil }
        let base = serverUrl, tok = token
        var comps = URLComponents(string: "\(base)/stemify-custom")
        comps?.queryItems = [URLQueryItem(name: "id", value: id),
                             URLQueryItem(name: "ext", value: fileURL.pathExtension.lowercased())]
        guard let url = comps?.url else { return nil }
        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        post.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        applyAuth(&post, token: tok)
        guard let (data, response) = try? await session.upload(for: post, fromFile: fileURL),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let view = try? JSONDecoder().decode(StemJob.self, from: data) else { return nil }
        if view.phase == .ready, let keys = view.stems { return Self.urls(fromKeys: keys, ripsBase: ripsBase) }
        if view.phase == .error || view.phase == .ineligible { return nil }
        guard let jobId = view.jobId else { return nil }
        // Poll to a terminal phase (the pollStemReady cadence; custom jobs skip the manifest).
        let deadline = Date().addingTimeInterval(4 * 60 * 60)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var req = URLRequest(url: URL(string: "\(base)/jobs/\(jobId)")!)
            applyAuth(&req, token: tok)
            guard let (d, r) = try? await session.data(for: req),
                  let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode),
                  let v = try? JSONDecoder().decode(StemJob.self, from: d) else { continue }
            switch v.phase {
            case .ready:
                guard let keys = v.stems else { return nil }
                return Self.urls(fromKeys: keys, ripsBase: ripsBase)
            case .error, .ineligible: return nil
            default: break   // queued / stemming — keep polling
            }
        }
        return nil
    }

    private nonisolated static func urls(fromKeys keys: [String: String], ripsBase: URL) -> [String: URL] {
        keys.mapValues { ripsBase.appendingPathComponent($0) }
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
        // Spec §8 — same studio-id fence as `ripCollection` (stemify rip-firsts a missing
        // song, so a leaked studio id is exactly as dangerous here).
        let kept = Self.excludingStudioIds(songIds)
        if kept.count != songIds.count {
            dlog("stemifyCollection: skipped \(songIds.count - kept.count) studio id(s) — studio items never stem (spec §8)")
        }
        let ids = Self.orderedUnique(kept)
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
        // Per-user identity rides alongside the shared bearer on every rip-server call.
        PDJIdentityHeaders.apply(to: &request, profileId: profileIdProvider())
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

// ============================================================================
// MARK: - Discover album ⇄ catalog album reference
// ============================================================================

extension RipsStore.DiscoverAlbumHit {
    /// Build the add-flow's hit from a catalog album REFERENCE. Hoisted out of
    /// `DiscoverAlbumSearchModel.hit(from:)` (which now calls this) so the album PREVIEW
    /// screen's giant ＋ and the Discover ▸ Albums row's ＋ synthesize the SAME provisional
    /// id (`amrec_album_<collectionId>`) from the same fields. If the two ever drifted,
    /// "add" from one surface would mint a DIFFERENT album than the other and neither would
    /// recognise the other's result as already-added.
    ///
    /// Lives in an extension, not the struct body: an `init` declared inside the declaration
    /// would suppress the synthesized memberwise init the decoder + every call site rely on.
    init(ref: AppleMusicAlbumRef, trackCount: Int? = nil) {
        self.init(appleMusicId: ref.storeID,
                  albumId: "amrec_album_\(ref.storeID)",
                  title: ref.title,
                  artist: ref.artist,
                  artworkUrl: ref.artworkURL?.absoluteString,
                  trackCount: trackCount,
                  year: ref.year,
                  url: ref.url?.absoluteString)
    }

    /// The reverse mapping — a subscription-free (`/search?entity=album` or `/album-tracks`)
    /// album row rendered as the same `AppleMusicAlbumRef` value the preview screen and the
    /// recognizer flow both speak. This is what lets a NON-subscriber reach the album preview.
    var albumRef: AppleMusicAlbumRef {
        AppleMusicAlbumRef(storeID: appleMusicId,
                           title: title,
                           artist: artist,
                           year: year,
                           artworkURL: artworkUrl.flatMap(URL.init(string:)),
                           url: url.flatMap(URL.init(string:)))
    }
}
