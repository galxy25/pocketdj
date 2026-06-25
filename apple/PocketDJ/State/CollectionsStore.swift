import SwiftUI
import Observation
import ZIPFoundation

/// On-device store for pockets + playlists, persisted as the versioned
/// `CollectionsDocument`. Operations mirror the PWA's `useCollectionsStore`.
@MainActor
@Observable
final class CollectionsStore {
    private(set) var pockets: [Pocket] = []
    private(set) var playlists: [Playlist] = []
    private(set) var setlists: [Setlist] = []
    private(set) var folders: [PlaylistFolder] = []
    private(set) var lastAddTarget: AddTarget?

    /// MONOTONIC restart token for the reserved "Now Playing" setlist. Bumped on every
    /// `playNow` (even when the same list re-plays / Shuffle re-orders) so an on-screen
    /// SetlistDetailView can `.onChange` it and re-snapshot the fresh order. Monotonic
    /// (not epoch-ms) so rapid taps never collide.
    private(set) var nowPlayingRevision = 0
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
            folders = doc.folders
            lastAddTarget = doc.lastAddTarget
        }
        // LIFECYCLE: drop any stale reserved "Now Playing" setlist persisted last session
        // so it never shows on launch (it's a per-session, reusable scratch set).
        setlists.removeAll { $0.id == nowPlayingSetlistId || $0.playlistId == nowPlayingPlaylistId }
        seedForUITestsIfRequested()
    }

    /// Testing seam: `PDJ_SEED_COLLECTIONS=1` (alongside PDJ_USE_FIXTURE) seeds a
    /// deterministic playlist with one fixture song so a setlist Play flow can be
    /// driven headlessly without the multi-step Browser ▸ Add-to dance. No-op in
    /// normal use.
    private func seedForUITestsIfRequested() {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_COLLECTIONS"] != nil,
              playlists.isEmpty else { return }
        let pl = createPlaylist("Seeded Set")
        addSong("sng_1", toPlaylist: pl.id)
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
    /// Setlists for a playlist, most-recent first (a performance history). The reserved
    /// "Now Playing" setlist is never a member (its synthetic parent id is filtered).
    func setlists(forPlaylist id: String) -> [Setlist] {
        guard id != nowPlayingPlaylistId else { return [] }
        return setlists.filter { $0.playlistId == id }.sorted { $0.generatedAt > $1.generatedAt }
    }
    /// The reserved, reusable "Now Playing" setlist (nil until a first ▶ Play / 🔀 Shuffle).
    func nowPlayingSetlist() -> Setlist? { setlist(nowPlayingSetlistId) }

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
    /// Append a free-text NOTE to a pocket (the "poetry pocket"). Notes are an ordered
    /// list, separate from members, so they never count toward song count / runtime.
    @discardableResult
    func addNote(_ text: String, toPocket id: String) -> PocketNote? {
        let note = PocketNote(id: CollectionsFactory.newPocketNoteId(), text: text,
                              position: pocket(id)?.notes.count ?? 0)
        mutatePocket(id) { $0.notes.append(note) }
        return pocket(id)?.notes.last
    }
    func setNoteText(_ noteId: String, text: String, inPocket id: String) {
        mutatePocket(id) { if let j = $0.notes.firstIndex(where: { $0.id == noteId }) { $0.notes[j].text = text } }
    }
    func removeNote(_ noteId: String, fromPocket id: String) {
        mutatePocket(id) { $0.notes.removeAll { $0.id == noteId } }
    }
    func movePocketNotes(inPocket id: String, from: IndexSet, to: Int) {
        mutatePocket(id) { $0.notes.move(fromOffsets: from, toOffset: to) }
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

    /// Reorder a node within its chapter's `children` by `delta` (-1 up, +1 down).
    /// No-op if the move would fall outside the chapter (so it's safe to call at the ends).
    func moveNode(_ nodeId: String, inPlaylist id: String, by delta: Int) {
        guard delta != 0 else { return }
        mutatePlaylist(id) { pl in
            for s in pl.sequences.indices {
                guard var children = pl.sequences[s].children,
                      let from = children.firstIndex(where: { $0.nodeId == nodeId }) else { continue }
                let to = from + delta
                guard children.indices.contains(to) else { return }   // at an end → no-op
                let node = children.remove(at: from)
                children.insert(node, at: to)
                pl.sequences[s].children = children
                return
            }
        }
    }
    func moveNodeUp(_ nodeId: String, inPlaylist id: String)   { moveNode(nodeId, inPlaylist: id, by: -1) }
    func moveNodeDown(_ nodeId: String, inPlaylist id: String) { moveNode(nodeId, inPlaylist: id, by:  1) }

    // Drag-and-drop reorder (SwiftUI `.onMove`): touch drag on iOS, pointer drag on
    // macOS. IndexSet/destination offsets are into the displayed collection.
    func moveNodes(inPlaylist id: String, sequenceId: String, from: IndexSet, to: Int) {
        mutatePlaylist(id) { pl in
            guard let s = pl.sequences.firstIndex(where: { $0.nodeId == sequenceId }) else { return }
            var children = pl.sequences[s].children ?? []
            children.move(fromOffsets: from, toOffset: to)
            pl.sequences[s].children = children
        }
    }
    func moveSequences(inPlaylist id: String, from: IndexSet, to: Int) {
        mutatePlaylist(id) { $0.sequences.move(fromOffsets: from, toOffset: to) }
    }
    func movePocketSongs(inPocket id: String, from: IndexSet, to: Int)    { mutatePocket(id) { $0.songIds.move(fromOffsets: from, toOffset: to) } }
    func movePocketAlbums(inPocket id: String, from: IndexSet, to: Int)   { mutatePocket(id) { $0.albumIds.move(fromOffsets: from, toOffset: to) } }
    func movePocketChildren(inPocket id: String, from: IndexSet, to: Int) { mutatePocket(id) { $0.childPocketIds.move(fromOffsets: from, toOffset: to) } }

    /// Create a fresh, editable local Playlist seeded with `songIds` in its default
    /// chapter (the "Duplicate as editable playlist" action on an index playlist).
    @discardableResult
    func createPlaylist(_ name: String, songIds: [String]) -> Playlist {
        var pl = CollectionsFactory.makePlaylist(name, now: now)
        pl.sequences[0].children = songIds.map {
            PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: $0)
        }
        playlists.append(pl); save(); return pl
    }

    // MARK: Convert playlist → pocket

    /// Convert an editable playlist TEMPLATE into a NEW, reusable Pocket. Its song /
    /// album / pocket node refs become the pocket's direct members (songs, albums,
    /// nested child pockets) and its free-text cues become ordered notes. Order +
    /// per-kind dedup are preserved; albums and pockets are kept as REFS (not
    /// expanded — a pocket holds them directly). The source playlist is left
    /// untouched. Returns the new pocket, or nil if the playlist id is unknown.
    @discardableResult
    func convertToPocket(playlistId id: String) -> Pocket? {
        guard let pl = playlist(id) else { return nil }
        let refs = pocketRefs(from: pl.sequences)
        return makeAndSavePocket(named: pl.name, songIds: refs.songIds, albumIds: refs.albumIds,
                                 childPocketIds: refs.childPocketIds, noteTexts: refs.noteTexts)
    }

    /// Convert a read-only "From your sources" playlist (e.g. an Apple Music user
    /// playlist carried in the catalog) into a NEW Pocket of its songs (order
    /// preserved, deduped). Always succeeds — even an empty source yields a pocket.
    @discardableResult
    func convertToPocket(source: SourcePlaylist) -> Pocket {
        var seen = Set<String>(); var ids: [String] = []
        for sid in source.songIds where seen.insert(sid).inserted { ids.append(sid) }
        return makeAndSavePocket(named: source.name, songIds: ids)
    }

    /// Walk a playlist's nodes (recursing into sub-sequences) and collect its DIRECT
    /// member refs — order-preserving + deduped per kind. Albums/pockets are NOT
    /// expanded (a pocket stores them as members); text cues are kept in order.
    private func pocketRefs(from sequences: [PlaylistNode])
        -> (songIds: [String], albumIds: [String], childPocketIds: [String], noteTexts: [String]) {
        var songIds: [String] = [], albumIds: [String] = [], childPocketIds: [String] = [], noteTexts: [String] = []
        var sSeen = Set<String>(), aSeen = Set<String>(), pSeen = Set<String>()
        func walk(_ nodes: [PlaylistNode]) {
            for n in nodes {
                switch n.kind {
                case .song:     if let id = n.songId, sSeen.insert(id).inserted { songIds.append(id) }
                case .album:    if let id = n.albumId, aSeen.insert(id).inserted { albumIds.append(id) }
                case .pocket:   if let id = n.pocketId, pSeen.insert(id).inserted { childPocketIds.append(id) }
                case .text:     if let t = n.text, !t.trimmingCharacters(in: .whitespaces).isEmpty { noteTexts.append(t) }
                case .sequence: walk(n.children ?? [])
                }
            }
        }
        walk(sequences)
        return (songIds, albumIds, childPocketIds, noteTexts)
    }

    /// Build + persist a new pocket from already-deduped/ordered member refs. Text
    /// cues become ordered `PocketNote`s (position = their index among the notes).
    @discardableResult
    private func makeAndSavePocket(named name: String, songIds: [String] = [], albumIds: [String] = [],
                                   childPocketIds: [String] = [], noteTexts: [String] = []) -> Pocket {
        let ts = now
        let notes = noteTexts.enumerated().map { i, t in
            PocketNote(id: CollectionsFactory.newPocketNoteId(), text: t, position: i)
        }
        let pocket = Pocket(id: CollectionsFactory.newPocketId(), name: name,
                            songIds: songIds, albumIds: albumIds, childPocketIds: childPocketIds,
                            notes: notes, createdAt: ts, updatedAt: ts)
        pockets.append(pocket); save()
        return pocket
    }

    // MARK: Playlist folders (FLAT — v3)

    func folder(_ id: String) -> PlaylistFolder? { folders.first { $0.id == id } }
    /// Folders, name-ordered (case-insensitive) for stable display.
    func foldersOrdered() -> [PlaylistFolder] {
        folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// Playlists in a folder (nil ⇒ top level), name-ordered.
    func playlists(inFolder id: String?) -> [Playlist] {
        playlists.filter { $0.folderId == id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func createFolder(_ name: String) -> PlaylistFolder {
        let f = PlaylistFolder(id: CollectionsFactory.newFolderId(), name: name, createdAt: now, updatedAt: now)
        folders.append(f); save(); return f
    }
    func renameFolder(_ id: String, _ name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name; folders[i].updatedAt = now; save()
    }
    /// Delete a folder; its member playlists fall back to the top level (folderId ⇒ nil).
    func deleteFolder(_ id: String) {
        folders.removeAll { $0.id == id }
        for i in playlists.indices where playlists[i].folderId == id {
            playlists[i].folderId = nil; playlists[i].updatedAt = now
        }
        save()
    }
    /// Move a playlist into a folder (nil ⇒ top level).
    func setPlaylistFolder(_ playlistId: String, folderId: String?) {
        mutatePlaylist(playlistId) { $0.folderId = folderId }
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

    // MARK: Container metadata (count + runtime)

    /// A pure `CollectionCatalog` wired to the live catalog (AppModel) + these pockets,
    /// for counting songs / summing runtime of a playlist, chapter, or pocket. Returns
    /// an empty catalog if the app graph isn't wired yet (so callers never crash).
    func catalog() -> CollectionCatalog {
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return CollectionCatalog(songsById: app?.songsById ?? [:],
                                 albumsById: app?.albumsById ?? [:],
                                 pocketsById: pocketsById)
    }

    // MARK: Collection → songIds (for batch RIP / BURN — Feature 2)
    //
    // Pure, deduped resolvers, one per collection type (each resolves differently).
    // Text/note nodes are excluded — CollectionCatalog only yields IndexSongs, and the
    // setlist resolver filters `isText` cues. An empty / missing collection yields [].

    /// Every resolved song id of an editable playlist (album/pocket expanded, deduped).
    func songIds(forPlaylist id: String) -> [String] {
        guard let pl = playlist(id) else { return [] }
        return catalog().songs(inPlaylist: pl).map { $0.id }
    }
    /// Every resolved song id of a pocket DAG (own + album tracks + nested, cycle-guarded).
    func songIds(forPocket id: String) -> [String] {
        var seen = Set<String>()
        return catalog().resolvePocketSongs(id, seen: &seen).map { $0.id }
    }
    /// Every audio track's song id of a frozen setlist (text cues excluded).
    func songIds(forSetlist id: String) -> [String] {
        guard let sl = setlist(id) else { return [] }
        return sl.tracks.filter { $0.isText != true && !$0.songId.isEmpty }.map { $0.songId }
    }
    /// A read-only "From your sources" playlist's song ids (already a flat list).
    func songIds(forSource source: SourcePlaylist) -> [String] { source.songIds }

    /// Resolve a list of song ids to the `(id,title,artist)` tuples the BURN queue +
    /// sidecar need, using the live catalog. Ids with no catalog song are dropped (the
    /// server is the unknown-id backstop for RIP; BURN can't burn a song it can't name).
    func burnTuples(_ songIds: [String]) -> [(id: String, title: String, artist: String)] {
        songIds.compactMap { id in app?.songsById[id].map { (id: id, title: $0.name, artist: $0.artist) } }
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

    /// Realize an explicit, ordered list of song ids into a fresh Setlist (used by
    /// the read-only "From your sources" index playlists' ▶ Play). Builds a transient
    /// one-chapter Playlist (NOT persisted) and reuses the standard realize path, so
    /// the produced Setlist still belongs to a parent playlist id for history. Returns
    /// nil if the catalog context is unavailable.
    @discardableResult
    func realize(songIds: [String], name: String) -> Setlist? {
        guard let ctx = makeCtx() else { return nil }
        var seq = CollectionsFactory.makeSequence("Set")
        seq.children = songIds.map { PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: $0) }
        let transient = Playlist(id: CollectionsFactory.newPlaylistId(), name: name,
                                 sequences: [seq], createdAt: now, updatedAt: now)
        let setlist = RealizeEngine.buildSetlist(transient, ctx, seed: CollectionsFactory.uid(),
                                                 name: name, now: now)
        setlists.append(setlist)
        save()
        return setlist
    }

    // MARK: Now Playing (the reusable ▶ Play / 🔀 Shuffle setlist)

    /// Build the reserved, reusable "Now Playing" setlist DIRECTLY from `songIds` — literal
    /// order, NO realize autofill / pocket-sampling / dedup-surprise. Ids with no catalog
    /// song are dropped; `shuffle` re-orders the resolved tracks fresh each call. UPSERTS the
    /// reserved setlist (last-writer-wins) and bumps the monotonic restart token so an
    /// on-screen detail view re-snapshots the new order. Returns nil if the catalog isn't wired.
    @discardableResult
    func playNow(songIds: [String], name: String = "Now Playing", shuffle: Bool = false) -> Setlist? {
        guard let app else { return nil }
        var tracks: [SetlistTrack] = songIds.compactMap { id in
            guard let s = app.songsById[id] else { return nil }   // drop unresolvable ids
            return SetlistTrack(songId: s.id, artist: s.artist, name: s.name,
                                bpm: s.bpm, camelot: s.camelot, lengthMs: s.length,
                                source: .explicit)
        }
        if shuffle { tracks.shuffle() }
        let totalMs = tracks.reduce(0) { $0 + $1.shownMs }
        nowPlayingRevision &+= 1   // monotonic; survives rapid taps (never epoch-ms collision)
        let set = Setlist(id: nowPlayingSetlistId, playlistId: nowPlayingPlaylistId, name: name,
                          seed: "now-playing", generatedAt: now, totalMs: totalMs, tracks: tracks)
        if let i = setlists.firstIndex(where: { $0.id == nowPlayingSetlistId }) {
            setlists[i] = set                  // replace in place (reuse)
        } else {
            setlists.append(set)
        }
        save()
        return set
    }

    /// ▶ Play a playlist into the reusable Now Playing setlist (literal resolved order).
    @discardableResult
    func playNow(playlistId: String, shuffle: Bool = false) -> Setlist? {
        playNow(songIds: songIds(forPlaylist: playlistId),
                name: playlist(playlistId)?.name ?? "Now Playing", shuffle: shuffle)
    }
    /// ▶ Play a pocket into the reusable Now Playing setlist (DAG-resolved order).
    @discardableResult
    func playNow(pocketId: String, shuffle: Bool = false) -> Setlist? {
        playNow(songIds: songIds(forPocket: pocketId),
                name: pocket(pocketId)?.name ?? "Now Playing", shuffle: shuffle)
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

    /// Recompute `totalMs` from the current tracks (text cues contribute 0), mirroring
    /// RealizeEngine's defaultTrackMs fallback so display + total never disagree.
    private func recomputeSetlistTotal(_ i: Int) {
        setlists[i].totalMs = setlists[i].tracks.reduce(0) { $0 + $1.shownMs }
    }

    /// Remove one track from a frozen setlist (keeps seed/provenance/generatedAt; just
    /// mutates the tracks + recomputes totalMs). The Setlist stays editable post-Play.
    @discardableResult
    func removeSetlistTrack(setlistId id: String, at index: Int) -> Setlist? {
        guard let i = setlists.firstIndex(where: { $0.id == id }),
              setlists[i].tracks.indices.contains(index) else { return nil }
        setlists[i].tracks.remove(at: index)
        recomputeSetlistTotal(i)
        save()
        return setlists[i]
    }

    /// Reorder tracks within a frozen setlist (SwiftUI `.onMove`). totalMs is unchanged
    /// by a reorder but recomputed for safety; persists.
    @discardableResult
    func moveSetlistTracks(setlistId id: String, from: IndexSet, to: Int) -> Setlist? {
        guard let i = setlists.firstIndex(where: { $0.id == id }) else { return nil }
        setlists[i].tracks.move(fromOffsets: from, toOffset: to)
        recomputeSetlistTotal(i)
        save()
        return setlists[i]
    }

    /// Append a free-text NOTE row (a top-level orderable item) to a frozen setlist.
    /// Inserted as an isText SetlistTrack with no backing song; carries the trailing
    /// `sequenceName` so it groups with the last chapter. totalMs unchanged (0 ms).
    @discardableResult
    func addSetlistNote(_ text: String, toSetlist id: String) -> Setlist? {
        guard let i = setlists.firstIndex(where: { $0.id == id }) else { return nil }
        let seqName = setlists[i].tracks.last?.sequenceName
        setlists[i].tracks.append(
            SetlistTrack(songId: "", artist: "", name: text, bpm: nil, camelot: nil,
                         source: .explicit, sequenceName: seqName, isText: true))
        recomputeSetlistTotal(i)
        save()
        return setlists[i]
    }

    // MARK: Import / export (single-item, versioned envelope)

    /// Export one pocket as a `CollectionsDocument` (the same versioned envelope used
    /// for persistence, carrying just that pocket). Returns nil if it's gone.
    func exportPocket(_ id: String) throws -> Data? {
        guard let p = pocket(id) else { return nil }
        return try CollectionsCodec.encode(CollectionsDocument(pockets: [p]))
    }
    /// Export one playlist as a `CollectionsDocument` carrying just that playlist.
    func exportPlaylist(_ id: String) throws -> Data? {
        guard let pl = playlist(id) else { return nil }
        return try CollectionsCodec.encode(CollectionsDocument(playlists: [pl]))
    }

    /// Import a `CollectionsDocument` export, MINTING FRESH ids for every imported
    /// pocket/playlist (and all playlist node ids) so it never collides with — or
    /// silently overwrites — existing collections. Imported pockets' cross-refs
    /// (childPocketIds, and any pocket node refs) are rewritten to the new ids when
    /// the referenced item is part of the same import. Setlists are not imported.
    func importCollection(data: Data) throws {
        let doc = try CollectionsCodec.decode(data)

        // 1) Allocate fresh ids for every imported pocket + playlist up-front so
        //    intra-import references can be remapped.
        var pocketIdMap: [String: String] = [:]
        for p in doc.pockets { pocketIdMap[p.id] = CollectionsFactory.newPocketId() }
        var playlistIdMap: [String: String] = [:]
        for pl in doc.playlists { playlistIdMap[pl.id] = CollectionsFactory.newPlaylistId() }
        // CRITIC-G: carry folders + remap their ids (a full-doc import preserves grouping).
        var folderIdMap: [String: String] = [:]
        for f in doc.folders { folderIdMap[f.id] = CollectionsFactory.newFolderId() }

        // 2) Pockets: remap id + child refs (drop refs to pockets not in the import).
        for var p in doc.pockets {
            p.id = pocketIdMap[p.id] ?? CollectionsFactory.newPocketId()
            p.childPocketIds = p.childPocketIds.compactMap { pocketIdMap[$0] }
            p.createdAt = now; p.updatedAt = now
            pockets.append(p)
        }

        // 3) Folders: remap id (kept only when present in the import).
        for var f in doc.folders {
            f.id = folderIdMap[f.id] ?? CollectionsFactory.newFolderId()
            f.createdAt = now; f.updatedAt = now
            folders.append(f)
        }

        // 4) Playlists: remap id + folder ref (drop a folder ref not in the import) +
        //    freshen every node id (recursively for sub-sequences).
        for var pl in doc.playlists {
            pl.id = playlistIdMap[pl.id] ?? CollectionsFactory.newPlaylistId()
            pl.folderId = pl.folderId.flatMap { folderIdMap[$0] }
            pl.sequences = pl.sequences.map { remintNode($0, pocketIdMap: pocketIdMap) }
            pl.createdAt = now; pl.updatedAt = now
            playlists.append(pl)
        }
        save()
    }

    // MARK: PWA .playlist.pocketdj.zip interop (single-playlist transfer)

    /// Export one playlist as the PWA's `.playlist.pocketdj.zip` (slim/non-portable):
    /// manifest + playlist.json + pockets.json (its referenced pockets, DAG-expanded).
    /// The bytes are readable by the PWA's `importPlaylistZip`. Returns nil if gone.
    func exportPlaylistZip(_ id: String) throws -> Data? {
        guard let pl = playlist(id) else { return nil }
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try PlaylistZip.export(playlist: pl, pocketsById: pocketsById)
    }

    /// Insert an already-reminted imported playlist + its pockets (from a
    /// `.playlist.pocketdj.zip`). Pockets are added only if their (fresh) id is absent;
    /// the playlist is always appended under its fresh id (never clobbers an existing one).
    func insertImported(playlist: Playlist, pockets: [Pocket]) {
        for p in pockets where pocket(p.id) == nil { self.pockets.append(p) }
        playlists.append(playlist)
        save()
    }

    /// Import a `.playlist.pocketdj.zip` (PWA or native-exported): mints fresh ids and
    /// inserts the playlist + its referenced pockets.
    func importPlaylistZip(data: Data) throws {
        let bundle = try PlaylistZip.import(data: data)
        insertImported(playlist: bundle.playlist, pockets: bundle.pockets)
    }

    // MARK: PWA .pocket.pocketdj.zip interop (single-pocket transfer)

    /// Export one pocket as a `.pocket.pocketdj.zip` (slim/non-portable): manifest +
    /// pocket.json + pockets.json (its child pockets, DAG-expanded). Returns nil if gone.
    func exportPocketZip(_ id: String) throws -> Data? {
        guard let p = pocket(id) else { return nil }
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try PocketZip.export(pocket: p, pocketsById: pocketsById)
    }

    /// Insert an already-reminted imported pocket bundle. Child pockets are added only
    /// if their (fresh) id is absent; the root is always appended (never clobbers).
    func insertImportedPocket(root: Pocket, children: [Pocket]) {
        for c in children where pocket(c.id) == nil { pockets.append(c) }
        pockets.append(root)
        save()
    }

    /// Import a `.pocket.pocketdj.zip`: mint fresh ids and insert the pocket + children.
    func importPocketZip(data: Data) throws {
        let bundle = try PocketZip.import(data: data)
        insertImportedPocket(root: bundle.pocket, children: bundle.children)
    }

    // MARK: Full backup `.pocketdj.zip` — collections merge (fresh ids)

    /// Merge the COLLECTIONS of a full backup into the store with FRESH ids (so it
    /// never clobbers existing items), remapping intra-import pocket refs (childPocketIds,
    /// playlist pocket nodes) and re-pointing setlists at their reminted playlists.
    /// Returns the number of pockets/playlists/setlists added.
    @discardableResult
    func mergeBackupCollections(pockets incPockets: [Pocket], playlists incPlaylists: [Playlist],
                                setlists incSetlists: [Setlist],
                                folders incFolders: [PlaylistFolder] = []) -> (pockets: Int, playlists: Int, setlists: Int) {
        var pocketIdMap: [String: String] = [:]
        for p in incPockets { pocketIdMap[p.id] = CollectionsFactory.newPocketId() }
        var playlistIdMap: [String: String] = [:]
        for pl in incPlaylists { playlistIdMap[pl.id] = CollectionsFactory.newPlaylistId() }
        // CRITIC-G: carry folders + remap their ids (preserve playlist grouping on merge).
        var folderIdMap: [String: String] = [:]
        for f in incFolders { folderIdMap[f.id] = CollectionsFactory.newFolderId() }

        for var p in incPockets {
            p.id = pocketIdMap[p.id] ?? CollectionsFactory.newPocketId()
            p.childPocketIds = p.childPocketIds.compactMap { pocketIdMap[$0] }
            p.createdAt = now; p.updatedAt = now
            pockets.append(p)
        }
        for var f in incFolders {
            f.id = folderIdMap[f.id] ?? CollectionsFactory.newFolderId()
            f.createdAt = now; f.updatedAt = now
            folders.append(f)
        }
        for var pl in incPlaylists {
            pl.id = playlistIdMap[pl.id] ?? CollectionsFactory.newPlaylistId()
            pl.folderId = pl.folderId.flatMap { folderIdMap[$0] }
            pl.sequences = pl.sequences.map { remintNode($0, pocketIdMap: pocketIdMap) }
            pl.createdAt = now; pl.updatedAt = now
            playlists.append(pl)
        }
        // Setlists: re-point at the reminted playlist (drop orphans whose playlist
        // wasn't in the import) and mint fresh setlist ids.
        var addedSetlists = 0
        for var sl in incSetlists {
            guard let newPid = playlistIdMap[sl.playlistId] else { continue }
            sl = Setlist(id: CollectionsFactory.newSetlistId(), playlistId: newPid, name: sl.name,
                         seed: sl.seed, generatedAt: sl.generatedAt, totalMs: sl.totalMs, tracks: sl.tracks)
            setlists.append(sl); addedSetlists += 1
        }
        save()
        return (incPockets.count, incPlaylists.count, addedSetlists)
    }

    /// The kind of an imported file, sniffed from its bytes (zip manifest `kind`, or a
    /// native collections `.json`). Used to route `importAny` and to drive a full-backup
    /// import (which also touches Settings + Edits) from the caller.
    enum ImportKind: Equatable { case playlist, pocket, backup, collectionsJSON }

    /// Detect what an imported file is. Zip ⇒ read `manifest.json.kind`
    /// (`playlist`/`pocket`/`backup`; a PWA backup omits `kind` ⇒ treated as backup).
    /// Non-zip ⇒ a native collections `.json`.
    nonisolated static func detectKind(data: Data) -> ImportKind {
        let isZip = data.starts(with: [0x50, 0x4B, 0x03, 0x04])   // "PK\u{03}\u{04}"
        guard isZip else { return .collectionsJSON }
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) } catch { return .collectionsJSON }
        if let entry = archive["manifest.json"] {
            var raw = Data()
            _ = try? archive.extract(entry, skipCRC32: true) { raw.append($0) }
            if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                switch obj["kind"] as? String {
                case "pocket": return .pocket
                case "playlist": return .playlist
                case "backup": return .backup
                default: break   // PWA backup omits `kind`
                }
            }
        }
        // A zip with no playlist/pocket manifest is a full backup (PWA shape).
        if archive["playlist.json"] != nil { return .playlist }
        if archive["pocket.json"] != nil { return .pocket }
        return .backup
    }

    /// Route an imported file by content. Zips dispatch on the manifest `kind`:
    /// `.playlist.pocketdj.zip` → `importPlaylistZip`, `.pocket.pocketdj.zip` →
    /// `importPocketZip`, a full `.pocketdj.zip` backup → merge its COLLECTIONS only
    /// (sources/edits are merged by the Settings coordinator, which owns those stores).
    /// A native collections `.json` → `importCollection`.
    func importAny(url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { return }
        switch CollectionsStore.detectKind(data: data) {
        case .playlist: try importPlaylistZip(data: data)
        case .pocket:   try importPocketZip(data: data)
        case .backup:
            let (payload, _) = try BackupZip.import(data: data)
            mergeBackupCollections(pockets: payload.pockets, playlists: payload.playlists,
                                   setlists: payload.setlists, folders: payload.folders)
        case .collectionsJSON: try importCollection(data: data)
        }
    }

    /// Deep-copy a node with a fresh nodeId, recursing into children; remap any
    /// pocket ref to its imported counterpart when present.
    private func remintNode(_ node: PlaylistNode, pocketIdMap: [String: String]) -> PlaylistNode {
        var n = node
        n.nodeId = CollectionsFactory.newNodeId()
        if let pid = n.pocketId, let mapped = pocketIdMap[pid] { n.pocketId = mapped }
        if let kids = n.children { n.children = kids.map { remintNode($0, pocketIdMap: pocketIdMap) } }
        return n
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
                                      playlists: playlists, setlists: setlists,
                                      folders: folders, lastAddTarget: lastAddTarget)
        if let data = try? CollectionsCodec.encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}
