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
/// — `SetlistPlayer` resets it on every track change.
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

    /// Whether the current track has burned stems on disk — read from the BurnStore so the Stems
    /// toggle is enabled BEFORE the swap (the DSP only learns `stemsAvailable` once engaged).
    private var stemsBurned: Bool {
        guard expanded, let id = sequencer.currentSongId else { return false }
        return burns.stemsBurned(forSong: id)
            || (ProfileSourceStore.isProfileSongId(id) && profileSource?.stemURLs(id: id) != nil)
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
                .disabled(!stemsBurned)
                .accessibilityIdentifier("np-mix-stems-toggle")
            }
            if !stemsBurned {
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
        .accessibilityValue(muted ? "Muted" : "On")
        .accessibilityIdentifier(a11y)
        .accessibilityAddTraits(.isButton)
    }
}
