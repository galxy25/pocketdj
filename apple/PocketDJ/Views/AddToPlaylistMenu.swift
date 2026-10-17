import SwiftUI

/// "Add to Playlist" for EVERY item context menu (Levi 2026-10-16): a submenu whose first rows
/// are the Add sheet's own Suggested (rec engine) + Recent targets, up to five, each with the
/// sheet's ✓-when-member toggle — followed by "More…", which opens the full Add-to sheet with its search field focused at the BOTTOM, so
/// picking any other playlist is "More…" then type.
///
/// A native context menu can't host a text field (UIKit/AppKit menus are item lists), which is
/// why "More…" hands off to the sheet rather than growing a field inside the menu itself.
///
/// Fold this INTO an existing `.contextMenu {}` (it is a `Menu`, i.e. a submenu — never a second
/// `.contextMenu` modifier, see `ForceSyncMenu`). Presentation goes through the nearest
/// `.addToPlaylistHost()`, so rows need no sheet plumbing of their own.
struct AddToPlaylistMenu: View {
    @Environment(CollectionsStore.self) private var collections
    @Environment(AppModel.self) private var app
    @Environment(RecommendationService.self) private var recEngine: RecommendationService?
    @Environment(AddToPlaylistPresenter.self) private var presenter: AddToPlaylistPresenter?

    let item: AddToCollectionView.Item

    /// The quick rows: the Add sheet's own Suggested (rec engine) then Recent targets — the SAME
    /// `AddToActions` the sheet uses — extended to five.
    static let quickLimit = 5

    private var actions: AddToActions { AddToActions(item: item, collections: collections) }

    var body: some View {
        if supported {
            Menu {
                let targets = quickTargets
                ForEach(Array(targets.enumerated()), id: \.offset) { idx, target in
                    // A Toggle renders the menu's native checkmark — the sheet's ✓ for "already in
                    // here"; tapping a checked row removes, exactly like the sheet.
                    Toggle(isOn: Binding(get: { actions.isMember(target) },
                                         set: { _ in actions.toggle(target) })) {
                        Label(collections.lastTargetLabel(target) ?? "",
                              systemImage: target.kind == .pocket ? "rectangle.stack" : "music.note.list")
                    }
                    .accessibilityIdentifier("ctx-add-target-\(idx)")
                }
                if presenter != nil {
                    if !targets.isEmpty { Divider() }
                    Button { presenter?.present(item, searchFirst: true) } label: {
                        Label("More…", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("ctx-add-playlist-more")
                }
            } label: {
                Label("Add to Playlist", systemImage: "music.note.list.badge.plus")
            }
            .accessibilityIdentifier("ctx-add-to-playlist")
        }
    }

    /// Only CATALOG items: a Now Playing/queue row can carry an id the catalog doesn't resolve (a
    /// Discover hit not yet added, a studio take) and filing that would mint a dead playlist row.
    /// Studio items keep their own menus (their sheet carries a repeat stepper).
    private var supported: Bool {
        switch item {
        case .song(let s): return app.songsById[s] != nil
        case .album(let a): return app.albumsById[a] != nil
        case .songs(let ids): return !ids.isEmpty
        case .studio: return false
        }
    }

    /// Suggested first (song items only — the engine suggests per song, as in the sheet), then
    /// Recent, deduped by the shared filter, capped at five.
    private var quickTargets: [AddTarget] {
        let recent = actions.recentTargets(limit: Self.quickLimit)
        var wire: [RecCollectionSuggestionWire] = []
        if case .song(let s) = item, let rec = recEngine { wire = rec.cachedCollectionSuggestions(for: s) }
        let suggested = actions.suggestedTargets(wire, excluding: recent, limit: Self.quickLimit)
        return Array((suggested + recent).prefix(Self.quickLimit))
    }
}

/// The nearest host's presentation state. One per `.addToPlaylistHost()` — a host inside a
/// sheet/full-screen cover shadows the root's through the environment, so "More…" always
/// presents over whatever modal the menu was opened in (a root-level sheet can't).
@Observable @MainActor
final class AddToPlaylistPresenter {
    struct Request: Identifiable {
        let id = UUID()
        let item: AddToCollectionView.Item
        let searchFirst: Bool
    }
    var request: Request?

    func present(_ item: AddToCollectionView.Item, searchFirst: Bool = false) {
        request = Request(item: item, searchFirst: searchFirst)
    }
}

private struct AddToPlaylistHost: ViewModifier {
    @State private var presenter = AddToPlaylistPresenter()

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .sheet(item: $presenter.request) { r in
                AddToCollectionView(item: r.item, searchFirst: r.searchFirst)
            }
    }
}

extension View {
    /// Hosts the "Add to Playlist › More…" sheet for every `AddToPlaylistMenu` inside.
    /// Apply at the window root AND at the root of any sheet/cover that shows item menus.
    func addToPlaylistHost() -> some View { modifier(AddToPlaylistHost()) }
}
