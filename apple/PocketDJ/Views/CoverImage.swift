import SwiftUI

/// Loads cover art from an ordered list of candidate URLs, falling back to the
/// next on any failure, and finally to a procedural-ish placeholder. Native
/// URLSession has no CORS restriction, so remote (iTunes) covers load directly.
struct CoverImage: View {
    let album: IndexAlbum
    var corner: CGFloat = Theme.radius

    // Optional env (read with the `?` form so CoverImage degrades gracefully — e.g. in a
    // preview — when the app graph isn't injected): the catalog (to find an album track's
    // catalog id) + the lazy streaming-art resolver.
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(AlbumArtworkStore.self) private var artStore: AlbumArtworkStore?

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .task(id: album.id) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgOverlay, Theme.bgRaised],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "opticaldisc")
                .font(.system(size: 26))
                .foregroundStyle(Theme.fgDim)
        }
    }

    private func load() async {
        // 1) Bundled candidates: self-hosted CDN thumbnail, then any iTunes remote cover.
        if await loadFirst(album.artCandidates) { return }
        // 2) Streaming fallback (lazy, on-display): when the album ships no usable cover but
        //    lives in a reachable streaming catalog, resolve its art via the provider using a
        //    track's catalog id. Memoized per-album in AlbumArtworkStore, so this fires at
        //    most once per on-screen album and never at launch.
        if let url = await streamingArtworkURL() {
            _ = await loadFirst([url])
        }
    }

    /// Resolve this album's streaming artwork URL via the injected resolver, passing the
    /// album's tracks that carry a catalog id as candidates. nil when the env isn't wired,
    /// no track has a catalog id, or the provider isn't ready / has no art.
    private func streamingArtworkURL() async -> URL? {
        guard let artStore, let app else { return nil }
        let candidates = album.trackList
            .compactMap { app.songsById[$0] }
            .filter { AlbumArtworkStore.hasCatalogID($0) }
        guard !candidates.isEmpty else { return nil }
        return await artStore.artworkURL(forAlbum: album.id, candidates: candidates)
    }

    /// Try each URL in order; on the first that decodes to an image, set it and return true.
    private func loadFirst(_ urls: [URL]) async -> Bool {
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
                if let img = PlatformImage(data: data) {
                    image = img
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }
}
