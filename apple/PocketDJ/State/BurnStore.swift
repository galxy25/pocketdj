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
        /// ANALOG cut export: the individual per-song cut chunk's filename in the burn folder
        /// (paired with the per-song sidecar) — the single-track view for DJ software, alongside
        /// the whole-album backcase. nil ⇒ no cut exported. `cutDownloadedAt` is the S3
        /// Last-Modified epoch-ms at download, so a later burn re-pulls when the S3 cut is newer
        /// (the manual-recut auto-repull). Both optional for back-compat decode.
        var cutFileName: String? = nil
        var cutDownloadedAt: Double? = nil

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
        var stemmedSongs = 0    // songs whose 4 stems are now fully on-disk (offline-mixable)
        var beatGridded = 0     // songs whose per-beat grid sidecar is now on-disk (offline beat pulse)
    }

    // MARK: Observed state

    private(set) var items: [String: BurnItem] = [:]
    /// Drives the collection screen's progress UI; nil when no burn is running.
    private(set) var progress: Progress?
    /// Live BACKGROUND-burn progress (enqueued, finished) for the current run, MIRRORED from the
    /// coordinator on the main actor. The collection overlay reads THIS `@Observable` value (this
    /// store is `@MainActor @Observable`) rather than the coordinator's `progressSnapshot` — the
    /// coordinator is a plain `NSObject` (background-session delegate), so a view bound to it would
    /// never re-render as each download finishes (the "burning number doesn't update" bug). (0,0)
    /// when idle / between runs (`beginRun` republishes 0,0).
    private(set) var backgroundProgress: (enqueued: Int, finished: Int) = (0, 0)

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

    /// TEST SEAM: overrides the app-managed burns root (`RipsStore.burnsDirectory()`) so
    /// the storage tests (bulk delete / usage / prune) are hermetic and can never touch
    /// this machine's real burned files. nil in production.
    @ObservationIgnored var appBurnsDirOverride: URL?
    private func appBurnsDir() -> URL? { appBurnsDirOverride ?? (try? RipsStore.burnsDirectory()) }

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
        // Mirror the coordinator's run-scoped progress into this @Observable store so the
        // collection overlay re-renders as each background download finishes (the coordinator
        // itself isn't observable). Fires on the main actor (see TransferCoordinator.publishProgress).
        transfers.onProgress = { [weak self] enqueued, finished in
            self?.backgroundProgress = (enqueued, finished)
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
        // Preserve any per-song cut export already written for this song (the cut pass runs
        // in-process during burn(); this album-finalize fires later from the background download
        // and would otherwise rebuild the item and drop the cut fields).
        let prevCut = items[record.songId]
        items[record.songId] = BurnItem(
            songId: record.songId, title: record.title, artist: record.artist,
            audioFileName: record.audioFileName, sidecarFileName: record.sidecarFileName,
            source: record.source,
            bpm: record.bpm, musicalKey: record.musicalKey, camelot: record.camelot,
            durationMs: record.durationMs, startMs: record.startMs,
            bytes: bytes, rippedAt: record.rippedAt, downloadedAt: now,
            state: .ready, error: nil, wasAppStorage: record.wasAppStorage,
            cutFileName: prevCut?.cutFileName, cutDownloadedAt: prevCut?.cutDownloadedAt)
        save()
    }

    // MARK: Feature 2 — burnt-music folder resolution (security-scoped)

    /// Resolve the ACTIVE burn folder: the user-picked security-scoped folder when a bookmark
    /// is set AND it resolves to a writable directory, else the app-managed Application
    /// Support `burns/` dir. Returns the dir + whether security-scoped access was started
    /// (the caller must `stopAccessingSecurityScopedResource()` then) + whether it is the
    /// user folder. Falls back on ANY problem (denied access / unmounted / not writable) so a
    /// burn never writes to an inaccessible path. `allowRePersist` re-creates + re-persists a
    /// stale bookmark (only on the write path; the read path resolves read-only). `requireWritable`
    /// (true on the WRITE path, false on the READ/playback path): PLAYBACK only needs the folder
    /// READABLE, so a Files-provider folder that resolves but isn't currently writable (e.g. an
    /// offline iCloud Drive folder) must still satisfy a read — gating reads on writability was a
    /// second way burned songs failed to resolve.
    private func resolveBurnFolder(allowRePersist: Bool, requireWritable: Bool = true) -> (url: URL, scoped: Bool, isUserFolder: Bool)? {
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
                if ok && (!requireWritable || FileManager.default.isWritableFile(atPath: url.path)) {
                    if stale && allowRePersist, let fresh = Self.makeBookmark(for: url) {
                        settings?.burnFolderBookmark = fresh
                        settings?.persist()
                    }
                    return (url, true, true)
                }
                if ok { url.stopAccessingSecurityScopedResource() }   // resolved but unusable
            }
        }
        return appBurnsDir().map { ($0, false, false) }
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
            return appBurnsDir().map { ($0, false) }
        }
        // READ/playback path: the folder only needs to be READABLE, not writable.
        guard let resolved = resolveBurnFolder(allowRePersist: false, requireWritable: false),
              resolved.isUserFolder else {
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

    /// Like `localURL`, but for PLAYBACK: when the burned file lives in a USER-PICKED
    /// (security-scoped) folder, this KEEPS the scoped access OPEN and returns a `release`
    /// closure for the player to call when it's done. `localURL` stops the scope immediately in
    /// its `defer` — fine for an existence check, but it leaves AVPlayer unable to READ the file
    /// during playback (a silent 0:00 / no audio). `release` is nil for app-storage files (no
    /// scope needed). Returns nil when the item isn't ready / the file is missing (then the
    /// caller skips or streams).
    func localURLForPlayback(forSong songId: String) -> (url: URL, release: (() -> Void)?)? {
        guard let item = items[songId], item.state == .ready,
              let (dir, scoped) = itemDir(item) else { return nil }
        let url = dir.appendingPathComponent(item.audioFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if scoped { dir.stopAccessingSecurityScopedResource() }   // missing → don't leak scope
            return nil
        }
        // KEEP the scope open; the player releases it on the next load / stop.
        return (url, scoped ? { dir.stopAccessingSecurityScopedResource() } : nil)
    }

    /// Like `localURLForPlayback`, but PREFERS the per-song CUT file (`cuts/<songId>.mp3` — a
    /// standalone slice that plays from 0:00) when one was exported, falling back to the (possibly
    /// shared, analog whole-side) main audio file. Returns the url, an optional scope-release
    /// closure, and `isCut` (true when the returned file is the standalone per-song cut). For a
    /// consumer that CAN'T seek into a shared analog album mp3 (the Mix decks): a cut plays the
    /// RIGHT song; the shared fallback plays from the side's start. When `isCut` is true the caller
    /// must NOT apply a `startMs` offset/window — the cut already IS the song. nil when the item
    /// isn't ready or no file is on disk.
    func localURLForPlaybackPreferringCut(forSong songId: String) -> (url: URL, release: (() -> Void)?, isCut: Bool)? {
        guard let item = items[songId], item.state == .ready,
              let (dir, scoped) = itemDir(item) else { return nil }
        let releaseClosure: (() -> Void)? = scoped ? { dir.stopAccessingSecurityScopedResource() } : nil
        // Prefer the standalone per-song cut. Trust the recorded `cutFileName` first; if it's
        // absent or its file is gone — a STALE in-memory record that predates the cut landing (the
        // in-process cut pass races the background album-download `finalizeBurn`, which rebuilds the
        // item and can drop the cut fields) — SELF-HEAL by finding the cut on disk by its
        // deterministic `-<songId>.mp3` suffix. Without this, a no-seek Mix deck silently loads the
        // whole shared-album mp3 from 0:00 (the wrong song).
        if let cut = resolveCutFileName(for: item, in: dir) {
            return (dir.appendingPathComponent(cut), releaseClosure, true)   // scope stays open; caller releases
        }
        // Fall back to the (possibly shared) main audio file — same dir, scope still held.
        let url = dir.appendingPathComponent(item.audioFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if scoped { dir.stopAccessingSecurityScopedResource() }   // missing → don't leak scope
            return nil
        }
        return (url, releaseClosure, false)
    }

    // MARK: Stem cache (SongDetail stem-audition + future Mix stem decks)
    //
    // Stems are BURNED to the SAME user-managed burn folder as everything else — the user-picked
    // security-scoped folder when one is configured (so the user can define + manage where stems
    // land, right alongside their other burns), else the app-managed Application Support `burns/`
    // dir. Never streamed: once auditioned, a song's stems play fully offline (and the Mix tab's
    // stem decks reuse the same local-file model). Deterministic names; existence-checked on disk.
    // Not tracked in the BurnItem ledger (their `stem-…` names don't match the cut/audio suffixes,
    // so they never collide with it / its dedup / its reconcile). When the burn folder is
    // security-scoped, the read/burn calls KEEP the scope open and hand back a `release` closure
    // the player calls on stop (mirroring `localURLForPlayback`) — AVAudioFile must read the file
    // for the whole session.

    // nonisolated: read by the nonisolated `auxFileSongId` parser (immutable + Sendable,
    // so this is safe under Swift 6 isolation checking).
    private nonisolated static let stemNames = ["vocals", "drums", "bass", "other"]
    private static func stemFileName(_ songId: String, _ stem: String) -> String { "stem-\(songId)-\(stem).mp3" }

    /// Local URLs for ALL 4 stems iff every one already exists on disk in the ACTIVE burn folder
    /// (user-picked when set, else Application Support). Returns the urls + a scope-release closure
    /// (nil for app storage) the caller must invoke when done reading. nil if any stem is missing
    /// (→ the caller burns first) or the folder is unresolvable. READ path: folder need only be
    /// readable.
    func localStemURLs(forSong songId: String) -> (urls: [String: URL], release: (() -> Void)?)? {
        guard let folder = resolveBurnFolder(allowRePersist: false, requireWritable: false) else { return nil }
        let dir = folder.url
        var urls: [String: URL] = [:]
        for name in Self.stemNames {
            let u = dir.appendingPathComponent(Self.stemFileName(songId, name))
            guard FileManager.default.fileExists(atPath: u.path) else {
                if folder.scoped { dir.stopAccessingSecurityScopedResource() }   // missing → don't leak scope
                return nil
            }
            urls[name] = u
        }
        return (urls, folder.scoped ? { dir.stopAccessingSecurityScopedResource() } : nil)
    }

    /// Are this song's stems already burned locally (offline-ready)? Existence check only —
    /// opens + immediately releases any scope.
    func stemsBurned(forSong songId: String) -> Bool {
        guard let got = localStemURLs(forSong: songId) else { return false }
        got.release?()
        return true
    }

    /// Every song id whose 4 stems are on disk in the ACTIVE burn folder — powers the Tracks
    /// stem-import picker. Scans every reachable burn root for `stem-<id>-<part>.mp3` names to
    /// gather candidates, then keeps only those with all four parts present in the active folder
    /// (the folder the import will read from). Read-only; scope opened/released per check.
    func localStemSongIds() -> [String] {
        var candidates = Set<String>()
        forEachBurnRoot { dir, _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names where n.hasPrefix("stem-") && n.hasSuffix(".mp3") {
                if let id = Self.auxFileSongId(n) { candidates.insert(id) }
            }
        }
        return candidates.filter { stemsBurned(forSong: $0) }
    }

    /// BURN the 4 stems into the active burn folder (download once → persists). Idempotent: returns
    /// the existing local files (scope held) without re-downloading. Returns the local urls + a
    /// scope-release closure (nil for app storage), or nil if the song isn't stemmed in the manifest
    /// / the folder is unwritable / a download failed. No streaming.
    func burnStems(forSong songId: String) async -> (urls: [String: URL], release: (() -> Void)?)? {
        if let existing = localStemURLs(forSong: songId) { return existing }   // scope held by the read
        guard let remote = rips.stemURLs(forSong: songId),
              let folder = resolveBurnFolder(allowRePersist: true) else { return nil }
        let dir = folder.url
        func bail() -> (urls: [String: URL], release: (() -> Void)?)? {
            if folder.scoped { dir.stopAccessingSecurityScopedResource() }
            return nil
        }
        var local: [String: URL] = [:]
        for name in Self.stemNames {
            guard let url = remote[name] else { return bail() }
            let dest = dir.appendingPathComponent(Self.stemFileName(songId, name))
            if FileManager.default.fileExists(atPath: dest.path) { local[name] = dest; continue }
            do {
                let data = try await rips.downloadBytes(url)
                try data.write(to: dest, options: .atomic)
                local[name] = dest
            } catch { return bail() }
        }
        return (local, folder.scoped ? { dir.stopAccessingSecurityScopedResource() } : nil)
    }

    // MARK: Beat grid (per-beat analysis sidecar) — burned + dynamically fetched like stems

    private static func beatgridFileName(_ songId: String) -> String { "analysis-\(songId).json" }

    /// Local per-beat sidecar URL iff already on disk in the ACTIVE burn folder (READ path). Returns
    /// the url + scope-release closure; nil if absent / folder unresolvable.
    func localBeatgridURL(forSong songId: String) -> (url: URL, release: (() -> Void)?)? {
        guard let folder = resolveBurnFolder(allowRePersist: false, requireWritable: false) else { return nil }
        let dir = folder.url
        let u = dir.appendingPathComponent(Self.beatgridFileName(songId))
        guard FileManager.default.fileExists(atPath: u.path) else {
            if folder.scoped { dir.stopAccessingSecurityScopedResource() }   // missing → don't leak scope
            return nil
        }
        return (u, folder.scoped ? { dir.stopAccessingSecurityScopedResource() } : nil)
    }

    /// Is this song's per-beat grid already burned locally? Existence check only.
    func beatgridBurned(forSong songId: String) -> Bool {
        guard let got = localBeatgridURL(forSong: songId) else { return false }
        got.release?()
        return true
    }

    /// Parse the LOCAL per-beat sidecar (no network). nil if not burned / unreadable / malformed.
    func localBeatGrid(forSong songId: String) -> RipsStore.BeatGridSidecar? {
        guard let got = localBeatgridURL(forSong: songId) else { return nil }
        defer { got.release?() }
        guard let data = try? Data(contentsOf: got.url),
              let sidecar = try? JSONDecoder().decode(RipsStore.BeatGridSidecar.self, from: data) else { return nil }
        return sidecar
    }

    /// BURN (download once → persist) the per-beat sidecar, then parse it. Idempotent: returns the
    /// local parse without re-downloading. nil if the song has no sidecar server-side / the folder is
    /// unwritable / the download or parse failed. The JSON is validated BEFORE it's cached, so a
    /// truncated/garbage body is never written.
    func burnBeatGrid(forSong songId: String) async -> RipsStore.BeatGridSidecar? {
        if let local = localBeatGrid(forSong: songId) { return local }
        guard let url = rips.beatgridSidecarURL(forSong: songId),
              let folder = resolveBurnFolder(allowRePersist: true) else { return nil }
        let dir = folder.url
        defer { if folder.scoped { dir.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await rips.downloadBytes(url)
            let sidecar = try JSONDecoder().decode(RipsStore.BeatGridSidecar.self, from: data)   // validate first
            try data.write(to: dir.appendingPathComponent(Self.beatgridFileName(songId)), options: .atomic)
            return sidecar
        } catch { return nil }
    }

    /// The per-song cut filename for a ready item, or nil if there genuinely is no cut on disk.
    /// Prefers the recorded `cutFileName`; if that's missing or its file is gone, scans the burn
    /// dir for the cut by its deterministic `-<songId>.mp3` suffix and HEALS the record (so the
    /// next load is O(1) and the ledger becomes correct). Caller must already hold the dir's scope.
    private func resolveCutFileName(for item: BurnItem, in dir: URL) -> String? {
        if let cut = item.cutFileName,
           FileManager.default.fileExists(atPath: dir.appendingPathComponent(cut).path) {
            return cut
        }
        // Cuts are an ANALOG-only concept (a per-song slice out of the shared whole-album mp3). A
        // DIGITAL item's audio file IS the song — and a re-rip writes a NEW descriptive name (the
        // prefix embeds re-analyzed bpm/key) without deleting the old one, so a sibling
        // "-<songId>.mp3" would be an ORPHAN from a prior burn, not a cut. Never scan/heal for
        // digital: fall back to the current audioFileName.
        guard item.source == "analog" else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let found = Self.cutFileName(amongst: names, songId: item.songId,
                                           audioFileName: item.audioFileName) else { return nil }
        items[item.songId]?.cutFileName = found   // self-heal the stale record + persist
        save()
        return found
    }

    /// Pick the per-song CUT out of a burn dir's listing. Every exported cut is named
    /// `<prefix>-<songId>.mp3` (or bare `<songId>.mp3` with no prefix), so the cut is the file
    /// ending in `-<songId>.mp3` that is NOT the item's own `audioFileName` — the exclusion matters
    /// because a DIGITAL per-song file ALSO ends `-<songId>.mp3` but IS the song (no separate cut),
    /// whereas an analog shared-album file ends `-<albumId>.mp3` and never matches. Pure + testable.
    nonisolated static func cutFileName(amongst names: [String], songId: String,
                                        audioFileName: String) -> String? {
        guard !songId.isEmpty else { return nil }
        let suffix = "-\(songId).mp3"
        let exact = "\(songId).mp3"
        return names.first { $0 != audioFileName && ($0.hasSuffix(suffix) || $0 == exact) }
    }

    /// The analog seek offset (ms) within a shared album mp3 for a ready burned song, so a
    /// player seeks to the song's start inside the whole-album file. nil for digital
    /// (per-song file) burns or songs that aren't burned.
    func startMs(forSong songId: String) -> Int? {
        guard let item = items[songId], item.state == .ready else { return nil }
        return item.startMs
    }

    /// The measured beat grid for a song (from the rips manifest), if the indexer has analyzed it.
    /// `bpm` (preferred over the catalog BPM for beat-matching) + the `firstDownbeatMs` phase
    /// reference + the `steady` gate. nil when there's no grid yet (engine falls back to catalog
    /// BPM + a downbeat-at-0 assumption). The grid is measured on the file the deck opens, so the
    /// downbeat is relative to the song's 0:00 either way (cut from 0; windowed album from startMs).
    func beatGrid(forSong songId: String) -> (bpm: Double?, firstDownbeatMs: Int?, steady: Bool?)? {
        guard let e = rips.manifest[songId], e.beatGridBpm != nil || e.firstDownbeatMs != nil else { return nil }
        return (e.beatGridBpm, e.firstDownbeatMs, e.steady)
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

    // MARK: Storage manager — bulk delete + usage (downloaded media ONLY)
    //
    // Everything here operates on the DOWNLOADED files + the burn ledger and never touches
    // the catalog or the user's collections — a deleted song stays in the library and can
    // always be re-burned later.

    /// Remove a batch of burned songs: each item's audio file (shared-analog-aware — the
    /// whole-album mp3 survives while any SURVIVING item still references it), sidecar,
    /// per-song cut, stems, and beat-grid sidecar, then drop the ledger entries and save
    /// ONCE. Unknown ids are ignored. An item whose dir is UNRESOLVABLE right now (a
    /// user-folder burn on an unplugged drive / offline provider) is SKIPPED entirely —
    /// dropping its ledger entry without deleting its files would orphan them forever
    /// (the same "no data destruction" rule `reconcileOnLaunch` follows).
    func removeBurns(songIds: [String]) {
        let requested = Set(songIds).filter { items[$0] != nil }
        guard !requested.isEmpty else { return }
        // Resolve reachability first: only reachable items are actually removed, and the
        // shared-audio survivor check must treat skipped (unreachable) items as survivors.
        var goners: [String: (url: URL, scoped: Bool)] = [:]
        for id in requested {
            guard let item = items[id] else { continue }
            guard let resolved = itemDir(item) else { continue }   // unreachable → keep
            goners[id] = resolved
        }
        let gonerIds = Set(goners.keys)
        guard !gonerIds.isEmpty else { return }
        // Audio files still referenced by a surviving (or skipped) item must not be deleted.
        let survivorAudio = Set(items.values.filter { !gonerIds.contains($0.songId) }.map(\.audioFileName))
        for (id, resolved) in goners {
            guard let item = items[id] else { continue }
            let dir = resolved.url
            if !item.audioFileName.isEmpty && !survivorAudio.contains(item.audioFileName) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.audioFileName))
            }
            if !item.sidecarFileName.isEmpty {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.sidecarFileName))
            }
            if let cut = resolveCutFileName(for: item, in: dir) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(cut))
            }
            if resolved.scoped { dir.stopAccessingSecurityScopedResource() }
            removeAuxFiles(forSong: id)
            items[id] = nil
        }
        save()
    }

    /// Remove EVERY burned song, then sweep any aux leftovers (the stem cache isn't
    /// ledger-tracked, so stems for never-burned songs linger otherwise). Cancels any
    /// in-flight burn first — otherwise a background download finalizing later would
    /// resurrect its ledger entry + file. Items in an unreachable user folder are kept
    /// (see `removeBurns`). Only files this app provably wrote are touched.
    func removeAllBurns() {
        requestStop()   // halt an in-process burn loop + cancel pending background downloads
        removeBurns(songIds: Array(items.keys))
        sweepAuxFiles { _ in true }
    }

    /// Delete aux files (stems / beat grids) whose parsed songId passes `shouldSweep`,
    /// in every reachable root — subject to the per-root ownership rule (`ownsAuxFile`),
    /// so a user folder's own files are never touched.
    private func sweepAuxFiles(_ shouldSweep: (String) -> Bool) {
        forEachBurnRoot { dir, isUserFolder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names {
                guard let id = Self.auxFileSongId(n), shouldSweep(id),
                      ownsAuxFile(n, inUserFolder: isUserFolder) else { continue }
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
    }

    /// Storage-manager prune pre-pass: delete ORPHAN aux files — stems / beat grids for
    /// songs with no ledger entry (auditioned-but-never-burned cache). Cheap space that
    /// should go before any real burned song is evicted.
    func sweepOrphanAuxFiles() {
        sweepAuxFiles { self.items[$0] == nil }
    }

    /// Total on-disk bytes of burned media (audio + sidecars + cuts + stems + beat grids)
    /// across both roots. Counts ONLY files this app provably wrote — ledger-recorded
    /// names + owned aux files — never a user folder's unrelated files.
    func burnedUsageBytes() -> Int {
        var ledgerNames = Set<String>()
        for it in items.values {
            if !it.audioFileName.isEmpty { ledgerNames.insert(it.audioFileName) }
            if !it.sidecarFileName.isEmpty { ledgerNames.insert(it.sidecarFileName) }
            if let c = it.cutFileName { ledgerNames.insert(c) }
        }
        var total = 0
        forEachBurnRoot { dir, isUserFolder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names where ledgerNames.contains(n) || ownsAuxFile(n, inUserFolder: isUserFolder) {
                let path = dir.appendingPathComponent(n).path
                if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int {
                    total += size
                }
            }
        }
        return total
    }

    /// Ready burned songs grouped by artist with APPROXIMATE attributable bytes (each
    /// unique audio file counted once within the group — a shared analog album mp3 may
    /// survive a per-artist delete if another artist's song on the same record still
    /// references it). Sorted by artist for the Storage manager list.
    struct ArtistUsage: Identifiable, Equatable {
        let artist: String
        let songIds: [String]
        let bytes: Int
        var id: String { artist }
    }
    func usageByArtist() -> [ArtistUsage] {
        let ready = items.values.filter { $0.state == .ready }
        let groups = Dictionary(grouping: ready) { $0.artist.isEmpty ? "Unknown artist" : $0.artist }
        return groups.map { artist, group in
            ArtistUsage(artist: artist,
                        songIds: group.map(\.songId).sorted(),
                        bytes: Self.uniqueAudioBytes(group))
        }
        .sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
    }

    /// The subset of `ids` that are burned + ready (what a per-collection delete removes).
    func readyBurnedIds(in ids: [String]) -> [String] {
        ids.filter { items[$0]?.state == .ready }
    }

    /// Approximate on-disk bytes attributable to a set of burned songs (unique audio files
    /// counted once). For the Storage manager's per-collection rows.
    func approximateBytes(forSongs ids: [String]) -> Int {
        Self.uniqueAudioBytes(ids.compactMap { items[$0] }.filter { $0.state == .ready })
    }

    /// Sum each DISTINCT audio file's recorded bytes once (analog albums share one mp3
    /// across their songs, each carrying the whole file's byte count).
    private static func uniqueAudioBytes(_ group: [BurnItem]) -> Int {
        var seen = Set<String>(); var total = 0
        for it in group where !it.audioFileName.isEmpty && seen.insert(it.audioFileName).inserted {
            total += it.bytes
        }
        return total
    }

    /// Parse a non-ledger companion file this app writes, returning the embedded songId
    /// iff `name` matches an EXACT deterministic shape — a stem
    /// `stem-<songId>-<part>.mp3` (part ∈ vocals/drums/bass/other) or a beat-grid sidecar
    /// `analysis-<songId>.json`. A loose prefix match isn't enough: a user's own
    /// `stem-loop.mp3` in their picked folder must never parse.
    nonisolated static func auxFileSongId(_ name: String) -> String? {
        if name.hasPrefix("stem-") && name.hasSuffix(".mp3") {
            let core = String(name.dropFirst("stem-".count).dropLast(".mp3".count))
            for part in stemNames where core.hasSuffix("-\(part)") {
                let id = String(core.dropLast(part.count + 1))
                return id.isEmpty ? nil : id
            }
            return nil
        }
        if name.hasPrefix("analysis-") && name.hasSuffix(".json") {
            let id = String(name.dropFirst("analysis-".count).dropLast(".json".count))
            return id.isEmpty ? nil : id
        }
        return nil
    }

    /// Whether an aux file BELONGS TO THIS APP in the given root. In the app-managed root
    /// any exact-shaped name qualifies (the dir is app-private, so everything there is
    /// ours). In a USER-PICKED folder the embedded songId must additionally be one the
    /// app knows (burn ledger or rips manifest) — a user's own coincidentally-named file
    /// is never counted or deleted. Conservative when offline (unknown id → not ours).
    private func ownsAuxFile(_ name: String, inUserFolder: Bool) -> Bool {
        guard let id = Self.auxFileSongId(name) else { return false }
        guard inUserFolder else { return true }
        return items[id] != nil || rips.manifest[id] != nil
    }

    /// Delete a song's non-ledger companion files (4 stems + beat-grid sidecar) from BOTH
    /// possible roots — they're written to the ACTIVE folder, which may have changed since.
    /// Exact deterministic names only, so this is safe in a user-picked folder.
    private func removeAuxFiles(forSong songId: String) {
        forEachBurnRoot { dir, _ in
            for name in Self.stemNames {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.stemFileName(songId, name)))
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.beatgridFileName(songId)))
        }
    }

    // MARK: Stem usage + cleanup (Settings ▸ Storage — MISC1)

    /// A `stem-<id>-<part>.mp3` name (part ∈ stemNames). Stricter than the caller checking
    /// `auxFileSongId != nil` alone would be — it must NEVER match a beat-grid
    /// `analysis-<id>.json`, so "remove stems" can't wipe beat grids.
    private static func isStemFile(_ name: String) -> Bool {
        name.hasPrefix("stem-") && name.hasSuffix(".mp3") && auxFileSongId(name) != nil
    }

    /// On-disk bytes of just the owned STEM files across both roots — broken out of
    /// `burnedUsageBytes()` so Storage shows stems as a separate, independently-clearable line.
    func stemUsageBytes() -> Int { stemBytesMatching { _ in true } }

    /// Owned stem bytes for a specific set of songIds (both roots).
    private func stemBytes(forSongs ids: [String]) -> Int {
        let want = Set(ids)
        return stemBytesMatching { want.contains($0) }
    }

    /// Sum owned stem-file bytes whose parsed songId passes `include`, in every reachable root.
    private func stemBytesMatching(_ include: (String) -> Bool) -> Int {
        var total = 0
        forEachBurnRoot { dir, isUserFolder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names where Self.isStemFile(n) && ownsAuxFile(n, inUserFolder: isUserFolder) {
                guard let id = Self.auxFileSongId(n), include(id) else { continue }
                let path = dir.appendingPathComponent(n).path
                if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int {
                    total += size
                }
            }
        }
        return total
    }

    /// Stem bytes attributed to each artist whose songs are burned + ready (grouped like
    /// `usageByArtist`). Only ledgered songs carry an artist; orphan (auditioned-only) stems
    /// have none — those are reachable solely via `removeAllStems`. Artists with no stems on
    /// disk are omitted.
    func stemUsageByArtist() -> [ArtistUsage] {
        let ready = items.values.filter { $0.state == .ready }
        let groups = Dictionary(grouping: ready) { $0.artist.isEmpty ? "Unknown artist" : $0.artist }
        return groups.compactMap { artist, group in
            let ids = group.map(\.songId)
            let bytes = stemBytes(forSongs: ids)
            guard bytes > 0 else { return nil }
            return ArtistUsage(artist: artist, songIds: ids.sorted(), bytes: bytes)
        }
        .sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
    }

    /// Delete EVERY owned stem file (both roots), leaving beat grids and burned audio intact.
    /// Gated on the stem name shape (never `analysis-*.json`). `protecting` skips songIds whose
    /// stems are loaded in a live player.
    func removeAllStems(protecting: Set<String> = []) {
        forEachBurnRoot { dir, isUserFolder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names where Self.isStemFile(n) && ownsAuxFile(n, inUserFolder: isUserFolder) {
                if let id = Self.auxFileSongId(n), protecting.contains(id) { continue }
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
    }

    /// Delete just the stem files (the 4 parts) for the given songs, both roots — beat grids
    /// stay. Deterministic names only, so this is safe in a user-picked folder.
    func removeStems(forSongs ids: [String], protecting: Set<String> = []) {
        forEachBurnRoot { dir, _ in
            for songId in ids where !protecting.contains(songId) {
                for part in Self.stemNames {
                    try? FileManager.default.removeItem(
                        at: dir.appendingPathComponent(Self.stemFileName(songId, part)))
                }
            }
        }
    }

    /// Visit each possible burn root once — the app-managed `burns/` dir, then the
    /// user-picked folder (when its bookmark resolves) with `isUserFolder: true`. Holds
    /// the security scope around the visit.
    private func forEachBurnRoot(_ body: (URL, _ isUserFolder: Bool) -> Void) {
        var visited = Set<String>()
        if let app = appBurnsDir(), visited.insert(app.path).inserted { body(app, false) }
        guard settings?.burnFolderBookmark != nil,
              let user = resolveBurnFolder(allowRePersist: false, requireWritable: false),
              user.isUserFolder else { return }
        defer { if user.scoped { user.url.stopAccessingSecurityScopedResource() } }
        if visited.insert(user.url.path).inserted { body(user.url, true) }
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

    // MARK: Recognizer "add to Apple Music → burn to device"

    /// One recognized track to rip + burn (the ＋ flow's payload).
    struct RipBurnTrack { let id, title, artist: String; let appleMusicId: String?; let lengthMs: Int? }

    /// Per-flow rip→burn lifecycles, owned by the store so they SURVIVE the Shazam result
    /// sheet being dismissed (a view-owned `Task` would cancel on disappear). Just the
    /// Task handles — the OBSERVED progress lives in `ripBurning`/`ripBurnError`.
    @ObservationIgnored private var ripBurnTasks: [String: Task<Void, Never>] = [:]

    /// Observed: songs with a recognizer rip→burn in flight. Drives the section's
    /// spinner — a plain @ObservationIgnored dict would not invalidate the view when it
    /// clears, leaving a stuck spinner on a silent failure.
    private(set) var ripBurning: Set<String> = []
    /// Observed: last rip→burn failure message per song (cleared on a new start / success).
    private(set) var ripBurnError: [String: String] = [:]

    /// True while a recognizer-initiated rip→burn for this song is still running.
    func isRipBurning(_ songId: String) -> Bool { ripBurning.contains(songId) }
    /// A surfaced rip→burn failure message for this song, if any.
    func ripBurnErrorMessage(_ songId: String) -> String? { ripBurnError[songId] }
    /// True while the (background) device download of an already-ripped song is in flight —
    /// covers the window after the rip task hands off to the transfer coordinator but before
    /// the file finalizes, so the UI doesn't briefly read as idle.
    func isDownloadingToDevice(_ songId: String) -> Bool { items[songId]?.state == .downloading }

    /// The recognizer's ＋ path AFTER the catalog add: rip the track (real-time capture on
    /// the rip server) then burn the result into the user's burn folder so it plays/mixes
    /// fully offline. Idempotent per song; the Task is store-owned so it outlives the sheet.
    func startRipAndBurn(songId: String, title: String, artist: String,
                         appleMusicId: String?, lengthMs: Int?) {
        guard ripBurnTasks[songId] == nil, localURL(forSong: songId) == nil else { return }
        ripBurning.insert(songId); ripBurnError[songId] = nil
        ripBurnTasks[songId] = Task { [weak self] in
            await self?.ripAndBurn(songId: songId, title: title, artist: artist,
                                   appleMusicId: appleMusicId, lengthMs: lengthMs)
            self?.ripBurning.remove(songId)
            self?.ripBurnTasks[songId] = nil
        }
    }

    /// Batched album variant: enqueue every track ONCE, then run a SINGLE shared poll loop
    /// (one manifest refresh per tick) that burns each as it lands — so a 12-track album
    /// doesn't fan out 12 independent 30-min timers + 12 simultaneous manifest GETs against
    /// the concurrency-1 real-time ripper. Budget scales with track count (serial capture).
    func startRipAndBurnAlbum(_ tracks: [RipBurnTrack]) {
        let todo = tracks.filter { localURL(forSong: $0.id) == nil }
        guard !todo.isEmpty else { return }
        let key = "album:" + todo.map(\.id).sorted().joined(separator: ",")
        guard ripBurnTasks[key] == nil else { return }
        todo.forEach { ripBurning.insert($0.id); ripBurnError[$0.id] = nil }
        ripBurnTasks[key] = Task { [weak self] in
            await self?.ripAndBurnAlbum(todo)
            self?.ripBurnTasks[key] = nil
        }
    }

    private func ripAndBurn(songId: String, title: String, artist: String,
                            appleMusicId: String?, lengthMs: Int?) async {
        if localURL(forSong: songId) != nil { return }   // already on device

        // Capture first when it isn't already in the S3 manifest.
        if rips.cachedURL(songId) == nil {
            switch await rips.requestRip(songId: songId, title: title, artist: artist,
                                         appleMusicId: appleMusicId, lengthMs: lengthMs) {
            case .ready, .queued, .inflight: break
            case .noServer: ripBurnError[songId] = "No rip server — can’t download"; return
            case .unknown:  ripBurnError[songId] = "Rip server can’t capture this track"; return
            case .failed:   ripBurnError[songId] = "Couldn’t start the download"; return
            }
            // Real-time capture: poll the manifest AND the job until the rip lands. The job
            // poll lets a worker error short-circuit instead of waiting out the cap.
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                await rips.refreshManifest()
                if rips.cachedURL(songId) != nil { break }
                if await rips.refreshJob(songId) == .error {
                    ripBurnError[songId] = "The rip failed on the server"; return
                }
                if Date().timeIntervalSince(start) > 30 * 60 {
                    ripBurnError[songId] = "Download timed out"; return
                }
            }
        }

        guard rips.cachedURL(songId) != nil else { return }
        _ = await burn([(id: songId, title: title, artist: artist)])
    }

    private func ripAndBurnAlbum(_ tracks: [RipBurnTrack]) async {
        let byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pending = Set<String>()
        for t in tracks {
            if rips.cachedURL(t.id) != nil { pending.insert(t.id); continue }
            switch await rips.requestRip(songId: t.id, title: t.title, artist: t.artist,
                                         appleMusicId: t.appleMusicId, lengthMs: t.lengthMs) {
            case .ready, .queued, .inflight: pending.insert(t.id)
            case .noServer, .unknown, .failed:
                ripBurnError[t.id] = "Couldn’t queue the download"; ripBurning.remove(t.id)
            }
        }
        // One shared loop. Budget accounts for SERIAL real-time capture (concurrency-1).
        let start = Date()
        let cap = TimeInterval(max(pending.count, 1)) * 15 * 60
        while !pending.isEmpty && !Task.isCancelled {
            let ready = pending.filter { rips.cachedURL($0) != nil }
            for id in ready {
                if let t = byId[id] { _ = await burn([(id: t.id, title: t.title, artist: t.artist)]) }
                ripBurning.remove(id)
            }
            pending.subtract(ready)
            if pending.isEmpty { break }
            if Date().timeIntervalSince(start) > cap { break }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await rips.refreshManifest()
        }
        for id in pending { ripBurning.remove(id); ripBurnError[id] = "Download timed out" }
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

            // ONE progress counter for the whole burn. The IN-PROCESS path drives the single
            // "Burning X of N" pill off `progress`; the BACKGROUND (iOS) path drives it off the
            // coordinator's `backgroundProgress` instead, so don't set `progress` there (it would
            // race the async download counter and make the number jump).
            if transfers == nil {
                progress = Progress(done: done, total: unique.count, label: "\(song.artist) — \(song.title)")
            }
            defer { done += 1 }

            // (1) Idempotency: already burned, file present, right size, not stale → skip.
            // Resolve freshness against the dir the EXISTING item was actually written to.
            if let existing = items[song.id], existing.state == .ready,
               let (exDir, exScoped) = itemDir(existing) {
                let fresh = isFresh(existing, dir: exDir, rippedAt: rips.manifest[song.id]?.rippedAt)
                if exScoped { exDir.stopAccessingSecurityScopedResource() }
                if fresh {
                    result.burned += 1
                    // Even when the album audio is already fresh, make sure the per-song analog cut
                    // is present/current (in-process path only — background runs a post-pass).
                    if transfers == nil, let e = rips.manifest[song.id] {
                        await exportAnalogCut(songId: song.id, entry: e, dir: dir)
                    }
                    continue
                }
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
                transfers.enqueueDownload(url: durableURL, token: rips.token,
                                          profileId: rips.profileIdProvider(), record: record)
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
                // Export this analog song's per-song cut INLINE (keeps a single progress counter —
                // no separate "making cuts" phase). No-op for digital / cutless songs.
                await exportAnalogCut(songId: song.id, entry: entry, dir: dir)
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

        // ANALOG CUT EXPORT. The IN-PROCESS path already exported each cut INLINE (one progress
        // counter). The BACKGROUND (iOS) path only ENQUEUED downloads, so it had no audio in-hand
        // to pair a cut with — run a SILENT post-pass here (no `progress` writes, so the only pill
        // stays the background "Burning X of N" counter). Both run inside burn()'s held folder scope.
        if transfers != nil {
            await exportAnalogCuts(unique, dir: dir)
        }

        // STEM BURN: pull every server-stemmed song's 4 stems into the burn folder (idempotent), so a
        // burned collection plays AND mixes ENTIRELY offline. Runs for both paths; a re-burn of an
        // already-audio-burned collection picks up stems that became available since. Skipped on STOP.
        if !result.stopped && !Task.isCancelled {
            result.stemmedSongs = await burnCollectionStems(unique, dir: dir)
        }

        // BEAT-GRID BURN: pull every analyzed song's per-beat sidecar (idempotent), so a burned
        // collection's beat pulse works fully offline. Same shape as stems; skipped on STOP.
        if !result.stopped && !Task.isCancelled {
            result.beatGridded = await burnCollectionBeatgrids(unique, dir: dir)
        }

        save()
        progress = nil
        return result
    }

    /// Download every server-stemmed song's 4 stems (the ones missing on disk) into the burn folder,
    /// under the deterministic `stem-<songId>-<part>.mp3` names the Mix decks + audition panel read.
    /// Drives the single "Burning stems X of N" pill, is STOP-aware, idempotent (skips present stems),
    /// and best-effort (a stem failure never fails the burn). Returns how many songs ended fully
    /// stemmed on disk (so a burned collection is offline-mixable). Only songs the server has stemmed
    /// (`manifest.stemVersion`) are considered — burning never triggers separation, only fetches it.
    private func burnCollectionStems(_ songs: [(id: String, title: String, artist: String)], dir: URL) async -> Int {
        let stemmed = songs.filter { rips.manifest[$0.id]?.stemVersion != nil }
        guard !stemmed.isEmpty else { return 0 }
        let pending = stemmed.filter { !stemFilesPresent($0.id, dir: dir) }
        var done = 0
        for s in pending {
            if stopRequested || Task.isCancelled { break }
            progress = Progress(done: done, total: pending.count, label: "Stems · \(s.artist) — \(s.title)")
            await downloadStems(songId: s.id, dir: dir)
            done += 1
        }
        // Count every stemmed song now fully present (the just-fetched ones + any already on disk).
        return stemmed.reduce(into: 0) { acc, s in if stemFilesPresent(s.id, dir: dir) { acc += 1 } }
    }

    /// Download the 4 stems for one song into `dir` (skipping any already on disk). Best-effort.
    private func downloadStems(songId: String, dir: URL) async {
        guard let remote = rips.stemURLs(forSong: songId) else { return }
        for name in Self.stemNames {
            if stopRequested || Task.isCancelled { return }
            guard let url = remote[name] else { return }
            let dest = dir.appendingPathComponent(Self.stemFileName(songId, name))
            if FileManager.default.fileExists(atPath: dest.path) { continue }   // idempotent
            do {
                let data = try await rips.downloadBytes(url)
                try data.write(to: dest, options: .atomic)
            } catch { return }   // a stem failure never fails the burn (album audio still plays)
        }
    }

    /// All 4 stem files for a song present on disk in `dir`?
    private func stemFilesPresent(_ songId: String, dir: URL) -> Bool {
        for name in Self.stemNames {
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.stemFileName(songId, name)).path) {
                return false
            }
        }
        return true
    }

    /// Download every analyzed song's per-beat sidecar (the ones missing on disk) into the burn
    /// folder as `analysis-<songId>.json`, so a burned collection's beat pulse works fully offline.
    /// STOP-aware, idempotent (skips present), best-effort (a sidecar failure never fails the burn).
    /// Returns how many songs ended with a sidecar on disk. Only songs the indexer has analyzed
    /// (`manifest.beatgrid`) are considered — burning fetches an existing grid, never triggers analysis.
    private func burnCollectionBeatgrids(_ songs: [(id: String, title: String, artist: String)], dir: URL) async -> Int {
        let analyzed = songs.filter { rips.hasBeatgridSidecar($0.id) }
        guard !analyzed.isEmpty else { return 0 }
        let pending = analyzed.filter { !beatgridFilePresent($0.id, dir: dir) }
        var done = 0
        for s in pending {
            if stopRequested || Task.isCancelled { break }
            progress = Progress(done: done, total: pending.count, label: "Beat grid · \(s.artist) — \(s.title)")
            await downloadBeatgrid(songId: s.id, dir: dir)
            done += 1
        }
        return analyzed.reduce(into: 0) { acc, s in if beatgridFilePresent(s.id, dir: dir) { acc += 1 } }
    }

    /// Download one song's per-beat sidecar into `dir` (skip if present). Validates the JSON before
    /// caching so a truncated/garbage body is never written. Best-effort.
    private func downloadBeatgrid(songId: String, dir: URL) async {
        let dest = dir.appendingPathComponent(Self.beatgridFileName(songId))
        if FileManager.default.fileExists(atPath: dest.path) { return }   // idempotent
        guard let url = rips.beatgridSidecarURL(forSong: songId) else { return }
        do {
            let data = try await rips.downloadBytes(url)
            _ = try JSONDecoder().decode(RipsStore.BeatGridSidecar.self, from: data)   // validate before caching
            try data.write(to: dest, options: .atomic)
        } catch { return }   // a sidecar failure never fails the burn
    }

    /// Is the per-beat sidecar present on disk in `dir`?
    private func beatgridFilePresent(_ songId: String, dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.beatgridFileName(songId)).path)
    }

    /// BACKGROUND-path post-pass: export EVERY analog song's cut (`cuts/<songId>.mp3`) into the
    /// burn folder. SILENT (no `progress` writes) so the only pill stays the background
    /// "Burning X of N" counter; the in-process path exports each cut INLINE instead (one counter).
    /// Stop-aware; a cut failure never fails the burn.
    private func exportAnalogCuts(_ songs: [(id: String, title: String, artist: String)], dir: URL) async {
        for s in songs {
            if stopRequested || Task.isCancelled { break }
            guard let e = rips.manifest[s.id] else { continue }
            await exportAnalogCut(songId: s.id, entry: e, dir: dir)
        }
    }

    /// Download ONE analog song's server-sliced cut (`cuts/<songId>.mp3`) into the burn folder
    /// under a per-song descriptive name (pairing with the per-song sidecar), so other DJ software
    /// gets the individual track alongside the whole-album backcase. No-op for digital / cutless
    /// songs. Auto-repull: re-download only when the S3 cut is NEWER than the device's copy (a
    /// manual re-upload bumps the S3 Last-Modified). Offline / HEAD-miss keeps any existing cut.
    /// A cut failure NEVER fails the burn (the album entry alone still plays + is the backcase).
    private func exportAnalogCut(songId: String, entry: RipsStore.ManifestEntry, dir: URL) async {
        guard entry.source == "analog", let cutKey = entry.cutKey else { return }
        let (s, a) = lookup?(songId) ?? (nil, nil)
        let cutName = Self.descriptiveName(
            prefix: Self.digitalSongPrefix(song: s, album: a, entry: entry),
            idSuffix: songId, ext: "mp3")
        let cutFileURL = dir.appendingPathComponent(cutName)
        let remoteMs = await rips.remoteLastModifiedMs(rips.url(forKey: cutKey))
        let exists = FileManager.default.fileExists(atPath: cutFileURL.path)
        // Up-to-date (local present + last download timestamp ≥ the current S3 one) → keep.
        if exists, let remoteMs, let storedMs = items[songId]?.cutDownloadedAt, storedMs >= remoteMs {
            items[songId]?.cutFileName = cutName
            return
        }
        // Offline (HEAD failed) but a local cut already exists → keep it; don't clobber.
        if remoteMs == nil, exists { items[songId]?.cutFileName = cutName; return }
        do {
            let data = try await rips.downloadBytes(rips.url(forKey: cutKey))
            // DELETE the old cut before placing the updated (re-tagged) one — both the
            // previously-recorded name (in case the descriptive name changed) AND the current
            // target — so an updated version cleanly replaces the prior file. Done AFTER the
            // new bytes are in hand, so a download failure never loses the existing cut.
            if let old = items[songId]?.cutFileName, old != cutName {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
            }
            try? FileManager.default.removeItem(at: cutFileURL)
            try data.write(to: cutFileURL, options: .atomic)
            items[songId]?.cutFileName = cutName
            items[songId]?.cutDownloadedAt = remoteMs ?? now
        } catch { /* best-effort — a cut export failure never fails the burn */ }
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
