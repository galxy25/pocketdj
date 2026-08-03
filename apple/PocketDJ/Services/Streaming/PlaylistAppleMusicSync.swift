import Foundation
import Observation

/// Coordinates bidirectional PocketDJ ↔ Apple Music library-playlist sync (WS2) via the
/// `AMPlaylistSyncClient` (the AWS Lambda) — replacing the iMac/Tailscale path.
///
/// • PUSH — idempotent server-side: a PocketDJ playlist is CREATED in Apple Music only when no
///   same-named playlist exists there; otherwise only its MISSING tracks are appended. Re-running
///   a partial sync tops playlists up — it never duplicates them (the 4×-"comfort zone" bug).
/// • RECONCILE — removals + reorders in EXISTING app-created AM playlists via on-device MusicKit
///   `MusicLibrary.edit` (the Web API is append-only), fail-closed (see `reconcile`).
/// • PULL — every Apple Music library playlist not already present locally (matched by name) is
///   imported as a PocketDJ playlist, its catalog tracks mapped back to local song ids.
///
/// ── Progress + audit trail ──────────────────────────────────────────────────────────────────────
/// `steps` is the LIVE step list the Settings UI renders in place of a bare spinner (the server
/// publishes {label, done, total} with every checkpoint and the client polls it through). Each
/// completed sync appends a `SyncReport` — per-playlist created/updated/reconciled/imported with
/// +added/−removed counts — to `auditTrail`, persisted to disk (newest first, capped).
///
/// The per-user Music-User-Token is minted on-device per sync and never stored server-side, so this
/// is DEVICE-ONLY (needs an active Apple Music subscription + prior authorization).
@MainActor
@Observable
final class PlaylistAppleMusicSync {

    // MARK: Live progress

    struct SyncStep: Identifiable, Equatable, Codable {
        /// String-raw + Codable so the CURRENT RUN persists to disk: the step list must survive
        /// an app kill mid-sync (Levi 2026-07-29 — "show progress if I go to another app").
        /// `.interrupted` is what a persisted `.running` becomes on relaunch: the process died
        /// with the step underway; the stored jobId means tapping Sync RESUMES it.
        enum State: String, Equatable, Codable { case running, done, failed, interrupted }
        let id: Int
        var label: String
        var detail: String?
        var state: State
    }

    /// The persisted current/most-recent run: hydrated at launch so the last sync — finished,
    /// failed, or interrupted mid-flight — is always inspectable from Settings ▸ Apple Music.
    private struct RunSnapshot: Codable, Equatable {
        var startedMs: Double
        var updatedMs: Double
        var steps: [SyncStep]
        var completed: Bool
    }

    // MARK: Audit trail

    struct SyncReport: Codable, Equatable, Identifiable {
        var id: Double { dateMs }
        var dateMs: Double
        var changes: [Change]
        var errors: [String]
        var summary: String

        struct Change: Codable, Equatable, Identifiable {
            var id: String { "\(kind)|\(name)" }
            /// "created" | "updated" | "reconciled" | "imported"
            var kind: String
            var name: String
            var added: Int
            var removed: Int
            var detail: String?
        }
    }

    private(set) var isSyncing = false
    private(set) var steps: [SyncStep] = []
    private(set) var lastResult: String?
    /// Newest-first, capped at `auditCap`, persisted across launches.
    private(set) var auditTrail: [SyncReport] = []
    /// When the current/most-recent run started (ms epoch) — nil until the first sync ever.
    private(set) var currentRunStartedMs: Double?
    /// False while a run is live AND when the app died mid-run (the "interrupted" state the UI
    /// flags as resumable); true once a run ends — success or failure.
    private(set) var currentRunCompleted = true

    private static let auditCap = 20
    private let auditURL: URL
    private let runURL: URL
    private let client: AMPlaylistSyncClient
    /// On-device MusicKit transport for the destructive (remove + reorder) half of the hybrid —
    /// nil on macOS/Catalyst (library edits are unavailable there), where push stays create+append.
    private let transport: (any PlaylistWriteBackTransport)?

    /// Should the pull IMPORT Apple Music playlists with no local counterpart? A seam rather than a
    /// parameter, matching `pushAllowed`/`onboardingIncomplete`: every caller of `syncNow` would
    /// otherwise have to thread settings through. Wired at app init to
    /// `settings.amImportNewPlaylists`. **nil ⇒ FALSE** — the safe default is to import nothing,
    /// because the failure mode is copying someone's entire Apple Music library onto their device.
    @ObservationIgnored var importNewPlaylistsEnabled: (() -> Bool)?

    init(client: AMPlaylistSyncClient? = nil,
         transport: (any PlaylistWriteBackTransport)? = nil,
         auditURL: URL? = nil,
         runURL: URL? = nil) {
        self.client = client ?? AMPlaylistSyncClient()
        self.transport = transport ?? PlaylistWriteBack.makeDefaultTransport()
        self.auditURL = auditURL ?? Self.defaultAuditURL()
        self.runURL = runURL ?? Self.defaultRunURL()
        auditTrail = Self.loadAudit(from: self.auditURL)
        if let data = try? Data(contentsOf: Self.catalogLookupsURL()),
           let m = try? JSONDecoder().decode([String: CatalogLookup].self, from: data) {
            catalogLookups = m
        }
        // Hydrate the persisted current run so the last sync is inspectable across launches. A
        // snapshot that never completed means the process died mid-sync: mark its running steps
        // interrupted — the stored jobId makes the next Sync tap RESUME server-side, so this is a
        // "pick up where you left off", not a failure.
        if let data = try? Data(contentsOf: self.runURL),
           let snapshot = try? JSONDecoder().decode(RunSnapshot.self, from: data) {
            currentRunStartedMs = snapshot.startedMs
            currentRunCompleted = snapshot.completed
            steps = snapshot.steps.map { step in
                var s = step
                if !snapshot.completed, s.state == .running { s.state = .interrupted }
                return s
            }
        }
    }

