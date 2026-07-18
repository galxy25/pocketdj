import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Producer ▸ DEMUXER — load ANY audio (a catalog track, a Studio sample/loop/instrumental, or
/// an imported file) and demux it into associated, time-synced metadata:
///   • the LYRICS/speech transcript (Apple Speech, fully on device) — karaoke panel;
///   • the dominant-CHORD timeline — colored blocks on the scrubbable strip, tap for
///     notation (treble/bass staves) or a guitar shape;
///   • the four Demucs STEMS — mute/solo live (the drums + bass stems ARE the rhythm view).
///     Stems degrade gracefully: burned → play; stemmed server-side → download; not stemmed →
///     create via the rip server when it's reachable (catalog tracks only) — there is NO
///     on-device separation (Demucs runs on the rip server; spec: stems architecture).
///
/// Source resolution reuses the sample-from-track ladder (burned → burn-on-demand → rip-first),
/// with one demux-specific twist: a shared ANALOG album side is carved once into the demux
/// audio cache so the timeline's 0:00 is the SONG's 0:00 (the analog-offset contract).
/// Transcription prefers the burned VOCALS stem over the full mix — far better recognition.
struct StudioDemuxView: View {
    @Environment(DemuxStore.self) private var demux
    @Environment(StudioStore.self) private var studio
    @Environment(AppModel.self) private var app
    @Environment(BurnStore.self) private var burns
    @Environment(RipsStore.self) private var rips

    private enum Phase: Equatable {
        case idle, resolving, ready, needsBurn, burning, ripFirst
        case failed(String)
    }

    /// Stem availability for the loaded source (songs only — see the header).
    private enum StemState: Equatable {
        case none            // non-song source, or song with no stems + no server
        case creatable       // song, not stemmed, rip server reachable
        case creating        // Demucs run in flight on the rip server
        case downloadable    // stemmed server-side, not burned
        case downloading
        case burned          // 4 local files — stem mode available
        case failed(String)
    }

    @State private var source: DemuxSource?
    @State private var phase: Phase = .idle
    @State private var stemState: StemState = .none
    /// The resolved single-mix local audio (the timeline/analysis source).
    @State private var audioURL: URL?
    @State private var durationMs = 0
    @State private var peaks: [Float] = []
    /// The shared synced player: single-mix mode loads one file, stem mode loads all four.
    @State private var player = StemPlayer()
    @State private var stemMode = false
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var chordDetail: DemuxChordSegment?

    var body: some View {
        Group {
            if let source, phase != .idle {
                loadedView(source)
            } else {
                pickerView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result, let src = demux.importFile(from: url) {
                select(src)
            }
        }
        .sheet(item: $chordDetail) { seg in
            #if os(macOS)
            DemuxChordDetailView(chord: seg)
            #else
            DemuxChordDetailView(chord: seg)
                .presentationDetents([.medium])
            #endif
        }
        .onDisappear { player.stop() }
    }

    // MARK: - Source picker

    private var pickerView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demuxer").font(.headline).foregroundStyle(Theme.fg)
                    Text("Pick audio to demux into lyrics, chords, and stems")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
                Spacer()
                Button { showImporter = true } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-import")
            }
            .padding(.horizontal, 16).padding(.top, 14)

            TextField("Search tracks, samples, loops, instrumentals", text: $searchText)
                .pocketField()
                .padding(.horizontal, 16)
                .accessibilityIdentifier("demux-source-search")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let studioItems = studioMatches()
                    if !studioItems.isEmpty {
                        sectionHeader("Performance media")
                        ForEach(studioItems, id: \.id) { item in studioRow(item) }
                    }
                    let tracks = trackMatches()
                    if !tracks.isEmpty {
                        sectionHeader("Tracks")
                        ForEach(tracks) { trackRow($0) }
                    }
                    if studioItems.isEmpty && tracks.isEmpty {
                        Text(query.isEmpty
                             ? "Burn a track, make a sample, or Import an audio file to demux it."
                             : "Nothing matches “\(searchText)”.")
                            .font(.caption).foregroundStyle(Theme.fgDim)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 32).padding(.top, 24)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Burned-first track matches (the sample-from-track idiom: empty query browses the
    /// burned subset; a query searches the whole catalog).
    private func trackMatches() -> [IndexSong] {
        let all = app.songsById.values
        let filtered: [IndexSong]
        if query.isEmpty {
            let burnedSet = Set(burns.readyBurnedIds(in: all.map(\.id)))
            filtered = all.filter { burnedSet.contains($0.id) }
        } else {
            filtered = all.filter {
                $0.name.lowercased().contains(query) || $0.artist.lowercased().contains(query)
            }
        }
        let burned = Set(burns.readyBurnedIds(in: filtered.map(\.id)))
        return Array(filtered.sorted { a, b in
            let ba = burned.contains(a.id), bb = burned.contains(b.id)
            if ba != bb { return ba }
            if a.artist.lowercased() != b.artist.lowercased() {
                return a.artist.lowercased() < b.artist.lowercased()
            }
            return a.name.lowercased() < b.name.lowercased()
        }.prefix(80))
    }

    /// Demuxable Studio media: samples, loops, and rendered instrumentals (things with a
    /// resolvable audio file — `localURLForPlayback` decides truthfully at selection time).
    private func studioMatches() -> [(id: String, name: String, icon: String)] {
        var items: [(String, String, String)] = []
        items += studio.samples.map { ($0.id, $0.name, "waveform") }
        items += studio.loops.map { ($0.id, $0.name, "repeat") }
        items += studio.takes.map { ($0.id, $0.name, "recordingtape") }
        let all = items.map { (id: $0.0, name: $0.1, icon: $0.2) }
        guard !query.isEmpty else { return Array(all.prefix(24)) }
        return all.filter { $0.name.lowercased().contains(query) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
            .padding(.top, 8).padding(.horizontal, 8)
    }

    private func trackRow(_ song: IndexSong) -> some View {
        let isBurned = !burns.readyBurnedIds(in: [song.id]).isEmpty
        return Button {
            select(.song(id: song.id, title: song.name, artist: song.artist))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(song.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                Spacer()
                if isBurned {
                    Image(systemName: "opticaldisc")
                        .font(.caption).foregroundStyle(Theme.accent)
                        .accessibilityLabel("On device")
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bgRaised))
        .accessibilityIdentifier("demux-track-row-\(song.id)")
    }

    private func studioRow(_ item: (id: String, name: String, icon: String)) -> some View {
        Button {
            select(.studio(id: item.id, name: item.name))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.caption).foregroundStyle(Theme.accent)
                Text(item.name).foregroundStyle(Theme.fg).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bgRaised))
        .accessibilityIdentifier("demux-studio-row-\(item.id)")
    }

    // MARK: - Loaded source

    private func loadedView(_ source: DemuxSource) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                loadedHeader(source)
                switch phase {
                case .resolving:
                    statusRow(spinner: true, "Preparing audio…", a11y: "demux-resolving")
                case .burning:
                    statusRow(spinner: true, "Burning for offline demuxing…", a11y: "demux-burning")
                case .needsBurn:
                    needsBurnState(source)
                case .ripFirst:
                    ripFirstState
                case .failed(let msg):
                    failedState(msg, source: source)
                case .ready:
                    readyBody(source)
                case .idle:
                    EmptyView()
                }
            }
            .padding(16)
        }
    }

    private func loadedHeader(_ source: DemuxSource) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName).font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                Text("Demuxed: synced lyrics + chords\(stemState == .burned ? " + stems" : "")")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
            Spacer()
            Button("Change") { clearSource() }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-change-source")
        }
    }

    @ViewBuilder private func readyBody(_ source: DemuxSource) -> some View {
        let doc = demux.document(for: source.key)
        transport
        DemuxTimelineView(durationMs: durationMs, peaks: peaks,
                          chords: doc?.chords ?? [], player: player,
                          onSeek: { seek(toMs: $0) },
                          onChordTap: { chordDetail = $0 })
        chordStatusRow(doc)
        stemsPanel(source)
        transcriptPanel(doc)
    }

    // MARK: Transport (play/pause + clock)

    private var transport: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 12) {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 38, height: 38)
                        .background(Theme.accent.opacity(0.18), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-play")
                Button { seek(toMs: 0) } label: {
                    Image(systemName: "gobackward")
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("demux-restart")
                Text("\(StemAuditionPanel.clock(player.currentTime)) / \(StemAuditionPanel.clock(Double(durationMs) / 1_000))")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                Spacer()
                if stemState == .burned {
                    Toggle(isOn: stemModeBinding) { Text("Stems").font(.caption) }
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("demux-stem-mode")
                }
            }
        }
    }

    private var stemModeBinding: Binding<Bool> {
        Binding(get: { stemMode }, set: { on in
            stemMode = on
            Task { await loadPlayer(stems: on) }
        })
    }

    // MARK: Chord + transcript status rows

    @ViewBuilder private func chordStatusRow(_ doc: DemuxDocument?) -> some View {
        if let source, demux.chordRuns.contains(source.key) {
            statusRow(spinner: true, "Listening for chords…", a11y: "demux-chords-running")
        } else if doc?.chordStatus == .failed {
            HStack(spacing: 8) {
                Text("No confident chords found.").font(.caption).foregroundStyle(Theme.fgDim)
                retryButton("demux-chords-retry") { kickoffChords(force: true) }
            }
        }
    }

    @ViewBuilder private func transcriptPanel(_ doc: DemuxDocument?) -> some View {
        if let source, demux.transcriptRuns.contains(source.key) {
            statusRow(spinner: true, "Transcribing on device…", a11y: "demux-transcribing")
        } else {
            switch doc?.transcriptStatus {
            case .done where !(doc?.words.isEmpty ?? true):
                sectionTitle("Lyrics", icon: "music.mic")
                DemuxLyricsView(words: doc?.words ?? [], player: player) { seek(toMs: $0) }
            case .done:
                Text("No words recognized — probably instrumental.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("demux-no-words")
            case .unavailable:
                Text("On-device transcription isn’t available (permission or language).")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("demux-transcript-unavailable")
            case .failed:
                HStack(spacing: 8) {
                    Text("Couldn’t transcribe this audio.").font(.caption).foregroundStyle(Theme.fgDim)
                    retryButton("demux-transcript-retry") { kickoffTranscript(force: true) }
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: Stems panel

    @ViewBuilder private func stemsPanel(_ source: DemuxSource) -> some View {
        sectionTitle("Stems", icon: "line.3.horizontal")
        switch stemState {
        case .burned:
            if stemMode {
                VStack(spacing: 6) {
                    ForEach(StemPlayer.stems, id: \.self) { name in stemRow(name) }
                }
            } else {
                Text("Flip the Stems switch to mute/solo drums, bass, vocals, and the rest live.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
        case .downloadable:
            HStack(spacing: 8) {
                Text("This track is stemmed — download to play stems offline.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                Button("Download") { Task { await downloadStems(source) } }
                    .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("demux-stems-download")
            }
        case .downloading:
            statusRow(spinner: true, "Downloading stems…", a11y: "demux-stems-downloading")
        case .creatable:
            HStack(spacing: 8) {
                Text("Not stemmed yet — separate it with Demucs on your rip server.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                Button("Create stems") { Task { await createStems(source) } }
                    .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("demux-stems-create")
            }
        case .creating:
            statusRow(spinner: true, "Separating stems on the rip server (this can take a few minutes)…",
                      a11y: "demux-stems-creating")
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("demux-stems-failed")
        case .none:
            Text(source.songId == nil
                 ? "Stems are available for catalog tracks (Demucs runs on the rip server)."
                 : "Stems need the rip server, which isn’t reachable right now.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("demux-stems-none")
        }
    }

    /// Mute/solo row (the StemAuditionPanel idiom, demux edition).
    private func stemRow(_ name: String) -> some View {
        HStack(spacing: 10) {
            Button { player.solo(name) } label: {
                Image(systemName: player.soloed == name && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(player.soloed == name ? Theme.accent2 : Theme.accent)
            .accessibilityIdentifier("demux-stem-solo-\(name)")

            Label(name.capitalized, systemImage: Self.stemIcon(name))
                .font(.callout).foregroundStyle(Theme.fg)
                .accessibilityIdentifier("demux-stem-row-\(name)")
            Spacer()
            Button { player.toggleMute(name) } label: {
                Image(systemName: player.isAudible(name) ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(player.isAudible(name) ? Theme.accent : Theme.fgDim)
            .accessibilityIdentifier("demux-stem-mute-\(name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.bgOverlay.opacity(player.soloed == name ? 0.6 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private static func stemIcon(_ name: String) -> String {
        switch name {
        case "vocals": return "music.mic"
        case "drums":  return "metronome"
        case "bass":   return "waveform.path"
        default:       return "music.note"
        }
    }

    // MARK: Ladder states

    private func needsBurnState(_ source: DemuxSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This track is ripped but not on the device yet.")
                .font(.caption).foregroundStyle(Theme.fgDim)
            Button("Burn + demux") { Task { await burnThenReady(source) } }
                .font(.callout.weight(.semibold)).buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-burn")
        }
    }

    private var ripFirstState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rip this track first", systemImage: "waveform.badge.plus")
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.fg)
            Text("This song has no local rip yet, so there’s nothing to demux. Rip it "
                 + "(▶/⤓ on the song, or Rip in a collection), then come back.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("demux-rip-first")
        }
    }

    private func failedState(_ msg: String, source: DemuxSource) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.accent2)
            Text(msg).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("demux-failed")
            Spacer()
            retryButton("demux-retry") { select(source) }
        }
    }

    private func statusRow(spinner: Bool, _ text: String, a11y: String) -> some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier(a11y)
            Spacer()
        }
    }

    private func retryButton(_ a11y: String, action: @escaping () -> Void) -> some View {
        Button("Retry", action: action)
            .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
            .accessibilityIdentifier(a11y)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold)).foregroundStyle(Theme.fg)
            .padding(.top, 4)
    }

    // MARK: - Selection + resolution

    private func select(_ src: DemuxSource) {
        clearSource()
        source = src
        phase = .resolving
        searchText = ""
        Task { await resolve(src) }
    }

    private func clearSource() {
        player.stop()
        source = nil
        phase = .idle
        stemState = .none
        stemMode = false
        audioURL = nil
        durationMs = 0
        peaks = []
    }

    private func resolve(_ src: DemuxSource) async {
        switch src {
        case .file(let id, _):
            guard let url = demux.importedAudioURL(for: id) else {
                phase = .failed("This imported file is gone from the demux cache. Import it again.")
                return
            }
            await enterReady(src, url: url, release: nil, lengthMs: fileLengthMs(url))
        case .studio(let id, _):
            guard let got = studio.localURLForPlayback(id: id) else {
                phase = .failed("This item has no playable audio yet (render or bounce it first).")
                return
            }
            await enterReady(src, url: got.url, release: got.release, lengthMs: got.lengthMs)
        case .song(let id, _, _):
            guard let song = app.songsById[id] else {
                phase = .failed("This track isn’t in the loaded catalog anymore.")
                return
            }
            if let local = await ensureSongAudio(song) {
                await enterReady(src, url: local.url, release: local.release, lengthMs: songLengthMs(song))
            } else {
                phase = rips.manifest[id] != nil ? .needsBurn : .ripFirst
            }
        }
    }

    /// Resolve a song to a local file whose 0:00 is the SONG's 0:00: a per-song cut or digital
    /// rip plays as-is; a shared analog album side is carved ONCE into the demux audio cache.
    private func ensureSongAudio(_ song: IndexSong) async -> (url: URL, release: (() -> Void)?)? {
        guard let h = burns.localURLForPlaybackPreferringCut(forSong: song.id) else { return nil }
        let offset = h.isCut ? 0 : (burns.startMs(forSong: song.id) ?? 0)
        if offset == 0 { return (h.url, h.release) }
        defer { h.release?() }
        if let cached = demux.carvedSongURL(for: song.id) { return (cached, nil) }
        guard let dest = demux.carvedSongDestination(for: song.id) else { return nil }
        let len = songLengthMs(song)
        guard let _ = try? await StudioRender.shared.carveTrackRegion(
            sourceURL: h.url, startMs: offset, endMs: offset + len, to: dest) else { return nil }
        return (dest, nil)
    }

    private func enterReady(_ src: DemuxSource, url: URL, release: (() -> Void)?, lengthMs: Int) async {
        audioURL = url
        durationMs = max(lengthMs, 1)
        var doc = demux.documentCreating(for: src)
        doc.durationMs = max(doc.durationMs, durationMs)
        demux.save(doc)
        refreshStemState(src)
        phase = .ready
        // Single-mix playback first; the Stems switch reloads with the four stem files.
        // The player holds `release` (the file's security scope) until stop/reload.
        player.load(songId: "\(src.key)#mix", localURLs: ["vocals": url], release: release)
        kickoffChords()
        kickoffTranscript()
        peaks = await loadPeaks(src, url: url)
    }

    private func loadPeaks(_ src: DemuxSource, url: URL) async -> [Float] {
        switch src {
        case .song(let id, _, _):
            // Carved/cut audio starts at the song's 0:00, so the song-windowed extractor and
            // the direct URL agree; prefer the song path (it reuses the Mix waveform cache).
            return await MixWaveform.peaks(forSong: id, lengthMs: durationMs, burns: burns)
        case .studio, .file:
            return await WaveformExtractor.peaks(url: url)
        }
    }

    private func burnThenReady(_ source: DemuxSource) async {
        guard case .song(let id, let title, let artist) = source else { return }
        phase = .burning
        let r = await burns.burn([(id: id, title: title, artist: artist)])
        if r.burned > 0, let song = app.songsById[id], let local = await ensureSongAudio(song) {
            await enterReady(source, url: local.url, release: local.release, lengthMs: songLengthMs(song))
            return
        }
        phase = .failed("Couldn’t burn this track for demuxing.")
    }

    // MARK: - Analysis kickoff

    private func kickoffChords(force: Bool = false) {
        guard let source, let audioURL else { return }
        demux.analyzeChords(source: source, url: audioURL, durationMs: durationMs, force: force)
    }

    /// Transcribe the burned VOCALS stem when available (recognition over a full mix is
    /// best-effort); otherwise the mix file.
    private func kickoffTranscript(force: Bool = false) {
        guard let source, let audioURL else { return }
        if let songId = source.songId, let stems = burns.localStemURLs(forSong: songId),
           let vocals = stems.urls["vocals"] {
            demux.analyzeTranscript(source: source, url: vocals, durationMs: durationMs,
                                    force: force, release: stems.release)
        } else {
            demux.analyzeTranscript(source: source, url: audioURL, durationMs: durationMs, force: force)
        }
    }

    // MARK: - Stems

    private func refreshStemState(_ src: DemuxSource) {
        guard let songId = src.songId else { stemState = .none; return }
        if burns.stemsBurned(forSong: songId) { stemState = .burned }
        else if rips.isStemmed(songId) { stemState = .downloadable }
        else if rips.hasServer, rips.manifest[songId] != nil { stemState = .creatable }
        else { stemState = .none }
    }

    private func downloadStems(_ src: DemuxSource) async {
        guard let songId = src.songId else { return }
        stemState = .downloading
        if let got = await burns.burnStems(forSong: songId) {
            got.release?()
            stemState = .burned
            // A better transcript source just arrived — re-run over the vocals stem.
            kickoffTranscript(force: true)
        } else {
            stemState = .failed("Couldn’t download this track’s stems.")
        }
    }

    /// Trigger Demucs on the rip server (`/stemify` + poll — `RipsStore.stemify` returns once
    /// the job is ready and the manifest refreshed), then pull the stems down.
    private func createStems(_ src: DemuxSource) async {
        guard let songId = src.songId else { return }
        stemState = .creating
        await rips.stemify(songId)
        if rips.isStemmed(songId) {
            await downloadStems(src)
        } else {
            stemState = .failed("The rip server couldn’t stem this track (check it’s reachable and try again).")
        }
    }

    // MARK: - Playback plumbing

    /// Reload the shared player in mix or stems mode, preserving position.
    private func loadPlayer(stems: Bool) async {
        guard let source else { return }
        let position = player.currentTime
        let wasPlaying = player.isPlaying
        if stems, let songId = source.songId, let got = burns.localStemURLs(forSong: songId) {
            player.load(songId: "\(source.key)#stems", localURLs: got.urls, release: got.release)
        } else if let audioURL {
            stemMode = false
            // Re-resolve the scope for the mix file (the previous load released it).
            var release: (() -> Void)?
            if let songId = source.songId,
               let h = burns.localURLForPlaybackPreferringCut(forSong: songId), h.url == audioURL {
                release = h.release
            } else if case .studio(let id, _) = source, let got = studio.localURLForPlayback(id: id),
                      got.url == audioURL {
                release = got.release
            }
            player.load(songId: "\(source.key)#mix", localURLs: ["vocals": audioURL], release: release)
        }
        player.seek(to: position)
        if wasPlaying { player.togglePlayPause() }
    }

    private func seek(toMs ms: Int) {
        player.seek(to: Double(ms) / 1_000)
    }

    private func songLengthMs(_ song: IndexSong) -> Int {
        if let len = song.length, len > 0 { return len }
        if let d = rips.manifest[song.id]?.durationMs, d > 0 { return d }
        return 1
    }

    private func fileLengthMs(_ url: URL) -> Int {
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return 1 }
        return max(Int(Double(f.length) / f.processingFormat.sampleRate * 1_000), 1)
    }
}
