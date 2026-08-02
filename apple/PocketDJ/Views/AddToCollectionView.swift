import SwiftUI

/// Sheet to add a song, album, or STUDIO item (sample/loop/pattern — spec §8) to a
/// pocket or playlist (or a new one). Remembers the last target — including the
/// playlist chapter — and surfaces it first, so building up a collection is just
/// "Add to…" then tap the remembered target.
struct AddToCollectionView: View {
    /// `.studio` carries the item's TITLE alongside its `smp_`/`lp_`/`ptn_` id because
    /// this sheet is presented from Studio list rows with no detail screen behind it
    /// (unlike songs/albums) — the header below names what's being added.
    enum Item: Hashable { case song(String), album(String), studio(id: String, title: String) }

    @Environment(CollectionsStore.self) private var collections
    @Environment(AppModel.self) private var app
    /// OPTIONAL on purpose: the write-back queue is a launch-wired app store, and this sheet
    /// is also driven by previews/tests that don't build the whole graph. nil ⇒ the Apple
    /// Music half is simply unavailable and the sheet says the add stays on this device.
    @Environment(PlaylistWriteBack.self) private var writeBack: PlaylistWriteBack?
    /// Optional for the same reason `writeBack` is: always injected by the app, but a preview or a
    /// test host that renders the picker standalone should degrade, not trap.
    @Environment(PlaylistAppleMusicSync.self) private var playlistSync: PlaylistAppleMusicSync?
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var newPocket = ""
    @State private var newPlaylist = ""
    /// Total plays for a performance item before the collection advances (spec: repeat count).
    /// Studio items only; 1 = normal single play. Applied to whichever target is tapped.
    @State private var repeatCount = 1
    /// What an "add to a source playlist" tap actually did. Non-nil ⇒ the result alert is up.
    /// Like the pocket/playlist rows, this path does NOT dismiss the picker (you stay to keep
    /// adding); the alert exists because adding to a shared source silently CREATES a local
    /// playlist and may write to the user's Apple Music library — it has to say so.
    @State private var sourceResult: SourceAddResult?

    private var isStudio: Bool { if case .studio = item { return true }; return false }

    /// The Recent quick-add targets: the store's MRU, filtered to those that STILL RESOLVE
    /// (`lastTargetLabel != nil` ⇒ the pocket/playlist still exists), capped at the top 3. The
    /// store keeps a deeper buffer so a deleted collection dropping out still fills the row.
    private var recentTargets: [AddTarget] {
        Array(collections.recentAddTargets.filter { collections.lastTargetLabel($0) != nil }.prefix(3))
    }

