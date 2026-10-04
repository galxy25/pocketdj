import SwiftUI
import UniformTypeIdentifiers

/// The Playlists screen's top-level tab: YOUR editable collections vs the read-only
/// SHARED source-derived playlists ("From your sources"). Mirrors BrowseView's segmented
/// Show-tabs. Persisted UI-ONLY in `@AppStorage("pdj.playlists.mode")` — NEVER in the
/// collections schema (it is view state, not collection data).
enum PlaylistMode: String, CaseIterable, Identifiable {
    case user, shared
    var id: String { rawValue }
    var label: String {
        switch self {
        case .user:   return "Yours"
        case .shared: return "Shared"
        }
    }

    /// Whether this tab has any search match, given the per-kind match counts — the seam that
    /// re-scopes the `.searchable` results (and the "no matches" placeholder) to the active tab:
    /// User ignores source matches, Shared ignores playlist/pocket matches.
    func hasMatches(playlists: Int, pockets: Int, sources: Int) -> Bool {
        switch self {
        case .user:   return playlists > 0 || pockets > 0
        case .shared: return sources > 0
        }
    }
}

/// Pure, testable helpers for the Shared tab's per-source grouping + collapse memory.
/// (Extracted from the view so the grouping/ordering + the expanded-set persistence are
/// unit-testable without SwiftUI.)
enum PlaylistSources {
    /// Group source playlists by `sourceName`, ordered by `availableSources` (first-seen source
    /// order); any source not in that list is appended alphabetically. O(n) over a small array.
    static func grouped(_ playlists: [SourcePlaylist],
                        availableSources: [String]) -> [(source: String, playlists: [SourcePlaylist])] {
        let byName = Dictionary(grouping: playlists, by: \.sourceName)
        var result: [(source: String, playlists: [SourcePlaylist])] = []
        for name in availableSources {
            if let group = byName[name] { result.append((name, group)) }
        }
        let known = Set(availableSources)
        for name in byName.keys.filter({ !known.contains($0) }).sorted() {
            if let group = byName[name] { result.append((name, group)) }
        }
        return result
    }

    /// The EXPANDED source names, stored as a `[String]` (inverse of the folder-collapse key:
    /// here MISSING ⇒ collapsed, so the collapse-by-default default needs no seeding).
    static let expandedKey = "pdj.sources.expanded"
    static func loadExpanded(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: expandedKey) ?? [])
    }
    /// Whether the expanded-set key has EVER been written — the one-time-seed marker (both the
    /// seed and any explicit toggle write it, so an empty persisted array ≠ never-touched).
    static func hasPersistedExpansion(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: expandedKey) != nil
    }
    static func persistExpanded(_ names: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(Array(names), forKey: expandedKey)
    }
}

