import SwiftUI

/// Loads cover art from an ordered list of candidate URLs, falling back to the
/// next on any failure, and finally to a procedural-ish placeholder. Native
/// URLSession has no CORS restriction, so remote (iTunes) covers load directly.
struct CoverImage: View {
    let album: IndexAlbum
    var corner: CGFloat = Theme.radius

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
        .task(id: album.id) { await load(album.artCandidates) }
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

    private func load(_ urls: [URL]) async {
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
                if let img = PlatformImage(data: data) {
                    image = img
                    return
                }
            } catch {
                continue
            }
        }
    }
}
