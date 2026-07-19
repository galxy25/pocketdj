import SwiftUI
import UniformTypeIdentifiers

/// Collections — playlists (ordered chapters) and pockets (reusable groupings), both
/// organized into optional collapsible FOLDERS (folders are heterogeneous: they hold
/// BOTH playlists and pockets). Your editable collections render ABOVE the read-only
/// "From your sources" index playlists. The body is factored into small helper subviews
/// so the Swift type-checker never times out.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(IntentServices.self) private var intents
    @Binding var path: NavigationPath
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

    private var indexPlaylists: [SourcePlaylist] { app.indexPlaylists }

    /// The trimmed search term; empty ⇒ not searching (the folder hierarchy shows as normal).
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// Case- and diacritic-insensitive substring match of the live query against `name`.
    private func matchesQuery(_ name: String) -> Bool {
        name.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // Filtered, name-ordered result lists — computed only while searching. Search FLATTENS
    // the folder hierarchy: a match surfaces regardless of which folder holds it, so finding
    // a playlist by name never means expanding folders first.
    private var matchingPlaylists: [Playlist] {
        collections.playlists.filter { matchesQuery($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var matchingPockets: [Pocket] {
        collections.pockets.filter { matchesQuery($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var matchingSources: [SourcePlaylist] {
        indexPlaylists.filter { matchesQuery($0.name) }
    }
    private var hasAnyMatch: Bool {
        !matchingPlaylists.isEmpty || !matchingPockets.isEmpty || !matchingSources.isEmpty
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
            if collections.playlists.isEmpty && collections.pockets.isEmpty && indexPlaylists.isEmpty {
                emptyState
            } else {
                List {
                    if isSearching {
                        searchResultsSections
                    } else {
                        yourPlaylistsSection
                        yourPocketsSection
                        ForEach(collections.foldersOrdered()) { folder in
                            folderSection(folder)
                        }
                        sourcesSection
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .searchable(text: $query, prompt: "Search playlists and pockets")
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

    // MARK: - Sections

    private var emptyState: some View {
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
    }

    /// YOUR (editable) top-level PLAYLISTS — those NOT in any folder. Own header, distinct
    /// from pockets and from the read-only "From your sources" section. Rendered first.
    @ViewBuilder private var yourPlaylistsSection: some View {
        let top = collections.playlists(inFolder: nil)
        Section("Your playlists") {
            if collections.playlists.isEmpty {
                Text("No playlists yet — tap + to create one.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            } else if top.isEmpty {
                Text("All your playlists are in folders below.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            ForEach(top) { pl in playlistRow(pl) }
        }
    }

    /// YOUR top-level POCKETS — those NOT in any folder. A SEPARATE section header from your
    /// playlists. Hidden entirely when you have no pockets at all (no empty "Pockets" header).
    @ViewBuilder private var yourPocketsSection: some View {
        if !collections.pockets.isEmpty {
            let top = collections.pockets(inFolder: nil)
            Section("Pockets") {
                if top.isEmpty {
                    Text("All your pockets are in folders below.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
                ForEach(top) { pk in pocketRow(pk) }
            }
        }
    }

    /// One collapsible FOLDER (flat) of playlists AND pockets, name-ordered. Collapse state persists.
    @ViewBuilder private func folderSection(_ folder: PlaylistFolder) -> some View {
        let plMembers = collections.playlists(inFolder: folder.id)
        let pkMembers = collections.pockets(inFolder: folder.id)
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

    /// The read-only "From your sources" section, now rendered LAST (below your collections).
    @ViewBuilder private var sourcesSection: some View {
        if !indexPlaylists.isEmpty {
            Section {
                ForEach(indexPlaylists) { sp in sourceRow(sp) }
            } header: {
                Text("From your sources")
            } footer: {
                Text("Read-only playlists from your enabled sources. Play one, or duplicate it into an editable playlist.")
            }
        }
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
        if !hasAnyMatch {
            Section {
                ContentUnavailableView.search(text: trimmedQuery)
                    .accessibilityIdentifier("playlists-search-empty")
            }
        } else {
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
            if !matchingSources.isEmpty {
                Section("From your sources") {
                    ForEach(matchingSources) { sp in sourceRow(sp) }
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
                    let stats = collections.catalog().stats(forPlaylist: pl)
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
    }

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
                    let stats = collections.catalog().stats(forPocket: pocket.id)
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
    }

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
                ForEach(collections.playlists) { pl in
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

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
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
    let source: SourcePlaylist
    @Binding var path: NavigationPath
    @State private var ripBurn = CollectionRipBurnController()

    private var songs: [IndexSong] { source.songIds.compactMap { app.songsById[$0] } }

    var body: some View {
        List {
            Section {
                Button { play() } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(songs.isEmpty)
                    .accessibilityIdentifier("indexplaylist-play")
                Button { shufflePlay() } label: { Label("Shuffle", systemImage: "shuffle") }
                    .disabled(songs.isEmpty)
                    .accessibilityIdentifier("indexplaylist-shuffle")
                Button { duplicate() } label: { Label("Duplicate as editable playlist", systemImage: "plus.square.on.square") }
                    .accessibilityIdentifier("indexplaylist-duplicate")
                Button { convertToPocket() } label: { Label("Convert to pocket", systemImage: "rectangle.stack.badge.plus") }
                    .disabled(source.songIds.isEmpty)
                    .accessibilityIdentifier("indexplaylist-convert")
                CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forSource: source) }, noun: "playlist")
            } footer: {
                Text("\(songs.count) of \(source.songIds.count) song\(source.songIds.count == 1 ? "" : "s") resolved from \(source.sourceName).")
            }

            Section("Songs") {
                ForEach(songs) { song in
                    VStack(spacing: 0) {
                        NavigationLink(value: song) { CollectionSongRow(song: song) }
                        InlinePlayerSlot(songId: song.id)
                    }
                }
            }
        }
        .navigationTitle(source.name)
        .accessibilityIdentifier("indexplaylist-detail")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .collectionRipBurn(ripBurn)
    }

    private func play() {
        if let sl = collections.realize(songIds: source.songIds, name: source.name) { path.append(sl) }
    }
    /// Shuffle-play this read-only source playlist (e.g. an Apple Music user playlist) IN PLACE —
    /// no longer requires duplicating it into an editable playlist first. Reuses the same
    /// reserved Now-Playing setlist + autoplay path the editable playlist's Shuffle button uses.
    private func shufflePlay() {
        collections.playNow(songIds: source.songIds, name: source.name, shuffle: true, source: .playlist,
                            originId: source.id)
        path.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
    }
    private func duplicate() {
        // Provenance-stamped: the duplicate follows this source playlist as the catalog
        // refreshes (toggle/manual-sync live in the editable playlist's ⋯ menu).
        let pl = collections.createPlaylist(source.name, songIds: source.songIds, source: source)
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
    let playlistId: String
    @Binding var path: NavigationPath
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
    /// Feedback for the manual "Sync from source now" action (nil = no alert showing).
    @State private var syncResult: String?

    private var playlist: Playlist? { collections.playlist(playlistId) }
    private var setlists: [Setlist] { collections.setlists(forPlaylist: playlistId) }
    private var itemCount: Int { (playlist?.sequences ?? []).reduce(0) { $0 + ($1.children?.count ?? 0) } }

    var body: some View {
        List {
            if let playlist {
                Section {
                    let stats = collections.catalog().stats(forPlaylist: playlist)
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.list").foregroundStyle(Theme.accent)
                        Text(stats.summary).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                        Spacer()
                    }
                    .accessibilityIdentifier("playlist-stats")
                }
                ForEach(playlist.sequences) { seq in
                    chapterSection(seq, chapterCount: playlist.sequences.count)
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
        .navigationTitle(playlist?.name ?? "Playlist")
        .accessibilityIdentifier("playlist-detail")
        .scrollContentBackground(.hidden).background(Theme.bg)
        // Reappears when the user pops back from Now Playing — allow the next Play to push.
        .onAppear { nowPlayingPushed = false }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PlaybackModeToggle()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { play(shuffle: false) } label: { Label("Play", systemImage: "play.fill") }
                    .help("Play this playlist now")
                    .disabled(itemCount == 0)
                    .accessibilityIdentifier("playlist-play")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { play(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .help("Shuffle-play this playlist now")
                    .disabled(itemCount == 0)
                    .accessibilityIdentifier("playlist-shuffle")
            }
            // The ⋯ menu holds everything beyond the primary Play/Shuffle so the toolbar
            // stays at 4 items and never overflows on compact-width iPhone (where a 7th
            // item used to collapse the whole menu behind a nested system "More").
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
                    Divider()
                    CollectionRipBurnButtons(controller: ripBurn, songIds: { collections.songIds(forPlaylist: playlistId) }, noun: "playlist")
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
                        .accessibilityIdentifier("delete-playlist")
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("playlist-menu")
            }
        }
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
        collections.playNow(playlistId: playlistId, shuffle: shuffle)
        // Donate the equivalent App Intent so Siri/Spotlight learn this habit.
        IntentDonations.playedPlaylist(collections.playlist(playlistId), shuffle: shuffle)
        if !nowPlayingPushed {
            nowPlayingPushed = true
            path.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
        }
        // else: already on screen — playNow bumped the revision; the open SetlistDetailView
        // re-snapshots + restarts (CRITIC-I). No second push.
    }

    /// 📋 Realize: the OLD ▶ behaviour — realize the template into a fresh frozen Setlist
    /// (a take, kept in history), push it WITHOUT autostart.
    private func realizeToSetlist() {
        if let sl = collections.realize(playlistId: playlistId) { path.append(sl) }
    }

    /// `<sanitized name>.csv` — the universal tracklist filename.
    private var csvFilename: String {
        let base = (playlist?.name ?? "playlist")
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "playlist" : base
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

    @ViewBuilder private func chapterSection(_ seq: PlaylistNode, chapterCount: Int) -> some View {
        let children = seq.children ?? []
        Section {
            if children.isEmpty {
                Text("Empty chapter — add items from a song/album ▸ Add to…")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            ForEach(Array(children.enumerated()), id: \.element.nodeId) { idx, node in
                nodeRow(node)
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) { collections.removeNode(node.nodeId, fromPlaylist: playlistId) }
                    }
                    .swipeActions(edge: .leading) {
                        Button { collections.moveNodeUp(node.nodeId, inPlaylist: playlistId) } label: { Label("Up", systemImage: "arrow.up") }
                            .tint(Theme.accent)
                            .disabled(idx == 0)
                        Button { collections.moveNodeDown(node.nodeId, inPlaylist: playlistId) } label: { Label("Down", systemImage: "arrow.down") }
                            .tint(Theme.accent2)
                            .disabled(idx == children.count - 1)
                    }
                    .contextMenu {
                        Button { collections.moveNodeUp(node.nodeId, inPlaylist: playlistId) } label: { Label("Move up", systemImage: "arrow.up") }
                            .accessibilityIdentifier("move-up-\(node.nodeId)")
                            .disabled(idx == 0)
                        Button { collections.moveNodeDown(node.nodeId, inPlaylist: playlistId) } label: { Label("Move down", systemImage: "arrow.down") }
                            .accessibilityIdentifier("move-down-\(node.nodeId)")
                            .disabled(idx == children.count - 1)
                        Button("Remove", role: .destructive) { collections.removeNode(node.nodeId, fromPlaylist: playlistId) }
                    }
            }
            .onMove { from, to in
                collections.moveNodes(inPlaylist: playlistId, sequenceId: seq.nodeId, from: from, to: to)
            }
            .onDelete { offsets in
                offsets.map { children[$0].nodeId }.forEach { collections.removeNode($0, fromPlaylist: playlistId) }
            }
            chapterActions(seq, chapterCount: chapterCount)
        } header: {
            HStack {
                Text(seq.name ?? "Chapter")
                Spacer()
                Text(collections.catalog().stats(forChapter: seq).summary)
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
                    Text("\(sl.tracks.count) track\(sl.tracks.count == 1 ? "" : "s") · \(Fmt.duration(sl.totalMs))")
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

    @ViewBuilder private func nodeRow(_ node: PlaylistNode) -> some View {
        switch node.kind {
        case .song:
            if let id = node.songId, let song = app.songsById[id] {
                // One List row = nav link + (when this song is playing) the inline panel
                // BELOW it, both in a VStack so the panel's taps don't hit the link and the
                // 1:1 element↔row mapping `onMove`/`onDelete` rely on is preserved.
                VStack(spacing: 0) {
                    NavigationLink(value: song) { CollectionSongRow(song: song) }
                    InlinePlayerSlot(songId: song.id)
                }
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
