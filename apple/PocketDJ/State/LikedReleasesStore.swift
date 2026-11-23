import Foundation
import Observation

/// The per-install metadata CACHE behind "Liked — not added" (`liked-releases.json`).
///
/// ── A CACHE, NOT STATE ───────────────────────────────────────────────────────────────────────
/// What he liked lives in `RecFeedbackStore` (synced) and what was added in `DiscoverAddsStore`
/// (synced). This file only remembers enough about each liked release to draw its row and add it
/// later — title, artist, art, date — plus the last add attempt. The feed cache can't supply
/// that: it keeps ONE release per artist, so a liked record drops out of it the moment its artist
/// puts out something newer. Deleting this file loses nothing: hydration
/// (`NewReleaseLikeAdder.hydrateMissing`) rebuilds every row from the verdict ids. So it is
/// deliberately NOT registered with CloudSync — two devices each rebuilding the same cache from
/// the same verdicts is cheaper and safer than merging attempt states across devices.
///
/// The JSON shape is identical on Android (`LikedReleasesStore.kt`), so fixtures can be shared.
/// Decoding is lenient: a bad row is skipped, never the file.
@MainActor
@Observable
final class LikedReleasesStore {

    struct Document: Codable {
        var schemaVersion: Int = 1
        var releases: [LikedRelease] = []

        init(releases: [LikedRelease] = []) { self.releases = releases }

        enum CodingKeys: String, CodingKey { case schemaVersion, releases }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            releases = ((try? c.decode([Lenient].self, forKey: .releases)) ?? []).compactMap(\.value)
        }

        private struct Lenient: Decodable {
            let value: LikedRelease?
            init(from decoder: Decoder) throws { value = try? LikedRelease(from: decoder) }
        }
    }

    /// storeId → release.
    private(set) var releases: [String: LikedRelease] = [:]
    /// Bumped on every change, so a view can observe one integer.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    nonisolated static let saveDebounce: Duration = .milliseconds(400)

    init(fileURL: URL = LikedReleasesStore.defaultURL()) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil,
                                                create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("liked-releases.json")
    }

    /// Under UI tests: an isolated, freshly-cleared file, so a run never reads yesterday's likes.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-uitest-liked-releases.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    // MARK: write

    /// Insert or refresh metadata, KEEPING the existing attempt and like time when the incoming
    /// row doesn't carry them (a re-like must not erase a failed attempt's message).
    func upsert(_ r: LikedRelease) {
        var merged = r
        if let old = releases[r.storeId] {
            if merged.attempt == nil { merged.attempt = old.attempt }
            if merged.likedAtMs == nil { merged.likedAtMs = old.likedAtMs }
            if merged.tombstoned == nil { merged.tombstoned = old.tombstoned }
        }
        guard releases[r.storeId] != merged else { return }
        releases[r.storeId] = merged
        changed()
    }

    func upsert(_ list: [LikedRelease]) {
        var any = false
        for r in list {
            var merged = r
            if let old = releases[r.storeId] {
                if merged.attempt == nil { merged.attempt = old.attempt }
                if merged.likedAtMs == nil { merged.likedAtMs = old.likedAtMs }
            }
            if releases[r.storeId] != merged { releases[r.storeId] = merged; any = true }
        }
        if any { changed() }
    }

    func setAttempt(_ attempt: LikeAddAttempt?, for storeId: String) {
        guard var r = releases[storeId], r.attempt != attempt else { return }
        r.attempt = attempt
        releases[storeId] = r
        changed()
    }

    /// Drop rows whose verdict is no longer `accepted` (cleared or flipped).
    func prune(keepingAccepted accepted: Set<String>) {
        let drop = releases.keys.filter { !accepted.contains($0) }
        guard !drop.isEmpty else { return }
        for k in drop { releases[k] = nil }
        changed()
    }

    private func changed() {
        revision &+= 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write now (atomic). Also the test seam, so a round-trip needn't wait out the debounce.
    func flush() {
        saveTask?.cancel(); saveTask = nil
        let doc = Document(releases: releases.values.sorted { $0.storeId < $1.storeId })
        guard let data = try? JSONEncoder().encode(doc) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {}
    }

    // MARK: load

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        var map: [String: LikedRelease] = [:]
        for var r in doc.releases {
            // `adding` is never trusted across launches: the process that was adding is gone.
            // `offline` is what the sweep retries, so a crash mid-add heals itself.
            if r.attempt?.state == .adding {
                r.attempt?.state = .offline
                r.attempt?.message = NewReleaseLikeAdder.offlineMessage
            }
            map[r.storeId] = r
        }
        releases = map
    }
}