/// Collections — playlists (ordered chapters) and pockets (reusable groupings), both
/// organized into optional collapsible FOLDERS (folders are heterogeneous: they hold
/// BOTH playlists and pockets). Your editable collections render ABOVE the read-only
/// "From your sources" index playlists. The body is factored into small helper subviews
/// so the Swift type-checker never times out.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(IntentServices.self) private var intents
    @Environment(SettingsStore.self) private var settings
    @Binding var path: NavigationPath
    /// USER | SHARED tab — persisted UI-only (outside the collections schema).
    @AppStorage("pdj.playlists.mode") private var mode: PlaylistMode = .user
    /// EXPANDED source names for the Shared tab's per-source DisclosureGroups (missing ⇒
    /// collapsed = default). Inverted clone of the folder-collapse persistence below.
    @State private var expandedSources: Set<String> = PlaylistSources.loadExpanded()
    // Playlist dialogs
    @State private var newName = ""
    @State private var showNew = false
    @State private var showImporter = false
    @State private var renamingId: String?
    @State private var nameDraft = ""
    @State private var deletingId: String?
    // Pocket dialogs
    @State private var showNewPocket = false
    @State private var newPocketName = ""
    @State private var renamingPocketId: String?
    @State private var pocketNameDraft = ""
    @State private var deletingPocketId: String?
    // Folder dialogs
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolderId: String?
    @State private var folderNameDraft = ""
    @State private var deletingFolderId: String?
    /// Collapsed folder ids, persisted across launches (UserDefaults).
    @State private var collapsed: Set<String> = PlaylistsView.loadCollapsed()
    /// Live name filter (the `.searchable` field). Substring, case/diacritic-insensitive,
    /// matched against playlist / pocket / source-playlist NAMES — see `matchesQuery`.
    @State private var query = ""
    /// The collection row currently hovered by a song drag (highlight). Playlist/pocket rows
    /// only — folder headers and read-only source rows take no drops (v1).
    @State private var dropTargetId: String?

    private var indexPlaylists: [SourcePlaylist] { app.indexPlaylists }

    /// The trimmed search term; empty ⇒ not searching (the folder hierarchy shows as normal).
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// Case- and diacritic-insensitive substring match of the live query against `name`.
    private func matchesQuery(_ name: String) -> Bool {
        name.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // Filtered result lists — computed only while searching, ordered by the chosen collection
    // sort. Search FLATTENS the folder hierarchy: a match surfaces regardless of which folder
    // holds it, so finding a playlist by name never means expanding folders first.
    private var matchingPlaylists: [Playlist] {
        settings.collectionSort.sorted(collections.playlists.filter { matchesQuery($0.name) })
    }
    private var matchingPockets: [Pocket] {
        settings.collectionSort.sorted(collections.pockets.filter { matchesQuery($0.name) })
    }
    private var matchingSources: [SourcePlaylist] {
        settings.collectionSort.sorted(indexPlaylists.filter { matchesQuery($0.name) })
    }
    /// Whether the ACTIVE tab has any search match (drives the per-tab "no matches" placeholder).
    private var hasAnyMatchInMode: Bool {
        mode.hasMatches(playlists: matchingPlaylists.count,
                        pockets: matchingPockets.count, sources: matchingSources.count)
    }

    /// The Siri "Create Pocket" build status — the async build's ONLY user-visible
    /// surface after the intent's "on it" dialog (the build may have been kicked off
    /// with the app backgrounded). Building shows progress; done/failed stick until
    /// dismissed so a silent failure can't eat the pocket.
    @ViewBuilder private var pocketBuilderBanner: some View {
        switch intents.pocketBuilder.phase {
        case .idle:
            EmptyView()
        case .building(let brief):
            builderBannerRow(icon: nil, text: "Building a pocket for “\(brief)”…", dismissable: false)
        case .done(_, let name, let songCount):
            builderBannerRow(icon: "checkmark.circle.fill",
                             text: "Siri created “\(name)” — \(songCount) \(songCount == 1 ? "song" : "songs").",
                             dismissable: true)
        case .failed(let message):
            builderBannerRow(icon: "exclamationmark.triangle.fill",
                             text: "Pocket build failed: \(message)", dismissable: true)
        }
    }

    private func builderBannerRow(icon: String?, text: String, dismissable: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).foregroundStyle(Theme.accent)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            if dismissable {
                Button { intents.pocketBuilder.acknowledge() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.accent.opacity(0.12))
        .accessibilityIdentifier("pocket-builder-banner")
    }

    var body: some View {
        VStack(spacing: 0) {
            pocketBuilderBanner
            modeTabsPicker
            content
        }
        .navigationTitle("Playlists")
        .searchable(text: $query, prompt: searchPrompt)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden).background(Theme.bg)
        .toolbar { toolbarContent }
        .modifier(folderDialogs)
        .alert("New Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { let n = newName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.createPlaylist(n) }; newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename playlist", isPresented: Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") {
                if let id = renamingId { let n = nameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renamePlaylist(id, n) } }
                renamingId = nil
            }
            Button("Cancel", role: .cancel) { renamingId = nil }
        }
        .confirmationDialog("Delete this playlist?", isPresented: Binding(get: { deletingId != nil }, set: { if !$0 { deletingId = nil } }), titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) { if let id = deletingId { collections.deletePlaylist(id) }; deletingId = nil }
            Button("Cancel", role: .cancel) { deletingId = nil }
        } message: {
            Text("This also deletes its set lists. This can't be undone.")
        }
        .alert("New Pocket", isPresented: $showNewPocket) {
            TextField("Name", text: $newPocketName)
            Button("Create") { let n = newPocketName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.createPocket(n) }; newPocketName = "" }
            Button("Cancel", role: .cancel) { newPocketName = "" }
        }
        .alert("Rename pocket", isPresented: Binding(get: { renamingPocketId != nil }, set: { if !$0 { renamingPocketId = nil } })) {
            TextField("Name", text: $pocketNameDraft)
            Button("Save") {
                if let id = renamingPocketId { let n = pocketNameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renamePocket(id, n) } }
                renamingPocketId = nil
            }
            Button("Cancel", role: .cancel) { renamingPocketId = nil }
        }
        .confirmationDialog("Delete this pocket?", isPresented: Binding(get: { deletingPocketId != nil }, set: { if !$0 { deletingPocketId = nil } }), titleVisibility: .visible) {
            Button("Delete pocket", role: .destructive) { if let id = deletingPocketId { collections.deletePocket(id) }; deletingPocketId = nil }
            Button("Cancel", role: .cancel) { deletingPocketId = nil }
        } message: {
            Text("Removes the pocket and unnests it from any parent. Its items aren't deleted. This can't be undone.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pocketDJCollection, .zip, .json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try? collections.importAny(url: url)
        }
    }

    // MARK: - Mode tabs + content

    /// USER | SHARED segmented tabs, docked at the TOP of the screen (mirrors BrowseView's
    /// `showTabsPicker`). Search + the list below scope to the selected tab.
    private var modeTabsPicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(PlaylistMode.allCases) { m in Text(m.label).tag(m) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityIdentifier("playlist-mode-picker")
    }

    /// The tab prompt so the search field advertises what it scopes to.
    private var searchPrompt: String {
        mode == .user ? "Search playlists and pockets" : "Search source playlists"
    }

    /// The list body, gated on the active tab. While searching, only the active tab's matches
    /// show (`searchResultsSections` branches on `mode`); otherwise the tab's own sections, each
    /// with its own empty state so a user with no own collections still sees a populated Shared tab.
    @ViewBuilder private var content: some View {
        if isSearching {
            List { searchResultsSections }
        } else {
            switch mode {
            case .user:
                // Show the list when there are own collections OR any recently-added items (the
                // virtual "Recently added" row lives at the top of the User tab).
                // `hasRecentlyAddedItems` (not `recentlyAddedPlaylist`): this gate needs a
                // yes/no, and building the 3,650-id playlist to answer it was the single
                // most expensive thing in the tab's body.
                if collections.playlists.isEmpty && collections.pockets.isEmpty
                    && !app.hasRecentlyAddedItems(limit: settings.defaultRecentlyAddedCount) {
                    userEmptyState
                } else {
                    List { userSections }
                }
            case .shared:
                if indexPlaylists.isEmpty {
                    sharedEmptyState
                } else {
                    List { sharedSections }
                }
            }
        }
    }

    // MARK: - Sections

    /// USER tab — your editable playlists + pockets + folders (no source rows), with the virtual
    /// "Recently added" row pinned at the top.
    @ViewBuilder private var userSections: some View {
        recentlyAddedSection
        yourPlaylistsSection
        yourPocketsSection
        ForEach(collections.foldersOrdered()) { folder in
            folderSection(folder)
        }
    }

    /// The synthetic "Recently added" row — the last N items the profile added to its library
    /// (Apple Music adds + ＋Add + imports + custom audio), N from Settings ▸ Collections. Navigates
    /// to the read-only source-playlist detail (Play / Shuffle / Duplicate / Convert / Rip-Burn).
    @ViewBuilder private var recentlyAddedSection: some View {
        if let ra = app.recentlyAddedPlaylist(limit: settings.defaultRecentlyAddedCount) {
            Section {
                NavigationLink(value: ra) {
                    Label("\(ra.playlist.songIds.count) songs — newest first",
                          systemImage: "clock.badge.checkmark")
                        .foregroundStyle(Theme.fg)
                }
                .accessibilityIdentifier("recently-added-row")
            } header: {
                Text("Recently added")
            }
        }
    }

    private var userEmptyState: some View {
        ContentUnavailableView {
            Label("No collections yet", systemImage: "music.note.list")
        } description: {
            Text("A playlist is a template of ordered chapters. A pocket is a reusable grouping of items that sound good together.")
        } actions: {
            HStack(spacing: 12) {
                Button("New Playlist") { showNew = true }.buttonStyle(.borderedProminent)
                Button("New Pocket") { showNewPocket = true }.buttonStyle(.bordered)
            }
        }
        .accessibilityIdentifier("playlists-user-empty")
    }

    private var sharedEmptyState: some View {
        ContentUnavailableView {
            Label("No source playlists", systemImage: "music.note.list")
        } description: {
            Text("Playlists from your enabled sources (Apple Music, vinyl, imports…) appear here. Enable a source in Settings, or add playlists to one.")
        }
        .accessibilityIdentifier("playlists-shared-empty")
    }

    /// YOUR (editable) top-level PLAYLISTS — those NOT in any folder. Own header, distinct
    /// from pockets and from the read-only "From your sources" section. Rendered first.
    @ViewBuilder private var yourPlaylistsSection: some View {
        let top = collections.playlists(inFolder: nil, sortedBy: settings.collectionSort)
        Section {
            // Collapsible like folders / shared sources. A reserved sentinel key (double-
            // underscore, un-collidable with folder UUIDs) reuses the folder collapse store,
            // so the state persists across launches. Default EXPANDED (missing ⇒ expanded).
            DisclosureGroup(isExpanded: folderExpansion("__your_playlists__")) {
                if collections.playlists.isEmpty {
                    Text("No playlists yet — tap + to create one.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                } else if top.isEmpty {
                    Text("All your playlists are in folders below.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
                ForEach(top) { pl in playlistRow(pl) }
            } label: {
                HStack {
                    Text("Your playlists")
                    Spacer()
                    Text("\(top.count)").font(.caption).foregroundStyle(Theme.fgDim)
                }
                .accessibilityIdentifier("your-playlists-header")
            }
        }
    }

    /// YOUR top-level POCKETS — those NOT in any folder. A SEPARATE section header from your
    /// playlists. Hidden entirely when you have no pockets at all (no empty "Pockets" header).
    @ViewBuilder private var yourPocketsSection: some View {
        if !collections.pockets.isEmpty {
            let top = collections.pockets(inFolder: nil, sortedBy: settings.collectionSort)
            Section {
                DisclosureGroup(isExpanded: folderExpansion("__your_pockets__")) {
                    if top.isEmpty {
                        Text("All your pockets are in folders below.")
                            .font(.caption).foregroundStyle(Theme.fgDim)
                    }
                    ForEach(top) { pk in pocketRow(pk) }
                } label: {
                    HStack {
                        Text("Pockets")
                        Spacer()
                        Text("\(top.count)").font(.caption).foregroundStyle(Theme.fgDim)
                    }
                    .accessibilityIdentifier("your-pockets-header")
                }
            }
        }
    }

    /// One collapsible FOLDER (flat) of playlists AND pockets, name-ordered. Collapse state persists.
    @ViewBuilder private func folderSection(_ folder: PlaylistFolder) -> some View {
        let plMembers = collections.playlists(inFolder: folder.id, sortedBy: settings.collectionSort)
        let pkMembers = collections.pockets(inFolder: folder.id, sortedBy: settings.collectionSort)
        let memberCount = plMembers.count + pkMembers.count
        Section {
            DisclosureGroup(isExpanded: folderExpansion(folder.id)) {
                if plMembers.isEmpty && pkMembers.isEmpty {
                    Text("Empty folder — move a playlist or pocket in with its ⋯ menu.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
                ForEach(plMembers) { pl in playlistRow(pl) }
                ForEach(pkMembers) { pk in pocketRow(pk) }
            } label: {
                HStack {
                    Label(folder.name, systemImage: "folder").foregroundStyle(Theme.accent2)
                    Spacer()
                    Text("\(memberCount)").font(.caption).foregroundStyle(Theme.fgDim)
                }
                .accessibilityIdentifier("folder-\(folder.id)")
                .contextMenu {
                    Button { folderNameDraft = folder.name; renamingFolderId = folder.id } label: { Label("Rename folder", systemImage: "pencil") }
                        .accessibilityIdentifier("folder-rename-\(folder.id)")
                    Button(role: .destructive) { deletingFolderId = folder.id } label: { Label("Delete folder", systemImage: "trash") }
                        .accessibilityIdentifier("folder-delete-\(folder.id)")
                }
            }
        }
    }

    /// SHARED tab — the read-only source playlists, GROUPED BY SOURCE into collapse-by-default,
    /// remember-my-expansions DisclosureGroups (inverse of the folder-collapse pattern below:
    /// EXPANDED names are persisted, so missing ⇒ collapsed). Groups follow `availableSources`
    /// order; each group's members honor the chosen collection sort.
    @ViewBuilder private var sharedSections: some View {
        Section {
            ForEach(groupedSources, id: \.source) { group in
                DisclosureGroup(isExpanded: sourceExpansion(group.source)) {
                    ForEach(settings.collectionSort.sorted(group.playlists)) { sp in sourceRow(sp) }
                } label: {
                    HStack {
                        Label(group.source, systemImage: "shippingbox").foregroundStyle(Theme.accent2)
                        Spacer()
                        Text("\(group.playlists.count)").font(.caption).foregroundStyle(Theme.fgDim)
                    }
                    .accessibilityIdentifier("source-group-\(group.source)")
                }
            }
        } header: {
            Text("From your sources")
        } footer: {
            Text("Read-only playlists from your enabled sources. Play one, or duplicate it into an editable playlist.")
        }
        .onAppear { seedDefaultSourceExpansion() }
    }

    /// Source playlists grouped by source, ordered for display (see `PlaylistSources.grouped`).
    /// PUBLIC mode (audit fix): the user's OWN on-device "Apple Music" library group leads —
    /// the shared-catalog groups (the catalog owner's playlists) follow. Private (the owner)
    /// keeps first-seen order.
    private var groupedSources: [(source: String, playlists: [SourcePlaylist])] {
        let groups = PlaylistSources.grouped(indexPlaylists, availableSources: app.availableSources)
        guard !settings.appleMusicPrivateSync else { return groups }
        let own = groups.filter { $0.source == AppleMusicLibraryStore.sourceName }
        return own + groups.filter { $0.source != AppleMusicLibraryStore.sourceName }
    }

    /// PUBLIC-mode default expansion (audit fix — "the mirrors exist but take two navigations
    /// to see"): a user who has never touched the Shared tab's disclosure state gets their OWN
    /// library group open. One-time seed; explicit collapses persist as usual afterwards.
    private func seedDefaultSourceExpansion() {
        // Once-only via KEY PRESENCE (review catch: `isEmpty` re-fired the seed after the user
        // explicitly collapsed everything). An unwritten key + amlib-not-yet-loaded correctly
        // defers the seed to a later visit.
        guard !settings.appleMusicPrivateSync, !PlaylistSources.hasPersistedExpansion(),
              indexPlaylists.contains(where: { $0.sourceName == AppleMusicLibraryStore.sourceName })
        else { return }
        expandedSources.insert(AppleMusicLibraryStore.sourceName)
        PlaylistSources.persistExpanded(expandedSources)
    }

    /// One read-only source-playlist row (shared by the sources section and search results).
    @ViewBuilder private func sourceRow(_ sp: SourcePlaylist) -> some View {
        NavigationLink(value: sp) {
            HStack {
                Image(systemName: "music.note.list").foregroundStyle(Theme.accent2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sp.name).foregroundStyle(Theme.fg)
                    HStack(spacing: 6) {
                        Text(sp.sourceName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent2.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.accent2)
                        Text("\(sp.songIds.count) song\(sp.songIds.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(Theme.fgDim)
                    }
                }
            }
        }
        .accessibilityIdentifier("indexplaylist-\(sp.id)")
    }

    /// Flattened, name-filtered results shown WHILE searching — matching playlists, pockets,
    /// and source playlists, each under its own header, folder nesting collapsed away. An
    /// empty match set shows a "No matches" placeholder so the list is never a blank void.
    @ViewBuilder private var searchResultsSections: some View {
        if !hasAnyMatchInMode {
            Section {
                ContentUnavailableView.search(text: trimmedQuery)
                    .accessibilityIdentifier("playlists-search-empty")
            }
        } else {
            switch mode {
            case .user:
                if !matchingPlaylists.isEmpty {
                    Section("Your playlists") {
                        ForEach(matchingPlaylists) { pl in playlistRow(pl) }
                    }
                }
                if !matchingPockets.isEmpty {
                    Section("Pockets") {
                        ForEach(matchingPockets) { pk in pocketRow(pk) }
                    }
                }
            case .shared:
                // Search flattens the per-source grouping: a match surfaces regardless of source.
                if !matchingSources.isEmpty {
                    Section("From your sources") {
                        ForEach(matchingSources) { sp in sourceRow(sp) }
                    }
                }
            }
        }
    }

    /// One editable-playlist row + its context menu (rename / move to folder / delete).
    @ViewBuilder private func playlistRow(_ pl: Playlist) -> some View {
        NavigationLink(value: pl) {
            HStack {
                Image(systemName: "music.note.list").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pl.name).foregroundStyle(Theme.fg)
                    let stats = collections.stats(forPlaylist: pl)
                    Text("\(pl.sequences.count) chapter\(pl.sequences.count == 1 ? "" : "s") · \(stats.summary)")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
            }
        }
        .accessibilityIdentifier("playlist-\(pl.id)")
        .contextMenu { playlistRowMenu(pl) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { collections.deletePlaylist(pl.id) } label: { Label("Delete", systemImage: "trash") }
        }
        // Multi-select drag & drop: dropping songs on the ROW adds them to the playlist's
        // default chapter (deduped batch — CollectionsStore.addSongs).
        .dropDestination(for: SongTransfer.self) { items, _ in
            // Studio ids resolve through studioLookup (never a bare prefix test — foreign
            // pasteboard strings must not persist into the cloud-synced document).
            let ids = SongDrop.acceptableIds(items) { app.songsById[$0] != nil || collections.studioLookup?($0) != nil }
            guard !ids.isEmpty else { return false }
            return collections.addSongs(ids, to: AddTarget(kind: .playlist, id: pl.id)) > 0
        } isTargeted: { over in
            if over { dropTargetId = pl.id } else if dropTargetId == pl.id { dropTargetId = nil }
        }
        .listRowBackground(dropTargetId == pl.id ? Theme.accent.opacity(0.18) : nil)
    }

    /// MANAGEMENT ONLY — NO PLAY ITEMS HERE. A round of this shipped ▶/🔀 straight off the row and
    /// the owner rejected it outright ("i dont want a row level play menu"): playing a collection
    /// is what its DETAIL screen's floating toolbar is for, and duplicating it into every row
    /// turned a long-press meant for rename/move/delete into a transport. `CollectionToolbar` is
    /// where that pair lives now — one screen, one place.
    @ViewBuilder private func playlistRowMenu(_ pl: Playlist) -> some View {
        Button { nameDraft = pl.name; renamingId = pl.id } label: { Label("Rename", systemImage: "pencil") }
            .accessibilityIdentifier("list-rename-\(pl.id)")
        Menu {
            if pl.folderId != nil {
                Button { collections.setPlaylistFolder(pl.id, folderId: nil) } label: { Label("Top level", systemImage: "tray") }
                    .accessibilityIdentifier("move-top-\(pl.id)")
            }
            ForEach(collections.foldersOrdered()) { f in
                Button { collections.setPlaylistFolder(pl.id, folderId: f.id) } label: {
                    Label(f.name, systemImage: pl.folderId == f.id ? "checkmark" : "folder")
                }
                .accessibilityIdentifier("move-to-\(f.id)-\(pl.id)")
            }
            Divider()
            Button { showNewFolder = true } label: { Label("New folder…", systemImage: "folder.badge.plus") }
        } label: { Label("Move to folder", systemImage: "folder") }
            .accessibilityIdentifier("move-folder-\(pl.id)")
        Button(role: .destructive) { deletingId = pl.id } label: { Label("Delete", systemImage: "trash") }
            .accessibilityIdentifier("list-delete-\(pl.id)")
    }

    /// One reusable-pocket row + its context menu (rename / move to folder / add to playlist / delete).
    @ViewBuilder private func pocketRow(_ pocket: Pocket) -> some View {
        NavigationLink(value: pocket) {
            HStack {
                Image(systemName: "rectangle.stack").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pocket.name).foregroundStyle(Theme.fg)
                    let stats = collections.stats(forPocket: pocket.id)
                    Text("\(pocket.memberCount) item\(pocket.memberCount == 1 ? "" : "s") · \(stats.summary)")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
            }
        }
        .accessibilityIdentifier("pocket-\(pocket.id)")
        .contextMenu { pocketRowMenu(pocket) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { collections.deletePocket(pocket.id) } label: { Label("Delete", systemImage: "trash") }
        }
        // Multi-select drag & drop: dropping songs on the ROW adds them to the pocket
        // (deduped batch — CollectionsStore.addSongs).
        .dropDestination(for: SongTransfer.self) { items, _ in
            // Same studio-id resolution rule as the playlist row above.
            let ids = SongDrop.acceptableIds(items) { app.songsById[$0] != nil || collections.studioLookup?($0) != nil }
            guard !ids.isEmpty else { return false }
            return collections.addSongs(ids, to: AddTarget(kind: .pocket, id: pocket.id)) > 0
        } isTargeted: { over in
            if over { dropTargetId = pocket.id } else if dropTargetId == pocket.id { dropTargetId = nil }
        }
        .listRowBackground(dropTargetId == pocket.id ? Theme.accent.opacity(0.18) : nil)
    }

    /// Management only — same rule as `playlistRowMenu` above: no transport on a row.
    @ViewBuilder private func pocketRowMenu(_ pocket: Pocket) -> some View {
        Button { pocketNameDraft = pocket.name; renamingPocketId = pocket.id } label: { Label("Rename", systemImage: "pencil") }
            .accessibilityIdentifier("list-rename-\(pocket.id)")
        // Move to folder
        Menu {
            if pocket.folderId != nil {
                Button { collections.setPocketFolder(pocket.id, folderId: nil) } label: { Label("Top level", systemImage: "tray") }
                    .accessibilityIdentifier("move-top-\(pocket.id)")
            }
            ForEach(collections.foldersOrdered()) { f in
                Button { collections.setPocketFolder(pocket.id, folderId: f.id) } label: {
                    Label(f.name, systemImage: pocket.folderId == f.id ? "checkmark" : "folder")
                }
                .accessibilityIdentifier("move-to-\(f.id)-\(pocket.id)")
            }
            Divider()
            Button { showNewFolder = true } label: { Label("New folder…", systemImage: "folder.badge.plus") }
        } label: { Label("Move to folder", systemImage: "folder") }
            .accessibilityIdentifier("move-folder-\(pocket.id)")
        // Add as a pocket-ref into an existing playlist (the "nesting" add)
        if !collections.playlists.isEmpty {
            Menu {
                ForEach(collections.playlistsAZ) { pl in
                    Button {
                        collections.addPocketRef(pocket.id, toPlaylist: pl.id,
                                                 sequenceId: pl.sequences.first?.nodeId)
                    } label: { Label(pl.name, systemImage: "music.note.list") }
                }
            } label: { Label("Add to playlist…", systemImage: "music.note.list.badge.plus") }
                .accessibilityIdentifier("add-to-playlist-\(pocket.id)")
        }
        Button(role: .destructive) { deletingPocketId = pocket.id } label: { Label("Delete", systemImage: "trash") }
            .accessibilityIdentifier("list-delete-\(pocket.id)")
    }

    // MARK: - Toolbar + folder dialogs

    /// The collection SORT control — one tap picks Recently played / A–Z / Last updated,
    /// write-through-persisted in Settings. Applies to the User tab's collections and each
    /// Shared-tab source group's members.
    private var sortMenu: some View {
        Menu {
            ForEach(CollectionSortOrder.allCases) { order in
                Button {
                    settings.collectionSort = order
                    settings.persist()
                } label: {
                    Label(order.label,
                          systemImage: settings.collectionSort == order ? "checkmark" : order.systemImage)
                }
                .accessibilityIdentifier("collection-sort-\(order.rawValue)")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort collections")
        .accessibilityIdentifier("collection-sort-menu")
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { sortMenu }
        ToolbarItem(placement: .primaryAction) {
            Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                .help("Import a playlist or pocket export")
                .accessibilityIdentifier("import-playlist")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { newFolderName = ""; showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder")
                .accessibilityIdentifier("new-folder")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showNewPocket = true } label: { Image(systemName: "rectangle.stack") }
                .help("New pocket")
                .accessibilityIdentifier("new-pocket")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showNew = true } label: { Image(systemName: "plus") }
                .help("New playlist")
                .accessibilityIdentifier("new-playlist")
        }
    }

    private var folderDialogs: FolderDialogs {
        FolderDialogs(
            collections: collections,
            showNewFolder: $showNewFolder, newFolderName: $newFolderName,
            renamingFolderId: $renamingFolderId, folderNameDraft: $folderNameDraft,
            deletingFolderId: $deletingFolderId)
    }

    // MARK: - Collapse persistence

    private static let collapsedKey = "pdj.playlistFolders.collapsed"
    private static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }
    private func persistCollapsed() {
        UserDefaults.standard.set(Array(collapsed), forKey: PlaylistsView.collapsedKey)
    }
    /// A binding into `collapsed` for a folder's DisclosureGroup, persisting on change.
    private func folderExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                persistCollapsed()
            })
    }

    /// A binding into `expandedSources` for a Shared-tab source DisclosureGroup, persisting on
    /// change. INVERSE of `folderExpansion`: presence in the set = EXPANDED, so a source not yet
    /// touched (absent) reads as collapsed — the requested collapse-by-default.
    private func sourceExpansion(_ name: String) -> Binding<Bool> {
        Binding(
            get: { expandedSources.contains(name) },
            set: { expanded in
                if expanded { expandedSources.insert(name) } else { expandedSources.remove(name) }
                PlaylistSources.persistExpanded(expandedSources)
            })
    }
}