    /// Whether the sync affordance should be offered (MusicKit enabled in this build).
    var isAvailable: Bool { AppleMusicCredentials.isEnabled }

    // MARK: Outgoing resolution (pure, testable)

    /// The SAME name normalization the server's push dedup uses (index.mjs normName): trim,
    /// lowercase, collapse internal whitespace. Client and server MUST agree on what "same name"
    /// means — a looser client match once let the pull re-import "Sap" next to local "Sap " while
    /// the push had just merged them.
    static func normName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// PURE (testable): every collection whose songs resolve to Apple Music catalog ids, as an
    /// outgoing push payload — the user's PLAYLISTS plus every POCKET that CAME FROM an Apple
    /// Music playlist (Levi 2026-07-29: the sync "is only syncing my playlists, not pockets that
    /// came from playlists"). Hand-made pockets (no Apple Music provenance) stay local by design —
    /// a DJ working set is not implicitly a public playlist; `linkPocketToSource` opts one in.
    /// Songs without an `appleMusicId` are dropped (only catalog songs can live in an Apple Music
    /// library playlist); a collection with none is dropped entirely.
    ///
    /// Collections whose names NORMALIZE EQUAL are merged into ONE outgoing list (ordered union) —
    /// the server targets one remote playlist per name, so two same-named locals pushed separately
    /// would fight over it (push re-appends what the other's reconcile just removed, forever).
    /// This also makes a converted pocket and its remote twin CONVERGE rather than duplicate.
    /// Track ids are de-duplicated in order for the same reason: a duplicate id absent remotely
    /// would be appended twice by one push.
    /// The Apple Music playlist id this outgoing entry is already bound to, if any. An entry can
    /// fold several local collections together; they should all carry the same link, so the first
    /// one found answers. nil ⇒ never pushed (or pushed before links existed) — resolve by name.
    static func linkedAMPlaylistId(for entry: AMPlaylistSyncClient.OutgoingPlaylist,
                                   collections: CollectionsStore) -> String? {
        for id in entry.localPlaylistIds {
            if let amId = collections.playlist(id)?.amPlaylistId, !amId.isEmpty { return amId }
        }
        for id in entry.localPocketIds {
            if let amId = collections.pocket(id)?.amPlaylistId, !amId.isEmpty { return amId }
        }
        return nil
    }

    /// What a push WOULD send, plus what it deliberately would not.
    struct OutgoingResolution {
        var playlists: [AMPlaylistSyncClient.OutgoingPlaylist]
        /// Collections that are set to push but carry nothing Apple Music can hold. They used to
        /// vanish from the payload with no trace, so a playlist of vinyl rips simply never appeared
        /// in Apple Music and nothing anywhere said why.
        var skipped: [Skipped]
        struct Skipped: Equatable {
            var name: String
            /// How many songs it has (all of them unhostable — that IS the reason).
            var songCount: Int
            var isPocket: Bool
        }
    }

    /// The thin wrapper the existing callers use.
    static func resolveOutgoing(collections: CollectionsStore, app: AppModel) -> [AMPlaylistSyncClient.OutgoingPlaylist] {
        resolveOutgoingDetailed(collections: collections, app: app).playlists
    }

    /// `resolvedCatalogIds` supplies store ids the INDEXER never resolved, looked up on device at
    /// push time (see `songsNeedingCatalogId`). Without it, a song with no `appleMusicId` is simply
    /// dropped — and a collection where that's true of every song disappears entirely.
    static func resolveOutgoingDetailed(collections: CollectionsStore, app: AppModel,
                                        resolvedCatalogIds: [String: String] = [:]) -> OutgoingResolution {
        var indexByKey: [String: Int] = [:]
        var out: [AMPlaylistSyncClient.OutgoingPlaylist] = []
        var seenByKey: [String: Set<String>] = [:]
        var seenNameByKey: [String: Set<String>] = [:]
        // PLURAL by necessity: resolveOutgoing merges name-colliding collections (a playlist
        // "Mix" and a pocket "Mix ") into ONE outgoing entry, so the push result's single id must
        // be stamped onto EVERY local collection that folded into it — otherwise the unstamped one
        // keeps matching by name and mints a duplicate on the next pass.
        var skipped: [OutgoingResolution.Skipped] = []
        func fold(name: String, songIds: [String], localId: String? = nil, isPocket: Bool = false) {
            let key = normName(name)
            if indexByKey[key] == nil {
                indexByKey[key] = out.count
                seenByKey[key] = []
                seenNameByKey[key] = []
                out.append(.init(name: name, description: nil, trackCatalogIds: []))
            }
            let i = indexByKey[key]!
            for songId in songIds {
                guard let song = app.songsById[songId],
                      let catalogId = song.appleMusicId ?? resolvedCatalogIds[songId] else { continue }
                guard seenByKey[key]!.insert(catalogId).inserted else { continue }
                // NAME+ARTIST duplicate gate (Levi 2026-07-29): the same recording under two
                // catalog ids must push once — the duplicate-flood killer, client half.
                guard seenNameByKey[key]!.insert(SongDuplicateJudge.key(name: song.name, artist: song.artist)).inserted else { continue }
                out[i].trackCatalogIds.append(catalogId)
                out[i].trackMeta.append(.init(id: catalogId, n: song.name, a: song.artist))
            }
            if let localId {
                if isPocket { out[i].localPocketIds.append(localId) }
                else { out[i].localPlaylistIds.append(localId) }
            }
            // Nothing hostable AFTER folding this collection in ⇒ it contributed nothing. Recorded
            // so the report can say so instead of the collection silently disappearing.
            if out[i].trackCatalogIds.isEmpty, !songIds.isEmpty {
                skipped.append(.init(name: name, songCount: songIds.count, isPocket: isPocket))
            }
        }
        // Per-collection DIRECTION gate (Levi 2026-07-29): "Get only"/"Off" collections never
        // push — the smart-playlist case (invisible to the write API; a push would mint a
        // regular-playlist duplicate forever).
        for pl in collections.playlists where pl.amSyncDir.allowsPush {
            fold(name: pl.name, songIds: collections.songIds(forPlaylist: pl.id), localId: pl.id)
        }
        // Pockets converted from (or linked to) an Apple Music playlist sync two-way like the
        // playlist they came from — either Apple Music source qualifies (the private catalog's
        // mirrors or the public on-device library's).
        for p in collections.pockets
        where p.hasSource && PlaylistWriteBack.isAppleMusicSource(p.sourceName ?? "")
            && p.amSyncDir.allowsPush {
            fold(name: p.name, songIds: collections.songIds(forPocket: p.id),
                 localId: p.id, isPocket: true)
        }
        let sendable = out.filter { !$0.trackCatalogIds.isEmpty }
        // A collection that folded into a name-colliding sibling which DID have hostable tracks is
        // not really skipped — drop those from the report.
        let sendableNames = Set(sendable.map { normName($0.name) })
        return OutgoingResolution(playlists: sendable,
                                  skipped: skipped.filter { !sendableNames.contains(normName($0.name)) })
    }

