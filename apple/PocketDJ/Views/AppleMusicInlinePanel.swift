import SwiftUI

/// The inline slide-out player shown below the now-playing row when APPLE MUSIC streaming
/// is the active backend. It mirrors the rip path's `InlinePlayerPanel` look + the same
/// hard-won macOS hit-testing rules (borderless buttons, NO container accessibility id, a
/// non-`@Observable` time source sampled on a `TimelineView` so the position ticks don't
/// re-lay-out the control buttons and drop their clicks), but:
///   • play/pause + stop delegate to the `PlaybackCoordinator` (→ `ApplicationMusicPlayer`),
///   • there is NO waveform (Apple Music streaming has none) — just a position scrubber,
///   • a small "via Apple Music" badge tells the user which backend is playing.
///
/// The rip path's panel is untouched; this is a parallel, backend-specific panel selected by
/// `InlinePlayerSlot`. It carries NO accessibility id on its container (a container id
/// propagates to every child on macOS and clobbers their ids), matching the rip panel.
struct AppleMusicInlinePanel: View {
    @Environment(PlaybackCoordinator.self) private var coordinator
    @State private var collapsed = false

    private var now: AppleMusicPlaybackProvider.NowPlaying? { coordinator.appleMusic.nowPlaying }

    var body: some View {
        if let now {
            VStack(spacing: 8) {
                header(now)
                if !collapsed { AppleMusicScrubber() }
            }
            .padding(10)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
                    .allowsHitTesting(false)   // let clicks reach the controls beneath
            )
            .padding(.vertical, 4)
        }
    }

    /// Header: play/pause · title/artist · "via Apple Music" · collapse · close. Same
    /// `.buttonStyle(.borderless)` + stable-id rules as the rip panel.
    private func header(_ now: AppleMusicPlaybackProvider.NowPlaying) -> some View {
        HStack(spacing: 10) {
            Button { coordinator.togglePlayPause() } label: {
                Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill").font(.body)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("am-player-toggle")

            VStack(alignment: .leading, spacing: 1) {
                Text(now.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(now.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            Text(PlaybackBackend.appleMusic.viaLabel)
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent2)
                .accessibilityIdentifier("am-player-via")

            Button { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down").font(.caption)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("am-player-chevron")

            Button { coordinator.stop() } label: {
                Image(systemName: "xmark").font(.caption)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("am-player-close")
        }
    }
}

/// The position scrubber for Apple Music streaming. `ApplicationMusicPlayer.playbackTime`
/// is read on a `TimelineView` schedule (NOT via Observation), so the ~4×/s position ticks
/// redraw only this view and never invalidate the panel's control buttons — the same
/// isolation the rip path's scrubber uses to keep its buttons click-safe on macOS.
/// Seeking sets `ApplicationMusicPlayer.playbackTime` on release.
private struct AppleMusicScrubber: View {
    @Environment(PlaybackCoordinator.self) private var coordinator
    @State private var scrubbing: Double?

    var body: some View {
        // No static duration is published by ApplicationMusicPlayer here (the catalog
        // song's duration would need a separate fetch), so we scrub against a generous
        // upper bound and rely on the elapsed label for the live position. The control is
        // primarily a live position read-out + coarse seek for streaming.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let pos = scrubbing ?? coordinator.appleMusic.positionSeconds
            VStack(spacing: 2) {
                Slider(value: Binding<Double>(get: { pos }, set: { scrubbing = $0 }),
                       in: 0...max(pos, 1)) { editing in
                    if !editing, let target = scrubbing { coordinator.seekAppleMusic(to: target); scrubbing = nil }
                }
                .accessibilityIdentifier("am-player-seek")
                HStack {
                    Text(Self.clock(pos)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Spacer()
                    Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(Theme.accent2)
                }
            }
        }
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let total = Int(s)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
