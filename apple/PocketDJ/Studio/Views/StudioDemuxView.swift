import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Producer ▸ DEMUXER — load ANY audio (a catalog track, a Studio sample/loop/instrumental, or
/// an imported file) and demux it into associated, time-synced metadata:
///   • the LYRICS/speech transcript (Apple Speech, fully on device) — karaoke panel;
///   • the dominant-CHORD timeline — colored blocks on the scrubbable strip, tap for
///     notation (treble/bass staves) or a guitar shape;
///   • the four separated STEMS — mute/solo live (the drums + bass stems ARE the rhythm view).
///     Stems degrade gracefully: burned → play; stemmed server-side → download; not stemmed →
///     create on the import server when one is configured — there is NO on-device separation
///     (Demucs runs on the import server; spec: stems architecture). A catalog track stems
///     from the copy the server already prepared for THIS user; imported/Studio audio uploads
///     the local file. Either way the server only ever separates audio the user owns — it
///     never goes and acquires audio to fill a gap.
///     #TOUPDATE: per-user prepared copies + request auth. Today rips/* is a FLAT, public-read
///     namespace keyed rips/<songId>.mp3 and SHARED across users, and the server's authed()
///     fails open (scripts/rip-server.mjs:1904), so "prepared for THIS user" is not yet true.
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

    /// Stem availability for the loaded source (songs and custom audio alike — see the header).
    private enum StemState: Equatable {
        case none            // no import server configured, or a song with no prepared audio
        case creatable       // not stemmed, and an import server is configured
        case creating        // separation run in flight on the import server
        case downloadable    // stemmed server-side, not burned
        case downloading
        case burned          // 4 local files — stem mode available
        case failed(String)
    }

    @State private var source: DemuxSource?
    /// Comma-joined set of EXPANDED source-group keys in the picker (absent ⇒ collapsed = default).
    @AppStorage("pdj.demuxExpandedGroups") private var expandedGroupsRaw = ""
    @State private var phase: Phase = .idle
    @State private var stemState: StemState = .none
    /// The resolved single-mix local audio (the timeline/analysis source).
    @State private var audioURL: URL?
    @State private var durationMs = 0
    @State private var peaks: [Float] = []
    /// The shared synced player: single-mix mode loads one file, stem mode loads all four.
    @State private var player = StemPlayer()
    /// ONE shared "follow the playhead" toggle, lifted here so the timeline, the drum-pattern
    /// lane-grid, AND the instrumental score all scroll to the SAME playhead position under a
    /// single Follow — including a paused scrub (each surface's poll reads `player.currentTime`,
    /// which returns pausedAt while paused and is moved by seek(), with NO isPlaying gate). The
    /// three panels' follow buttons are all views of this one state (toggling any toggles all).
    @State private var demuxFollow = true
    /// The in-flight source resolution — stored so re-selection/tab-exit can cancel it
    /// (see select()).
    @State private var resolveTask: Task<Void, Never>?
    @State private var stemMode = false
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var chordDetail: DemuxChordSegment?
    /// The "Cut sample" sheet (catalog songs → the full sampler flow; custom/studio sources →
    /// the URL-seeded region editor). The demux player is PAUSED before presenting — the sheet
    /// auditions through StudioEngine and two live players violate the one-audio-owner rule.
    @State private var showCutSample = false
    /// The drum-pattern grid's bar list (measured sidecar downbeats when available, else an
    /// estimated constant grid) — resolved once per extraction, off the render path.
    /// `drumBarsKey` records WHICH source the bars belong to: the async resolve (sidecar
    /// download / 90 s grid estimate) can lag a source switch, and quantizing the new song's
    /// hits on the old song's bars would render — and export — a wrong pattern.
    @State private var drumBars: [DrumPatternDetector.Bar] = []
    @State private var drumBarsKey: String?
    /// The chords-only beat grid the "Extract instrumental" panel builds from (measured beat
    /// lattice when the song has a sidecar, else a constant grid from bpm). Resolved off the render
    /// path and keyed to the source (a stale async resolve must never label another source's grid
    /// as this one's — the drumBarsKey discipline).
    @State private var instBpm: Double = 120
    @State private var instFirstDownbeat = 0
    @State private var instBeatsMs: [Int] = []
    @State private var instGridKey: String?
    /// A cloud lyrics-sidecar download in flight (drives the panel's fetching row).
    @State private var cloudLyricsFetching = false

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
        .onDisappear { resolveTask?.cancel(); player.stop() }
    }

    // MARK: - Source picker

    private var pickerView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demuxer").font(.headline).foregroundStyle(Theme.fg)
                    Text(DemuxFeatures.lyricsEnabled
                         ? "Pick audio to demux into lyrics, chords, and stems"
                         : "Pick audio to demux into chords and stems")
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
                    // Each source group is COLLAPSED by default (like the collection's playlists /
                    // pockets) and remembers whether you opened it; a search auto-expands them all
                    // so matches are never hidden behind a closed group.
                    // Imported audio stays reachable (previously an import vanished from
                    // the picker once deselected — the only way back was re-importing).
                    let files = fileMatches()
                    if !files.isEmpty {
                        demuxGroup("Imported audio", "imported", count: files.count) {
                            ForEach(files, id: \.id) { fileRow($0) }
                        }
                    }
                    let studioItems = studioMatches()
                    if !studioItems.isEmpty {
                        demuxGroup("Performance media", "studio", count: studioItems.count) {
                            ForEach(studioItems, id: \.id) { item in studioRow(item) }
                        }
                    }
                    let tracks = trackMatches()
                    if !tracks.isEmpty {
                        demuxGroup("Tracks", "tracks", count: tracks.count) {
                            ForEach(tracks) { trackRow($0) }
                        }
                    }
                    if files.isEmpty && studioItems.isEmpty && tracks.isEmpty {
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

    /// A collapsible source group — collapsed by default, remembering the user's expansions (the
    /// collection playlists/pockets pattern). Uses a plain expander Button rather than a
    /// `DisclosureGroup` so the header is a reliable XCUITest tap target. While a search is active
    /// every group is force-expanded so matches are never hidden.
    @ViewBuilder private func demuxGroup(_ title: String, _ key: String, count: Int,
                                         @ViewBuilder _ content: () -> some View) -> some View {
        let expanded = !query.isEmpty || expandedGroupKeys.contains(key)
        Button {
            toggleGroup(key)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .frame(width: 10)
                Text(title).font(.caption2.weight(.semibold))
                Spacer()
                Text("\(count)").font(.caption2.monospacedDigit())
            }
            .foregroundStyle(Theme.fgDim)
            .padding(.top, 8).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("demux-group-\(key)")
        if expanded { content() }
    }

    /// The set of expanded group keys, persisted across launches. Absent ⇒ collapsed (the default).
    private var expandedGroupKeys: Set<String> {
        Set(expandedGroupsRaw.split(separator: ",").map(String.init))
    }
    private func toggleGroup(_ key: String) {
        var s = expandedGroupKeys
        if s.contains(key) { s.remove(key) } else { s.insert(key) }
        expandedGroupsRaw = s.sorted().joined(separator: ",")
    }

    private func fileMatches() -> [(id: String, name: String)] {
        let all = demux.importedSources()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(query) }
    }

    private func fileRow(_ f: (id: String, name: String)) -> some View {
        Button {
            select(.file(id: f.id, name: f.name))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.caption).foregroundStyle(Theme.accent)
                Text(f.name).foregroundStyle(Theme.fg).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bgRaised))
        .accessibilityIdentifier("demux-file-row-\(f.id)")
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
                Text((DemuxFeatures.lyricsEnabled
                      || cloudLyricsAvailable(source, demux.document(for: source.key))
                      ? "Demuxed: synced lyrics + chords"
                      : "Demuxed: chord timeline")
                     + (stemState == .burned ? " + stems" : ""))
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
                          chords: doc?.chords ?? [], player: player, follow: $demuxFollow,
                          onSeek: { seek(toMs: $0) },
                          onChordTap: { chordDetail = $0 })
        chordStatusRow(doc)
        stemsPanel(source)
        drumPatternPanel(source, doc)
        instrumentalPanel(source, doc)
        melodyPanel(source, doc)
        cutSampleRow(source)
        // The CLOUD engine (whisper sidecars) shows for any song that has one — the
        // DemuxFeatures gate's documented exit criterion. On-device recognition stays
        // env-gated (too sparse over the FULL MIX to ship as "lyrics").
        let cloud = cloudLyricsAvailable(source, doc)
        if DemuxFeatures.lyricsEnabled || cloud {
            transcriptPanel(doc)
        }
        // The user-triggered on-device lyric generator — the shipped path when there's NO cloud
        // sidecar (the cloud panel owns that case) and the env dev-seam is off. Unlike the full
        // mix, it runs over the isolated VOCALS stem (much better recognition), so it's gated on
        // the stems being on the device — exactly like the drum/melody extract panels.
        if !DemuxFeatures.lyricsEnabled && !cloud {
            lyricsPanel(source, doc)
        }
    }

    // MARK: Lyrics (vocals stem → on-device DemuxTranscriber → timed karaoke words)

    /// Parallel to the melody panel, but it TRANSCRIBES: gated on the vocals stem (the drum/melody
    /// contract), the button runs the on-device `DemuxTranscriber` over the isolated VOCALS stem
    /// (`DemuxStore.analyzeTranscript`, off @MainActor, incremental + resumable). The button reads
    /// "Generate lyrics" the first time, "Regenerate" once words exist, and "Retry"/"Resume" after
    /// a failed/interrupted run — `DemuxLyricButton.state` decides. Results persist on the SAME
    /// additive transcript fields the cloud path writes (words / status / coverage), no schema bump.
    @ViewBuilder private func lyricsPanel(_ source: DemuxSource, _ doc: DemuxDocument?) -> some View {
        let state = DemuxLyricButton.state(status: doc?.transcriptStatus,
                                           hasWords: !(doc?.words.isEmpty ?? true),
                                           running: demux.transcriptRuns.contains(source.key),
                                           hasVocals: stemState == .burned)
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Lyrics", icon: "music.mic")
            switch state {
            case .running:
                statusRow(spinner: true, "Transcribing the vocals…", a11y: "demux-transcribing")
                // Words land per finished window — show them AS THEY ARRIVE.
                if let words = doc?.words, !words.isEmpty {
                    DemuxLyricsView(words: words, player: player) { seek(toMs: $0) }
                }
            case .needsStems:
                Text("Download this track’s stems first — lyrics are read from the vocals stem.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("demux-lyrics-needs-stems")
            case .generate:
                generateLyricsButton("Generate lyrics", a11y: "demux-generate-lyrics")
            case .regenerate:
                if let diag = doc?.transcriptDiag {
                    Text(diag).font(.caption2).foregroundStyle(Theme.fgDim)
                        .accessibilityIdentifier("demux-lyrics-diag")
                }
                DemuxLyricsView(words: doc?.words ?? [], player: player) { seek(toMs: $0) }
                HStack(spacing: 8) {
                    Spacer()
                    lyricTextButton("Regenerate", "demux-lyrics-regenerate") { kickoffLyrics(force: true) }
                }
            case .retry:
                HStack(spacing: 8) {
                    Text(doc?.transcriptStatus == .failed
                         ? "Couldn’t transcribe the vocals stem."
                         : "No words recognized — probably instrumental.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                        .accessibilityIdentifier("demux-lyrics-empty")
                    lyricTextButton("Retry", "demux-lyrics-retry") { kickoffLyrics(force: true) }
                }
            case .resume:
                HStack(spacing: 8) {
                    Text("Transcription was interrupted.").font(.caption).foregroundStyle(Theme.fgDim)
                    Spacer()
                    lyricTextButton("Resume", "demux-lyrics-resume") { kickoffLyrics() }
                }
                if let words = doc?.words, !words.isEmpty {
                    DemuxLyricsView(words: words, player: player) { seek(toMs: $0) }
                }
            case .unavailable:
                Text("On-device transcription isn’t available (permission or language).")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("demux-lyrics-unavailable")
            }
        }
    }

    /// The accent-tinted primary trigger (the melody/drum "Extract …" button idiom).
    private func generateLyricsButton(_ title: String, a11y: String) -> some View {
        Button { kickoffLyrics() } label: {
            HStack(spacing: 8) {
                Image(systemName: "music.mic")
                Text(title).font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.accent)
        .accessibilityIdentifier(a11y)
    }

    /// A small borderless text button with a custom label (the `retryButton` idiom, arbitrary title).
    private func lyricTextButton(_ title: String, _ a11y: String,
                                 action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
            .accessibilityIdentifier(a11y)
    }

    /// Resolve the VOCALS stem (songs from the burn folder — its security scope handed to the run;
    /// custom audio from the demux stems cache) and kick off the on-device transcription over it.
    /// `force` re-runs the whole file; otherwise a persisted `.running` run resumes from coverage.
    private func kickoffLyrics(force: Bool = false) {
        guard let source else { return }
        if let songId = source.songId, let stems = burns.localStemURLs(forSong: songId) {
            if let vocals = stems.urls["vocals"] {
                demux.analyzeTranscript(source: source, url: vocals, durationMs: durationMs,
                                        force: force, release: stems.release)
            } else {
                stems.release?()
            }
        } else if let vocals = demux.localStemURLs(for: source.key)?["vocals"] {
            demux.analyzeTranscript(source: source, url: vocals, durationMs: durationMs, force: force)
        }
    }

    // MARK: Drum pattern (drums + bass stem onsets → color-coded bar grid → sequencer export)

    @ViewBuilder private func drumPatternPanel(_ source: DemuxSource, _ doc: DemuxDocument?) -> some View {
        let status = doc?.drumStatus ?? .none
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Drum pattern", icon: "square.grid.4x3.fill")
            if demux.drumRuns.contains(source.key) {
                statusRow(spinner: true, "Listening for drum hits…", a11y: "demux-drums-running")
            } else if status == .done, let hits = doc?.drumHits, !hits.isEmpty {
                if drumBarsKey == source.key {
                    DemuxDrumPatternView(source: source, hits: hits, bars: drumBars,
                                         durationMs: durationMs, player: player,
                                         follow: $demuxFollow,
                                         onSeek: { seek(toMs: $0) })
                } else {
                    // Bars still resolving for THIS source — never render/export the new
                    // song's hits on the previous song's bar lattice.
                    statusRow(spinner: true, "Aligning bars…", a11y: "demux-drums-bars")
                }
                HStack(spacing: 8) {
                    Text("Kick · snare · perc · other from the drums stem; the bass lane from the bass stem.")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                    Spacer()
                    retryButton("demux-drums-rerun") { kickoffDrums(force: true) }
                }
            } else if status == .failed {
                HStack(spacing: 8) {
                    Text("No clear drum hits found in the stems.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                    retryButton("demux-drums-retry") { kickoffDrums(force: true) }
                }
            } else if stemState == .burned {
                Button { kickoffDrums() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                        Text("Extract drum pattern").font(.callout.weight(.semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-drums-extract")
            } else {
                Text("Download this track’s stems first — the pattern reads the drums (+ bass) stems.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
        }
        // Bars resolve when a finished extraction is on screen (sidecar downbeats → measured
        // bars; else a constant-grid estimate from the drums stem itself). Keyed to the source
        // so a stale async resolve can never label another source's bars as this one's.
        .task(id: "\(source.key)#\(status.rawValue)") {
            guard status == .done else { return }
            guard drumBarsKey != source.key else { return }   // already resolved for this source
            let bars = await resolveDrumBars(source)
            guard isCurrent(source) else { return }
            drumBars = bars
            drumBarsKey = source.key
        }
    }

    private func kickoffDrums(force: Bool = false) {
        guard let source else { return }
        if let songId = source.songId, let stems = burns.localStemURLs(forSong: songId),
           let drums = stems.urls["drums"] {
            demux.analyzeDrumPattern(source: source, drumsURL: drums, bassURL: stems.urls["bass"],
                                     force: force, release: stems.release)
        } else if let stems = demux.localStemURLs(for: source.key), let drums = stems["drums"] {
            demux.analyzeDrumPattern(source: source, drumsURL: drums, bassURL: stems["bass"],
                                     force: force)
        }
    }

    /// The pattern grid's bars: measured sidecar downbeats when the song has an analysis
    /// sidecar (tempo drift included), else a constant grid estimated from the drums stem.
    private func resolveDrumBars(_ src: DemuxSource) async -> [DrumPatternDetector.Bar] {
        if let songId = src.songId {
            var sc = burns.localBeatGrid(forSong: songId)
            if sc == nil { sc = await burns.burnBeatGrid(forSong: songId) }
            if let sc {
                let bars = DrumPatternDetector.bars(downbeatsMs: sc.downbeatsMs,
                                                    bpm: sc.beatGridBpm,
                                                    firstDownbeatMs: sc.firstDownbeatMs,
                                                    durationMs: durationMs)
                if !bars.isEmpty { return bars }
            }
            if let got = burns.localStemURLs(forSong: songId) {
                let drums = got.urls["drums"]
                let grid: StudioGrid? = await Task.detached(priority: .utility) {
                    drums.flatMap { DrumPatternDetector.gridEstimate(url: $0) }
                }.value
                got.release?()
                if let grid, grid.bpm > 0 {
                    return DrumPatternDetector.bars(downbeatsMs: [], bpm: grid.bpm,
                                                    firstDownbeatMs: grid.firstDownbeatMs,
                                                    durationMs: durationMs)
                }
            }
            return []
        }
        if let drums = demux.localStemURLs(for: src.key)?["drums"] {
            let grid: StudioGrid? = await Task.detached(priority: .utility) {
                DrumPatternDetector.gridEstimate(url: drums)
            }.value
            if let grid, grid.bpm > 0 {
                return DrumPatternDetector.bars(downbeatsMs: [], bpm: grid.bpm,
                                                firstDownbeatMs: grid.firstDownbeatMs,
                                                durationMs: durationMs)
            }
        }
        return []
    }

    // MARK: Instrumental (chord blocks → beat-quantized chord-comping StudioTake + synced score)

    /// Parallel to the drum-pattern panel, but built from the CHORD timeline ALONE (no stems):
    /// gated on `chordStatus == .done`. Renders the synced-playback panel (shared follow → bars +
    /// score) and the "Extract instrumental" hand-off to the Instruments tab.
    @ViewBuilder private func instrumentalPanel(_ source: DemuxSource, _ doc: DemuxDocument?) -> some View {
        if doc?.chordStatus == .done, let chords = doc?.chords, !chords.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Instrumental (chord comping)", icon: "pianokeys")
                if instGridKey == source.key {
                    DemuxInstrumentalView(source: source, content: .comping(chords: chords),
                                          bpm: instBpm, firstDownbeatMs: instFirstDownbeat,
                                          beatsMs: instBeatsMs, durationMs: durationMs,
                                          player: player, follow: $demuxFollow,
                                          onSeek: { seek(toMs: $0) })
                } else {
                    statusRow(spinner: true, "Preparing the chord grid…", a11y: "demux-instrumental-preparing")
                }
            }
            // Resolve the chords-only grid once per source (song beat-grid sidecar → measured
            // lattice; else a constant grid). Keyed to the source so a stale resolve can't apply
            // one source's grid to another (the drumBars discipline).
            .task(id: "\(source.key)#inst") {
                guard instGridKey != source.key else { return }
                let g = await resolveInstrumentalGrid(source)
                guard isCurrent(source) else { return }
                instBpm = g.bpm; instFirstDownbeat = g.firstDownbeatMs; instBeatsMs = g.beatsMs
                instGridKey = source.key
            }
        }
    }

    /// The instrumental's beat grid — CHORDS ALONE (no stems). A catalog song uses its beat-grid
    /// sidecar (measured per-beat `beatsMs` + tempo + phase); everything else falls to a steady
    /// 120-BPM grid anchored at 0 (deterministic, and what the seeded fixture uses).
    private func resolveInstrumentalGrid(_ src: DemuxSource) async -> DemuxInstrumental.Grid {
        if let songId = src.songId {
            var sc = burns.localBeatGrid(forSong: songId)
            if sc == nil { sc = await burns.burnBeatGrid(forSong: songId) }
            if let sc, let bpm = sc.beatGridBpm, bpm > 0 {
                return (bpm, sc.firstDownbeatMs ?? 0, sc.beatsMs)
            }
        }
        return (120, 0, [])
    }

    // MARK: Melody (vocals/other stem → monophonic pitch-tracked single-voice StudioTake + score)

    /// Parallel to the chord-comping panel, but the TRUE melody: gated on stems (the drum-panel
    /// contract), it tracks the VOCALS stem (else `other`) with `MelodyTracker` and hands the
    /// single-voice line to the SAME synced score + Instruments hand-off. The tracked notes cache
    /// on the document (compute once, the `drumHits` precedent).
    @ViewBuilder private func melodyPanel(_ source: DemuxSource, _ doc: DemuxDocument?) -> some View {
        let status = doc?.melodyStatus ?? .none
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Instrumental (melody)", icon: "waveform.path")
            if demux.melodyRuns.contains(source.key) {
                statusRow(spinner: true, "Tracking the melody…", a11y: "demux-melody-running")
            } else if status == .done, let notes = doc?.melodyNotes, !notes.isEmpty {
                if instGridKey == source.key {
                    DemuxInstrumentalView(source: source, content: .melody(notes: notes),
                                          bpm: instBpm, firstDownbeatMs: instFirstDownbeat,
                                          beatsMs: instBeatsMs, durationMs: durationMs,
                                          player: player, follow: $demuxFollow,
                                          onSeek: { seek(toMs: $0) })
                } else {
                    statusRow(spinner: true, "Preparing the beat grid…", a11y: "demux-melody-preparing")
                }
                HStack(spacing: 8) {
                    Text("Tracked from the vocals stem (or “other” when there’s no vocal) — a solid, editable starting point.")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                    Spacer()
                    retryButton("demux-melody-rerun") { kickoffMelody(force: true) }
                }
            } else if status == .failed {
                HStack(spacing: 8) {
                    Text("No clear melody found in the stems.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                    retryButton("demux-melody-retry") { kickoffMelody(force: true) }
                }
            } else if stemState == .burned {
                Button { kickoffMelody() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                        Text("Extract melody").font(.callout.weight(.semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-melody-track")
            } else {
                Text("Download this track’s stems first — the melody reads the vocals (or “other”) stem.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("demux-melody-needs-stems")
            }
        }
        // Resolve the shared beat grid for THIS source (same resolver + key the comping panel uses,
        // so the melody panel works even when there are no chords to show the comping panel).
        .task(id: "\(source.key)#melodygrid") {
            guard instGridKey != source.key else { return }
            let g = await resolveInstrumentalGrid(source)
            guard isCurrent(source) else { return }
            instBpm = g.bpm; instFirstDownbeat = g.firstDownbeatMs; instBeatsMs = g.beatsMs
            instGridKey = source.key
        }
    }

    /// Resolve the melodic stem (VOCALS, else `other`) and kick off the pitch tracker. Songs pull
    /// from the burn folder (its security scope handed to `analyzeMelody`), custom audio from the
    /// demux stems cache.
    private func kickoffMelody(force: Bool = false) {
        guard let source else { return }
        if let songId = source.songId, let stems = burns.localStemURLs(forSong: songId) {
            if let url = stems.urls["vocals"] ?? stems.urls["other"] {
                demux.analyzeMelody(source: source, melodyURL: url, force: force, release: stems.release)
            } else {
                stems.release?()
            }
        } else if let stems = demux.localStemURLs(for: source.key),
                  let url = stems["vocals"] ?? stems["other"] {
            demux.analyzeMelody(source: source, melodyURL: url, force: force)
        }
    }

    // MARK: Cut sample (the sampler's in/out region editor over THIS loaded audio)

    private func cutSampleRow(_ source: DemuxSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Cut sample", icon: "scissors")
            Button {
                if player.isPlaying { player.togglePlayPause() }   // one-audio-owner: sheet auditions
                showCutSample = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                    Text("Cut a sample from this audio").font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.fgDim)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("demux-cut-sample")
            Text(source.songId != nil
                 ? "Opens the sampler’s region editor — full track or a mix of its stems."
                 : (demux.localStemURLs(for: source.key) != nil
                    ? "Set in/out points — full audio or a mix of its stems."
                    : "Set in/out points over this audio."))
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
        .sheet(isPresented: $showCutSample) {
            if case .song(let id, _, _) = source {
                StudioNewSampleFromTrackView(initialSongId: id)
            } else {
                DemuxCutSampleView(source: source)
            }
        }
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
        if cloudLyricsFetching {
            statusRow(spinner: true, "Fetching lyrics…", a11y: "demux-lyrics-fetching")
        } else if let source, demux.transcriptRuns.contains(source.key) {
            statusRow(spinner: true, "Transcribing on device…", a11y: "demux-transcribing")
            // Words land per finished window — show them AS THEY ARRIVE (and a re-run
            // keeps the screen honest about what's been heard so far).
            if let words = doc?.words, !words.isEmpty {
                DemuxLyricsView(words: words, player: player) { seek(toMs: $0) }
            }
        } else {
            switch doc?.transcriptStatus {
            case .done where !(doc?.words.isEmpty ?? true):
                // Regenerate is ALWAYS available (Levi): partial-coverage runs (the
                // recognizer bailing mid-song) should be one tap from a fresh pass.
                HStack(spacing: 8) {
                    sectionTitle("Lyrics", icon: "music.mic")
                    Spacer()
                    retryButton("demux-transcript-regenerate") { kickoffTranscript(force: true) }
                }
                if let diag = doc?.transcriptDiag {
                    Text(diag).font(.caption2).foregroundStyle(Theme.fgDim)
                        .accessibilityIdentifier("demux-transcript-diag")
                }
                DemuxLyricsView(words: doc?.words ?? [], player: player) { seek(toMs: $0) }
            case .running:
                // Status persisted `.running` with no live run = the app died mid-analysis.
                // The next kickoff auto-resumes from the coverage point; meanwhile show
                // what it heard and offer the resume by hand.
                HStack(spacing: 8) {
                    sectionTitle("Lyrics", icon: "music.mic")
                    Spacer()
                    Button("Resume") { kickoffTranscript() }
                        .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("demux-transcript-resume")
                }
                if let words = doc?.words, !words.isEmpty {
                    DemuxLyricsView(words: words, player: player) { seek(toMs: $0) }
                }
            case .done:
                // Retry here too (Levi 2026-07-18): a .done-empty verdict can be a stale
                // artifact of the pre-chunking transcriber (or a bad run) — let the user
                // re-trigger the on-device analysis without re-importing anything.
                HStack(spacing: 8) {
                    Text("No words recognized — probably instrumental.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                        .accessibilityIdentifier("demux-no-words")
                    retryButton("demux-transcript-retry-empty") { kickoffTranscript(force: true) }
                }
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
                // #TOUPDATE: "stays private to you" needs per-user storage + request auth on
                // the import server. Today an upload lands in the FLAT, public-read rips/*
                // namespace shared across users, and authed() fails open
                // (scripts/rip-server.mjs:1904). Drop the clause or land the server change.
                Text(source.songId == nil
                     ? "Uploads this audio to the import server to separate its stems — it stays private to you."
                     : "Not stemmed yet — separate it on the import server.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                Button("Create stems") { Task { await createStems(source) } }
                    .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("demux-stems-create")
            }
        case .creating:
            statusRow(spinner: true,
                      source.songId == nil
                      ? "Uploading + separating on the import server (this can take a few minutes)…"
                      : "Separating stems on the import server (this can take a few minutes)…",
                      a11y: "demux-stems-creating")
        case .failed(let msg):
            HStack(spacing: 8) {
                Text(msg).font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("demux-stems-failed")
                retryButton("demux-stems-retry") { Task { await createStems(source) } }
            }
        case .none:
            Text("No stems for this one yet — they’re separated on the import server (Settings ▸ Import server).")
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
            Text("This track’s audio is prepared but not on the device yet.")
                .font(.caption).foregroundStyle(Theme.fgDim)
            Button("Burn + demux") { Task { await burnThenReady(source) } }
                .font(.callout.weight(.semibold)).buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("demux-burn")
        }
    }

    private var ripFirstState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nothing to demux here", systemImage: "waveform.badge.plus")
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.fg)
            Text("There’s no prepared audio for this track yet, so there’s nothing to demux. "
                 + "Pick a track that’s already on the device, or Import an audio file.")
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
        resolveTask?.cancel()
        clearSource()
        source = src
        phase = .resolving
        searchText = ""
        // STORED so a re-selection (or leaving the tab) cancels the in-flight resolve —
        // an orphaned resolve could suspend for seconds (carve) or minutes (burn) and
        // then stomp the newer selection's phase/audio/peaks with stale state.
        resolveTask = Task { await resolve(src) }
    }

    /// A resolve that awoke from an await must still be the CURRENT run before it writes
    /// any view state — the user may have re-selected (or cancelled) while it slept.
    private func isCurrent(_ src: DemuxSource) -> Bool {
        !Task.isCancelled && source?.key == src.key
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
        drumBars = []
        drumBarsKey = nil
        instBeatsMs = []
        instGridKey = nil
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
                guard isCurrent(src) else { local.release?(); return }
                await enterReady(src, url: local.url, release: local.release, lengthMs: songLengthMs(song))
            } else {
                guard isCurrent(src) else { return }
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
        guard isCurrent(src) else { release?(); return }
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
        let loaded = await loadPeaks(src, url: url)
        guard isCurrent(src) else { return }
        peaks = loaded
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
        guard isCurrent(source) else { return }
        if r.burned > 0, let song = app.songsById[id], let local = await ensureSongAudio(song) {
            guard isCurrent(source) else { local.release?(); return }
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

    /// Transcript source ladder, CLOUD FIRST: a catalog song with a manifest lyrics sidecar
    /// (whisper over the vocals stem, produced by the offload workers) fetches that — better
    /// than any on-device recognition, works regardless of the on-device gate, and never
    /// triggers the speech permission prompt. Only sources WITHOUT a cloud sidecar fall to the
    /// gated on-device path (vocals stem when local, else the mix file).
    private func kickoffTranscript(force: Bool = false) {
        guard let source, audioURL != nil else { return }
        if let songId = source.songId, rips.hasLyricsSidecar(songId) {
            let doc = demux.documentCreating(for: source)
            // Fetched-once dedup: a landed cloud transcript isn't re-downloaded per load
            // (Regenerate forces a refetch — the sidecar may have been re-transcribed).
            if force || doc.transcriptStatus != .done || doc.transcriptEngine != "cloud" {
                Task { await fetchCloudTranscript(source, songId: songId, force: force) }
            }
            return
        }
        kickoffDeviceTranscript(force: force)
    }

    /// The ON-DEVICE ladder (vocals stem when local, else the mix file) — the path for sources
    /// with no cloud sidecar, and the fallback when a cloud fetch fails on a gated build.
    /// Gated with the panel: no recognition runs and — crucially — the speech permission
    /// prompt never appears for a feature the user can't see.
    private func kickoffDeviceTranscript(force: Bool = false) {
        guard DemuxFeatures.lyricsEnabled else { return }
        guard let source, let audioURL else { return }
        if let songId = source.songId, let stems = burns.localStemURLs(forSong: songId),
           let vocals = stems.urls["vocals"] {
            demux.analyzeTranscript(source: source, url: vocals, durationMs: durationMs,
                                    force: force, release: stems.release)
        } else if let vocals = demux.localStemURLs(for: source.key)?["vocals"] {
            demux.analyzeTranscript(source: source, url: vocals, durationMs: durationMs, force: force)
        } else {
            demux.analyzeTranscript(source: source, url: audioURL, durationMs: durationMs, force: force)
        }
    }

    /// Download + decode the cloud lyrics sidecar and land it on the document (wholesale —
    /// DemuxStore stamps done/coverage/provenance). Word timestamps are already song-relative
    /// (the vocals stem is cut-derived), so they drop straight into the karaoke panel.
    /// A device run in flight wins the race (its per-window appends would interleave with the
    /// wholesale replace); the sidecar is fetched again on the next open. A FAILED fetch
    /// (offline / corrupt sidecar) falls back to the gated on-device ladder so a dev-seam
    /// build never loses the transcription it used to get.
    private func fetchCloudTranscript(_ source: DemuxSource, songId: String, force: Bool) async {
        guard !cloudLyricsFetching else { return }
        guard !demux.transcriptRuns.contains(source.key) else { return }
        cloudLyricsFetching = true
        defer { cloudLyricsFetching = false }
        guard let url = rips.lyricsSidecarURL(forSong: songId),
              let data = try? await rips.downloadBytes(url),
              let sidecar = try? JSONDecoder().decode(RipsStore.TimedLyricsSidecar.self, from: data)
        else {
            guard isCurrent(source) else { return }
            kickoffDeviceTranscript(force: force)
            return
        }
        demux.applyCloudTranscript(
            source: source,
            words: sidecar.words.map { DemuxWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs) },
            model: sidecar.model)
    }

    /// The transcript panel shows for a source with a cloud sidecar (or an already-landed
    /// cloud transcript — the offline case) even while on-device lyrics stay env-gated.
    private func cloudLyricsAvailable(_ source: DemuxSource, _ doc: DemuxDocument?) -> Bool {
        if let songId = source.songId, rips.hasLyricsSidecar(songId) { return true }
        return doc?.transcriptEngine == "cloud" && !(doc?.words.isEmpty ?? true)
    }

    // MARK: - Stems

    private func refreshStemState(_ src: DemuxSource) {
        guard let songId = src.songId else {
            // CUSTOM audio (imported file / performance media): stems come from the upload
            // path (`/stemify-custom`) and cache in the DemuxStore, not the BurnStore.
            if demux.localStemURLs(for: src.key) != nil { stemState = .burned }
            else if rips.hasServer { stemState = .creatable }
            else { stemState = .none }
            return
        }
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

    /// Trigger separation on the import server, then pull the stems down. Catalog songs go
    /// through `/stemify` (the server separates the copy it already prepared for this user, and
    /// stamps the manifest); CUSTOM audio STREAMS the local file up via `/stemify-custom` and
    /// caches the results in the demux stems cache. Neither path acquires audio the user does
    /// not already own — a song with nothing prepared is a MISS, not a fetch.
    /// #TOUPDATE: "prepared for this user" + "is a MISS" both need the server work — rips/* is
    /// still a flat, shared, public-read namespace, and scripts/rip-server.mjs:798 still routes
    /// DIGITAL-source ids to Apple Music capture unconditionally.
    private func createStems(_ src: DemuxSource) async {
        stemState = .creating
        if let songId = src.songId {
            await rips.stemify(songId)
            if rips.isStemmed(songId) {
                await downloadStems(src)
            } else {
                stemState = .failed("The import server couldn’t stem this track (check it’s reachable and try again).")
            }
            return
        }
        // Custom: upload the resolved local audio, await the job, download the four stems.
        guard let audioURL else { stemState = .failed("No local audio to upload."); return }
        guard let remote = await rips.stemifyCustom(id: src.key, fileURL: audioURL) else {
            stemState = .failed("The import server couldn’t stem this audio (check it’s reachable and try again).")
            return
        }
        if await demux.downloadStems(for: src.key, remote: remote) != nil {
            stemState = .burned
            kickoffTranscript(force: true)   // a vocals stem just arrived — much better source
        } else {
            stemState = .failed("Couldn’t download the separated stems.")
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
        } else if stems, let got = demux.localStemURLs(for: source.key) {
            // Custom audio: stems live in the demux cache (app-managed — no security scope).
            player.load(songId: "\(source.key)#stems", localURLs: got)
        } else if let audioURL {
            stemMode = false
            // Re-resolve the scope for the mix file (the previous load released it).
            // NOTE: these helpers OPEN the security scope eagerly — on a URL mismatch the
            // handle must be released, not dropped, or the sandbox scope leaks.
            var release: (() -> Void)?
            if let songId = source.songId,
               let h = burns.localURLForPlaybackPreferringCut(forSong: songId) {
                if h.url == audioURL { release = h.release } else { h.release?() }
            } else if case .studio(let id, _) = source, let got = studio.localURLForPlayback(id: id) {
                if got.url == audioURL { release = got.release } else { got.release?() }
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
