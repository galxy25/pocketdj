import SwiftUI

/// F4 — the collapsible Mix mini-panel docked on the Now Playing deck. It exposes tempo / pitch /
/// gain / effects / stems for the CURRENTLY PLAYING local track by driving `NowPlayingDSP`.
///
/// Visibility (np-mix-mode phase 2): the HEADER — chevron · "Mix" · status chip · the MIX MODE
/// switch — shows whenever a session runs (tvOS keeps F4's rule: no Mix Mode there, Q10). The
/// CONTROLS show when the current track is mixable (`SetlistPlayer.mixAvailable`); with Mix Mode
/// on they also show, DISABLED, while the track's local copy buffers ("Buffering 42%" in the
/// chip). A track that can never be local (Apple Music with no local copy, a live capture) keeps
/// F4's "hide, don't grey" rule; an Apple Music row whose local copy exists (phase 4) shows its
/// controls live and the first touch switches it to that copy (`SetlistPlayer.handOffFromAppleMusic`). Collapsed by default (`@AppStorage("nowPlayingMixExpanded")`); turning Mix Mode on
/// expands it once.
///
/// ENGAGE = swap-on-touch: every control first calls `SetlistPlayer.engageMix()` (idempotent), which
/// on the FIRST touch hands the current track's audio off the `AVPlayer` into the DSP graph AT the
/// current position; the control then applies to the truly-playing track. Control state is EPHEMERAL
/// — `SetlistPlayer` resets it on every track change, unless the session's STEM LOCK (the 🔒 beside the
/// Stems toggle) carries the stem set forward (see `StemLock`), or its FX LOCK (the 🔒 at the right end of
/// the Effects group's header, placed like the Stem Lock) carries the effects forward (see `FXLock`; tempo / pitch / gain
/// still reset).
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

    /// Mix Mode lives on every Now Playing surface but the TV (Q10).
    private static var mixModeSupported: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }
    /// The header shows whenever a session runs (F4 on tvOS: only when mixable).
    private var showsHeader: Bool { Self.mixModeSupported ? sequencer.isRunning : available }
    private var indicator: NPMixMode.Indicator { sequencer.mixModeIndicator }
    /// Controls visible: mixable — or, in Mix Mode, buffering towards mixable (shown disabled).
    private var controlsVisible: Bool {
        if available { return true }
        if case .buffering = indicator { return true }
        return false
    }

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
        if showsHeader {
            VStack(alignment: .leading, spacing: 8) {
                header
                if !controlsVisible, sequencer.stemLock.enabled {
                    // A locked session on a track that can't be mixed still says why this track
                    // plays the full mix (expanded or not, as before the header was always shown).
                    StemLockStatusRow(indicator: sequencer.stemLockIndicator)
                }
                if expanded {
                    if controlsVisible {
                        controls
                            .disabled(!available)
                            .opacity(available ? 1 : 0.45)
                    }
                    if sequencer.mixMode.enabled { MixModeBufferStrip() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .accessibilityIdentifier("np-mix-panel")
        } else if sequencer.stemLock.enabled, sequencer.isRunning {
            // The panel hides on a track that can't be mixed (a stream, Apple Music) — but a
            // session locked to stems must still say why this track plays without them. (The FX
            // Lock has NO status line anywhere — Levi 2026-11-03: its held / paused state lives
            // in the lock glyph's own look + VoiceOver value, never in extra vertical space.)
            StemLockStatusRow(indicator: sequencer.stemLockIndicator)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    // MARK: Header (chevron + "Mix" + engaged dot · status chip · Mix Mode switch)

    @ViewBuilder private var header: some View {
        if Self.mixModeSupported {
            MixModeIndicatorReader { ind, note in
                MixPanelHeaderLayout(chip: MixModeChipLabel.Content(indicator: ind, note: note,
                                                                    dj: sequencer.djIndicator.chipText)) {
                    headerToggle
                } modeSwitch: {
                    // DJ Mode sits LEFT of Mix Mode, the same capsule (np-dj-mode §7).
                    HStack(spacing: 6) {
                        djModeSwitch
                        mixModeSwitch
                    }
                }
            }
        } else {
            HStack(spacing: 6) { headerToggle; Spacer(minLength: 4) }
        }
    }

    /// Chevron · "Mix" · engaged dot · lock badges — the expand / collapse button.
    private var headerToggle: some View {
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
                if sequencer.fxLock.enabled {
                    let fx = sequencer.fxLockIndicator
                    // Held (this track can't take the effects) / paused (Mix tab live): an
                    // OUTLINED, dimmed lock — the words ride in the VoiceOver value only.
                    HStack(spacing: 1) {
                        Image(systemName: fx.isHeld ? "lock" : "lock.fill")
                        Text("FX")
                    }
                    .font(.caption2)
                    .opacity(fx.isHeld ? 0.6 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("FX Lock on")
                    .accessibilityValue(fx.statusText(mixable: available) ?? "")
                    .accessibilityIdentifier("np-mix-fx-lock-badge")
                }
            }
            .foregroundStyle(sequencer.mixEngaged ? Theme.accent : Theme.fgDim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("np-mix-toggle")
    }

    /// The MIX MODE capsule switch (`np-mix-mode`): session state, not a mix control — it
    /// never engages the DSP by itself.
    private var mixModeSwitch: some View {
        let on = sequencer.mixMode.enabled
        return Button {
            withAnimation { sequencer.setMixMode(!on) }
            IntentDonations.setMixMode(!on)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.badge.plus")
                Text("Mix Mode")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(on ? Theme.accent : Theme.fgDim)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.18) : Theme.bgOverlay))
            .overlay(Capsule().stroke(on ? Theme.accent : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mix Mode")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityHint("Buffers this and the upcoming songs so the mix controls work on any track")
        .accessibilityIdentifier("np-mix-mode")
    }

    /// The DJ MODE capsule switch (`np-dj-mode`) — session state like Mix Mode (which it turns on):
    /// transitions, tempo / key matching, effect sweeps, leveling and the PocketDJ selector.
    private var djModeSwitch: some View {
        let on = sequencer.djMode.enabled
        return Button {
            withAnimation { sequencer.setDJMode(!on) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "dial.medium" : "music.note.list")
                Text("DJ")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(on ? Theme.accent : Theme.fgDim)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.18) : Theme.bgOverlay))
            // The out → in crossfade, filling the capsule's floor while a transition runs (the
            // Mix tab's crossfader sweep, in the chip's own footprint — no new row).
            .overlay(alignment: .bottom) {
                if on, automating {
                    Capsule().fill(Theme.accent)
                        .frame(height: 2)
                        .scaleEffect(x: max(0.04, dsp.djDisplay.crossfade), anchor: .leading)
                        .padding(.horizontal, 7)
                        .padding(.bottom, 1)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("np-dj-crossfade")
                }
            }
            .overlay(Capsule().stroke(on ? Theme.accent : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("DJ Mode")
        .accessibilityValue(on ? (automating ? "On, mixing \(Int((dsp.djDisplay.crossfade * 100).rounded())) percent" : "On") : "Off")
        .accessibilityHint("Mixes each song into the next with tempo, key and effect transitions, and orders the queue into tempo waves")
        .accessibilityIdentifier("np-dj-mode")
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            // DJ Mode automation MOVES these (the Mix tab's gliding sliders): they show what is
            // heard (`displayRate` / `displayPitch`) and a touch takes over from that value — the
            // DSP ends the glide and the listener's value becomes the dragged one (no jump).
            DeckSlider(title: "Tempo", display: String(format: "%.2f×", dsp.displayRate),
                       value: dsp.displayRate, range: MixEngine.rateRange, step: 0.02,
                       a11y: "np-mix-tempo",
                       onChange: { engage(); dsp.setRate($0) })
            DeckSlider(title: "Pitch", display: pitchDisplay,
                       value: dsp.displayPitch, range: MixEngine.pitchRange, step: 0.5,
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
        let p = dsp.displayPitch
        return abs(p) < 0.05 ? "0 st" : String(format: "%+.1f st", p)
    }

    /// DJ Mode automation is driving the controls (observed at ~16 Hz while it runs).
    private var automating: Bool { dsp.djDisplay.active }

    private var effectsGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            // FX LOCK mirrors the Stem Lock's placement in the Stems header: on the header line
            // itself (no new row), on the RIGHT — "Effects", then the status text, then the lock
            // (the Effects group has no On/Off toggle, so the lock is the trailing item, where the
            // Stems header's lock + On/Off sit). The capsule's vertical padding is absorbed so the
            // line keeps the label's height.
            HStack {
                Text("Effects").font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
                Spacer(minLength: 4)
                // A lock holding effects this track can't take yet (an Apple Music row whose
                // local copy is ready — a control touch moves it, Q1) says so through the
                // capsule's own look (outlined glyph, dashed border) + its VoiceOver value; no text.
                fxLockButton
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(MixEngine.Effect.allCases) { effect in
                    // Shows the transition's sweep too; a touch acts on what is SHOWN: a tap
                    // flips the shown state, a strength drag on a swept effect keeps it on.
                    let shown = dsp.displayEffect(effect)
                    EffectButton(effect: effect,
                                 isOn: shown.on,
                                 strength: shown.strength,
                                 a11y: "np-mix-fx-\(effect.rawValue)",
                                 onToggle: { engage(); dsp.setEffect(effect, enabled: !dsp.displayEffect(effect).on) },
                                 onStrength: { v in
                                     engage()
                                     if dsp.displayEffect(effect).on, !dsp.isEnabled(effect) { dsp.setEffect(effect, enabled: true) }
                                     dsp.setEffectStrength(effect, v)
                                 })
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
    /// FX LOCK — carry this track's effects (each one's on/off + strength) to every following
    /// track of the session; tempo / pitch / gain still reset. Session state, not a mix control:
    /// it doesn't engage the DSP by itself. Same glyph + capsule as the Stem Lock.
    fileprivate var fxLockButton: some View {
        let locked = sequencer.fxLock.enabled
        let fx = sequencer.fxLockIndicator
        let held = locked && fx.isHeld
        return Button {
            sequencer.setFXLock(!locked)
        } label: {
            Image(systemName: locked ? (held ? "lock" : "lock.fill") : "lock.open")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(locked ? Theme.accent : Theme.fgDim)
                .opacity(held ? 0.6 : 1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.bgOverlay))
                .overlay(Capsule().stroke(locked ? Theme.accent : Theme.border,
                                          style: StrokeStyle(lineWidth: 1, dash: held ? [2, 2] : [])))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Absorb the capsule's 3 pt top/bottom padding: the header line stays the label's height.
        .padding(.vertical, -3)
        .accessibilityLabel("FX Lock")
        .accessibilityValue(locked ? (fx.statusText(mixable: available).map { "On, \($0)" } ?? "On") : "Off")
        .accessibilityHint("Keeps these effects for the next tracks")
        .accessibilityIdentifier("np-mix-fx-lock")
    }

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

/// Reads MIX MODE's indicator (+ the rule-A edition note) for the panel header. Re-reads twice a
/// second while buffering (the byte progress isn't observable), otherwise only on state changes.
struct MixModeIndicatorReader<Content: View>: View {
    @Environment(SetlistPlayer.self) private var sequencer
    @ViewBuilder let content: (NPMixMode.Indicator, String?) -> Content

    private var current: (NPMixMode.Indicator, String?) {
        #if DEBUG
        if let o = NPMixMode.debugChipOverride { return o }
        #endif
        return (sequencer.mixModeIndicator, sequencer.editionSubstituteNote)
    }

    var body: some View {
        let (ind, note) = current
        switch ind {
        case .buffering, .holding:
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let (i, n) = current
                content(i, n)
            }
        default:
            if sequencer.djIndicator.isBuffering {   // "DJ — buffering next n%" moves too
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let (i, n) = current
                    content(i, n)
                }
            } else {
                content(ind, note)
            }
        }
    }
}

/// The Mix panel header's layout (Levi 2026-11-03: the chip was CUT OFF on an iPhone). The chip is
/// CENTERED and never truncated: it sits inline between the "Mix" toggle and the Mix Mode switch
/// when its one line fits there (no extra height — "Ready", "Mixing", "Buffering 42%"); otherwise
/// it drops to its own centered line under them, wrapping to 2 lines (scaling to 0.8 first if
/// even that's tight). With no chip (Mix Mode off) the header is the single row it always was.
struct MixPanelHeaderLayout<Toggle: View, Switch: View>: View {
    let chip: MixModeChipLabel.Content?
    @ViewBuilder let toggle: Toggle
    @ViewBuilder let modeSwitch: Switch

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                toggle
                if let chip {
                    MixModeChipLabel(content: chip, wraps: false)
                        .frame(maxWidth: .infinity)
                } else {
                    Spacer(minLength: 4)
                }
                modeSwitch
            }
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    toggle
                    Spacer(minLength: 4)
                    modeSwitch
                }
                if let chip {
                    MixModeChipLabel(content: chip, wraps: true)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// MIX MODE's status chip (`np-mix-mode-status`) — pure, so the header layout is testable.
struct MixModeChipLabel: View {
    struct Content: Equatable {
        let indicator: NPMixMode.Indicator
        let text: String
        /// Rule A: a vocals-muted substitution whose vocals were un-muted mid-track says which
        /// edition is actually playing ("Clean edition").
        let note: String?
        /// DJ Mode's status (np-dj-mode §7: "DJ — next mixes in" / "DJ — buffering next n%" /
        /// "DJ — mixing"), riding the same chip after Mix Mode's own word. nil = DJ off.
        let dj: String?

        /// nil when the indicator has no chip (Mix Mode off).
        init?(indicator: NPMixMode.Indicator, note: String?, dj: String? = nil) {
            guard let text = indicator.chipText else { return nil }
            self.indicator = indicator
            self.text = text
            self.note = note
            self.dj = dj
        }

        /// The chip's full words (text + DJ + note), as VoiceOver reads them.
        var spoken: String {
            [text, dj, note].compactMap { $0 }.joined(separator: " · ")
        }
    }

    let content: Content
    /// false = one line at its natural width (the inline slot); true = centered, up to 2 lines.
    let wraps: Bool

    var body: some View {
        let ind = content.indicator
        HStack(spacing: 4) {
            switch ind {
            case .engaged, .stemsLoading:
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
            case .ready, .readyFromAppleMusic:
                Circle().stroke(Theme.accent, lineWidth: 1.5).frame(width: 6, height: 6)
            case .buffering, .holding, .waiting:
                Image(systemName: "arrow.down.circle").font(.caption2)
            case .unavailable, .suspended, .ripping, .rippingEdition:
                Image(systemName: "exclamationmark.circle").font(.caption2)
            case .off:
                EmptyView()
            }
            label
                .multilineTextAlignment(.center)
                .lineLimit(wraps ? 2 : 1)
                .minimumScaleFactor(wraps ? 0.8 : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(ind.controlsLive ? Theme.accent : Theme.fgDim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mix Mode status")
        .accessibilityValue(content.spoken)
        .accessibilityIdentifier("np-mix-mode-status")
    }

    /// One Text so the note wraps with the status as a single centered paragraph.
    private var label: Text {
        var t = Text(content.text)
        if let dj = content.dj { t = t + Text(" · \(dj)").foregroundStyle(Theme.accent) }
        if let note = content.note { t = t + Text(" · \(note)").foregroundStyle(Theme.fgDim) }
        return t
    }
}

/// The one-line buffer strip under the controls (`np-mix-buffer-strip`): the next rows as
/// ● local · ◐ buffering · ○ queued · ⨯ unavailable.
struct MixModeBufferStrip: View {
    @Environment(SetlistPlayer.self) private var sequencer

    var body: some View {
        let rows = sequencer.mixModeBufferStrip()
        if !rows.isEmpty {
            HStack(spacing: 6) {
                Text("Up next").font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
                ForEach(rows) { r in
                    Text(r.dot.glyph)
                        .font(.caption2)
                        .foregroundStyle(r.dot == .local ? Theme.accent : Theme.fgDim)
                        .help("\(r.title) — \(Self.word(r.dot))")
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Buffer")
            .accessibilityValue(rows.map { Self.word($0.dot) }.joined(separator: ", "))
            .accessibilityIdentifier("np-mix-buffer-strip")
        }
    }

    static func word(_ d: NPMixMode.BufferDot) -> String {
        switch d {
        case .local: return "on device"
        case .buffering: return "buffering"
        case .queued: return "queued"
        case .unavailable: return "unavailable"
        }
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

extension FXLock.Indicator {
    /// Held (the lock carries effects THIS track can't take) or paused (the Mix tab is live):
    /// the lock glyph draws outlined + dimmed instead of filled.
    var isHeld: Bool { self == .waiting || self == .dormant }

    /// The words the old FX Lock status line said — now only the lock's VoiceOver value (no
    /// visible line: Levi 2026-11-03). `mixable` = the current track can be swapped onto the DSP
    /// by a control touch (an Apple Music row whose local copy is ready).
    func statusText(mixable: Bool) -> String? {
        switch self {
        case .waiting:
            return mixable ? "tap a control to apply"
                           : "effects can't apply to this track — kept for the next"
        case .dormant: return "paused while the Mix tab plays"
        case .off, .idle, .applied: return nil
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
        .onTapGesture {
            onInteract(); dsp.toggleStemMute(stem)
            IntentDonations.toggledStem(stem, muted: dsp.isStemMuted(stem))
        }
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
