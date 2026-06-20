import SwiftUI

/// Edit a song's metadata. Stores only changed fields (delta vs the original) in
/// the local EditsStore, then re-applies the overlay.
struct EditSongView: View {
    @Environment(AppModel.self) private var app
    @Environment(EditsStore.self) private var edits
    @Environment(\.dismiss) private var dismiss
    let song: IndexSong

    @State private var name: String
    @State private var artist: String
    @State private var yearText: String
    @State private var trackText: String
    @State private var bpmText: String
    @State private var key: String
    @State private var camelot: String
    @State private var explicit: Bool
    @State private var sentiment: String

    init(song: IndexSong) {
        self.song = song
        _name = State(initialValue: song.name)
        _artist = State(initialValue: song.artist)
        _yearText = State(initialValue: song.year.map(String.init) ?? "")
        _trackText = State(initialValue: song.trackNumber.map(String.init) ?? "")
        _bpmText = State(initialValue: song.bpm.map { Fmt.trim($0) } ?? "")
        _key = State(initialValue: song.key ?? "")
        _camelot = State(initialValue: song.camelot ?? "")
        _explicit = State(initialValue: song.explicit ?? false)
        _sentiment = State(initialValue: (song.sentimentKeywords ?? []).joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Song") {
                    EditField("Title", text: $name)
                    EditField("Artist", text: $artist)
                    EditField("Track #", text: $trackText, numeric: true)
                    EditField("Year", text: $yearText, numeric: true)
                }
                Section("Audio") {
                    EditField("BPM", text: $bpmText, numeric: true)
                    EditField("Key", text: $key)
                    EditField("Camelot", text: $camelot)
                    Toggle("Explicit", isOn: $explicit)
                }
                Section("Sentiment") {
                    EditField("Keywords", text: $sentiment)
                    Text("Comma-separated").font(.caption).foregroundStyle(.secondary)
                }
                if edits.songEdit(song.id) != nil {
                    Section {
                        Button("Reset to original", role: .destructive) {
                            edits.setSong(song.id, SongEdit()); app.applyEdits(); dismiss()
                        }
                        .accessibilityIdentifier("reset-edit")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Song")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.accessibilityIdentifier("save-edit")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 520)
            #endif
        }
    }

    private func save() {
        let raw = app.rawSong(song.id)
        var edit = SongEdit()
        edit.name = EditDelta.string(name, raw?.name)
        edit.artist = EditDelta.string(artist, raw?.artist)
        edit.year = EditDelta.int(yearText, raw?.year)
        edit.trackNumber = EditDelta.int(trackText, raw?.trackNumber)
        edit.bpm = EditDelta.double(bpmText, raw?.bpm)
        edit.key = EditDelta.optional(key, raw?.key)
        edit.camelot = EditDelta.optional(camelot, raw?.camelot)
        edit.explicit = EditDelta.bool(explicit, raw?.explicit)
        edit.sentimentKeywords = EditDelta.tags(sentiment, raw?.sentimentKeywords)
        edits.setSong(song.id, edit)
        app.applyEdits()
        dismiss()
    }
}
