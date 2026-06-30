import Foundation
import CryptoKit

/// Fetches and decodes the catalog index from CloudFront (same document the PWA
/// auto-seeds from). On a SUCCESSFUL load the raw bytes are persisted to an explicit
/// on-disk cache (per source URL); if a later load FAILS (no network / server down) the
/// cached index is returned instead — so the app opens with its full catalog OFFLINE.
///
/// Why an explicit file cache and not just `URLCache`: `URLRequest.cachePolicy =
/// .returnCacheDataElseLoad` leans on `URLSession`'s shared `URLCache`, which silently
/// REFUSES to persist responses past its (small, default) capacity — and the catalog index
/// (1,300+ albums) routinely exceeds it, so offline relaunch had nothing to fall back to.
/// A plain file in Application Support has no such cap and survives relaunch deterministically.
struct CatalogService: Sendable {
    var url: URL = Config.indexURL

    /// The HTTP validators for a cached index, stored alongside it so a refresh can ask the
    /// origin "only send a body if it changed" (`If-Modified-Since` / `If-None-Match`).
    struct Validator: Codable, Sendable { var lastModified: String?; var etag: String? }

    /// CONDITIONAL refresh. Sends the stored validators so an UNCHANGED index returns **304 No
    /// Body** (we keep the cache); a CHANGED index returns 200 (we decode + re-cache). On ANY
    /// network/server failure we return the last-good disk cache instead of throwing — the caller
    /// (AppModel) renders from the disk cache instantly anyway, so a refresh can never blank it.
    func loadIndex() async throws -> IndexJSON {
        do {
            var request = URLRequest(url: url)
            // Drive caching ourselves (conditional GET) rather than leaning on URLCache, whose
            // tiny capacity + relaunch-non-persistence + the SPA-HTML-200 gotcha all bit us before.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            if let v = Self.loadValidator(for: url) {
                if let lm = v.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
                if let et = v.etag { request.setValue(et, forHTTPHeaderField: "If-None-Match") }
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            // 304 Not Modified → the cache is current; serve it (must exist, since we only sent a
            // validator we stored next to a cached body).
            if http.statusCode == 304, let cached = Self.loadCachedIndex(for: url) {
                return cached
            }
            guard (200..<300).contains(http.statusCode) else {
                throw URLError(.init(rawValue: http.statusCode == 404 ? URLError.fileDoesNotExist.rawValue
                                                                       : URLError.badServerResponse.rawValue))
            }
            let index = try JSONDecoder().decode(IndexJSON.self, from: data)
            // Persist the raw bytes + validators for an OFFLINE relaunch + the next conditional GET
            // (only after a valid decode, so we never cache a garbage/partial response).
            Self.writeCache(data, for: url,
                            validator: Validator(lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                                                 etag: http.value(forHTTPHeaderField: "ETag")))
            return index
        } catch {
            // OFFLINE / server-down FALLBACK: serve the last good index for this source from
            // disk so the catalog still opens with no network. Re-throw only if there's no cache.
            if let cached = Self.loadCachedIndex(for: url) { return cached }
            throw error
        }
    }

    // MARK: Offline disk cache (per source URL)

    /// The cache directory (`Application Support/catalog-cache/`). A `dir` override is the
    /// unit-test seam (a temp dir), so the round-trip can be tested without Application Support.
    static func cacheDirectory(_ dir: URL? = nil) -> URL? {
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let d = base.appendingPathComponent("catalog-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A deterministic, flat, O(1) cache filename for a source URL — a SHA-256 of the URL
    /// string (NOT Swift's per-process-seeded `Hasher`, which wouldn't survive relaunch).
    static func cacheFileURL(for url: URL, in dir: URL? = nil) -> URL? {
        guard let directory = cacheDirectory(dir) else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }

    /// Persist the raw index bytes for `url` (atomic). Best-effort — a cache-write failure
    /// never fails the load. Optionally persists the HTTP `validator` (Last-Modified / ETag)
    /// in a sibling `.meta.json` for the next conditional GET.
    static func writeCache(_ data: Data, for url: URL, in dir: URL? = nil, validator: Validator? = nil) {
        guard let dest = cacheFileURL(for: url, in: dir) else { return }
        try? data.write(to: dest, options: .atomic)
        guard let validator, let meta = metaFileURL(for: url, in: dir),
              let encoded = try? JSONEncoder().encode(validator) else { return }
        try? encoded.write(to: meta, options: .atomic)
    }

    /// Sibling validator file for a cached source URL (`<sha256>.meta.json`).
    static func metaFileURL(for url: URL, in dir: URL? = nil) -> URL? {
        cacheFileURL(for: url, in: dir)?.deletingPathExtension().appendingPathExtension("meta.json")
    }

    /// The stored HTTP validators for `url`'s cache, or nil when absent (so the first refresh
    /// after this ships is an unconditional GET that then records them).
    static func loadValidator(for url: URL, in dir: URL? = nil) -> Validator? {
        guard let meta = metaFileURL(for: url, in: dir), let data = try? Data(contentsOf: meta) else { return nil }
        return try? JSONDecoder().decode(Validator.self, from: data)
    }

    /// Load + decode the cached index for `url`, or nil when there's no (valid) cache.
    static func loadCachedIndex(for url: URL, in dir: URL? = nil) -> IndexJSON? {
        guard let src = cacheFileURL(for: url, in: dir),
              let data = try? Data(contentsOf: src) else { return nil }
        return try? JSONDecoder().decode(IndexJSON.self, from: data)
    }
}
