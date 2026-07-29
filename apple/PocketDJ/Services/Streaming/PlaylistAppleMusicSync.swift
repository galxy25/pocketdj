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

    init(client: AMPlaylistSyncClient? = nil,
         transport: (any PlaylistWriteBackTransport)? = nil,
         auditURL: URL? = nil,
         runURL: URL? = nil) {
        self.client = client ?? AMPlaylistSyncClient()
        self.transport = transport ?? PlaylistWriteBack.makeDefaultTransport()
        self.auditURL = auditURL ?? Self.defaultAuditURL()
        self.runURL = runURL ?? Self.defaultRunURL()
        auditTrail = Self.loadAudit(from: self.auditURL)
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

    /// PURE (testable): every PocketDJ playlist whose songs resolve to Apple Music catalog ids,
    /// as an outgoing push payload. A playlist with no Apple-Music-hostable songs is dropped (only
    /// songs carrying an `appleMusicId` can live in an Apple Music library playlist).
    ///
    /// Playlists whose names NORMALIZE EQUAL are merged into ONE outgoing list (ordered union) —
    /// the server targets one remote playlist per name, so two same-named locals pushed separately
    /// would fight over it (push re-appends what the other's reconcile just removed, forever).
    /// Track ids are de-duplicated in order for the same reason: a duplicate id absent remotely
    /// would be appended twice by one push.
    static func resolveOutgoing(collections: CollectionsStore, app: AppModel) -> [AMPlaylistSyncClient.OutgoingPlaylist] {
        var indexByKey: [String: Int] = [:]
        var out: [AMPlaylistSyncClient.OutgoingPlaylist] = []
        var seenByKey: [String: Set<String>] = [:]
        for pl in collections.playlists {
            let catalogIds = collections.songIds(forPlaylist: pl.id)
                .compactMap { app.songsById[$0]?.appleMusicId }
            guard !catalogIds.isEmpty else { continue }
            let key = normName(pl.name)
            if indexByKey[key] == nil {
                indexByKey[key] = out.count
                seenByKey[key] = []
                out.append(.init(name: pl.name, description: nil, trackCatalogIds: []))
            }
            let i = indexByKey[key]!
            for id in catalogIds where seenByKey[key]!.insert(id).inserted {
                out[i].trackCatalogIds.append(id)
            }
        }
        return out.filter { !$0.trackCatalogIds.isEmpty }
    }

    /// PURE (testable): which pulled remote playlists should be imported locally. Skips any whose
    /// normalized name already exists locally, and collapses same-named remote copies (e.g. the
    /// duplicates an older buggy push created) to the FULLEST one — k copies import once, not k
    /// times. `existingNames` must already be normName-normalized.
    static func newImports(remote: [AMPlaylistSyncClient.RemotePlaylist],
                           existingNames: Set<String>) -> [AMPlaylistSyncClient.RemotePlaylist] {
        var bestByKey: [String: AMPlaylistSyncClient.RemotePlaylist] = [:]
        var order: [String] = []
        for r in remote {
            let key = normName(r.name)
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

    func syncNow(collections: CollectionsStore, app: AppModel) async {
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
            // ── 1. Resolve what we can push ─────────────────────────────────────────────────────
            beginStep("Preparing playlists")
            let outgoing = Self.resolveOutgoing(collections: collections, app: app)
            let trackTotal = outgoing.reduce(0) { $0 + $1.trackCatalogIds.count }
            finishStep("\(outgoing.count) playlist\(outgoing.count == 1 ? "" : "s") · \(trackTotal) tracks")

            // ── 2. PUSH (idempotent: create-if-absent + append-only-missing) ────────────────────
            beginStep("Pushing to Apple Music")
            let pushed = try await client.push(outgoing) { [weak self] p in self?.updateStep(p.display) }
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

            // ── 3. RECONCILE (on-device removals + reorders; skips just-created playlists) ──────
            if let transport, transport.canWrite {
                beginStep("Reconciling removals & reorders")
                var reconciled = 0
                let justCreated = Set(createdRows.map { Self.normName($0.name) })
                // Never reconcile the same REMOTE playlist twice in one pass — two outgoing lists
                // resolving to one library playlist would replace-all it back and forth.
                var reconciledIds = Set<String>()
                for pl in outgoing where !justCreated.contains(Self.normName(pl.name)) {
                    updateStep("Checking “\(pl.name)”")
                    guard let amId = try? await transport.resolvePlaylistId(
                        name: pl.name, expectedAppleMusicIds: pl.trackCatalogIds),
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
            let existingNames = Set(collections.playlists.map { Self.normName($0.name) })
            var imported = 0
            for r in Self.newImports(remote: remote, existingNames: existingNames) {
                let localIds = r.trackCatalogIds.compactMap { localByAppleMusicId[$0] }
                _ = collections.createPlaylist(r.name, songIds: localIds)
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
