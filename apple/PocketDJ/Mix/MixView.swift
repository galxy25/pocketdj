import SwiftUI

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
             bpm: l.bpm, camelot: l.camelot, key: l.key, albumId: l.albumId, on: deck)
    }
}

// MARK: - Mix tab

/// The Mix screen (iPhone · iPad · Mac). Mirrors Switchboard's DJ "Main Screen": two decks
/// side-by-side, a single crossfader spanning both, then ONE big Play/Pause that drives both
/// decks. The engine is app-scoped (env), so a mix keeps playing while you leave the tab; the
/// per-deck SOURCE is local view state (the loaded track itself is read back from the engine).
struct MixView: View {
    @Environment(MixEngine.self) private var engine

    /// Per-deck source (nil ⇒ none picked yet). Two vars so each deck can hold its own.
    @State private var sourceA: MixSource?
    @State private var sourceB: MixSource?
    /// Which deck's track-loader sheet is open (`.sheet(item:)`).
    @State private var loaderDeck: MixEngine.Deck?

    var body: some View {
        ScrollView {                                   // scrolls on iPhone-portrait; roomy on Mac/iPad
            VStack(spacing: 18) {
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
        .navigationTitle("Mix")
        .accessibilityIdentifier("mix-tab")
        .task { engine.prepare() }                     // warm the Switchboard graph when the tab opens
        // Track loader: long-press (iOS) / right-click (macOS) on a deck, or tap its header.
        .sheet(item: $loaderDeck) { deck in
            TrackLoaderSheet(deck: deck, engine: engine,
                             source: deck == .a ? $sourceA : $sourceB)
        }
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

    let deck: MixEngine.Deck
    let engine: MixEngine
    @Binding var source: MixSource?
    /// Open the track-loader sheet for this deck (owned by MixView).
    let onLoad: () -> Void

    /// Local, recomputed-once-per-load waveform peaks (R3 reads the burned file off the main
    /// actor; keyed on the loaded songId so it fires exactly once per track — never on a redraw).
    @State private var peaks: [Float] = []

    private var loaded: MixEngine.LoadedTrack? { engine.loaded(deck) }
    private var a11y: String { "deck-\(deck.rawValue)" }      // "deck-A" / "deck-B"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            deckLabel
            header
            refreshRow             // ↺ rewind-to-start — under the waveform
            effectsGrid
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
        HStack {
            Text("Deck \(deck.rawValue)")
                .font(.headline).foregroundStyle(Theme.fg)
            Spacer()
            sourceMenu
        }
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

    // ↺ Refresh row (under the waveform): re-open the deck's file to rewind to 0:00. (Tempo, pitch,
    // and beat-sync are intentionally absent — the vendored Switchboard 3.2.3 player can't do them;
    // see MixEngine's note. Rewind is the only position control the SDK exposes.)
    private var refreshRow: some View {
        HStack {
            Spacer()
            Button { engine.restart(deck) } label: {
                Image(systemName: "arrow.counterclockwise").font(.callout)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .disabled(loaded == nil)
            .help("Rewind to the start")
            .accessibilityIdentifier("\(a11y)-restart")
        }
    }

    private var volSlider: some View {
        DeckSlider(title: "Vol",
                   display: "\(Int((engine.volume(deck) * 100).rounded()))%",
                   value: engine.volume(deck),
                   range: 0...1,
                   a11y: "\(a11y)-vol") { engine.setVolume($0, on: deck) }
    }

    // 2×2 grid: Compressor · Reverb (top), Flanger · Filter (bottom).
    private var effectsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                  spacing: 6) {
            ForEach(MixEngine.Effect.allCases) { fx in
                EffectButton(effect: fx,
                             isOn: engine.isEnabled(fx, on: deck),
                             a11y: "\(a11y)-fx-\(fx.rawValue)") {
                    engine.setEffect(fx, enabled: !engine.isEnabled(fx, on: deck), on: deck)
                }
            }
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

/// A labelled slider (title + live value over a full-width Slider) — a manual `Binding` so a
/// drag pushes straight into the engine.
private struct DeckSlider: View {
    let title: String
    let display: String
    let value: Double
    let range: ClosedRange<Double>
    let a11y: String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Theme.fgDim)
                Spacer()
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(Theme.accent)
                .accessibilityIdentifier(a11y)
        }
    }
}

/// One effect toggle chip: accent-filled + "selected" trait when on, dim outline when off.
private struct EffectButton: View {
    let effect: MixEngine.Effect
    let isOn: Bool
    let a11y: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: effect.icon)
                Text(effect.label).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(isOn ? Theme.accent.opacity(0.25) : Theme.bgOverlay,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isOn ? Theme.accent : Theme.border, lineWidth: 1))
            .foregroundStyle(isOn ? Theme.accent : Theme.fgDim)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(a11y)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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

    let deck: MixEngine.Deck
    let engine: MixEngine
    @Binding var source: MixSource?

    @State private var searchText = ""

    /// Resolve the deck's source to its loadable (local) tracks, then filter by the query.
    private var items: [MixLoadable] {
        guard let source else { return [] }
        let all = MixResolver(app: app, collections: collections, burns: burns).loadables(for: source)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { item in
            item.title.lowercased().contains(q)
                || item.artist.lowercased().contains(q)
                || (item.albumId.flatMap { app.albumsById[$0]?.name } ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                sourceMenu
                TextField("Search artist, title, album", text: $searchText)
                    .pocketField()
                    .accessibilityIdentifier("mix-loader-search")
                content
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

    @ViewBuilder private var content: some View {
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
            if let cam = item.camelot, !cam.isEmpty {
                KeyChip(key: item.key, camelot: cam)
            } else if let bpm = item.bpm {
                Text("\(Int(bpm.rounded()))").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
        }
        .contentShape(Rectangle())
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
