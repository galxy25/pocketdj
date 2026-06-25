import Foundation
import Observation

/// App-side BURN (Feature 2): a SERIAL, one-by-one download queue that persists each
/// song's durable mp3 PLUS a human-readable `.txt` metadata sidecar into app-managed
/// storage, recording each item in a versioned local index — the machine-readable
/// source of truth a FUTURE offline player / live-mixer will enumerate.
///
/// Offline playback and live mixing are explicitly NOT implemented here; this only
/// establishes the download queue + local persistence + sidecar layer they consume.
///
/// Design notes (resolving the reviewer issues baked into the spec):
///   • Files are keyed by songId (digital → `<songId>.mp3`) / albumId (analog →
///     `<albumId>.mp3`, ONE shared file per album), so no Artist-Title collisions and
///     no N duplicate whole-album downloads.
///   • Burn NEVER blocks on the 30-min rip-on-demand path — it downloads ONLY songs
///     already in the manifest (`RipsStore.downloadDataIfCached`); not-yet-ripped songs
///     are reported and optionally enqueued via `RipsStore.ripCollection` for a later pass.
///   • The burn INDEX (pocketdj-burns.json) carries the analyzed bpm/key/camelot/
///     durationMs/startMs actually used (preferring the ManifestEntry over the catalog),
///     so a consumer reads it directly instead of parsing the prose `.txt`.
///   • Mirrors CollectionsStore/EditsStore durable-JSON persistence (atomic save,
///     decode-on-init, PDJ_USE_FIXTURE test seam).
@MainActor
@Observable
final class BurnStore {
    /// Per-item lifecycle state.
    enum State: String, Codable { case queued, downloading, ready, error }

    /// One burned (or attempted) track. The MACHINE-READABLE record a future offline
    /// player / live-mixer reads — it carries the analyzed values + the analog seek
    /// offset, so consumers never parse the prose sidecar.
    struct BurnItem: Codable, Identifiable, Equatable {
        var songId: String
        var title: String
        var artist: String
        /// `<songId>.mp3` (digital) or `<albumId>.mp3` (analog, shared across the album).
        var audioFileName: String
        /// `<songId>.txt`.
        var sidecarFileName: String
        /// "analog" | "digital".
        var source: String
        var bpm: Double?
        var musicalKey: String?
        var camelot: String?
        var durationMs: Int?
        /// Analog: the seek offset within the shared album mp3 (nil for digital).
        var startMs: Int?
        var bytes: Int
        /// From the ManifestEntry (when present) — staleness check vs. `downloadedAt`.
        var rippedAt: Double?
        var downloadedAt: Double
        var state: State
        var error: String?
        /// Feature 2 (burnt-music FOLDER): whether this item's files were written to the
        /// app-managed Application Support `burns/` dir (true) vs. the user-picked folder
        /// (false). Each item is resolved against the dir it was ACTUALLY written to, so a
        /// later folder switch never mis-resolves or prunes an item against the wrong dir.
        /// Optional for backward-compat decode of older index json — coalesced nil → true
        /// (every pre-feature burn lives in Application Support).
        var wasAppStorage: Bool?

        var id: String { songId }
    }

    /// The persisted, versioned index document.
    struct Document: Codable {
        var schemaVersion: Int = burnSchemaVersion
        var items: [BurnItem] = []
    }

    /// Bulk progress for the collection UI ({done,total,label}); nil when idle.
    struct Progress: Equatable {
        var done: Int
        var total: Int
        var label: String
    }

    /// The outcome of a `burn(...)` run, for the partial-success summary.
    struct BurnResult: Equatable {
        var burned = 0          // newly downloaded + persisted (or already ready)
        var notRipped = 0       // skipped — not in the manifest yet
        var failed = 0          // per-item download/write errors
        var total = 0
        var outOfSpace = false  // disk filled — remaining items aborted
        var folderUnavailable = false // the chosen burnt-music folder couldn't be written
        var stopped = false     // the user pressed STOP — remaining items not attempted
    }

    // MARK: Observed state

    private(set) var items: [String: BurnItem] = [:]
    /// Drives the collection screen's progress UI; nil when no burn is running.
    private(set) var progress: Progress?

    /// Feature 1 (STOP burn): set by `requestStop()`; checked at the TOP of each burn-loop
    /// iteration (never mid-item, so each item is fully written+recorded or never started —
    /// no orphan sidecar). Reset at the start of every `burn(...)` run.
    private(set) var stopRequested = false

