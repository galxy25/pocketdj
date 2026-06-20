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

                    ForEach(sections(setlist.tracks), id: \.name) { section in
                        Section {
                            ForEach(section.rows, id: \.index) { row in
                                trackRow(row.track, index: row.index)
                            }
                        } header: {
                            HStack {
                                Text(section.name)
                                Spacer()
                                Text("\(section.rows.count) · \(Fmt.duration(section.ms))")
                                    .foregroundStyle(Theme.fgDim)
                            }
                        }
                    }
                }
                .navigationTitle(setlist.name ?? "Set list")
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

    // MARK: Group by sequence (chapter), mirroring the PWA's groupBySequence

    private struct Row { let track: SetlistTrack; let index: Int }
    private struct SectionGroup { let name: String; var ms: Int; var rows: [Row] }

    private func sections(_ tracks: [SetlistTrack]) -> [SectionGroup] {
        var out: [SectionGroup] = []
        for (i, t) in tracks.enumerated() {
            let name = t.sequenceName?.isEmpty == false ? t.sequenceName! : "Set"
            if out.last?.name != name { out.append(SectionGroup(name: name, ms: 0, rows: [])) }
            out[out.count - 1].rows.append(Row(track: t, index: i))
            if t.isText != true { out[out.count - 1].ms += t.shownMs }
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