/// The folder create/rename/delete alerts, lifted out of `body` so the view's main
/// expression stays type-checkable. Holds only bindings + the store.
private struct FolderDialogs: ViewModifier {
    let collections: CollectionsStore
    @Binding var showNewFolder: Bool
    @Binding var newFolderName: String
    @Binding var renamingFolderId: String?
    @Binding var folderNameDraft: String
    @Binding var deletingFolderId: String?

    func body(content: Content) -> some View {
        content
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") { let n = newFolderName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.createFolder(n) }; newFolderName = "" }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            .alert("Rename folder", isPresented: Binding(get: { renamingFolderId != nil }, set: { if !$0 { renamingFolderId = nil } })) {
                TextField("Name", text: $folderNameDraft)
                Button("Save") {
                    if let id = renamingFolderId { let n = folderNameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renameFolder(id, n) } }
                    renamingFolderId = nil
                }
                Button("Cancel", role: .cancel) { renamingFolderId = nil }
            }
            .confirmationDialog("Delete this folder?", isPresented: Binding(get: { deletingFolderId != nil }, set: { if !$0 { deletingFolderId = nil } }), titleVisibility: .visible) {
                Button("Delete folder", role: .destructive) { if let id = deletingFolderId { collections.deleteFolder(id) }; deletingFolderId = nil }
                Button("Cancel", role: .cancel) { deletingFolderId = nil }
            } message: {
                Text("The folder's playlists and pockets move back to the top level. This can't be undone.")
            }
    }
}

