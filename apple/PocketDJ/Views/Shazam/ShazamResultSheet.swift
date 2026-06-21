import SwiftUI

/// Presents a Shazam recognition result. An in-catalog hit offers a deep link into
/// the existing `SongDetailView` (via `NavigationLink(value: IndexSong)`, the
/// destination already registered in `RootView`); a not-in-catalog hit shows the
/// recognized metadata and, when an `appleMusicID` is present, notes that a linked
/// Apple Music account could play it (the optional `SongRecognizer` bridge).
struct ShazamResultSheet: View {
    let match: ShazamMatch
    /// Called when the user dismisses (the button resets the recognizer).
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.bg.ignoresSafeArea())
                .navigationTitle("Heard it")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss(); onDone() }
                    }
                }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder private var content: some View {
        switch match {
        case .inCatalog(let song, let info):
            VStack(alignment: .leading, spacing: 16) {
                artwork(info.artworkURL)
                Text(song.name).font(.title2.bold()).foregroundStyle(Theme.fg)
                Text(song.artist).font(.headline).foregroundStyle(Theme.fgDim)
                Label("In your crate", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                NavigationLink(value: song) {
                    Label("Open song", systemImage: "chevron.right.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }

        case .notInCatalog(let info):
            VStack(alignment: .leading, spacing: 16) {
                artwork(info.artworkURL)
                Text(info.title ?? "Unknown title").font(.title2.bold()).foregroundStyle(Theme.fg)
                Text(info.artist ?? "Unknown artist").font(.headline).foregroundStyle(Theme.fgDim)
                Label("Not in your crate", systemImage: "questionmark.circle")
                    .foregroundStyle(Theme.fgDim)
                if info.appleMusicID != nil {
                    Text("A linked Apple Music account can play this.")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func artwork(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Theme.bgRaised)
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.bgRaised)
                .frame(width: 96, height: 96)
                .overlay(Image(systemName: "music.note").foregroundStyle(Theme.fgDim))
        }
    }
}
