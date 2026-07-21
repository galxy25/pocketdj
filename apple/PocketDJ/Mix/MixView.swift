import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A deck's playback SOURCE — a pocket or a set list. UI-only value; `MixResolver.loadables(for:)`
/// expands it to the loadable local tracks the loader lists. Two decks can share one source OR
/// each point at its own.
enum MixSource: Hashable, Identifiable {
    case pocket(String)
    case setlist(String)
    var id: String {
        switch self {
        case .pocket(let id):  return "pocket:\(id)"
        case .setlist(let id): return "setlist:\(id)"
        }
    }
}

/// Glue: load a resolver `MixLoadable` onto a deck without the engine needing to know the
/// resolver's type — forwards to the engine's primitive `load`.
extension MixEngine {
    func load(_ l: MixLoadable, on deck: MixEngine.Deck) {
        load(songId: l.songId, title: l.title, artist: l.artist,
             bpm: l.bpm, camelot: l.camelot, key: l.key, albumId: l.albumId, lengthMs: l.lengthMs, on: deck)
    }
}

// MARK: - Mix tab

/// The Mix screen (iPhone · iPad · Mac). A two-deck DJ "Main Screen": two decks
/// side-by-side, a single crossfader spanning both, then ONE big Play/Pause that drives both
/// decks. The engine is app-scoped (env), so a mix keeps playing while you leave the tab; the
/// per-deck SOURCE is local view state (the loaded track itself is read back from the engine).
struct MixView: View {
    @Environment(MixEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(BurnStore.self) private var burns
    @Environment(StudioStore.self) private var studio
    @Environment(SettingsStore.self) private var settings
    @Environment(MixSessionStore.self) private var mixSessions
    @Environment(MixRecorder.self) private var recorder
    @Environment(JukeboxStore.self) private var jukebox

    /// The detail NavigationStack's path (owned by RootView) — so the Sessions button can push.
    @Binding var path: NavigationPath

    /// Per-deck source (nil ⇒ none picked yet). Two vars so each deck can hold its own.
    @State private var sourceA: MixSource?
    @State private var sourceB: MixSource?
    /// Which deck's track-loader sheet is open (`.sheet(item:)`).
    @State private var loaderDeck: MixEngine.Deck?
    /// The GLOBAL collection Auto mode plays end-to-end (distinct from the per-deck sources).
    @State private var autoSource: MixSource?
    /// Session rename alert + reset confirmation.
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmingReset = false
    #if os(iOS)
    /// Single-deck layout only (`MixDeckLayout.single`): which deck (A/B) is currently showing.
    @State private var visibleDeck: MixEngine.Deck = .a
    /// iPhone landscape (compact height) always shows the two decks side-by-side — there's width for
    /// the two-up board — so the Deck-layout setting only governs portrait. See `deckArea`.
    @Environment(\.verticalSizeClass) private var vSizeClass
    #endif

    var body: some View {
        ScrollView {                                   // scrolls on iPhone-portrait; roomy on Mac/iPad
            VStack(spacing: 18) {
                sessionHeader                           // the renamable session name (in-content)
                if recorder.isRecording { recordingIndicator }  // ● Recording m:ss + Stop (reachable on iPhone)
                if engine.autoEnabled && !engine.autoMixing { autoSetupBar }  // pick + Play/Shuffle
                if engine.autoMixing { autoMixBanner }  // Auto-DJ status + Stop (visible on every size)
                deckArea                                // side-by-side · stacked · single (iOS view-mode setting)
                CrossfaderView(engine: engine)         // one crossfader spanning both decks
                masterTransport                        // one big Play/Pause for both decks
                if engine.autoMixing { skipButton }    // Auto-DJ only: advance to the next track
            }
            .padding(16)
            .frame(maxWidth: 900)                       // keep controls a comfortable width on Mac/iPad
            .frame(maxWidth: .infinity)                 // ...centered in a wide window
        }
        .background(Theme.bg)
        // The renamable session name lives in the CONTENT (`sessionHeader`), not the toolbar: macOS
        // reserves a toolbar item's right-click for its own "Icon Only / Icon & Text" menu, so a
        // toolbar title can never host a right-click → Rename. The nav bar just shows the screen name.
        .navigationTitle("Mix")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("mix-tab")
        .toolbar { autoMixToolbar }                    // Auto/Manual + collection Play/Shuffle
        .toolbar { sessionLeadingToolbar }             // Sessions (history) + Reset (X)
        .task {
            engine.prepare()                           // warm the AVAudioEngine graph when the tab opens
            engine.setCueOnRight(settings.cueOutputChannel.onRight)   // push the cue-channel preference
            engine.setBeatPulseEnabled(settings.beatPulseEnabled)     // gate the on-load beat-grid fetch
            engine.setMixGlideSeconds(settings.mixGlideSeconds)       // glide ramp length
            engine.setSkipFadeSeconds(settings.skipFadeSeconds)       // lock-screen ⏮ slow-skip length
            recorder.settings = settings                              // session-folder location source
            recorder.recoverOrphans()                                 // re-file any crash-interrupted takes
            // Durable mix-deck session: MATERIALIZE a launch-parked snapshot now that the Mix
            // surface is up — decks re-load and cue at their saved playheads, the Auto-DJ queue
            // comes back SUSPENDED, and nothing makes a sound until the user acts. After the
            // settings pushes above so the restored decks honor cue-channel/glide/pulse prefs.
            engine.materializePendingRestoreIfNeeded()
        }
        // Writer death mid-take (disk full / session folder vanished): the recorder auto-stopped
        // and FILED the partial take — tell the user why the record button went dark.
        .alert("Recording stopped",
               isPresented: Binding(get: { recorder.writerFailureMessage != nil },
                                    set: { if !$0 { recorder.writerFailureMessage = nil } })) {
            Button("OK", role: .cancel) { recorder.writerFailureMessage = nil }
        } message: {
            Text(recorder.writerFailureMessage ?? "")
        }
        .onChange(of: settings.mixGlideSeconds) { engine.setMixGlideSeconds(settings.mixGlideSeconds) }
        .onChange(of: settings.skipFadeSeconds) { engine.setSkipFadeSeconds(settings.skipFadeSeconds) }
        .onChange(of: settings.cueOutputChannel) { engine.setCueOnRight(settings.cueOutputChannel.onRight) }
        .onChange(of: settings.beatPulseEnabled) { engine.setBeatPulseEnabled(settings.beatPulseEnabled) }
        // Auto mode pins BOTH decks' load source to the auto-mix collection (so a Pause → hand-load-more
        // flow needs no per-deck source picking). Fires when you pick the collection or flip on Auto.
        .onChange(of: autoSource) { syncDeckSourcesToAuto() }
        .onChange(of: engine.autoEnabled) { syncDeckSourcesToAuto() }
        // DELIBERATELY no `.onDisappear { engine.pauseBoth()/stopAutoMix()/teardown() }`: the engine is
        // app-scoped and its tick + audio graph must keep running when you leave the Mix tab, so a mix
        // (and an Auto-DJ) keeps playing and the lock-screen card stays live. Sibling views do pause on
        // disappear; this one must NOT (pause/pauseBoth end the auto-mix). Load-bearing omission.
        // Track loader: long-press (iOS) / right-click (macOS) on a deck, or tap its header.
        .sheet(item: $loaderDeck) { deck in
            TrackLoaderSheet(deck: deck, engine: engine,
                             source: deck == .a ? $sourceA : $sourceB)
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $nameDraft).accessibilityIdentifier("mix-rename-field")
            Button("Save") { mixSessions.rename(mixSessions.currentId, nameDraft) }
                .accessibilityIdentifier("mix-rename-confirm")
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Start a new session?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("New session") { mixSessions.reset() }.accessibilityIdentifier("mix-reset-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current session is saved to Sessions. The fresh session starts with no played tracks.")
        }
    }

    // MARK: Deck layout (iOS "view mode" — Settings ▸ Mix ▸ Deck layout)

    /// The two decks, arranged per the iOS Deck-layout setting: side-by-side, stacked, or a single
    /// deck at a time with ‹ › switchers. Landscape (compact height = iPhone landscape) always uses
    /// side-by-side — there's width for the two-up board, so the setting governs PORTRAIT only. macOS
    /// is always side-by-side (there's room; the setting is hidden). The engine is app-scoped, so
    /// single mode's HIDDEN deck keeps playing — only its view is unmounted, never its audio.
    @ViewBuilder private var deckArea: some View {
        #if os(iOS)
        if vSizeClass == .compact {                     // iPhone landscape → always the two-up board
            sideBySideDecks
        } else {
            switch settings.mixDeckLayout {
            case .sideBySide: sideBySideDecks
            case .stacked:    stackedDecks
            case .single:     singleDeck
            }
        }
        #else
        sideBySideDecks
        #endif
    }

    /// One deck view wired to its per-deck source binding + track-loader trigger.
    private func deckView(_ deck: MixEngine.Deck) -> some View {
        DeckView(deck: deck, engine: engine,
                 source: deck == .a ? $sourceA : $sourceB) { loaderDeck = deck }
    }

    /// Classic two-up board: A left, B right, equal width.
    private var sideBySideDecks: some View {
        HStack(alignment: .top, spacing: 12) { deckView(.a); deckView(.b) }
    }

    /// Full-width decks, one above the other (the iOS default — roomy sliders in portrait).
    private var stackedDecks: some View {
        VStack(spacing: 12) { deckView(.a); deckView(.b) }
    }

