import SwiftUI

/// STREAMING MODE's "Buffering…" capsule — one look on every surface that shows a Mix deck or
/// the on-air track (Mix tab decks + auto-mix banner on iPhone/iPad/Mac/Vision, the TV mix
/// screens). Shown while a deck holds its playhead waiting for downloaded audio
/// (`MixEngine.isBuffering` / `onAirBuffering`); it disappears the moment playback resumes.
/// CarPlay can't host SwiftUI — its Mix tab says "Buffering…" in the live row's detail text.
/// The same capsule says "Loading stems…" while a deck's stem handover waits for its stems
/// (`MixEngine.stemHandover`) — the full mix plays on meanwhile.
struct MixBufferingBadge: View {
    /// TV reads from across the room: a larger type ramp there.
    var large = false
    var text = "Buffering…"
    var a11yId = "mix-buffering"

    var body: some View {
        HStack(spacing: large ? 12 : 5) {
            ProgressView()
                #if !os(tvOS)
                .controlSize(.mini)
                #endif
            Text(text)
                .font(large ? .callout.weight(.semibold) : .caption.weight(.medium))
        }
        .foregroundStyle(Theme.fgDim)
        .padding(.horizontal, large ? 16 : 8)
        .padding(.vertical, large ? 8 : 3)
        .background(Theme.bgOverlay, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text.replacingOccurrences(of: "…", with: ""))
        .accessibilityIdentifier(a11yId)
    }
}
