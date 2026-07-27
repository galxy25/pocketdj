import SwiftUI

/// SongDetail-ONLY stem-audition panel — the e2e test bed for the Demucs stem feature before it
/// reaches the Mix tab. Tapping the stem glyph on the song's transport slides this out below the
/// inline player. On open it BURNS the 4 stems to the offline store (the SAME user-managed burn
/// folder as everything else — never streamed), then loads them into a synchronized `StemPlayer`.
///
/// Layout (top → bottom): one row per stem (vocals / drums / bass / other), each with a solo ▶
/// ("play just this one"), the stem name, and a 🔊/🔇 mute toggle; a shared scrubber; and a
/// CENTERED "Play All" that starts every stem in sync (all audible, from 0:00) so you can then
/// mute / solo specific stems live. Uses the same control idioms as the inline player.
struct StemAuditionPanel: View {
    @Environment(BurnStore.self) private var burns
    @Environment(ProfileSourceStore.self) private var profileSource: ProfileSourceStore?
    let song: (id: String, title: String, artist: String)
    /// Owned by `SongDetailView` (survives the panel collapsing) so playback isn't torn down by a
    /// transient re-render; the panel stops it on disappear / song change.
    @Bindable var player: StemPlayer

    enum Phase: Equatable { case burning, ready, failed(String) }
    @State private var phase: Phase = .burning
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 10) {
            header
            switch phase {
            case .burning:           burningState
            case .failed(let msg):   failedState(msg)
            case .ready:
                stemRows
                scrubber
                playAllBar
            }
        }
        .padding(12)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        // Border drawn in an `.overlay` (on TOP of the controls) must NOT eat their clicks on
        // macOS — `.allowsHitTesting(false)` lets taps reach the buttons beneath (same fix as
        // `InlinePlayerPanel`).
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .padding(.vertical, 4)
        // IMPORTANT: no `.accessibilityIdentifier` on this container — on macOS SwiftUI propagates
        // a container id onto every descendant, clobbering the child control ids (same trap as
        // `InlinePlayerPanel`). The panel is detected via its child controls.
        .task(id: song.id) { await prepare() }
        // Collapsing the panel stops playback + releases the burn folder's security scope.
        .onDisappear { player.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(Theme.accent)
            Text("Stems").font(.caption.weight(.semibold)).foregroundStyle(Theme.fg)
            Spacer()
            if case .ready = phase {
                Text("4 · offline").font(.caption2).foregroundStyle(Theme.fgDim)
            }
        }
    }

    // MARK: Burning / failed states

    private var burningState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Burning stems for offline playback…")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("stem-burning")
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failedState(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.accent2)
            Text(msg).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("stem-failed")
            Spacer()
            Button("Retry") { Task { await prepare() } }
                .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("stem-retry")
        }
    }

    // MARK: Stem rows (solo ▶ · name · mute)

    private var stemRows: some View {
        VStack(spacing: 6) {
            ForEach(StemPlayer.stems, id: \.self) { name in stemRow(name) }
        }
    }

    private func stemRow(_ name: String) -> some View {
        HStack(spacing: 10) {
            // Solo / "play just this one" — toggles solo, starting playback if stopped.
            Button { player.solo(name) } label: {
                Image(systemName: soloing(name) ? "pause.fill" : "play.fill").font(.caption)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(soloing(name) ? Theme.accent2 : Theme.accent)
            .accessibilityIdentifier("stem-solo-\(name)")

            // The row's NAME carries the row id (NOT the HStack — a container id would clobber the
            // two buttons' ids on macOS).
            Label(name.capitalized, systemImage: Self.icon(name))
                .font(.callout).foregroundStyle(Theme.fg)
                .accessibilityIdentifier("stem-row-\(name)")

            Spacer()

            // Mute toggle (independent of solo).
            Button { player.toggleMute(name) } label: {
                Image(systemName: player.isAudible(name) ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(player.isAudible(name) ? Theme.accent : Theme.fgDim)
            .accessibilityIdentifier("stem-mute-\(name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.bgOverlay.opacity(soloing(name) ? 0.6 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// This stem is the one currently soloed AND audio is running (drives the row ▶/⏸ + tint).
    private func soloing(_ name: String) -> Bool { player.soloed == name && player.isPlaying }

    // MARK: Shared scrubber

    private var scrubber: some View {
        // Position SAMPLED on a TimelineView (not observed) so the 4×/s ticks redraw only this
        // subview and never invalidate the control buttons (the InlinePlayer pattern).
        let duration = max(player.duration, 0.01)
        return TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = min(scrubbing ?? player.currentTime, duration)
            VStack(spacing: 2) {
                Slider(value: Binding<Double>(get: { now }, set: { scrubbing = $0 }),
                       in: 0...duration) { editing in
                    if !editing, let target = scrubbing { player.seek(to: target); scrubbing = nil }
                }
                .accessibilityIdentifier("stem-scrubber")
                HStack {
                    Text(Self.clock(now)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    Spacer()
                    Text(Self.clock(duration)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
            }
        }
    }

    // MARK: Centered Play All / restart

    private var playAllBar: some View {
        HStack(spacing: 16) {
            Spacer()
            Button { player.seek(to: 0) } label: {
                Image(systemName: "gobackward").font(.body)
                    .frame(width: 34, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("stem-restart")

            Button { masterTapped() } label: {
                Label(masterLabel, systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("stem-play-all")
            Spacer()
        }
    }

    /// "Pause" while running; "Resume" when paused mid-track (keeps the mute set + position);
    /// "Play All" from a stop at 0:00 (starts every stem audible, in sync).
    private var masterLabel: String {
        if player.isPlaying { return "Pause" }
        return player.currentTime > 0.05 ? "Resume" : "Play All"
    }

    private func masterTapped() {
        if player.isPlaying { player.togglePlayPause() }              // pause (preserve mutes/solo)
        else if player.currentTime > 0.05 { player.togglePlayPause() } // resume where we paused
        else { player.playAll() }                                     // fresh: all audible, in sync, from 0
    }

    // MARK: Prepare (burn-to-local → load)

    private func prepare() async {
        if player.loadedSongId == song.id, player.ready { phase = .ready; return }
        // A "Pocket DJ" profile item's stems are already on disk (app-managed, no burn/no scope) —
        // load them directly; only rip/burn ids need the burn-to-local step below.
        if ProfileSourceStore.isProfileSongId(song.id), let urls = profileSource?.stemURLs(id: song.id) {
            player.load(songId: song.id, localURLs: urls, release: nil)
            phase = player.loadError == nil ? .ready : .failed(player.loadError ?? "Couldn’t load stems.")
            return
        }
        phase = .burning
        guard let (urls, release) = await burns.burnStems(forSong: song.id) else {
            phase = .failed("Couldn’t prepare stems for offline playback.")
            return
        }
        player.load(songId: song.id, localURLs: urls, release: release)
        phase = player.loadError == nil ? .ready : .failed(player.loadError ?? "Couldn’t load stems.")
    }

    // MARK: Helpers

    private static func icon(_ name: String) -> String {
        switch name {
        case "vocals": return "music.mic"
        case "drums":  return "metronome"
        case "bass":   return "waveform.path"
        default:       return "music.note"
        }
    }

    static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
