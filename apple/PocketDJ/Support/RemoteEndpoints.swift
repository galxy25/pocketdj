import Foundation

/// REMOTE ENDPOINT CONFIG (docs/design/remote-endpoints.md) — lets the backend be flipped between
/// AWS accounts (blue 011183829623 ↔ green 623170744161) WITHOUT an app release.
///
/// One JSON document, schema v1, fetched from a stable, account-independent URL on our own
/// domain (`EndpointResolver.remoteURL`):
///
///     {"v":1,"env":"blue","endpoints":{"catalogBase":"https://…", …},"aliases":{…}}
///
/// Resolution order: last-good fetched document (persisted) → compiled-in defaults (today's blue
/// values). A fetched document replaces the active one ONLY if it validates (`decode`): `v == 1`,
/// non-empty `env`, every required key present, every URL https on an allowlisted host. Anything
/// else is ignored and the current config stays. The fetch never blocks launch.
///
/// Every call site reads `Config.<x>` → `EndpointResolver.shared.url(_:)` at REQUEST time, so a
/// new config applies to the next request; in-flight work (a download already resumed, a sync job
/// already polling) keeps the URL it started with and is never torn down.
///
/// Kept in lock-step with the PWA (`src/config/endpointSchema.ts`, the canonical rules + the
/// deploy-time validator) and Android (`RemoteEndpoints.kt`).
enum EndpointKey: String, CaseIterable, Sendable {
    /// Prod CloudFront: catalog indexes, `/art`, `/lyrics`, `timbre.json`, `favorites-seed.json`.
    case catalogBase
    /// Dev CloudFront (only when `Config.environment == .dev`).
    case catalogBaseDev
    /// Public rips bucket (`rips/manifest.json`, `rips/<id>.mp3`, instrument packs).
    case ripsBase
    /// API Gateway in front of `pocketdj-am-playlist-sync`.
    case amPlaylistSyncBase
    /// API Gateway in front of `pocketdj-rec-engine`.
    case recEngineBase
    /// Listening pockets (today an alias of `recEngineBase` — same HTTP API, `/pockets`).
    case listeningPocketsBase
    /// Private diag-log bucket (`DiagLog`, SigV4 PutObject on `diag/*`).
    case diagLogsBase
    /// `search-config.json` — names the OpenSearch host (itself already remote-configured).
    case searchConfigURL

    static let required: [EndpointKey] = [.catalogBase, .ripsBase, .amPlaylistSyncBase,
                                           .recEngineBase, .diagLogsBase]
}

/// A validated schema-v1 document. Optional keys are DERIVED from the same document when absent
/// (never from the compiled-in blue values — a green doc must never half-fall-back to blue).
struct EndpointConfig: Equatable, Sendable {
    static let schemaVersion = 1

    let env: String
    let endpoints: [EndpointKey: URL]
    /// Extra hosts whose PERSISTED catalog URLs (Settings ▸ Sources) rebase onto this doc.
    let catalogAliases: Set<String>
    let catalogDevAliases: Set<String>

    func url(_ key: EndpointKey) -> URL {
        if let u = endpoints[key] { return u }
        switch key {
        case .catalogBaseDev:       return url(.catalogBase)
        case .listeningPocketsBase: return url(.recEngineBase)
        case .searchConfigURL:      return url(.catalogBase).appendingPathComponent("search-config.json")
        default:                    return EndpointConfig.compiledIn.endpoints[key]!   // unreachable: required
        }
    }

    /// Today's values (blue, 011183829623). Must equal `config/endpoints.blue.json` (a test pins it).
    static let compiledIn = EndpointConfig(
        env: "blue",
        endpoints: [
            .catalogBase: URL(string: "https://d2p4cubg6se03u.cloudfront.net")!,
            .catalogBaseDev: URL(string: "https://djictbz9w796r.cloudfront.net")!,
            .ripsBase: URL(string: "https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com")!,
            .amPlaylistSyncBase: URL(string: "https://ynwdaa8vh2.execute-api.us-west-2.amazonaws.com")!,
            .recEngineBase: URL(string: "https://n5ordrwfe9.execute-api.us-west-2.amazonaws.com")!,
            .listeningPocketsBase: URL(string: "https://n5ordrwfe9.execute-api.us-west-2.amazonaws.com")!,
            .diagLogsBase: URL(string: "https://pocketdj-logs-011183829623.s3.us-west-2.amazonaws.com")!,
            .searchConfigURL: URL(string: "https://d2p4cubg6se03u.cloudfront.net/search-config.json")!,
        ],
        catalogAliases: [], catalogDevAliases: [])

