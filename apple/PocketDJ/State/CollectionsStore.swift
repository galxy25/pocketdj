import SwiftUI
import Observation

/// On-device store for pockets + playlists, persisted as the versioned
/// `CollectionsDocument`. Operations mirror the PWA's `useCollectionsStore`.
@MainActor
@Observable
final class CollectionsStore {
    private(set) var pockets: [Pocket] = []
    private(set) var playlists: [Playlist] = []
    private(set) var setlists: [Setlist] = []
    private(set) var lastAddTarget: AddTarget?
    private let fileURL: URL

    /// The catalog the realize engine resolves ids against (wired at launch, like
    /// AppModel.settings/edits). Weak so the store never retains the app graph.
    weak var app: AppModel?

    init(fileURL: URL = CollectionsStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let doc = try? CollectionsCodec.decode(data) {
            pockets = doc.pockets
            playlists = doc.playlists
            setlists = doc.setlists
            lastAddTarget = doc.lastAddTarget
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-collections.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-collections.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    private var now: Double { Date().timeIntervalSince1970 * 1000 }
    func pocket(_ id: String) -> Pocket? { pockets.first { $0.id == id } }
    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }
    func setlist(_ id: String) -> Setlist? { setlists.first { $0.id == id } }
    /// Setlists for a playlist, most-recent first (a performance history).
    func setlists(forPlaylist id: String) -> [Setlist] {
        setlists.filter { $0.playlistId == id }.sorted { $0.generatedAt > $1.generatedAt }
    }

    // MARK: Pockets

    @discardableResult
    func createPocket(_ name: String, kind: PocketKind = .harmonic) -> Pocket {
        let p = CollectionsFactory.makePocket(name, kind: kind, now: now)
        pockets.append(p); save(); return p
    }
    func renamePocket(_ id: String, _ name: String) { mutatePocket(id) { $0.name = name } }
    func deletePocket(_ id: String) {
        pockets.removeAll { $0.id == id }
        for i in pockets.indices { pockets[i].childPocketIds.removeAll { $0 == id } }
        save()
    }
    func addSong(_ songId: String, toPocket id: String) {
        mutatePocket(id) { if !$0.songIds.contains(songId) { $0.songIds.append(songId) } }
    }
    func addAlbum(_ albumId: String, toPocket id: String) {
        mutatePocket(id) { if !$0.albumIds.contains(albumId) { $0.albumIds.append(albumId) } }
    }
    /// Nest `childId` under `parentId`; returns false (no-op) if it would form a cycle.
    @discardableResult
    func addChildPocket(_ childId: String, toPocket parentId: String) -> Bool {
        guard childId != parentId, !wouldCycle(parent: parentId, child: childId) else { return false }
        mutatePocket(parentId) { if !$0.childPocketIds.contains(childId) { $0.childPocketIds.append(childId) } }
        return true
    }
    func removeSong(_ songId: String, fromPocket id: String) { mutatePocket(id) { $0.songIds.removeAll { $0 == songId } } }
    func removeAlbum(_ albumId: String, fromPocket id: String) { mutatePocket(id) { $0.albumIds.removeAll { $0 == albumId } } }
    func removeChildPocket(_ childId: String, fromPocket id: String) { mutatePocket(id) { $0.childPocketIds.removeAll { $0 == childId } } }

    /// True if making `child` a child of `parent` would create a cycle (parent is
    /// reachable from child via childPocketIds).
    func wouldCycle(parent: String, child: String) -> Bool {
        var stack = [child], seen = Set<String>()
        while let cur = stack.popLast() {
            if cur == parent { return true }
            if !seen.insert(cur).inserted { continue }
            if let p = pocket(cur) { stack.append(contentsOf: p.childPocketIds) }
        }
        return false
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(_ name: String) -> Playlist {
        let p = CollectionsFactory.makePlaylist(name, now: now)
        playlists.append(p); save(); return p
    }
    func renamePlaylist(_ id: String, _ name: String) { mutatePlaylist(id) { $0.name = name } }
    func deletePlaylist(_ id: String) {
        playlists.removeAll { $0.id == id }
        setlists.removeAll { $0.playlistId == id }   // cascade: drop its frozen takes
        save()
    }

    /// Append a leaf node to a sequence (the default sequence when `sequenceId` is nil).
    func addNode(_ node: PlaylistNode, toPlaylist id: String, sequenceId: String? = nil) {
        mutatePlaylist(id) { pl in
            let seqIdx = sequenceId.flatMap { sid in pl.sequences.firstIndex { $0.nodeId == sid } } ?? 0
            guard pl.sequences.indices.contains(seqIdx) else { return }
            var children = pl.sequences[seqIdx].children ?? []
            children.append(node)
            pl.sequences[seqIdx].children = children
        }
    }
    func addSong(_ songId: String, toPlaylist id: String, sequenceId: String? = nil) {
        addNode(PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: songId), toPlaylist: id, sequenceId: sequenceId)
    }
    func addAlbum(_ albumId: String, toPlaylist id: String, sequenceId: String? = nil) {
        addNode(PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .album, albumId: albumId), toPlaylist: id, sequenceId: sequenceId)
    }
    func addPocketRef(_ pocketId: String, toPlaylist id: String, sequenceId: String? = nil) {
        addNode(PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .pocket, pocketId: pocketId), toPlaylist: id, sequenceId: sequenceId)
    }
    func addText(_ text: String, toPlaylist id: String, sequenceId: String? = nil) {
        addNode(PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .text, text: text), toPlaylist: id, sequenceId: sequenceId)
    }
    func addSequence(_ name: String, toPlaylist id: String) {
        mutatePlaylist(id) { $0.sequences.append(CollectionsFactory.makeSequence(name)) }
    }
    func renameSequence(_ sequenceId: String, _ name: String, inPlaylist id: String) {
        mutatePlaylist(id) { pl in if let i = pl.sequences.firstIndex(where: { $0.nodeId == sequenceId }) { pl.sequences[i].name = name } }
    }
    func removeSequence(_ sequenceId: String, fromPlaylist id: String) {
        mutatePlaylist(id) { pl in if pl.sequences.count > 1 { pl.sequences.removeAll { $0.nodeId == sequenceId } } }
    }
    func setSequenceTarget(_ sequenceId: String, ms: Int?, inPlaylist id: String) {
        mutatePlaylist(id) { pl in if let i = pl.sequences.firstIndex(where: { $0.nodeId == sequenceId }) { pl.sequences[i].targetMs = ms } }
    }
    func setNodeNote(_ nodeId: String, note: String?, inPlaylist id: String) {
        mutatePlaylist(id) { pl in for i in pl.sequences.indices {
            if let j = pl.sequences[i].children?.firstIndex(where: { $0.nodeId == nodeId }) { pl.sequences[i].children?[j].note = note }
        } }
    }
    func removeNode(_ nodeId: String, fromPlaylist id: String) {
        mutatePlaylist(id) { pl in for i in pl.sequences.indices { pl.sequences[i].children?.removeAll { $0.nodeId == nodeId } } }
    }

    // MARK: Add-to memory ("remembers last" target + chapter, for fast repeat adds)

    func setLastAddTarget(_ target: AddTarget?) { lastAddTarget = target; save() }

    func addSong(_ songId: String, to target: AddTarget) {
        switch target.kind {
        case .pocket:   addSong(songId, toPocket: target.id)
        case .playlist: addSong(songId, toPlaylist: target.id, sequenceId: target.sequenceId)
        }
        setLastAddTarget(target)
    }
    func addAlbum(_ albumId: String, to target: AddTarget) {
        switch target.kind {
        case .pocket:   addAlbum(albumId, toPocket: target.id)
        case .playlist: addAlbum(albumId, toPlaylist: target.id, sequenceId: target.sequenceId)
        }
        setLastAddTarget(target)
    }

    /// "Pocket" or "Playlist › Chapter" for the remembered target — nil if it's gone.
    func lastTargetLabel(_ target: AddTarget) -> String? {
        switch target.kind {
        case .pocket:
            return pocket(target.id)?.name
        case .playlist:
            guard let pl = playlist(target.id) else { return nil }
            if let sid = target.sequenceId, let seq = pl.sequences.first(where: { $0.nodeId == sid }) {
                return "\(pl.name) › \(seq.name ?? "Chapter")"
            }
            return pl.name
        }
    }

    // MARK: Setlists (Play → realize → freeze)

    /// Build the read-only RealizeCtx from the injected catalog (AppModel). The
    /// autofill candidate pool is every catalog song with BOTH bpm AND camelot.
    private func makeCtx() -> RealizeCtx? {
        guard let app else { return nil }
        let candidates = app.songs.filter { $0.bpm != nil && $0.camelot != nil }
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return RealizeCtx(songsById: app.songsById, albumsById: app.albumsById,
                          pocketsById: pocketsById, candidates: candidates)
    }

    /// "Name — take N": the next take number for a playlist (history count + 1).
    private func nextSetlistName(forPlaylist id: String) -> String {
        let base = playlist(id)?.name ?? "Set"
        let take = setlists(forPlaylist: id).count + 1
        return "\(base) — take \(take)"
    }

    /// Realize a playlist into a fresh, persisted Setlist (the ▶ Play action). Returns
    /// nil if the playlist or the catalog context is unavailable. Deterministic given a
    /// `seed`; when nil, a fresh per-call seed yields a new "take" each Play.
    @discardableResult
    func realize(playlistId: String, seed: String? = nil, name: String? = nil) -> Setlist? {
        guard let pl = playlist(playlistId), let ctx = makeCtx() else { return nil }
        let theSeed = seed ?? CollectionsFactory.uid()   // fresh seed ⇒ a different take each Play
        let theName = name ?? nextSetlistName(forPlaylist: playlistId)
        let setlist = RealizeEngine.buildSetlist(pl, ctx, seed: theSeed, name: theName, now: now)
        setlists.append(setlist)
        save()
        return setlist
    }

    func deleteSetlist(_ id: String) { setlists.removeAll { $0.id == id }; save() }

    @discardableResult
    func renameSetlist(_ id: String, _ name: String) -> Setlist? {
        guard let i = setlists.firstIndex(where: { $0.id == id }) else { return nil }
        setlists[i].name = name
        save()
        return setlists[i]
    }

    /// Edit a single frozen track's performer note (by index, mirroring the PWA).
    @discardableResult
    func setSetlistTrackNote(_ id: String, trackIndex: Int, note: String?) -> Setlist? {
        guard let i = setlists.firstIndex(where: { $0.id == id }),
              setlists[i].tracks.indices.contains(trackIndex) else { return nil }
        setlists[i].tracks[trackIndex].note = note
        save()
        return setlists[i]
    }

    // MARK: Persistence

    private func mutatePocket(_ id: String, _ body: (inout Pocket) -> Void) {
        guard let i = pockets.firstIndex(where: { $0.id == id }) else { return }
        body(&pockets[i]); pockets[i].updatedAt = now; save()
    }
    private func mutatePlaylist(_ id: String, _ body: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        body(&playlists[i]); playlists[i].updatedAt = now; save()
    }
    private func save() {
        let doc = CollectionsDocument(schemaVersion: collectionsSchemaVersion, pockets: pockets,
                                      playlists: playlists, setlists: setlists, lastAddTarget: lastAddTarget)
        if let data = try? CollectionsCodec.encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}
