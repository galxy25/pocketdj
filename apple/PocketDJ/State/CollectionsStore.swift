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
    /// The last few "Add to…" targets, MOST-RECENT FIRST (the Recent quick-add row). Deduped by
    /// (kind,id) IGNORING sequenceId + capped at `maxRecentTargets` — the top entry mirrors
    /// `lastAddTarget`. Persisted on the collections document (rides the same CloudSync), so the
    /// MRU follows the user across devices. Kept a few deeper than the UI shows (see the cap) so a
    /// deleted collection dropping out still leaves enough resolvable entries to fill the row.
    private(set) var recentAddTargets: [AddTarget] = []
    /// How many recent targets we retain. The Recent row shows the top 3 that still resolve; the
    /// surplus is a buffer so a stale/deleted entry falling off the front doesn't empty the row.
    static let maxRecentTargets = 10

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
    /// The off-main encode+write pipeline behind `save()` — see `CollectionsDocumentWriter`.
    @ObservationIgnored private let writer = CollectionsDocumentWriter()
    /// Monotonic version stamped on every writer operation so writes land in mutation order
    /// even when their tasks are scheduled out of order.
    @ObservationIgnored private var saveVersion = 0
    /// Last-known "N songs · runtime" per collection, so the list never regresses to "0 songs"
    /// while the catalog is still decoding. @ObservationIgnored: recording into it happens while
    /// a view body READS the stats, and invalidating that body from inside itself would loop.
    @ObservationIgnored private let statsCache = CollectionStatsCache()
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

    /// A user ADD/REMOVE of an item to/from a collection — the collection-activity-history seam
    /// (F11). Mirrors `onChange`: wired at launch to `CollectionActivityStore.record` so the store
    /// stays UI-agnostic + unit-testable (a test sets a counting closure). Fired ONLY from the
    /// user-facing choke points (`addSong(_:to:)` / `addAlbum(_:to:)` / `removeSong(fromPocket:)`
    /// / `removeAlbum(fromPocket:)` / `removeNode(fromPlaylist:)`) — NEVER from source-sync
    /// reconcile (which mutates the arrays directly) or from a decode/seed. HEART events are logged
    /// separately from the app's `FavoritesStore.onChanged`, not here.
    var onActivity: ((ActivityHook) -> Void)?

    /// Batch twin of `onActivity` — ONE emission per user gesture so the recorder can do ONE
    /// document write (the multi-select / drag-&-drop / paste batch adds; per-hook recording
    /// costs a full activity-log encode + atomic write EACH). Optional: when unwired the
    /// store falls back to per-hook `onActivity`, keeping every existing test seam working.
    var onActivityBatch: (([ActivityHook]) -> Void)?

    private func emitActivityBatch(_ hooks: [ActivityHook]) {
        guard !hooks.isEmpty else { return }
        if let onActivityBatch { onActivityBatch(hooks) } else { for h in hooks { onActivity?(h) } }
    }

    /// The payload of an `onActivity` emission — a user add/remove, snapshotted at fire time.
    struct ActivityHook {
        enum Kind: String { case add, remove }
        var kind: Kind
        var itemId: String
        var itemTitle: String?
        /// Artist snapshot, so a row for an item the LOCAL catalog can't resolve still reads as a
        /// song rather than a bare id (R3). Nil when nothing resolves / not a song.
        var itemArtist: String?
        var collectionId: String?
        var collectionKind: String?    // AddTarget.Kind raw ("pocket" / "playlist")
        var collectionName: String?
    }

    /// APPLE-MUSIC WRITE-BACK SEAM (two-way source sync, Levi 2026-07-22). Wired at app init
    /// to `PlaylistWriteBack.enqueue` + `runSoon` (behind its own `canWriteBack` gate). Called
    /// from the user-facing add choke point (`addSong(_:to:)`) whenever a song lands in a
    /// collection that was CONVERTED (pocket) or DUPLICATED (playlist) from an Apple Music
    /// "From your sources" playlist, so the add reaches the REAL Apple Music library playlist —
    /// not just the on-device copy.
    ///
    /// THE BUG THIS FIXES: write-back used to fire ONLY from the "From your sources" row in the
    /// Add sheet (`addSong(_:toIndexPlaylist:)`). A song added straight to a converted pocket
    /// therefore stayed on-device forever and never appeared in Apple Music. The provenance a
    /// converted pocket already carries (`sourcePlaylistId`/`sourceName`/`sourceSongIds`) is
    /// exactly enough to make it a first-class two-way citizen; this seam is the missing wire.
    ///
    /// A SEAM, not a direct `PlaylistWriteBack` reference, for the same reason as `onActivity` /
    /// `studioLookup`: the store stays free of MusicKit and unit-testable with no account. nil
    /// in tests / on platforms that can't write — the local add still stands, exactly as before.
    ///
    /// Returns TRUE when a NEW job was queued, FALSE when nothing was (this build can't write,
    /// or an equivalent job is already queued/delivered — the queue dedups on id+song). The
    /// per-add caller ignores it; `backfillSourceWriteBacks` sums it into a "newly queued" count.
    /// `appleMusicId` may be nil/empty — our indexer missed it — in which case the identity
    /// (`title`/`artist`/`album`/`durationMs`) lets the transport resolve the catalog id
    /// on-device at delivery. See `PlaylistWriteBack.enqueue`.
    var enqueueSourceWriteBack: ((_ indexPlaylistId: String, _ playlistName: String,
                                  _ songId: String, _ appleMusicId: String?,
                                  _ title: String, _ artist: String,
                                  _ album: String?, _ durationMs: Int?) -> Bool)?

    /// Batch twin of `enqueueSourceWriteBack` (wired to `PlaylistWriteBack.enqueueMany` +
    /// ONE `runSoon`): a multi-select batch add owes N upstream writes as ONE queue
    /// prune/save, not N. Falls back to N single enqueues when unwired (tests).
    var enqueueSourceWriteBackBatch: ((_ items: [PlaylistWriteBack.EnqueueItem]) -> Int)?

    /// Whether THIS build/session can deliver upstream writes at all (wired to
    /// `PlaylistWriteBack.canWriteBack`). Consulted before parking a large batch for user
    /// confirmation — a platform that can't write must never show the confirm dialog.
    /// Unwired (tests) ⇒ treated as capable so the gate itself stays unit-testable.
    var canWriteBackUpstream: (() -> Bool)?

    /// Cancel still-undelivered write-backs owed to `indexPlaylistId` for `songIds` (wired to
    /// `PlaylistWriteBack.cancelPending`). Fired when a pocket is re-linked away from a source, so a
    /// queued-but-undelivered add can't still land in the OLD, wrong Apple Music playlist. nil in
    /// tests / where there's no queue.
    var cancelPendingWriteBacks: ((_ indexPlaylistId: String, _ songIds: Set<String>) -> Void)?

    /// STUDIO SEAM (spec §8, wired at app init by the integrator to `StudioStore`):
    /// resolve a studio id (`smp_`/`lp_`/`ptn_`) to its display metadata — title plus
    /// the REAL lengthMs (mandatory: a 4-second loop must never count or realize as the
    /// engine's 210 s default track), and bpm/camelot when known. nil until wired (and
    /// in most unit tests). NIL-SAFE BY CONTRACT: every consumer below treats a nil
    /// seam / nil result as "not resolvable" and degrades to the exact catalog-only
    /// behavior it had before Studio existed (studio ids simply drop out).
    var studioLookup: ((String) -> (title: String, lengthMs: Int, bpm: Double?, camelot: String?)?)?

    /// Fired from `playNow` BEFORE the new queue is built — "whatever was running is being
    /// replaced". Wired in `PocketDJApp` to `RecFeedbackStore.endPlaybackScope`, so a recommendation
    /// scope can never outlive the queue it describes. A closure rather than a store reference for
    /// the same reason `studioLookup` is one: this store stays out of the recommendation graph, and
    /// a unit test that never wires it behaves exactly as it did before the tuning loop existed.
    var onPlaybackReplaced: (() -> Void)?

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
            recentAddTargets = doc.recentAddTargets ?? []
        }
        // LIFECYCLE: drop any stale reserved "Now Playing" setlist persisted last session
        // so it never shows on launch (it's a per-session, reusable scratch set).
        setlists.removeAll { $0.id == nowPlayingSetlistId || $0.playlistId == nowPlayingPlaylistId }
        seedForUITestsIfRequested()
    }

    /// Testing seam: `PDJ_SEED_COLLECTIONS=1` (alongside PDJ_USE_FIXTURE) seeds a
    /// deterministic playlist with one fixture song so a setlist Play flow can be
    /// driven headlessly without the multi-step Browser ▸ Add-to dance. A value ABOVE 1
    /// seeds that many playlists ("Seeded Set", then "Crate 2"…"Crate N") — a long
    /// collection list is what pushed the Collectors Puzzle's Start control off the
    /// bottom of the screen, so a test needs to be able to reproduce that shape.
    /// No-op in normal use.
    private func seedForUITestsIfRequested() {
        if let raw = ProcessInfo.processInfo.environment["PDJ_SEED_COLLECTIONS"], playlists.isEmpty {
            let pl = createPlaylist("Seeded Set")
            addSong("sng_1", toPlaylist: pl.id)
            let extra = max(1, Int(raw) ?? 1)
            if extra > 1 { for i in 2...extra { _ = createPlaylist("Crate \(i)") } }
        }
        // Clean-versions-only seam: a deterministic 3-song playlist over the fixture's
        // clean / substitutable / skip trio (sng_1 clean · sng_2 explicit WITH a clean id ·
        // sng_6 explicit WITHOUT one). Keyed on the playlist NAME (not `playlists.isEmpty`)
        // so it composes with PDJ_SEED_COLLECTIONS.
        if ProcessInfo.processInfo.environment["PDJ_SEED_CLEANONLY"] != nil,
           !playlists.contains(where: { $0.name == "Clean Test" }) {
            let pl = createPlaylist("Clean Test")
            addSong("sng_1", toPlaylist: pl.id)
            addSong("sng_2", toPlaylist: pl.id)
            addSong("sng_6", toPlaylist: pl.id)
        }
        // Recommendations-OFF seam: a collection that has ALREADY been switched off, so a test can
        // drive the RECOVERY path (Settings ▸ For You ▸ turn it back on) without first having to
        // produce a For You tile — which needs a refresh that happened to find something to suggest,
        // i.e. exactly the condition a closed crate is least likely to satisfy. Deliberately EMPTY:
        // an empty collection can never earn a tile, so it is the strictest version of "the only way
        // back is the Settings list".
        if ProcessInfo.processInfo.environment["PDJ_SEED_RECS_OFF"] != nil,
           !pockets.contains(where: { $0.name == "Comfort Zone" }) {
            let p = createPocket("Comfort Zone")
            setRecommendationsEnabled(false, forPocket: p.id)
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
    /// User-facing set lists: only those whose parent template (a playlist or pocket) still exists
    /// ON THIS DEVICE. Excludes ORPHANS — set lists left behind by a parent that was deleted or that
    /// arrived via sync without its template — and the reserved "Now Playing" set (synthetic parent).
    /// Non-destructive (the orphan stays on disk, so it reappears if its template syncs back in);
    /// flat pickers like the Mix Auto-DJ source list read this instead of raw `setlists`.
    var visibleSetlists: [Setlist] {
        let templates = Set(playlists.map(\.id)).union(pockets.map(\.id))
        return setlists.filter { templates.contains($0.playlistId) }
    }
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
        let name = pocket(id)?.name
        mutatePocket(id) { $0.songIds.removeAll { $0 == songId }; $0.songRepeats[songId] = nil }
        emitRemoveActivity(itemId: songId, collectionId: id, kind: .pocket, name: name)
    }
    /// Batch remove — the multi-select Add sheet's toggle-OFF. ONE mutate → ONE document
    /// write (the per-id loop re-encoded the multi-MB document N times on the main actor),
    /// one activity-batch emission for the ids that were actually members.
    func removeSongs(_ songIds: [String], fromPocket id: String) {
        let drop = Set(songIds)
        guard !drop.isEmpty, let p = pocket(id) else { return }
        let removed = p.songIds.filter { drop.contains($0) }
        guard !removed.isEmpty else { return }
        mutatePocket(id) { p in
            p.songIds.removeAll { drop.contains($0) }
            for s in drop { p.songRepeats[s] = nil }
        }
        let name = pocket(id)?.name
        emitActivityBatch(removed.map { ActivityHook(kind: .remove, itemId: $0,
                                                     itemTitle: activityTitle($0),
                                                     itemArtist: activityArtist($0),
                                                     collectionId: id,
                                                     collectionKind: AddTarget.Kind.pocket.rawValue,
                                                     collectionName: name) })
    }
    /// Set a pocket member's repeat (loop) count. A count ≤ 1 clears the key.
    func setSongRepeat(_ songId: String, count: Int, inPocket id: String) {
        mutatePocket(id) { $0.songRepeats[songId] = CollectionMembership.storedRepeat(count) }
    }
    /// The stored repeat count for a pocket member (1 when none).
    func repeatCount(forSong songId: String, inPocket id: String) -> Int {
        CollectionMembership.normalizedRepeat(pocket(id)?.songRepeats[songId])
    }
    func removeAlbum(_ albumId: String, fromPocket id: String) {
        let name = pocket(id)?.name
        mutatePocket(id) { $0.albumIds.removeAll { $0 == albumId } }
        emitRemoveActivity(itemId: albumId, collectionId: id, kind: .pocket, name: name)
    }
    /// Remove a nested child pocket from its parent — a user removal of an item from a
    /// collection, so it logs one remove activity like removeSong/removeAlbum/removeNode
    /// (itemId = the child pocket id, itemTitle = its name, collection = the parent).
    func removeChildPocket(_ childId: String, fromPocket id: String) {
        let parentName = pocket(id)?.name
        let childName = pocket(childId)?.name   // the child pocket itself survives; only the ref goes
        mutatePocket(id) { $0.childPocketIds.removeAll { $0 == childId } }
        emitRemoveActivity(itemId: childId, collectionId: id, kind: .pocket,
                           name: parentName, itemTitle: childName)
    }

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
        // R3 (second instance of the same asymmetry): nesting a pocket in a playlist emitted
        // nothing, while its inverse `removeNode` DOES emit — so the timeline showed the removal of
        // a pocket it never showed being added. `itemTitle` is passed explicitly because a POCKET
        // id resolves to no catalog song/album, so `activityTitle` would return nil.
        emitAddActivity(itemId: pocketId, target: AddTarget(kind: .playlist, id: id),
                        itemTitle: pocket(pocketId)?.name)
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
        // Snapshot the removed node's underlying item id + title BEFORE the mutation, so the
        // activity row names what left (a text/cue node has no item id → fall back to nodeId).
        let removed = playlist(id)?.sequences.lazy.compactMap { $0.children?.first { $0.nodeId == nodeId } }.first
        let itemId = removed?.songId ?? removed?.albumId ?? removed?.pocketId ?? nodeId
        let name = playlist(id)?.name
        mutatePlaylist(id) { pl in for i in pl.sequences.indices { pl.sequences[i].children?.removeAll { $0.nodeId == nodeId } } }
        emitRemoveActivity(itemId: itemId, collectionId: id, kind: .playlist, name: name)
    }

    /// Log a user REMOVE to the activity history (nil-safe when the seam is unwired).
    /// `itemTitle` overrides the catalog snapshot for items the catalog can't name (e.g. a
    /// child pocket id, which resolves to no catalog song); nil ⇒ resolve via `activityTitle`.
    private func emitRemoveActivity(itemId: String, collectionId: String,
                                    kind: AddTarget.Kind, name: String?,
                                    itemTitle: String? = nil) {
        onActivity?(ActivityHook(kind: .remove, itemId: itemId,
                                 itemTitle: itemTitle ?? activityTitle(itemId),
                                 itemArtist: activityArtist(itemId),
                                 collectionId: collectionId, collectionKind: kind.rawValue,
                                 collectionName: name))
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
        /// This source is a real Apple Music playlist AND the song can be written back — it has a
        /// store id OR enough identity (title+artist) to resolve one on-device at delivery. False ⇒
        /// the add is local-only by nature (a non-Apple-Music source playlist, or a song with no
        /// Apple Music identity at all).
        let writeBackEligible: Bool
        /// The store id the write-back would use — nil when the indexer never resolved one (the
        /// write-back then resolves it on-device from `title`/`artist`) or when not eligible.
        let appleMusicId: String?
        /// Song identity carried so the write-back can resolve a store id ON-DEVICE when
        /// `appleMusicId` is nil — the indexer-missed Apple Music song (the "Running It Up" case).
        /// Empty when not eligible / not a catalog song.
        let title: String
        let artist: String
        let album: String?
        let durationMs: Int?
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
            // R3 — LOG THE ADD. This path composes the two LOW-LEVEL primitives
            // (`duplicateForSource` + `addSong(_:toPlaylist:)`), neither of which emits, so an add
            // made from a "From your sources" row produced ZERO history rows: the user's add to an
            // Apple Music playlist was silently unrecorded. The emit belongs here, at the composed
            // choke point, not in the primitives (which reconcile/import also drive).
            //
            // GATED ON `!present` — LOAD-BEARING, not an optimization. `duplicateForSource` mints
            // the duplicate already seeded with EVERY id in `source.songIds`, so the very first tap
            // on a song the Apple Music playlist already contains finds `present == true` and
            // appends nothing. An unconditional emit would log "Added X" for an add that never
            // happened, and `backfillSourceWriteBacks` would then re-drive it upstream.
            //
            // `collectionId`/`collectionKind` name the on-device DUPLICATE (not the read-only
            // source): that is what `backfillSourceWriteBacks` resolves via `playlist(cid,
            // contains:)` when it re-drives missed write-backs.
            emitAddActivity(itemId: songId, target: AddTarget(kind: .playlist, id: pl.id))
        }

        let song = app?.songsById[songId]
        let amId = (appleMusicId ?? song?.appleMusicId ?? "").trimmingCharacters(in: .whitespaces)
        let title = (song?.name ?? "").trimmingCharacters(in: .whitespaces)
        let artist = (song?.artist ?? "").trimmingCharacters(in: .whitespaces)
        // Eligible when the target is a real Apple Music playlist AND we have SOMETHING to write
        // with — a known store id OR enough identity to resolve one on-device. The old gate was
        // `!amId.isEmpty`, which wrongly dropped Apple Music songs our indexer never resolved a
        // store id for (they read as "not an Apple Music track" and never synced); this matches the
        // converted-pocket path (`writeBackAddedSong`), which already enqueues identity-only songs.
        let eligible = PlaylistWriteBack.isAppleMusicSource(source.sourceName)
            && (!amId.isEmpty || (!title.isEmpty && !artist.isEmpty))
        let album = song?.albumId.flatMap { app?.albumsById[$0]?.name }
        return IndexPlaylistAdd(playlist: playlist(pl.id) ?? pl,
                                createdDuplicate: created,
                                alreadyPresent: present,
                                writeBackEligible: eligible,
                                appleMusicId: amId.isEmpty ? nil : amId,
                                title: title, artist: artist, album: album, durationMs: song?.length)
    }

    /// DIRECT membership test: does this playlist carry a `.song` node for `songId`?
    /// Membership, not resolution — unlike `playableIds(forPlaylist:)` this doesn't expand
    /// albums/pockets and doesn't need the catalog, so it answers correctly for a song the
    /// live catalog can't currently resolve.
    func playlist(_ id: String, contains songId: String) -> Bool {
        guard let pl = playlist(id) else { return false }
        return songIdsInNodes(pl.sequences).contains(songId)
    }

    /// Every `.song` node id in the playlist as ONE set — the batch membership check.
    /// Per-id `playlist(_:contains:)` walks the whole node tree per call, so an N-song
    /// batch (the Add-to sheet's `.songs` item) must resolve membership against this
    /// instead: one tree walk, N O(1) lookups.
    func playlistSongIdSet(_ id: String) -> Set<String> {
        guard let pl = playlist(id) else { return [] }
        return songIdsInNodes(pl.sequences)
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

    /// DIRECT album membership test (the `.album`-node twin of `playlist(_:contains:)`).
    func playlist(_ id: String, containsAlbum albumId: String) -> Bool {
        guard let pl = playlist(id) else { return false }
        return albumIdsInNodes(pl.sequences).contains(albumId)
    }

    private func albumIdsInNodes(_ nodes: [PlaylistNode]) -> Set<String> {
        var out = Set<String>()
        func walk(_ ns: [PlaylistNode]) {
            for n in ns {
                if n.kind == .album, let id = n.albumId { out.insert(id) }
                if let kids = n.children { walk(kids) }
            }
        }
        walk(nodes)
        return out
    }

    /// Toggle-OFF for the multi-select Add sheet: remove EVERY `.song` node for `songId` from a
    /// playlist (all chapters + nested sub-chapters). No-op when absent; one remove activity.
    func removeSong(_ songId: String, fromPlaylist id: String) {
        guard playlist(id, contains: songId) else { return }
        let name = playlist(id)?.name
        mutatePlaylist(id) { pl in
            for i in pl.sequences.indices {
                var kids = pl.sequences[i].children ?? []
                CollectionsStore.pruneNodes(&kids) { $0.kind == .song && $0.songId == songId }
                pl.sequences[i].children = kids
            }
        }
        emitRemoveActivity(itemId: songId, collectionId: id, kind: .playlist, name: name)
    }
    /// Batch twin of `removeSong(_:fromPlaylist:)` (the multi-song Add-sheet toggle-OFF):
    /// ONE mutate → ONE document write, one activity-batch emission for the actual members.
    func removeSongs(_ songIds: [String], fromPlaylist id: String) {
        let drop = Set(songIds)
        guard !drop.isEmpty else { return }
        let members = playlistSongIdSet(id)          // one tree walk, not one per id
        let removed = songIds.filter { members.contains($0) }
        guard !removed.isEmpty else { return }
        let name = playlist(id)?.name
        mutatePlaylist(id) { pl in
            for i in pl.sequences.indices {
                var kids = pl.sequences[i].children ?? []
                CollectionsStore.pruneNodes(&kids) { n in
                    n.kind == .song && (n.songId.map(drop.contains) ?? false)
                }
                pl.sequences[i].children = kids
            }
        }
        emitActivityBatch(removed.map { ActivityHook(kind: .remove, itemId: $0,
                                                     itemTitle: activityTitle($0),
                                                     itemArtist: activityArtist($0),
                                                     collectionId: id,
                                                     collectionKind: AddTarget.Kind.playlist.rawValue,
                                                     collectionName: name) })
    }

    /// Toggle-OFF for an `.album` node (all chapters). No-op when absent; one remove activity.
    func removeAlbum(_ albumId: String, fromPlaylist id: String) {
        guard playlist(id, containsAlbum: albumId) else { return }
        let name = playlist(id)?.name
        mutatePlaylist(id) { pl in
            for i in pl.sequences.indices {
                var kids = pl.sequences[i].children ?? []
                CollectionsStore.pruneNodes(&kids) { $0.kind == .album && $0.albumId == albumId }
                pl.sequences[i].children = kids
            }
        }
        emitRemoveActivity(itemId: albumId, collectionId: id, kind: .playlist, name: name)
    }

    /// Recursively drop every node matching `pred`, recursing into surviving nodes' children.
    private static func pruneNodes(_ nodes: inout [PlaylistNode], where pred: (PlaylistNode) -> Bool) {
        nodes.removeAll(where: pred)
        for i in nodes.indices {
            if var kids = nodes[i].children { pruneNodes(&kids, where: pred); nodes[i].children = kids }
        }
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
        let p = makeAndSavePocket(named: pl.name, songIds: refs.songIds, albumIds: refs.albumIds,
                                  childPocketIds: refs.childPocketIds, noteTexts: refs.noteTexts)
        // CARRY THE SOURCE LINK (Levi 2026-07-22). A playlist DUPLICATED from a "From your
        // sources" list carries provenance (`sourcePlaylistId`/`sourceName`/`sourceSongIds`);
        // converting it to a pocket used to DROP that link, so the classic flow
        // duplicate → convert → delete-the-playlist left an unlinked pocket whose adds could
        // never reach Apple Music. A pocket converted from a provenance-stamped playlist now
        // stays two-way-synced, exactly like one converted straight from the source.
        if pl.sourcePlaylistId != nil {
            mutatePocket(p.id) {
                $0.sourcePlaylistId = pl.sourcePlaylistId
                $0.sourceName = pl.sourceName
                $0.sourceSongIds = pl.sourceSongIds
                $0.sourceSyncEnabled = pl.sourceSyncEnabled
            }
        }
        return pocket(p.id) ?? p
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

    /// Link an EXISTING pocket to a "From your sources" playlist after the fact (Levi 2026-07-22).
    /// Recovers a pocket that has NO source link — one made by the classic duplicate → convert →
    /// delete-the-playlist flow before convert carried provenance, or a hand-built pocket the user
    /// now wants two-way-synced. Snapshots the source's CURRENT membership as the base, so the
    /// pocket's EXTRA songs (the user's own adds) read as adds — write-back candidates the backfill
    /// can push, and safe from reconcile removal — never as source removals. No-op (false) if the
    /// pocket is gone.
    @discardableResult
    func linkPocketToSource(_ pocketId: String, source: SourcePlaylist) -> Bool {
        guard let p = pocket(pocketId) else { return false }
        // RE-LINK away from a different source: cancel any still-undelivered write-backs owed to the
        // OLD source for this pocket's songs, so a queued-but-offline add can't later land in the
        // wrong Apple Music playlist. Scoped to this pocket's members (never a blanket wipe).
        if let old = p.sourcePlaylistId, old != source.id {
            cancelPendingWriteBacks?(old, Set(p.songIds))
        }
        var seen = Set<String>(); var ids: [String] = []
        for sid in source.songIds where seen.insert(sid).inserted { ids.append(sid) }
        mutatePocket(pocketId) {
            $0.sourcePlaylistId = source.id
            $0.sourceName = source.sourceName
            $0.sourceSongIds = ids
            // Do NOT force `sourceSyncEnabled = true`: a first-time link leaves it nil (→ enabled by
            // default via `syncsWithSource`'s `?? true`), and a RE-LINK preserves an explicit OFF the
            // user set — write-back doesn't depend on source-sync being on, so re-linking must not
            // silently re-subscribe the pocket to source-driven removals.
        }
        return true
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
    /// Set a collection's per-item Apple Music sync DIRECTION (nil-safe on a missing id).
    /// Rides `mutatePocket`/`mutatePlaylist` so it persists + cloud-syncs like every edit.
    func setAMSyncDirection(_ direction: CollectionSyncDirection, forPocket id: String) {
        mutatePocket(id) { $0.amSyncDirection = direction.rawValue }
    }
    func setAMSyncDirection(_ direction: CollectionSyncDirection, forPlaylist id: String) {
        mutatePlaylist(id) { $0.amSyncDirection = direction.rawValue }
    }

    /// Clean-versions-only toggle (see `CleanOnly`). Stored as `true`/nil (never `false`)
    /// so an untouched collection's serialized bytes are unchanged (CloudSync byte-compare).
    func setCleanOnly(_ on: Bool, forPlaylist id: String) {
        mutatePlaylist(id) { $0.cleanOnly = on ? true : nil }
    }
    func setCleanOnly(_ on: Bool, forPocket id: String) {
        mutatePocket(id) { $0.cleanOnly = on ? true : nil }
    }

    // MARK: Per-collection recommendations opt-out (For You)

    /// Turn For You's suggestions for this collection ON/OFF. Stored `false`/nil (never `true`)
    /// — the inverse of `setCleanOnly`'s idiom and for the same reason: ON is the default, so an
    /// untouched collection's serialized bytes must not change. See `Playlist.recsEnabled`.
    ///
    /// Rides `mutatePlaylist`/`mutatePocket`, so it persists and cloud-syncs like every other edit
    /// and the change is visible to the grid through `revision` on the next render.
    func setRecommendationsEnabled(_ on: Bool, forPlaylist id: String) {
        mutatePlaylist(id) { $0.recsEnabled = on ? nil : false }
    }
    func setRecommendationsEnabled(_ on: Bool, forPocket id: String) {
        mutatePocket(id) { $0.recsEnabled = on ? nil : false }
    }

    /// Does this collection want suggestions? Takes an id of UNKNOWN KIND, because that is all a
    /// For You tile carries. An id that resolves to NOTHING answers `true`: a since-deleted
    /// collection is dropped by the caller's own existence filter, and answering "off" here would
    /// silently double as a delete detector.
    func recommendationsEnabled(forCollection id: String) -> Bool {
        if let pl = playlist(id) { return pl.wantsRecommendations }
        if let p = pocket(id) { return p.wantsRecommendations }
        return true
    }

    /// Flip it from a tile, which knows only an id. Returns false when the id resolves to nothing.
    @discardableResult
    func setRecommendationsEnabled(_ on: Bool, forCollection id: String) -> Bool {
        if playlist(id) != nil { setRecommendationsEnabled(on, forPlaylist: id); return true }
        if pocket(id) != nil { setRecommendationsEnabled(on, forPocket: id); return true }
        return false
    }

    /// The ids `ForYouFeedBuilder` must NOT rank suggestions for. A `Set` because the builder
    /// tests it once per crate.
    func recommendationsOffIds() -> Set<String> {
        var out = Set<String>()
        for pl in playlists where !pl.wantsRecommendations { out.insert(pl.id) }
        for p in pockets where !p.wantsRecommendations { out.insert(p.id) }
        return out
    }

    /// EVERY collection with recommendations turned off, named — the "turn it back on" list.
    ///
    /// ── WHY THIS IS NOT `suggestibleCollections().filter { … }` ──────────────────────────────
    /// That one drops EMPTY collections (no members ⇒ no profile to suggest against). The whole
    /// point of this list is to reach a collection whose tile is not there, and "empty" is one of
    /// the ways a tile is not there. Filtering the suggestible set would make an empty, switched-off
    /// collection unreachable from the only screen that can switch it back on.
    ///
    /// Sorted by name so the list is stable between reads.
    func recommendationsOffCollections() -> [(id: String, kind: String, name: String)] {
        var out: [(id: String, kind: String, name: String)] = []
        for pl in playlists where !pl.wantsRecommendations { out.append((pl.id, "playlist", pl.name)) }
        for p in pockets where !p.wantsRecommendations { out.append((p.id, "pocket", p.name)) }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                            || ($0.name == $1.name && $0.id < $1.id) }
    }

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
        // `amSyncDir.allowsPull` gates the PULL half per collection (Levi 2026-07-29): a
        // "Send only"/"Off" item stops following its source without touching the freeze toggle.
        for p in pockets where p.syncsWithSource && p.amSyncDir.allowsPull {
            guard let sp = match(p.sourcePlaylistId, p.sourceName) else { continue }
            if reconcilePocket(p.id, from: sp) { changed += 1 }
        }
        for pl in playlists where pl.syncsWithSource && pl.amSyncDir.allowsPull {
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
        // NAME+ARTIST duplicate gate (Levi 2026-07-29): a source add whose recording already
        // sits in the pocket under a DIFFERENT id (indexed twin, amlib twin, rip) is skipped —
        // "we shouldn't add a new song to a collection … if there is already a song with that
        // same name and artist".
        let keptAfterRemovals = p.songIds.filter { !removals.contains($0) }
        var presentKeys = Set(keptAfterRemovals.compactMap { sid in
            app?.songsById[sid].map { SongDuplicateJudge.key(name: $0.name, artist: $0.artist) }
        })
        let additions = srcIds.filter { sid in
            guard !snapSet.contains(sid), !current.contains(sid) else { return false }
            guard let song = app?.songsById[sid] else { return true }
            return presentKeys.insert(SongDuplicateJudge.key(name: song.name, artist: song.artist)).inserted
        }
        var newSongIds = keptAfterRemovals
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
        // NAME+ARTIST duplicate gate — the playlist twin of reconcilePocket's (a source add whose
        // recording already sits here under a different id is skipped; removals are pruned from a
        // separate pass below, and a removed id's key no longer guards once pruned next sync).
        let snapSetPl = Set(snapshot)
        var presentKeysPl = Set(currentSongIds.subtracting(removals).compactMap { sid in
            app?.songsById[sid].map { SongDuplicateJudge.key(name: $0.name, artist: $0.artist) }
        })
        let additions = srcIds.filter { sid in
            guard !snapSetPl.contains(sid), !currentSongIds.contains(sid) else { return false }
            guard let song = app?.songsById[sid] else { return true }
            return presentKeysPl.insert(SongDuplicateJudge.key(name: song.name, artist: song.artist)).inserted
        }

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
    /// Playlists in a folder (nil ⇒ top level), ordered by the user's chosen collection sort.
    /// The name-only overload above is retained as a stable name-ordered helper (used by tests).
    func playlists(inFolder id: String?, sortedBy order: CollectionSortOrder) -> [Playlist] {
        order.sorted(playlists.filter { $0.folderId == id })
    }
    /// Pockets in a folder (nil ⇒ top level), ordered by the user's chosen collection sort.
    func pockets(inFolder id: String?, sortedBy order: CollectionSortOrder) -> [Pocket] {
        order.sorted(pockets.filter { $0.folderId == id })
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

    /// Push `target` onto the front of the recent-add MRU: dedupe by (kind,id) IGNORING
    /// `sequenceId` (re-adding to a different chapter of the same playlist is the SAME target for
    /// this row, and the freshest chapter wins), move-to-front, cap at `maxRecentTargets`. Mutates
    /// the array only — the following `setLastAddTarget` save() persists it (both are called from
    /// the `addSong(_:to:)`/`addAlbum(_:to:)` choke points, so there's exactly one write).
    private func noteRecentTarget(_ target: AddTarget) {
        recentAddTargets.removeAll { $0.kind == target.kind && $0.id == target.id }
        recentAddTargets.insert(target, at: 0)
        if recentAddTargets.count > Self.maxRecentTargets {
            recentAddTargets.removeLast(recentAddTargets.count - Self.maxRecentTargets)
        }
    }

    /// A display title snapshot for an added/removed item id — catalog song, catalog album, or a
    /// Studio item (`smp_`/`lp_`/`ptn_`/`tk_`) via the studio seam. nil when nothing resolves
    /// (the activity row then reads "an unknown item" and shows the raw id beneath it — see
    /// `HistoryView.isUnresolved`), so this is always safe to call.
    private func activityTitle(_ id: String) -> String? {
        if let s = app?.songsById[id] { return s.name }
        if let a = app?.albumsById[id] { return a.name }
        if StudioFactory.isStudioId(id), let info = studioLookup?(id) { return info.title }
        return nil
    }

    /// The artist snapshot for an added/removed item id (song or album). nil when nothing
    /// resolves — same always-safe contract as `activityTitle`.
    private func activityArtist(_ id: String) -> String? {
        if let s = app?.songsById[id] { return s.artist }
        if let a = app?.albumsById[id] { return a.artist }
        return nil
    }

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
        noteRecentTarget(target)
        setLastAddTarget(target)
        emitAddActivity(itemId: songId, target: target)
        writeBackAddIfSourced(songId, target: target)
    }
    func addAlbum(_ albumId: String, to target: AddTarget) {
        switch target.kind {
        case .pocket:   addAlbum(albumId, toPocket: target.id)
        case .playlist: addAlbum(albumId, toPlaylist: target.id, sequenceId: target.sequenceId)
        }
        noteRecentTarget(target)
        setLastAddTarget(target)
        emitAddActivity(itemId: albumId, target: target)
    }

    /// What a playlist batch add dedups against. `.wholeCollection` (drops/pastes): a song
    /// already ANYWHERE in the playlist is skipped — a fumbled self-drop never mints
    /// duplicate nodes. `.targetChapter` (the Add-to sheet's per-chapter rows): only the
    /// chosen chapter's members block, so the sheet stays the deliberate-duplication path
    /// exactly like its single-song `addSong` twin. Pocket adds always dedup on membership.
    enum BatchDedupe { case wholeCollection, targetChapter }

    /// Batch membership add — the drag-&-drop / paste / multi-select "Add to" choke point.
    /// ONE mutate → ONE collections-document write, ONE activity-batch emission (the
    /// recorder does one log write for it), ONE write-back resolution for the whole batch.
    /// Ids are prefix-agnostic (studio ids ride verbatim, same doctrine as
    /// addSong(toPocket:)). MRU/lastAddTarget stamped once. Returns the count actually
    /// added; 0 ⇒ nothing saved, nothing emitted, nothing queued upstream.
    @discardableResult
    func addSongs(_ songIds: [String], to target: AddTarget,
                  dedupe: BatchDedupe = .wholeCollection) -> Int {
        var toAdd: [String] = []
        switch target.kind {
        case .pocket:
            guard let p = pocket(target.id) else { return 0 }
            var seen = Set(p.songIds)
            toAdd = songIds.filter { seen.insert($0).inserted }
            guard !toAdd.isEmpty else { return 0 }
            mutatePocket(target.id) { $0.songIds.append(contentsOf: toAdd) }
        case .playlist:
            guard let pl = playlist(target.id) else { return 0 }
            let targetIdx = target.sequenceId.flatMap { sid in
                pl.sequences.firstIndex { $0.nodeId == sid } } ?? 0
            let dedupeScope: [PlaylistNode] = (dedupe == .targetChapter
                && pl.sequences.indices.contains(targetIdx)) ? [pl.sequences[targetIdx]] : pl.sequences
            var seen = Set(dedupeScope.flatMap { ($0.children ?? [])
                .compactMap { $0.kind == .song ? $0.songId : nil } })
            toAdd = songIds.filter { seen.insert($0).inserted }
            guard !toAdd.isEmpty else { return 0 }
            var appended = false
            mutatePlaylist(target.id) { pl in
                // A playlist that decoded with NO chapters (lossy decode dropped an unknown
                // node kind, or an imported doc carried "sequences": []) self-heals: the
                // default chapter is a schema invariant, not user content (same repair the
                // source-sync reconcile applies).
                if pl.sequences.isEmpty { pl.sequences = [CollectionsFactory.makeSequence("Default")] }
                let seqIdx = target.sequenceId.flatMap { sid in
                    pl.sequences.firstIndex { $0.nodeId == sid } } ?? 0
                guard pl.sequences.indices.contains(seqIdx) else { return }
                var children = pl.sequences[seqIdx].children ?? []
                children.append(contentsOf: toAdd.map {
                    PlaylistNode(nodeId: CollectionsFactory.newNodeId(), kind: .song, songId: $0) })
                pl.sequences[seqIdx].children = children
                appended = true
            }
            // Nothing landed ⇒ report the truth: no MRU stamp, no History rows, and above all
            // no irreversible Apple Music write-back for songs that were never added locally.
            guard appended else { return 0 }
        }
        noteRecentTarget(target)
        setLastAddTarget(target)
        let collectionName = plainCollectionName(target)   // loop-invariant: resolved once
        emitActivityBatch(toAdd.map { ActivityHook(kind: .add, itemId: $0,
                                                   itemTitle: activityTitle($0),
                                                   itemArtist: activityArtist($0),
                                                   collectionId: target.id,
                                                   collectionKind: target.kind.rawValue,
                                                   collectionName: collectionName) })
        writeBackAddIfSourced(toAdd, target: target)
        return toAdd.count
    }

    // MARK: Two-way source sync — push a converted/duplicated collection's add upstream

    /// Resolve `target`'s Apple Music provenance and, if this collection came from an Apple
    /// Music "From your sources" playlist, push the just-added song up to that real library
    /// playlist. No-op for a plain (non-sourced) collection. Deliberately NOT called for
    /// ALBUM adds: an album is stored as a ref, not expanded to catalog tracks, and the
    /// source-row path doesn't write albums back either.
    private func writeBackAddIfSourced(_ songId: String, target: AddTarget) {
        _ = writeBackSong(songId, forTargetKind: target.kind, collectionId: target.id)
    }

    // MARK: Batch write-back (multi-select / drag / paste adds)

    /// Above this many upstream-owed songs, a batch add PARKS the Apple Music write-back
    /// behind an explicit confirmation instead of enqueueing: upstream adds are append-only
    /// and not retractable from this app, so a select-all-sized batch must never push
    /// implicitly (one drag-release must not rewrite the user's real library).
    static let writeBackConfirmThreshold = 50

    /// A large batch's upstream leg, awaiting the user's OK (see the threshold). Transient
    /// UI state — never persisted; RootView presents the confirmation alert. The LOCAL add
    /// has already been committed when this appears; only the Apple Music push waits.
    struct PendingWriteBackBatch: Identifiable {
        let id = UUID()
        var items: [PlaylistWriteBack.EnqueueItem]
        /// The real Apple Music playlist the items would be appended to.
        var playlistName: String
        var count: Int { items.count }
    }
    var pendingWriteBackBatch: PendingWriteBackBatch?

    /// Batch twin of the per-add write-back: resolves the target's provenance ONCE, builds
    /// every eligible item (same per-song eligibility as `writeBackAddedSong`, via the shared
    /// `writeBackPayload`), then either enqueues the whole batch as ONE queue write (small)
    /// or parks it behind the confirmation gate (large).
    private func writeBackAddIfSourced(_ songIds: [String], target: AddTarget) {
        guard !songIds.isEmpty,
              enqueueSourceWriteBack != nil || enqueueSourceWriteBackBatch != nil else { return }
        let plId: String?, sourceName: String?, allowsPush: Bool
        let collectionName: String, snapshot: [String]?
        switch target.kind {
        case .pocket:
            guard let p = pocket(target.id) else { return }
            (plId, sourceName, allowsPush, collectionName, snapshot) =
                (p.sourcePlaylistId, p.sourceName, p.amSyncDir.allowsPush, p.name, p.sourceSongIds)
        case .playlist:
            guard let pl = playlist(target.id) else { return }
            (plId, sourceName, allowsPush, collectionName, snapshot) =
                (pl.sourcePlaylistId, pl.sourceName, pl.amSyncDir.allowsPush, pl.name, pl.sourceSongIds)
        }
        guard allowsPush, plId != nil, PlaylistWriteBack.isAppleMusicSource(sourceName ?? "") else { return }
        let snap = Set(snapshot ?? [])   // the snapshot is scanned per song — Set it once
        let items = songIds.compactMap {
            writeBackPayload($0, sourcePlaylistId: plId, sourceName: sourceName,
                             sourceSnapshot: snap, collectionName: collectionName, force: false).item
        }
        guard !items.isEmpty else { return }
        if items.count > Self.writeBackConfirmThreshold {
            // A platform/session that can't deliver must never show a confirm dialog for nothing.
            if let can = canWriteBackUpstream, !can() { return }
            pendingWriteBackBatch = PendingWriteBackBatch(items: items,
                                                          playlistName: items[0].playlistName)
        } else {
            enqueueWriteBackItems(items)
        }
    }

    private func enqueueWriteBackItems(_ items: [PlaylistWriteBack.EnqueueItem]) {
        if let batch = enqueueSourceWriteBackBatch {
            _ = batch(items)
        } else if let enqueue = enqueueSourceWriteBack {
            for i in items {
                _ = enqueue(i.indexPlaylistId, i.playlistName, i.songId, i.appleMusicId,
                            i.title, i.artist, i.album, i.durationMs)
            }
        }
    }

    /// The user confirmed the parked batch — push it upstream (one queue write + one drain).
    func confirmPendingWriteBackBatch() {
        guard let pending = pendingWriteBackBatch else { return }
        pendingWriteBackBatch = nil
        enqueueWriteBackItems(pending.items)
    }
    /// The user declined — the local add stands; Apple Music is left untouched.
    func discardPendingWriteBackBatch() { pendingWriteBackBatch = nil }

    /// The outcome of a single write-back decision — rich enough to drive the force-sync UI's
    /// "queued / already-queued / why-not" feedback. The per-add path + backfill only ever care
    /// about `.queued` (a NEW job was enqueued); the force-sync action (`forceWriteBackSong`)
    /// reports the rest to the user so a skip is never silent again.
    enum WriteBackAttempt: Equatable {
        /// The queue accepted a NEW upstream job.
        case queued
        /// The seam took nothing — an equivalent job is already queued/delivered, the song settled
        /// `.unresolvable`, OR this platform/build can't write back (macOS / not-yet-authorized).
        /// The force-sync UI disambiguates these against `PlaylistWriteBack.canWriteBack` / `isUnsyncable`.
        case deduped
        /// This collection has no Apple Music source playlist to write to (a plain pocket, or a
        /// vinyl / My Digital / Imported source).
        case notLinked
        /// The collection's per-item sync direction is "Get only"/"Off" — writes upstream are
        /// deliberately disabled (e.g. a smart-playlist mirror the write API can't target).
        case pushDisabled
        /// A Studio/performance item (sample/loop/sequence/instrumental) — not an Apple Music
        /// catalog song, so there's nothing to add to a catalog playlist.
        case notCatalogSong
        /// A catalog song with NEITHER a store id NOR a title+artist to resolve one on-device.
        case noIdentity
        /// The song is already in the source SNAPSHOT (already upstream). Only returned on the
        /// non-force path; `forceWriteBackSong` deliberately overrides this guard.
        case alreadyUpstream
    }

    /// Resolve a collection's Apple Music provenance from its id + kind, then decide whether to
    /// write `songId` back. Shared by the per-add path, the backfill, and the force-sync action.
    /// `force` bypasses the "already in the source snapshot" guard (see `writeBackAddedSong`).
    @discardableResult
    private func writeBackSong(_ songId: String, forTargetKind kind: AddTarget.Kind,
                              collectionId: String, force: Bool = false) -> WriteBackAttempt {
        switch kind {
        case .pocket:
            guard let p = pocket(collectionId) else { return .notLinked }
            // Direction gate (Levi 2026-07-29): a "Get only"/"Off" collection never writes
            // upstream — the exact protection a smart-playlist mirror needs.
            guard p.amSyncDir.allowsPush else { return .pushDisabled }
            return writeBackAddedSong(songId, sourcePlaylistId: p.sourcePlaylistId,
                                      sourceName: p.sourceName, sourceSnapshot: p.sourceSongIds,
                                      collectionName: p.name, force: force)
        case .playlist:
            guard let pl = playlist(collectionId) else { return .notLinked }
            guard pl.amSyncDir.allowsPush else { return .pushDisabled }
            return writeBackAddedSong(songId, sourcePlaylistId: pl.sourcePlaylistId,
                                      sourceName: pl.sourceName, sourceSnapshot: pl.sourceSongIds,
                                      collectionName: pl.name, force: force)
        }
    }

    /// FORCE a write-back attempt for one song in a collection, bypassing the "already in the
    /// source snapshot" guard — the manual escape hatch behind the collection row's context-menu
    /// "Force Apple Music sync" (Levi 2026-07-24). Used when a song the user KNOWS isn't in the
    /// real Apple Music playlist reads as "already upstream" because the pocket's snapshot is stale
    /// or over-broad (the very failure mode the re-link flow also targets). Same append-only safety
    /// as every other write-back path: it only ever ENQUEUES, never removes, so a wrong force is
    /// harmless (the local membership already stands). Returns the outcome for user feedback; the
    /// wired seam still applies the final `canWriteBack` gate and its own queued/delivered dedup.
    @discardableResult
    func forceWriteBackSong(_ songId: String, forTargetKind kind: AddTarget.Kind,
                            collectionId: String) -> WriteBackAttempt {
        writeBackSong(songId, forTargetKind: kind, collectionId: collectionId, force: true)
    }

    /// The write-back decision, factored out so pocket and playlist share it verbatim. Fires
    /// the seam only when there is genuinely an Apple Music playlist owed a song — every guard
    /// below is a real reason NOT to write, mirroring `addSong(_:toIndexPlaylist:)`'s eligibility:
    ///   • the collection carries Apple Music provenance (`sourcePlaylistId` + Apple Music source);
    ///   • the song has an Apple Music store id — a vinyl / My Digital / Studio id has no upstream;
    ///   • the song is NOT already in the source SNAPSHOT. The snapshot IS Apple Music's membership
    ///     as of the last catalog refresh, so a song already in it is already upstream and re-adding
    ///     would DUPLICATE the track (`MusicLibrary.add` is not idempotent). This is the same guard
    ///     `AddToCollectionView.addToSource` applies via the live source membership, but read from
    ///     the locally-stored snapshot so it holds offline too.
    /// The seam itself (wired in the app) applies the final `canWriteBack` gate and dedups
    /// queued/delivered jobs, so this stays purely about "is an upstream write owed at all".
    /// Returns the `WriteBackAttempt` outcome; `force` overrides the snapshot guard (see below).
    @discardableResult
    private func writeBackAddedSong(_ songId: String, sourcePlaylistId: String?,
                                    sourceName: String?, sourceSnapshot: [String]?,
                                    collectionName: String, force: Bool = false) -> WriteBackAttempt {
        guard let enqueue = enqueueSourceWriteBack else { return .notLinked }
        switch writeBackPayload(songId, sourcePlaylistId: sourcePlaylistId, sourceName: sourceName,
                                sourceSnapshot: Set(sourceSnapshot ?? []),
                                collectionName: collectionName, force: force) {
        case .ineligible(let verdict):
            return verdict
        case .eligible(let item):
            return enqueue(item.indexPlaylistId, item.playlistName, item.songId, item.appleMusicId,
                           item.title, item.artist, item.album, item.durationMs) ? .queued : .deduped
        }
    }

    /// One song's write-back eligibility, resolved to either the enqueue-able payload or the
    /// verdict explaining why there is none. The SINGLE implementation both the per-add path
    /// (`writeBackAddedSong`) and the batch path (`writeBackAddIfSourced(_:[String]:)`) run,
    /// so their eligibility can never drift.
    private enum WriteBackResolution {
        case eligible(PlaylistWriteBack.EnqueueItem)
        case ineligible(WriteBackAttempt)
        var item: PlaylistWriteBack.EnqueueItem? {
            if case .eligible(let i) = self { return i }
            return nil
        }
    }

    private func writeBackPayload(_ songId: String, sourcePlaylistId: String?, sourceName: String?,
                                  sourceSnapshot: Set<String>, collectionName: String,
                                  force: Bool) -> WriteBackResolution {
        guard let plId = sourcePlaylistId,
              PlaylistWriteBack.isAppleMusicSource(sourceName ?? "") else { return .ineligible(.notLinked) }
        // Only CATALOG songs can be written back. Studio performance items aren't in `songsById`
        // (excluded by construction), but "Pocket DJ" PROFILE items ARE full songsById citizens —
        // device-local custom audio has NO Apple Music counterpart, so fence it EXPLICITLY, else a
        // title/artist match could push a WRONG track into the user's real Apple Music playlist.
        guard !ProfileSourceStore.isProfileSongId(songId) else { return .ineligible(.notCatalogSong) }
        guard let song = app?.songsById[songId] else { return .ineligible(.notCatalogSong) }
        let amId = (song.appleMusicId ?? "").trimmingCharacters(in: .whitespaces)
        let title = song.name.trimmingCharacters(in: .whitespaces)
        let artist = song.artist.trimmingCharacters(in: .whitespaces)
        // Need a KNOWN catalog id, or enough identity to resolve one on-device (the case our
        // indexer missed — e.g. "The Magic Clap" by The Coup, an Apple Music (Local) song with no
        // `appleMusicId`). With neither, there's nothing to write; the local add is the whole op.
        guard !amId.isEmpty || (!title.isEmpty && !artist.isEmpty) else { return .ineligible(.noIdentity) }
        // The snapshot IS Apple Music's membership as of the last catalog refresh, so a song already
        // in it is already upstream and re-adding would DUPLICATE the track. A FORCE sync overrides
        // this: the user is explicitly telling us the song is NOT actually in the real playlist
        // (a stale / over-broad snapshot — the same failure the re-link flow rescues), and the
        // transport's own "already in the playlist?" pre-check is the backstop against a true dup.
        if !force, sourceSnapshot.contains(songId) { return .ineligible(.alreadyUpstream) }
        let album = song.albumId.flatMap { app?.albumsById[$0]?.name }
        // The join key is the source playlist id; the NAME is only the first-resolve bootstrap
        // (`PlaylistWriteBack` remembers the MusicKit id thereafter). Prefer the live source
        // playlist's current name (drift-proof), falling back to the collection's own name — its
        // value at convert/duplicate time — when the catalog isn't loaded, because `enqueue`
        // rejects an empty name.
        let name = liveSourcePlaylist(id: plId, sourceName: sourceName)?.name ?? collectionName
        return .eligible(.init(indexPlaylistId: plId, playlistName: name, songId: songId,
                               appleMusicId: amId.isEmpty ? nil : amId, title: title, artist: artist,
                               album: album, durationMs: song.length))
    }

    /// The default look-back for the write-back backfill, and the ceiling the UI clamps to.
    static let writeBackBackfillDefaultDays = 2
    static let writeBackBackfillMaxDays = 90

    /// BACKFILL the outbound Apple Music write-back from the collection ACTIVITY history: for
    /// every ADD in the last `days` days to a converted pocket / duplicated Apple Music
    /// collection, re-drive the same write-back decision the per-add path makes now. This
    /// recovers adds made BEFORE the write-back wiring existed, or while offline / signed out —
    /// the case the user hits after upgrading. Driven off the activity log (not raw membership)
    /// so it can be time-bounded and so it mirrors exactly what History ▸ Collection shows.
    ///
    /// IDEMPOTENT by construction: the per-(collection,song) pair is considered once, a song
    /// still in the source snapshot is skipped (already upstream), and `PlaylistWriteBack.enqueue`
    /// dedups against queued/delivered jobs — so running it twice, or overlapping with the
    /// per-add path, queues nothing extra. A song since REMOVED from the collection is skipped
    /// (its add was undone). Returns the number of songs NEWLY queued.
    ///
    /// LOCAL-ORIGIN ONLY. The activity log is CLOUD-SYNCED — a peer device's adds are merged in —
    /// but the write-back queue that dedups deliveries is deliberately device-local, so re-driving
    /// a PEER's add here would re-deliver a write another device already made (a duplicate in the
    /// real Apple Music playlist). So only events THIS install originated are considered; a legacy
    /// event with no origin (recorded before attribution existed) is treated as local — those are
    /// exactly the pre-wiring adds this backfill is meant to recover, and the transport's own
    /// "already in the playlist?" check is the backstop against a legacy add a peer already sent.
    @discardableResult
    func backfillSourceWriteBacks(from events: [CollectionActivityStore.ActivityEvent],
                                  days: Int, localInstallId: String?,
                                  nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Int {
        guard enqueueSourceWriteBack != nil else { return 0 }
        let clampedDays = min(max(days, 1), Self.writeBackBackfillMaxDays)
        let sinceMs = nowMs - Double(clampedDays) * 86_400_000
        var seen = Set<String>()
        var queued = 0
        // Newest-first so a re-add after a remove is judged on the LATEST add's timestamp.
        for e in events.reversed() where e.kind == .add && e.at >= sinceMs {
            // Skip a peer device's attributed add (see LOCAL-ONLY note); nil origin = legacy = local.
            guard e.originInstallId == nil || e.originInstallId == localInstallId else { continue }
            guard let cid = e.collectionId, !e.itemId.isEmpty,
                  let kind = e.collectionKind.flatMap(AddTarget.Kind.init(rawValue:)) else { continue }
            let key = cid + "\u{1}" + e.itemId
            guard seen.insert(key).inserted else { continue }
            // The song must still BE in the collection — an add later undone by a remove owes
            // Apple Music nothing. (`writeBackSong` itself skips a missing collection.)
            let stillMember: Bool = {
                switch kind {
                case .pocket:   return pocket(cid)?.songIds.contains(e.itemId) ?? false
                case .playlist: return playlist(cid, contains: e.itemId)
                }
            }()
            guard stillMember else { continue }
            if case .queued = writeBackSong(e.itemId, forTargetKind: kind, collectionId: cid) { queued += 1 }
        }
        return queued
    }

    /// Log a user ADD to the activity history (nil-safe when the seam is unwired). Resolves the
    /// collection name from the live target so the row reads standalone even after a rename/delete.
    /// Uses the PLAIN collection name (not `lastTargetLabel`'s "› Chapter" form) so an ADD and a
    /// REMOVE of the same list read consistently ("Added X to Set" / "Removed X from Set").
    /// `itemTitle` overrides the catalog snapshot for items the catalog can't name (mirrors
    /// `emitRemoveActivity`) — a child POCKET id resolves to no catalog song, so the pocket's own
    /// name is passed in.
    private func emitAddActivity(itemId: String, target: AddTarget, itemTitle: String? = nil) {
        onActivity?(ActivityHook(kind: .add, itemId: itemId,
                                 itemTitle: itemTitle ?? activityTitle(itemId),
                                 itemArtist: activityArtist(itemId),
                                 collectionId: target.id, collectionKind: target.kind.rawValue,
                                 collectionName: plainCollectionName(target)))
    }

    /// The PLAIN collection name (pocket/playlist `.name`, no chapter suffix) for a target — the
    /// shared source both ADD and REMOVE activity rows name the list from (FIX 4). nil if it's gone.
    private func plainCollectionName(_ target: AddTarget) -> String? {
        switch target.kind {
        case .pocket:   return pocket(target.id)?.name
        case .playlist: return playlist(target.id)?.name
        }
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
    /// CHEAP: O(pockets), not O(every member id in the document). It used to eagerly build a
    /// studio lookup TABLE by walking every pocket's members and every playlist's whole node
    /// tree — and this method is called from inside row builders, so the Collections list paid
    /// the cost of the entire collections document once per rendered row. `CollectionCatalog`
    /// now takes the `studioLookup` SEAM itself and consults it only for an id that misses the
    /// catalog and looks like a studio id, which is strictly less work with no cache to
    /// invalidate. Same referenced-only property as before: the catalog still never enumerates
    /// the studio library, it only answers questions about ids the collections already carry.
    func catalog() -> CollectionCatalog {
        let pocketsById = Dictionary(pockets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return CollectionCatalog(songsById: app?.songsById ?? [:],
                                 albumsById: app?.albumsById ?? [:],
                                 pocketsById: pocketsById,
                                 studioLookup: studioLookup)
    }

    // MARK: Subtitle stats (catalog-backed, cache-fronted)
    //
    // Use THESE, not `catalog().stats(…)`, from any view that shows a collection's
    // "N songs · runtime". Collections decode from disk synchronously and are on screen at once,
    // but the catalog they resolve against is a ~50 MB decode — so a raw resolve reads
    // "0 songs · 0m" on every cold launch until it lands. These remember the last real answer
    // and show that in the meantime. See `CollectionStatsCache` for why that can only ever
    // delay bad news, not invent good news.

    /// The catalog has actually loaded — the discriminator between "this collection resolved to
    /// nothing" and "there is nothing to resolve against yet".
    private var catalogReady: Bool { !(app?.songsById.isEmpty ?? true) }

    func stats(forPlaylist playlist: Playlist) -> CollectionCatalog.Stats {
        resolvedStats(id: playlist.id, stamp: playlist.updatedAt) { $0.stats(forPlaylist: playlist) }
    }

    func stats(forPocket id: String) -> CollectionCatalog.Stats {
        resolvedStats(id: id, stamp: pocket(id)?.updatedAt ?? 0) { $0.stats(forPocket: id) }
    }

    /// Chapters are keyed by their node id, which is unique across the document. A chapter has no
    /// `updatedAt` of its own, so it rides its owning playlist's — every chapter edit goes through
    /// `mutatePlaylist`, which stamps it.
    func stats(forChapter chapter: PlaylistNode) -> CollectionCatalog.Stats {
        let stamp = playlists.first { $0.sequences.contains { $0.nodeId == chapter.nodeId } }?.updatedAt ?? 0
        return resolvedStats(id: chapter.nodeId, stamp: stamp) { $0.stats(forChapter: chapter) }
    }

    /// In-memory memo so re-rendering a list doesn't re-resolve every row. `stamp` is the
    /// collection's `updatedAt` (bumped by `mutatePlaylist`/`mutatePocket` on every membership
    /// or name change) and `catalogRevision` covers the catalog side, so between them any input
    /// that could change the answer changes the key. @ObservationIgnored: this is filled while a
    /// view body READS it, and invalidating that body from inside itself would loop.
    @ObservationIgnored private var statsMemo: [String: (key: String, stats: CollectionCatalog.Stats)] = [:]

    private func resolvedStats(id: String, stamp: Double,
                               _ derive: (CollectionCatalog) -> CollectionCatalog.Stats) -> CollectionCatalog.Stats {
        guard catalogReady else { return statsCache.stats(for: id) ?? CollectionCatalog.Stats() }
        let key = "\(app?.catalogRevision ?? 0)|\(stamp)"
        if let memo = statsMemo[id], memo.key == key { return memo.stats }
        let stats = derive(catalog())
        statsMemo[id] = (key, stats)
        statsCache.record(stats, for: id, catalogReady: true)
        return stats
    }

    /// Persist the subtitle cache and drop entries for deleted collections. Called from the
    /// app's background/inactive hook — not per row — so a list render never touches the disk.
    func flushStatsCache() {
        var live = Set(playlists.map(\.id))
        live.formUnion(pockets.map(\.id))
        for pl in playlists {
            for seq in pl.sequences { live.insert(seq.nodeId) }
        }
        statsCache.prune(keeping: live)
        statsCache.flushIfNeeded()
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
        return catalog().songs(inPlaylist: pl).map { $0.id }
            .filter { !StudioFactory.isStudioId($0) && !ProfileSourceStore.isProfileSongId($0) }
    }
    /// Every resolved song id of a pocket DAG (own + album tracks + nested, cycle-guarded).
    /// CATALOG-ONLY — same studio strip as `songIds(forPlaylist:)`, same reason.
    func songIds(forPocket id: String) -> [String] {
        var seen = Set<String>()
        return catalog().resolvePocketSongs(id, seen: &seen).map { $0.id }
            .filter { !StudioFactory.isStudioId($0) && !ProfileSourceStore.isProfileSongId($0) }
    }
    /// Every audio track's song id of a frozen setlist (text cues excluded). STUDIO rows
    /// are excluded exactly like text cues: this raw-passthrough resolver feeds the
    /// setlist Rip/Burn buttons, the CSV export, and StorageCollectionsView — a frozen
    /// set that carries a loop row must not enqueue `lp_…` at the rip server or write it
    /// into a tracklist CSV (spec §8; playback reads `playableIds(forSetlist:)`).
    func songIds(forSetlist id: String) -> [String] {
        guard let sl = setlist(id) else { return [] }
        return sl.tracks
            .filter { $0.isText != true && !$0.songId.isEmpty && !StudioFactory.isStudioId($0.songId)
                      && !ProfileSourceStore.isProfileSongId($0.songId) }
            .map { $0.songId }
    }
    /// A read-only "From your sources" playlist's song ids (already a flat list).
    func songIds(forSource source: SourcePlaylist) -> [String] { source.songIds }

    // MARK: Collection → ripIds (the rip/burn/stem funnels — cleanOnly-aware)
    //
    // Same catalog-only resolution as `songIds(...)` but routed through `CleanOnly.ripIds`
    // when the collection's cleanOnly toggle is on: explicit songs become their VARIANT id
    // ("<baseId>_clean" — a distinct S3/burn key) or drop. `songIds(...)` itself is
    // deliberately untouched — it also feeds CSV export + StorageView, where variant ids
    // must never leak into tracklists.

    /// Rip/burn/stem id list for a playlist (variant-substituted under cleanOnly).
    func ripIds(forPlaylist id: String) -> [String] {
        let ids = songIds(forPlaylist: id)
        guard playlist(id)?.cleanOnly == true, let app else { return ids }
        return CleanOnly.ripIds(ids: ids, songsById: app.songsById)
    }
    /// Rip/burn/stem id list for a pocket (variant-substituted under cleanOnly).
    func ripIds(forPocket id: String) -> [String] {
        let ids = songIds(forPocket: id)
        guard pocket(id)?.cleanOnly == true, let app else { return ids }
        return CleanOnly.ripIds(ids: ids, songsById: app.songsById)
    }
    /// Rip/burn/stem id list for a FROZEN setlist: same filters as `songIds(forSetlist:)`,
    /// but each track's frozen `variant` stamp (a cleanOnly realize/playNow substitution)
    /// yields its variant id — the freeze decided the edition, so rips follow it.
    func ripIds(forSetlist id: String) -> [String] {
        guard let sl = setlist(id) else { return [] }
        return sl.tracks
            .filter { $0.isText != true && !$0.songId.isEmpty && !StudioFactory.isStudioId($0.songId)
                      && !ProfileSourceStore.isProfileSongId($0.songId) }
            .map { t in t.songVariant.map { SongVariant.variantId(t.songId, $0) } ?? t.songId }
    }

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
    /// Every collection the For You grid may offer "add these" suggestions for.
    ///
    /// Both playlists and pockets, resolved through `playableIds` so a pocket's DAG and a
    /// playlist's album/pocket members are expanded to real songs — suggesting a song that is
    /// already in the collection via an album member would be an obvious wrong answer.
    ///
    /// EMPTY COLLECTIONS ARE EXCLUDED: with no members there is no profile to match against, so
    /// any "suggestion" would be arbitrary. Setlists are excluded too — a setlist is a FROZEN
    /// performance instance, so proposing additions to one is meaningless.
    ///
    /// ── THE RECOMMENDATIONS OPT-OUT IS DELIBERATELY *NOT* APPLIED HERE ───────────────────────
    /// A switched-off collection (`recsEnabled == false`) still belongs in this list, because this
    /// list has TWO consumers and only one of them is "what to suggest for". The other is In Da
    /// Zone's `otherCollections` — the CO-MEMBERSHIP similarity signal, i.e. "you file these
    /// together". Turning off suggestions FOR Comfort Zone is a statement about that tile; it is
    /// not a statement that Comfort Zone's contents should stop informing what to play. Dropping it
    /// here would quietly degrade In Da Zone for everyone who closes a crate.
    ///
    /// The opt-out is applied one layer up, at the only place it means anything: the crate
    /// SUGGESTION pass (`ForYouFeedBuilder.build`, via `ForYouFeedInputs.recsOffCrateIds`), which
    /// is also where the expensive per-collection catalog sweep is skipped.
    func suggestibleCollections() -> [(id: String, kind: String, name: String, songIds: [String])] {
        var out: [(id: String, kind: String, name: String, songIds: [String])] = []
        for p in playlists {
            let ids = playableIds(forPlaylist: p.id)
            if !ids.isEmpty { out.append((p.id, "playlist", p.name, ids)) }
        }
        for p in pockets {
            let ids = playableIds(forPocket: p.id)
            if !ids.isEmpty { out.append((p.id, "pocket", p.name, ids)) }
        }
        return out
    }

    /// Playable ids for a collection id whose KIND the caller doesn't know — the For You tiles
    /// carry only an id, since the tile was built from `suggestibleCollections()`. Playlist is
    /// tried first (ids are disjoint across the two stores, so order is arbitrary); an id that
    /// matches neither returns [] rather than trapping, which is what a tile for a
    /// since-deleted collection needs.
    func playableIdsForAnyCollection(_ id: String) -> [String] {
        if playlist(id) != nil { return playableIds(forPlaylist: id) }
        if pocket(id) != nil { return playableIds(forPocket: id) }
        return []
    }

    /// The `AddTarget` for a collection id of unknown kind — the For You collection tile's
    /// one-tap ＋. nil when the id no longer resolves, so the caller falls back to the sheet
    /// instead of adding into nothing.
    func addTargetForAnyCollection(_ id: String) -> AddTarget? {
        if playlist(id) != nil { return AddTarget(kind: .playlist, id: id, sequenceId: nil) }
        if pocket(id) != nil { return AddTarget(kind: .pocket, id: id) }
        return nil
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
        // Profile ("Pocket DJ") ids ARE in songsById (unlike studio ids), so skip them here too —
        // a device-local custom item must never be named into a BURN sidecar (a fourth fence).
        // Metadata resolves by the BASE id (a variant id "sng_…_clean" isn't in the catalog);
        // the tuple keeps the VARIANT id so the burn downloads + names the variant file.
        songIds.filter { !ProfileSourceStore.isProfileSongId($0) }
            .compactMap { id in
                app?.songsById[SongVariant.baseId(id)].map { (id: id, title: $0.name, artist: $0.artist) }
            }
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
        var setlist = RealizeEngine.buildSetlist(pl, ctx, seed: theSeed, name: theName, now: now)
        // Clean-versions-only playlist: FREEZE the decision into the setlist — skipped
        // songs drop, substituted ones carry `variant = "clean"` — so the frozen set plays
        // (and rips) the same editions forever, even if the toggle later flips.
        if pl.cleanOnly == true, let app {
            setlist.tracks = setlist.tracks.compactMap { t in
                guard t.isText != true, let s = app.songsById[t.songId] else { return t }
                if CleanOnly.isSkipped(s) { return nil }
                guard s.explicit == true else { return t }
                var out = t
                out.variant = SongVariant.clean.rawValue
                return out
            }
            setlist.totalMs = setlist.tracks.reduce(0) { $0 + $1.shownMs }
        }
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
                 originId: String? = nil, variants: [String: SongVariant] = [:]) -> Setlist? {
        // THE ONE FUNNEL every "start playing this set" path in the app goes through, which makes
        // it the only correct place to retire a stale recommendation scope. A For You list calls
        // `beginPlayback` immediately AFTER this returns; everything else (a playlist, an album,
        // Browse, CarPlay, Siri) leaves the scope cleared, so the now-playing 👍/👎 pair hides
        // instead of filing a verdict against a tile the listener has since left.
        //
        // Without this the scope outlives its queue: start a playlist that happens to contain a
        // song from an earlier In Da Zone set and the thumbs reappear, filing against `zone`.
        //
        // Fired BEFORE the `app` guard on purpose. The guard is "this store has no catalog wired",
        // which is a test/preview condition, not a runtime one — and a request to play something
        // else has already invalidated the old scope by the time we find out we cannot serve it.
        onPlaybackReplaced?()
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
            // catalog id on the line below. (Variants never apply to studio rows.)
            if StudioFactory.isStudioId(id) {
                guard let info = studioLookup?(id) else { return nil }
                return SetlistTrack(songId: id, artist: studioArtist, name: info.title,
                                    bpm: info.bpm, camelot: info.camelot, lengthMs: info.lengthMs,
                                    source: .explicit, repeatCount: rep)
            }
            guard let s = app.songsById[id] else { return nil }   // drop unresolvable ids
            return SetlistTrack(songId: s.id, artist: s.artist, name: s.name,
                                bpm: s.bpm, camelot: s.camelot, lengthMs: s.length,
                                source: .explicit, repeatCount: rep,
                                variant: variants[id]?.rawValue)
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
        // Stamp "recently played" here — the single funnel every collection-play entry point
        // (detail views, CarPlay, Siri/App Intents via IntentServices.playPlaylist) routes through.
        markPlayed(playlistId: playlistId)
        // Clean-versions-only: resolve the queue THROUGH CleanOnly at this single funnel
        // (covers detail ▶, shuffle, CarPlay, Siri/App Intents) — explicit songs substitute
        // their clean edition or drop; everything else passes untouched.
        var ids = playableIds(forPlaylist: playlistId)
        var variants: [String: SongVariant] = [:]
        if playlist(playlistId)?.cleanOnly == true, let app {
            let r = CleanOnly.resolve(ids: ids, songsById: app.songsById)
            ids = r.ids; variants = r.variants
        }
        return playNow(songIds: ids,
                name: playlist(playlistId)?.name ?? "Now Playing", shuffle: shuffle, source: .playlist,
                repeats: playlistRepeatMap(playlistId), originId: playlistId, variants: variants)
    }
    /// ▶ Play a pocket into the reusable Now Playing setlist (DAG-resolved order).
    /// `playableIds` for the same reason as the playlist variant above.
    @discardableResult
    func playNow(pocketId: String, shuffle: Bool = false) -> Setlist? {
        // Stamp "recently played" here — the single funnel every pocket-play entry point
        // (PocketsView, CarPlay, Siri/App Intents via IntentServices.playPocket) routes through.
        markPlayed(pocketId: pocketId)
        var ids = playableIds(forPocket: pocketId)
        var variants: [String: SongVariant] = [:]
        if pocket(pocketId)?.cleanOnly == true, let app {
            let r = CleanOnly.resolve(ids: ids, songsById: app.songsById)
            ids = r.ids; variants = r.variants
        }
        return playNow(songIds: ids,
                name: pocket(pocketId)?.name ?? "Now Playing", shuffle: shuffle, source: .pocket,
                repeats: pocket(pocketId)?.songRepeats ?? [:], originId: pocketId, variants: variants)
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

    /// Does the collection a RUN came from carry the clean-versions-only flag? Resolved
    /// through `originCollection` so it works for the reusable Now Playing setlist (whose
    /// origin is the pocket/playlist that filled it) as well as a frozen setlist played
    /// directly. This is rule 1 of `EditionPolicy` — the input that makes a clean-only
    /// collection beat the global "Prefer explicit versions" toggle. A setlist origin is
    /// false: a frozen set already carries its editions per track.
    func isCleanOnly(sourceSetlistId id: String?) -> Bool {
        guard let origin = originCollection(forSourceSetlistId: id) else { return false }
        switch origin.kind {
        case .playlist: return playlist(origin.id)?.cleanOnly == true
        case .pocket:   return pocket(origin.id)?.cleanOnly == true
        default:        return false
        }
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
        // Match-by-id merge (same idempotent doctrine as mergeBackupCollections): ids are PRESERVED,
        // so an item that already exists is merged (members unioned, songs deduped) rather than
        // duplicated, and its intra-doc references (childPocketIds, pocket nodes, folderId, setlist
        // playlistId) stay valid without remapping. A re-import is a no-op.
        for f in doc.folders { upsertFolder(f) }
        for p in doc.pockets { upsertPocket(p) }
        for pl in doc.playlists { upsertPlaylist(pl) }
        dropDanglingRefs()
        save()
    }

    /// Drop collection refs that resolve to NOTHING in the store — a folder or child-pocket id that
    /// isn't present anywhere (in this import or already local). Run after an id-PRESERVING import so
    /// a dangling ref never survives, while a ref to an item that DOES exist (the whole point of
    /// match-by-id merge) is kept. Idempotent + safe on pre-existing collections (they already
    /// resolve, so it's a no-op for them).
    private func dropDanglingRefs() {
        let folderIds = Set(folders.map(\.id))
        let pocketIds = Set(pockets.map(\.id))
        for i in pockets.indices {
            if let f = pockets[i].folderId, !folderIds.contains(f) { pockets[i].folderId = nil }
            let kept = pockets[i].childPocketIds.filter { pocketIds.contains($0) }
            if kept != pockets[i].childPocketIds { pockets[i].childPocketIds = kept }
        }
        for i in playlists.indices {
            if let f = playlists[i].folderId, !folderIds.contains(f) { playlists[i].folderId = nil }
        }
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
    // MARK: - Idempotent import merge (match-by-id; never duplicate a collection or a song in it)

    /// Restore/import merges by PRESERVING ids and matching an incoming collection to the existing
    /// one of the same id: a re-import of the same backup is a no-op, and a MODIFIED re-import unions
    /// in only the genuinely-new members (songs/albums/child-pockets/nodes) — it never creates a
    /// duplicate collection or re-adds a song already present. (This aligns the file backup with the
    /// CloudKit sync's stable-id model; the old behaviour reminted every id and appended, so a
    /// second import duplicated everything.)
    func mergeBackupCollections(pockets incPockets: [Pocket], playlists incPlaylists: [Playlist],
                                setlists incSetlists: [Setlist],
                                folders incFolders: [PlaylistFolder] = []) -> (pockets: Int, playlists: Int, setlists: Int) {
        for f in incFolders { upsertFolder(f) }
        for p in incPockets { upsertPocket(p) }
        for pl in incPlaylists { upsertPlaylist(pl) }
        // Setlists are frozen snapshots — keep one only when its parent playlist is present (drop
        // orphans, as before); upsert dedupes by setlist id so a re-import doesn't duplicate them.
        for sl in incSetlists where playlists.contains(where: { $0.id == sl.playlistId }) { upsertSetlist(sl) }
        dropDanglingRefs()
        save()
        // Report the number PROCESSED (added or merged) — every incoming item is restored either way.
        return (incPockets.count, incPlaylists.count, incSetlists.count)
    }

    /// Union `incoming` into `base`, preserving order and appending only ids not already present.
    private func unionIds(_ base: [String], _ incoming: [String]) -> [String] {
        var seen = Set(base); var out = base
        for id in incoming where seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// Content-identity of a LEAF node — for de-duping songs/albums/pockets/text within a chapter.
    /// Sequence (chapter) nodes are matched by nodeId, so they return nil here.
    private func nodeContentKey(_ n: PlaylistNode) -> String? {
        switch n.kind {
        case .song:     return n.songId.map { "s:\($0)" }
        case .album:    return n.albumId.map { "a:\($0)" }
        case .pocket:   return n.pocketId.map { "p:\($0)" }
        case .text:     return n.text.map { "t:\($0)" }
        case .sequence: return nil
        }
    }

    /// Merge one imported chapter's leaves into an existing chapter: append imported leaves whose
    /// CONTENT isn't already present (so a re-import is a no-op and a modified re-import adds only
    /// new items, never duplicating a song).
    private func mergeChapterChildren(into existing: PlaylistNode, from incoming: PlaylistNode) -> PlaylistNode {
        var merged = existing
        var kids = existing.children ?? []
        var present = Set(kids.compactMap(nodeContentKey))
        for child in incoming.children ?? [] {
            guard let key = nodeContentKey(child) else { continue }  // never nest a chapter in a chapter
            if present.insert(key).inserted { kids.append(child) }
        }
        merged.children = kids
        return merged
    }

    /// Add or MERGE an imported pocket by id (idempotent).
    @discardableResult
    private func upsertPocket(_ inc: Pocket) -> Bool {
        guard let i = pockets.firstIndex(where: { $0.id == inc.id }) else {
            var p = inc
            if p.createdAt == 0 { p.createdAt = now }
            p.updatedAt = now
            // Strip the Apple Music link on INSERT. A restored/imported collection is not
            // necessarily this user's own — a shared backup would otherwise carry a handle into
            // the sharer's library and push the importer's edits there. Costless to drop: the
            // next push re-establishes the link by name, which is what happened before links
            // existed at all.
            p.amPlaylistId = nil
            pockets.append(p)
            return true
        }
        var p = pockets[i]
        p.songIds = unionIds(p.songIds, inc.songIds)
        p.albumIds = unionIds(p.albumIds, inc.albumIds)
        p.childPocketIds = unionIds(p.childPocketIds, inc.childPocketIds)
        let haveNote = Set(p.notes.map(\.id))
        p.notes += inc.notes.filter { !haveNote.contains($0.id) }
        for (k, v) in inc.songRepeats where p.songRepeats[k] == nil { p.songRepeats[k] = v }
        p.updatedAt = now
        pockets[i] = p
        return false
    }

    /// Add or MERGE an imported playlist by id (idempotent). Chapters match by their sequence
    /// nodeId; leaves within a matched chapter union by content; genuinely-new chapters append.
    @discardableResult
    private func upsertPlaylist(_ inc: Playlist) -> Bool {
        guard let i = playlists.firstIndex(where: { $0.id == inc.id }) else {
            var pl = inc
            if pl.createdAt == 0 { pl.createdAt = now }
            pl.updatedAt = now
            pl.amPlaylistId = nil   // see the pocket note in upsertPocket
            playlists.append(pl)
            return true
        }
        var pl = playlists[i]
        var seqs = pl.sequences
        var byNodeId = Dictionary(seqs.enumerated().map { ($1.nodeId, $0) }, uniquingKeysWith: { a, _ in a })
        for incSeq in inc.sequences {
            if let idx = byNodeId[incSeq.nodeId] {
                seqs[idx] = mergeChapterChildren(into: seqs[idx], from: incSeq)
            } else {
                seqs.append(incSeq)
                byNodeId[incSeq.nodeId] = seqs.count - 1
            }
        }
        pl.sequences = seqs
        pl.updatedAt = now
        playlists[i] = pl
        return false
    }

    /// Add an imported folder by id if not already present (idempotent; folders carry no members).
    @discardableResult
    private func upsertFolder(_ inc: PlaylistFolder) -> Bool {
        guard !folders.contains(where: { $0.id == inc.id }) else { return false }
        var f = inc
        if f.createdAt == 0 { f.createdAt = now }
        f.updatedAt = now
        folders.append(f)
        return true
    }

    /// Add an imported (frozen) setlist by id if not already present. Frozen snapshots aren't merged.
    @discardableResult
    private func upsertSetlist(_ inc: Setlist) -> Bool {
        guard !setlists.contains(where: { $0.id == inc.id }) else { return false }
        setlists.append(inc)
        return true
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


    // MARK: Persistence

    private func mutatePocket(_ id: String, _ body: (inout Pocket) -> Void) {
        guard let i = pockets.firstIndex(where: { $0.id == id }) else { return }
        body(&pockets[i]); pockets[i].updatedAt = now; save()
    }
    private func mutatePlaylist(_ id: String, _ body: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        body(&playlists[i]); playlists[i].updatedAt = now; save()
    }

    // MARK: Recently-played stamps
    //
    // ▶ Play stamps `lastPlayedAt` for the "Recently played" collection sort. Deliberately
    // written + save()d DIRECTLY (NOT through mutatePlaylist/mutatePocket) so `updatedAt` —
    // the distinct "Last updated" signal — is never disturbed by playback. Missing id ⇒ no-op
    // (read-only source playlists have no editable record to stamp — recently-played is scoped
    // to the user's own playlists/pockets).

    /// Stamp a playlist's `lastPlayedAt` = now, WITHOUT touching `updatedAt`.
    func markPlayed(playlistId id: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].lastPlayedAt = now; save()
    }
    /// Stamp a pocket's `lastPlayedAt` = now, WITHOUT touching `updatedAt`.
    func markPlayed(pocketId id: String) {
        guard let i = pockets.firstIndex(where: { $0.id == id }) else { return }
        pockets[i].lastPlayedAt = now; save()
    }
    /// Bind a collection to the Apple Music library playlist the sync just pushed it to.
    ///
    /// A DIRECT write, deliberately not through `mutatePlaylist`/`mutatePocket`: stamping a link is
    /// bookkeeping about a sync that already happened, not a user edit, and bumping `updatedAt`
    /// would make every sync look like a fresh local change to the NEXT sync (and to CloudKit).
    /// Same reasoning as `markPlayed`. Idempotent — re-stamping the same id writes nothing.
    func linkToAppleMusic(playlistId id: String, amPlaylistId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }),
              playlists[i].amPlaylistId != amPlaylistId else { return }
        playlists[i].amPlaylistId = amPlaylistId; save()
    }
    func linkToAppleMusic(pocketId id: String, amPlaylistId: String) {
        guard let i = pockets.firstIndex(where: { $0.id == id }),
              pockets[i].amPlaylistId != amPlaylistId else { return }
        pockets[i].amPlaylistId = amPlaylistId; save()
    }

    // MARK: - Membership snapshot (the Gem Collector similarity profile)

    /// Monotonic, bumped on every persisted mutation and every reload/wipe. `@ObservationIgnored`
    /// ON PURPOSE: it is a MEMO KEY for off-main derivations, not something a view should
    /// re-render on.
    @ObservationIgnored private(set) var membershipRevision = 0
    @ObservationIgnored private var membershipSnapshotCache: (revision: Int, rows: [[String]])?

    /// Every collection's membership as flat id arrays, for Gem Collector's similarity profile
    /// (the "shared with another collection" signal).
    ///
    /// CAPPED like the rec-engine snapshot (300 collections / 5,000 members each / 200,000 ids
    /// total) and MEMOIZED on `membershipRevision`, both load-bearing rather than polish:
    /// `songIds(forPlaylist:)` walks a playlist's whole node tree and is `@MainActor`, and this
    /// is read from the 0.25 s ticker's mid-round top-up as well as every debounced settings
    /// keystroke — 300 playlists × thousands of nodes on the main thread is exactly the class
    /// of runloop stall the Browse off-main work eliminated. During a round membership only
    /// changes when the player files a song, so the cache hits on essentially every tick.
    func membershipSnapshotForSimilarity() -> [[String]] {
        if let cache = membershipSnapshotCache, cache.revision == membershipRevision {
            return cache.rows
        }
        var rows: [[String]] = []
        var total = 0
        for p in pockets.prefix(Self.similarityCollectionCap) {
            let ids = Array(songIds(forPocket: p.id).prefix(Self.similarityMemberCap))
            guard !ids.isEmpty else { continue }
            rows.append(ids); total += ids.count
            if total >= Self.similarityTotalIdCap { break }
        }
        if total < Self.similarityTotalIdCap {
            for pl in playlists.prefix(max(0, Self.similarityCollectionCap - rows.count)) {
                let ids = Array(songIds(forPlaylist: pl.id).prefix(Self.similarityMemberCap))
                guard !ids.isEmpty else { continue }
                rows.append(ids); total += ids.count
                if total >= Self.similarityTotalIdCap { break }
            }
        }
        membershipSnapshotCache = (membershipRevision, rows)
        return rows
    }

    private static let similarityCollectionCap = 300
    private static let similarityMemberCap = 5_000
    private static let similarityTotalIdCap = 200_000

    // MARK: - Membership as RECOMMENDATION IDENTITY (the "already in here" filter)

    /// One `RecMembership` per collection id, memoized on `membershipRevision`.
    @ObservationIgnored private var recMembershipCache: (revision: Int, byId: [String: RecMembership])?

    /// Who is already in this collection, in the identity form the suggestion surfaces compare
    /// against (see `RecMembership` — variant ids and `amrec_` captures fold onto the recording).
    ///
    /// MEMOIZED ON `membershipRevision`, which is exactly the right key in both directions:
    /// `playableIdsForAnyCollection` walks a playlist's whole node tree (or a pocket's DAG) and is
    /// main-actor work, so re-resolving it on every tile derivation would put a per-collection tree
    /// walk on a render path — and the memo can never go stale, because the only thing that changes
    /// membership is a persisted mutation, and every one of those bumps the revision.
    func recMembership(forCollection id: String) -> RecMembership {
        if let cache = recMembershipCache, cache.revision == membershipRevision,
           let hit = cache.byId[id] { return hit }
        let ids = playableIdsForAnyCollection(id)
        let songs = app?.songsById
        let m = RecMembership(memberIds: ids,
                              appleMusicId: { songs?[$0]?.appleMusicId },
                              // The VERSION half (feature 6). Parsed once per collection per
                              // `membershipRevision` — the memo below is what keeps this off the
                              // render path even for a 5,000-song crate.
                              titleArtist: { songs?[$0].map { (title: $0.name, artist: $0.artist) } })
        var byId = recMembershipCache?.revision == membershipRevision
            ? (recMembershipCache?.byId ?? [:]) : [:]
        byId[id] = m
        recMembershipCache = (membershipRevision, byId)
        return m
    }

    /// **THE READ-TIME HALF OF "never suggest what is already in here."**
    ///
    /// The suggestion lists are frozen by the owner's cache rule and only recomputed on an explicit
    /// Refresh, but membership moves on every add — including the adds made from those very lists.
    /// So the build-time filter in `ZoneEngine.suggestions` is necessary and NOT sufficient: without
    /// this, a song thumbed-up into the collection keeps being counted on its tile and keeps being
    /// offered after a relaunch, until the next scheduled refresh.
    ///
    /// Cheap enough to be unconditional: a set lookup per row over a list of ~25, against a memo
    /// that only rebuilds when the collection actually changes.
    func suggestionsExcludingMembers(_ suggestionIds: [String], ofCollection id: String) -> [String] {
        let m = recMembership(forCollection: id)
        guard !m.isEmpty else { return suggestionIds }
        let songs = app?.songsById
        return m.excluding(suggestionIds,
                           appleMusicId: { songs?[$0]?.appleMusicId },
                           titleArtist: { songs?[$0].map { (title: $0.name, artist: $0.artist) } })
    }

    private func save() {
        // Every mutator funnels through here, so this is the one honest memo key.
        membershipRevision &+= 1
        // ENCODE + WRITE OFF THE MAIN THREAD. This used to JSONEncode the whole document and
        // write it synchronously right here — O(document) on the main actor for EVERY mutation.
        // Play/Shuffle on a large source playlist upserts a Now Playing setlist holding the
        // entire list (26,821 tracks for "Favorite Songs"), so that single line was the visible
        // multi-second stall behind the ▶. The document is snapshotted here (cheap COW copies of
        // value types), then encoded and written inside a version-ordered actor: writes land in
        // version order regardless of task scheduling, and a newer version already on disk drops
        // a stale straggler. Durability at suspension is covered by `flushDocumentNow()` on the
        // scenePhase-background seam, same doctrine as PlaybackSessionStore.flush().
        let doc = CollectionsDocument(schemaVersion: collectionsSchemaVersion, pockets: pockets,
                                      playlists: playlists, setlists: setlists,
                                      folders: folders, lastAddTarget: lastAddTarget,
                                      recentAddTargets: recentAddTargets.isEmpty ? nil : recentAddTargets)
        saveVersion &+= 1
        let v = saveVersion, url = fileURL, w = writer
        Task.detached(priority: .userInitiated) { await w.write(doc, version: v, to: url) }
        onChange?()
    }

    /// Synchronous last-chance write for the suspension seam (scenePhase `.background`) and the
    /// tests' reload round-trips: the async writer's in-flight encode dies with the process, so
    /// the freshest document must be on disk BEFORE iOS may kill us.
    ///
    /// ORDER MATTERS: the version mark must land in the actor BEFORE the inline write, and the
    /// wait guarantees it. The actor serializes, so by the time `invalidate(through: v)` has
    /// executed, every straggler save that arrived earlier has already written (and our inline
    /// write below then supersedes it on disk), and every straggler that arrives later is
    /// version-dropped. Writing first and marking after left a window where an older queued
    /// save landed on top of the flushed file — the reload tests caught exactly that.
    func flushDocumentNow() {
        let doc = CollectionsDocument(schemaVersion: collectionsSchemaVersion, pockets: pockets,
                                      playlists: playlists, setlists: setlists,
                                      folders: folders, lastAddTarget: lastAddTarget,
                                      recentAddTargets: recentAddTargets.isEmpty ? nil : recentAddTargets)
        saveVersion &+= 1
        let v = saveVersion, url = fileURL, w = writer
        let barrier = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await w.invalidate(through: v)
            barrier.signal()
        }
        // Bounded block of the caller (the actor runs on the cooperative pool, never on this
        // thread, so this cannot deadlock; the timeout is a belt against a wedged executor).
        _ = barrier.wait(timeout: .now() + 5)
        if let data = try? CollectionsCodec.encode(doc) { try? data.write(to: url, options: .atomic) }
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
        recentAddTargets = doc.recentAddTargets ?? []
        setlists.removeAll { $0.id == nowPlayingSetlistId || $0.playlistId == nowPlayingPlaylistId }
        membershipRevision &+= 1
        // The file now holds cloud-pulled content newer than anything the async writer may still
        // have queued — invalidate those stragglers so a pre-pull save can't overwrite the pull.
        saveVersion &+= 1
        let v = saveVersion, w = writer
        Task.detached { await w.invalidate(through: v) }
        onChange?()
    }

    /// FULL WIPE: reset every collection family (pockets, playlists, setlists, folders,
    /// and the remembered add target) to empty AND delete the on-disk document, so the
    /// UI updates immediately and a relaunch decodes nothing. Inverse of init's decode:
    /// where `save()` writes the doc, this removes it (`try?` swallows a missing file,
    /// same as `launchURL()`), then fires `onChange` so Spotlight/Siri drop the vocabulary.
    func clear() {
        pockets = []
        playlists = []
        setlists = []
        folders = []
        lastAddTarget = nil
        recentAddTargets = []
        membershipRevision &+= 1
        // Version-ordered like save(): a queued async write of the PRE-wipe document must not
        // resurrect the file after this delete, so the delete goes through the same writer.
        saveVersion &+= 1
        let v = saveVersion, url = fileURL, w = writer
        Task.detached(priority: .userInitiated) { await w.delete(version: v, at: url) }
        onChange?()
    }
}

// ============================================================================
// MARK: - Background document writer (encode + write off the main actor)
// ============================================================================

/// Serialized, VERSION-ORDERED writer for the collections document. Both the JSON encode and
/// the disk write happen inside the actor — off the main actor — because the encode is the
/// expensive half: a document holding a large Now Playing setlist encodes megabytes of track
/// snapshots, which used to run synchronously inside every `save()`.
///
/// Version ordering (not arrival ordering) is the correctness rule: unstructured Tasks may reach
/// the actor out of submission order, so each operation carries the store's monotonic
/// `saveVersion` and anything at-or-below the high-water mark is dropped. `invalidate(through:)`
/// raises the mark without touching the file — used after a synchronous flush or a cloud pull
/// made the on-disk content newer than every queued write.
actor CollectionsDocumentWriter {
    private var latest = 0

    func write(_ doc: CollectionsDocument, version: Int, to url: URL) {
        guard version > latest else { return }
        latest = version
        guard let data = try? CollectionsCodec.encode(doc) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func delete(version: Int, at url: URL) {
        guard version > latest else { return }
        latest = version
        try? FileManager.default.removeItem(at: url)
    }

    func invalidate(through version: Int) {
        latest = max(latest, version)
    }
}
