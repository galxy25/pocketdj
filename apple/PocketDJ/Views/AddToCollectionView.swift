import SwiftUI

/// Sheet to add a song or album to a pocket or playlist (or a new one). Remembers
/// the last target — including the playlist chapter — and surfaces it first, so
/// building up a collection is just "Add to…" then tap the remembered target.
struct AddToCollectionView: View {
    enum Item: Hashable { case song(String), album(String) }

    @Environment(CollectionsStore.self) private var collections
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var newPocket = ""
    @State private var newPlaylist = ""

    var body: some View {
        NavigationStack {
            List {
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
        }
    }

    private func inPocket(_ p: Pocket) -> Bool {
        switch item {
        case .song(let s): return p.songIds.contains(s)
        case .album(let a): return p.albumIds.contains(a)
        }
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
