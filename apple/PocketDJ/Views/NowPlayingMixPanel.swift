import SwiftUI

/// F4 — the collapsible Mix mini-panel docked on the Now Playing deck. It exposes tempo / pitch /
/// gain / effects / stems for the CURRENTLY PLAYING local track by driving `NowPlayingDSP`.
///
/// Visibility: shown ONLY when the current track is a local/mixable file AND no Mix-tab session is
/// actively playing (`SetlistPlayer.mixAvailable`). Otherwise the whole section is HIDDEN — never
/// greyed. Collapsed by default (`@AppStorage("nowPlayingMixExpanded")`).
///
/// ENGAGE = swap-on-touch: every control first calls `SetlistPlayer.engageMix()` (idempotent), which
/// on the FIRST touch hands the current track's audio off the `AVPlayer` into the DSP graph AT the
/// current position; the control then applies to the truly-playing track. Control state is EPHEMERAL
/// — `SetlistPlayer` resets it on every track change, unless the session's STEM LOCK (the 🔒 beside the
/// Stems toggle) carries the stem set forward (see `StemLock`).
///
/// Reuses the Mix tab's `DeckSlider` / `EffectButton` / `StepButton` / `ChipStrengthPopover`, bound to
/// `NowPlayingDSP` instead of a `MixEngine` deck. iPhone-portrait width constraints are handled by the
/// same fixed-width popover pattern those components carry.
struct NowPlayingMixPanel: View {
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(NowPlayingDSP.self) private var dsp
    @Environment(MixEngine.self) private var mix
    @Environment(BurnStore.self) private var burns
    @Environment(ProfileSourceStore.self) private var profileSource: ProfileSourceStore?

    @AppStorage("nowPlayingMixExpanded") private var expanded = false

    /// The mutually-exclusive Mix-tab session state (one DSP surface at a time).
    private var mixActive: Bool { mix.isRunning || mix.autoMixing }
    private var available: Bool { sequencer.mixAvailable(mixActive: mixActive) }

    /// Whether the current track HAS stems anywhere — burned on disk, a profile item's, or in the
    /// catalog (streamed in on demand while the full song keeps playing) — read from the stores so
    /// the Stems toggle is enabled BEFORE the swap (the DSP only learns `stemsAvailable` once
    /// engaged).
    private var stemsObtainable: Bool {
        guard expanded, let id = sequencer.currentSongId else { return false }
        return burns.stemsBurned(forSong: id)
            || (ProfileSourceStore.isProfileSongId(id) && profileSource?.stemURLs(id: id) != nil)
            || burns.stemsRemote(forSong: id)
    }

    /// Idempotent: the first control touch performs the AVPlayer→DSP hand-off.
    private func engage() { sequencer.engageMix() }

    var body: some View {
        if available {
            VStack(alignment: .leading, spacing: 8) {
                header
                if expanded { controls }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .accessibilityIdentifier("np-mix-panel")
        } else if sequencer.stemLock.enabled, sequencer.isRunning {
            // The panel hides on a track that can't be mixed (a stream, Apple Music) — but a
            // session locked to stems must still say why this track plays the full mix.
            StemLockStatusRow(indicator: sequencer.stemLockIndicator)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    // MARK: Header (chevron + "Mix" + engaged dot)

    private var header: some View {
        Button {
            withAnimation { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                Image(systemName: "slider.horizontal.3").font(.caption)
                Text("Mix").font(.caption.weight(.semibold))
                if sequencer.mixEngaged {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .accessibilityLabel("Engaged")
                }
                if sequencer.stemLock.enabled {
                    Image(systemName: "lock.fill").font(.caption2)
                        .accessibilityLabel("Stem Lock on")
                }
                Spacer()
            }
            .foregroundStyle(sequencer.mixEngaged ? Theme.accent : Theme.fgDim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("np-mix-toggle")
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            DeckSlider(title: "Tempo", display: String(format: "%.2f×", dsp.rate),
                       value: dsp.rate, range: MixEngine.rateRange, step: 0.02,
                       a11y: "np-mix-tempo",
                       onChange: { engage(); dsp.setRate($0) })
            DeckSlider(title: "Pitch", display: pitchDisplay,
                       value: dsp.pitch, range: MixEngine.pitchRange, step: 0.5,
                       a11y: "np-mix-pitch",
                       onChange: { engage(); dsp.setPitch($0) })
            DeckSlider(title: "Gain", display: "\(Int((dsp.volume * 100).rounded()))%",
                       value: dsp.volume, range: MixEngine.volumeRange, step: 0.05,
                       a11y: "np-mix-gain",
                       valueColor: dsp.volume > 1.0 ? Theme.accent2 : Theme.fg,
                       accessibilityValueText: "\(Int((dsp.volume * 100).rounded())) percent",
                       onChange: { engage(); dsp.setVolume($0) })

            effectsGrid
            stemSection
        }
    }

    private var pitchDisplay: String {
        dsp.pitch == 0 ? "0 st" : String(format: "%+.1f st", dsp.pitch)
    }

    private var effectsGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Effects").font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(MixEngine.Effect.allCases) { effect in
                    EffectButton(effect: effect,
                                 isOn: dsp.isEnabled(effect),
                                 strength: dsp.strength(effect),
                                 a11y: "np-mix-fx-\(effect.rawValue)",
                                 onToggle: { engage(); dsp.setEffect(effect, enabled: !dsp.isEnabled(effect)) },
                                 onStrength: { engage(); dsp.setEffectStrength(effect, $0) })
                }
            }
        }
    }