    // MARK: Validation

    enum Rejection: Error, Equatable {
        case notJSON, unsupportedVersion, missingEnv, missingEndpoints
        case missingKey(String), rejectedURL(String)
    }

    /// Host allowlist: pocket-dj.com + *.pocket-dj.com · *.cloudfront.net ·
    /// <id>.execute-api.us-west-2.amazonaws.com · pocketdj-*.s3.us-west-2.amazonaws.com.
    static func isAllowedHost(_ raw: String) -> Bool {
        let h = raw.lowercased()
        func matches(_ pattern: String) -> Bool {
            h.range(of: pattern, options: .regularExpression) != nil
        }
        if h == "pocket-dj.com" || matches(#"^[a-z0-9-]+(\.[a-z0-9-]+)*\.pocket-dj\.com$"#) { return true }
        if matches(#"^[a-z0-9]+\.cloudfront\.net$"#) { return true }
        if matches(#"^[a-z0-9]+\.execute-api\.us-west-2\.amazonaws\.com$"#) { return true }
        if matches(#"^pocketdj-[a-z0-9-]+\.s3\.us-west-2\.amazonaws\.com$"#) { return true }
        return false
    }

    /// https + allowlisted host, no credentials/port/query/fragment; trailing slash trimmed.
    static func normalize(_ raw: Any?) -> URL? {
        guard let s = raw as? String, !s.isEmpty,
              let c = URLComponents(string: s),
              c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, isAllowedHost(host),
              c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil
        else { return nil }
        var trimmed = s
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }

    static func decode(_ data: Data) -> Result<EndpointConfig, Rejection> {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let doc = obj as? [String: Any] else { return .failure(.notJSON) }
        guard (doc["v"] as? NSNumber)?.intValue == schemaVersion,
              !(doc["v"] is Bool) else { return .failure(.unsupportedVersion) }
        guard let envRaw = doc["env"] as? String,
              case let env = envRaw.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty
        else { return .failure(.missingEnv) }
        guard let eps = doc["endpoints"] as? [String: Any] else { return .failure(.missingEndpoints) }
        var out: [EndpointKey: URL] = [:]
        for key in EndpointKey.allCases {
            guard let raw = eps[key.rawValue] else {
                if EndpointKey.required.contains(key) { return .failure(.missingKey(key.rawValue)) }
                continue
            }
            guard let u = normalize(raw) else { return .failure(.rejectedURL(key.rawValue)) }
            out[key] = u
        }
        let aliases = doc["aliases"] as? [String: Any] ?? [:]
        func hosts(_ k: String) -> Set<String> {
            Set((aliases[k] as? [Any] ?? []).compactMap { ($0 as? String)?.lowercased() }.filter(isAllowedHost))
        }
        return .success(EndpointConfig(env: env, endpoints: out,
                                       catalogAliases: hosts("catalogBase"),
                                       catalogDevAliases: hosts("catalogBaseDev")))
    }
}

/// Where the active config came from — surfaced in the diag log + Settings ▸ Debug.
enum EndpointSource: String, Sendable {
    case compiledIn = "compiled-in", cached, remote
}

/// Thread-safe (lock-guarded, not actor-isolated) so `Config`'s synchronous accessors work from
/// any context — nonisolated statics, background URLSession delegates, @MainActor views.
final class EndpointResolver: @unchecked Sendable {
    /// The stable, account-independent config URL: the prod PWA host on our own domain (served
    /// from the prod web bucket by `scripts/deploy.sh`; the `pocket-dj.com` zone moves WITH the
    /// account, so this URL survives the migration). See docs/design/remote-endpoints.md.
    static let remoteURL = URL(string: "https://app.pocket-dj.com/config/endpoints.json")!
    /// Foreground refetches are throttled to one per this window (launch always fetches).
    static let minRefreshInterval: TimeInterval = 15 * 60

    typealias Fetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    /// The process-wide resolver. Test hosts get an in-memory, compiled-in-only resolver that
    /// never touches the network or the persisted cache (and tests swap `Config.endpoints`).
    static let shared: EndpointResolver = {
        let isTestHost = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil
        return isTestHost ? EndpointResolver(cacheURL: nil, fetcher: nil)
                          : EndpointResolver(cacheURL: defaultCacheURL())
    }()

    private let lock = NSLock()
    private var _config: EndpointConfig
    private var _source: EndpointSource
    private var _generation = 0
    private var _lastFetchAt: Date?
    private var _lastOutcome = "not fetched"
    /// Every catalog host any accepted config used (persisted) — so a source URL saved while on
    /// green still rebases after flipping back to blue.
    private var _seenCatalogHosts: Set<String> = []
    private var _seenCatalogDevHosts: Set<String> = []
    private var inflight: Task<Bool, Never>?

    let cacheURL: URL?
    private let fetcher: Fetcher?

    init(cacheURL: URL?, fetcher: Fetcher? = EndpointResolver.defaultFetch) {
        self.cacheURL = cacheURL
        self.fetcher = fetcher
        _config = .compiledIn
        _source = .compiledIn
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CacheFile.self, from: data),
           case .success(let cfg) = EndpointConfig.decode(Data(cached.doc.utf8)) {
            _config = cfg
            _source = .cached
            _seenCatalogHosts = Set(cached.seenCatalogHosts ?? [])
            _seenCatalogDevHosts = Set(cached.seenCatalogDevHosts ?? [])
        }
    }

    /// Test/seam initializer: start from an explicit config.
    convenience init(config: EndpointConfig, source: EndpointSource = .remote) {
        self.init(cacheURL: nil, fetcher: nil)
        lock.lock(); _config = config; _source = source; lock.unlock()
    }

    // MARK: Reads

    var config: EndpointConfig { lock.lock(); defer { lock.unlock() }; return _config }
    var source: EndpointSource { lock.lock(); defer { lock.unlock() }; return _source }
    /// Bumps every time the active config CHANGES — memoized consumers (search config) re-read.
    var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }
    var lastOutcome: String { lock.lock(); defer { lock.unlock() }; return _lastOutcome }
    var lastFetchAt: Date? { lock.lock(); defer { lock.unlock() }; return _lastFetchAt }

    func url(_ key: EndpointKey) -> URL { config.url(key) }

    /// `env=blue source=cached fetch=accepted` — the diag/debug one-liner.
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "env=\(_config.env) source=\(_source.rawValue) fetch=\(_lastOutcome)"
    }

    // MARK: Catalog-URL rebasing

    /// Persisted absolute catalog URLs (Settings ▸ Sources stores `…/current-index.json` with the
    /// host baked in) must follow a flip. A URL whose host is a KNOWN catalog host — compiled-in
    /// blue, any doc alias, or any catalog host a previously accepted config used — is rebased
    /// onto the live catalog base of the same tier (prod/dev). Anything else (a user's custom
    /// source) is returned untouched.
    func rebasedCatalogURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased() else { return url }
        lock.lock()
        let cfg = _config
        let prodHosts = Set([EndpointConfig.compiledIn.url(.catalogBase).host!.lowercased()])
            .union(cfg.catalogAliases).union(_seenCatalogHosts)
        let devHosts = Set([EndpointConfig.compiledIn.url(.catalogBaseDev).host!.lowercased()])
            .union(cfg.catalogDevAliases).union(_seenCatalogDevHosts)
        lock.unlock()
        let target: URL
        if prodHosts.contains(host) { target = cfg.url(.catalogBase) }
        else if devHosts.contains(host) { target = cfg.url(.catalogBaseDev) }
        else { return url }
        if target.host?.lowercased() == host { return url }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let t = URLComponents(url: target, resolvingAgainstBaseURL: false)
        c?.scheme = t?.scheme
        c?.host = t?.host
        c?.port = nil
        let prefix = t?.path ?? ""
        c?.path = (prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix) + (c?.path ?? "")
        return c?.url ?? url
    }