    #if os(iOS)
    /// Single-deck layout: one deck at a time, flanked by ‹ (left) and › (right) switch buttons.
    /// With only two decks, EITHER chevron flips to the other — so whichever thumb is nearer flips
    /// it (max convenience) — and a row of dots under the deck marks which of A/B is showing.
    private var singleDeck: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                deckSwitchButton(isNext: false)         // ‹
                deckView(visibleDeck)
                    .frame(maxWidth: .infinity)
                    .id(visibleDeck)                    // fresh per-deck identity (clean state + cross-fade)
                    .transition(.opacity)
                deckSwitchButton(isNext: true)          // ›
            }
            deckDots
        }
        .animation(.easeInOut(duration: 0.22), value: visibleDeck)
    }

    /// A tall ‹ / › switch button flanking the single deck; tapping flips to the OTHER deck.
    private func deckSwitchButton(isNext: Bool) -> some View {
        Button {
            visibleDeck = (visibleDeck == .a) ? .b : .a
        } label: {
            Image(systemName: isNext ? "chevron.right" : "chevron.left")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityIdentifier(isNext ? "mix-deck-next" : "mix-deck-prev")
        .accessibilityLabel(isNext ? "Next deck" : "Previous deck")
    }

    /// Page dots (A · B) under the single deck marking which deck is showing.
    private var deckDots: some View {
        HStack(spacing: 7) {
            ForEach([MixEngine.Deck.a, .b]) { d in
                Circle()
                    .fill(d == visibleDeck ? Theme.accent : Theme.border)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
    #endif

    // MARK: Sessions (name menu · history · reset)

    /// The current session's name, centered at the top of the Mix content. CLICK/TAP → rename;
    /// RIGHT-CLICK (macOS) / LONG-PRESS (iOS) → the full session menu via `.contextMenu`. It lives in
    /// the content (not the toolbar) so the right-click gesture isn't stolen by the macOS toolbar menu.
    private var sessionHeader: some View {
        Button { nameDraft = mixSessions.currentName; renaming = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.subheadline).foregroundStyle(Theme.accent)
                Text(mixSessions.currentName).font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.fg).lineLimit(1)
                Image(systemName: "pencil").font(.caption).foregroundStyle(Theme.fgDim)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.bgRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Click to rename · right-click for more")
        .accessibilityIdentifier("mix-session-title")
        .contextMenu { sessionTitleMenu }          // right-click (macOS) / long-press (iOS)
    }

    /// The session menu (rename the current session, start a new one, or jump to the full Sessions
    /// list) — shown from the session header's context menu.
    @ViewBuilder private var sessionTitleMenu: some View {
        Button { nameDraft = mixSessions.currentName; renaming = true } label: {
            Label("Rename Session…", systemImage: "pencil")
        }
        Button { confirmingReset = true } label: { Label("New Session", systemImage: "xmark") }
        Divider()
        Button { path.append(MixSessionsRoute()) } label: {
            Label("All Sessions…", systemImage: "clock.arrow.circlepath")
        }
    }

    /// Leading toolbar: the discrete Sessions (history) + Reset (X) buttons. Leading keeps them off
    /// the already-crowded trailing auto-mix group (which collapses to overflow on iPhone).
    @ToolbarContentBuilder private var sessionLeadingToolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) { sessionsButton }
        ToolbarItem(placement: .topBarLeading) { resetButton }
        #else
        ToolbarItem(placement: .navigation) { sessionsButton }
        ToolbarItem(placement: .navigation) { resetButton }
        #endif
    }

    private var sessionsButton: some View {
        Button { path.append(MixSessionsRoute()) } label: { Image(systemName: "clock.arrow.circlepath") }
            .help("Mix sessions — replay & history")
            .accessibilityIdentifier("mix-sessions")
    }

    private var resetButton: some View {
        Button { confirmingReset = true } label: { Image(systemName: "xmark") }
            .help("Start a new session (the current one is saved to Sessions)")
            .accessibilityIdentifier("mix-reset")
    }

    /// JUKEBOX — the Mix side of Jukebox Hero. No session yet: one tap CREATES the
    /// jukebox (default name) and pushes its view (QR + requests); Back returns here.
    /// Session live: the antenna glows accent and the tap just opens the jukebox.
    /// NOT a broadcast, which is why the help text doesn't call it one: a new session is a
    /// VIEW-ONLY request line (`JukeboxStore.start` sets `hearEnabled = false`) — guests see
    /// what's playing and send requests, and no audio goes to them unless the host turns hear
    /// mode on from the Jukebox screen.
    /// #TOUPDATE: a jukebox is meant to be a PRIVATE event — the guest link token-gated by
    /// default, a server-enforced listener cap, and mandatory session expiry. None of the three
    /// exists yet (the guest page is public to anyone holding the link, there is no cap, and
    /// `timeless` still opts a session out of expiry), so no copy on this button may call a
    /// jukebox private, capped, or token-gated.
    private var broadcastButton: some View {
        Button {
            if jukebox.session == nil {
                Task {
                    await jukebox.start(name: JukeboxView.defaultName(settings))
                    path.append(JukeboxRoute())
                }
            } else {
                path.append(JukeboxRoute())
            }
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(jukebox.session != nil ? Theme.accent : Theme.fg)
        }
        .disabled(jukebox.starting)
        .help(jukebox.session != nil
              ? "Jukebox is live — open it (requests + QR code)"
              : "Jukebox — start a request line so guests can see the mix and send requests")
        .accessibilityIdentifier("mix-broadcast")
    }

    // MARK: Auto-Mix (auto-DJ)

    /// Toolbar: a Manual/Auto toggle button, then (in Auto) the global-collection picker + ▶ Play /
    /// 🔀 Shuffle / ⏹ Stop — mirroring the Playlists tab's menu-bar play/shuffle.
    @ToolbarContentBuilder private var autoMixToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // JUKEBOX (Jukebox Hero): one tap starts a jukebox session (if none is live)
            // and pushes its view onto THIS stack — Back returns to the decks. The mix and
            // the jukebox share the setlist: guests see the on-air track + the auto queue,
            // and accepted requests feed the Auto-DJ (in-mix actions take precedence).
            // By default only TEXT (title/artist) crosses to guests — a view-only request
            // line. Audio is added only if the host turns hear mode on from the Jukebox screen.
            broadcastButton
            // Record the mix audio into the current session's folder — pulses purple→red while live.
            RecordButton(recorder: recorder)
            // ONE-TAP mode toggle: shows the current mode and flips to the other on tap (no dropdown).
            Button { engine.setAutoEnabled(!engine.autoEnabled) } label: {
                Label(engine.autoEnabled ? "Auto" : "Manual",
                      systemImage: engine.autoEnabled ? "wand.and.stars" : "slider.horizontal.3")
            }
            .help(engine.autoEnabled ? "Auto mode — tap to switch to Manual"
                                     : "Manual mode — tap to switch to Auto")
            .accessibilityIdentifier("mix-auto-mode")

            // The collection picker + ▶ Play / 🔀 Shuffle do NOT live here: in iPhone portrait the
            // trailing toolbar collapses into a "•••" overflow that buries them behind a nested
            // submenu (you had to rotate to landscape to reach them). They're in the always-visible
            // in-content `autoSetupBar` instead. Stop + Skip likewise live in the in-body banner.
        }
    }

    @ViewBuilder private var autoSourceMenuItems: some View {
        if collections.pockets.isEmpty && collections.setlists.isEmpty {
            Text("No pockets or set lists yet")
        }
        if !collections.pockets.isEmpty {
            Section("Pockets") {
                ForEach(collections.pockets) { p in Button(p.name) { autoSource = .pocket(p.id) } }
            }
        }
        if !collections.setlists.isEmpty {
            Section("Set lists") {
                ForEach(collections.setlists) { s in Button(s.name ?? "Set list") { autoSource = .setlist(s.id) } }
            }
        }
    }

    private var autoSourceName: String? {
        switch autoSource {
        case .pocket(let id):  return collections.pocket(id)?.name
        case .setlist(let id): return collections.setlist(id)?.name ?? "Set list"
        case nil:              return nil
        }
    }

    /// In-CONTENT Auto-mode setup row (shown in Auto mode before a mix starts): the collection
    /// picker + ▶ Play / 🔀 Shuffle. Lives in the body — NOT the toolbar — so it's always reachable on
    /// iPhone portrait, where the trailing toolbar collapses these into a nested "•••" overflow.
    private var autoSetupBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
                Menu {
                    autoSourceMenuItems
                } label: {
                    Label(autoSourceName ?? engine.autoSourceLabel ?? "Pick a collection",
                          systemImage: "rectangle.stack")
                        .lineLimit(1)
                }
                .accessibilityIdentifier("mix-auto-source")
                Spacer(minLength: 8)
                Button { startAuto(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(autoSource == nil)
                    .help("Auto-mix this collection in order")
                    .accessibilityIdentifier("mix-auto-play")
                Button { startAuto(shuffled: true) } label: {
                    Label("Shuffle", systemImage: "shuffle").labelStyle(.iconOnly)
                }
                .disabled(autoSource == nil)
                .help("Auto-mix this collection shuffled")
                .accessibilityIdentifier("mix-auto-shuffle")
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            glideToggles                                  // FX Glide · Mix Glide (arm before Play)
        }
        .padding(12)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
        // NO accessibilityIdentifier on this HStack: an id on a button *container* merges the children
        // into one element, hiding mix-auto-play / mix-auto-shuffle from the a11y tree (and UI tests).
        // See the native-playlist-toolbar-overflow lesson.
    }

    /// In-body banner so the Stop control + progress are reachable on iPhone (where a crowded
    /// nav bar can hide toolbar items).
    private var autoMixBanner: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.autoPaused ? "Auto-mix paused" : "Auto-mixing")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                    if let status = engine.autoStatus {
                        Text(status).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    }
                }
                Spacer()
                // Pause / Resume — walk away, hand-mix, come back — next to Stop (in-body so it stays
                // reachable on iPhone). Toggles: Pause a running mix; Resume a paused one (playback +
                // recording keep running through a pause; Resume re-arms the transition machine).
                if engine.autoPaused {
                    Button { engine.resumeAuto() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent2)
                        .accessibilityIdentifier("mix-auto-resume")
                } else {
                    Button { engine.pauseAuto() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent2)
                        .accessibilityIdentifier("mix-auto-pause")
                }
                Button(role: .destructive) { engine.stopAutoMix() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .accessibilityIdentifier("mix-auto-stop-banner")
            }
            glideToggles                                  // FX Glide · Mix Glide (toggle mid-mix too)
        }
        .padding(12)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
        // NO accessibilityIdentifier on this container: a button-container id merges the children into
        // one a11y element, hiding mix-auto-stop-banner / mix-fx-glide / mix-mix-glide (which must stay
        // reachable to flip mid-mix). Same lesson as autoSetupBar + the native-playlist-toolbar-overflow note.
    }

    /// The two auto-mix transition toggles that ride the auto-mix pill (both the pre-mix setup bar and
    /// the during-mix banner, so they're reachable to arm before Play AND to flip mid-mix). FX Glide
    /// sweeps a coherent effect across each transition; Mix Glide bends bpm+pitch with beat sync.
    private var glideToggles: some View {
        HStack(spacing: 8) {
            GlidePillToggle(title: "FX Glide", systemImage: "slider.horizontal.2.gobackward",
                            isOn: engine.fxGlideEnabled, a11y: "mix-fx-glide") {
                engine.setFXGlide(!engine.fxGlideEnabled)
            }
            .help("Sweep a coherent effect through each auto-mix transition")
            GlidePillToggle(title: "Mix Glide", systemImage: "dial.medium",
                            isOn: engine.mixGlideEnabled, a11y: "mix-mix-glide") {
                engine.setMixGlide(!engine.mixGlideEnabled)
            }
            .help("Glide bpm + pitch (Camelot ±1 key) with beat sync through each transition")
            Spacer(minLength: 0)
        }
    }

    /// In-content recording status (● Recording m:ss + Stop) — shown while a recording runs. Keeps the
    /// record state + a Stop control visible even if the toolbar button overflows on iPhone; the
    /// pulsing dot mirrors the toolbar button's purple→red pulse.
    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            // Stalled capture (engine stopped and unrecovered — no media reaching the take):
            // amber warning triangle instead of the healthy pulsing dot, so the indicator never
            // pulses reassuringly over a dead take.
            if recorder.captureStalled {
                Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.orange)
            } else {
                Image(systemName: "record.circle.fill").font(.title3).modifier(RecordPulse(active: true))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(recorder.captureStalled ? "Recording — no audio" : "Recording")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(recorder.captureStalled ? Color.orange : Theme.fg)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.elapsedClock(sinceMs: recorder.startedAtMs))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
            }
            Spacer()
            Button(role: .destructive) { recorder.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityIdentifier("mix-record-stop")
        }
        .padding(12)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder((recorder.captureStalled ? Color.orange : Color.red).opacity(0.5), lineWidth: 1))
        .accessibilityIdentifier("mix-record-indicator")
    }

    /// Elapsed recording clock (m:ss) from the recorder's start epoch-ms.
    private static func elapsedClock(sinceMs startMs: Double) -> String {
        let s = Int(max(0, Date().timeIntervalSince1970 * 1000 - startMs) / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Build the queue from the chosen collection (resolver order) + each song's catalog length,
    /// then hand it to the engine with the Settings-configured lead/fade. Shuffle is applied in
    /// the engine so order/shuffle share one path.
    /// With Auto mode on + a collection chosen, mirror it onto BOTH decks' load source so hand-loading
    /// more tracks during a Pause takes no per-deck source picking. Only mirrors while Auto is enabled;
    /// a manual per-deck source change afterwards is left as-is (this fires on collection / mode change).
    private func syncDeckSourcesToAuto() {
        guard engine.autoEnabled, let s = autoSource else { return }
        sourceA = s
        sourceB = s
    }

    private func startAuto(shuffled: Bool) {
        guard let src = autoSource else { return }
        sourceA = src; sourceB = src           // both decks browse the auto collection (for hand-loading on Pause)
        let loadables = MixResolver(app: app, collections: collections, burns: burns, studio: studio).loadables(for: src)
        let items = loadables.map { l in
            MixEngine.AutoMixItem(loadable: l, durationMs: l.lengthMs ?? 180_000)
        }
        engine.startAutoMix(items, shuffled: shuffled,
                            lead: settings.autoMixLeadSeconds, fade: settings.autoMixFadeSeconds,
                            label: autoSourceName)
        // Donate the equivalent App Intent so Siri/Spotlight learn this habit.
        IntentDonations.startedAutoMix(source: src, shuffle: shuffled, collections: collections)
    }

    /// The single bottom Play/Pause — starts/stops BOTH decks (and the engine). Mirrors the
    /// example app's startPlayback/pausePlayback.
    private var masterTransport: some View {
        Button { engine.toggleAll() } label: {
            Label(engine.isRunning ? "Pause both decks" : "Play both decks",
                  systemImage: engine.isRunning ? "pause.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        // Nothing loaded ⇒ no audio to drive; keep the transport from reporting "playing" silence.
        .disabled(engine.loaded(.a) == nil && engine.loaded(.b) == nil)
        .accessibilityIdentifier("mix-play")
    }

    /// Auto-Mix only: advance to the next queued track. SINGLE tap = crossfade over the configured
    /// Skip-fade (Settings ▸ Mix, default 15 s); DOUBLE tap = a fast 5 s sweep. It is a plain tappable
    /// view (NOT a `Button`) so a double tap doesn't ALSO fire the single-tap action — a Button's
    /// primary action fires on the first tap. `count: 2` is declared first so SwiftUI disambiguates a
    /// double tap to the fast path; a lone tap fires after the short disambiguation delay.
    private var skipButton: some View {
        HStack(spacing: 8) {
            Image(systemName: "forward.fill")
            Text("Skip to next")
            Text("· double-tap = fast").font(.caption).foregroundStyle(Theme.fgDim)
        }
        .font(.headline)
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .onTapGesture(count: 2) { engine.skipToNext(fadeSeconds: 5) }                       // fast sweep
        .onTapGesture(count: 1) { engine.skipToNext(fadeSeconds: settings.skipFadeSeconds) } // configurable
        .accessibilityIdentifier("mix-auto-skip")
        .accessibilityLabel("Skip to next track")
        .accessibilityHint("Double-tap for a fast five second sweep")
    }
}

// MARK: - One deck

/// A single deck (A or B): header (waveform + artwork + artist/title + key/bpm) over a Rate
/// slider, a 2×2 effects grid, a Vol slider, and a per-deck play/pause. The header is the
/// track-loader trigger (tap, plus a `.contextMenu` for right-click/long-press), and carries a
/// quick SOURCE menu so a deck can be re-pointed without opening the sheet.
private struct DeckView: View {
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(BurnStore.self) private var burns
    @Environment(RipsStore.self) private var rips
    @Environment(SettingsStore.self) private var settings
    @Environment(StudioStore.self) private var studio   // positional cue points, keyed by songId

    let deck: MixEngine.Deck
    let engine: MixEngine
    @Binding var source: MixSource?
    /// Open the track-loader sheet for this deck (owned by MixView).
    let onLoad: () -> Void

    // iPhone portrait packs two decks into a narrow width — show Lead/Sync as icons only there.
    // Size classes are iOS-only (unavailable on plain macOS), so guard the env reads.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    #endif

    /// Local, recomputed-once-per-load waveform peaks (R3 reads the burned file off the main
    /// actor; keyed on the loaded songId so it fires exactly once per track — never on a redraw).
    @State private var peaks: [Float] = []

    private var loaded: MixEngine.LoadedTrack? { engine.loaded(deck) }
    private var a11y: String { "deck-\(deck.rawValue)" }      // "deck-A" / "deck-B"
    /// The loaded track has server-side stems (⇒ show the stem-mode toggle; tapping it burns the
    /// stems locally if needed, then enters stem mode).
    private var stemmed: Bool { loaded.map { rips.isStemmed($0.songId) } ?? false }

    /// iPhone portrait (cramped two-deck width) → render Lead/Sync icon-only; macOS/iPad keep labels.
    private var compactControls: Bool {
        #if os(iOS)
        return hSizeClass == .compact && vSizeClass == .regular
        #else
        return false
        #endif
    }

    /// A Lead/Sync label that drops its text (icon-only) in iPhone portrait. `.iconOnly` keeps the
    /// title in the accessibility tree, so VoiceOver still reads "Lead"/"Sync".
    @ViewBuilder private func sizedLabel(_ title: String, systemImage: String) -> some View {
        let label = Label(title, systemImage: systemImage)
        if compactControls { label.labelStyle(.iconOnly) } else { label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            deckLabel
            header
            DeckSeekSlider(engine: engine, deck: deck)   // playback position scrubber (drag to seek)
            cueJumpRow                                   // color-coded jump-to-cue buttons (if the track has cues)
            transportRow                                 // ↺ rewind · Sync to Lead
            tempoSlider                                  // live time-stretch (pitch preserved)
            pitchSlider                                  // live pitch shift (tempo preserved)
            effectsGrid                                  // tap = toggle · long-press / right-click = strength
            if engine.stemActive(deck) { stemGrid }      // 2×2 stem pads — only while in stem mode
            DeckVUMeter(engine: engine, deck: deck, a11y: a11y)   // level; right-click/long-press → pre/post
            volSlider
            playButton
        }
        .padding(10)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
        // Beat pulse (opt-in, Settings ▸ Mix, default off): a glowing ring that flashes on every beat
        // (downbeats brighter) so you can SEE each deck's groove and eyeball-align the two while
        // beat-matching. Isolated subview so its ~10 Hz updates never re-render the rest of the deck;
        // not created at all when disabled, so it costs nothing.
        .overlay { if settings.beatPulseEnabled { BeatPulseView(engine: engine, deck: deck).allowsHitTesting(false) } }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(a11y)
        .task(id: loaded?.songId) {                            // compute peaks once per loaded track
            guard let id = loaded?.songId else { peaks = []; return }
            // Song length (ms) windows an analog shared-album file to its own slice (digital: ignored).
            peaks = await MixWaveform.peaks(forSong: id, lengthMs: app.songsById[id]?.length, burns: burns)
        }
    }

    // Deck letter + quick source picker (pocket / set list).
    private var deckLabel: some View {
        HStack(spacing: 8) {
            Text("Deck \(deck.rawValue)")
                .font(.headline).foregroundStyle(Theme.fg)
            Spacer()
            sourceMenu
        }
    }

    // ★ "Lead" — designate this deck as the beat-match LEAD (exclusive; tapping the current lead
    // clears it). Lives next to Sync (left of it) so it reads as the reference Sync matches to.
    private var leadButton: some View {
        Button { engine.setLead(deck) } label: {
            sizedLabel("Lead", systemImage: engine.isLead(deck) ? "star.fill" : "star")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(engine.isLead(deck) ? Theme.accent.opacity(0.25) : Theme.bgOverlay,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(engine.isLead(deck) ? Theme.accent : Theme.border, lineWidth: 1))
                .foregroundStyle(engine.isLead(deck) ? Theme.accent : Theme.fgDim)
        }
        .buttonStyle(.plain)
        .help(engine.isLead(deck) ? "Lead deck (tempo reference) — tap to clear" : "Make this the Lead deck (beat-match reference)")
        .accessibilityIdentifier("\(a11y)-lead")
        .accessibilityAddTraits(engine.isLead(deck) ? .isSelected : [])
    }

    private var sourceMenu: some View {
        Menu {
            if collections.pockets.isEmpty && collections.setlists.isEmpty {
                Text("No pockets or set lists yet")
            }
            if !collections.pockets.isEmpty {
                Section("Pockets") {
                    ForEach(collections.pockets) { p in
                        Button(p.name) { source = .pocket(p.id) }
                    }
                }
            }
            if !collections.setlists.isEmpty {
                Section("Set lists") {
                    ForEach(collections.setlists) { s in
                        Button(s.name ?? "Set list") { source = .setlist(s.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.stack")
                Text(sourceName ?? "Pick source").lineLimit(1)
            }
            .font(.caption).foregroundStyle(Theme.accent2)
        }
        .accessibilityIdentifier("\(a11y)-source")
    }

    // Waveform + artwork + artist/title + key|bpm. The whole header loads a track on tap,
    // and (per spec) via long-press/right-click — the discoverable + the documented path.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            MixWaveformView(peaks: peaks)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 8) {
                artwork.frame(width: 46, height: 46)
                if let loaded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loaded.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.fg).lineLimit(1)
                        Text(loaded.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                        keyOrBpm(loaded)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Load a track").font(.subheadline).foregroundStyle(Theme.fg)
                        Text("Tap, or long-press / right-click")
                            .font(.caption2).foregroundStyle(Theme.fgDim)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onLoad() }
        .contextMenu {                                         // right-click (macOS) · long-press (iOS)
            Button { onLoad() } label: { Label("Load track…", systemImage: "tray.and.arrow.down") }
        }
        .accessibilityIdentifier("\(a11y)-load")
    }

    @ViewBuilder private var artwork: some View {
        if let albumId = loaded?.albumId, let album = app.albumsById[albumId] {
            CoverImage(album: album, corner: 6)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.bgOverlay)
                .overlay(Image(systemName: "opticaldisc").foregroundStyle(Theme.fgDim))
        }
    }

    // Camelot chip (when known) PLUS the beat-grid BPM — the measured grid BPM the engine syncs on
    // (falls back to the catalog BPM). Placeholder chip only when neither key nor BPM is known.
    @ViewBuilder private func keyOrBpm(_ t: MixEngine.LoadedTrack) -> some View {
        let bpm = beatGridBpmLabel(t)
        HStack(spacing: 6) {
            if let cam = t.camelot, !cam.isEmpty {
                KeyChip(key: t.key, camelot: cam)
            }
            if let bpm {
                Text(bpm).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("\(a11y)-gridbpm")
            }
            if (t.camelot?.isEmpty ?? true) && bpm == nil {
                KeyChip(key: nil, camelot: nil)
            }
        }
    }

    /// The BPM to show on the deck: the MEASURED beat-grid BPM (one decimal — the one beat-matching
    /// uses) when present, else the rounded catalog BPM, else nil.
    private func beatGridBpmLabel(_ t: MixEngine.LoadedTrack) -> String? {
        if let g = t.gridBpm, g > 0 { return String(format: "%.1f BPM", g) }
        if let b = t.bpm, b > 0 { return "\(Int(b.rounded())) BPM" }
        return nil
    }

    // Lead · Sync · Reset. Lead (left) is the beat-match reference; Sync matches this deck's tempo
    // (and best-effort aligns beats) to the Lead; Reset (↺) clears the whole deck + rewinds.
    private var transportRow: some View {
        HStack(spacing: 8) {
            leadButton
            Button { engine.syncToLead(deck) } label: {
                sizedLabel("Sync", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent2)
            .disabled(!engine.canSync(deck))
            .help("Match this deck's tempo to the Lead deck (downbeat alignment is best-effort)")
            .accessibilityIdentifier("\(a11y)-sync")
            // Stem mode (between Sync and Reset) — only for a track that HAS stems.
            if stemmed {
                StemModeButton(deck: deck, engine: engine, songId: loaded?.songId ?? "",
                               compact: compactControls, a11y: "\(a11y)-stemmode")
            }
            // LOOP (∞), immediately right of the stem icon — tap for a 2-unit loop off the
            // previous boundary; long-press / right-click for length + edge nudges.
            LoopButton(engine: engine, deck: deck, enabled: loaded != nil, a11y: "\(a11y)-loop")
            Spacer()
            // CUE / PFL — tap to monitor this deck on the cue channel (house mix untouched);
            // long-press / right-click for its cue-volume slider. Just left of Reset.
            CueButton(engine: engine, deck: deck, enabled: loaded != nil, a11y: "\(a11y)-cue")
            // TAP ↺ resets tempo/pitch/effects/volume + rewinds (keeps the track). LONG-PRESS /
            // RIGHT-CLICK ejects the track entirely, returning the deck to the empty zero state.
            Button { engine.resetDeck(deck) } label: {
                Image(systemName: "arrow.counterclockwise").font(.callout)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .disabled(loaded == nil)
            .help("Reset deck — tap: clear tempo, pitch, effects & volume, then rewind · long-press / right-click: eject the track to an empty deck")
            .accessibilityIdentifier("\(a11y)-restart")
            .contextMenu {
                Button(role: .destructive) { engine.clearDeck(deck) } label: {
                    Label("Clear deck (eject track)", systemImage: "eject")
                }
                .accessibilityIdentifier("\(a11y)-clear")
            }
        }
    }

    private var tempoSlider: some View {
        DeckSlider(title: "Tempo",
                   display: String(format: "%.2f×", engine.rate(deck)),
                   value: engine.rate(deck),
                   range: MixEngine.rateRange, step: 0.01,
                   a11y: "\(a11y)-tempo") { engine.setRate($0, on: deck) }
    }

    private var pitchSlider: some View {
        let p = engine.pitch(deck)
        return DeckSlider(title: "Pitch",
                          display: p == 0 ? "0" : String(format: "%+.1f", p),
                          value: p,
                          range: MixEngine.pitchRange, step: 0.1,
                          a11y: "\(a11y)-pitch") { engine.setPitch($0, on: deck) }
    }

    /// Jump-to-cue buttons for the loaded track's positional cue points (set in the Performance ▸
    /// Cues tab, keyed by songId in `StudioStore`). Up to 8 cues render as a 4-wide grid → at most
    /// TWO rows, each chip stable-colored by slot (matching the Studio tab). Tapping seeks the deck
    /// to the cue — `StudioCue.positionMs` is song-relative from 0:00, exactly what `seek(toSeconds:)`
    /// wants. Absent entirely when the track has no cues, so it costs nothing for un-cued tracks.
    @ViewBuilder private var cueJumpRow: some View {
        if let songId = loaded?.songId {
            let cues = studio.cues(forSong: songId)
            if !cues.isEmpty {
                // NO accessibilityIdentifier on this grid: an id on a button *container* merges the
                // child cue buttons into one a11y element, hiding each `deck-X-cue-N` id/label (the
                // toolbar-overflow lesson). The per-cue ids below are the targets.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(cues) { cue in cueButton(cue) }
                }
            }
        }
    }

    private func cueButton(_ cue: StudioCue) -> some View {
        let color = StudioCuesView.slotColor(cue.slot)
        return Button {
            engine.seek(deck, toSeconds: Double(cue.positionMs) / 1000)
        } label: {
            VStack(spacing: 1) {
                Text(cue.name ?? "\(cue.slot + 1)")
                    .font(.caption2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                Text(Self.cueClock(cue.positionMs))
                    .font(.system(size: 9).monospacedDigit()).opacity(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .padding(.vertical, 3).padding(.horizontal, 2)
            .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(color, lineWidth: 1))
            .foregroundStyle(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(a11y)-cue-\(cue.slot)")
        .accessibilityLabel("Jump to cue \(cue.slot + 1)\(cue.name.map { ", \($0)" } ?? ""), \(StudioCuesView.stamp(cue.positionMs))")
    }

    /// Compact "m:ss" for a cue chip (the Studio tab's `stamp` carries millis — too wide here).
    private static func cueClock(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // Gain to 200%. >100% is a boost (gold value + "+N dB" suffix, not color-only) backed by the
    // deck EQ globalGain + a master limiter. A drag snaps to unity (0 dB) within a small epsilon.
    private var volSlider: some View {
        let v = engine.volume(deck)
        let pct = Int((v * 100).rounded())
        let boosted = v > 1.0001
        let dB = 20 * log10(max(v, 0.0001))
        let dBStr = String(format: "%.1f", dB)
        return DeckSlider(title: "Vol",
                          display: boosted ? "\(pct)% · +\(dBStr)dB" : "\(pct)%",
                          value: v,
                          range: MixEngine.volumeRange, step: 0.05,
                          a11y: "\(a11y)-vol",
                          tint: boosted ? Theme.accent2 : Theme.accent,
                          valueColor: boosted ? Theme.accent2 : Theme.fg,
                          accessibilityValueText: boosted ? "\(pct) percent, plus \(dBStr) decibels" : "\(pct) percent") {
            engine.setVolume(abs($0 - 1.0) < 0.03 ? 1.0 : $0, on: deck)   // snap to unity by drag
        }
    }

    // 2×2 grid: Compressor · Reverb (top), Flanger · Filter (bottom).
    private var effectsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                  spacing: 6) {
            ForEach(MixEngine.Effect.allCases) { fx in
                EffectButton(effect: fx,
                             isOn: engine.isEnabled(fx, on: deck),
                             strength: engine.strength(fx, on: deck),
                             a11y: "\(a11y)-fx-\(fx.rawValue)",
                             onToggle: { engine.setEffect(fx, enabled: !engine.isEnabled(fx, on: deck), on: deck) },
                             onStrength: { engine.setEffectStrength(fx, $0, on: deck) })
            }
        }
    }

    // 2×2 stem grid (only shown in stem mode): TAP a pad = mute (greys out); long-press / right-click
    // = that stem's volume. Coloured per stem (red bass · yellow drums · green other · purple vocals).
    private var stemGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                  spacing: 6) {
            ForEach(MixEngine.stemNames, id: \.self) { name in
                StemPad(deck: deck, engine: engine, stem: name,
                        color: Self.stemColor(name), a11y: "\(a11y)-stem-\(name)")
            }
        }
    }

    /// The user-specified stem highlight colours.
    private static func stemColor(_ name: String) -> Color {
        switch name {
        case "bass":   return .red
        case "drums":  return .yellow
        case "other":  return .green
        case "vocals": return .purple
        default:       return Theme.accent
        }
    }

    private var playButton: some View {
        Button { engine.togglePlay(deck) } label: {
            Image(systemName: engine.isPlaying(deck) ? "pause.fill" : "play.fill")
                .font(.title3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .disabled(loaded == nil)
        .accessibilityIdentifier("\(a11y)-play")
    }

    private var sourceName: String? {
        switch source {
        case .pocket(let id):  return collections.pocket(id)?.name
        case .setlist(let id): return collections.setlist(id)?.name ?? "Set list"
        case nil:              return nil
        }
    }
}

// MARK: - Auto-mix pill toggles

/// One capsule toggle chip on the auto-mix pill (FX Glide / Mix Glide). Accent-filled + "selected"
/// when on. A plain `Button` (these aren't long-pressable, unlike the deck effect chips).
private struct GlidePillToggle: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let a11y: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(isOn ? Theme.accent2.opacity(0.25) : Theme.bgOverlay, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Theme.accent2 : Theme.border, lineWidth: 1))
                .foregroundStyle(isOn ? Theme.accent2 : Theme.fgDim)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(a11y)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Record button

/// The top-level Mix toolbar RECORD button. Idle = a dim record ring; recording = a purple→red
/// gradient record icon that PULSES (breathes). Tapping toggles recording of the mix's house output
/// into the current session's folder. App-scoped recorder, so it survives leaving the tab.
/// The recorder taps the mix's OWN audio graph, and that graph is fed exclusively by on-device
/// files (`MixResolver` keeps only ids whose burned/studio file exists; `MixEngine.load` opens
/// them through `BurnStore`) — it never records from Apple Music or any other stream.
private struct RecordButton: View {
    let recorder: MixRecorder
    var body: some View {
        Button { recorder.toggle() } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "record.circle")
                .modifier(RecordPulse(active: recorder.isRecording))
        }
        .help(recorder.isRecording ? "Stop recording the mix"
                                   : "Record the mix audio into this session")
        .accessibilityIdentifier("mix-record")
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record mix")
        .accessibilityValue(recorder.isRecording ? "Recording" : "Off")
        .accessibilityAddTraits(recorder.isRecording ? .isSelected : [])
    }
}

/// Purple→red gradient fill + a breathing pulse while `active`; a plain dim tint when idle. Isolated
/// modifier so the repeating animation lives with the icon (the toolbar button + the in-content dot
/// share it). The pulse is a single value flip driven into a `repeatForever` animation on appear.
private struct RecordPulse: ViewModifier {
    let active: Bool
    @State private var pulse = false
    func body(content: Content) -> some View {
        if active {
            content
                .foregroundStyle(LinearGradient(colors: [.purple, .red],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .scaleEffect(pulse ? 1.12 : 0.94)
                .opacity(pulse ? 1 : 0.65)
                .shadow(color: .red.opacity(pulse ? 0.6 : 0), radius: pulse ? 5 : 0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
                .onDisappear { pulse = false }
        } else {
            content.foregroundStyle(Theme.fgDim)
        }
    }
}

// MARK: - Cue (PFL) button + beat pulse

/// The per-deck CUE / pre-fade-listen button (left of Reset). TAP toggles the deck's cue send on the
/// monitor channel (the house mix is untouched). LONG-PRESS (iOS) / RIGHT-CLICK (macOS) reveals a
/// fixed-width cue-VOLUME popover (the cue level is independent of the deck's main Vol fader). A plain
/// tappable view, NOT a Button, so the long-press isn't swallowed (same reason as `EffectButton`).
// MARK: - Loop (∞) chip

/// The deck's LOOP control, sitting immediately right of the stem icon.
///   • TAP — engage/release. Engaging snaps back to the PREVIOUS boundary and repeats 2 units
///     (a 2-beat loop when the track has a grid; a 2-second loop when it doesn't).
///   • LONG-PRESS / RIGHT-CLICK — the length popover: a 1…32 slider plus ← → arrows on each end
///     that walk the loop's START and END one unit at a time.
/// Not a `Button` for the same reason as `CueButton`/`EffectButton`: a real Button swallows the
/// long-press. Works in BOTH playback modes — a stem deck loops all four synced stem nodes — so
/// it's disabled only when the deck has no track.
private struct LoopButton: View {
    let engine: MixEngine
    let deck: MixEngine.Deck
    let enabled: Bool
    let a11y: String
    @State private var showPopover = false

    var body: some View {
        let on = engine.loopOn(deck)
        Image(systemName: "infinity")
            .font(.callout)
            .frame(minHeight: 18)
            .padding(.vertical, 6).padding(.horizontal, 9)
            .background(on ? Theme.accent.opacity(0.25) : Theme.bgOverlay,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: 1))
            .foregroundStyle(!enabled ? Theme.fgDim.opacity(0.4) : (on ? Theme.accent : Theme.fgDim))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture { if enabled { engine.setLoop(deck, on: !on) } }
            .onLongPressGesture(minimumDuration: 0.4) { if enabled { showPopover = true } }
            #if os(macOS)
            .overlay { if enabled { SecondaryClick { showPopover = true } } }
            #endif
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                LoopLengthPopover(engine: engine, deck: deck, presented: $showPopover, a11y: a11y)
            }
            .help("Loop — tap to loop 2 \(engine.loopUsesBeats(deck) ? "beats" : "seconds") from the previous "
                  + "\(engine.loopUsesBeats(deck) ? "beat" : "second") · long-press for length and in/out nudges")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loop")
            .accessibilityValue(on ? "On, \(Int(engine.loopUnits(deck))) \(engine.loopUsesBeats(deck) ? "beats" : "seconds")" : "Off")
            .accessibilityIdentifier(a11y)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The loop popover: LENGTH (1…32 units) plus per-edge ← → nudges. Fixed width + compact-adaptation
/// + 3 s idle auto-dismiss, matching `ChipStrengthPopover` (an in-place slider is undraggable in
/// iPhone portrait). Adjusting anything ENGAGES the loop — dialling a length you can't hear is a
/// dead control (the `StemPad.reveal()` precedent).
private struct LoopLengthPopover: View {
    let engine: MixEngine
    let deck: MixEngine.Deck
    @Binding var presented: Bool
    let a11y: String
    @State private var interaction = 0
    /// True while a slider drag is in progress — a finger held STILL bumps nothing, so without
    /// this the 3 s idle timer would close the popover out from under the drag.
    @State private var editing = false

    private var unitName: String { engine.loopUsesBeats(deck) ? "beat" : "sec" }

    var body: some View {
        let units = engine.loopUnits(deck)
        VStack(alignment: .leading, spacing: 12) {
            Label("Loop length", systemImage: "infinity")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            HStack(spacing: 8) {
                // LEFT pair — walk the loop's START edge back / forward one unit.
                nudge("arrow.left", edge: .start, delta: -1, id: "\(a11y)-start-back")
                nudge("arrow.right", edge: .start, delta: 1, id: "\(a11y)-start-fwd")
                Slider(value: Binding(get: { units },
                                      set: { engage(); engine.setLoopUnits(deck, $0); interaction += 1 }),
                       in: 1...32, step: 1,
                       onEditingChanged: { editing = $0; if !$0 { interaction += 1 } })
                    .tint(Theme.accent)
                    .accessibilityIdentifier("\(a11y)-length")
                // RIGHT pair — walk the loop's END edge back / forward one unit.
                nudge("arrow.left", edge: .end, delta: -1, id: "\(a11y)-end-back")
                nudge("arrow.right", edge: .end, delta: 1, id: "\(a11y)-end-fwd")
            }
            Text("\(Int(units)) \(unitName)\(Int(units) == 1 ? "" : "s")"
                 + (engine.loopUsesBeats(deck) ? "" : " — no beat grid on this track"))
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
        }
        .padding(16)
        .frame(width: 320)                              // fixed width — room to actually drag
        .presentationCompactAdaptation(.popover)        // stay a popover on iPhone (not a sheet)
        .task(id: interaction) {                        // 3 s idle auto-dismiss
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, !editing { presented = false }
        }
    }

    private func nudge(_ icon: String, edge: MixEngine.LoopEdge, delta: Double, id: String) -> some View {
        Button {
            engage()
            engine.nudgeLoop(deck, edge: edge, byUnits: delta)
            interaction += 1
        } label: {
            Image(systemName: icon).font(.caption.weight(.semibold))
                .frame(width: 26, height: 26)
                .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.fgDim)
        .accessibilityLabel("\(edge == .start ? "Loop in" : "Loop out") \(delta < 0 ? "back" : "forward") one \(unitName)")
        .accessibilityIdentifier(id)
    }

    /// The nudges act on a LIVE window, so a length tweak from the released state engages first.
    private func engage() {
        if !engine.loopOn(deck) { engine.setLoop(deck, on: true) }
    }
}

private struct CueButton: View {
    let engine: MixEngine
    let deck: MixEngine.Deck
    let enabled: Bool
    let a11y: String
    @State private var showPopover = false

    var body: some View {
        let on = engine.cued(deck)
        Image(systemName: "headphones")
            .font(.callout)
            .frame(minHeight: 18)
            .padding(.vertical, 6).padding(.horizontal, 9)
            .background(on ? Theme.accent2.opacity(0.25) : Theme.bgOverlay,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(on ? Theme.accent2 : Theme.border, lineWidth: 1))
            .foregroundStyle(!enabled ? Theme.fgDim.opacity(0.4) : (on ? Theme.accent2 : Theme.fgDim))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture { if enabled { engine.toggleCue(deck) } }
            .onLongPressGesture(minimumDuration: 0.4) { if enabled { showPopover = true } }
            #if os(macOS)
            .overlay { if enabled { SecondaryClick { showPopover = true } } }
            #endif
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                ChipStrengthPopover(title: "Cue level", systemImage: "headphones", tint: Theme.accent2,
                                    value: engine.cueVolume(deck), step: 0.05, a11y: "\(a11y)-vol",
                                    presented: $showPopover,
                                    onChange: { engine.setCueVolume($0, on: deck) })
            }
            .help("Cue (pre-fade listen) — tap to monitor on the cue channel · long-press for cue level")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cue")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityIdentifier(a11y)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A glowing ring that flashes the deck container on each beat — downbeats brighter/longer — so you
/// can feel the groove and visually align the two decks while beat-matching. Beats are synthesized
/// from the measured grid BPM (or catalog BPM) + the first-downbeat phase; the ~10 Hz playhead drives
/// detection, the flash itself is a smooth SwiftUI animation. Its own struct so these frequent
/// updates re-render ONLY the overlay, never the whole deck (same isolation as `DeckSeekSlider`).
private struct BeatPulseView: View {
    let engine: MixEngine
    let deck: MixEngine.Deck

    var body: some View {
        // Drive the flash at display rate (60 fps) so it's smooth and PHASE-LOCKED to the real audio;
        // paused (no redraws) while the deck is stopped. Computing intensity directly each frame means
        // the pulse can't get "stuck" — there's no peak/decay state to coalesce away.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !engine.isPlaying(deck))) { _ in
            let env = envelope()
            let color = env.down ? Theme.accent : Theme.accent2
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(color, lineWidth: 1 + 3 * env.intensity)
                .shadow(color: color.opacity(0.7 * env.intensity), radius: 9 * env.intensity)
                .opacity(env.intensity)
        }
    }

    /// The pulse intensity (0…1) + whether the current beat is a bar downbeat, from the TRUE audio
    /// playhead (so it tracks exactly what you hear, including tempo changes). The flash decays in
    /// WALL-CLOCK time — `elapsed source seconds since the last beat ÷ rate` — so it looks the same at
    /// any tempo while the beat SPACING follows the playing tempo.
    private func envelope() -> (intensity: Double, down: Bool) {
        guard engine.isPlaying(deck), let track = engine.loaded(deck) else { return (0, false) }
        let pos = engine.truePlayhead(deck) ?? engine.position(deck)
        guard let (lastBeatSec, down) = lastBeat(track, at: pos) else { return (0, false) }
        let rate = max(engine.rate(deck), 0.05)
        let elapsedWall = max(0, pos - lastBeatSec) / rate
        let decay = down ? 0.34 : 0.22
        let t = max(0, 1 - elapsedWall / decay)
        return (t * t, down)                           // quadratic ease — snappier attack/decay
    }

    /// The most recent beat at/just before `pos` (source seconds) + whether it's a bar downbeat. Uses
    /// the REAL per-beat grid (`beatsMs`, burned/fetched) when present — so a tempo-DRIFTING track
    /// pulses on its actual beats (the binary searches live in the shared `BeatMath`, also used by
    /// Studio loop slicing) — otherwise synthesizes a constant grid from the measured BPM + the
    /// first-downbeat phase. nil before the first beat / when there's no grid at all.
    private func lastBeat(_ t: MixEngine.LoadedTrack, at pos: Double) -> (sec: Double, down: Bool)? {
        let posMs = pos * 1000
        if let beats = t.beatsMs, !beats.isEmpty {
            guard let hit = BeatMath.lastBeat(beatsMs: beats, downbeatsMs: t.downbeatsMs, atMs: posMs) else { return nil }
            return (Double(hit.beatMs) / 1000, hit.isDownbeat)
        }
        let bpm = (t.gridBpm ?? 0) > 0 ? (t.gridBpm ?? 0) : (t.bpm ?? 0)
        guard bpm > 0 else { return nil }
        let downSec = Double(t.firstDownbeatMs ?? 0) / 1000
        let secPerBeat = 60.0 / bpm
        let idx = floor((pos - downSec) / secPerBeat)
        guard idx >= 0 else { return nil }
        return (downSec + idx * secPerBeat, Int(idx).isMultiple(of: 4))   // every 4th beat = downbeat (4/4)
    }
}

// MARK: - Small controls

/// One −/＋ fine-adjust button, flanking a slider, that nudges `value` by `step` (clamped to
/// `range`). Disabled at the relevant bound. `onInteract` lets a host with an idle-revert timer
/// (the chip flip / popover) reset it on each tap so careful stepping doesn't dismiss mid-adjust.
// Reused by the F4 Now Playing mix mini-panel (NowPlayingMixPanel) — hence internal, not private.
struct StepButton: View {
    enum Dir { case dec, inc }
    let dir: Dir
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    var tint: Color = Theme.accent
    let a11y: String
    let onChange: (Double) -> Void
    var onInteract: () -> Void = {}

    private var target: Double {
        dir == .dec ? max(range.lowerBound, value - step) : min(range.upperBound, value + step)
    }
    private var enabled: Bool {
        dir == .dec ? value > range.lowerBound + 1e-9 : value < range.upperBound - 1e-9
    }

    var body: some View {
        Button { onChange(target); onInteract() } label: {
            Image(systemName: dir == .dec ? "minus" : "plus")
                .font(.caption2.weight(.bold))
                .frame(width: 24, height: 24)
                .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? tint : Theme.fgDim)
        .disabled(!enabled)
        .accessibilityIdentifier("\(a11y)-\(dir == .dec ? "dec" : "inc")")
        .accessibilityLabel(dir == .dec ? "Decrease" : "Increase")
    }
}

/// A labelled slider (title + live value) FLANKED by −/＋ steppers for finer-grain adjustment than a
/// drag. A manual `Binding` pushes straight into the engine. `tint`/`valueColor`/`accessibilityValueText`
/// let the Vol slider signal a >100% boost without being color-only.
// Reused by the F4 Now Playing mix mini-panel (NowPlayingMixPanel) — hence internal, not private.
struct DeckSlider: View {
    let title: String
    let display: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let a11y: String
    var tint: Color = Theme.accent
    var valueColor: Color = Theme.fg
    var accessibilityValueText: String? = nil
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Theme.fgDim)
                Spacer()
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(valueColor)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(spacing: 6) {
                StepButton(dir: .dec, value: value, range: range, step: step, tint: tint, a11y: a11y, onChange: onChange)
                Slider(value: Binding(get: { value }, set: onChange), in: range)
                    .tint(tint)
                    .accessibilityIdentifier(a11y)
                    .accessibilityValue(accessibilityValueText ?? display)
                StepButton(dir: .inc, value: value, range: range, step: step, tint: tint, a11y: a11y, onChange: onChange)
            }
        }
    }
}

/// Per-deck VU meter — sits above the volume slider, below the FX grid. A `TimelineView`-polled
/// bar off the engine's non-observable `MixDeckLevels` mirror (never touches Observation, so the
/// ~20 Hz redraw can't invalidate the rest of the deck — the `PlayerClock` doctrine). The body is a
/// blue→gold→pink gradient (RMS, one-pole-smoothed on the tap thread) with a fast peak-hold marker,
/// dB-scaled over −48…+3 dBFS, plus a header rhyming with `DeckSlider` (source tag + live peak dB).
/// RIGHT-CLICK (macOS) / LONG-PRESS (iOS) — both native via `.contextMenu` — switch the meter
/// between PRE-fader (post-FX, before volume/crossfade) and POST-fader (after it).
private struct DeckVUMeter: View {
    let engine: MixEngine
    let deck: MixEngine.Deck
    let a11y: String

    /// dB window the bar spans: floor (≈silence, left edge) → top (a hair above 0 dBFS, right edge).
    private static let floorDb: Float = -48
    private static let topDb: Float = 3

    /// Linear amplitude → 0…1 bar position on a dBFS scale.
    private static func norm(_ amp: Float) -> CGFloat {
        let db = 20 * log10(max(amp, 1e-6))
        return CGFloat(min(1, max(0, (db - floorDb) / (topDb - floorDb))))
    }

    /// Gradient stops pinned to dB ZONES (not to fill width): blue < −12 dB, gold −12…−3 dB,
    /// pink > −3 dB. Locations are `norm(-12 dBFS)` ≈ 0.706 and `norm(-3 dBFS)` ≈ 0.882.
    private static let zoneGradient = Gradient(stops: [
        .init(color: Theme.accent,  location: 0.0),
        .init(color: Theme.accent,  location: 0.706),
        .init(color: Theme.accent2, location: 0.716),
        .init(color: Theme.accent2, location: 0.882),
        .init(color: Theme.danger,  location: 0.892),
        .init(color: Theme.danger,  location: 1.0),
    ])

    var body: some View {
        let source = engine.meterSource(deck)
        return TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let lv = engine.levels(deck)
            let live = Date().timeIntervalSinceReferenceDate - lv.updatedAt < 0.3
            let peak = live ? (source == .pre ? lv.prePeak : lv.postPeak) : 0
            let rms  = live ? (source == .pre ? lv.preRMS  : lv.postRMS)  : 0
            let peakDb = 20 * log10(max(peak, 1e-6))
            VStack(alignment: .leading, spacing: 2) {
                header(source: source, peakDb: peakDb)
                bar(rms: rms, peak: peak, hot: peakDb >= -1)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { engine.setMeterSource(.pre, on: deck) } label: {
                Label("Pre-fader", systemImage: source == .pre ? "checkmark.circle.fill" : "circle")
            }
            .accessibilityIdentifier("\(a11y)-vu-pre")
            Button { engine.setMeterSource(.post, on: deck) } label: {
                Label("Post-fader", systemImage: source == .post ? "checkmark.circle.fill" : "circle")
            }
            .accessibilityIdentifier("\(a11y)-vu-post")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("\(a11y)-vu")
        .accessibilityLabel("Level meter, \(source == .pre ? "pre" : "post") fader")
    }

    private func header(source: MixEngine.MeterSource, peakDb: Float) -> some View {
        HStack(spacing: 6) {
            Text("VU").font(.caption).foregroundStyle(Theme.fgDim)
            Text(source == .pre ? "PRE" : "POST")
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
            Spacer()
            Text(peakDb <= Self.floorDb ? "−∞" : String(format: "%+.0f dB", Double(peakDb)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(peakDb >= -1 ? Theme.danger : Theme.fgDim)
                .lineLimit(1)
        }
    }

    private func bar(rms: Float, peak: Float, hot: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = Self.norm(rms) * w
            let px = Self.norm(peak) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bgOverlay)
                Capsule()
                    .fill(LinearGradient(gradient: Self.zoneGradient, startPoint: .leading, endPoint: .trailing))
                    // Reveal up to the RMS level; nothing at silence (no always-on nub), a clean
                    // minimum once there's signal so a tiny fill isn't a degenerate capsule.
                    .mask(alignment: .leading) { Capsule().frame(width: fill < 1 ? 0 : max(3, fill)) }
                if peak > 0.001 {
                    Capsule().fill(hot ? Theme.danger : Theme.fg)
                        .frame(width: 2.5)
                        .offset(x: min(w - 2.5, max(0, px - 1.25)))
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

/// One effect chip with an IN-PLACE flip: TAP toggles the effect; LONG-PRESS (iOS) / RIGHT-CLICK
/// (macOS) flips the chip — same footprint, no popover, no screen nav — to a strength slider so you
/// dial the wet amount right there. After 3 s with no interaction it flips back to the labelled
/// button, keeping you in the flow. Flipping to the slider also enables the effect (so the dial is
/// immediately audible). Accent-filled + "selected" when the effect is on.
// Reused by the F4 Now Playing mix mini-panel (NowPlayingMixPanel) — hence internal, not private.
struct EffectButton: View {
    let effect: MixEngine.Effect
    let isOn: Bool
    let strength: Double
    let a11y: String
    let onToggle: () -> Void
    let onStrength: (Double) -> Void

    /// In-place flip (landscape / iPad / macOS): showing the strength slider vs the labelled button.
    @State private var editing = false
    /// Bumped on every interaction (flip-in + each slider change) to (re)start the 3 s idle timer.
    @State private var interaction = 0
    /// iPhone-portrait path: present the strength slider as a fixed-width POPOVER (room to drag).
    @State private var showPopover = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    /// Use the fixed-width POPOVER on ALL compact widths (iPhone portrait AND landscape) — the chip is
    /// too narrow there for an in-place slider, let alone steppers. iPad/macOS (regular width) keep
    /// the roomy in-place flip, which now also carries the −/＋ steppers.
    private var useChipPopover: Bool { hSize == .compact }
    #else
    private var useChipPopover: Bool { false }
    #endif

    var body: some View {
        Group {
            if editing && !useChipPopover { sliderFace } else { buttonFace }
        }
        .animation(.easeInOut(duration: 0.15), value: editing)
        // In-place flip idle auto-revert: each interaction restarts this; 3 s idle flips back.
        .task(id: interaction) {
            guard editing else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { editing = false }
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            ChipStrengthPopover(title: effect.label, systemImage: effect.icon, tint: Theme.accent,
                                value: strength, step: 0.05, a11y: "\(a11y)-strength",
                                presented: $showPopover, onChange: onStrength)
        }
    }

    // TAP toggles; long-press (iOS) / right-click (macOS) flips to the strength slider. A plain
    // tappable view, NOT a Button — a SwiftUI Button swallows the long-press on iOS (the flip never
    // fired), so tap + long-press are explicit gestures here instead.
    private var buttonFace: some View {
        HStack(spacing: 4) {
            Image(systemName: effect.icon)
            Text(effect.label).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity, minHeight: 18)
        .padding(.vertical, 7)
        .background(isOn ? Theme.accent.opacity(0.25) : Theme.bgOverlay,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(isOn ? Theme.accent : Theme.border, lineWidth: 1))
        .foregroundStyle(isOn ? Theme.accent : Theme.fgDim)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        // Secondary gesture reveals the strength slider STRAIGHT away — no "Adjust strength…" step.
        .onTapGesture { onToggle() }
        .onLongPressGesture(minimumDuration: 0.4) { reveal() }
        #if os(macOS)
        .overlay(SecondaryClick { reveal() })
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(effect.label)
        .accessibilityIdentifier(a11y)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // The flipped-in strength slider (iPad / macOS — roomy) with −/＋ steppers. Each change (drag OR
    // step) restarts the idle timer so careful stepping doesn't auto-revert mid-adjust.
    private var sliderFace: some View {
        HStack(spacing: 5) {
            Image(systemName: effect.icon)
            StepButton(dir: .dec, value: strength, range: 0...1, step: 0.05, a11y: "\(a11y)-strength",
                       onChange: onStrength, onInteract: { interaction += 1 })
            Slider(value: Binding(get: { strength }, set: { onStrength($0); interaction += 1 }), in: 0...1)
                .controlSize(.small)
                .accessibilityIdentifier("\(a11y)-strength")
            StepButton(dir: .inc, value: strength, range: 0...1, step: 0.05, a11y: "\(a11y)-strength",
                       onChange: onStrength, onInteract: { interaction += 1 })
            Text("\(Int((strength * 100).rounded()))%")
                .monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity, minHeight: 18)
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1))
        .foregroundStyle(Theme.accent)
    }

    private func reveal() {
        if !isOn { onToggle() }     // dialling strength should be audible → enable on reveal
        if useChipPopover { showPopover = true }       // fixed-width popover (compact iPhone)
        else { editing = true; interaction += 1 }      // in-place flip (iPad / macOS)
    }
}

/// A fixed-width popover slider — used on iPhone PORTRAIT to dial an effect's strength or a stem's
/// volume, wide enough to actually drag (the in-place chip flip is too narrow there). Dismisses on
/// an outside tap (native popover) OR after 3 s with no slider interaction.
// Reused by the F4 Now Playing mix mini-panel (NowPlayingMixPanel) — hence internal, not private.
struct ChipStrengthPopover: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: Double
    let step: Double
    let a11y: String
    @Binding var presented: Bool
    let onChange: (Double) -> Void
    @State private var interaction = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold)).foregroundStyle(tint)
            HStack(spacing: 8) {
                StepButton(dir: .dec, value: value, range: 0...1, step: step, tint: tint, a11y: a11y,
                           onChange: onChange, onInteract: { interaction += 1 })
                Slider(value: Binding(get: { value }, set: { onChange($0); interaction += 1 }), in: 0...1)
                    .tint(tint)
                    .accessibilityIdentifier(a11y)
                StepButton(dir: .inc, value: value, range: 0...1, step: step, tint: tint, a11y: a11y,
                           onChange: onChange, onInteract: { interaction += 1 })
                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(width: 290)
        .presentationCompactAdaptation(.popover)       // stay a popover on iPhone (not a sheet)
        // Auto-dismiss after 3 s idle; each drag OR step bumps `interaction` and restarts the timer.
        .task(id: interaction) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { presented = false }
        }
    }
}

#if os(macOS)
/// Fires `action` on a macOS SECONDARY (right) click, while staying transparent to left-clicks (so
/// the chip's normal tap still toggles). Lets an effect chip reveal its slider IMMEDIATELY on
/// right-click — no context menu. The hitTest trick: claim the hit only when the in-flight event is
/// a right-click, else return nil so the click passes through to the SwiftUI button beneath.
private struct SecondaryClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(action) }
    func updateNSView(_ view: NSView, context: Context) { (view as? CatcherView)?.action = action }

    final class CatcherView: NSView {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let t = NSApp.currentEvent?.type
            return (t == .rightMouseDown || t == .rightMouseUp) ? self : nil
        }
        override func rightMouseDown(with event: NSEvent) { action() }
    }
}
#endif

/// The stem-mode toggle (between Sync and Reset, shown only for a track that HAS stems). TAP enters
/// stem mode — burning the 4 stems locally first if they aren't already (a brief spinner) — or exits
/// it. Accent-filled + "selected" while on.
private struct StemModeButton: View {
    let deck: MixEngine.Deck
    let engine: MixEngine
    let songId: String
    let compact: Bool          // iPhone portrait → icon-only (cramped two-deck row)
    let a11y: String
    @Environment(BurnStore.self) private var burns
    @State private var burning = false

    var body: some View {
        let on = engine.stemModeOn(deck)
        Button { toggle() } label: {
            label(on: on)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Theme.accent.opacity(0.25) : Theme.bgOverlay,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: 1))
                .foregroundStyle(on ? Theme.accent : Theme.fgDim)
        }
        .buttonStyle(.plain)
        .disabled(burning || songId.isEmpty)
        .help(on ? "Stem mode on — tap to exit"
                 : "Split this track into stems (vocals · drums · bass · other) for live mixing")
        .accessibilityIdentifier(a11y)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func label(on: Bool) -> some View {
        if burning {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); if !compact { Text("Stems") } }
        } else if compact {
            Image(systemName: "square.split.2x2")
        } else {
            Label("Stems", systemImage: "square.split.2x2")
        }
    }

    private func toggle() {
        if engine.stemModeOn(deck) { engine.setStemMode(false, on: deck); return }
        // Stems must be BURNED locally to play (no streaming). Burn first if needed, then enter.
        if burns.stemsBurned(forSong: songId) { engine.setStemMode(true, on: deck); return }
        burning = true
        Task {
            _ = await burns.burnStems(forSong: songId)
            burning = false
            engine.setStemMode(true, on: deck)
        }
    }
}

