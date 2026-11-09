import SwiftUI

/// Settings ▸ Mixing — every mixing control in one pane: the crossfade lengths the Mix tab's Auto
/// mode AND Now Playing DJ Mode share, which parts of a DJ Mode mix are on (all on by default —
/// np-dj-mode §6), and the Mix tab's own deck options.
struct MixingSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            crossfadesSection
            #if !os(tvOS)
            djModeSection
            #endif
            mixTabSection
        }
        .formStyle(.grouped)
        .navigationTitle("Mixing")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .onDisappear { settings.persist() }
    }

    // MARK: Crossfades (shared: the Mix tab's Auto mode + Now Playing DJ Mode)

    private func secondsStepper(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>,
                                id: String) -> some View {
        Stepper(value: value, in: range, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) s")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(id)
        .onChange(of: value.wrappedValue) { settings.persist() }
    }

    private var crossfadesSection: some View {
        Section {
            secondsStepper("Crossfade lead", $settings.autoMixLeadSeconds, in: 3...60, id: "settings-automix-lead")
            secondsStepper("Crossfade length", $settings.autoMixFadeSeconds, in: 1...12, id: "settings-automix-fade")
            secondsStepper("Skip fade", $settings.skipFadeSeconds, in: 1...60, id: "settings-automix-skip-fade")
            secondsStepper("Mix Glide length", $settings.mixGlideSeconds, in: 1...30, id: "settings-mix-glide-length")
        } header: {
            Text("Crossfades")
        } footer: {
            Text("These lengths drive both the Mix tab's Auto mode and Now Playing DJ Mode. Each crossfade may begin up to the lead before a song ends and sweeps from one song to the next over the crossfade length; Mix Glide is how long the tempo / key / effect glide eases in before the fade and back out after it.\n\nSkip fade is how long the crossfade lasts when you skip — the Mix tab's Skip button, or ⏭ in Now Playing with DJ Mode on. A double-tap (and ⏭ on the lock screen, CarPlay or a widget) is always a fast 5 s sweep.")
        }
    }

    // MARK: Now Playing DJ Mode (np-dj-mode §6) — which parts are on; all on by default

    #if !os(tvOS)
    private func djToggle(_ title: String, _ key: ReferenceWritableKeyPath<SettingsStore, Bool>, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { settings[keyPath: key] },
                                    set: { settings[keyPath: key] = $0; settings.persist() }))
            .accessibilityIdentifier(id)
    }

    private var djModeSection: some View {
        Section {
            djToggle("Transitions (crossfade)", \.djTransitions, id: "settings-dj-transitions")
            djToggle("Effect sweeps", \.djEffectSweeps, id: "settings-dj-effects")
            djToggle("Tempo match", \.djTempoMatch, id: "settings-dj-tempo")
            djToggle("Key / pitch match", \.djKeyMatch, id: "settings-dj-key")
            djToggle("Volume leveling", \.djVolumeLeveling, id: "settings-dj-volume")
            djToggle("Tempo waves", \.djTempoWaves, id: "settings-dj-waves")
            djToggle("Pockets (genre, year, collections)", \.djPockets, id: "settings-dj-pockets")
        } header: {
            Text("Now Playing DJ Mode")
        } footer: {
            Text("DJ Mode (the DJ chip beside Mix Mode in Now Playing) mixes each song into the next once both are on this device, using the crossfades above.\n\nTransitions crossfades songs (off: songs end and start as usual, the ordering below still applies). Effect sweeps rides a filter / echo / reverb sweep through each mix. Tempo match glides the tempos together; Key / pitch match nudges the pitch toward a compatible key. Volume leveling evens out loudness between songs (−14 LUFS). Tempo waves orders what's coming up into 10 BPM steps that build up and wind down; Pockets plays runs of 3–4 songs of a similar genre, era and collection.")
        }
    }
    #endif

    // MARK: The Mix tab's own options

    private var mixTabSection: some View {
        Section {
            Toggle("Volume glide (Auto-DJ)", isOn: $settings.mixVolumeGlide)
                .accessibilityIdentifier("settings-mix-volume-glide")
                .onChange(of: settings.mixVolumeGlide) { settings.persist() }

            Toggle("Auto-hide played tracks", isOn: $settings.mixAutoHidePlayed)
                .accessibilityIdentifier("settings-mix-autohide")
                .onChange(of: settings.mixAutoHidePlayed) { settings.persist() }

            Picker(selection: $settings.cueOutputChannel) {
                ForEach(CueChannel.allCases) { ch in Text(ch.label).tag(ch) }
            } label: {
                Text("Cue output channel")
            }
            .accessibilityIdentifier("settings-mix-cue-channel")
            .onChange(of: settings.cueOutputChannel) { settings.persist() }

            Toggle("Beat pulse", isOn: $settings.beatPulseEnabled)
                .accessibilityIdentifier("settings-mix-beat-pulse")
                .onChange(of: settings.beatPulseEnabled) { settings.persist() }

            // iOS-only "view mode": how the two decks are arranged in the Mix tab. macOS is always
            // side-by-side (there's room), so the picker is hidden there.
            #if os(iOS)
            Picker(selection: $settings.mixDeckLayout) {
                ForEach(MixDeckLayout.allCases) { layout in
                    Label(layout.label, systemImage: layout.systemImage).tag(layout)
                }
            } label: {
                Text("Deck layout")
            }
            .accessibilityIdentifier("settings-mix-deck-layout")
            .onChange(of: settings.mixDeckLayout) { settings.persist() }
            #endif
        } header: {
            Text("Mix tab")
        } footer: {
            Text(mixTabFooter)
        }
    }

    /// The deck-layout paragraph is iOS-only (the picker is too).
    private var mixTabFooter: String {
        var s = "Volume glide (off by default) levels every song the Auto-DJ plays to one loudness (−14 LUFS, at most −12…+6 dB, ramped over 2 s) on each deck's own trim — your Vol faders are never moved — and shows the trim under each deck's Vol. Hand-mixing is never leveled.\n\nA mix session records what you play until you hit Reset. When Auto-hide played tracks is on, the deck loader hides tracks you've already played this session; off, they still show with a ✓.\n\nCue output channel routes a deck's pre-fade-listen (the headphones button on each deck) to one side of the stereo output, leaving the house mix on the other — for a booth where you monitor on a separate feed.\n\nBeat pulse flashes a ring around each deck on every beat (downbeats brighter) so you can feel the groove and eyeball-align the two decks while beat-matching."
        #if os(iOS)
        s += "\n\nDeck layout arranges the two Mix decks in portrait: Side by side (the classic two-up board), Stacked (full-width decks, one above the other), or Single (one deck at a time with ‹ › buttons on either side to flip to the other). Portrait defaults to Stacked so each deck's sliders stay finger-friendly; landscape always shows them side by side."
        #endif
        return s
    }
}
