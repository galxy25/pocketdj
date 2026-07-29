import Foundation
import Observation

/// Coordinates bidirectional PocketDJ ↔ Apple Music library-playlist sync (WS2) via the
/// `AMPlaylistSyncClient` (the AWS Lambda) — replacing the iMac/Tailscale path.
///
/// • PUSH — every PocketDJ playlist whose songs resolve to Apple Music catalog ids is (re)created
///   in the user's Apple Music library with those tracks (server-side create + append). Reflecting
///   a REMOVAL or REORDER in an EXISTING Apple Music playlist is not possible server-side (the Web
///   API is append-only) — that is the on-device MusicKit `MusicLibrary.edit` half of the hybrid
///   (see `PlaylistWriteBack`), a device-gated follow-up. Additive mirroring works today.
/// • PULL — every Apple Music library playlist not already present locally (matched by name) is
///   imported as a PocketDJ playlist, its catalog tracks mapped back to local song ids.
///
/// The per-user Music-User-Token is minted on-device per sync and never stored server-side, so this
/// is DEVICE-ONLY (needs an active Apple Music subscription + prior authorization).
@MainActor
@Observable
final class PlaylistAppleMusicSync {
    private(set) var isSyncing = false
    private(set) var lastResult: String?

    private let client: AMPlaylistSyncClient
    /// On-device MusicKit transport for the destructive (remove + reorder) half of the hybrid —
    /// nil on macOS/Catalyst (library edits are unavailable there), where push stays create+append.
    private let transport: (any PlaylistWriteBackTransport)?
    init(client: AMPlaylistSyncClient? = nil, transport: (any PlaylistWriteBackTransport)? = nil) {
        self.client = client ?? AMPlaylistSyncClient()
        self.transport = transport ?? PlaylistWriteBack.makeDefaultTransport()
    }

    /// Whether the sync affordance should be offered (MusicKit enabled in this build).
    var isAvailable: Bool { AppleMusicCredentials.isEnabled }

    /// PURE (testable): every PocketDJ playlist whose songs resolve to Apple Music catalog ids,
    /// as an outgoing push payload. A playlist with no Apple-Music-hostable songs is dropped (only
    /// songs carrying an `appleMusicId` can live in an Apple Music library playlist).
    static func resolveOutgoing(collections: CollectionsStore, app: AppModel) -> [AMPlaylistSyncClient.OutgoingPlaylist] {
        collections.playlists.compactMap { pl in
            let catalogIds = collections.songIds(forPlaylist: pl.id)
                .compactMap { app.songsById[$0]?.appleMusicId }
            guard !catalogIds.isEmpty else { return nil }
            return .init(name: pl.name, description: nil, trackCatalogIds: catalogIds)
        }
    }

    func syncNow(collections: CollectionsStore, app: AppModel) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastResult = nil
        defer { isSyncing = false }
        do {
            // ── PUSH: PocketDJ playlists -> Apple Music (create + append) ──────────────────────
            let outgoing = Self.resolveOutgoing(collections: collections, app: app)
            let pushed = try await client.push(outgoing)

            // ── HYBRID DESTRUCTIVE HALF: reflect REMOVALS + REORDERS into existing app-created AM
            // playlists via on-device MusicKit (the Web API is append-only, so this is the only way
            // to remove or re-order). Best-effort + safe: reconcile skips playlists this app didn't
            // create and never edits toward an empty/partial list (see transport.reconcile).
            var reconciled = 0
            if let transport, transport.canWrite {
                for pl in outgoing {
                    guard let amId = try? await transport.resolvePlaylistId(
                        name: pl.name, expectedAppleMusicIds: pl.trackCatalogIds) else { continue }
                    if case .edited = try? await transport.reconcile(
                        playlistId: amId, orderedAppleMusicIds: pl.trackCatalogIds) {
                        reconciled += 1
                    }
                }
            }

            // ── PULL: Apple Music playlists -> PocketDJ (import the new ones) ───────────────────
            let remote = try await client.pull()
            // One-pass reverse index: Apple Music catalog id -> local song id.
            var localByAppleMusicId: [String: String] = [:]
            localByAppleMusicId.reserveCapacity(app.songsById.count)
            for (id, song) in app.songsById {
                if let am = song.appleMusicId { localByAppleMusicId[am] = id }
            }
            let existingNames = Set(collections.playlists.map { $0.name.lowercased() })
            var imported = 0
            for r in remote where !existingNames.contains(r.name.lowercased()) {
                let localIds = r.trackCatalogIds.compactMap { localByAppleMusicId[$0] }
                _ = collections.createPlaylist(r.name, songIds: localIds)
                imported += 1
            }

            var summary = "Pushed \(pushed.created.count) to Apple Music, imported \(imported)."
            if reconciled > 0 { summary += " Reconciled \(reconciled)." }
            if !pushed.errors.isEmpty { summary += " \(pushed.errors.count) push error(s)." }
            lastResult = summary
        } catch {
            lastResult = error.localizedDescription
        }
    }
}
