import SwiftUI

/// Builds AND-composed filter clauses (eq / is-not / any-of / between), mirroring
/// the PWA FilterBuilder. Field set follows the item kind.
struct FilterSheet: View {
    @Bindable var browse: BrowseState
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    private var fields: [Field] { Fields.forKind(browse.kind) }

    var body: some View {
        NavigationStack {
            Form {
                if browse.clauses.isEmpty {
                    Section {
                        Text("No filters. Add one to narrow the \(browse.kind == .album ? "albums" : "songs").")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach($browse.clauses) { $clause in
                    Section {
                        ClauseEditor(clause: $clause, fields: fields, app: app, browse: browse)
                    }
                }
                Section {
                    Button {
                        let f = fields.first!
                        browse.clauses.append(Clause(field: f.id, op: f.ops.first!))
                    } label: { Label("Add filter", systemImage: "plus.circle") }
                    .accessibilityIdentifier("add-filter")
                }
            }
            .navigationTitle("Filter")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("filter-done")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear All") { browse.clauses.removeAll() }
                        .disabled(browse.clauses.isEmpty)
                        .accessibilityIdentifier("filter-clear-all")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 540)
        #endif
    }
}

private struct ClauseEditor: View {
    @Binding var clause: Clause
    let fields: [Field]
    let app: AppModel
    let browse: BrowseState

    private var field: Field { Fields.byID[clause.field] ?? fields[0] }
    private var options: [String] { field.hasOptions ? browse.options(for: field.id, in: app) : [] }

    var body: some View {
        Picker("Field", selection: Binding(
            get: { clause.field },
            set: { newID in
                clause.field = newID
                let f = Fields.byID[newID]!
                clause.op = f.ops.first!
                clause.value = ""; clause.values = []; clause.min = nil; clause.max = nil
            })
        ) {
            ForEach(fields) { Text($0.label).tag($0.id) }
        }
        .accessibilityIdentifier("clause-field")

        Picker("Operator", selection: $clause.op) {
            ForEach(field.ops) { Text($0.label).tag($0) }
        }
        .accessibilityIdentifier("clause-op")

        valueEditor
    }

    @ViewBuilder private var valueEditor: some View {
        switch field.kind {
        case .bool:
            Toggle("Is explicit", isOn: Binding(
                get: { clause.value == "true" },
                set: { clause.value = $0 ? "true" : "false" }))
        default:
            switch clause.op {
            case .between:
                HStack {
                    numberField("Min", value: $clause.min)
                    Text("–").foregroundStyle(.secondary)
                    numberField("Max", value: $clause.max)
                }
            case .inList:
                if field.hasOptions {
                    MultiSelect(title: field.label, options: options, selection: $clause.values)
                } else {
                    TextField("Comma-separated", text: Binding(
                        get: { clause.values.sorted().joined(separator: ", ") },
                        set: { clause.values = Set($0.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }))
                        .pocketField()
                }
            default: // eq / neq
                if field.hasOptions {
                    Picker("Value", selection: $clause.value) {
                        Text("—").tag("")
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                } else if field.numeric {
                    TextField("Value", text: $clause.value)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .pocketField()
                } else {
                    TextField("Value", text: $clause.value)
                        .pocketField()
                }
            }
        }
    }

    private func numberField(_ label: String, value: Binding<Double?>) -> some View {
        TextField(label, text: Binding(
            get: { value.wrappedValue.map { Fmt.trim($0) } ?? "" },
            set: { value.wrappedValue = Double($0) }))
        #if os(iOS)
        .keyboardType(.numbersAndPunctuation)
        #endif
        .pocketField()
    }
}

/// A simple multi-select list backed by a Set<String>.
struct MultiSelect: View {
    let title: String
    let options: [String]
    @Binding var selection: Set<String>

    var body: some View {
        DisclosureGroup("\(title) (\(selection.count))") {
            ForEach(options, id: \.self) { opt in
                Button {
                    if selection.contains(opt) { selection.remove(opt) } else { selection.insert(opt) }
                } label: {
                    HStack {
                        Text(opt).foregroundStyle(.primary)
                        Spacer()
                        if selection.contains(opt) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
            }
        }
        .accessibilityIdentifier("multiselect-\(title)")
    }
}