    // MARK: Apply / fetch

    /// Validate + apply a document. On success it is persisted as the new last-good and becomes
    /// the active config (`source = .remote`). Returns whether the ACTIVE config changed.
    @discardableResult
    func apply(_ data: Data) -> Result<Bool, EndpointConfig.Rejection> {
        switch EndpointConfig.decode(data) {
        case .failure(let why):
            lock.lock(); _lastOutcome = "rejected (\(why))"; lock.unlock()
            return .failure(why)
        case .success(let cfg):
            lock.lock()
            let changed = cfg != _config
            _config = cfg
            _source = .remote
            _lastOutcome = "accepted"
            if changed { _generation += 1 }
            for h in [cfg.url(.catalogBase).host, EndpointConfig.compiledIn.url(.catalogBase).host] {
                if let h { _seenCatalogHosts.insert(h.lowercased()) }
            }
            for h in [cfg.url(.catalogBaseDev).host, EndpointConfig.compiledIn.url(.catalogBaseDev).host] {
                if let h { _seenCatalogDevHosts.insert(h.lowercased()) }
            }
            let file = CacheFile(doc: String(decoding: data, as: UTF8.self),
                                 seenCatalogHosts: _seenCatalogHosts.sorted(),
                                 seenCatalogDevHosts: _seenCatalogDevHosts.sorted())
            lock.unlock()
            persist(file)
            return .success(changed)
        }
    }

