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
    /// The ORIGIN kind of whatever last populated the reserved Now Playing setlist (a playlist,
    /// pocket, album, or single). The reserved setlist's id can't reveal what realized into it,
    /// so `playNow` records the kind here for the Play-History hook to attribute the play. nil
    /// ⇒ treat as a generic set list.
    private(set) var nowPlayingSource: PlayHistoryStore.PlaySource?
    /// The COLLECTION id the reserved Now Playing setlist was built from (playlist/pocket/
    /// album/artist per `nowPlayingSource`) — what the Up Next header's collection button
    /// re-opens. nil for browser singles / direct songIds plays with no origin threaded.
    private(set) var nowPlayingOriginId: String?
    private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the
    /// store was constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }

    /// The catalog the realize engine resolves ids against (wired at launch, like
    /// AppModel.settings/edits). Weak so the store never retains the app graph.
    weak var app: AppModel?
    /// Provisional entries for imported songs outside the enabled sources (set by the
    /// app at launch) — portable zip imports materialize unknown ids through it.
    weak var importedSongs: ImportedSongsStore?

    /// Fired after every persisted mutation (post-`save()`). Wired at launch by the
    /// App Intents layer to re-index Spotlight entities + refresh Siri's speakable
    /// playlist/pocket vocabulary. Nil during init (decode/seed never fires it).
    var onChange: (() -> Void)?

    /// STUDIO SEAM (spec §8, wired at app init by the integrator to `StudioStore`):
    /// resolve a studio id (`smp_`/`lp_`/`ptn_`) to its display metadata — title plus
    /// the REAL lengthMs (mandatory: a 4-second loop must never count or realize as the
    /// engine's 210 s default track), and bpm/camelot when known. nil until wired (and
    /// in most unit tests). NIL-SAFE BY CONTRACT: every consumer below treats a nil
    /// seam / nil result as "not resolvable" and degrades to the exact catalog-only
    /// behavior it had before Studio existed (studio ids simply drop out).
    var studioLookup: ((String) -> (title: String, lengthMs: Int, bpm: Double?, camelot: String?)?)?

    /// The artist label stamped on a performance item when it's snapshotted into a setlist / Now
    /// Playing (the user's "PocketDJ name", `SettingsStore.pocketDJName`). Wired from settings at
    /// app init + on change; falls back to "Studio" when unset. `studioArtist` resolves it.
    var performerName: String = ""
    var studioArtist: String { performerName.isEmpty ? "Studio" : performerName }

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
    /// One-shot creation of a pocket from an explicit ordered song list (the App
    /// Intents "Create pocket" path) — one persist, order preserved, ids deduped.
    @discardableResult
    func createPocket(_ name: String, songIds: [String], description: String? = nil) -> Pocket {
        var p = CollectionsFactory.makePocket(name, now: now)
        var seen = Set<String>()
        p.songIds = songIds.filter { seen.insert($0).inserted }
        p.description = description
        pockets.append(p); save(); return p
    }
    func renamePocket(_ id: String, _ name: String) { mutatePocket(id) { $0.name = name } }
    func deletePocket(_ id: String) {
        pockets.removeAll { $0.id == id }
        for i in pockets.indices { pockets[i].childPocketIds.removeAll { $0 == id } }
        save()
    }
    /// Membership add. `songId` is a PLAIN STRING id — STUDIO ids (`smp_`/`lp_`/`ptn_`,
    /// spec §8's namespaced-id mechanism) ride this exact path verbatim: a pocket stores
    /// them in `songIds` like any song and every consumer routes on the id PREFIX at
    /// resolve time (playable vs. rip/CSV). No `addStudioItem` twin is needed — this IS it.
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
    func removeSong(_ songId: String, fromPocket id: String) {
        mutatePocket(id) { $0.songIds.removeAll { $0 == songId }; $0.songRepeats[songId] = nil }
    }
    /// Set a pocket member's repeat (loop) count. A count ≤ 1 clears the key.
    func setSongRepeat(_ songId: String, count: Int, inPocket id: String) {
        mutatePocket(id) { $0.songRepeats[songId] = CollectionMembership.storedRepeat(count) }
    }
    /// The stored repeat count for a pocket member (1 when none).
    func repeatCount(forSong songId: String, inPocket id: String) -> Int {
        CollectionMembership.normalizedRepeat(pocket(id)?.songRepeats[songId])
    }
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
    func addSong(_ songId: String, toPlaylist id: String, sequenceId: String? = nil,
                 repeatCount: Int? = nil) {
        addNode(PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: songId,
                             repeatCount: CollectionMembership.storedRepeat(repeatCount ?? 1)),
                toPlaylist: id, sequenceId: sequenceId)
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
    /// Set a node's repeat (loop) count. A count ≤ 1 clears the field (persists as a normal
    /// single play). Searches every chapter for the node id.
    func setNodeRepeat(_ nodeId: String, count: Int, inPlaylist id: String) {
        mutatePlaylist(id) { pl in for i in pl.sequences.indices {
            if let j = pl.sequences[i].children?.firstIndex(where: { $0.nodeId == nodeId }) {
                pl.sequences[i].children?[j].repeatCount = CollectionMembership.storedRepeat(count)
            }
        } }
    }
    /// The stored repeat count for a playlist node (1 when none / not found).
    func repeatCount(forNode nodeId: String, inPlaylist id: String) -> Int {
        guard let pl = playlist(id) else { return 1 }
        for seq in pl.sequences {
            if let n = seq.children?.first(where: { $0.nodeId == nodeId }) {
                return CollectionMembership.normalizedRepeat(n.repeatCount)
            }
        }
        return 1
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
    /// PROVENANCE (v6): pass `source` when duplicating a "From your sources" playlist —
    /// the playlist then remembers where it came from and snapshots the membership, so
    /// catalog refreshes keep it in sync (see `syncConvertedCollections`).
    @discardableResult
    func createPlaylist(_ name: String, songIds: [String], source: SourcePlaylist? = nil) -> Playlist {
        var pl = CollectionsFactory.makePlaylist(name, now: now)
        pl.sequences[0].children = songIds.map {
            PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: $0)
        }
        if let source {
            pl.sourcePlaylistId = source.id
            pl.sourceName = source.sourceName
            pl.sourceSongIds = source.songIds
        }
        playlists.append(pl); save(); return pl
    }

    // MARK: Source playlist → on-device duplicate (find-or-create)

    /// The ONE find-or-create primitive for "the on-device duplicate of this source
    /// playlist". Returns the existing duplicate when there is one, else mints a fresh
    /// provenance-stamped one via `createPlaylist(_:songIds:source:)`.
    ///
    /// WHY IT MUST BE THE ONLY PATH: the manual "Duplicate as editable playlist" button and
    /// the automatic duplication behind "add a song to an Apple Music playlist" would
    /// otherwise each mint their own copy, and the user would end up with two playlists
    /// both claiming to follow the same source — both getting reconciled, neither holding
    /// all their edits. Every caller goes through here.
    ///
    /// MATCHES ON BOTH `sourcePlaylistId` AND `sourceName`: a playlist id is unique only
    /// WITHIN a source namespace ("Apple Music (Local)" and "My Digital" can each carry a
    /// playlist id `1234`), so id alone can collide across sources. A LEGACY duplicate
    /// stamped before `sourceName` existed (nil) still matches by id alone — same
    /// concession `liveSourcePlaylist` / `syncConvertedCollections` make, and the reason a
    /// legacy item doesn't get a second, competing copy.
    @discardableResult
    func duplicateForSource(_ source: SourcePlaylist) -> Playlist {
        if let exact = playlists.first(where: {
            $0.sourcePlaylistId == source.id && $0.sourceName == source.sourceName
        }) { return exact }
        if let legacy = playlists.first(where: {
            $0.sourcePlaylistId == source.id && $0.sourceName == nil
        }) { return legacy }
        return createPlaylist(source.name, songIds: source.songIds, source: source)
    }

    /// The existing duplicate of a source playlist, WITHOUT creating one (so a view can
    /// say "you already have a local copy" before the user commits to anything).
    func existingDuplicate(forSource source: SourcePlaylist) -> Playlist? {
        playlists.first { $0.sourcePlaylistId == source.id && $0.sourceName == source.sourceName }
            ?? playlists.first { $0.sourcePlaylistId == source.id && $0.sourceName == nil }
    }

    /// What `addSong(_:toIndexPlaylist:appleMusicId:)` did — enough for the caller to
    /// enqueue the Apple Music write-back AND to tell the user what just happened.
    struct IndexPlaylistAdd {
        /// The on-device duplicate the song landed in.
        let playlist: Playlist
        /// The duplicate was minted by THIS call (the user has a new local playlist).
        let createdDuplicate: Bool
        /// The song was already a member — nothing was appended locally.
        let alreadyPresent: Bool
        /// This source has a real Apple Music upstream AND the song has a store id, so a
        /// write-back job is worth queueing. False ⇒ the add is local-only by nature
        /// (vinyl / My Digital / Studio song, or a non-Apple-Music source playlist).
        let writeBackEligible: Bool
        /// The store id the write-back would use (nil when not eligible).
        let appleMusicId: String?
    }

    /// Add a song to a read-only SOURCE ("From your sources") playlist — the two-way path.
    /// Composes `duplicateForSource` + `addSong(_:toPlaylist:)`: the on-device duplicate is
    /// found or created, and the song is appended to its default chapter.
    ///
    /// DELIBERATELY DOES NOT TOUCH `sourceSongIds`. That snapshot is the base of
    /// `reconcilePlaylist`'s three-way merge, and removals are computed as
    /// (snapshot − current source). Writing the new song into the snapshot before Apple
    /// Music has confirmed it would make the very next catalog refresh classify it as a
    /// source REMOVAL and delete the user's add. Leaving it out means a failed write-back
    /// degrades to exactly "the add stayed local", which is the safe outcome. The snapshot
    /// advances only when a real catalog refresh brings the song back from the source.
    ///
    /// Also deliberately does NOT set `lastAddTarget`: the "Last used" shortcut re-adds to a
    /// plain local playlist with no write-back, so silently remembering this target would
    /// quietly drop the Apple Music half of a repeat add.
    @discardableResult
    func addSong(_ songId: String, toIndexPlaylist source: SourcePlaylist,
                 appleMusicId: String?) -> IndexPlaylistAdd {
        let existing = existingDuplicate(forSource: source)
        let pl = existing ?? duplicateForSource(source)
        let created = existing == nil

        let present = songIdsInNodes(pl.sequences).contains(songId)
        if !present {
            addSong(songId, toPlaylist: pl.id, sequenceId: pl.sequences.first?.nodeId)
        }

        let amId = (appleMusicId ?? "").trimmingCharacters(in: .whitespaces)
        let eligible = !amId.isEmpty && PlaylistWriteBack.isAppleMusicSource(source.sourceName)
        return IndexPlaylistAdd(playlist: playlist(pl.id) ?? pl,
                                createdDuplicate: created,
                                alreadyPresent: present,
                                writeBackEligible: eligible,
                                appleMusicId: eligible ? amId : nil)
    }

    /// DIRECT membership test: does this playlist carry a `.song` node for `songId`?
    /// Membership, not resolution — unlike `playableIds(forPlaylist:)` this doesn't expand
    /// albums/pockets and doesn't need the catalog, so it answers correctly for a song the
    /// live catalog can't currently resolve.
    func playlist(_ id: String, contains songId: String) -> Bool {
        guard let pl = playlist(id) else { return false }
        return songIdsInNodes(pl.sequences).contains(songId)
    }

    /// Every song id referenced by a node tree (recursing into sub-chapters) — membership,
    /// not resolution, so albums/pockets are NOT expanded.
    private func songIdsInNodes(_ nodes: [PlaylistNode]) -> Set<String> {
        var out = Set<String>()
        func walk(_ ns: [PlaylistNode]) {
            for n in ns {
                if n.kind == .song, let id = n.songId { out.insert(id) }
                if let kids = n.children { walk(kids) }
            }
        }
        walk(nodes)
        return out
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
    /// PROVENANCE (v6): the pocket remembers which source playlist it came from and
    /// snapshots the membership, so catalog refreshes can keep it in sync (source
    /// adds/removals propagate; the user's own edits survive). See `syncConvertedPockets`.
    @discardableResult
    func convertToPocket(source: SourcePlaylist) -> Pocket {
        var seen = Set<String>(); var ids: [String] = []
        for sid in source.songIds where seen.insert(sid).inserted { ids.append(sid) }
        let p = makeAndSavePocket(named: source.name, songIds: ids)
        mutatePocket(p.id) {
            $0.sourcePlaylistId = source.id
            $0.sourceName = source.sourceName
            $0.sourceSongIds = ids
        }
        return pocket(p.id) ?? p
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

    // MARK: Source sync (converted pockets + duplicated playlists follow their source — v6)

    /// Find the CURRENT catalog copy of a provenance-stamped item's source playlist.
    /// Matches by playlist id + source name (a legacy item with a nil sourceName matches
    /// by id alone). nil when the catalog hasn't loaded or the playlist is gone.
    private func liveSourcePlaylist(id plId: String, sourceName: String?) -> SourcePlaylist? {
        (app?.indexPlaylists ?? []).first {
            $0.id == plId && (sourceName == nil || $0.sourceName == sourceName)
        }
    }
    func sourcePlaylist(forPocket id: String) -> SourcePlaylist? {
        guard let p = pocket(id), let plId = p.sourcePlaylistId else { return nil }
        return liveSourcePlaylist(id: plId, sourceName: p.sourceName)
    }
    func sourcePlaylist(forPlaylist id: String) -> SourcePlaylist? {
        guard let pl = playlist(id), let plId = pl.sourcePlaylistId else { return nil }
        return liveSourcePlaylist(id: plId, sourceName: pl.sourceName)
    }

    /// Per-item sync opt-out (the ⋯ menu toggles). nil-provenance items are ignored.
    func setSourceSyncEnabled(_ enabled: Bool, forPocket id: String) {
        guard pocket(id)?.hasSource == true else { return }
        mutatePocket(id) { $0.sourceSyncEnabled = enabled }
    }
    func setSourceSyncEnabled(_ enabled: Bool, forPlaylist id: String) {
        guard playlist(id)?.hasSource == true else { return }
        mutatePlaylist(id) { $0.sourceSyncEnabled = enabled }
    }

    /// AUTO sync pass — reconcile every sync-enabled converted pocket AND duplicated
    /// playlist against the freshly-refreshed catalog playlists. Called on catalog
    /// assign (see PocketDJApp wiring; the GLOBAL Settings toggle gates the call there).
    /// An item whose source playlist is missing from this refresh is left untouched — a
    /// source that disappeared (source disabled, playlist deleted upstream) must never
    /// silently wipe the user's copy. Returns the number of items changed.
    @discardableResult
    func syncConvertedCollections(with sourcePlaylists: [SourcePlaylist]) -> Int {
        var byId: [String: [SourcePlaylist]] = [:]
        for sp in sourcePlaylists { byId[sp.id, default: []].append(sp) }
        func match(_ plId: String?, _ sourceName: String?) -> SourcePlaylist? {
            guard let plId else { return nil }
            return (byId[plId] ?? []).first { sourceName == nil || $0.sourceName == sourceName }
        }
        var changed = 0
        for p in pockets where p.syncsWithSource {
            guard let sp = match(p.sourcePlaylistId, p.sourceName) else { continue }
            if reconcilePocket(p.id, from: sp) { changed += 1 }
        }
        for pl in playlists where pl.syncsWithSource {
            guard let sp = match(pl.sourcePlaylistId, pl.sourceName) else { continue }
            if reconcilePlaylist(pl.id, from: sp) { changed += 1 }
        }
        return changed
    }

    /// MANUAL "Sync from source now" — reconciles one item immediately, regardless of
    /// the global/per-item auto-sync toggles (an explicit user action). Returns true
    /// when the item changed (false = already in sync, or the source is unavailable).
    @discardableResult
    func syncPocketFromSourceNow(_ id: String) -> Bool {
        guard let sp = sourcePlaylist(forPocket: id) else { return false }
        return reconcilePocket(id, from: sp)
    }
    @discardableResult
    func syncPlaylistFromSourceNow(_ id: String) -> Bool {
        guard let sp = sourcePlaylist(forPlaylist: id) else { return false }
        return reconcilePlaylist(id, from: sp)
    }

    /// Three-way merge of one pocket against its source playlist, using the stored
    /// snapshot (`sourceSongIds`) as the base:
    ///   • source ADDS   (in source, not in snapshot)  → appended (unless already present —
    ///     the user may have added the song themselves);
    ///   • source REMOVES (in snapshot, not in source) → removed from the pocket (their
    ///     repeat counts too);
    ///   • the user's OWN adds/removes/reorders live outside both sets and survive.
    /// The snapshot then advances to the fresh source membership. Persists only when
    /// something actually differs, so a no-change catalog refresh never churns save()/
    /// updatedAt. Returns true when the pocket (or its snapshot) changed.
    @discardableResult
    private func reconcilePocket(_ id: String, from sp: SourcePlaylist) -> Bool {
        guard let p = pocket(id) else { return false }
        var seen = Set<String>(); var srcIds: [String] = []
        for sid in sp.songIds where seen.insert(sid).inserted { srcIds.append(sid) }
        let snapshot = p.sourceSongIds ?? []
        let snapSet = Set(snapshot)
        let removals = snapSet.subtracting(srcIds)
        let current = Set(p.songIds)
        let additions = srcIds.filter { !snapSet.contains($0) && !current.contains($0) }
        var newSongIds = p.songIds.filter { !removals.contains($0) }
        newSongIds.append(contentsOf: additions)
        guard newSongIds != p.songIds || srcIds != snapshot else { return false }
        mutatePocket(id) {
            $0.songIds = newSongIds
            $0.sourceSongIds = srcIds
            $0.sourceSyncedAt = now
            for gone in removals { $0.songRepeats.removeValue(forKey: gone) }
        }
        return true
    }

    /// The playlist twin of `reconcilePocket` — same three-way merge, applied to the
    /// template's song NODES: source removals drop every `.song` node carrying that id
    /// (recursing into nested sub-sequences); source adds append fresh song nodes to the
    /// DEFAULT chapter (`sequences[0]`). Chapters, text cues, albums, pockets, and the
    /// user's own song nodes are untouched.
    @discardableResult
    private func reconcilePlaylist(_ id: String, from sp: SourcePlaylist) -> Bool {
        guard let pl = playlist(id) else { return false }
        var seen = Set<String>(); var srcIds: [String] = []
        for sid in sp.songIds where seen.insert(sid).inserted { srcIds.append(sid) }
        let snapshot = pl.sourceSongIds ?? []
        let removals = Set(snapshot).subtracting(srcIds)

        var currentSongIds = Set<String>()
        func collect(_ nodes: [PlaylistNode]) {
            for n in nodes {
                if n.kind == .song, let sid = n.songId { currentSongIds.insert(sid) }
                if let kids = n.children { collect(kids) }
            }
        }
        collect(pl.sequences)
        let additions = srcIds.filter { !Set(snapshot).contains($0) && !currentSongIds.contains($0) }

        var removedCount = 0
        func prune(_ nodes: [PlaylistNode]) -> [PlaylistNode] {
            nodes.compactMap { n in
                if n.kind == .song, let sid = n.songId, removals.contains(sid) { removedCount += 1; return nil }
                var copy = n
                if let kids = n.children { copy.children = prune(kids) }
                return copy
            }
        }
        let pruned = prune(pl.sequences)

        guard removedCount > 0 || !additions.isEmpty || srcIds != snapshot else { return false }
        mutatePlaylist(id) {
            var seqs = pruned
            if !additions.isEmpty {
                if seqs.isEmpty { seqs = [CollectionsFactory.makeSequence("Default")] }
                let newNodes = additions.map {
                    PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: $0)
                }
                seqs[0].children = (seqs[0].children ?? []) + newNodes
            }
            $0.sequences = seqs
            $0.sourceSongIds = srcIds
            $0.sourceSyncedAt = now
        }
        return true
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
    /// Pockets in a folder (nil ⇒ top level), name-ordered.
    func pockets(inFolder id: String?) -> [Pocket] {
        pockets.filter { $0.folderId == id }
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
    /// Delete a folder; its member playlists AND pockets fall back to the top level (folderId ⇒ nil).
    func deleteFolder(_ id: String) {
        folders.removeAll { $0.id == id }
        for i in playlists.indices where playlists[i].folderId == id {
            playlists[i].folderId = nil; playlists[i].updatedAt = now
        }
        for i in pockets.indices where pockets[i].folderId == id {
            pockets[i].folderId = nil; pockets[i].updatedAt = now
        }
        save()
    }
    /// Move a playlist into a folder (nil ⇒ top level).
    func setPlaylistFolder(_ playlistId: String, folderId: String?) {
        mutatePlaylist(playlistId) { $0.folderId = folderId }
    }
    /// Move a pocket into a folder (nil ⇒ top level).
    func setPocketFolder(_ pocketId: String, folderId: String?) {
        mutatePocket(pocketId) { $0.folderId = folderId }
    }

    // MARK: Add-to memory ("remembers last" target + chapter, for fast repeat adds)

    func setLastAddTarget(_ target: AddTarget?) { lastAddTarget = target; save() }

    /// The Add-to sheet's seam. Like `addSong(toPocket:)`, the id is prefix-agnostic:
    /// `AddToCollectionView.Item.studio` routes its `smp_`/`lp_`/`ptn_` ids straight
    /// through here (spec §8) — the string-array plumbing needs no studio-specific twin.
    func addSong(_ songId: String, to target: AddTarget, repeatCount: Int? = nil) {
        switch target.kind {
        case .pocket:
            addSong(songId, toPocket: target.id)
            if let r = CollectionMembership.storedRepeat(repeatCount ?? 1) {
                setSongRepeat(songId, count: r, inPocket: target.id)
            }
        case .playlist:
            addSong(songId, toPlaylist: target.id, sequenceId: target.sequenceId, repeatCount: repeatCount)
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
    /// STUDIO-AWARE: it carries title+length for every studio id referenced by these
    /// collections (spec §8 — counts/runtime INCLUDE studio items with real lengths),
    /// which is why `songIds(...)` below must strip them back out for rip/burn/CSV.
    func catalog() -> CollectionCatalog {
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return CollectionCatalog(songsById: app?.songsById ?? [:],
                                 albumsById: app?.albumsById ?? [:],
                                 pocketsById: pocketsById,
                                 studio: studioEntries())
    }

    /// Title + real length for every studio id referenced ANYWHERE in these pockets /
    /// playlists, resolved through `studioLookup` (empty when the seam isn't wired).
    /// REFERENCED-ONLY on purpose: this is a lookup table for ids the collections
    /// already carry, never an enumeration of the whole studio library — the catalog
    /// must not become a discovery surface for studio content.
    private func studioEntries() -> [String: (title: String, lengthMs: Int)] {
        guard let lookup = studioLookup else { return [:] }
        var out: [String: (title: String, lengthMs: Int)] = [:]
        func add(_ id: String) {
            guard StudioFactory.isStudioId(id), out[id] == nil, let info = lookup(id) else { return }
            out[id] = (title: info.title, lengthMs: info.lengthMs)
        }
        for p in pockets { p.songIds.forEach(add) }
        func walk(_ nodes: [PlaylistNode]) {
            for n in nodes {
                if n.kind == .song, let id = n.songId { add(id) }
                if let kids = n.children { walk(kids) }
            }
        }
        for pl in playlists { walk(pl.sequences) }
        return out
    }

    // MARK: Collection → songIds (for batch RIP / BURN — Feature 2)
    //
    // Pure, deduped resolvers, one per collection type (each resolves differently).
    // Text/note nodes are excluded — and so are STUDIO ids (`smp_`/`lp_`/`ptn_`):
    // these resolvers feed RIP / BURN / STEMIFY / CSV / Browse membership filters /
    // Storage — money-and-infra paths where a studio id must never leak (spec §8's
    // per-consumer policy; RipsStore + rip-server carry the defense-in-depth mirrors).
    // Playback wants studio rows — use the `playableIds(...)` companions instead.
    // An empty / missing collection yields [].

    /// Every resolved song id of an editable playlist (album/pocket expanded, deduped).
    /// CATALOG-ONLY: `catalog()` is studio-aware (for counts/playback), so studio ids
    /// are explicitly stripped here — historically they dropped "naturally" because
    /// `songsById` had no `smp_`/`lp_`/`ptn_` entries; the studio-aware catalog would
    /// otherwise leak them into every rip/burn/CSV consumer of this method.
    func songIds(forPlaylist id: String) -> [String] {
        guard let pl = playlist(id) else { return [] }
        return catalog().songs(inPlaylist: pl).map { $0.id }.filter { !StudioFactory.isStudioId($0) }
    }
    /// Every resolved song id of a pocket DAG (own + album tracks + nested, cycle-guarded).
    /// CATALOG-ONLY — same studio strip as `songIds(forPlaylist:)`, same reason.
    func songIds(forPocket id: String) -> [String] {
        var seen = Set<String>()
        return catalog().resolvePocketSongs(id, seen: &seen).map { $0.id }
            .filter { !StudioFactory.isStudioId($0) }
    }
    /// Every audio track's song id of a frozen setlist (text cues excluded). STUDIO rows
    /// are excluded exactly like text cues: this raw-passthrough resolver feeds the
    /// setlist Rip/Burn buttons, the CSV export, and StorageCollectionsView — a frozen
    /// set that carries a loop row must not enqueue `lp_…` at the rip server or write it
    /// into a tracklist CSV (spec §8; playback reads `playableIds(forSetlist:)`).
    func songIds(forSetlist id: String) -> [String] {
        guard let sl = setlist(id) else { return [] }
        return sl.tracks
            .filter { $0.isText != true && !$0.songId.isEmpty && !StudioFactory.isStudioId($0.songId) }
            .map { $0.songId }
    }
    /// A read-only "From your sources" playlist's song ids (already a flat list).
    func songIds(forSource source: SourcePlaylist) -> [String] { source.songIds }

    // MARK: Collection → playableIds (playback companions — studio rows KEPT)
    //
    // Same resolution + order as `songIds(...)` but KEEPING studio ids: samples /
    // loops / patterns are playable rows (SetlistPlayer resolves them via its
    // `studioResolve` seam; `playNow` snapshots them via `studioLookup`). NEVER feed
    // these to rip/burn/CSV — that's what the catalog-only `songIds(...)` are for.

    /// Playlist's resolved playable ids, in play order (albums/pockets expanded; studio
    /// ids kept when `studioLookup` resolves them — an unresolvable studio id drops out,
    /// matching how unknown catalog ids behave everywhere else).
    func playableIds(forPlaylist id: String) -> [String] {
        guard let pl = playlist(id) else { return [] }
        return catalog().songs(inPlaylist: pl).map { $0.id }
    }
    /// Pocket DAG's resolved playable ids (cycle-guarded, deduped; studio ids kept).
    func playableIds(forPocket id: String) -> [String] {
        var seen = Set<String>()
        return catalog().resolvePocketSongs(id, seen: &seen).map { $0.id }
    }
    /// A frozen setlist's playable ids in FROZEN ORDER — studio rows included (they're
    /// snapshotted tracks like any other); only text cues (no backing item) drop out.
    func playableIds(forSetlist id: String) -> [String] {
        guard let sl = setlist(id) else { return [] }
        return sl.tracks.filter { $0.isText != true && !$0.songId.isEmpty }.map { $0.songId }
    }

    // MARK: - CSV tracklist export (universal columns — see TracklistCSV)

    /// Playlist → tracklist CSV (the resolved songs in order). nil if the playlist is gone / no catalog.
    func exportPlaylistCSV(_ id: String) -> Data? {
        guard playlist(id) != nil, let app else { return nil }
        return TracklistCSV.data(rows: app.tracklistCSVRows(forSongIds: songIds(forPlaylist: id)))
    }
    /// Pocket → tracklist CSV.
    func exportPocketCSV(_ id: String) -> Data? {
        guard pocket(id) != nil, let app else { return nil }
        return TracklistCSV.data(rows: app.tracklistCSVRows(forSongIds: songIds(forPocket: id)))
    }
    /// Setlist → tracklist CSV (audio tracks in order; text cues excluded).
    func exportSetlistCSV(_ id: String) -> Data? {
        guard setlist(id) != nil, let app else { return nil }
        return TracklistCSV.data(rows: app.tracklistCSVRows(forSongIds: songIds(forSetlist: id)))
    }

    /// Resolve a list of song ids to the `(id,title,artist)` tuples the BURN queue +
    /// sidecar need, using the live catalog. Ids with no catalog song are dropped (the
    /// server is the unknown-id backstop for RIP; BURN can't burn a song it can't name).
    /// Studio ids drop here too (`songsById` never contains them) — a third fence behind
    /// the `songIds(...)` strip and the RipsStore/rip-server guards.
    func burnTuples(_ songIds: [String]) -> [(id: String, title: String, artist: String)] {
        songIds.compactMap { id in app?.songsById[id].map { (id: id, title: $0.name, artist: $0.artist) } }
    }

    // MARK: Setlists (Play → realize → freeze)

    /// Build the read-only RealizeCtx from the injected catalog (AppModel). The
    /// autofill candidate pool is every catalog song with BOTH bpm AND camelot.
    ///
    /// STUDIO (spec §8): synthetic pseudo-songs for studio ids are injected into
    /// `ctx.songsById` ONLY for ids the playlist being realized actually references
    /// (its song nodes + its pocket refs' DAGs) — carrying the REAL lengthMs from
    /// `studioLookup` so a 4 s loop never realizes as the 210 s default track.
    /// AUTOFILL FENCE: they are NEVER added to `ctx.candidates` — a user's loop must
    /// not surface as a harmonic bridge in arbitrary setlists (the candidate pool is
    /// built from `app.songs`, which is catalog-only by construction; the injection
    /// below deliberately touches `songsById` alone). Internal (not private) so
    /// CollectionsStudioTests can assert the injection + the fence directly.
    func makeCtx(for playlist: Playlist? = nil) -> RealizeCtx? {
        guard let app else { return nil }
        let candidates = app.songs.filter { $0.bpm != nil && $0.camelot != nil }
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var songsById = app.songsById
        if let playlist, let lookup = studioLookup {
            for id in referencedStudioIds(in: playlist) where songsById[id] == nil {
                guard let info = lookup(id) else { continue }   // unresolvable → node places nothing
                songsById[id] = IndexSong.studioSynthetic(id: id, title: info.title,
                                                          lengthMs: info.lengthMs, artist: studioArtist,
                                                          bpm: info.bpm, camelot: info.camelot)
            }
        }
        return RealizeCtx(songsById: songsById, albumsById: app.albumsById,
                          pocketsById: pocketsById, candidates: candidates)
    }

    /// The studio ids a playlist can reach at realize time: its song nodes (recursing
    /// through sub-sequences) PLUS its pocket refs' DAG members (cycle-guarded) — a
    /// pocket holding a loop must place that loop when the playlist realizes. Album
    /// nodes can't carry studio ids (trackLists are catalog data), so they're skipped.
    private func referencedStudioIds(in playlist: Playlist) -> Set<String> {
        var out = Set<String>()
        var seenPockets = Set<String>()
        func addPocket(_ id: String) {
            guard seenPockets.insert(id).inserted, let p = pocket(id) else { return }
            for sid in p.songIds where StudioFactory.isStudioId(sid) { out.insert(sid) }
            p.childPocketIds.forEach(addPocket)
        }
        func walk(_ nodes: [PlaylistNode]) {
            for n in nodes {
                switch n.kind {
                case .song:     if let id = n.songId, StudioFactory.isStudioId(id) { out.insert(id) }
                case .pocket:   if let id = n.pocketId { addPocket(id) }
                case .sequence: walk(n.children ?? [])
                case .album, .text: break
                }
            }
        }
        walk(playlist.sequences)
        return out
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
        guard let pl = playlist(playlistId), let ctx = makeCtx(for: pl) else { return nil }
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
        var seq = CollectionsFactory.makeSequence("Set")
        seq.children = songIds.map { PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: $0) }
        let transient = Playlist(id: CollectionsFactory.newPlaylistId(), name: name,
                                 sequences: [seq], createdAt: now, updatedAt: now)
        // Ctx is built FOR the transient playlist so explicit studio ids (a caller
        // passing playable ids) get their synthetic entries too — same referenced-only
        // injection + candidates fence as the persisted-playlist path.
        guard let ctx = makeCtx(for: transient) else { return nil }
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
    func playNow(songIds: [String], name: String = "Now Playing", shuffle: Bool = false,
                 source: PlayHistoryStore.PlaySource? = nil, repeats: [String: Int] = [:],
                 originId: String? = nil) -> Setlist? {
        guard let app else { return nil }
        nowPlayingSource = source
        nowPlayingOriginId = originId
        var tracks: [SetlistTrack] = songIds.compactMap { id in
            // Per-item repeat (loop) count from the source collection — snapshotted so the
            // player loops the row that many times before advancing.
            let rep = CollectionMembership.storedRepeat(repeats[id] ?? 1)
            // STUDIO rows (spec §8 — playNow RESOLVES studio ids): synthesize the frozen
            // snapshot from the studio lookup — title + REAL lengthMs so `shownMs` never
            // invents the 210 s fallback for a 4 s loop, bpm/camelot when known, and a
            // "Studio" artist so the row + Now Playing label read sensibly. Unresolvable
            // (seam unwired / item deleted) drops the row, exactly like an unknown
            // catalog id on the line below.
            if StudioFactory.isStudioId(id) {
                guard let info = studioLookup?(id) else { return nil }
                return SetlistTrack(songId: id, artist: studioArtist, name: info.title,
                                    bpm: info.bpm, camelot: info.camelot, lengthMs: info.lengthMs,
                                    source: .explicit, repeatCount: rep)
            }
            guard let s = app.songsById[id] else { return nil }   // drop unresolvable ids
            return SetlistTrack(songId: s.id, artist: s.artist, name: s.name,
                                bpm: s.bpm, camelot: s.camelot, lengthMs: s.length,
                                source: .explicit, repeatCount: rep)
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

    /// The Up Next header's SETLIST button target: the reserved Now Playing setlist if
    /// it still exists, else MATERIALIZED from the live queue. A durable-session restore
    /// drops the stale Now Playing doc at launch (init/reloadFromDisk cleanup), so a
    /// restored run's queue lives only in the player until the user asks for the setlist
    /// view — this rebuilds the document that queue represents. Rows carry their own
    /// snapshot (title/artist/length rode the durable session); bpm/camelot re-attach
    /// from the catalog when the id still resolves.
    @discardableResult
    func materializeNowPlayingSetlist(
        name: String?,
        queue: [(id: String, title: String, artist: String, lengthMs: Int?, repeatCount: Int?)]
    ) -> Setlist? {
        if let existing = setlist(nowPlayingSetlistId) { return existing }
        guard !queue.isEmpty else { return nil }
        let tracks: [SetlistTrack] = queue.map { row in
            let s = app?.songsById[row.id]
            return SetlistTrack(songId: row.id, artist: row.artist, name: row.title,
                                bpm: s?.bpm, camelot: s?.camelot,
                                lengthMs: row.lengthMs ?? s?.length,
                                source: .explicit,
                                repeatCount: CollectionMembership.storedRepeat(row.repeatCount ?? 1))
        }
        let totalMs = tracks.reduce(0) { $0 + $1.shownMs }
        let set = Setlist(id: nowPlayingSetlistId, playlistId: nowPlayingPlaylistId,
                          name: name ?? "Now Playing", seed: "now-playing",
                          generatedAt: now, totalMs: totalMs, tracks: tracks)
        setlists.append(set)
        save()
        return set
    }

    /// ▶ Play a playlist into the reusable Now Playing setlist (literal resolved order).
    /// Resolves via `playableIds` — studio rows are PLAYABLE and belong in Now Playing
    /// (spec §8), unlike the rip/CSV-facing `songIds(forPlaylist:)`.
    @discardableResult
    func playNow(playlistId: String, shuffle: Bool = false) -> Setlist? {
        playNow(songIds: playableIds(forPlaylist: playlistId),
                name: playlist(playlistId)?.name ?? "Now Playing", shuffle: shuffle, source: .playlist,
                repeats: playlistRepeatMap(playlistId), originId: playlistId)
    }
    /// ▶ Play a pocket into the reusable Now Playing setlist (DAG-resolved order).
    /// `playableIds` for the same reason as the playlist variant above.
    @discardableResult
    func playNow(pocketId: String, shuffle: Bool = false) -> Setlist? {
        playNow(songIds: playableIds(forPocket: pocketId),
                name: pocket(pocketId)?.name ?? "Now Playing", shuffle: shuffle, source: .pocket,
                repeats: pocket(pocketId)?.songRepeats ?? [:], originId: pocketId)
    }

    /// Best-effort songId → repeat-count map for a playlist's `.song` nodes (recursing into
    /// sub-chapters). Keyed by songId, so if the same item appears in two nodes with different
    /// counts the later one wins — acceptable for a playback convenience, and the common case
    /// (a performance item added once) is exact.
    private func playlistRepeatMap(_ id: String) -> [String: Int] {
        guard let pl = playlist(id) else { return [:] }
        var map: [String: Int] = [:]
        func walk(_ nodes: [PlaylistNode]) {
            for n in nodes {
                if n.kind == .song, let sid = n.songId, let r = n.repeatCount, r > 1 { map[sid] = r }
                if let kids = n.children { walk(kids) }
            }
        }
        for seq in pl.sequences { walk(seq.children ?? []) }
        return map
    }

    /// Resolve the Play-History source-kind + display name for a sequencer run tagged with
    /// `sourceSetlistId`. For the reserved Now Playing setlist (album/playlist/pocket/single all
    /// realize into it) the KIND comes from `nowPlayingSource`; the NAME is the setlist's own
    /// name (which `playNow` sets to the album/playlist/pocket name). A real setlist resolves to
    /// (.setlist, its name). A single-song play (`.browser`) carries no set name.
    func historyContext(forSourceSetlistId id: String?) -> (source: PlayHistoryStore.PlaySource, name: String?) {
        guard let id else { return (.setlist, nil) }
        if id == nowPlayingSetlistId {
            let src = nowPlayingSource ?? .setlist
            return src == .browser ? (.browser, nil) : (src, setlist(id)?.name)
        }
        if let s = setlist(id) { return (.setlist, s.name) }
        // Defensive: a real playlist/pocket id ever threaded directly.
        if let p = playlist(id) { return (.playlist, p.name) }
        if let pk = pocket(id) { return (.pocket, pk.name) }
        return (.setlist, nil)
    }

    /// Resolve the NAVIGABLE origin collection for a sequencer run tagged with
    /// `sourceSetlistId` — the Up Next header's collection button target. For the reserved
    /// Now Playing setlist the origin is whatever `playNow` recorded (playlist/pocket/
    /// album/artist + its id); a REAL setlist is its own origin. nil (⇒ button hidden)
    /// for browser singles and origins that no longer resolve.
    func originCollection(forSourceSetlistId id: String?) -> (kind: PlayHistoryStore.PlaySource, id: String)? {
        guard let id else { return nil }
        if id == nowPlayingSetlistId {
            guard let src = nowPlayingSource, let oid = nowPlayingOriginId else { return nil }
            return (src, oid)
        }
        if setlist(id) != nil { return (.setlist, id) }
        // Defensive twins of historyContext's fallbacks.
        if playlist(id) != nil { return (.playlist, id) }
        if pocket(id) != nil { return (.pocket, id) }
        return nil
    }

    /// SUPERSEDE remap (Discover eventual consistency): every collection reference to a
    /// provisional `amrec_` song follows the INDEXED catalog entry that replaced it —
    /// playlists (recursive node trees), pockets (songIds + per-song repeats), and
    /// setlist tracks. One save at the end when anything moved.
    func remapSongIds(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        let map = Dictionary(pairs.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        var changed = false

        func remapNodes(_ nodes: [PlaylistNode]) -> [PlaylistNode] {
            nodes.map { node in
                var n = node
                if let sid = n.songId, let to = map[sid] { n.songId = to; changed = true }
                if let kids = n.children { n.children = remapNodes(kids) }
                return n
            }
        }
        for i in playlists.indices {
            playlists[i].sequences = remapNodes(playlists[i].sequences)
            if let src = playlists[i].sourceSongIds, src.contains(where: { map[$0] != nil }) {
                playlists[i].sourceSongIds = src.map { map[$0] ?? $0 }
                changed = true
            }
        }
        for i in pockets.indices {
            if pockets[i].songIds.contains(where: { map[$0] != nil }) {
                pockets[i].songIds = pockets[i].songIds.map { map[$0] ?? $0 }
                changed = true
            }
            for (sid, rep) in pockets[i].songRepeats {
                if let to = map[sid] {
                    pockets[i].songRepeats.removeValue(forKey: sid)
                    pockets[i].songRepeats[to] = rep
                    changed = true
                }
            }
        }
        for i in setlists.indices {
            for j in setlists[i].tracks.indices {
                if let to = map[setlists[i].tracks[j].songId] {
                    setlists[i].tracks[j].songId = to
                    changed = true
                }
            }
        }
        if changed { save() }
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

        // 2) Pockets: remap id + child refs + folder ref (drop refs not in the import).
        for var p in doc.pockets {
            p.id = pocketIdMap[p.id] ?? CollectionsFactory.newPocketId()
            p.childPocketIds = p.childPocketIds.compactMap { pocketIdMap[$0] }
            p.folderId = p.folderId.flatMap { folderIdMap[$0] }
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

    /// Export one playlist as the PWA's `.playlist.pocketdj.zip`, PORTABLE: manifest +
    /// playlist.json + pockets.json + items.json (the referenced catalog items in the
    /// PWA `MusicItem[]` shape), so it imports fully on a device — or the PWA — whose
    /// catalog doesn't cover these ids. Returns nil if gone.
    func exportPlaylistZip(_ id: String) throws -> Data? {
        guard let pl = playlist(id) else { return nil }
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try PlaylistZip.export(playlist: pl, pocketsById: pocketsById,
                                      songsById: app?.songsById ?? [:],
                                      albumsById: app?.albumsById ?? [:])
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
    /// inserts the playlist + its referenced pockets, then materializes any portable
    /// items OUTSIDE the live catalog as provisional "Imported" entries — the songs are
    /// browsable/playable/burnable immediately (acceptance test A).
    func importPlaylistZip(data: Data) throws {
        let bundle = try PlaylistZip.import(data: data)
        insertImported(playlist: bundle.playlist, pockets: bundle.pockets)
        materializePortableItems(bundle.items)
    }

    // MARK: PWA .pocket.pocketdj.zip interop (single-pocket transfer)

    /// Export one pocket as a `.pocket.pocketdj.zip`, PORTABLE (items.json — the
    /// PlaylistZip doctrine): manifest + pocket.json + pockets.json (its child pockets,
    /// DAG-expanded) + the referenced catalog items. Returns nil if gone.
    func exportPocketZip(_ id: String) throws -> Data? {
        guard let p = pocket(id) else { return nil }
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try PocketZip.export(pocket: p, pocketsById: pocketsById,
                                    songsById: app?.songsById ?? [:],
                                    albumsById: app?.albumsById ?? [:])
    }

    /// Insert an already-reminted imported pocket bundle. Child pockets are added only
    /// if their (fresh) id is absent; the root is always appended (never clobbers).
    /// folderId is cleared on all imported pockets — a single-pocket transfer carries
    /// no folder context and the referenced folder won't exist on the target.
    func insertImportedPocket(root: Pocket, children: [Pocket]) {
        for var c in children where pocket(c.id) == nil {
            c.folderId = nil
            pockets.append(c)
        }
        var mutableRoot = root; mutableRoot.folderId = nil
        pockets.append(mutableRoot)
        save()
    }

    /// Import a `.pocket.pocketdj.zip`: mint fresh ids and insert the pocket + children,
    /// then materialize portable items outside the catalog (the PlaylistZip doctrine).
    func importPocketZip(data: Data) throws {
        let bundle = try PocketZip.import(data: data)
        insertImportedPocket(root: bundle.pocket, children: bundle.children)
        materializePortableItems(bundle.items)
    }

    /// Materialize a portable snapshot's UNKNOWN ids as provisional "Imported" catalog
    /// entries (ImportedSongsStore → AppModel injection → browse/play/burn/stems all
    /// resolve them). Ids the live catalog already carries are skipped — a real source
    /// always wins; the provisional store dedups against itself. No-op when the seam
    /// isn't wired (tests) or the zip was slim.
    func materializePortableItems(_ items: PortableItems.Payload) {
        guard let importedSongs, !items.isEmpty else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let albumsById = Dictionary(items.albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let songs = items.songs
            .filter { app?.songsById[$0.id] == nil && !StudioFactory.isStudioId($0.id) }
            .map { s in
                ImportedSongsStore.SongEntry(
                    songId: s.id, title: s.name, artist: s.artist, albumId: s.albumId,
                    album: s.albumId.flatMap { albumsById[$0]?.name },
                    artworkUrl: s.albumId.flatMap { albumsById[$0]?.coverArtUrl },
                    durationMs: s.lengthMs, bpm: s.bpm, key: s.key, camelot: s.camelot,
                    year: s.year, appleMusicId: s.appleMusicId, addedAtMs: now)
            }
        let albums = items.albums
            .filter { app?.albumsById[$0.id] == nil }
            .map { a in
                ImportedSongsStore.AlbumEntry(
                    albumId: a.id, name: a.name, artist: a.artist, trackIds: a.trackIds,
                    artworkUrl: a.coverArtUrl, genre: a.genre, year: a.year, addedAtMs: now)
            }
        importedSongs.add(songs: songs, albums: albums)
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
            p.folderId = p.folderId.flatMap { folderIdMap[$0] }
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
        onChange?()
    }

    /// Re-decode the on-disk document after CloudSyncService pulled a newer cloud copy
    /// (whole-document LWW). Mirrors init's decode + stale Now Playing cleanup, then fires
    /// `onChange` so Spotlight/Siri donations reindex against the pulled collections.
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? CollectionsCodec.decode(data) else { return }
        pockets = doc.pockets
        playlists = doc.playlists
        setlists = doc.setlists
        folders = doc.folders
        lastAddTarget = doc.lastAddTarget
        setlists.removeAll { $0.id == nowPlayingSetlistId || $0.playlistId == nowPlayingPlaylistId }
        onChange?()
    }
}
