import SwiftUI

/// The FROZEN, read-only performance produced by ▶ Play. "Spin these tracks, in this
/// order." Each track carries its own snapshot (artist/name/bpm/camelot/length) so it
/// reads standalone even if the catalog or pockets change. Mirrors the PWA's
/// `SetlistView.tsx`: grouped-by-chapter sections, a provenance badge per track, and
/// per-track performer notes.
struct SetlistDetailView: View {
    @Environment(CollectionsStore.self) private var collections
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let setlistId: String

    @State private var nameDraft = ""
    @State private var renaming = false
    @State private var noteEditing: Int?      // track index being edited
    @State private var noteDraft = ""
    @State private var addingNote = false      // top-level "Add note" composer
    @State private var addNoteDraft = ""

    private var setlist: Setlist? { collections.setlist(setlistId) }

    var body: some View {
        Group {
            if let setlist {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Spin these tracks, in this order.")
                                .font(.caption).foregroundStyle(Theme.fgDim)
                            HStack(spacing: 14) {
                                stat(Fmt.duration(setlist.totalMs), "total")
                                stat("\(setlist.tracks.count)", setlist.tracks.count == 1 ? "track" : "tracks")
                                if setlist.generatedAt > 0 {
                                    Text(Date(timeIntervalSince1970: setlist.generatedAt / 1000),
                                         style: .date)
                                        .font(.caption2).foregroundStyle(Theme.fgDim)
                                }
                            }
                            .accessibilityIdentifier("setlist-stats")
                        }
                    }

                    Section {
                        ForEach(Array(setlist.tracks.enumerated()), id: \.offset) { idx, track in
                            trackRow(track, index: idx)
                        }
                        .onMove { from, to in collections.moveSetlistTracks(setlistId: setlistId, from: from, to: to) }
                        .onDelete { offsets in
                            // Remove highest-index first so earlier offsets stay valid.
                            offsets.sorted(by: >).forEach { collections.removeSetlistTrack(setlistId: setlistId, at: $0) }
                        }
                    } header: {
                        chapterLegend(setlist.tracks)
                    }
                }
                .navigationTitle(setlist.name ?? "Set list")
                #if os(iOS)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton().accessibilityIdentifier("setlist-edit-order") } }
                #endif
            } else {
                ContentUnavailableView("Set list gone", systemImage: "waveform.slash",
                                       description: Text("This set list no longer exists."))
            }
        }
        .accessibilityIdentifier("setlist-detail")
        .background(Theme.bg)
        .toolbar {
            if let setlist {
                ToolbarItem(placement: .primaryAction) {
                    Button { addNoteDraft = ""; addingNote = true } label: { Image(systemName: "text.badge.plus") }
                        .help("Add a note between tracks")
                        .accessibilityIdentifier("setlist-add-note")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { nameDraft = setlist.name ?? ""; renaming = true } label: { Image(systemName: "pencil") }
                        .accessibilityIdentifier("setlist-rename")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        collections.deleteSetlist(setlist.id); dismiss()
                    } label: { Image(systemName: "trash") }
                        .accessibilityIdentifier("setlist-delete")
                }
            }
        }
        .alert("Add note", isPresented: $addingNote) {
            TextField("Note (mic break, sample, cue…)", text: $addNoteDraft)
            Button("Add") {
                let n = addNoteDraft.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { collections.addSetlistNote(n, toSetlist: setlistId) }
                addNoteDraft = ""
            }
            Button("Cancel", role: .cancel) { addNoteDraft = "" }
        } message: {
            Text("Added to the end — drag it into place with Edit.")
        }
        .alert("Rename set list", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { let n = nameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renameSetlist(setlistId, n) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Track note", isPresented: Binding(get: { noteEditing != nil }, set: { if !$0 { noteEditing = nil } })) {
            TextField("Performer note…", text: $noteDraft)
            Button("Save") {
                if let i = noteEditing {
                    let n = noteDraft.trimmingCharacters(in: .whitespaces)
                    collections.setSetlistTrackNote(setlistId, trackIndex: i, note: n.isEmpty ? nil : n)
                }
                noteEditing = nil
            }
            Button("Clear", role: .destructive) {
                if let i = noteEditing { collections.setSetlistTrackNote(setlistId, trackIndex: i, note: nil) }
                noteEditing = nil
            }
            Button("Cancel", role: .cancel) { noteEditing = nil }
        }
    }

    /// The album behind a frozen track, for its cover-art thumbnail — resolved from
    /// the live catalog by the snapshot's songId (nil if the song is gone, so the row
    /// still reads from the snapshot with a graceful placeholder).
    private func album(for track: SetlistTrack) -> IndexAlbum? {
        app.songsById[track.songId]?.albumId.flatMap { app.albumsById[$0] }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
            Text(label).font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    @ViewBuilder
    private func trackRow(_ track: SetlistTrack, index: Int) -> some View {
        if track.isText == true {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim).frame(width: 22, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Badge("cue", color: Theme.fgDim)
                        Text(track.name).foregroundStyle(Theme.fg).italic()
                    }
                    noteButton(track, index: index)
                }
            }
            .accessibilityIdentifier("setlist-track-\(index)")
        } else {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim).frame(width: 22, alignment: .trailing)
                SongThumbnail(album: album(for: track)).frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(track.artist) — \(track.name)").foregroundStyle(Theme.fg).lineLimit(2)
                    HStack(spacing: 6) {
                        if let bpm = track.bpm, bpm > 0 { Badge("\(Int(bpm.rounded())) BPM", color: Theme.accent) }
                        if let cam = track.camelot, !cam.isEmpty { KeyChip(key: nil, camelot: cam) }
                        sourceBadge(track.source)
                        if let seq = track.sequenceName, !seq.isEmpty { Badge(seq, color: Theme.fgDim) }
                    }
                    noteButton(track, index: index)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Fmt.duration(track.shownMs)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    TransportPlaceholders(songId: track.songId.isEmpty ? track.id : track.songId)
                }
            }
            .accessibilityIdentifier("setlist-track-\(index)")
        }
    }

    @ViewBuilder
    private func noteButton(_ track: SetlistTrack, index: Int) -> some View {
        Button {
            noteDraft = track.note ?? ""
            noteEditing = index
        } label: {
            Text(track.note.map { "📝 \($0)" } ?? "＋ note")
                .font(.caption2).foregroundStyle(track.note == nil ? Theme.fgDim : Theme.accent2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setlist-note-\(index)")
    }

    private func sourceBadge(_ source: TrackSource) -> some View {
        switch source {
        case .explicit: return Badge("explicit", color: Theme.fgDim)
        case .pocket:   return Badge("pocket", color: Theme.accent2)
        case .autofill: return Badge("↔ bridge", color: Theme.accent)
        }
    }

    // MARK: Chapter legend

    /// A single flat, reorderable track list (so `.onMove`/`.onDelete` indices map
    /// straight to `setlist.tracks`). The per-row `sequenceName` badge still names each
    /// track's chapter; this header summarizes which chapters are present + the total.
    @ViewBuilder
    private func chapterLegend(_ tracks: [SetlistTrack]) -> some View {
        let names = orderedChapterNames(tracks)
        HStack {
            Text(names.count <= 1 ? (names.first ?? "Set") : names.joined(separator: " · "))
            Spacer()
            Text("\(tracks.count) · \(Fmt.duration(tracks.reduce(0) { $0 + $1.shownMs }))")
                .foregroundStyle(Theme.fgDim)
        }
        .accessibilityIdentifier("setlist-chapter-legend")
    }

    private func orderedChapterNames(_ tracks: [SetlistTrack]) -> [String] {
        var out: [String] = []
        for t in tracks {
            let name = t.sequenceName?.isEmpty == false ? t.sequenceName! : "Set"
            if out.last != name && !out.contains(name) { out.append(name) }
        }
        return out
    }
}

/// A tiny pill chip matching the PWA's `pdj-badge`.
private struct Badge: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