    /// Songs in PUSHABLE collections that carry no Apple Music store id — the ones the push would
    /// otherwise drop. Returned with enough identity for `PlaylistWriteBackTransport.resolveCatalogId`
    /// to look them up against the user's own Apple Music catalog.
    ///
    /// This is the gap that made a PocketDJ-built playlist never appear: the indexer resolves store
    /// ids for Apple Music library tracks, but a playlist of rips / digital files has none, so the
    /// payload came out empty and the playlist was dropped. The write-back path already resolves
    /// ids on device; the playlist push simply never used that machinery.
    ///
    /// SCOPED to `onlyCollectionsNamed` — the collections a dry run says would be DROPPED. Looking
    /// up every id-less song in every pushable collection instead meant hundreds of network round
    /// trips at the front of EVERY sync (including the nightly one), for songs whose collections
    /// were pushing perfectly well without them. A healthy library now pays nothing at all: the set
    /// is empty, so this returns immediately and no lookup happens.
    static func songsNeedingCatalogId(collections: CollectionsStore, app: AppModel,
                                      onlyCollectionsNamed: Set<String>) -> [(songId: String, song: WriteBackSong)] {
        guard !onlyCollectionsNamed.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [(songId: String, song: WriteBackSong)] = []
        func consider(_ songIds: [String]) {
            for id in songIds {
                guard let s = app.songsById[id], s.appleMusicId == nil, seen.insert(id).inserted else { continue }
                let title = s.name.trimmingCharacters(in: .whitespaces)
                let artist = s.artist.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty, !artist.isEmpty else { continue }
                out.append((id, WriteBackSong(appleMusicId: "", title: title, artist: artist,
                                              album: nil, durationMs: s.length)))
            }
        }
        for pl in collections.playlists
        where pl.amSyncDir.allowsPush && onlyCollectionsNamed.contains(normName(pl.name)) {
            consider(collections.songIds(forPlaylist: pl.id))
        }
        for p in collections.pockets
        where p.hasSource && PlaylistWriteBack.isAppleMusicSource(p.sourceName ?? "")
            && p.amSyncDir.allowsPush && onlyCollectionsNamed.contains(normName(p.name)) {
            consider(collections.songIds(forPocket: p.id))
        }
        return out
    }

    /// Per-pass cap on on-device catalog lookups. NOT a ceiling on what can ever sync: results are
    /// PERSISTED (`resolvedCatalogIds`), so each pass skips what it already knows and works on the
    /// next batch. A 1,000-song playlist finishes over five passes rather than stalling at 200.
    /// (Before persistence this was a true hard cap — every pass re-resolved the same first 200 and
    /// song 201 was never reached. That is exactly why the results are on disk.)
    static let catalogResolveCap = 200

    /// How long a MISS is trusted before we ask Apple again. Without this, a song Apple Music
    /// genuinely doesn't have would burn a lookup slot on every single sync, forever, crowding out
    /// songs that could actually resolve. With it, a track that later appears in the catalog is
    /// still picked up eventually.
    static let missRetryAfterMs: Double = 30 * 24 * 60 * 60 * 1000

    /// songId → what an on-device catalog lookup found. A hit carries the store id; a miss carries
    /// only the timestamp, so it can be retried after `missRetryAfterMs`.
    struct CatalogLookup: Codable, Equatable {
        var catalogId: String?
        var checkedAtMs: Double
    }

    /// Persisted lookup results. Device-local by design: it is a cache of what Apple answered, not
    /// user data, and each device can rebuild it for free.
    private(set) var catalogLookups: [String: CatalogLookup] = [:]

    /// The hits only, in the shape the payload builder wants.
    var resolvedCatalogIds: [String: String] {
        catalogLookups.compactMapValues(\.catalogId)
    }

    private func recordLookup(songId: String, catalogId: String?, nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        catalogLookups[songId] = CatalogLookup(catalogId: catalogId, checkedAtMs: nowMs)
    }

