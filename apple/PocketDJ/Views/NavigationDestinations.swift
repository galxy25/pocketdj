import SwiftUI

/// THE navigation-destination registry for every PocketDJ `NavigationStack`.
///
/// WHY THIS EXISTS (the bug it makes unrepresentable). SwiftUI renders a pushed value as a
/// BLANK screen — a real stack entry, with a working back chevron and nothing in it — when
/// the stack it was pushed onto has no `navigationDestination(for:)` registered for that
/// value's type. Nothing warns you: the push "succeeds", every `waitForExistence` on the
/// pushed screen's identifier fails, and the user sees black.
///
/// That is exactly what shipped: `AppleMusicAlbumRef` was registered on the Shazam sheet's
/// stack only, and the two sheets that present `SongDetailView` (`NowPlayingPanel`,
/// `MixSessionsView`) wrapped it in a BARE `NavigationStack` with no destinations at all, so
/// its artist/album hotlinks had nowhere to push and had to route the long way round —
/// `dismiss()` + a cross-stack `IntentRoute` + a re-rooted path + a 450 ms staged append —
/// which lost the push and left the user on a blank screen (Levi, 2026-08-07: "click on the
/// album … takes you to a blank screen").
///
/// So: ONE modifier, applied by EVERY stack. A new destination type is added here once and
/// every stack in the app can push it. Registering a destination a given stack never pushes
/// costs nothing — the closure is only invoked when a value of that type is actually pushed.
///
/// Split into two halves purely to keep the SwiftUI type-checker fast; `pocketDJDestinations`
/// is the only entry point callers should use.
extension View {
    /// Register every value type any PocketDJ screen can push, on this stack.
    /// `path` is the stack's own `NavigationPath` binding — pushed detail views take it so
    /// THEY can push further (a direct `path.append`, the only mechanism that is reliable).
    func pocketDJDestinations(path: Binding<NavigationPath>) -> some View {
        self
            .pocketDJCatalogDestinations(path: path)
            .pocketDJCollectionDestinations(path: path)
            .pocketDJFeatureDestinations(path: path)
    }

    /// Catalog: album ▸ song ▸ artist, plus the Apple-Music album PREVIEW for an album that
    /// isn't (yet) in the catalog. `AppleMusicAlbumRef` being registered HERE rather than on
    /// one sheet is what makes "tap the album on a song you don't own" work everywhere.
    private func pocketDJCatalogDestinations(path: Binding<NavigationPath>) -> some View {
        self
            .navigationDestination(for: IndexAlbum.self) { AlbumDetailView(album: $0, path: path) }
            .navigationDestination(for: IndexSong.self) { SongDetailView(song: $0, path: path) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artistName: $0.name, path: path) }
            .navigationDestination(for: AppleMusicAlbumRef.self) { AlbumPreviewView(album: $0, path: path) }
    }

    /// Collections: pockets, playlists, source playlists, setlists (and the autoplay launch).
    private func pocketDJCollectionDestinations(path: Binding<NavigationPath>) -> some View {
        self
            .navigationDestination(for: Pocket.self) { PocketDetailView(pocketId: $0.id, path: path) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistId: $0.id, path: path) }
            .navigationDestination(for: SourcePlaylist.self) { IndexPlaylistDetailView(source: $0, path: path) }
            .navigationDestination(for: Setlist.self) { SetlistDetailView(setlistId: $0.id, path: path) }
            .navigationDestination(for: SetlistLaunch.self) {
                SetlistDetailView(setlistId: $0.setlistId, autoplay: $0.autoplay, path: path)
            }
    }

    /// Feature routes reached from the sidebar / deep links.
    private func pocketDJFeatureDestinations(path: Binding<NavigationPath>) -> some View {
        self
            .navigationDestination(for: MixSessionsRoute.self) { _ in MixSessionsView() }
            .navigationDestination(for: MixSessionRoute.self) { MixSessionDetailView(sessionId: $0.sessionId) }
            .navigationDestination(for: JukeboxRoute.self) { _ in JukeboxView() }
            .navigationDestination(for: JukeboxJoinRoute.self) { JukeboxJoinView(entry: $0.entry) }
            .navigationDestination(for: CollectorsPuzzleRoute.self) { _ in CollectorsPuzzleView(path: path) }
            .navigationDestination(for: MwFSessionRoute.self) { MusicWithFriendsSessionView(sessionId: $0.sessionId, path: path) }
            // For You tiles. `.new` gets its own screen (releases are ALBUMS, not songs); the
            // other two kinds are both ranked song lists and share one view.
            .navigationDestination(for: ForYouTileRoute.self) { route in
                switch route.kind {
                // Releases are ALBUMS, not songs, so `.new` gets its own screen.
                case .new: NewReleasesView(path: path)
                // `.zone` and `.collection` are both ranked catalog-song lists — and that now
                // includes a cloud-ranked zone, because the cloud answer is shaped into the same
                // frozen `zoneIds` this screen reads rather than into a screen of its own.
                default:   ForYouSongListView(route: route, path: path)
                }
            }
    }
}