    private let fileURL: URL
    /// Catalog lookup wired at launch (mirrors CollectionsStore.app) so the sidecar can
    /// resolve the IndexSong / IndexAlbum for a songId.
    var lookup: ((String) -> (song: IndexSong?, album: IndexAlbum?))?

    /// Feature 2 (burnt-music FOLDER): supplies the security-scoped bookmark for the
    /// user-picked burn folder. `nil` in tests / before wiring → app-storage fallback.
    var settings: SettingsStore?

    private let rips: RipsStore

    /// Feature (backgrounded burning): when set, `burn(...)` hands each song to a BACKGROUND
    /// download task (via the coordinator) that survives suspend, persisting the `.downloading`
    /// item IMMEDIATELY and finalizing each `.ready` item from the delegate callback. When nil
    /// (all existing tests), `burn(...)` uses today's in-process serial loop unchanged.
    let transfers: TransferCoordinator?

    init(rips: RipsStore, transfers: TransferCoordinator? = nil, fileURL: URL = BurnStore.defaultURL()) {
        self.rips = rips
        self.transfers = transfers
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            items = Dictionary(doc.items.map { ($0.songId, $0) }, uniquingKeysWith: { first, _ in first })
        }
        // Wire the coordinator's finalize hooks back to this store (the delegate calls these on
        // the main actor when a background download finishes / fails). `wireTransfers()` also
        // supplies the burn-folder bookmark the nonisolated delegate re-resolves.
        wireTransfers()
    }

    /// Connect the (optional) coordinator's main-actor finalize callbacks to this store, and
    /// give it the burn-folder bookmark accessor. Safe when `transfers == nil`.
    private func wireTransfers() {
        guard let transfers else { return }
        transfers.onBurnFinalized = { [weak self] record, bytes in
            self?.finalizeBurn(record: record, bytes: bytes)
        }
        transfers.onBurnFailed = { [weak self] record, message in
            self?.items[record.songId] = self?.errorItem(
                (id: record.songId, title: record.title, artist: record.artist), message: message)
            self?.save()
        }
        // NOTE: the burn-folder bookmark is NOT exposed to the coordinator via a closure anymore.
        // The delegate runs off the main actor (and may run cold-relaunched before this store
        // exists), so a `@MainActor` closure read would TRAP. Instead `burn(...)` captures the
        // bookmark Data onto each TransferRecord at enqueue time (below), and the delegate
        // resolves the destination purely from `record.burnFolderBookmark` with no main-actor hop.
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-burns.json")
    }

    /// UI tests get an isolated, fresh burn index (mirrors CollectionsStore.launchURL).
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-burns.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private var now: Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: Feature 1 — STOP a running burn

    /// Request the in-flight `burn(...)` serial loop to stop after the current item. The loop
    /// checks this (and `Task.isCancelled`) ONLY at the top of each iteration, so the item
    /// being written when STOP is pressed completes (fully written + recorded) and no orphan
    /// half-written sidecar is left behind. Idempotent.
    func requestStop() {
        stopRequested = true
        // Background path: cancel any in-flight background download tasks for items still
        // downloading (so a Stop during a backgrounded burn actually halts the transfers) +
        // drop those items so they don't linger as `.downloading`.
        if let transfers {
            let pending = items.values.filter { $0.state == .downloading }.map { $0.songId }
            if !pending.isEmpty {
                transfers.cancelAll(songIds: pending)
                for id in pending { items[id] = nil }
                save()
            }
        }
    }

    /// Called by the `TransferCoordinator` (on the main actor) when a background burn download
    /// finishes: the delegate already moved the file + wrote the sidecar, so upsert the `.ready`
    /// BurnItem from the record + persist. Idempotent (a duplicate callback re-writes the same
    /// ready item).
    func finalizeBurn(record: TransferCoordinator.TransferRecord, bytes: Int) {
        items[record.songId] = BurnItem(
            songId: record.songId, title: record.title, artist: record.artist,
            audioFileName: record.audioFileName, sidecarFileName: record.sidecarFileName,
            source: record.source,
            bpm: record.bpm, musicalKey: record.musicalKey, camelot: record.camelot,
            durationMs: record.durationMs, startMs: record.startMs,
            bytes: bytes, rippedAt: record.rippedAt, downloadedAt: now,
            state: .ready, error: nil, wasAppStorage: record.wasAppStorage)
        save()
    }

    // MARK: Feature 2 — burnt-music folder resolution (security-scoped)

    /// Resolve the ACTIVE burn folder: the user-picked security-scoped folder when a bookmark
    /// is set AND it resolves to a writable directory, else the app-managed Application
    /// Support `burns/` dir. Returns the dir + whether security-scoped access was started
    /// (the caller must `stopAccessingSecurityScopedResource()` then) + whether it is the
    /// user folder. Falls back on ANY problem (denied access / unmounted / not writable) so a
    /// burn never writes to an inaccessible path. `allowRePersist` re-creates + re-persists a
    /// stale bookmark (only on the write path; the read path resolves read-only).
    private func resolveBurnFolder(allowRePersist: Bool) -> (url: URL, scoped: Bool, isUserFolder: Bool)? {
        if let data = settings?.burnFolderBookmark {
            var stale = false
            #if os(macOS)
            let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let opts: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(resolvingBookmarkData: data, options: opts,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let ok = url.startAccessingSecurityScopedResource()
                if ok && FileManager.default.isWritableFile(atPath: url.path) {
                    if stale && allowRePersist, let fresh = Self.makeBookmark(for: url) {
                        settings?.burnFolderBookmark = fresh
                        settings?.persist()
                    }
                    return (url, true, true)
                }
                if ok { url.stopAccessingSecurityScopedResource() }   // resolved but unusable
            }
        }
        return (try? RipsStore.burnsDirectory()).map { ($0, false, false) }
    }

    /// Create a security-scoped bookmark for a folder URL (macOS adds `.withSecurityScope`;
    /// iOS uses a plain bookmark). The caller must hold access while creating it.
    nonisolated static func makeBookmark(for url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: .withSecurityScope,
                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData()
        #endif
    }

    /// The base dir a given item's files live in — resolved by the dir it was ACTUALLY
    /// written to (`wasAppStorage`), never assuming the current setting. Returns the dir +
    /// whether security-scoped access was started (caller must stop it). For an app-storage
    /// item this is always Application Support (no scope); for a user-folder item it resolves
    /// the bookmark read-only (falling back to app storage only if the folder is gone).
    private func itemDir(_ item: BurnItem) -> (url: URL, scoped: Bool)? {
        // nil coalesces to true: every pre-feature burn lives in Application Support.
        if item.wasAppStorage ?? true {
            return (try? RipsStore.burnsDirectory()).map { ($0, false) }
        }
        guard let resolved = resolveBurnFolder(allowRePersist: false), resolved.isUserFolder else {
            return nil   // the user folder is gone — the item can't be resolved right now
        }
        return (resolved.url, resolved.scoped)
    }

    // MARK: Future-consumer seam (designed-for, NOT used here)

    /// The persisted audio file URL for a ready item — ONLY when the file still exists
    /// on disk (nil if iOS purged it). A future offline player feeds this (+ `startMs`
    /// for analog) into `PlayerEngine.load`; this store does NOT play anything.
    func localURL(forSong songId: String) -> URL? {
        guard let item = items[songId], item.state == .ready,
              let (dir, scoped) = itemDir(item) else { return nil }
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
        let url = dir.appendingPathComponent(item.audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The analog seek offset (ms) within a shared album mp3 for a ready burned song, so a
    /// player seeks to the song's start inside the whole-album file. nil for digital
    /// (per-song file) burns or songs that aren't burned.
    func startMs(forSong songId: String) -> Int? {
        guard let item = items[songId], item.state == .ready else { return nil }
        return item.startMs
    }

    /// Total bytes burned to disk (eviction-ready: a future cap policy reads this).
    var totalBytes: Int { items.values.filter { $0.state == .ready }.reduce(0) { $0 + $1.bytes } }

    /// Remove a burned item + its files (eviction-ready; not wired to any UI yet).
    func remove(_ songId: String) {
        if let item = items[songId], let (dir, scoped) = itemDir(item) {
            defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
            // The analog album mp3 is shared — only delete it if no other ready item uses it.
            let shared = items.values.contains { $0.songId != songId && $0.audioFileName == item.audioFileName }
            if !shared { try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.audioFileName)) }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.sidecarFileName))
        }
        items[songId] = nil
        save()
    }

    /// Prune index entries whose audio file vanished (iOS purges Application Support
    /// under storage pressure without touching the index). Call at launch.
    func reconcileOnLaunch() {
        var changed = false
        for (songId, item) in items where item.state == .ready {
            // Resolve per-item against the dir it was ACTUALLY written to. If that dir is
            // currently unresolvable (a user folder that's unmounted/ejected), SKIP the item
            // — never prune based on a folder it was never written to (no data destruction).
            guard let (dir, scoped) = itemDir(item) else { continue }
            let url = dir.appendingPathComponent(item.audioFileName)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if scoped { dir.stopAccessingSecurityScopedResource() }
            if !exists { items[songId] = nil; changed = true }
        }
        if changed { save() }
    }

    // MARK: The serial download queue

    /// BURN a collection's songs ONE BY ONE: download each already-ripped song's durable
    /// mp3 + write its `.txt` sidecar, persisting both into app-managed storage and
    /// recording the result in the index. NEVER blocks on a live rip (skips not-yet-ripped
    /// songs). Per-item try/catch → partial success; disk-full aborts the remainder.
    /// Empty input is a no-op.
    @discardableResult
    func burn(_ songs: [(id: String, title: String, artist: String)]) async -> BurnResult {
        stopRequested = false   // Feature 1: fresh STOP signal for this run.
        // Reset the coordinator's run-scoped progress counters so a 2nd burn doesn't show
        // "Burning 4 of 5" (the totals are NOT monotonic across runs).
        transfers?.beginRun()
        let unique = orderedUnique(songs)
        var result = BurnResult(total: unique.count)
        guard !unique.isEmpty else { return result }

        // Feature 2: resolve the active burn folder ONCE for the whole run (user-picked +
        // security-scoped when set, else Application Support). Bracket scoped access around
        // the entire loop; re-persist a stale bookmark on this (write) path.
        guard let folder = resolveBurnFolder(allowRePersist: true) else {
            result.failed = unique.count; return result
        }
        let dir = folder.url
        let isUserFolder = folder.isUserFolder
        defer { if folder.scoped { dir.stopAccessingSecurityScopedResource() } }

        // Background path: capture the user folder's security-scoped bookmark ONCE for this run,
        // to STORE on each TransferRecord. The off-main delegate resolves the destination from
        // this Data (not a @MainActor closure), so a cold-relaunched delegate writes to the right
        // folder without ever touching the main actor. nil for app-storage (the delegate then
        // resolves Application Support directly). We're holding scoped access to `dir` here, so
        // this is the moment the bookmark can be minted.
        let runBookmark: Data? = (isUserFolder && transfers != nil) ? Self.makeBookmark(for: dir) : nil

        // Feature 2: PROBE the folder ONCE with a sentinel write+delete. If it fails, abort
        // with a single clear message (mirroring the out-of-space abort) instead of N
        // per-item errors.
        let sentinel = dir.appendingPathComponent(".pdj-burn-probe-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: sentinel, options: .atomic)
            try? FileManager.default.removeItem(at: sentinel)
        } catch {
            try? FileManager.default.removeItem(at: sentinel)
            result.folderUnavailable = true
            return result
        }

        var done = 0
        for song in unique {
            // Feature 1: STOP / cancel is checked ONLY here (loop top) — never mid-item, so
            // each item is fully written+recorded or never started (no orphan sidecar).
            if stopRequested || Task.isCancelled { result.stopped = true; break }

            progress = Progress(done: done, total: unique.count, label: "\(song.artist) — \(song.title)")
            defer { done += 1 }

            // (1) Idempotency: already burned, file present, right size, not stale → skip.
            // Resolve freshness against the dir the EXISTING item was actually written to.
            if let existing = items[song.id], existing.state == .ready,
               let (exDir, exScoped) = itemDir(existing) {
                let fresh = isFresh(existing, dir: exDir, rippedAt: rips.manifest[song.id]?.rippedAt)
                if exScoped { exDir.stopAccessingSecurityScopedResource() }
                if fresh { result.burned += 1; continue }
            }

            // (2) Not-ripped short-circuit — Burn never blocks on the 30-min ensureURL.
            guard let durableURL = rips.cachedURL(song.id), let entry = rips.manifest[song.id] else {
                let why = rips.hasServer ? "not ripped — Rip first" : "not ripped (no rip server)"
                items[song.id] = errorItem(song, message: why)
                result.notRipped += 1
                continue
            }

            // BACKGROUND PATH: hand the durable mp3 to a background download task that survives
            // suspend. Pre-render the sidecar HERE (on the main actor) so the nonisolated
            // delegate can finish a cold-launch file with no catalog lookup, persist the
            // `.downloading` item IMMEDIATELY (incremental — a relaunch knows what's pending),
            // and DON'T await bytes (the delegate finalizes via `finalizeBurn`).
            if let transfers {
                // CRITIC-A — resolve the catalog lookup BEFORE building the filenames so the
                // descriptive name can use the IndexSong/IndexAlbum.
                let (s, a) = lookup?(song.id) ?? (nil, nil)
                let (audioName, sidecarName) = fileNames(for: song.id, entry: entry, song: s, album: a)
                let sidecar = Self.buildSidecar(songId: song.id, fallback: song, song: s, album: a, entry: entry)
                let record = TransferCoordinator.TransferRecord(
                    taskIdentifier: 0, songId: song.id, kind: .burn,
                    audioFileName: audioName, sidecarFileName: sidecarName, sidecarText: sidecar,
                    wasAppStorage: !isUserFolder, burnFolderBookmark: runBookmark, expectedBytes: nil,
                    manifestKey: entry.key, source: entry.source ?? "digital",
                    bpm: entry.bpm, musicalKey: entry.musicalKey, camelot: entry.camelot,
                    durationMs: entry.durationMs,
                    startMs: entry.source == "analog" ? entry.startMs : nil,
                    rippedAt: entry.rippedAt, title: song.title, artist: song.artist,
                    createdAt: now)
                items[song.id] = BurnItem(
                    songId: song.id, title: song.title, artist: song.artist,
                    audioFileName: audioName, sidecarFileName: sidecarName,
                    source: entry.source ?? "digital",
                    bpm: entry.bpm, musicalKey: entry.musicalKey, camelot: entry.camelot,
                    durationMs: entry.durationMs,
                    startMs: entry.source == "analog" ? entry.startMs : nil,
                    bytes: 0, rippedAt: entry.rippedAt, downloadedAt: now,
                    state: .downloading, error: nil, wasAppStorage: !isUserFolder)
                save()   // incremental persistence — survive relaunch mid-flight
                transfers.enqueueDownload(url: durableURL, token: rips.token, record: record)
                result.burned += 1   // "enqueued" — the overlay tracks completion via the coordinator
                continue
            }

            items[song.id]?.state = .downloading

            do {
                guard let (data, entry) = try await rips.downloadDataIfCached(song) else {
                    // Manifest changed out from under us mid-run — treat as not ripped.
                    items[song.id] = errorItem(song, message: "not ripped — Rip first")
                    result.notRipped += 1
                    continue
                }

                // CRITIC-A — resolve the catalog lookup BEFORE building the filenames so the
                // descriptive name can use the IndexSong/IndexAlbum.
                let (s, a) = lookup?(song.id) ?? (nil, nil)
                let (audioName, sidecarName) = fileNames(for: song.id, entry: entry, song: s, album: a)
                let audioURL = dir.appendingPathComponent(audioName)

                // Analog: the whole-album mp3 is stored ONCE and shared across the album's
                // songs — don't re-download/re-write it if a sibling already wrote it.
                let analogShared = entry.source == "analog" && FileManager.default.fileExists(atPath: audioURL.path)
                if !analogShared {
                    try data.write(to: audioURL, options: .atomic)
                }

                let sidecar = Self.buildSidecar(songId: song.id, fallback: song, song: s, album: a, entry: entry)
                try Data(sidecar.utf8).write(to: dir.appendingPathComponent(sidecarName), options: .atomic)

                items[song.id] = BurnItem(
                    songId: song.id, title: song.title, artist: song.artist,
                    audioFileName: audioName, sidecarFileName: sidecarName,
                    source: entry.source ?? "digital",
                    bpm: entry.bpm, musicalKey: entry.musicalKey, camelot: entry.camelot,
                    durationMs: entry.durationMs,
                    startMs: entry.source == "analog" ? entry.startMs : nil,
                    bytes: data.count, rippedAt: entry.rippedAt, downloadedAt: now,
                    state: .ready, error: nil,
                    wasAppStorage: !isUserFolder)
                result.burned += 1
            } catch let err as NSError where err.code == NSFileWriteOutOfSpaceError {
                // Disk full — every remaining item would fail too. Abort the rest.
                items[song.id] = errorItem(song, message: "out of space")
                result.outOfSpace = true
                result.failed += 1
                break
            } catch {
                items[song.id] = errorItem(song, message: error.localizedDescription)
                result.failed += 1
            }
        }

        save()
        progress = nil
        return result
    }

    // MARK: Helpers

    /// A ready burn is fresh when its audio file exists, is the recorded size (catches a
    /// zero-byte / partial prior write), AND the source rip hasn't been re-ripped since we
    /// downloaded it. `rippedAt` is the manifest entry's epoch-ms rip completion time:
    /// a burn is STALE (=> re-download) when that is newer than the burn's `downloadedAt`.
    /// Backward-compat: when `rippedAt` is nil (older manifest entries / older burns) the
    /// staleness-by-time signal is skipped and only the size check applies.
    private func isFresh(_ item: BurnItem, dir: URL, rippedAt: Double?) -> Bool {
        let url = dir.appendingPathComponent(item.audioFileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size == item.bytes else { return false }
        // Re-ripped after we last burned it → stale (skipped when rippedAt is unknown).
        if let rippedAt, rippedAt > item.downloadedAt { return false }
        return true
    }

    /// CRITIC-A — the burned filenames. The audio name carries a SANITIZED, descriptive
    /// prefix ("Artist-Song-Album-Year-Genre-Camelot-Key-BPM" for digital per-song, or
    /// "Artist-Album-Year-Genre" for the analog SHARED album file) so the files read in
    /// Finder/Files, but ALWAYS ends in the stable id suffix + extension so the keying scheme
    /// (analog → one shared `…-<albumId>.mp3`; digital → per-song `…-<songId>.mp3`) and the
    /// existing dedup/isFresh/finalize logic are unchanged. The PREFIX is truncated to a cap;
    /// the id suffix + extension are NEVER truncated.
    ///
    /// `song`/`album` come from the catalog lookup (passed in — the call sites resolve them
    /// BEFORE calling this); `entry` supplies analyzed bpm/key/camelot (preferred over the
    /// catalog, mirroring `buildSidecar`). The id suffix is the manifest key's basename
    /// (albumId for analog, songId for digital) so it matches the server's S3 key scheme.
    private func fileNames(for songId: String, entry: RipsStore.ManifestEntry,
                           song: IndexSong?, album: IndexAlbum?) -> (audio: String, sidecar: String) {
        let isAnalog = entry.source == "analog"
        // The stable id token preserved as the audio suffix (album-shared for analog).
        let idToken = Self.idToken(entry: entry, songId: songId)
        let prefix = isAnalog
            ? Self.analogAlbumPrefix(song: song, album: album)
            : Self.digitalSongPrefix(song: song, album: album, entry: entry)
        let audio = Self.descriptiveName(prefix: prefix, idSuffix: idToken, ext: "mp3")
        // The sidecar is ALWAYS per-song (even for an analog shared album file): a full
        // descriptive name suffixed with the songId so every song reads standalone.
        let sidecarPrefix = Self.digitalSongPrefix(song: song, album: album, entry: entry)
        let sidecar = Self.descriptiveName(prefix: sidecarPrefix, idSuffix: songId, ext: "txt")
        return (audio, sidecar)
    }

    /// The id token from the manifest key's basename (albumId for analog / songId for
    /// digital), falling back to the songId. e.g. "rips/alb_1.mp3" → "alb_1".
    private nonisolated static func idToken(entry: RipsStore.ManifestEntry, songId: String) -> String {
        let base = ((entry.key as NSString).lastPathComponent as NSString).deletingPathExtension
        return base.isEmpty ? songId : base
    }

    /// "Artist-Song-Album-Year-Genre-Camelot-Key-BPM" for a digital per-song file.
    /// Missing fields are dropped (no empty placeholder tokens). entry precedence for the
    /// analyzed bpm/key/camelot (like `buildSidecar`).
    private nonisolated static func digitalSongPrefix(song: IndexSong?, album: IndexAlbum?,
                                                      entry: RipsStore.ManifestEntry?) -> String {
        let bpm = entry?.bpm ?? song?.bpm
        let parts: [String?] = [
            song?.artist, song?.name, album?.name,
            (song?.year ?? album?.year).map(String.init),
            album?.genre,
            entry?.camelot ?? song?.camelot,
            entry?.musicalKey ?? song?.key,
            bpm.map { String(Int($0.rounded())) },
        ]
        return joinTokens(parts)
    }

    /// "Artist-Album-Year-Genre" for the ANALOG shared album file — ALBUM-LEVEL so every
    /// song of the album maps to the SAME audio name (keeps analogShared/isFresh/dedup
    /// correct). No per-song bpm/key here (it's a whole-album file).
    private nonisolated static func analogAlbumPrefix(song: IndexSong?, album: IndexAlbum?) -> String {
        let artist = album?.artist ?? song?.artist
        let parts: [String?] = [
            artist, album?.name,
            album?.year.map(String.init),
            album?.genre,
        ]
        return joinTokens(parts)
    }

    /// Join descriptive tokens with "-", dropping empties + per-token sanitizing/capping.
    private nonisolated static func joinTokens(_ parts: [String?]) -> String {
        parts.compactMap { sanitizeToken($0) }.filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// Sanitize a single token for a filesystem: strip path/illegal characters, collapse
    /// whitespace + separators to a single space, then cap the token length.
    private nonisolated static func sanitizeToken(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // Illegal / reserved filename characters + our own separator (so a value containing
        // "-" can't fake extra tokens) → spaces; collapse runs of whitespace.
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|-").union(.controlCharacters).union(.newlines)
        let cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
        let collapsed = cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(tokenCap))
    }

    private nonisolated static let tokenCap = 40
    private nonisolated static let prefixCap = 150

    /// Assemble "<prefix>-<idSuffix>.<ext>", truncating ONLY the prefix to `prefixCap` (the
    /// id suffix + extension are always kept whole so keying/dedup/finalize are stable). A
    /// blank prefix yields just "<idSuffix>.<ext>".
    private nonisolated static func descriptiveName(prefix: String, idSuffix: String, ext: String) -> String {
        let safeId = idSuffix.isEmpty ? "audio" : idSuffix
        let cappedPrefix = String(prefix.prefix(prefixCap))
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        return cappedPrefix.isEmpty
            ? "\(safeId).\(ext)"
            : "\(cappedPrefix)-\(safeId).\(ext)"
    }

    private func errorItem(_ song: (id: String, title: String, artist: String), message: String) -> BurnItem {
        BurnItem(songId: song.id, title: song.title, artist: song.artist,
                 audioFileName: "", sidecarFileName: "", source: "digital",
                 bpm: nil, musicalKey: nil, camelot: nil, durationMs: nil, startMs: nil,
                 bytes: 0, rippedAt: nil, downloadedAt: now, state: .error, error: message,
                 wasAppStorage: nil)
    }

    /// Stable de-dupe preserving first-seen order (don't double-download a repeated song).
    private func orderedUnique(_ songs: [(id: String, title: String, artist: String)]) -> [(id: String, title: String, artist: String)] {
        var seen = Set<String>(); var out: [(id: String, title: String, artist: String)] = []
        for s in songs where !s.id.isEmpty && seen.insert(s.id).inserted { out.append(s) }
        return out
    }

    private func save() {
        let doc = Document(items: items.values.sorted { $0.downloadedAt < $1.downloadedAt })
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: Sidecar (human-readable companion; the INDEX is the machine contract)

    /// The `.txt` sidecar — mirrors burn-setlist.mjs `buildSidecar` HEADER ORDER
    /// (BPM · Key+Camelot · Sentiment · Album) as a HUMAN companion. Prefers the
    /// ManifestEntry analyzed bpm/musicalKey/camelot over catalog values (as
    /// SongRowView.effBpm/effKey/effCamelot does). The Raw JSON embeds the entry so the
    /// prose header and JSON agree. Omits the burn-setlist "Segment" block (no pointer
    /// offsets on IndexSong — the analog seek offset lives in the burn INDEX `startMs`).
    nonisolated static func buildSidecar(songId: String,
                                         fallback: (id: String, title: String, artist: String),
                                         song: IndexSong?,
                                         album: IndexAlbum?,
                                         entry: RipsStore.ManifestEntry?) -> String {
        let artist = song?.artist ?? fallback.artist
        let title = song?.name ?? fallback.title
        let bpm = entry?.bpm ?? song?.bpm
        let key = entry?.musicalKey ?? song?.key
        let camelot = entry?.camelot ?? song?.camelot
        let sentiment = (song?.sentimentKeywords ?? []).joined(separator: ", ")
        let albumName = album?.name

        func dash(_ s: String?) -> String { (s?.isEmpty == false) ? s! : "—" }
        func num(_ n: Double?) -> String { n.map { String($0) } ?? "—" }

        var L: [String] = []
        L.append("\(artist) — \(title)")
        L.append(String(repeating: "=", count: 60))
        L.append("")
        L.append("BPM:        \(num(bpm))")
        L.append("Key:        \(dash(key))  (Camelot \(dash(camelot)))")
        L.append("Sentiment:  \(sentiment.isEmpty ? "—" : sentiment)")
        L.append("Album:      \(dash(albumName))")
        L.append("")
        L.append("-- Song metadata --")
        if let song {
            for (k, v) in songFields(song) { L.append("  \(k): \(v)") }
        } else {
            L.append("  (song not found in index)")
        }
        L.append("")
        L.append("-- Album metadata --")
        if let album {
            for (k, v) in albumFields(album) { L.append("  \(k): \(v)") }
        } else {
            L.append("  (album not found in index)")
        }
        L.append("")
        L.append("-- Raw JSON --")
        L.append(rawJSON(song: song, album: album, entry: entry))
        L.append("")
        return L.joined(separator: "\n")
    }

    private nonisolated static func songFields(_ s: IndexSong) -> [(String, String)] {
        func d(_ v: String?) -> String { (v?.isEmpty == false) ? v! : "—" }
        return [
            ("id", s.id),
            ("artist", d(s.artist)),
            ("name", d(s.name)),
            ("albumId", d(s.albumId)),
            ("trackNumber", s.trackNumber.map(String.init) ?? "—"),
            ("year", s.year.map(String.init) ?? "—"),
            ("sentimentKeywords", (s.sentimentKeywords ?? []).joined(separator: ", ").ifEmpty("—")),
            ("explicit", s.explicit.map { String($0) } ?? "—"),
            ("bpm", s.bpm.map { String($0) } ?? "—"),
            ("key", d(s.key)),
            ("camelot", d(s.camelot)),
            ("length", s.length.map(String.init) ?? "—"),
            ("fileType", d(s.fileType)),
            ("appleMusicId", d(s.appleMusicId)),
        ]
    }

    private nonisolated static func albumFields(_ a: IndexAlbum) -> [(String, String)] {
        func d(_ v: String?) -> String { (v?.isEmpty == false) ? v! : "—" }
        return [
            ("id", a.id),
            ("artist", d(a.artist)),
            ("name", d(a.name)),
            ("genre", d(a.genre)),
            ("year", a.year.map(String.init) ?? "—"),
            ("country", d(a.country)),
            ("fileType", d(a.fileType)),
            ("trackList", "[\(a.trackList.count) entries]"),
            ("audioTracks", "[\((a.audioTracks ?? []).count) entries]"),
        ]
    }

    /// The Raw JSON block — {song, album, manifestEntry} so the prose header (which
    /// prefers analyzed values) and the JSON agree. Built field-by-field because the
    /// catalog models are Decodable-only (no `Encodable` to round-trip through).
    private nonisolated static func rawJSON(song: IndexSong?, album: IndexAlbum?, entry: RipsStore.ManifestEntry?) -> String {
        var obj: [String: Any] = [:]
        if let song { obj["song"] = songJSON(song) }
        if let album { obj["album"] = albumJSON(album) }
        if let entry { obj["manifestEntry"] = entryJSON(entry) }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private nonisolated static func songJSON(_ s: IndexSong) -> [String: Any] {
        var o: [String: Any] = ["id": s.id, "artist": s.artist, "name": s.name]
        o["albumId"] = s.albumId; o["trackNumber"] = s.trackNumber; o["year"] = s.year
        o["sentimentKeywords"] = s.sentimentKeywords; o["explicit"] = s.explicit
        o["bpm"] = s.bpm; o["key"] = s.key; o["camelot"] = s.camelot; o["length"] = s.length
        o["fileType"] = s.fileType; o["lyricsStatus"] = s.lyricsStatus; o["appleMusicId"] = s.appleMusicId
        return o.compactMapValues { $0 }
    }

    private nonisolated static func albumJSON(_ a: IndexAlbum) -> [String: Any] {
        var o: [String: Any] = ["id": a.id, "artist": a.artist, "name": a.name,
                                "trackList": a.trackList, "trackCount": a.trackList.count]
        o["genre"] = a.genre; o["year"] = a.year; o["country"] = a.country; o["fileType"] = a.fileType
        o["audioDurationSec"] = a.audioDurationSec; o["audioTrackCount"] = (a.audioTracks ?? []).count
        return o.compactMapValues { $0 }
    }

    private nonisolated static func entryJSON(_ e: RipsStore.ManifestEntry) -> [String: Any] {
        var o: [String: Any] = ["key": e.key]
        o["ext"] = e.ext; o["source"] = e.source; o["startMs"] = e.startMs; o["durationMs"] = e.durationMs
        o["bpm"] = e.bpm; o["musicalKey"] = e.musicalKey; o["camelot"] = e.camelot
        o["waveform"] = e.waveform; o["analyzed"] = e.analyzed
        return o.compactMapValues { $0 }
    }
}

let burnSchemaVersion = 1

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