/// One pad in a deck's 2×2 stem grid (visible only in stem mode). TAP toggles MUTE (the pad greys
/// out); LONG-PRESS (iOS) / RIGHT-CLICK (macOS) dials that stem's VOLUME — an in-place flip on
/// landscape / iPad / macOS, a fixed-width popover on iPhone portrait (room to drag). Highlighted in
/// the stem's colour when audible.
private struct StemPad: View {
    let deck: MixEngine.Deck
    let engine: MixEngine
    let stem: String
    let color: Color
    let a11y: String

    @State private var editing = false
    @State private var interaction = 0
    @State private var showPopover = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    /// Compact iPhone (portrait + landscape) → popover; iPad/macOS → in-place flip (with steppers).
    private var useChipPopover: Bool { hSize == .compact }
    #else
    private var useChipPopover: Bool { false }
    #endif

    private var muted: Bool { engine.isStemMuted(stem, on: deck) }

    var body: some View {
        Group {
            if editing && !useChipPopover { sliderFace } else { padFace }
        }
        .animation(.easeInOut(duration: 0.15), value: editing)
        .task(id: interaction) {
            guard editing else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { editing = false }
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            ChipStrengthPopover(title: stem.capitalized, systemImage: Self.icon(stem), tint: color,
                                value: engine.stemVolume(stem, on: deck), step: 0.05, a11y: "\(a11y)-volume",
                                presented: $showPopover,
                                onChange: { engine.setStemVolume(stem, $0, on: deck) })
        }
    }

