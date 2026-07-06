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
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var newPocket = ""
    @State private var newPlaylist = ""

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
                            Text(title).foregroundStyle(Theme.fg)
                            Spacer()
                            Text(studioKindLabel).font(.caption).foregroundStyle(Theme.fgDim)
                        }
                    } header: { Text("Adding") }
                }

                if let last = collections.lastAddTarget, let label = collections.lastTargetLabel(last) {
                    Section("Last used") {
                        Button { addTo(last); dismiss() } label: {
                            HStack {
                                Image(systemName: last.kind == .pocket ? "rectangle.stack" : "music.note.list")
                                    .foregroundStyle(Theme.accent2)
                                Text(label).foregroundStyle(Theme.fg)
                                Spacer()
                                Image(systemName: "arrow.uturn.left").foregroundStyle(Theme.fgDim)
                            }
                        }
                        .accessibilityIdentifier("add-last")
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
            }
            .navigationTitle("Add to…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 520)
            #endif
        }
    }

    /// Adds the item and records the target (incl. chapter) as "last used".
    private func addTo(_ target: AddTarget) {
        switch item {
        case .song(let s): collections.addSong(s, to: target)
        case .album(let a): collections.addAlbum(a, to: target)
        // Studio ids ride the SAME string-id plumbing as songs (spec §8's namespaced-id
        // mechanism): pockets keep them in `songIds`, playlists as `.song` nodes; every
        // consumer routes on the id prefix at resolve time.
        case .studio(let id, _): collections.addSong(id, to: target)
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
        return "Sample"
    }

    /// The sub-tab's SF symbol per kind (spec §1: waveform / repeat / grid).
    private var studioIcon: String {
        guard case .studio(let id, _) = item else { return "waveform" }
        if id.hasPrefix("lp_") { return "repeat" }
        if id.hasPrefix("ptn_") { return "square.grid.4x3.fill" }
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
