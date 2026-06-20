import SwiftUI

/// Edit an album's metadata. Saves only the fields that DIFFER from the original
/// index value (a clean delta) into the local EditsStore, then re-applies the
/// overlay so every view updates.
struct EditAlbumView: View {
    @Environment(AppModel.self) private var app
    @Environment(EditsStore.self) private var edits
    @Environment(\.dismiss) private var dismiss
    let album: IndexAlbum

    @State private var name: String
    @State private var artist: String
    @State private var genre: String
    @State private var yearText: String
    @State private var country: String

    init(album: IndexAlbum) {
        self.album = album
        _name = State(initialValue: album.name)
        _artist = State(initialValue: album.artist)
        _genre = State(initialValue: album.genre ?? "")
        _yearText = State(initialValue: album.year.map(String.init) ?? "")
        _country = State(initialValue: album.country ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Album") {
                    EditField("Title", text: $name)
                    EditField("Artist", text: $artist)
                    EditField("Genre", text: $genre)
                    EditField("Year", text: $yearText, numeric: true)
                    EditField("Country", text: $country)
                }
                if edits.albumEdit(album.id) != nil {
                    Section {
                        Button("Reset to original", role: .destructive) {
                            edits.setAlbum(album.id, AlbumEdit()); app.applyEdits(); dismiss()
                        }
                        .accessibilityIdentifier("reset-edit")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Album")
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
            .frame(minWidth: 440, minHeight: 420)
            #endif
        }
    }

    private func save() {
        let raw = app.rawAlbum(album.id)
        var edit = AlbumEdit()
        edit.name = EditDelta.string(name, raw?.name)
        edit.artist = EditDelta.string(artist, raw?.artist)
        edit.genre = EditDelta.optional(genre, raw?.genre)
        edit.year = EditDelta.int(yearText, raw?.year)
        edit.country = EditDelta.optional(country, raw?.country)
        edits.setAlbum(album.id, edit)
        app.applyEdits()
        dismiss()
    }
}

/// A labelled text field for the edit forms.
struct EditField: View {
    let label: String
    @Binding var text: String
    var numeric = false
    init(_ label: String, text: Binding<String>, numeric: Bool = false) {
        self.label = label; self._text = text; self.numeric = numeric
    }
    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(numeric ? .numbersAndPunctuation : .default)
                .textInputAutocapitalization(numeric ? .never : .sentences)
                .autocorrectionDisabled(numeric)
                #endif
        }
    }
}

/// Computes a metadata delta: the entered value, or `nil` when it matches the
/// original (so unchanged fields are NOT stored as overrides).
enum EditDelta {
    static func string(_ entered: String, _ original: String?) -> String? {
        let v = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        return v == (original ?? "") ? nil : v
    }
    static func optional(_ entered: String, _ original: String?) -> String? {
        let v = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = v.isEmpty ? nil : v
        return value == original ? nil : value
    }
    static func int(_ entered: String, _ original: Int?) -> Int? {
        let value = Int(entered.trimmingCharacters(in: .whitespacesAndNewlines))
        return value == original ? nil : value
    }
    static func double(_ entered: String, _ original: Double?) -> Double? {
        let value = Double(entered.trimmingCharacters(in: .whitespacesAndNewlines))
        return value == original ? nil : value
    }
    static func bool(_ entered: Bool, _ original: Bool?) -> Bool? {
        entered == (original ?? false) ? nil : entered
    }
    static func tags(_ entered: String, _ original: [String]?) -> [String]? {
        let list = entered.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let value: [String]? = list.isEmpty ? nil : list
        return value == original ? nil : value
    }
}