/// Read-only detail for a source ("From your sources") playlist: its songs, with a
/// ▶ Play (realize → Setlist) and a "Duplicate as editable playlist" action.
struct IndexPlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(FavoritesStore.self) private var favorites
    @Environment(RowSelection.self) private var rowSelection
    let source: SourcePlaylist
    @Binding var path: NavigationPath
    @State private var ripBurn = CollectionRipBurnController()
    /// Per-collection sort/filter — its own `BrowseState` keyed by the collection id, so the sort
    /// and filters persist on-device PER collection (reusing the Browser's exact machinery).
    @State private var browse: BrowseState
    @State private var showSort = false
    @State private var showFilter = false
    /// The resolved rows, held as STATE rather than recomputed in `body`. `songs` used to be a
    /// computed property running the whole Browser pipeline over every member id, and `body`
    /// read it four times (both `.disabled`s, the footer count, the `ForEach`) — with the
    /// second body pass `.onAppear` forces, that was eight full resolves of a 3,650-id
    /// collection before the view settled. Now it resolves once per input change, in a `.task`
    /// that runs AFTER the first frame, so navigating in is immediate.
    @State private var resolved: [IndexSong] = []
    /// The resolved rows' ids, cached alongside `resolved`: `songs.map(\.id)` per tap /
    /// per drag was an O(26k) rebuild at each interaction on the huge collections.
    @State private var resolvedIds: [String] = []
    /// Nothing has resolved yet — the window is showing stored-order placeholders (or nothing).
    @State private var isResolving = true
    /// How many rows are currently rendered. See `RowWindow`.
    @State private var shown = RowWindow.page
    /// CRITIC-B guard (the PlaylistDetailView/PocketDetailView pattern): ▶/🔀 now awaits the
    /// detached 26k build before pushing, so the button stays live for hundreds of ms — a
    /// double-tap used to land TWO `path.append`s (a double-pushed Now Playing needing two
    /// back-pops). Reset in `onAppear` so popping back re-arms the next Play.
    @State private var nowPlayingPushed = false
    /// Whether this view is actually on screen. The deferred push must not fire from a screen
    /// the user already left: pop this detail mid-build and the stale `path.append` teleported
    /// the user into Now Playing from the home list ~1s later.
    @State private var isOnScreen = false

    init(source: SourcePlaylist, path: Binding<NavigationPath>) {
        self.source = source
        self._path = path
        // defaultKind .song: without it a first-ever open resolved once in the `.album`
        // default and again after the sheets' onAppear flipped the kind (see BrowseState.init).
        self._browse = State(initialValue: BrowseState(persistenceKey: "pdj.collection.\(source.id)",
                                                       defaultKind: .song))
    }

    /// The rows to render right now. Once `.task` has resolved, that is the answer. Before then
    /// — and ONLY when the sort/filter state can't reorder or drop anything — the collection's
    /// stored ids already ARE the display order, so the first page is painted straight from the
    /// catalog and the list is never blank. With a query, filter or sort active there is no
    /// honest placeholder, so it shows nothing until the real answer lands.
    private var songs: [IndexSong] {
        if !isResolving { return resolved }
        guard browse.isStoredOrder else { return [] }
        return source.songIds.prefix(shown).compactMap { app.songsById[$0] }
    }

    /// Re-resolve whenever the membership, the catalog, or the sort/filter state changes.
    private var resolveKey: String {
        "\(source.id)|\(source.songIds.count)|\(app.catalogRevision)|\(browse.resultsKey(app))"
            + "|\(browse.readTimeKey(collections: collections, favorites: favorites))"
    }

    /// An on-device duplicate of THIS source already exists (see `duplicate()`).
    private var hasDuplicate: Bool { collections.existingDuplicate(forSource: source) != nil }

    // MARK: Multi-select (copy/drag SOURCE only — song-id keys)

    private var selectionScope: String { "source-\(source.id)" }

    /// The display-ordered id universe: the cached resolved ids once the resolve landed,
    /// else the stored-order prefix the placeholder rows show.
    private func orderedIds() -> [String] {
        isResolving ? songs.map(\.id) : resolvedIds
    }
    private func selectionPayload() -> SongTransfer? {
        let ids = rowSelection.orderedSelection(in: orderedIds())
        guard !ids.isEmpty else { return nil }
        return SongTransfer.make(ids: ids, songsById: app.songsById)
    }
    private func dragPayload(for song: IndexSong) -> SongTransfer {
        rowSelection.payloadForRow(song.id, scope: selectionScope,
            single: SongTransfer.make(ids: [song.id], songsById: app.songsById))
    }

    var body: some View {
        List {
            Section {
                // `source.songIds.isEmpty`, not `songs.isEmpty`: an empty SOURCE is the real
                // "nothing to play" condition, and it is known without resolving anything —
                // so Play/Shuffle are never spuriously disabled during the resolve.
                Button { play() } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(source.songIds.isEmpty)
                    .accessibilityIdentifier("indexplaylist-play")
                Button { shufflePlay() } label: { Label("Shuffle", systemImage: "shuffle") }
                    .disabled(source.songIds.isEmpty)
                    .accessibilityIdentifier("indexplaylist-shuffle")
                // One duplicate per source, always: when a copy already exists (made here or
                // automatically by an "Add to…" into this playlist) this OPENS it rather
                // than minting a rival that follows the same source.
                Button { duplicate() } label: {
                    Label(hasDuplicate ? "Open editable copy" : "Duplicate as editable playlist",
                          systemImage: hasDuplicate ? "arrow.right.square" : "plus.square.on.square")
                }
                .accessibilityIdentifier("indexplaylist-duplicate")
                Button { convertToPocket() } label: { Label("Convert to pocket", systemImage: "rectangle.stack.badge.plus") }
                    .disabled(source.songIds.isEmpty)
                    .accessibilityIdentifier("indexplaylist-convert")
                CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forSource: source) }, noun: "playlist")
            } footer: {
                if isResolving {
                    Text("Resolving \(source.songIds.count) song\(source.songIds.count == 1 ? "" : "s") from \(source.sourceName)…")
                } else {
                    Text("\(resolved.count) of \(source.songIds.count) song\(source.songIds.count == 1 ? "" : "s") resolved from \(source.sourceName).")
                }
            }

            Section("Songs") {
                // With a sort/filter active the display order is unknowable before the
                // off-main resolve lands — paint skeleton rows instead of a blank section
                // so the push is instant for a 26k-song source (the footer narrates the
                // resolve). The stored-order fast path below is untouched.
                if isResolving && !browse.isStoredOrder {
                    ForEach(0..<min(source.songIds.count, RowWindow.page), id: \.self) { _ in
                        SkeletonSongRow()
                    }
                }
                let rows = songs
                ForEach(rows.prefix(shown)) { song in
                    VStack(spacing: 0) {
                        CollectionSongRow(song: song)
                            .selectableSongRow(id: song.id, scope: selectionScope,
                                               orderedIds: { orderedIds() },
                                               payload: { dragPayload(for: song) },
                                               onOpen: { path.append(song) })
                            .contextMenu {           // rows had no menu before — no fold conflict
                                Button { rowSelection.enterSelectMode(scope: selectionScope, initial: song.id) } label: {
                                    Label("Select", systemImage: "checklist")
                                }
                                .accessibilityIdentifier("select-source-song-\(song.id)")
                                Button { rowSelection.copyRowOrSelection(rowId: song.id, scope: selectionScope,
                                    single: SongTransfer.make(ids: [song.id], songsById: app.songsById)) } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .accessibilityIdentifier("copy-source-song-\(song.id)")
                            }
                        InlinePlayerSlot(songId: song.id)
                    }
                }
                RowWindowSentinel(total: rows.count, shown: $shown)
            }
        }
        .navigationTitle(source.name)
        .accessibilityIdentifier("indexplaylist-detail")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .collectionRipBurn(ripBurn)
        .collectionSortFilterToolbar(browse: browse, showSort: $showSort, showFilter: $showFilter,
                                     app: app, collections: collections)
        // Copy/drag SOURCE only — no drop target, no paste (write-back semantics deferred).
        .modifier(CollectionSelectionChrome(scope: selectionScope,
                                            pruneKey: "\(resolved.count)|\(resolveKey)",
                                            allIds: { orderedIds() },
                                            payload: { selectionPayload() },
                                            acceptDrop: nil))
        // Resolves AFTER the first frame, so the push animation is never blocked. `.task(id:)`
        // also auto-cancels a stale run when the sort/filter changes mid-resolve. The resolve
        // itself runs OFF the main actor (`sortedFilteredSongsAsync`) — for a 26k-song source
        // playlist the row construction + filter/sort pipeline is hundreds of ms, and running it
        // main-actor inside this .task stalled every interaction right after the push (the
        // windowed placeholder painted, then the UI froze while the "background" resolve ran on
        // the very thread it was deferred to protect).
        .task(id: resolveKey) {
            let full = await app.sortedFilteredSongsAsync(ids: source.songIds, browse: browse,
                                                          collections: collections, favorites: favorites)
            guard !Task.isCancelled else { return }
            resolved = full
            resolvedIds = full.map(\.id)
            isResolving = false
            MainThreadStallWatchdog.shared.marker("collection-open-resolved \(full.count)")
        }
        // Stall-watchdog attribution (+ settles WHICH surface the user is actually on —
        // this read-only source detail vs. the editable duplicate of the same name).
        .onAppear {
            nowPlayingPushed = false
            isOnScreen = true
            MainThreadStallWatchdog.shared.marker("collection-open-start IndexPlaylistDetailView \(source.id)")
        }
        .onDisappear {
            isOnScreen = false
            MainThreadStallWatchdog.shared.marker("back-nav IndexPlaylistDetailView")
        }
    }

    /// ▶ Play this read-only source playlist IN PLACE, literal order, via the same reserved
    /// Now-Playing setlist Shuffle uses. This used to go through `realize(songIds:)`, which
    /// (a) ran the whole realize engine over the list and (b) APPENDED a full persisted "take"
    /// setlist to the collections document — for "Favorite Songs" that meant a 26,821-track
    /// setlist written to disk on every ▶, which was most of the multi-second stall (and
    /// permanent document bloat). `playNow` upserts the one reserved setlist instead.
    private func play() {
        MainThreadStallWatchdog.shared.marker("play-tapped IndexPlaylistDetailView")
        let ids = source.songIds, name = source.name, originId = source.id
        Task {
            // The 26k-track build runs detached (see `playNowAsync`); the push waits for the
            // commit so the setlist exists when SetlistDetailView asks for it.
            await collections.playNowAsync(songIds: ids, name: name, shuffle: false,
                                           source: .playlist, originId: originId)
            pushNowPlayingIfAppropriate()
        }
    }
    /// Shuffle-play this read-only source playlist (e.g. an Apple Music user playlist) IN PLACE —
    /// no longer requires duplicating it into an editable playlist first. Reuses the same
    /// reserved Now-Playing setlist + autoplay path the editable playlist's Shuffle button uses.
    private func shufflePlay() {
        MainThreadStallWatchdog.shared.marker("shuffle-tapped IndexPlaylistDetailView")
        let ids = source.songIds, name = source.name, originId = source.id
        Task {
            await collections.playNowAsync(songIds: ids, name: name, shuffle: true,
                                           source: .playlist, originId: originId)
            pushNowPlayingIfAppropriate()
        }
    }

    /// The guarded Now-Playing push shared by ▶/🔀: at most one push per screen visit
    /// (double-tapping during the detached build must not stack two setlist screens — the
    /// second commit already restarted playback via the revision bump), and never from a
    /// screen the user has popped (a stale deferred push teleported them into Now Playing
    /// from wherever they'd navigated to).
    private func pushNowPlayingIfAppropriate() {
        guard isOnScreen, !nowPlayingPushed else { return }
        nowPlayingPushed = true
        path.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
    }
    private func duplicate() {
        // Provenance-stamped: the duplicate follows this source playlist as the catalog
        // refreshes (toggle/manual-sync live in the editable playlist's ⋯ menu).
        // FIND-OR-CREATE, not create: the Add-to sheet duplicates this same source
        // automatically when you add a song to it, so a second create here would leave two
        // playlists both claiming to follow this source. `duplicateForSource` is the single
        // primitive both paths share — tapping this when a copy already exists just opens it.
        let pl = collections.duplicateForSource(source)
        // Replace the read-only detail with the new editable one.
        path.removeLast()
        path.append(pl)
    }
    /// Convert this read-only source playlist (e.g. an Apple Music user playlist) into a new
    /// reusable pocket of its songs and jump straight into it.
    private func convertToPocket() {
        path.append(collections.convertToPocket(source: source))
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(FavoritesStore.self) private var favorites
    /// Optional like the other app-scoped services here: always injected by the app, but a preview
    /// or test host rendering this view standalone should degrade rather than trap.
    @Environment(PlaylistAppleMusicSync.self) private var playlistSync: PlaylistAppleMusicSync?
    @Environment(RowSelection.self) private var rowSelection
    let playlistId: String
    @Binding var path: NavigationPath
    /// Per-collection sort/filter (keyed by playlist id → remembered per playlist, on-device). Applies
    /// WITHIN each chapter to the song leaves; non-song nodes pin to the end while sorting/filtering.
    @State private var browse: BrowseState
    @State private var showSort = false
    @State private var showFilter = false
    @State private var newSeq = ""
    @State private var showNewSeq = false
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var renamingChapter: String?       // sequence nodeId being renamed
    @State private var chapterDraft = ""
    @State private var confirmingDelete = false
    @State private var showExporter = false
    @State private var exportDoc = PlaylistZipFile(data: Data())
    @State private var showFormatDialog = false
    @State private var showCSVExporter = false
    @State private var csvDoc = CSVFile(data: Data())
    @State private var renamingSetlistId: String?
    @State private var setlistNameDraft = ""
    @State private var deletingSetlistId: String?
    @State private var addingNoteChapter: String?     // sequence nodeId to add a text note to
    @State private var noteDraft = ""
    @State private var ripBurn = CollectionRipBurnController()
    /// CRITIC-B: true once we've pushed the reusable Now Playing setlist from HERE and not
    /// yet returned. A re-tap then only re-snapshots (playNow) instead of stacking a second
    /// live SetlistDetailView for the same reserved id. Cleared when this view reappears
    /// (the user popped back) so a fresh Play pushes again.
    @State private var nowPlayingPushed = false
    /// The deferred (post-await) push must not fire from a screen the user already popped —
    /// see IndexPlaylistDetailView.isOnScreen.
    @State private var isOnScreen = false
    /// Feedback for the manual "Sync from source now" action (nil = no alert showing).
    @State private var syncResult: String?
    /// How many nodes are rendered across ALL chapters — the `RowWindow` window over the
    /// FLATTENED node list (page 1 = the first 150 nodes regardless of chapter boundaries).
    /// Handing every node of a 26k-row duplicated playlist to the List made SwiftUI build
    /// identity + row chrome for all of them at open, and tear it all down on pop.
    @State private var shownNodes = RowWindow.page
    /// Per-chapter display order under an ACTIVE sort/filter, resolved OFF-main by
    /// `.task(id: chapterResolveKey)` (the sync `displayChildren` pipeline ran the whole
    /// Browser sort per chapter per body pass). Keyed by the chapter's nodeId; empty while
    /// the stored order is displayed (no sort/filter) or a resolve is in flight.
    @State private var resolvedChapters: [String: [PlaylistNode]] = [:]
    @State private var isResolvingChapters = false
    /// Total nodes in `resolvedChapters` — a cheap resolve-landed signal for the prune key.
    @State private var resolvedNodeCount = 0

    init(playlistId: String, path: Binding<NavigationPath>) {
        self.playlistId = playlistId
        self._path = path
        // defaultKind .song: same first-open double-resolve fix as IndexPlaylistDetailView.
        self._browse = State(initialValue: BrowseState(persistenceKey: "pdj.collection.\(playlistId)",
                                                       defaultKind: .song))
    }

    private var playlist: Playlist? { collections.playlist(playlistId) }
    private var setlists: [Setlist] { collections.setlists(forPlaylist: playlistId) }
    private var itemCount: Int { (playlist?.sequences ?? []).reduce(0) { $0 + ($1.children?.count ?? 0) } }

    // MARK: Multi-select (NODE-id keyed — several nodes may reference one song)

    private var selectionScope: String { "playlist-\(playlistId)" }

    /// Display-ordered selectable node ids across ALL chapters (range-select universe).
    /// Reads the RESOLVED per-chapter order (never re-running the sort pipeline inline —
    /// that made every ⌘A/range tap O(n log n) while a sort was active).
    private func displayedSongNodeIds() -> [String] {
        guard let playlist else { return [] }
        let isDefaultOrder = browse.sortKeys.isEmpty && browse.activeFilterCount == 0
        return playlist.sequences.flatMap { seq -> [String] in
            let children = seq.children ?? []
            let displayed = isDefaultOrder ? children : (resolvedChapters[seq.nodeId] ?? [])
            return displayed.compactMap { n in
                guard n.kind == .song, let sid = n.songId, app.songsById[sid] != nil else { return nil }
                return n.nodeId
            }
        }
    }

    /// Everything the per-chapter display order depends on: membership + names (`updatedAt`
    /// is stamped by every `mutatePlaylist`), the catalog, and the sort/filter state.
    private var chapterResolveKey: String {
        "\(playlistId)|\(playlist?.updatedAt ?? 0)|\(app.catalogRevision)|\(browse.resultsKey(app))"
            + "|\(browse.readTimeKey(collections: collections, favorites: favorites))"
    }
    /// Node ids → their song ids (payload translation), order-preserving.
    private func nodeSongIds(_ nodeIds: [String]) -> [String] {
        guard let playlist else { return [] }
        let byNode = Dictionary((playlist.sequences.flatMap { $0.children ?? [] })
            .compactMap { n in n.songId.map { (n.nodeId, $0) } }, uniquingKeysWith: { a, _ in a })
        return nodeIds.compactMap { byNode[$0] }
    }
    private func selectionPayload() -> SongTransfer? {
        let ids = nodeSongIds(rowSelection.orderedSelection(in: displayedSongNodeIds()))
        guard !ids.isEmpty else { return nil }
        return SongTransfer.make(ids: ids, songsById: app.songsById)
    }
    private func dragPayload(node: PlaylistNode, song: IndexSong) -> SongTransfer {
        rowSelection.payloadForRow(node.nodeId, scope: selectionScope,
                                   single: SongTransfer.make(ids: [song.id], songsById: app.songsById))
    }
    /// Drop/paste: dedup against every existing song node, land in the DEFAULT chapter
    /// (sequences[0] — AddTarget.sequenceId nil). Documented v1 behavior.
    private func acceptDrop(_ items: [SongTransfer]) -> Bool {
        // Studio ids resolve through studioLookup — never a bare prefix test (see the row drops).
        let ids = SongDrop.acceptableIds(items) { app.songsById[$0] != nil || collections.studioLookup?($0) != nil }
        guard !ids.isEmpty else { return false }
        return collections.addSongs(ids, to: AddTarget(kind: .playlist, id: playlistId)) > 0
    }

    var body: some View {
        List {
            if let playlist {
                Section {
                    let stats = collections.stats(forPlaylist: playlist)
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.list").foregroundStyle(Theme.accent)
                        Text(stats.summary).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                        Spacer()
                    }
                    .accessibilityIdentifier("playlist-stats")
                }
                let slices = chapterSlices(playlist)
                let totalNodes = slices.last.map { $0.start + $0.displayed.count } ?? 0
                ForEach(slices) { slice in
                    chapterSection(slice, chapterCount: playlist.sequences.count, totalNodes: totalNodes)
                }
                .onMove { from, to in collections.moveSequences(inPlaylist: playlistId, from: from, to: to) }

                if !setlists.isEmpty {
                    Section("Set lists") {
                        ForEach(setlists) { sl in setlistRow(sl) }
                        .onDelete { idx in idx.map { setlists[$0].id }.forEach(collections.deleteSetlist) }
                    }
                }
            }
        }
        .collectionSortFilterSheets(browse: browse, showSort: $showSort, showFilter: $showFilter,
                                    app: app, collections: collections)
        .navigationTitle(playlist?.name ?? "Playlist")
        .accessibilityIdentifier("playlist-detail")
        // Selection bar + whole-list drop target (→ default chapter) + paste registration.
        .modifier(CollectionSelectionChrome(scope: selectionScope,
                                            pruneKey: "\(itemCount)|\(resolvedNodeCount)|\(chapterResolveKey)",
                                            allIds: { displayedSongNodeIds() },
                                            payload: { selectionPayload() },
                                            acceptDrop: { acceptDrop($0) }))
        .scrollContentBackground(.hidden).background(Theme.bg)
        // Reappears when the user pops back from Now Playing — allow the next Play to push.
        .onAppear {
            nowPlayingPushed = false
            isOnScreen = true
            MainThreadStallWatchdog.shared.marker("collection-open-start PlaylistDetailView \(playlistId)")
        }
        .onDisappear {
            isOnScreen = false
            MainThreadStallWatchdog.shared.marker("back-nav PlaylistDetailView")
        }
        // OFF-main per-chapter sort/filter resolve. `.task(id:)` auto-cancels a stale run;
        // the default (stored-order) state clears the map and never resolves anything.
        .task(id: chapterResolveKey) {
            guard let playlist, !(browse.sortKeys.isEmpty && browse.activeFilterCount == 0) else {
                resolvedChapters = [:]; resolvedNodeCount = 0; isResolvingChapters = false
                return
            }
            isResolvingChapters = true
            var out: [String: [PlaylistNode]] = [:]
            for seq in playlist.sequences {
                out[seq.nodeId] = await displayChildrenAsync(seq.children ?? [])
                if Task.isCancelled { return }
            }
            resolvedChapters = out
            resolvedNodeCount = out.values.reduce(0) { $0 + $1.count }
            isResolvingChapters = false
            MainThreadStallWatchdog.shared.marker("collection-open-resolved \(resolvedNodeCount)")
        }
        // 📱/☁️ · ▶ · 🔀 · ⋯ — the SHARED `CollectionToolbar`. This screen is the one the owner
        // points at ("like in a playlist"), and it is now the same FOUR items the pocket screen and
        // the For You tile screens wear, from one definition. (It briefly carried a fifth, ▶▶ Play
        // All, which the owner removed — see `CollectionToolbar`.)
        .collectionToolbar(idPrefix: "playlist", noun: "playlist", canPlay: itemCount > 0,
                           play: { play(shuffle: $0) },
                           menuItems: { overflowMenu })
        .modifier(playlistAlerts)
        .alert("Sync from source", isPresented: syncResultShowing) {
            Button("OK") { syncResult = nil }
        } message: {
            Text(syncResult ?? "")
        }
        .collectionRipBurn(ripBurn)
        .confirmationDialog("Delete this playlist?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) {
                collections.deletePlaylist(playlistId)
                if !path.isEmpty { path.removeLast() }
            }
            .accessibilityIdentifier("delete-playlist-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also deletes its set lists. This can't be undone.")
        }
        .alert("Rename set list", isPresented: Binding(get: { renamingSetlistId != nil }, set: { if !$0 { renamingSetlistId = nil } })) {
            TextField("Name", text: $setlistNameDraft)
            Button("Save") {
                if let id = renamingSetlistId { let n = setlistNameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renameSetlist(id, n) } }
                renamingSetlistId = nil
            }
            Button("Cancel", role: .cancel) { renamingSetlistId = nil }
        }
        .confirmationDialog("Delete this set list?", isPresented: Binding(get: { deletingSetlistId != nil }, set: { if !$0 { deletingSetlistId = nil } }), titleVisibility: .visible) {
            Button("Delete set list", role: .destructive) { if let id = deletingSetlistId { collections.deleteSetlist(id) }; deletingSetlistId = nil }
            Button("Cancel", role: .cancel) { deletingSetlistId = nil }
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .pocketDJCollection,
                      defaultFilename: exportFilename) { _ in }
        .fileExporter(isPresented: $showCSVExporter, document: csvDoc, contentType: .commaSeparatedText,
                      defaultFilename: csvFilename) { _ in }
        .confirmationDialog("Export playlist", isPresented: $showFormatDialog, titleVisibility: .visible) {
            Button("PocketDJ (full metadata)") { exportPocketDJ() }.accessibilityIdentifier("export-format-pocketdj")
            Button("CSV (tracklist)") { exportCSV() }.accessibilityIdentifier("export-format-csv")
        } message: {
            Text("PocketDJ keeps everything (re-importable). CSV is a universal tracklist (title, artist, album, year, genre).")
        }
    }

    /// The ⋯ menu — everything beyond the primary Play/Shuffle, so the toolbar stays at 4 items
    /// and never overflows on compact-width iPhone (where a 7th item used to collapse the whole
    /// menu behind a nested system "More"). Lifted out of `body` for the type-checker, same
    /// medicine as `playlistAlerts` below.
    @ViewBuilder private var overflowMenu: some View {
        // Per-playlist sort + filter (folded into the ⋯ menu). Applies within each chapter.
        CollectionSortFilterMenuButtons(browse: browse, showSort: $showSort, showFilter: $showFilter)
        // Multi-select: arm Select mode for this list / paste the copied songs
        // (→ default chapter, deduped).
        Button { rowSelection.enterSelectMode(scope: selectionScope, initial: nil) } label: {
            Label("Select songs", systemImage: "checklist")
        }
        .accessibilityIdentifier("select-songs")
        Button { rowSelection.performPaste() } label: {
            Label("Paste songs", systemImage: "doc.on.clipboard")
        }
        .disabled(!SongPasteboard.hasSongs)
        .accessibilityIdentifier("paste-songs")
        Divider()
        Button { realizeToSetlist() } label: { Label("Make set list", systemImage: "list.bullet.clipboard") }
            .disabled(itemCount == 0)
            .accessibilityIdentifier("playlist-realize")
        Button { showNewSeq = true } label: { Label("Add chapter", systemImage: "plus.rectangle.on.rectangle") }
            .accessibilityIdentifier("add-chapter")
        #if os(iOS)
        EditButton().accessibilityIdentifier("edit-order")   // toggles drag-reorder of chapters + items
        #endif
        Divider()
        Button { nameDraft = playlist?.name ?? ""; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
            .accessibilityIdentifier("rename-playlist")
        Button { showFormatDialog = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            .accessibilityIdentifier("export-playlist")
        Button { convertToPocket() } label: { Label("Convert to pocket", systemImage: "rectangle.stack.badge.plus") }
            .disabled(itemCount == 0)
            .accessibilityIdentifier("convert-to-pocket")
        if playlist?.hasSource == true { sourceSyncMenuItems }
        // ALL playlists can push to Apple Music (create-if-absent), so the DIRECTION
        // control shows unconditionally (Levi 2026-07-29): "Get only" = never push —
        // the smart-playlist setting; "Off" = never sync either way.
        amSyncDirectionMenuItem
        amSyncNowMenuItem
        cleanOnlyMenuItem
        // For You's per-collection opt-out. It lives HERE as well as on the tile because the tile
        // is the surface that disappears when you use it — and because a collection only earns a
        // tile on a refresh that found something to add to it, so for a curated, finished crate
        // (the exact case this switch is for) this menu is usually the ONLY place it is reachable.
        CollectionRecsToggle(collectionId: playlistId, idPrefix: "playlist")
        Divider()
        CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.ripIds(forPlaylist: playlistId) }, noun: "playlist")
        Divider()
        Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
            .accessibilityIdentifier("delete-playlist")
    }

    /// New-chapter / rename-playlist / rename-chapter / add-note alerts, grouped into
    /// one modifier so the main `body` stays within the Swift type-checker's reach.
    private var playlistAlerts: PlaylistAlerts {
        PlaylistAlerts(
            collections: collections, playlistId: playlistId,
            showNewSeq: $showNewSeq, newSeq: $newSeq,
            renaming: $renaming, nameDraft: $nameDraft,
            renamingChapter: $renamingChapter, chapterDraft: $chapterDraft,
            addingNoteChapter: $addingNoteChapter, noteDraft: $noteDraft)
    }

    /// Presented-state for the sync-result alert (computed OUTSIDE body — see the
    /// PocketDetailView type-checker note; same medicine here).
    private var syncResultShowing: Binding<Bool> {
        Binding(get: { syncResult != nil }, set: { if !$0 { syncResult = nil } })
    }

    /// Per-playlist Apple Music sync DIRECTION (Levi 2026-07-29) — a Picker rendering as a
    /// submenu. "Get only" is the smart-playlist setting: the playlist keeps following its
    /// source (when linked) but is never pushed, so the write API can't mint duplicates of a
    /// smart playlist it can't see.
    @ViewBuilder private var amSyncDirectionMenuItem: some View {
        let directionBinding = Binding<CollectionSyncDirection>(
            get: { playlist?.amSyncDir ?? .both },
            set: { collections.setAMSyncDirection($0, forPlaylist: playlistId) })
        Picker(selection: directionBinding) {
            ForEach(CollectionSyncDirection.allCases, id: \.self) { d in
                Text(d.label).tag(d)
            }
        } label: {
            Label("Apple Music sync", systemImage: "arrow.up.arrow.down.circle")
        }
        .accessibilityIdentifier("playlist-am-sync-direction")
    }

    /// Clean-versions-only toggle (see `CleanOnly`): explicit songs play/rip their clean
    /// edition when one is resolved, else are skipped for this playlist.
    @ViewBuilder private var cleanOnlyMenuItem: some View {
        let b = Binding<Bool>(get: { playlist?.cleanOnly == true },
                              set: { collections.setCleanOnly($0, forPlaylist: playlistId) })
        Toggle(isOn: b) { Label("Clean versions only", systemImage: "c.square") }
            .accessibilityIdentifier("playlist-clean-only")
    }

    /// Send THIS playlist to Apple Music now, without waiting for (or sitting through) a whole-
    /// library pass. Writes a normal sync report, so it appears in Settings ▸ Apple Music's sync
    /// history like any other run. Hidden when the playlist is set never to push — offering an
    /// action the direction gate would refuse is just a lie with a spinner.
    @ViewBuilder private var amSyncNowMenuItem: some View {
        if let playlistSync, (playlist?.amSyncDir ?? .both).allowsPush {
            Button {
                Task { await playlistSync.syncCollection(playlistId: playlistId,
                                                         collections: collections, app: app) }
            } label: {
                // SAY WHY when it can't run. The sync engine is single-flight app-scoped, so a
                // full pass already in progress disables this — and a greyed control with no
                // explanation reads as broken. The label carries the reason instead.
                Label(playlistSync.isSyncing ? "Syncing… (Apple Music sync running)"
                                             : "Sync with Apple Music",
                      systemImage: playlistSync.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.up.circle")
            }
            .disabled(playlistSync.isSyncing)
            .accessibilityIdentifier("playlist-am-sync-now")
        }
    }

    /// Source-sync ⋯-menu items — shown only for a playlist duplicated from a source
    /// playlist (provenance present). Mirrors PocketDetailView's.
    @ViewBuilder private var sourceSyncMenuItems: some View {
        let syncBinding = Binding<Bool>(
            get: { playlist?.syncsWithSource ?? false },
            set: { collections.setSourceSyncEnabled($0, forPlaylist: playlistId) })
        Divider()
        Toggle(isOn: syncBinding) {
            Label("Sync with source", systemImage: "arrow.triangle.2.circlepath")
        }
        .accessibilityIdentifier("playlist-sync-toggle")
        Button(action: syncFromSourceNow) {
            Label("Sync from source now", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("playlist-sync-now")
    }

    /// Manual sync + user feedback (runs regardless of the auto-sync toggles).
    private func syncFromSourceNow() {
        if collections.syncPlaylistFromSourceNow(playlistId) {
            let source = playlist?.sourceName ?? "source"
            syncResult = "Updated from \(source)."
        } else if collections.sourcePlaylist(forPlaylist: playlistId) == nil {
            syncResult = "Source playlist not available (check the source is enabled and loaded)."
        } else {
            syncResult = "Already in sync."
        }
    }

    /// `<sanitized name>.playlist.pdjcollection` — the extension is written EXPLICITLY, NOT left to
    /// `.fileExporter` to append: for a custom exported type it doesn't reliably append on-device
    /// (it shipped bare `.playlist` files with no PocketDJ type). The `.pdjcollection` tail is
    /// com.pocketdj.collection, so the file is tap-to-open in Files/iMessage + selectable in the importer.
    private var exportFilename: String {
        let base = (playlist?.name ?? "playlist")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "playlist" : base).playlist.pdjcollection"
    }

    /// ▶ Play / 🔀 Shuffle: snapshot the resolved playlist into the reusable "Now Playing"
    /// setlist (literal order, or shuffled) and open it autostarting. CRITIC-B: if the nav
    /// stack ALREADY ends at the Now Playing setlist, don't push a second copy — just call
    /// playNow and let the on-screen restart (CRITIC-I) fire.
    private func play(shuffle: Bool) {
        MainThreadStallWatchdog.shared.marker(shuffle ? "shuffle-tapped PlaylistDetailView"
                                                      : "play-tapped PlaylistDetailView")
        Task {
            // The 26k-track build runs detached (see `playNowAsync`); everything after it
            // needs the committed setlist, so it stays in this task, in order.
            await collections.playNowAsync(playlistId: playlistId, shuffle: shuffle)
            // Donate the equivalent App Intent so Siri/Spotlight learn this habit.
            IntentDonations.playedPlaylist(collections.playlist(playlistId), shuffle: shuffle)
            if isOnScreen, !nowPlayingPushed {
                nowPlayingPushed = true
                path.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
            }
            // else: already on screen — playNow bumped the revision; the open SetlistDetailView
            // re-snapshots + restarts (CRITIC-I). No second push.
        }
    }

    /// 📋 Realize: the OLD ▶ behaviour — realize the template into a fresh frozen Setlist
    /// (a take, kept in history), push it WITHOUT autostart.
    private func realizeToSetlist() {
        if let sl = collections.realize(playlistId: playlistId) { path.append(sl) }
    }

    /// `<sanitized name>.csv` — the universal tracklist filename. The `.csv` is written EXPLICITLY
    /// (like `.pdjcollection` above): `.fileExporter` doesn't reliably append even a standard type's
    /// extension on-device, so it shipped bare, extension-less files.
    private var csvFilename: String {
        let base = (playlist?.name ?? "playlist")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "playlist" : base).csv"
    }

    private func exportPocketDJ() {
        if let data = try? collections.exportPlaylistZip(playlistId) {
            exportDoc = PlaylistZipFile(data: data); showExporter = true
        }
    }

    private func exportCSV() {
        if let data = collections.exportPlaylistCSV(playlistId) {
            csvDoc = CSVFile(data: data); showCSVExporter = true
        }
    }

    /// Convert this playlist into a new reusable pocket (its songs/albums/pockets become
    /// members, text cues become notes) and jump straight into it. Source playlist intact.
    private func convertToPocket() {
        if let pocket = collections.convertToPocket(playlistId: playlistId) { path.append(pocket) }
    }

    /// A chapter's children reordered by the per-collection sort/filter: SONG leaves ordered by the
    /// Browser pipeline (no-dateAdded songs last), then the non-song nodes (album/pocket/text/
    /// studio) appended — hidden while a FILTER is active (they carry no song fields to match).
    /// Dup-safe: several nodes for the same songId each consume one slot. The HEAVY half (row
    /// build + filter + sort) runs OFF-main via `sortedFilteredSongsAsync`; only the node
    /// re-mapping (O(chapter) dictionary hops) touches the main actor.
    private func displayChildrenAsync(_ children: [PlaylistNode]) async -> [PlaylistNode] {
        let songNodes = children.filter { $0.kind == .song }
        var nodesBySongId: [String: [PlaylistNode]] = [:]
        for n in songNodes { if let sid = n.songId { nodesBySongId[sid, default: []].append(n) } }
        let orderedSongs = await app.sortedFilteredSongsAsync(ids: songNodes.compactMap(\.songId),
                                                              browse: browse,
                                                              collections: collections,
                                                              favorites: favorites)
        var orderedSongNodes: [PlaylistNode] = []
        for song in orderedSongs {
            if var q = nodesBySongId[song.id], !q.isEmpty {
                orderedSongNodes.append(q.removeFirst())
                nodesBySongId[song.id] = q
            }
        }
        let tail = browse.activeFilterCount == 0 ? children.filter { $0.kind != .song } : []
        return orderedSongNodes + tail
    }

    /// One chapter's slice of the FLATTENED node window: its display order (stored children,
    /// or the resolved sorted order) + where it starts in the flattened list. O(chapters) per
    /// body pass — the arrays are CoW references, never copies.
    private struct ChapterSlice: Identifiable {
        let seq: PlaylistNode
        let displayed: [PlaylistNode]
        let start: Int
        /// Where this chapter's SKELETON rows start in a flattened list of every chapter's
        /// stored children — the in-flight-resolve stand-in for `start` (during a resolve all
        /// `displayed` are empty, so `start` is 0 for every chapter and can't budget anything).
        let skeletonStart: Int
        var id: String { seq.nodeId }
    }

    private func chapterSlices(_ playlist: Playlist) -> [ChapterSlice] {
        let isDefaultOrder = browse.sortKeys.isEmpty && browse.activeFilterCount == 0
        var start = 0
        var skeletonStart = 0
        return playlist.sequences.map { seq in
            let children = seq.children ?? []
            let displayed = isDefaultOrder ? children : (resolvedChapters[seq.nodeId] ?? [])
            defer { start += displayed.count; skeletonStart += children.count }
            return ChapterSlice(seq: seq, displayed: displayed, start: start,
                                skeletonStart: skeletonStart)
        }
    }

    @ViewBuilder private func chapterSection(_ slice: ChapterSlice, chapterCount: Int,
                                             totalNodes: Int) -> some View {
        let seq = slice.seq
        let children = seq.children ?? []
        // DEFAULT (no sort/filter): stored node order, with drag-reorder + up/down. SORTED/FILTERED:
        // the chapter's SONG leaves ordered by the Browser pipeline (no-dateAdded songs sort to the
        // END), with non-song nodes (album/pocket/text/studio) pinned last; reorder is disabled while
        // the display order ≠ the stored order. The stored order is never mutated.
        //
        // WINDOWED (`RowWindow` + sentinel — the IndexPlaylistDetailView pattern): the window is a
        // prefix of the FLATTENED node list, so this chapter renders `shownNodes - start` of its
        // rows and the sentinel lives in whichever chapter the window's edge falls in. A prefix
        // window keeps `.onMove`/`.onDelete` offsets identical to the stored child indices.
        let isDefaultOrder = browse.sortKeys.isEmpty && browse.activeFilterCount == 0
        let displayed = slice.displayed
        let localShown = RowWindow.localShown(start: slice.start, count: displayed.count,
                                              shown: shownNodes)
        Section {
            if children.isEmpty {
                Text("Empty chapter — add items from a song/album ▸ Add to…")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            // Sort/filter active but the off-main resolve hasn't landed: skeleton rows keep
            // the push instant instead of a blank section (same as the source-playlist detail).
            // BUDGETED out of the SHARED flattened window (`skeletonStart`), not per-section:
            // `RowWindow.page` per chapter let a 20-chapter playlist paint ~3,000 skeleton
            // rows in one List pass — reinstating the very open-stall the windowing kills.
            if !isDefaultOrder, isResolvingChapters, displayed.isEmpty, !children.isEmpty {
                let skeletons = RowWindow.localShown(start: slice.skeletonStart,
                                                     count: children.count, shown: shownNodes)
                ForEach(0..<skeletons, id: \.self) { _ in
                    SkeletonSongRow()
                }
            }
            ForEach(Array(displayed.prefix(localShown).enumerated()), id: \.element.nodeId) { idx, node in
                nodeRowWithMenu(node, idx: idx, count: displayed.count)
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) { collections.removeNode(node.nodeId, fromPlaylist: playlistId) }
                    }
                    .swipeActions(edge: .leading) {
                        if isDefaultOrder {
                            Button { collections.moveNodeUp(node.nodeId, inPlaylist: playlistId) } label: { Label("Up", systemImage: "arrow.up") }
                                .tint(Theme.accent)
                                .disabled(idx == 0)
                            Button { collections.moveNodeDown(node.nodeId, inPlaylist: playlistId) } label: { Label("Down", systemImage: "arrow.down") }
                                .tint(Theme.accent2)
                                .disabled(idx == displayed.count - 1)
                        }
                    }
            }
            .onMove { from, to in
                // Reorder only makes sense on the stored order — ignored while sorted/filtered.
                if isDefaultOrder { collections.moveNodes(inPlaylist: playlistId, sequenceId: seq.nodeId, from: from, to: to) }
            }
            .onDelete { offsets in
                offsets.map { displayed[$0].nodeId }.forEach { collections.removeNode($0, fromPlaylist: playlistId) }
            }
            if RowWindow.hostsSentinel(start: slice.start, count: displayed.count,
                                       shown: shownNodes, total: totalNodes) {
                RowWindowSentinel(total: totalNodes, shown: $shownNodes)
            }
            chapterActions(seq, chapterCount: chapterCount)
        } header: {
            HStack {
                Text(seq.name ?? "Chapter")
                Spacer()
                Text(collections.stats(forChapter: seq).summary)
                    .foregroundStyle(Theme.fgDim)
            }
            .accessibilityIdentifier("chapter-stats-\(seq.nodeId)")
        }
    }

    /// The per-chapter action rows (add note / rename / delete), extracted so the
    /// chapter section body stays within the type-checker's reach.
    @ViewBuilder private func chapterActions(_ seq: PlaylistNode, chapterCount: Int) -> some View {
        Button { addingNoteChapter = seq.nodeId; noteDraft = "" } label: {
            Label("Add note", systemImage: "text.badge.plus").font(.caption)
        }
        .accessibilityIdentifier("add-note-\(seq.nodeId)")
        Button { renamingChapter = seq.nodeId; chapterDraft = seq.name ?? "" } label: {
            Label("Rename chapter", systemImage: "pencil").font(.caption)
        }
        .accessibilityIdentifier("rename-chapter")
        if chapterCount > 1 {
            Button("Delete chapter", role: .destructive) { collections.removeSequence(seq.nodeId, fromPlaylist: playlistId) }
                .font(.caption)
        }
    }

    @ViewBuilder private func setlistRow(_ sl: Setlist) -> some View {
        NavigationLink(value: sl) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Theme.accent2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sl.name ?? "Set list").foregroundStyle(Theme.fg)
                    Text("\(sl.tracks.count) track\(sl.tracks.count == 1 ? "" : "s") · \(Fmt.longDuration(sl.totalMs))")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
            }
        }
        .accessibilityIdentifier("setlist-\(sl.id)")
        .contextMenu {
            Button { setlistNameDraft = sl.name ?? ""; renamingSetlistId = sl.id } label: { Label("Rename", systemImage: "pencil") }
                .accessibilityIdentifier("list-rename-\(sl.id)")
            Button(role: .destructive) { deletingSetlistId = sl.id } label: { Label("Delete", systemImage: "trash") }
                .accessibilityIdentifier("list-delete-\(sl.id)")
        }
    }

    /// The chapter row's context menu, folded into ONE menu per row: catalog-song rows get the
    /// "Force Apple Music sync" action PLUS the reorder items (via `forceSyncContextMenu`, since a
    /// second `.contextMenu` would shadow it); every other node gets just the reorder items.
    @ViewBuilder private func nodeRowWithMenu(_ node: PlaylistNode, idx: Int, count: Int) -> some View {
        if node.kind == .song, let id = node.songId, let song = app.songsById[id] {
            nodeRow(node)
                .forceSyncContextMenu(song: song, kind: .playlist, collectionId: playlistId) {
                    nodeReorderMenu(node, idx: idx, count: count)
                }
        } else {
            nodeRow(node)
                .contextMenu { nodeReorderMenu(node, idx: idx, count: count) }
        }
    }

    /// The Move up / Move down / Remove items shared by every chapter row's context menu.
    /// Catalog-song rows lead with the multi-select Select / Copy actions (folded into the
    /// SAME single menu via forceSyncContextMenu's extraMenuItems — the one-menu-per-row rule).
    @ViewBuilder private func nodeReorderMenu(_ node: PlaylistNode, idx: Int, count: Int) -> some View {
        if node.kind == .song, let sid = node.songId, let song = app.songsById[sid] {
            Button { rowSelection.enterSelectMode(scope: selectionScope, initial: node.nodeId) } label: {
                Label("Select", systemImage: "checklist")
            }
            .accessibilityIdentifier("select-node-\(node.nodeId)")
            Button { rowSelection.copyRowOrSelection(rowId: node.nodeId, scope: selectionScope,
                single: SongTransfer.make(ids: [song.id], songsById: app.songsById)) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("copy-node-\(node.nodeId)")
            Divider()
        }
        Button { collections.moveNodeUp(node.nodeId, inPlaylist: playlistId) } label: { Label("Move up", systemImage: "arrow.up") }
            .accessibilityIdentifier("move-up-\(node.nodeId)")
            .disabled(idx == 0)
        Button { collections.moveNodeDown(node.nodeId, inPlaylist: playlistId) } label: { Label("Move down", systemImage: "arrow.down") }
            .accessibilityIdentifier("move-down-\(node.nodeId)")
            .disabled(idx == count - 1)
        Button("Remove", role: .destructive) { collections.removeNode(node.nodeId, fromPlaylist: playlistId) }
    }

    @ViewBuilder private func nodeRow(_ node: PlaylistNode) -> some View {
        switch node.kind {
        case .song:
            if let id = node.songId, let song = app.songsById[id] {
                // One List row = the row content + (when this song is playing) the inline
                // panel BELOW it, both in a VStack so the panel's taps don't hit the row and
                // the 1:1 element↔row mapping `onMove`/`onDelete` rely on is preserved.
                // `selectableSongRow` replaces the old NavigationLink: plain tap still opens
                // the song (path.append), modifier-clicks / Select mode multi-select, and the
                // row is the drag source (selection-aware payload; NODE-id keyed). The
                // force-sync context menu is attached by `nodeRowWithMenu` (folded with the
                // chapter reorder items) — NOT here, or a second menu would shadow it.
                VStack(spacing: 0) {
                    CollectionSongRow(song: song, syncsToSource: playlist?.syncsWithSource ?? false,
                                      cleanOnlyCollection: playlist?.cleanOnly == true)
                        // reorderHost: this ForEach owns .onMove — drag source only on
                        // selected rows so plain row-drags keep reordering (macOS path).
                        .selectableSongRow(id: node.nodeId, scope: selectionScope,
                                           reorderHost: true,
                                           orderedIds: { displayedSongNodeIds() },
                                           payload: { dragPayload(node: node, song: song) },
                                           onOpen: { path.append(song) })
                    InlinePlayerSlot(songId: song.id)
                }
                // Clean-versions-only skip indicator: a row this playlist would SKIP at
                // ▶ Play (explicit, no clean edition) dims. Styling only — verification is
                // by queue count, and no new a11y id lands on a button container.
                .opacity(playlist?.cleanOnly == true && CleanOnly.isSkipped(song) ? 0.45 : 1)
            } else if let id = node.songId, StudioFactory.isStudioId(id) {
                // Performance items (sample/loop/sequence/instrumental) — studio-aware row with its
                // repeat count. Previously fell to "(missing song)" because they aren't in the catalog.
                StudioCollectionRow(
                    id: id,
                    repeatCount: CollectionMembership.normalizedRepeat(node.repeatCount),
                    onSetRepeat: { collections.setNodeRepeat(node.nodeId, count: $0, inPlaylist: playlistId) },
                    onRemove: { collections.removeNode(node.nodeId, fromPlaylist: playlistId) })
            } else { missing("song") }
        case .album:
            if let id = node.albumId, let album = app.albumsById[id] {
                NavigationLink(value: album) { Label(album.name, systemImage: "rectangle.stack").foregroundStyle(Theme.fg) }
            } else { missing("album") }
        case .pocket:
            if let id = node.pocketId, let pocket = collections.pocket(id) {
                NavigationLink(value: pocket) { Label(pocket.name, systemImage: "rectangle.stack.badge.play").foregroundStyle(Theme.accent2) }
            } else { missing("pocket") }
        case .text:
            Label(node.text ?? "", systemImage: "text.quote").foregroundStyle(Theme.fgDim).italic()
        case .sequence:
            Label(node.name ?? "Sub-chapter", systemImage: "list.bullet.indent").foregroundStyle(Theme.fgDim)
        }
    }

    private func missing(_ what: String) -> some View {
        Label("(missing \(what))", systemImage: "questionmark.circle").foregroundStyle(Theme.fgDim)
    }
}