    private var padFace: some View {
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
        .onTapGesture { engine.toggleStemMute(stem, on: deck) }
        .onLongPressGesture(minimumDuration: 0.4) { reveal() }
        #if os(macOS)
        .overlay(SecondaryClick { reveal() })
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stem.capitalized)
        .accessibilityValue(muted ? "Muted" : "On")
        .accessibilityIdentifier(a11y)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(muted ? [] : .isSelected)
    }

    private var sliderFace: some View {
        HStack(spacing: 5) {
            Image(systemName: Self.icon(stem))
            StepButton(dir: .dec, value: engine.stemVolume(stem, on: deck), range: 0...1, step: 0.05,
                       tint: color, a11y: "\(a11y)-volume",
                       onChange: { engine.setStemVolume(stem, $0, on: deck) }, onInteract: { interaction += 1 })
            Slider(value: Binding(get: { engine.stemVolume(stem, on: deck) },
                                  set: { engine.setStemVolume(stem, $0, on: deck); interaction += 1 }),
                   in: 0...1)
                .controlSize(.small)
                .accessibilityIdentifier("\(a11y)-volume")
            StepButton(dir: .inc, value: engine.stemVolume(stem, on: deck), range: 0...1, step: 0.05,
                       tint: color, a11y: "\(a11y)-volume",
                       onChange: { engine.setStemVolume(stem, $0, on: deck) }, onInteract: { interaction += 1 })
            Text("\(Int((engine.stemVolume(stem, on: deck) * 100).rounded()))%")
                .monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity, minHeight: 18)
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color, lineWidth: 1))
        .foregroundStyle(color)
    }

    private func reveal() {
        if useChipPopover { showPopover = true }           // fixed-width popover (compact iPhone)
        else { editing = true; interaction += 1 }          // in-place flip (iPad / macOS)
    }

    static func icon(_ stem: String) -> String {
        switch stem {
        case "vocals": return "music.mic"
        case "drums":  return "metronome"
        case "bass":   return "waveform.path"
        default:       return "music.note"
        }
    }
}