    @ViewBuilder private var stemSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stems").font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
                Spacer()
                // A pending handover says so — the full song plays on until the stems land
                // (or, toggling off, until the full song has runway). Tapping again cancels.
                if let h = dsp.stemHandover {
                    MixBufferingBadge(text: h == .toStems ? "Loading stems…" : "Loading full mix…",
                                      a11yId: "np-mix-stems-pending")
                }
                stemLockButton
                Button {
                    engage()
                    dsp.setStemMode(!dsp.stemMode)
                } label: {
                    Text(dsp.stemMode ? "On" : "Off")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(dsp.stemMode ? Theme.accent : Theme.fgDim)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.bgOverlay))
                        .overlay(Capsule().stroke(dsp.stemMode ? Theme.accent : Theme.border))
                }
                .buttonStyle(.plain)
                .disabled(!stemsObtainable)
                .accessibilityIdentifier("np-mix-stems-toggle")
                .accessibilityValue(dsp.stemsLoading ? "Loading" : (dsp.stemMode ? "On" : "Off"))
            }
            if sequencer.stemLockIndicator == .unavailable {
                StemLockStatusRow(indicator: .unavailable)
            }
            if !stemsObtainable {
                Text("No stems for this track")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            } else if dsp.stemMode {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(MixEngine.stemNames, id: \.self) { stem in
                        NowPlayingStemPad(dsp: dsp, stem: stem,
                                          a11y: "np-mix-stem-\(stem)",
                                          onInteract: engage)
                    }
                }
            }
        }
    }
}

extension NowPlayingMixPanel {
    /// STEM LOCK — carry this track's stem set (on/off + which parts) to every following track
    /// of the session. Session state, not a mix control: it doesn't engage the DSP by itself.
    fileprivate var stemLockButton: some View {
        let locked = sequencer.stemLock.enabled
        return Button {
            sequencer.setStemLock(!locked)
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(locked ? Theme.accent : Theme.fgDim)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.bgOverlay))
                .overlay(Capsule().stroke(locked ? Theme.accent : Theme.border))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stem Lock")
        .accessibilityValue(locked ? "On" : "Off")
        .accessibilityHint("Keeps this stem setup for the next tracks")
        .accessibilityIdentifier("np-mix-stem-lock")
    }
}

/// The small, unobtrusive Stem Lock line for a locked session whose CURRENT track can't do the
/// carried stems (or is still bringing them up while the panel is hidden): the full mix plays,
/// and the lock carries on to the next track.
struct StemLockStatusRow: View {
    let indicator: StemLock.Indicator

    private var text: String? {
        switch indicator {
        case .unavailable: return "Stem Lock · no stems for this track — full mix"
        case .loading: return "Stem Lock · stems loading…"
        case .active: return "Stem Lock · stems on"
        case .idle: return "Stem Lock · stems off"
        case .off: return nil
        }
    }

    var body: some View {
        if let text {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                Text(text).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.caption2)
            .foregroundStyle(Theme.fgDim)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("np-stem-lock-status")
        }
    }
}

/// One stem pad for the Now Playing mix panel — TAP toggles MUTE; LONG-PRESS (iOS) / RIGHT-CLICK
/// (macOS) opens the fixed-width volume popover (the `ChipStrengthPopover` the Mix tab uses). Bound to
/// `NowPlayingDSP`. A dedicated pad (the Mix tab's `StemPad` is bound to `MixEngine`).
private struct NowPlayingStemPad: View {
    let dsp: NowPlayingDSP
    let stem: String
    let a11y: String
    let onInteract: () -> Void

    @State private var showPopover = false

    private var muted: Bool { dsp.isStemMuted(stem) }
    private var color: Color { Theme.accent }
    /// Stem Lock: an un-muted part a PARTIAL set hasn't got yet — it plays once it lands.
    private var pending: Bool { !muted && dsp.unwiredStemParts.contains(stem) }

    private static func icon(_ stem: String) -> String {
        switch stem {
        case "vocals": return "music.mic"
        case "drums":  return "metronome"
        case "bass":   return "waveform.path"
        default:       return "music.note"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: muted ? "speaker.slash.fill" : Self.icon(stem))
            Text(stem.capitalized).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity, minHeight: 18)
        .padding(.vertical, 7)
        .background(muted ? Theme.bgOverlay : color.opacity(0.28),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(muted ? Theme.border : color, lineWidth: 1))
        .foregroundStyle(muted ? Theme.fgDim : color)
        .opacity(pending ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { onInteract(); dsp.toggleStemMute(stem) }
        .onLongPressGesture(minimumDuration: 0.4) { showPopover = true }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            ChipStrengthPopover(title: stem.capitalized, systemImage: Self.icon(stem), tint: color,
                                value: dsp.stemVolume(stem), step: 0.05, a11y: "\(a11y)-volume",
                                presented: $showPopover,
                                onChange: { onInteract(); dsp.setStemVolume(stem, $0) })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stem.capitalized)
        .accessibilityValue(muted ? "Muted" : (pending ? "Loading" : "On"))
        .accessibilityIdentifier(a11y)
        .accessibilityAddTraits(.isButton)
    }
}