/// The PlaylistDetailView text-entry alerts, lifted out of `body` so the view's main
/// expression stays type-checkable. Holds only bindings + the store.
private struct PlaylistAlerts: ViewModifier {
    let collections: CollectionsStore
    let playlistId: String
    @Binding var showNewSeq: Bool
    @Binding var newSeq: String
    @Binding var renaming: Bool
    @Binding var nameDraft: String
    @Binding var renamingChapter: String?
    @Binding var chapterDraft: String
    @Binding var addingNoteChapter: String?
    @Binding var noteDraft: String

    func body(content: Content) -> some View {
        content
            .alert("New Chapter", isPresented: $showNewSeq) {
                TextField("Name", text: $newSeq)
                Button("Add") { let n = newSeq.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.addSequence(n, toPlaylist: playlistId) }; newSeq = "" }
                Button("Cancel", role: .cancel) { newSeq = "" }
            }
            .alert("Rename playlist", isPresented: $renaming) {
                TextField("Name", text: $nameDraft)
                Button("Save") { let n = nameDraft.trimmingCharacters(in: .whitespaces); if !n.isEmpty { collections.renamePlaylist(playlistId, n) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename chapter", isPresented: Binding(get: { renamingChapter != nil }, set: { if !$0 { renamingChapter = nil } })) {
                TextField("Name", text: $chapterDraft)
                Button("Save") {
                    if let sid = renamingChapter {
                        let n = chapterDraft.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty { collections.renameSequence(sid, n, inPlaylist: playlistId) }
                    }
                    renamingChapter = nil
                }
                Button("Cancel", role: .cancel) { renamingChapter = nil }
            }
            .alert("Add note", isPresented: Binding(get: { addingNoteChapter != nil }, set: { if !$0 { addingNoteChapter = nil } })) {
                TextField("Note (mic break, sample, cue…)", text: $noteDraft)
                Button("Add") {
                    if let sid = addingNoteChapter {
                        let n = noteDraft.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty { collections.addText(n, toPlaylist: playlistId, sequenceId: sid) }
                    }
                    addingNoteChapter = nil
                }
                Button("Cancel", role: .cancel) { addingNoteChapter = nil }
            }
    }
}