    /// The song id being added, or nil for albums / studio items. Source-playlist adds are
    /// song-only: an album has no single Apple Music track to write back, and a studio
    /// sample has no Apple Music identity at all.
    private var songId: String? { if case .song(let s) = item { return s }; return nil }
    private var songTitle: String { songId.flatMap { app.songsById[$0]?.name } ?? "This song" }
    /// Source ("From your sources") playlists, name-ordered.
    private var sourcePlaylists: [SourcePlaylist] {
        app.indexPlaylists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// Your pockets + playlists, sorted alphabetically by default (the raw stored arrays are in
    /// arbitrary insertion order — a quick-add picker should list them A–Z so you can scan by name,
    /// matching the "From your sources" section below and the app's `localizedCaseInsensitiveCompare`
    /// collection convention).
    private var sortedPockets: [Pocket] {
        collections.pockets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var sortedPlaylists: [Playlist] {
        collections.playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                // WHAT is being added — shown only for studio items: a sample/loop/
                // sequence row has no backing detail screen naming it behind this
                // sheet, so the sheet itself says so. Songs/albums keep the sheet
                // exactly as it was (their detail screen is right behind it).
                if case .studio(_, let title) = item {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: studioIcon).foregroundStyle(Theme.accent2)
                            Text(title.isEmpty ? "Untitled \(studioKindLabel.lowercased())" : title)
                                .foregroundStyle(Theme.fg)
                            Spacer()
                            Text(studioKindLabel).font(.caption).foregroundStyle(Theme.fgDim)
                        }
                        Stepper(value: $repeatCount, in: 1...CollectionMembership.maxRepeat) {
                            HStack {
                                Text("Plays")
                                Spacer()
                                Text(repeatCount == 1 ? "once" : "\(repeatCount)×")
                                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.fgDim)
                            }
                        }
                        .accessibilityIdentifier("add-repeat-stepper")
                    } header: {
                        Text("Adding")
                    } footer: {
                        Text("How many times this \(studioKindLabel.lowercased()) plays before the collection moves on.")
                    }
                }

                // RECENT quick-add (F11): the last few collections you added to, most-recent
                // first — one tap re-adds. Supersedes the single "Last used" row. Filtered to
                // targets that still RESOLVE (a deleted collection drops out) and capped at 3.
                if !recentTargets.isEmpty {
                    Section("Recent") {
                        ForEach(Array(recentTargets.enumerated()), id: \.offset) { idx, target in
                            Button { toggleTarget(target) } label: {
                                HStack {
                                    Image(systemName: target.kind == .pocket ? "rectangle.stack" : "music.note.list")
                                        .foregroundStyle(Theme.accent2)
                                    Text(collections.lastTargetLabel(target) ?? "").foregroundStyle(Theme.fg)
                                    Spacer()
                                    // Member ⇒ checkmark (tap removes); not ⇒ the re-add arrow (tap adds).
                                    Image(systemName: isMember(target) ? "checkmark" : "arrow.uturn.left")
                                        .foregroundStyle(isMember(target) ? Theme.accent : Theme.fgDim)
                                }
                            }
                            .accessibilityIdentifier("recent-add-\(idx)")
                        }
                    }
                }

                Section {
                    ForEach(sortedPockets) { pocket in
                        Button { togglePocket(pocket) } label: {
                            HStack {
                                Label(pocket.name, systemImage: "rectangle.stack")
                                Spacer()
                                if inPocket(pocket) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                        .accessibilityIdentifier("add-pocket-\(pocket.id)")
                    }
                    newRow("New pocket", text: $newPocket) { name in
                        let p = collections.createPocket(name)
                        addTo(AddTarget(kind: .pocket, id: p.id))
                    }
                } header: {
                    Text("Pockets")
                } footer: {
                    Text("Tap to add or remove — an item can live in several.")
                }

                Section {
                    ForEach(sortedPlaylists) { pl in
                        // Tap toggles WHOLE-playlist membership: add lands in the default chapter
                        // (sequences[0]), remove clears the item from every chapter. The per-chapter
                        // rows below add to a specific chapter when you want one.
                        Button { togglePlaylist(pl) } label: {
                            HStack {
                                Label(pl.name, systemImage: "music.note.list")
                                Spacer()
                                if inPlaylist(pl) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                        .accessibilityIdentifier("add-playlist-\(pl.id)")
                        if pl.sequences.count > 1 {
                            ForEach(pl.sequences) { seq in
                                Button {
                                    addTo(AddTarget(kind: .playlist, id: pl.id, sequenceId: seq.nodeId))
                                } label: {
                                    Label(seq.name ?? "Chapter", systemImage: "chevron.right")
                                        .font(.caption).foregroundStyle(Theme.fgDim).padding(.leading, 20)
                                }
                            }
                        }
                    }
                    newRow("New playlist", text: $newPlaylist) { name in
                        let p = collections.createPlaylist(name)
                        addTo(AddTarget(kind: .playlist, id: p.id, sequenceId: p.sequences.first?.nodeId))
                    }
                } header: {
                    Text("Playlists")
                } footer: {
                    Text("Tap to add or remove. Chapters add to a specific one.")
                }

                sourcePlaylistsSection
            }
            .navigationTitle("Add to…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 520)
            #endif
            .alert(sourceResult?.title ?? "", isPresented: sourceResultShowing,
                   presenting: sourceResult) { result in
                sourceAlertActions(result)
            } message: { result in
                Text(result.message)
            }
        }
    }

    // MARK: - Source ("From your sources") playlists — the two-way add

    /// Apple Music (and other source) playlists as add TARGETS. They're read-only lists in
    /// the catalog, so an add can't land in them directly: it lands in the on-device
    /// duplicate (found or created by `CollectionsStore.duplicateForSource`), and — for an
    /// Apple Music source playlist plus a song that has an Apple Music id — a write-back job
    /// carries it up to the real library playlist too.
    ///
    /// Song-only, and hidden entirely when the catalog carries no source playlists.
    @ViewBuilder
    private var sourcePlaylistsSection: some View {
        if songId != nil, !sourcePlaylists.isEmpty {
            Section {
                ForEach(sourcePlaylists) { source in
                    Button { addToSource(source) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "music.note.list").foregroundStyle(Theme.accent2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).foregroundStyle(Theme.fg)
                                // Say BEFORE the tap whether this makes a new local playlist —
                                // silently minting one would be a surprise.
                                Text(sourceRowSubtitle(source))
                                    .font(.caption2).foregroundStyle(Theme.fgDim)
                            }
                            Spacer()
                            if alreadyIn(source) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .accessibilityIdentifier("add-source-\(source.id)")
                }
            } header: {
                Text("From your sources")
            } footer: {
                Text(sourceSectionFooter)
            }
        }
    }

    /// "Apple Music (Local) · adds to your local copy" / "· makes a local copy".
    private func sourceRowSubtitle(_ source: SourcePlaylist) -> String {
        let has = collections.existingDuplicate(forSource: source) != nil
        return "\(source.sourceName) · \(has ? "adds to your local copy" : "makes a local copy")"
    }

    /// The honest, up-front statement of what tapping a row does. Three cases the user can
    /// actually be in, and the footer names whichever one applies to THIS song.
    private var sourceSectionFooter: String {
        let base = "These lists are read-only, so PocketDJ keeps an editable copy on this device and adds the song there."
        if writeBack?.canWriteBack == true {
            // Whether or not the indexer resolved a store id, an Apple Music list add tries to reach
            // the real playlist — resolving the song on-device when it's on Apple Music, and staying
            // local when it isn't (so no promise is made that an off-catalog track will sync).
            return base + " For Apple Music lists, if the song is on Apple Music it’s also added to the real playlist in your Apple Music library."
        }
        // This device can't write to Apple Music DIRECTLY (macOS: MusicLibrary's write methods are
        // @available(macOS, unavailable)) — but the add does NOT stay here. The Apple Music sync's
        // push step has no platform gate, so the local copy goes up at the next sync, which the
        // daily automatic pass runs on this device too. Saying "stays on this device" was simply
        // false, and it is the kind of false that makes someone add the song twice.
        return base + " This device can’t send it to Apple Music the moment you tap, but it goes up at the next Apple Music sync — or use Sync now."
    }

    /// Already a member of the source list itself, or of the on-device duplicate.
    private func alreadyIn(_ source: SourcePlaylist) -> Bool {
        guard let sid = songId else { return false }
        if source.songIds.contains(sid) { return true }
        guard let pl = collections.existingDuplicate(forSource: source) else { return false }
        return collections.playlist(pl.id, contains: sid)
    }

    /// Perform the two-way add and compose the result the alert reports.
    private func addToSource(_ source: SourcePlaylist) {
        guard let sid = songId else { return }
        // True when the add is real but this device can't deliver it instantly — the alert then
        // offers to run the sync on the spot instead of leaving the user to wait for the daily pass.
        var queuedForSync = false
        let amId = app.songsById[sid]?.appleMusicId
        let result = collections.addSong(sid, toIndexPlaylist: source, appleMusicId: amId)

        var lines: [String] = []
        if result.alreadyPresent {
            lines.append("“\(songTitle)” was already in your copy of “\(source.name)”.")
        } else if result.createdDuplicate {
            lines.append("PocketDJ made an editable copy of “\(source.name)” on this device and added “\(songTitle)” to it. The copy keeps following the original.")
        } else {
            lines.append("Added “\(songTitle)” to your editable copy of “\(source.name)”.")
        }

        if result.writeBackEligible {
            // The source snapshot IS Apple Music's membership as of the last catalog
            // refresh. If the song is already in it, Apple Music already has it — queueing
            // a write would add a SECOND copy of the track to the real playlist.
            if source.songIds.contains(sid) {
                lines.append("Your Apple Music library playlist already has it.")
            } else if let writeBack, writeBack.canWriteBack {
                // Pass the carried identity so the queue can resolve a store id ON-DEVICE when the
                // indexer never minted one (`result.appleMusicId == nil`) — the "Running It Up" case.
                if writeBack.enqueue(indexPlaylistId: source.id, playlistName: source.name,
                                     songId: sid, appleMusicId: result.appleMusicId,
                                     title: result.title, artist: result.artist,
                                     album: result.album, durationMs: result.durationMs) != nil {
                    lines.append("It’s also being added to “\(source.name)” in your Apple Music library.")
                } else {
                    lines.append("It’s already on its way to “\(source.name)” in your Apple Music library.")
                }
                writeBack.runSoon()
            } else {
                lines.append("This device can’t add to Apple Music instantly, so it’s queued for the next Apple Music sync.")
                queuedForSync = true
            }
        } else if PlaylistWriteBack.isAppleMusicSource(source.sourceName) {
            // Apple Music list, but the song has no Apple Music identity at all (no store id and no
            // title+artist) — nothing to resolve, so it stays in the local copy only.
            lines.append("“\(songTitle)” can’t be matched to Apple Music, so it stays in your copy only.")
        }

        sourceResult = SourceAddResult(title: result.alreadyPresent ? "Already there" : "Added",
                                       message: lines.joined(separator: "\n\n"),
                                       queuedForSync: queuedForSync)
    }

    /// Extracted from the `.alert` closure: inlined, it pushed that view body past the Swift
    /// type-checker's budget ("unable to type-check this expression in reasonable time").
    @ViewBuilder
    private func sourceAlertActions(_ result: SourceAddResult) -> some View {
        // Acknowledge the "made a local copy" notice but STAY on the picker (don't dismiss back to
        // song detail) — the source playlist is now in your collections, so you can keep adding
        // elsewhere; the toolbar "Done" closes the picker when you're finished.
        Button("Done") { sourceResult = nil }
        // On a device that can't deliver the add itself, don't make the user hunt for the sync in
        // Settings — offer it right where the wait is announced.
        if result.queuedForSync, let playlistSync, !playlistSync.isSyncing {
            Button("Sync now") {
                sourceResult = nil
                // PUSH only: the user is waiting on THIS add reaching Apple Music, and a full
                // two-way pass would also pull the whole library — minutes, for no benefit here.
                Task { await playlistSync.syncNow(collections: collections, app: app, direction: .push) }
            }
        }
    }

    private var sourceResultShowing: Binding<Bool> {
        Binding(get: { sourceResult != nil }, set: { if !$0 { sourceResult = nil } })
    }

    /// The result alert's payload (`.alert(presenting:)` wants an Identifiable-ish value).
    private struct SourceAddResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// The add is waiting on an Apple Music sync ⇒ the alert offers to run one now.
        var queuedForSync = false
    }

    /// Adds the item and records the target (incl. chapter) as "last used".
    private func addTo(_ target: AddTarget) {
        switch item {
        case .song(let s): collections.addSong(s, to: target)
        case .album(let a): collections.addAlbum(a, to: target)
        // Studio ids ride the SAME string-id plumbing as songs (spec §8's namespaced-id
        // mechanism): pockets keep them in `songIds`, playlists as `.song` nodes; every
        // consumer routes on the id prefix at resolve time.
        case .studio(let id, _): collections.addSong(id, to: target, repeatCount: repeatCount)
        }
    }

    private func inPocket(_ p: Pocket) -> Bool {
        switch item {
        case .song(let s): return p.songIds.contains(s)
        case .album(let a): return p.albumIds.contains(a)
        case .studio(let id, _): return p.songIds.contains(id)   // rides songIds (see addTo)
        }
    }

    // MARK: - Multi-select toggle (add ⇄ remove across many collections, without dismissing)

    /// The song/studio id being toggled (studio ids ride the song plumbing — see `addTo`); nil
    /// for an album item.
    private var toggleSongId: String? {
        switch item { case .song(let s): return s; case .studio(let id, _): return id; case .album: return nil }
    }
    private var toggleAlbumId: String? { if case .album(let a) = item { return a }; return nil }

    /// Whole-playlist membership of the current item (present in ANY chapter).
    private func inPlaylist(_ pl: Playlist) -> Bool {
        if let s = toggleSongId { return collections.playlist(pl.id, contains: s) }
        if let a = toggleAlbumId { return collections.playlist(pl.id, containsAlbum: a) }
        return false
    }

    /// Tap a POCKET: add if absent, remove if present. Never dismisses (multi-select).
    private func togglePocket(_ p: Pocket) {
        if inPocket(p) { removeFromPocket(p.id) } else { addTo(AddTarget(kind: .pocket, id: p.id)) }
    }
    /// Tap a PLAYLIST: toggle whole-playlist membership — add lands in the default chapter, remove
    /// clears the item from EVERY chapter. Never dismisses.
    private func togglePlaylist(_ pl: Playlist) {
        if inPlaylist(pl) { removeFromPlaylist(pl.id) }
        else { addTo(AddTarget(kind: .playlist, id: pl.id, sequenceId: pl.sequences.first?.nodeId)) }
    }
    private func removeFromPocket(_ id: String) {
        if let s = toggleSongId { collections.removeSong(s, fromPocket: id) }
        else if let a = toggleAlbumId { collections.removeAlbum(a, fromPocket: id) }
    }
    private func removeFromPlaylist(_ id: String) {
        if let s = toggleSongId { collections.removeSong(s, fromPlaylist: id) }
        else if let a = toggleAlbumId { collections.removeAlbum(a, fromPlaylist: id) }
    }

    /// A Recent quick-target's current membership + its toggle (kind-dispatched).
    private func isMember(_ target: AddTarget) -> Bool {
        switch target.kind {
        case .pocket: return collections.pocket(target.id).map(inPocket) ?? false
        case .playlist: return collections.playlist(target.id).map(inPlaylist) ?? false
        }
    }
    private func toggleTarget(_ target: AddTarget) {
        guard isMember(target) else { addTo(target); return }
        switch target.kind {
        case .pocket: removeFromPocket(target.id)
        case .playlist: removeFromPlaylist(target.id)
        }
    }

    /// "Sample" / "Loop" / "Sequence" from the studio id's prefix — the id namespace IS
    /// the kind (no schema field carries it; spec §8), mirroring every other consumer.
    private var studioKindLabel: String {
        guard case .studio(let id, _) = item else { return "" }
        if id.hasPrefix("lp_") { return "Loop" }
        if id.hasPrefix("ptn_") { return "Sequence" }
        if id.hasPrefix("tk_") { return "Instrumental" }
        return "Sample"
    }

    /// The sub-tab's SF symbol per kind (spec §1: waveform / repeat / grid / instrumental).
    private var studioIcon: String {
        guard case .studio(let id, _) = item else { return "waveform" }
        if id.hasPrefix("lp_") { return "repeat" }
        if id.hasPrefix("ptn_") { return "square.grid.4x3.fill" }
        if id.hasPrefix("tk_") { return "pianokeys" }
        return "waveform"
    }

    private func newRow(_ placeholder: String, text: Binding<String>,
                        action: @escaping (String) -> Void) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .pocketField()
            Button("Add") {
                let n = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { action(n); text.wrappedValue = "" }
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// Identifiable box so a Studio list row can present `AddToCollectionView` for a studio item via
/// `.sheet(item:)` (the row has no detail screen behind it, so it carries the resolved title).
struct StudioAddRef: Identifiable, Hashable {
    let id: String       // the studio id (smp_/lp_/ptn_/tk_)
    let title: String
}

extension View {
    /// Attach an "Add to playlist or pocket…" context-menu entry + its sheet to a Studio row.
    /// `ref` is set by the button (captured id+title) and cleared on dismiss.
    func studioAddToCollection(_ ref: Binding<StudioAddRef?>) -> some View {
        sheet(item: ref) { r in
            AddToCollectionView(item: .studio(id: r.id, title: r.title))
        }
    }
}
