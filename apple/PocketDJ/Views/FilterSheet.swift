import SwiftUI

/// Builds AND-composed filter clauses (eq / is-not / any-of / between), mirroring
/// the PWA FilterBuilder. Field set follows the item kind.
struct FilterSheet: View {
    @Bindable var browse: BrowseState
    let app: AppModel
    let collections: CollectionsStore
    @Environment(\.dismiss) private var dismiss

    private var fields: [Field] { Fields.forKind(browse.kind, includeHistory: browse.historyMode) }
    /// The membership filter is song-mode only and only meaningful when the user has
    /// at least one collection (mirrors BrowserView.tsx's render gate). Excluded in History
    /// mode (its rows are per-event, so the song-id membership filter doesn't apply cleanly).
    private var showMembership: Bool {
        browse.kind == .song && !browse.historyMode
            && !(collections.playlists.isEmpty && collections.pockets.isEmpty)
    }
    /// The favorite filter is song-mode only (and excluded from History, whose per-event rows
    /// bypass the read-time layer). Unlike membership it has NO "do you own any?" gate: an empty
    /// ♥ set is a legitimate thing to filter on ("show me what I haven't favorited yet").
    private var showFavorite: Bool { browse.kind == .song && !browse.historyMode }
    /// Hide-skips is HISTORY-only, the mirror image of the two gates above: skip-ness lives on
    /// play EVENTS, and only History rows carry one (`PlayRef`) — Browse has nothing to hide by.
    private var showHideSkips: Bool { browse.historyMode }

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
                        Button(role: .destructive) {
                            browse.removeClause(id: clause.id)
                        } label: {
                            Label("Remove filter", systemImage: "trash")
                        }
                        .accessibilityIdentifier("remove-clause-\(clause.field)")
                        .swipeActions {
                            Button(role: .destructive) {
                                browse.removeClause(id: clause.id)
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
                Section {
                    Button {
                        let f = fields.first!
                        browse.clauses.append(Clause(field: f.id, op: f.ops.first!))
                    } label: { Label("Add filter", systemImage: "plus.circle") }
                    .accessibilityIdentifier("add-filter")
                }

                if showFavorite {
                    FavoriteSection(browse: browse)
                }

                if showHideSkips {
                    PlaybackSection(browse: browse)
                }

                if showMembership {
                    MembershipSection(browse: browse, collections: collections)
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
                    Button("Clear All") { browse.clearAllFilters() }
                        .disabled(browse.clauses.isEmpty && !browse.favoriteActive && !browse.hideSkips)
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
                if field.id == "lastPlayedAt" {
                    dateRangeEditor            // "played between May and August 2026"
                } else {
                    HStack {
                        numberField("Min", value: $clause.min)
                        Text("–").foregroundStyle(.secondary)
                        numberField("Max", value: $clause.max)
                    }
                }
            // any-of (.inList) and none-of (.notInList) share the same multi-select
            // (chips/checkbox) UX over a Set<String>; only the predicate differs.
            case .inList, .notInList:
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

    // MARK: Date-range (History "Last played")
    // Clause.min/max hold epoch-MS (Double), matching PlayEvent.playedAt; FilterEngine's numeric
    // `.between` filters inclusively (>= min && <= max). The pickers are day-granular: "From" maps
    // to the START of the chosen day, "To" to the END of the chosen day, so an August "To" includes
    // all of Aug 31.
    @ViewBuilder private var dateRangeEditor: some View {
        DatePicker("From", selection: dateBinding($clause.min, endOfDay: false),
                   displayedComponents: .date)
            .accessibilityIdentifier("daterange-from")
        DatePicker("To", selection: dateBinding($clause.max, endOfDay: true),
                   displayedComponents: .date)
            .accessibilityIdentifier("daterange-to")
        if clause.min != nil || clause.max != nil {
            Button("Clear dates", role: .destructive) { clause.min = nil; clause.max = nil }
                .accessibilityIdentifier("daterange-clear")
        }
    }

    /// Bridge an epoch-ms `Double?` clause bound to a `Date` DatePicker. `endOfDay` stores the
    /// last instant of the chosen day (inclusive upper bound), derived from the Calendar (start of
    /// the NEXT day − 1 ms) so it's correct on DST-transition days (not every day is 24 h).
    private func dateBinding(_ ms: Binding<Double?>, endOfDay: Bool) -> Binding<Date> {
        Binding(
            get: { ms.wrappedValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date() },
            set: { picked in
                let cal = Calendar.current
                let start = cal.startOfDay(for: picked)
                if endOfDay {
                    let nextDay = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
                    ms.wrappedValue = nextDay.timeIntervalSince1970 * 1000 - 1
                } else {
                    ms.wrappedValue = start.timeIntervalSince1970 * 1000
                }
            })
    }
}

/// History-only playback section: the "Hide skips" lens on the timeline (a skip = advanced
/// away from with <50% played, the SkipTracker verdict). A Toggle, not a tri-state picker —
/// "skips ONLY" has no read the timeline's sort doesn't already give.
private struct PlaybackSection: View {
    @Bindable var browse: BrowseState

    var body: some View {
        Section("Playback") {
            Toggle("Hide skips", isOn: $browse.hideSkips)
                .accessibilityIdentifier("filter-hide-skips")
        }
    }
}

/// Favorite filter (song mode) — the ♥ sibling of the membership section below, sharing its
/// idiom: a titled `Section` holding one labelled control whose row shows the current state.
/// A tri-state Picker rather than membership's DisclosureGroup because there is nothing to
/// expand — three mutually-exclusive choices, not a list of ids. Left at the Form's DEFAULT
/// (menu) picker style deliberately: a `.segmented` style would squeeze "Not favorited" into
/// an unreadable sliver in iPhone portrait, which is the same narrow-control failure the
/// portrait-slider-popover rule exists to prevent.
private struct FavoriteSection: View {
    @Bindable var browse: BrowseState

    var body: some View {
        Section("Favorites") {
            Picker("Favorites", selection: $browse.favoriteFilter) {
                Text("Any").tag(BrowseState.FavoriteFilter.any)
                Text("Favorites only").tag(BrowseState.FavoriteFilter.only)
                Text("Not favorited").tag(BrowseState.FavoriteFilter.exclude)
            }
            .accessibilityIdentifier("favorite-filter")
        }
    }
}

/// Collection-membership filter (song mode) — ports the PWA's two MembershipFilter
/// variants (src/components/browser/MembershipFilter.tsx): SHOW ("in playlist/pocket",
/// keep only members) and HIDE ("not in playlist/pocket", drop members). Each is an
/// "Any playlist / pocket" toggle plus grouped per-collection checkboxes, with Clear.
private struct MembershipSection: View {
    @Bindable var browse: BrowseState
    let collections: CollectionsStore

    var body: some View {
        Section("Collection membership") {
            MembershipPicker(
                title: "In playlist / pocket",
                anyHint: "any collection",
                idPrefix: "include",
                collections: collections,
                any: $browse.includeAny,
                ids: $browse.includeIds)
            MembershipPicker(
                title: "Not in playlist / pocket",
                anyHint: "any collection",
                idPrefix: "exclude",
                collections: collections,
                any: $browse.excludeAny,
                ids: $browse.excludeIds)
            if browse.membershipActive {
                Button("Clear membership", role: .destructive) { browse.clearMembership() }
                    .accessibilityIdentifier("membership-clear")
            }
        }
    }
}

/// One membership variant: an "Any playlist / pocket" toggle (which disables the
/// per-collection list, like the PWA's `<fieldset disabled={any}>`), then a Playlists
/// group and a Pockets group of checkboxes. Mixed playlist+pocket ids share one Set.
private struct MembershipPicker: View {
    let title: String
    let anyHint: String
    let idPrefix: String
    let collections: CollectionsStore
    @Binding var any: Bool
    @Binding var ids: Set<String>

    private var summary: String {
        any ? anyHint : (ids.isEmpty ? "off" : "\(ids.count) selected")
    }

    var body: some View {
        DisclosureGroup("\(title): \(summary)") {
            Toggle("Any playlist / pocket", isOn: $any)
                .accessibilityIdentifier("\(idPrefix)-any")
            if !any {
                if !collections.playlists.isEmpty {
                    Text("Playlists").font(.caption).foregroundStyle(.secondary)
                    ForEach(collections.playlists) { row("\u{266B} \($0.name)", id: $0.id) }
                }
                if !collections.pockets.isEmpty {
                    Text("Pockets").font(.caption).foregroundStyle(.secondary)
                    ForEach(collections.pockets) { row("\u{25D6} \($0.name)", id: $0.id) }
                }
            }
        }
        .accessibilityIdentifier("membership-\(idPrefix)")
    }

    private func row(_ label: String, id: String) -> some View {
        Button {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if ids.contains(id) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .accessibilityIdentifier("\(idPrefix)-chip-\(id)")
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
