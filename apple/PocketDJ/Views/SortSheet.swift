import SwiftUI

/// Multi-key sort builder. Keys apply in order (top = primary); reorder to change
/// priority, toggle each key's direction. Mirrors the PWA's multi-key stable sort.
struct SortSheet: View {
    @Bindable var browse: BrowseState
    @Environment(\.dismiss) private var dismiss

    private var sortable: [Field] { Fields.forKind(browse.kind).filter { $0.sortable } }
    private var unused: [Field] { sortable.filter { f in !browse.sortKeys.contains { $0.field == f.id } } }

    var body: some View {
        NavigationStack {
            List {
                if browse.sortKeys.isEmpty {
                    Text("No sort. Default order is artist › title.")
                        .foregroundStyle(.secondary)
                }
                ForEach($browse.sortKeys) { $key in
                    HStack {
                        Text(Fields.byID[key.field]?.label ?? key.field)
                        Spacer()
                        Button {
                            key.dir = key.dir == .asc ? .desc : .asc
                        } label: {
                            Image(systemName: key.dir == .asc ? "arrow.up" : "arrow.down")
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("sortdir-\(key.field)")
                    }
                }
                .onMove { browse.sortKeys.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { browse.sortKeys.remove(atOffsets: $0) }

                if !unused.isEmpty {
                    Section("Add key") {
                        ForEach(unused) { f in
                            Button {
                                browse.sortKeys.append(SortKey(field: f.id))
                            } label: { Label(f.label, systemImage: "plus") }
                            .accessibilityIdentifier("addsort-\(f.id)")
                        }
                    }
                }
            }
            .navigationTitle("Sort")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { EditButton() } }
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("sort-done")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear All") { browse.sortKeys.removeAll() }
                        .disabled(browse.sortKeys.isEmpty)
                        .accessibilityIdentifier("sort-clear-all")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}