    /// Flush the cache to disk every `catalogSaveEvery` lookups, not just at the end of the batch.
    /// Leaving the app mid-sync is normal — the run comes back as `.interrupted` and resumes — and
    /// an end-of-batch-only save meant every lookup done before the interruption was thrown away
    /// and re-asked on resume. Small JSON, atomic write; flushing costs far less than re-asking.
    static let catalogSaveEvery = 25

    private func saveCatalogLookups() {
        if let data = try? JSONEncoder().encode(catalogLookups) {
            try? data.write(to: Self.catalogLookupsURL(), options: .atomic)
        }
    }

    nonisolated static func catalogLookupsURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-am-catalog-ids.json")
    }

    /// Which of `needing` still deserves a network call: never looked up, or a miss old enough to
    /// be worth re-asking. PURE so the chunking is testable without a network.
    static func pendingLookups(_ needing: [(songId: String, song: WriteBackSong)],
                               known: [String: CatalogLookup],
                               nowMs: Double = Date().timeIntervalSince1970 * 1000)
        -> [(songId: String, song: WriteBackSong)] {
        needing.filter { entry in
            guard let seen = known[entry.songId] else { return true }
            if seen.catalogId != nil { return false }                       // already resolved
            return nowMs - seen.checkedAtMs > missRetryAfterMs              // stale miss ⇒ re-ask
        }
    }

    /// PURE (testable): every local collection name (normalized) the pull-import dedupes against —
    /// PLAYLISTS and POCKETS both: a remote playlist whose local twin is a converted POCKET must
    /// not re-import as a duplicate playlist beside it.
    static func existingCollectionNames(collections: CollectionsStore) -> Set<String> {
        Set(collections.playlists.map { normName($0.name) })
            .union(collections.pockets.map { normName($0.name) })
    }

    /// PURE (testable): which pulled remote playlists should be imported locally. Skips any whose
    /// normalized name already exists locally, and collapses same-named remote copies (e.g. the
    /// duplicates an older buggy push created) to the FULLEST one — k copies import once, not k
    /// times. `existingNames` must already be normName-normalized.
    /// Every Apple Music playlist id a local collection is already bound to — by the durable link
    /// stamped at push time, or by the provenance a converted/duplicated collection carries.
    static func linkedRemoteIds(collections: CollectionsStore) -> Set<String> {
        var out = Set<String>()
        for pl in collections.playlists {
            if let id = pl.amPlaylistId, !id.isEmpty { out.insert(id) }
            if let id = pl.sourcePlaylistId, !id.isEmpty { out.insert(id) }
        }
        for p in collections.pockets {
            if let id = p.amPlaylistId, !id.isEmpty { out.insert(id) }
            if let id = p.sourcePlaylistId, !id.isEmpty { out.insert(id) }
        }
        return out
    }

    static func newImports(remote: [AMPlaylistSyncClient.RemotePlaylist],
                           existingNames: Set<String>,
                           linkedRemoteIds: Set<String> = []) -> [AMPlaylistSyncClient.RemotePlaylist] {
        var bestByKey: [String: AMPlaylistSyncClient.RemotePlaylist] = [:]
        var order: [String] = []
        for r in remote {
            let key = normName(r.name)
            // ALREADY OURS, BY IDENTITY. Matching on name alone re-imported a copy the user had
            // renamed locally: the local "Roadtrip 2026" no longer matched the remote "Roadtrip",
            // so the sync helpfully made a second one. An id can't drift the way a name does.
            if linkedRemoteIds.contains(r.id) { continue }
            guard !existingNames.contains(key) else { continue }
            if let current = bestByKey[key] {
                if r.trackCatalogIds.count > current.trackCatalogIds.count { bestByKey[key] = r }
            } else {
                bestByKey[key] = r
                order.append(key)
            }
        }
        return order.compactMap { bestByKey[$0] }
    }

    // MARK: Sync

    /// Which half of the two-way sync to run — the pane's "↑ Send to Apple Music" /
    /// "↓ Get from Apple Music" buttons map straight onto these; the primary button is `.both`.
    enum Direction {
        case both, push, pull
    }

    /// AUTO-RESUME (Levi 2026-07-29: "async and auto resume"): if the last run never completed
    /// (the persisted RunSnapshot hydrated with `completed == false` — the app was killed
    /// mid-sync), silently pick it back up: the client re-attaches to the stored server job and
    /// every half of the engine is idempotent, so re-running is safe. Called at launch/foreground
    /// (PocketDJApp) — the user never has to babysit the sync screen.
    func resumeIfInterrupted(collections: CollectionsStore, app: AppModel) async {
        guard !isSyncing, !currentRunCompleted, currentRunStartedMs != nil else { return }
        await syncNow(collections: collections, app: app, direction: .both)
    }

    /// Push ONE collection to Apple Music, on demand, from its ⋯ menu.
    ///
    /// Same engine as the full pass — the same on-device id resolution, the same idempotent
    /// create-if-absent + append-only-missing push, the same durable link stamp — but scoped to a
    /// single collection so the user doesn't have to run (and wait for) the whole library to get one
    /// playlist up. It writes a SyncReport like any other run, so it shows up in Settings ▸ Apple
    /// Music's sync history alongside the full passes; a per-collection sync that left no trace
    /// would be the same silent-drop problem in a new place.
    ///
    /// PUSH ONLY by design: pulling is a whole-library operation, and the user asked for "sync this
    /// one", not "reconcile everything".
    func syncCollection(playlistId: String? = nil, pocketId: String? = nil,
                        collections: CollectionsStore, app: AppModel) async {
        guard !isSyncing else { return }
        guard let name = playlistId.flatMap({ collections.playlist($0)?.name })
                ?? pocketId.flatMap({ collections.pocket($0)?.name }) else { return }
        isSyncing = true
        lastResult = nil
        steps = []
        currentRunStartedMs = Date().timeIntervalSince1970 * 1000
        currentRunCompleted = false
        persistCurrentRun()
        defer {
            isSyncing = false
            currentRunCompleted = true
            persistCurrentRun()
        }

        var changes: [SyncReport.Change] = []
        var errors: [String] = []
        let songIds = playlistId.map { collections.songIds(forPlaylist: $0) }
            ?? pocketId.map { collections.songIds(forPocket: $0) } ?? []

        do {
            // 1. Resolve store ids for this collection's songs that the indexer never matched.
            var resolvedIds: [String: String] = [:]
            let needing: [(songId: String, song: WriteBackSong)] = songIds.compactMap { id in
                guard let s = app.songsById[id], s.appleMusicId == nil else { return nil }
                let t = s.name.trimmingCharacters(in: .whitespaces)
                let a = s.artist.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !a.isEmpty else { return nil }
                return (id, WriteBackSong(appleMusicId: "", title: t, artist: a, album: nil, durationMs: s.length))
            }
            // Only pay for lookups when this collection would otherwise send NOTHING. If it
            // already has hostable tracks, the push works today and the round trips buy nothing.
            let alreadyHostable = !Self.catalogIds(for: songIds, app: app, resolved: [:]).isEmpty
            resolvedIds = resolvedCatalogIds
            let pending = Self.pendingLookups(needing, known: catalogLookups)
            if let transport, transport.canWrite, !pending.isEmpty, !alreadyHostable {
                beginStep("Matching songs to Apple Music")
                var matched = 0, looked = 0
                for (songId, song) in pending.prefix(Self.catalogResolveCap) {
                    if Task.isCancelled { break }
                    looked += 1
                    updateStep("Looking up “\(song.title)”")
                    let id = try? await transport.resolveCatalogId(for: song)
                    recordLookup(songId: songId, catalogId: id)
                    if let id { resolvedIds[songId] = id; matched += 1 }
                    if looked % Self.catalogSaveEvery == 0 { saveCatalogLookups() }
                }
                saveCatalogLookups()
                let remaining = max(0, pending.count - looked)
                finishStep("\(matched) of \(looked) matched"
                           + (remaining > 0 ? " · \(remaining) to go, sync again to continue" : ""))
            }

            // 2. Build the payload for THIS collection only.
            let catalogIds = Self.catalogIds(for: songIds, app: app, resolved: resolvedIds)
            guard !catalogIds.isEmpty else {
                let detail = songIds.isEmpty ? "empty"
                    : "no Apple Music match for any of its \(songIds.count) songs"
                changes.append(.init(kind: "skipped", name: name, added: 0, removed: 0, detail: detail))
                let summary = "“\(name)” has nothing Apple Music can hold — \(detail)."
                lastResult = summary
                appendAudit(.init(dateMs: Date().timeIntervalSince1970 * 1000,
                                  changes: changes, errors: errors, summary: summary))
                return
            }
            var entry = AMPlaylistSyncClient.OutgoingPlaylist(
                name: name, description: nil, trackCatalogIds: catalogIds.map(\.id))
            entry.trackMeta = catalogIds.map { .init(id: $0.id, n: $0.name, a: $0.artist) }
            if let playlistId { entry.localPlaylistIds = [playlistId] }
            if let pocketId { entry.localPocketIds = [pocketId] }

            // 3. Push it — the same idempotent server half the full pass uses.
            beginStep("Sending “\(name)” to Apple Music")
            let pushed = try await client.push([entry]) { [weak self] p in self?.updateStep(p.display) }
            for row in pushed.playlists {
                guard let amId = row.id else { continue }
                if let playlistId { collections.linkToAppleMusic(playlistId: playlistId, amPlaylistId: amId) }
                if let pocketId { collections.linkToAppleMusic(pocketId: pocketId, amPlaylistId: amId) }
            }
            for row in pushed.playlists where row.created || row.added > 0 {
                changes.append(.init(kind: row.created ? "created" : "updated", name: row.name,
                                     added: row.added, removed: 0,
                                     detail: row.total.map { "\(row.added) of \($0) tracks sent" }))
            }
            for f in pushed.errors { errors.append("\(f.name): \(f.error)") }
            let added = pushed.playlists.reduce(0) { $0 + $1.added }
            let summary = errors.isEmpty
                ? (pushed.playlists.contains(where: \.created)
                    ? "Created “\(name)” in Apple Music with \(added) track\(added == 1 ? "" : "s")."
                    : added > 0 ? "Added \(added) track\(added == 1 ? "" : "s") to “\(name)”."
                                : "“\(name)” was already up to date.")
                : "“\(name)”: \(errors.joined(separator: "; "))"
            finishStep(summary)
            lastResult = summary
            appendAudit(.init(dateMs: Date().timeIntervalSince1970 * 1000,
                              changes: changes, errors: errors, summary: summary))
        } catch {
            failStep(error.localizedDescription)
            errors.append(error.localizedDescription)
            lastResult = error.localizedDescription
            appendAudit(.init(dateMs: Date().timeIntervalSince1970 * 1000,
                              changes: changes, errors: errors,
                              summary: "“\(name)” failed: \(error.localizedDescription)"))
        }
    }

    /// Catalog ids for a song list, applying the SAME dedup gates the full push uses: one entry per
    /// catalog id, and one per name+artist identity (the duplicate-flood killer).
    static func catalogIds(for songIds: [String], app: AppModel,
                           resolved: [String: String]) -> [(id: String, name: String, artist: String)] {
        var seenId = Set<String>(), seenIdentity = Set<String>()
        var out: [(id: String, name: String, artist: String)] = []
        for songId in songIds {
            guard let song = app.songsById[songId],
                  let catalogId = song.appleMusicId ?? resolved[songId] else { continue }
            guard seenId.insert(catalogId).inserted else { continue }
            guard seenIdentity.insert(SongDuplicateJudge.key(name: song.name, artist: song.artist)).inserted else { continue }
            out.append((catalogId, song.name, song.artist))
        }
        return out
    }

    func syncNow(collections: CollectionsStore, app: AppModel, direction: Direction = .both) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastResult = nil
        steps = []
        currentRunStartedMs = Date().timeIntervalSince1970 * 1000
        currentRunCompleted = false
        persistCurrentRun()
        defer { isSyncing = false }

        var changes: [SyncReport.Change] = []
        var errors: [String] = []
        do {
            if direction != .pull {
                // ── 1. Resolve what we can push ─────────────────────────────────────────────────
                beginStep("Preparing playlists")
                // RESOLVE MISSING STORE IDS ON DEVICE first. The indexer only mints Apple Music
                // ids for Apple Music library tracks, so a playlist built from rips or digital
                // files resolved to an EMPTY payload and was dropped without a word. The write-back
                // transport can look a song up by title+artist against the user's own catalog —
                // this is the same machinery, applied to the playlist push.
                // A DRY RUN FIRST: only the collections that would actually be dropped are worth
                // paying network lookups for. Everything already pushing is left alone, so a
                // healthy library adds zero round trips to its sync.
                var resolvedIds: [String: String] = [:]
                let dryRun = Self.resolveOutgoingDetailed(collections: collections, app: app)
                resolvedIds = resolvedCatalogIds   // everything earlier passes already resolved
                let needing = Self.songsNeedingCatalogId(
                    collections: collections, app: app,
                    onlyCollectionsNamed: Set(dryRun.skipped.map { Self.normName($0.name) }))
                let pending = Self.pendingLookups(needing, known: catalogLookups)
                if let transport, transport.canWrite, !pending.isEmpty {
                    beginStep("Matching songs to Apple Music")
                    var matched = 0, looked = 0
                    for (songId, song) in pending.prefix(Self.catalogResolveCap) {
                        if Task.isCancelled { break }
                        looked += 1
                        updateStep("Looking up “\(song.title)”")
                        let id = try? await transport.resolveCatalogId(for: song)
                        recordLookup(songId: songId, catalogId: id)
                        if let id { resolvedIds[songId] = id; matched += 1 }
                        // Checkpoint, so backgrounding the app mid-batch keeps this progress.
                        if looked % Self.catalogSaveEvery == 0 { saveCatalogLookups() }
                    }
                    saveCatalogLookups()
                    // Say what is LEFT rather than silently stopping — the remainder is picked up
                    // by the next pass, because the results above are on disk.
                    let remaining = max(0, pending.count - looked)
                    finishStep("\(matched) of \(looked) matched"
                               + (remaining > 0 ? " · \(remaining) to go, continuing next sync" : ""))
                }
                let resolution = Self.resolveOutgoingDetailed(collections: collections, app: app,
                                                              resolvedCatalogIds: resolvedIds)
                let outgoing = resolution.playlists
                // NEVER DROP SILENTLY. A collection set to push that has nothing Apple Music can
                // hold used to vanish from the payload with no trace anywhere.
                for skip in resolution.skipped {
                    changes.append(.init(kind: "skipped", name: skip.name, added: 0, removed: 0,
                                         detail: skip.songCount == 0
                                             ? "empty"
                                             : "no Apple Music match for any of its \(skip.songCount) songs"))
                }
                let trackTotal = outgoing.reduce(0) { $0 + $1.trackCatalogIds.count }
                finishStep("\(outgoing.count) playlist\(outgoing.count == 1 ? "" : "s") · \(trackTotal) tracks")

                // ── 2. PUSH (idempotent: create-if-absent + append-only-missing) ────────────────
                beginStep("Pushing to Apple Music")
                let pushed = try await client.push(outgoing) { [weak self] p in self?.updateStep(p.display) }
                // STAMP THE DURABLE LINK. The server already returns the Apple Music playlist id
                // for every row and the client already decodes it — it was simply discarded, which
                // is why a rename in PocketDJ made the next pass create a SECOND playlist instead
                // of updating the first. Match rows back to the outgoing entries by the same
                // normalized name the fold used, then stamp EVERY local collection that folded in.
                let outgoingByKey = Dictionary(outgoing.map { (Self.normName($0.name), $0) },
                                               uniquingKeysWith: { a, _ in a })
                for row in pushed.playlists {
                    guard let amId = row.id, let entry = outgoingByKey[Self.normName(row.name)] else { continue }
                    for pid in entry.localPlaylistIds {
                        collections.linkToAppleMusic(playlistId: pid, amPlaylistId: amId)
                    }
                    for pid in entry.localPocketIds {
                        collections.linkToAppleMusic(pocketId: pid, amPlaylistId: amId)
                    }
                }
                let createdRows = pushed.playlists.filter(\.created)
                let updatedRows = pushed.playlists.filter { !$0.created && $0.added > 0 }
                for row in pushed.playlists where row.created || row.added > 0 {
                    changes.append(.init(kind: row.created ? "created" : "updated",
                                         name: row.name, added: row.added, removed: 0,
                                         detail: row.total.map { "\(row.added) of \($0) tracks sent" }))
                }
                for failure in pushed.errors { errors.append("\(failure.name): \(failure.error)") }
                let addedTotal = updatedRows.reduce(0) { $0 + $1.added }
                finishStep(pushSummary(created: createdRows.count, updated: updatedRows.count,
                                       addedTracks: addedTotal, unchanged: pushed.playlists.count - createdRows.count - updatedRows.count,
                                       failed: pushed.errors.count))

                // ── 3. RECONCILE (on-device removals + reorders; skips just-created playlists) ──
                if let transport, transport.canWrite {
                    beginStep("Reconciling removals & reorders")
                    var reconciled = 0
                    let justCreated = Set(createdRows.map { Self.normName($0.name) })
                    // Never reconcile the same REMOTE playlist twice in one pass — two outgoing
                    // lists resolving to one library playlist would replace-all it back and forth.
                    var reconciledIds = Set<String>()
                    for pl in outgoing where !justCreated.contains(Self.normName(pl.name)) {
                        updateStep("Checking “\(pl.name)”")
                        // PREFER THE DURABLE LINK. Resolving by name here would target the wrong
                        // playlist the moment the user renames one in PocketDJ — and reconcile is a
                        // REPLACE-ALL, so aiming it at the wrong list would overwrite that list's
                        // contents. The stored id came from the push result and survives renames on
                        // both sides. Fall back to the name only when there is no link yet.
                        // (`??` can't take an async right-hand side, so this is spelled out.)
                        let resolved: String?
                        if let linked = Self.linkedAMPlaylistId(for: pl, collections: collections) {
                            resolved = linked
                        } else {
                            resolved = try? await transport.resolvePlaylistId(
                                name: pl.name, expectedAppleMusicIds: pl.trackCatalogIds)
                        }
                        guard let amId = resolved,
                              reconciledIds.insert(amId).inserted else { continue }
                        if case .edited(let count, let added, let removed) = try? await transport.reconcile(
                            playlistId: amId, orderedAppleMusicIds: pl.trackCatalogIds) {
                            reconciled += 1
                            changes.append(.init(kind: "reconciled", name: pl.name,
                                                 added: added, removed: removed,
                                                 detail: "now \(count) tracks in PocketDJ order"))
                        }
                    }
                    finishStep(reconciled == 0 ? "Nothing to fix" : "\(reconciled) playlist\(reconciled == 1 ? "" : "s") re-ordered/pruned")
                }
            }

            if direction == .push {
                let summary = reportSummary(changes: changes, errors: errors)
                lastResult = summary
                currentRunCompleted = true
                persistCurrentRun()
                appendAudit(.init(dateMs: Date().timeIntervalSince1970 * 1000,
                                  changes: changes, errors: errors, summary: summary))
                return
            }

            // ── 4. PULL ─────────────────────────────────────────────────────────────────────────
            beginStep("Reading Apple Music playlists")
            let remote = try await client.pull { [weak self] p in self?.updateStep(p.display) }
            finishStep("\(remote.count) playlist\(remote.count == 1 ? "" : "s") read")

            // ── 5. IMPORT the new ones ──────────────────────────────────────────────────────────
            beginStep("Importing new playlists")
            // One-pass reverse index: Apple Music catalog id -> local song id.
            var localByAppleMusicId: [String: String] = [:]
            localByAppleMusicId.reserveCapacity(app.songsById.count)
            for (id, song) in app.songsById {
                if let am = song.appleMusicId { localByAppleMusicId[am] = id }
            }
            // normName on BOTH sides (matching the server's push dedup) + same-name collapse in
            // `newImports` — otherwise the pull re-imports what the push just merged ("Sap " vs
            // "Sap") or imports k same-named remote dupes as k locals.
            let existingNames = Self.existingCollectionNames(collections: collections)
            // Provenance stamp (parity review): when an Apple-Music SOURCE playlist mirror with
            // the same normalized name exists (the on-device library index or the private
            // catalog), the import arrives LINKED to it — so instant write-back, the Send
            // backfill, force-sync, and source-follow all work on it, exactly like a duplicate
            // made from the mirror itself.
            var mirrorByName: [String: SourcePlaylist] = [:]
            for sp in app.indexPlaylists where PlaylistWriteBack.isAppleMusicSource(sp.sourceName) {
                let key = Self.normName(sp.name)
                if mirrorByName[key] == nil { mirrorByName[key] = sp }
            }
            var imported = 0
            // IMPORT IS OPT-IN. This step used to copy EVERY Apple Music library playlist that had
            // no local counterpart onto the device — so an automatic pass could clone the user's
            // whole Apple Music library into PocketDJ. Off by default now: sync touches only the
            // collections the user explicitly converted or duplicated. Reported rather than
            // silently skipped, so "nothing appeared" is never a mystery.
            let unmatched = Self.newImports(remote: remote, existingNames: existingNames,
                                            linkedRemoteIds: Self.linkedRemoteIds(collections: collections))
            let mayImport = importNewPlaylistsEnabled?() ?? false
            if !mayImport, !unmatched.isEmpty {
                changes.append(.init(
                    kind: "not imported",
                    name: "\(unmatched.count) Apple Music playlist\(unmatched.count == 1 ? "" : "s")",
                    added: 0, removed: 0,
                    detail: "left in Apple Music — turn on “Import new Apple Music playlists” to copy them here"))
            }
            for r in (mayImport ? unmatched : []) {
                // NAME+ARTIST duplicate gate on the way IN too: two remote ids resolving to two
                // local twins of the same recording import once.
                var seenSongKeys = Set<String>()
                let localIds = r.trackCatalogIds.compactMap { localByAppleMusicId[$0] }.filter { id in
                    guard let song = app.songsById[id] else { return true }
                    return seenSongKeys.insert(SongDuplicateJudge.key(name: song.name, artist: song.artist)).inserted
                }
                _ = collections.createPlaylist(r.name, songIds: localIds,
                                               source: mirrorByName[Self.normName(r.name)])
                changes.append(.init(kind: "imported", name: r.name,
                                     added: localIds.count, removed: 0,
                                     detail: "\(localIds.count) of \(r.trackCatalogIds.count) tracks matched locally"))
                imported += 1
            }
            finishStep(imported == 0 ? "Nothing new" : "\(imported) imported")

            let summary = reportSummary(changes: changes, errors: errors)
            lastResult = summary
            currentRunCompleted = true
            persistCurrentRun()
            appendAudit(.init(dateMs: Date().timeIntervalSince1970 * 1000,
                              changes: changes, errors: errors, summary: summary))
        } catch {
            failStep(error.localizedDescription)
            errors.append(error.localizedDescription)
            lastResult = error.localizedDescription
            currentRunCompleted = true
            persistCurrentRun()
            appendAudit(.init(dateMs: Date().timeIntervalSince1970 * 1000,
                              changes: changes, errors: errors,
                              summary: "Failed: \(error.localizedDescription)"))
        }
    }

    // MARK: Step helpers

    /// Every mutation persists the run snapshot: the step list must be re-readable after an app
    /// kill mid-sync, so the disk copy tracks the live one (tiny JSON, atomic write, ≤1 per poll).
    private func beginStep(_ label: String) {
        steps.append(.init(id: steps.count, label: label, detail: nil, state: .running))
        persistCurrentRun()
    }
    private func updateStep(_ detail: String) {
        guard let i = steps.lastIndex(where: { $0.state == .running }) else { return }
        steps[i].detail = detail
        persistCurrentRun()
    }
    private func finishStep(_ detail: String? = nil) {
        guard let i = steps.lastIndex(where: { $0.state == .running }) else { return }
        steps[i].state = .done
        if let detail { steps[i].detail = detail }
        persistCurrentRun()
    }
    private func failStep(_ detail: String) {
        guard let i = steps.lastIndex(where: { $0.state == .running }) else { return }
        steps[i].state = .failed
        steps[i].detail = detail
        persistCurrentRun()
    }

    // MARK: Summaries (pure, testable)

    static func pushSummaryText(created: Int, updated: Int, addedTracks: Int, unchanged: Int, failed: Int) -> String {
        var parts: [String] = []
        if created > 0 { parts.append("created \(created)") }
        if updated > 0 { parts.append("updated \(updated) (+\(addedTracks) song\(addedTracks == 1 ? "" : "s"))") }
        if unchanged > 0 { parts.append("\(unchanged) already in sync") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Nothing to push" : parts.joined(separator: " · ")
    }
    private func pushSummary(created: Int, updated: Int, addedTracks: Int, unchanged: Int, failed: Int) -> String {
        Self.pushSummaryText(created: created, updated: updated, addedTracks: addedTracks, unchanged: unchanged, failed: failed)
    }

    static func reportSummaryText(changes: [SyncReport.Change], errors: [String]) -> String {
        let created = changes.filter { $0.kind == "created" }.count
        let updated = changes.filter { $0.kind == "updated" }.count
        let reconciled = changes.filter { $0.kind == "reconciled" }.count
        let imported = changes.filter { $0.kind == "imported" }.count
        var parts: [String] = []
        if created > 0 { parts.append("\(created) created") }
        if updated > 0 { parts.append("\(updated) updated") }
        if reconciled > 0 { parts.append("\(reconciled) reconciled") }
        if imported > 0 { parts.append("\(imported) imported") }
        if parts.isEmpty { parts.append("Everything in sync") }
        if !errors.isEmpty { parts.append("\(errors.count) error\(errors.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
    private func reportSummary(changes: [SyncReport.Change], errors: [String]) -> String {
        Self.reportSummaryText(changes: changes, errors: errors)
    }

    // MARK: Audit persistence

    nonisolated static func defaultAuditURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-am-sync-audit.json")
    }

    nonisolated static func defaultRunURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-am-sync-current.json")
    }

    private func persistCurrentRun() {
        guard let startedMs = currentRunStartedMs else { return }
        let snapshot = RunSnapshot(startedMs: startedMs,
                                   updatedMs: Date().timeIntervalSince1970 * 1000,
                                   steps: steps,
                                   completed: currentRunCompleted)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: runURL, options: .atomic)
        }
    }

    private static func loadAudit(from url: URL) -> [SyncReport] {
        guard let data = try? Data(contentsOf: url),
              let reports = try? JSONDecoder().decode([SyncReport].self, from: data) else { return [] }
        return reports
    }

    /// READ-MERGE-WRITE, not overwrite: another instance (a second window's Settings panel, or a
    /// sync still finishing after this panel was re-entered) may have appended reports since this
    /// instance loaded — a blind write from a stale in-memory copy would silently drop them.
    private func appendAudit(_ report: SyncReport) {
        var merged = Self.loadAudit(from: auditURL)
        merged.insert(report, at: 0)
        var seen = Set<Double>()
        merged = merged.filter { seen.insert($0.dateMs).inserted }
        merged.sort { $0.dateMs > $1.dateMs }
        if merged.count > Self.auditCap { merged.removeLast(merged.count - Self.auditCap) }
        auditTrail = merged
        if let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: auditURL, options: .atomic)
        }
    }
}
