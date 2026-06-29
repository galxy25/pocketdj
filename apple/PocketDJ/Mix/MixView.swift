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
    @Environment(SettingsStore.self) private var settings
    @Environment(MixSessionStore.self) private var mixSessions

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

    var body: some View {
        ScrollView {                                   // scrolls on iPhone-portrait; roomy on Mac/iPad
            VStack(spacing: 18) {
                if engine.autoMixing { autoMixBanner }  // Auto-DJ status + Stop (visible on every size)
                // Two decks side-by-side (A left, B right), equal width.
                HStack(alignment: .top, spacing: 12) {
                    DeckView(deck: .a, engine: engine, source: $sourceA) { loaderDeck = .a }
                    DeckView(deck: .b, engine: engine, source: $sourceB) { loaderDeck = .b }
                }
                CrossfaderView(engine: engine)         // one crossfader spanning both decks
                masterTransport                        // one big Play/Pause for both decks
            }
            .padding(16)
            .frame(maxWidth: 900)                       // keep controls a comfortable width on Mac/iPad
            .frame(maxWidth: .infinity)                 // ...centered in a wide window
        }
        .background(Theme.bg)
        // The centered nav title shows the CURRENT session's name; tapping it opens the title menu
        // (Rename / New session / All sessions) — the reliable, system-centered cross-platform way to
        // make the session name interactive (vs. an unreliable .principal + .contextMenu).
        .navigationTitle(mixSessions.currentName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarTitleMenu { sessionTitleMenu }
        .accessibilityIdentifier("mix-tab")
        .toolbar { autoMixToolbar }                    // Auto/Manual + collection Play/Shuffle
        .toolbar { sessionLeadingToolbar }             // Sessions (history) + Reset (X)
        .task { engine.prepare() }                     // warm the AVAudioEngine graph when the tab opens
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

    // MARK: Sessions (name menu · history · reset)

    /// The nav-title tap menu: rename the current session, start a new one (reset), or jump to the
    /// full Sessions list. Mirrors the discrete Sessions/Reset toolbar buttons for discoverability.
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

    // MARK: Auto-Mix (auto-DJ)

    /// Toolbar: a Manual/Auto toggle button, then (in Auto) the global-collection picker + ▶ Play /
    /// 🔀 Shuffle / ⏹ Stop — mirroring the Playlists tab's menu-bar play/shuffle.
    @ToolbarContentBuilder private var autoMixToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // ONE-TAP mode toggle: shows the current mode and flips to the other on tap (no dropdown).
            Button { engine.setAutoEnabled(!engine.autoEnabled) } label: {
                Label(engine.autoEnabled ? "Auto" : "Manual",
                      systemImage: engine.autoEnabled ? "wand.and.stars" : "slider.horizontal.3")
            }
            .help(engine.autoEnabled ? "Auto mode — tap to switch to Manual"
                                     : "Manual mode — tap to switch to Auto")
            .accessibilityIdentifier("mix-auto-mode")

            if engine.autoEnabled {
                Menu {
                    autoSourceMenuItems
                } label: {
                    Label(autoSourceName ?? "Collection", systemImage: "rectangle.stack")
                }
                .accessibilityIdentifier("mix-auto-source")

                Button { startAuto(shuffled: false) } label: { Image(systemName: "play.fill") }
                    .disabled(autoSource == nil)
                    .help("Auto-mix this collection in order")
                    .accessibilityIdentifier("mix-auto-play")

                Button { startAuto(shuffled: true) } label: { Image(systemName: "shuffle") }
                    .disabled(autoSource == nil)
                    .help("Auto-mix this collection shuffled")
                    .accessibilityIdentifier("mix-auto-shuffle")
                // Stop lives in the always-visible in-body banner (`autoMixBanner`) so it stays
                // reachable on iPhone, where a crowded nav bar collapses extra items into "•••".
            }
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

    /// In-body banner so the Stop control + progress are reachable on iPhone (where a crowded
    /// nav bar can hide toolbar items).
    private var autoMixBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-mixing").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                if let status = engine.autoStatus {
                    Text(status).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                }
            }
            Spacer()
            Button(role: .destructive) { engine.stopAutoMix() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .accessibilityIdentifier("mix-auto-stop-banner")
        }
        .padding(12)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
        .accessibilityIdentifier("mix-auto-banner")
    }

    /// Build the queue from the chosen collection (resolver order) + each song's catalog length,
    /// then hand it to the engine with the Settings-configured lead/fade. Shuffle is applied in
    /// the engine so order/shuffle share one path.
    private func startAuto(shuffled: Bool) {
        guard let src = autoSource else { return }
        let loadables = MixResolver(app: app, collections: collections, burns: burns).loadables(for: src)
        let items = loadables.map { l in
            MixEngine.AutoMixItem(loadable: l, durationMs: l.lengthMs ?? 180_000)
        }
        engine.startAutoMix(items, shuffled: shuffled,
                            lead: settings.autoMixLeadSeconds, fade: settings.autoMixFadeSeconds)
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
            transportRow                                 // ↺ rewind · Sync to Lead
            tempoSlider                                  // live time-stretch (pitch preserved)
            pitchSlider                                  // live pitch shift (tempo preserved)
            effectsGrid                                  // tap = toggle · long-press / right-click = strength
            if engine.stemActive(deck) { stemGrid }      // 2×2 stem pads — only while in stem mode
            volSlider
            playButton
        }
        .padding(10)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
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

    // Camelot chip when known; else BPM; else the KeyChip's placeholder.
    @ViewBuilder private func keyOrBpm(_ t: MixEngine.LoadedTrack) -> some View {
        if let cam = t.camelot, !cam.isEmpty {
            KeyChip(key: t.key, camelot: cam)
        } else if let bpm = t.bpm {
            Text("\(Int(bpm.rounded())) BPM").font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
        } else {
            KeyChip(key: nil, camelot: nil)
        }
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
            Spacer()
            Button { engine.resetDeck(deck) } label: {
                Image(systemName: "arrow.counterclockwise").font(.callout)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .disabled(loaded == nil)
            .help("Reset deck — clear tempo, pitch, effects & volume, then rewind")
            .accessibilityIdentifier("\(a11y)-restart")
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

// MARK: - Small controls

/// One −/＋ fine-adjust button, flanking a slider, that nudges `value` by `step` (clamped to
/// `range`). Disabled at the relevant bound. `onInteract` lets a host with an idle-revert timer
/// (the chip flip / popover) reset it on each tap so careful stepping doesn't dismiss mid-adjust.
private struct StepButton: View {
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
private struct DeckSlider: View {
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

/// One effect chip with an IN-PLACE flip: TAP toggles the effect; LONG-PRESS (iOS) / RIGHT-CLICK
/// (macOS) flips the chip — same footprint, no popover, no screen nav — to a strength slider so you
/// dial the wet amount right there. After 3 s with no interaction it flips back to the labelled
/// button, keeping you in the flow. Flipping to the slider also enables the effect (so the dial is
/// immediately audible). Accent-filled + "selected" when the effect is on.
private struct EffectButton: View {
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
private struct ChipStrengthPopover: View {
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
/// playhead updates re-render only this slider, not the whole deck. Drag to seek (sample-accurate).
private struct DeckSeekSlider: View {
    let engine: MixEngine
    let deck: MixEngine.Deck
    @State private var scrubbing: Double?

    var body: some View {
        let dur = engine.duration(deck)
        let pos = scrubbing ?? engine.position(deck)
        VStack(spacing: 1) {
            Slider(value: Binding(get: { dur > 0 ? min(max(pos, 0), dur) : 0 },
                                  set: { scrubbing = $0 }),
                   in: 0...max(dur, 0.001),
                   onEditingChanged: { editing in
                       if !editing, let s = scrubbing { engine.seek(deck, toSeconds: s); scrubbing = nil }
                   })
                .tint(Theme.accent2)
                .disabled(dur <= 0)
                .accessibilityIdentifier("deck-\(deck.rawValue)-seek")
            HStack {
                Text(Self.clock(pos)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
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
        return MixResolver(app: app, collections: collections, burns: burns).loadables(for: source)
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
