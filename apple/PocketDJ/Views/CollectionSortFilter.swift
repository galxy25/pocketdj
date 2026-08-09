import SwiftUI

/// Reusable per-collection SORT + FILTER controls for a collection detail view's song list. Adds the
/// sort + filter toolbar buttons (matching the Browser), presents the SHARED `SortSheet`/`FilterSheet`
/// bound to the collection's own `BrowseState`, forces song-kind, and persists on sheet dismiss.
///
/// The owning view holds the `BrowseState` (keyed `"pdj.collection.<id>"`), so sort + filters are
/// remembered on-device PER collection — and it derives its displayed songs via
/// `AppModel.sortedFilteredSongs(ids:browse:collections:favorites:)`, which runs the exact Browser
/// pipeline on the collection's own song subset. The underlying stored order is never mutated.
/// The SHEETS + song-kind + persistence half — reusable whether the sort/filter triggers live in a
/// toolbar (source-playlist detail) or folded into a ⋯ Menu (pocket detail, whose toolbar is full).
struct CollectionSortFilterSheets: ViewModifier {
    @Bindable var browse: BrowseState
    @Binding var showSort: Bool
    @Binding var showFilter: Bool
    let app: AppModel
    let collections: CollectionsStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showSort) { SortSheet(browse: browse) }
            .sheet(isPresented: $showFilter) { FilterSheet(browse: browse, app: app, collections: collections) }
            // Collections are song lists — pin the field set to songs.
            .onAppear { browse.kind = .song }
            // The "Plays" sort is offered here too (same field set), so this state needs the same
            // play-count snapshot the Browser gets — without it the option would be inert.
            .playCountsFeed(browse)
            // Persist the collection's sort/filter when either sheet closes (device-local per id).
            .onChange(of: showSort) { if !showSort { browse.persist() } }
            .onChange(of: showFilter) { if !showFilter { browse.persist() } }
    }
}

/// Toolbar variant — two toolbar buttons + the sheets. For a detail view that has room in its
/// toolbar (e.g. the source-playlist detail, which had none).
struct CollectionSortFilterToolbar: ViewModifier {
    @Bindable var browse: BrowseState
    @Binding var showSort: Bool
    @Binding var showFilter: Bool
    let app: AppModel
    let collections: CollectionsStore

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showSort = true } label: { Image(systemName: "arrow.up.arrow.down") }
                        .help("Sort")
                        .accessibilityIdentifier("collection-sort")
                    Button { showFilter = true } label: {
                        Image(systemName: browse.activeFilterCount > 0
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .help("Filter")
                    .accessibilityIdentifier("collection-filter")
                }
            }
            .modifier(CollectionSortFilterSheets(browse: browse, showSort: $showSort,
                                                 showFilter: $showFilter, app: app, collections: collections))
    }
}

extension View {
    /// Attach the per-collection sort/filter TOOLBAR + sheets. `browse` must be a `BrowseState`
    /// keyed per collection (`"pdj.collection.<id>"`) so state is remembered per collection.
    func collectionSortFilterToolbar(browse: BrowseState, showSort: Binding<Bool>, showFilter: Binding<Bool>,
                                     app: AppModel, collections: CollectionsStore) -> some View {
        modifier(CollectionSortFilterToolbar(browse: browse, showSort: showSort, showFilter: showFilter,
                                             app: app, collections: collections))
    }

    /// Attach ONLY the sheets (+ song-kind + persistence) — for a view that triggers sort/filter
    /// from its OWN controls (e.g. folded into a full ⋯ Menu).
    func collectionSortFilterSheets(browse: BrowseState, showSort: Binding<Bool>, showFilter: Binding<Bool>,
                                    app: AppModel, collections: CollectionsStore) -> some View {
        modifier(CollectionSortFilterSheets(browse: browse, showSort: showSort, showFilter: showFilter,
                                            app: app, collections: collections))
    }
}

/// Reusable sort + filter buttons for folding into an existing ⋯ Menu (the pocket detail's).
struct CollectionSortFilterMenuButtons: View {
    @Bindable var browse: BrowseState
    @Binding var showSort: Bool
    @Binding var showFilter: Bool
    var body: some View {
        Button { showSort = true } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .accessibilityIdentifier("collection-sort")
        Button { showFilter = true } label: {
            Label(browse.activeFilterCount > 0 ? "Filter (\(browse.activeFilterCount))" : "Filter",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("collection-filter")
    }
}
