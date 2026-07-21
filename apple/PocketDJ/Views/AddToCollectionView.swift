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
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var newPocket = ""
    @State private var newPlaylist = ""
    /// Total plays for a performance item before the collection advances (spec: repeat count).
    /// Studio items only; 1 = normal single play. Applied to whichever target is tapped.
    @State private var repeatCount = 1
    /// What an "add to a source playlist" tap actually did. Non-nil ⇒ the result alert is up.
    /// Unlike the pocket/playlist rows (which just dismiss), this path silently CREATES a
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
                            Button { addTo(target); dismiss() } label: {
                                HStack {
                                    Image(systemName: target.kind == .pocket ? "rectangle.stack" : "music.note.list")
                                        .foregroundStyle(Theme.accent2)
                                    Text(collections.lastTargetLabel(target) ?? "").foregroundStyle(Theme.fg)
                                    Spacer()
                                    Image(systemName: "arrow.uturn.left").foregroundStyle(Theme.fgDim)
                                }
                            }
                            .accessibilityIdentifier("recent-add-\(idx)")
                        }
                    }
                }

                Section("Pockets") {
                    ForEach(collections.pockets) { pocket in
                        Button { addTo(AddTarget(kind: .pocket, id: pocket.id)); dismiss() } label: {
                            HStack {
                                Label(pocket.name, systemImage: "rectangle.stack")
                                Spacer()
                                if inPocket(pocket) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                    newRow("New pocket", text: $newPocket) { name in
                        let p = collections.createPocket(name)
                        addTo(AddTarget(kind: .pocket, id: p.id)); dismiss()
                    }
                }

                Section {
                    ForEach(collections.playlists) { pl in
                        // Tapping the playlist always lands in its default chapter
                        // (sequences[0]) — no need to pick. Extra chapters are offered
                        // below for when you do want a specific one.
                        Button {
                            addTo(AddTarget(kind: .playlist, id: pl.id, sequenceId: pl.sequences.first?.nodeId)); dismiss()
                        } label: { Label(pl.name, systemImage: "music.note.list") }
                        if pl.sequences.count > 1 {
                            ForEach(pl.sequences) { seq in
                                Button {
                                    addTo(AddTarget(kind: .playlist, id: pl.id, sequenceId: seq.nodeId)); dismiss()
                                } label: {
                                    Label(seq.name ?? "Chapter", systemImage: "chevron.right")
                                        .font(.caption).foregroundStyle(Theme.fgDim).padding(.leading, 20)
                                }
                            }
                        }
                    }
                    newRow("New playlist", text: $newPlaylist) { name in
                        let p = collections.createPlaylist(name)
                        addTo(AddTarget(kind: .playlist, id: p.id, sequenceId: p.sequences.first?.nodeId)); dismiss()
                    }
                } header: {
                    Text("Playlists")
                } footer: {
                    Text("Tapping a playlist adds to its default chapter.")
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
                   presenting: sourceResult) { _ in
                Button("Done") { sourceResult = nil; dismiss() }
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
        let hasAppleMusicId = !(songId.flatMap { app.songsById[$0]?.appleMusicId } ?? "").isEmpty
        if !hasAppleMusicId {
            // Vinyl / My Digital / Studio: no Apple Music identity to write back.
            return base + " This song isn’t from Apple Music, so the add stays on this device."
        }
        if writeBack?.canWriteBack == true {
            return base + " For Apple Music lists it’s also added to the real playlist in your Apple Music library."
        }
        return base + " Apple Music playlists can’t be edited from this device, so the add stays on this device."
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
                if writeBack.enqueue(indexPlaylistId: source.id, playlistName: source.name,
                                     songId: sid, appleMusicId: result.appleMusicId) != nil {
                    lines.append("It’s also being added to “\(source.name)” in your Apple Music library.")
                } else {
                    lines.append("It’s already on its way to “\(source.name)” in your Apple Music library.")
                }
                writeBack.runSoon()
            } else {
                lines.append("Apple Music playlists can’t be edited from this device, so this add stays on this device.")
            }
        } else if PlaylistWriteBack.isAppleMusicSource(source.sourceName) {
            // Apple Music list, but a vinyl / My Digital / Studio song — no store id exists.
            lines.append("“\(songTitle)” isn’t an Apple Music track, so it stays in your copy only.")
        }

        sourceResult = SourceAddResult(title: result.alreadyPresent ? "Already there" : "Added",
                                       message: lines.joined(separator: "\n\n"))
    }

    private var sourceResultShowing: Binding<Bool> {
        Binding(get: { sourceResult != nil }, set: { if !$0 { sourceResult = nil } })
    }

    /// The result alert's payload (`.alert(presenting:)` wants an Identifiable-ish value).
    private struct SourceAddResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String
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
