import Foundation
import Observation

/// Fetches a song's lyrics from the catalog CDN (`{catalogBase}/lyrics/<songId>.txt`)
/// ON DEMAND — only when a song's detail opens — and caches the text on disk so a
/// re-open is instant + works offline. Mirrors the PWA, which fetches + caches lyrics in
/// IndexedDB the same way. Only songs whose index `lyricsStatus == "found"` have a file;
/// the rest are never fetched.
@MainActor
@Observable
final class LyricsStore {
    /// Fetch raw bytes for a URL. Injected so the cache logic is unit-testable offline; the
    /// default does a real GET and treats any non-2xx response as a miss (so a 404/Access-
    /// Denied body is never cached).
    typealias Fetcher = @MainActor (URL) async throws -> Data

    private let cacheDir: URL?
    private let baseURL: @MainActor () -> URL
    private let fetch: Fetcher
    /// songId → lyrics text. The in-memory tier above the on-disk cache.
    private var memory: [String: String] = [:]

    init(cacheDir: URL? = LyricsStore.defaultCacheDir(),
         baseURL: @escaping @MainActor () -> URL = { Config.catalogBase },
         fetch: @escaping Fetcher = { try await LyricsStore.defaultFetch($0) }) {
        self.cacheDir = cacheDir
        self.baseURL = baseURL
        self.fetch = fetch
    }

    /// `Application Support/lyrics-cache/`. A `dir` override is the unit-test seam.
    nonisolated static func defaultCacheDir(_ dir: URL? = nil) -> URL? {
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let d = base.appendingPathComponent("lyrics-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    nonisolated static func defaultFetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.fileDoesNotExist)
        }
        return data
    }

    /// On-disk filename for a song id. Ids are URL-shaped (`sng_<uuid>`); sanitize the few
    /// path-unsafe characters defensively so any id round-trips to a flat file.
    private func fileURL(_ songId: String) -> URL? {
        guard let cacheDir else { return nil }
        let safe = songId.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        return cacheDir.appendingPathComponent("\(safe).txt")
    }

    /// Lyrics for a song, or nil. Memory → on-disk cache → network (then persisted to both).
    /// Returns nil for any song without a found-lyrics file, or on a network miss. Songs
    /// whose `lyricsStatus` isn't "found" are never fetched.
    func lyrics(for song: IndexSong) async -> String? {
        guard song.lyricsStatus == "found" else { return nil }
        let id = song.id
        if let hit = memory[id] { return hit }
        // On-disk cache (durable + offline).
        if let f = fileURL(id), let data = try? Data(contentsOf: f),
           let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            memory[id] = text
            return text
        }
        // Network — fetch once, then persist for next time.
        let url = baseURL().appendingPathComponent("lyrics").appendingPathComponent("\(id).txt")
        guard let data = try? await fetch(url),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        memory[id] = text
        if let f = fileURL(id) { try? data.write(to: f, options: .atomic) }
        return text
    }
}