    /// Fetch the remote document and apply it if valid. Throttled to `minRefreshInterval` unless
    /// `force`; concurrent callers share one fetch. Never throws; returns whether the active config
    /// changed.
    @discardableResult
    func refresh(force: Bool = false, now: Date = Date()) async -> Bool {
        guard let fetcher else { return false }
        let task: Task<Bool, Never>
        lock.lock()
        if let running = inflight {
            task = running
        } else {
            if !force, let last = _lastFetchAt, now.timeIntervalSince(last) < Self.minRefreshInterval {
                lock.unlock(); return false
            }
            _lastFetchAt = now
            let url = Self.remoteURL
            task = Task { [weak self] in
                guard let self else { return false }
                do {
                    let (data, resp) = try await fetcher(url)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        self.setOutcome("http \(http.statusCode)")
                        return false
                    }
                    // The SPA fallback answers a missing file with index.html (200) — decode rejects it.
                    if case .success(let changed) = self.apply(data) { return changed }
                    return false
                } catch {
                    self.setOutcome("network error")
                    return false
                }
            }
            inflight = task
        }
        lock.unlock()
        let changed = await task.value
        lock.lock(); if inflight == task { inflight = nil }; lock.unlock()
        return changed
    }

    private func setOutcome(_ s: String) { lock.lock(); _lastOutcome = s; lock.unlock() }

    // MARK: Persistence

    private struct CacheFile: Codable {
        /// The raw accepted document (re-validated on load — a tampered cache falls to compiled-in).
        var doc: String
        var seenCatalogHosts: [String]?
        var seenCatalogDevHosts: [String]?
    }

    private func persist(_ file: CacheFile) {
        guard let cacheURL, let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    static func defaultCacheURL() -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("pocketdj-endpoints.json")
    }

    static let defaultFetch: Fetcher = { url in
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: req)
    }
}

extension EndpointResolver {
    /// Launch + foreground hook: fetch (throttled unless `force`) and, when the active backend
    /// changed, write an `[endpoints]` diag line. Fire-and-forget; never blocks the caller.
    @MainActor
    static func refreshAndLog(force: Bool = false) {
        let resolver = Config.endpoints
        Task {
            let changed = await resolver.refresh(force: force)
            if changed || force {
                DiagLog.shared.log("endpoints", "\(changed ? "changed" : "checked") \(resolver.summary)")
            }
        }
    }
}
