import SwiftUI

/// Embedded YouTube playback via the official **youtube-ios-player-helper**
/// (`YTPlayerView`, a `WKWebView` wrapping the IFrame Player API). This is the
/// ToS-compliant way to play YouTube on iOS — we must NOT extract/download audio
/// or play the stream outside the official player.
///
/// COMPILES WITHOUT THE POD. The helper isn't linked yet (see project.yml note),
/// so this file is guarded by `canImport(YouTubeiOSPlayerHelper)`. Until the pod
/// is added, `YouTubePlayerView` renders a small placeholder telling the dev to
/// link it; the rest of the app (search, settings, account-link) builds and runs.
///
/// `playsinline: 1` keeps playback in-view rather than going fullscreen.
struct YouTubePlayerView: View {
    /// The YouTube videoId to load (e.g. from `StreamingTrack.providerTrackID`).
    let videoID: String
    /// Start position, seconds.
    var startSeconds: Float = 0

    var body: some View {
        #if canImport(YouTubeiOSPlayerHelper)
        YTPlayerRepresentable(videoID: videoID, startSeconds: startSeconds)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
        #else
        placeholder
        #endif
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.85))
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.red)
                Text("YouTube player not linked").font(.headline).foregroundStyle(.white)
                Text("Add the youtube-ios-player-helper Swift package to enable embedded playback. videoId: \(videoID)")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .accessibilityIdentifier("youtube-player-placeholder")
    }
}

#if canImport(YouTubeiOSPlayerHelper)
import YouTubeiOSPlayerHelper

#if os(iOS)
import UIKit

/// Bridges `YTPlayerView` (UIKit/WKWebView) into SwiftUI. Reuses a single player
/// instance and `cueVideoById:` on change rather than reloading — per the helper
/// guide's best practice.
struct YTPlayerRepresentable: UIViewRepresentable {
    let videoID: String
    let startSeconds: Float

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> YTPlayerView {
        let view = YTPlayerView()
        view.delegate = context.coordinator
        // playsinline + a clean chrome; modestbranding is ignored by newer API but harmless.
        let vars: [String: Any] = ["playsinline": 1, "rel": 0]
        view.load(withVideoId: videoID, playerVars: vars)
        context.coordinator.loadedID = videoID
        return view
    }

    func updateUIView(_ view: YTPlayerView, context: Context) {
        guard context.coordinator.loadedID != videoID else { return }
        view.cueVideo(byId: videoID, startSeconds: startSeconds)
        context.coordinator.loadedID = videoID
    }

    final class Coordinator: NSObject, YTPlayerViewDelegate {
        var loadedID: String?
        func playerView(_ playerView: YTPlayerView, didChangeTo state: YTPlayerState) {
            // Hook for future PlayerEngine integration (out of scope here).
        }
    }
}
#else
// macOS: YTPlayerView is iOS-only. Fall back to opening in the system browser
// or a WKWebView-based embed could be added later; keep the build green.
struct YTPlayerRepresentable: View {
    let videoID: String
    let startSeconds: Float
    var body: some View {
        Link("Open in YouTube",
             destination: URL(string: "https://www.youtube.com/watch?v=\(videoID)")!)
    }
}
#endif
#endif