/// The per-deck playback-position scrubber (under the waveform). A SEPARATE view so the ~10 Hz
/// playhead updates re-render only this slider, not the whole deck. Drag anywhere on the track to
/// seek (sample-accurate); the displayed position ALWAYS follows the engine when you're not dragging.
///
/// This is a hand-rolled track+thumb rather than a `Slider`: the drag offset lives in a
/// **`@GestureState`**, which SwiftUI *guarantees* to reset to `nil` the instant the gesture ends.
/// So the moment you lift your finger the display reverts to `engine.position(deck)` and resumes
/// following playback — there is no `@State`/`onEditingChanged` flag that can get stranded (the bug
/// where the timestamp froze after a release until you switched tabs).
private struct DeckSeekSlider: View {
    let engine: MixEngine
    let deck: MixEngine.Deck
    /// 0…1 position within the track WHILE dragging; auto-resets to nil when the drag ends.
    @GestureState private var dragFraction: Double?

    var body: some View {
        let dur = engine.duration(deck)
        let live = engine.position(deck)                 // ALWAYS read → Observation dependency holds
        let liveFraction = dur > 0 ? min(max(live / dur, 0), 1) : 0
        let shownFraction = dragFraction ?? liveFraction // dragging → finger; else → live playhead
        let shownSeconds = shownFraction * dur
        VStack(spacing: 1) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border).frame(height: 4)
                    Capsule().fill(Theme.accent2).frame(width: max(0, w * shownFraction), height: 4)
                    Circle().fill(Theme.accent2)
                        .frame(width: 16, height: 16)
                        .offset(x: min(max(0, w * shownFraction - 8), w - 16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragFraction) { value, frac, _ in
                            frac = w > 0 ? min(max(value.location.x / w, 0), 1) : 0
                        }
                        .onEnded { value in
                            guard dur > 0, w > 0 else { return }
                            engine.seek(deck, toSeconds: min(max(value.location.x / w, 0), 1) * dur)
                        }
                )
            }
            .frame(height: 20)
            .opacity(dur > 0 ? 1 : 0.4)
            .allowsHitTesting(dur > 0)
            .accessibilityElement()
            .accessibilityIdentifier("deck-\(deck.rawValue)-seek")
            .accessibilityLabel("Playback position")
            .accessibilityValue(Self.clock(shownSeconds))
            .accessibilityAdjustableAction { dir in
                guard dur > 0 else { return }
                let step = max(1, dur / 20)
                engine.seek(deck, toSeconds: min(max(0, live + (dir == .increment ? step : -step)), dur))
            }
            HStack {
                Text(Self.clock(shownSeconds)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                Spacer()
                Text(Self.clock(dur)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
        }
    }

    private static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The single equal-power crossfader spanning both decks (A ◀ ▶ B), 0…1.
private struct CrossfaderView: View {
    let engine: MixEngine
    var body: some View {
        VStack(spacing: 4) {
            Text("Crossfader").font(.caption).foregroundStyle(Theme.fgDim)
            HStack(spacing: 8) {
                Text("A").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                Slider(value: Binding(get: { engine.crossfader }, set: { engine.setCrossfader($0) }),
                       in: 0...1)
                    .tint(Theme.accent2)
                    .accessibilityIdentifier("crossfader")
                Text("B").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(10)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Track loader sheet

/// A searchable picker of a deck's LOADABLE (locally-burned) tracks. Opens from the deck's
/// tap / long-press / right-click. Carries a source menu (so you can pick or switch the deck's
/// pocket/set list here too) and a search field filtering by title, artist, OR album. Tapping a
/// row loads it onto the deck and dismisses.
private struct TrackLoaderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(BurnStore.self) private var burns
    @Environment(StudioStore.self) private var studio
    @Environment(MixSessionStore.self) private var mixSessions
    @Environment(SettingsStore.self) private var settings

    let deck: MixEngine.Deck
    let engine: MixEngine
    @Binding var source: MixSource?

    @State private var searchText = ""
    /// Local override to reveal already-played tracks (with their ✓) even when auto-hide is on.
    @State private var showPlayed = false

    /// Resolve the deck's source to its loadable (local) tracks ONCE per render. `loadables(for:)`
    /// stats each candidate file on the main actor; resolving it 3-4× per body pass (the old `items`
    /// was read twice + `hiddenPlayedCount` once) re-walked the whole pocket on every keystroke.
    private func resolvedSource() -> [MixLoadable] {
        guard let source else { return [] }
        return MixResolver(app: app, collections: collections, burns: burns, studio: studio).loadables(for: source)
    }

    /// Apply the search query to an already-resolved list (post-search, pre-played-drop).
    private func queried(_ all: [MixLoadable]) -> [MixLoadable] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { item in
            item.title.lowercased().contains(q)
                || item.artist.lowercased().contains(q)
                || (item.albumId.flatMap { app.albumsById[$0]?.name } ?? "").lowercased().contains(q)
        }
    }

    /// The rows to show: the query-filtered set minus already-played tracks (unless auto-hide is off
    /// or the local reveal is on — then all queried rows, the played ones marked with a ✓).
    private func visibleItems(_ queried: [MixLoadable]) -> [MixLoadable] {
        guard settings.mixAutoHidePlayed, !showPlayed else { return queried }
        return queried.filter { !mixSessions.hasPlayed($0.songId) }
    }

    /// How many of the CURRENTLY-QUERIED tracks auto-hide is hiding — counted from the same
    /// search-filtered set as the list, so the toggle's count matches what flipping it reveals.
    private func hiddenPlayedCount(_ queried: [MixLoadable]) -> Int {
        guard settings.mixAutoHidePlayed else { return 0 }
        return queried.filter { mixSessions.hasPlayed($0.songId) }.count
    }

    var body: some View {
        _ = mixSessions.playedRevision   // observe so the list refreshes when a track becomes played
        let queriedItems = queried(resolvedSource())
        let visible = visibleItems(queriedItems)
        let hidden = hiddenPlayedCount(queriedItems)
        return NavigationStack {
            VStack(spacing: 8) {
                sourceMenu
                TextField("Search artist, title, album", text: $searchText)
                    .pocketField()
                    .accessibilityIdentifier("mix-loader-search")
                if hidden > 0 || showPlayed {
                    Toggle(isOn: $showPlayed) {
                        Text(showPlayed ? "Showing played" : "Show \(hidden) played")
                            .font(.caption).foregroundStyle(Theme.fgDim)
                    }
                    .toggleStyle(.switch).tint(Theme.accent2).controlSize(.mini)
                    .accessibilityIdentifier("mix-loader-show-played")
                }
                content(visible)
            }
            .padding(12)
            .background(Theme.bg)
            .navigationTitle("Load Deck \(deck.rawValue)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("mix-loader-done")
                }
            }
        }
        .accessibilityIdentifier("mix-loader")
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }

    @ViewBuilder private func content(_ items: [MixLoadable]) -> some View {
        if source == nil {
            ContentUnavailableView("Pick a source", systemImage: "rectangle.stack",
                                   description: Text("Choose a pocket or set list to load tracks from."))
        } else if items.isEmpty {
            ContentUnavailableView("No loadable tracks", systemImage: "waveform.slash",
                                   description: Text("Only burned (on-device) songs can be mixed. Burn this collection first."))
        } else {
            List(items) { item in
                Button { engine.load(item, on: deck); dismiss() } label: { row(item) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mix-loader-row-\(item.songId)")
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ item: MixLoadable) -> some View {
        HStack(spacing: 10) {
            if let albumId = item.albumId, let album = app.albumsById[albumId] {
                CoverImage(album: album, corner: 6).frame(width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.bgOverlay).frame(width: 40, height: 40)
                    .overlay(Image(systemName: "music.note").foregroundStyle(Theme.fgDim))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).foregroundStyle(Theme.fg).lineLimit(1)
                Text(item.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            if mixSessions.hasPlayed(item.songId) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent2)
                    .accessibilityLabel("Played")
            }
            if let cam = item.camelot, !cam.isEmpty {
                KeyChip(key: item.key, camelot: cam)
            } else if let bpm = item.bpm {
                Text("\(Int(bpm.rounded()))").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
        }
        .contentShape(Rectangle())
        .accessibilityValue(mixSessions.hasPlayed(item.songId) ? "Played" : "")
    }

    private var sourceMenu: some View {
        Menu {
            if !collections.pockets.isEmpty {
                Section("Pockets") {
                    ForEach(collections.pockets) { p in Button(p.name) { source = .pocket(p.id) } }
                }
            }
            if !collections.setlists.isEmpty {
                Section("Set lists") {
                    ForEach(collections.setlists) { s in Button(s.name ?? "Set list") { source = .setlist(s.id) } }
                }
            }
        } label: {
            HStack {
                Image(systemName: "rectangle.stack").foregroundStyle(Theme.accent2)
                Text(sourceName ?? "Pick a source").foregroundStyle(Theme.fg)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.fgDim)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityIdentifier("mix-loader-source")
    }

    private var sourceName: String? {
        switch source {
        case .pocket(let id):  return collections.pocket(id)?.name
        case .setlist(let id): return collections.setlist(id)?.name ?? "Set list"
        case nil:              return nil
        }
    }
}
