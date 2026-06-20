import SwiftUI

/// Edit an album's audio-analysis segments (BPM / key / Camelot, and optionally
/// the segment start/end). Stores only the fields that DIFFER from the raw
/// (detected) album as a per-segment delta in the local EditsStore, then
/// re-applies the overlay so every view updates. Mirrors `EditAlbumView`.
struct EditAudioAnalysisView: View {
    @Environment(AppModel.self) private var app
    @Environment(EditsStore.self) private var edits
    @Environment(\.dismiss) private var dismiss
    let album: IndexAlbum

    /// One row's editable text fields, seeded from the (already-overlaid) album.
    private struct Row: Identifiable {
        let id: Int             // array index — stable for the lifetime of the sheet
        let trackNumber: Int?   // segment trackNumber (the overlay match key)
        var bpm: String
        var key: String
        var camelot: String
        var startMs: String
        var endMs: String
    }

    @State private var rows: [Row]

    init(album: IndexAlbum) {
        self.album = album
        _rows = State(initialValue: (album.audioTracks ?? []).enumerated().map { i, seg in
            Row(id: i,
                trackNumber: seg.trackNumber,
                bpm: seg.bpm.map { Fmt.trim($0) } ?? "",
                key: seg.key ?? "",
                camelot: seg.camelot ?? "",
                startMs: seg.startMs.map(String.init) ?? "",
                endMs: seg.endMs.map(String.init) ?? "")
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach($rows) { $row in
                    Section("Segment \(row.trackNumber ?? (row.id + 1))") {
                        EditField("BPM", text: $row.bpm, numeric: true)
                            .accessibilityIdentifier("audio-bpm-\(row.id)")
                        EditField("Key", text: $row.key)
                            .accessibilityIdentifier("audio-key-\(row.id)")
                        EditField("Camelot", text: $row.camelot)
                            .accessibilityIdentifier("audio-camelot-\(row.id)")
                        EditField("Start (ms)", text: $row.startMs, numeric: true)
                            .accessibilityIdentifier("audio-start-\(row.id)")
                        EditField("End (ms)", text: $row.endMs, numeric: true)
                            .accessibilityIdentifier("audio-end-\(row.id)")
                    }
                }
                if edits.albumEdit(album.id)?.audioTracks != nil {
                    Section {
                        Button("Reset audio analysis", role: .destructive) { reset() }
                            .accessibilityIdentifier("reset-audio-edit")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Audio Analysis")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.accessibilityIdentifier("save-audio-edit")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 480)
            #endif
        }
    }

    /// Build per-segment deltas against the RAW album's detected segments, keep
    /// any other album-edit fields, store, and re-overlay. An all-empty delta set
    /// clears the audio override entirely.
    private func save() {
        let raw = app.rawAlbum(album.id) ?? album
        let segs = raw.audioTracks ?? []
        var deltas: [AudioTrackEdit] = []
        for row in rows {
            let seg = row.id < segs.count ? segs[row.id] : nil
            var d = AudioTrackEdit()
            // Carry the trackNumber so the overlay can match this delta back even
            // if segment order ever shifts. (Not itself editable.)
            d.trackNumber = seg?.trackNumber ?? row.trackNumber
            d.bpm = EditDelta.double(row.bpm, seg?.bpm)
            d.key = EditDelta.optional(row.key, seg?.key)
            d.camelot = EditDelta.optional(row.camelot, seg?.camelot)
            d.startMs = EditDelta.int(row.startMs, seg?.startMs)
            d.endMs = EditDelta.int(row.endMs, seg?.endMs)
            deltas.append(d)
        }
        // A delta is meaningful only if it overrides something beyond trackNumber.
        let hasOverride = deltas.contains { !$0.isEmpty }

        var edit = edits.albumEdit(album.id) ?? AlbumEdit()
        edit.audioTracks = hasOverride ? deltas : nil
        edits.setAlbum(album.id, edit)
        app.applyEdits()
        dismiss()
    }

    /// Drop only the audio-analysis override, leaving other album edits intact.
    private func reset() {
        var edit = edits.albumEdit(album.id) ?? AlbumEdit()
        edit.audioTracks = nil
        edits.setAlbum(album.id, edit)
        app.applyEdits()
        dismiss()
    }
}
