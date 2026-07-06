import SwiftUI

/// Performance ▸ SAMPLES ▸ "From track" (spec §10) — pick an indexed song, then carve a region out
/// of it into a new sample. Presented as a SHEET from `StudioSamplesView` (no init args), so it
/// never depends on the shell's navigation container; on carve it files the `StudioSample` and
/// dismisses (the samples list opens the editor on tap).
///
/// Two stages, one view:
///   1. SONG PICKER — search over the whole catalog (burned-first, burned badge shown); the same
///      idiom `StudioCuesView` uses so the two track pickers read alike.
///   2. REGION EDITOR — a waveform (local peak extraction via `MixWaveform` when a local file
///      resolves, else a flat baseline), start/end handles + "mark in/out while auditioning", fine
///      nudge (±10 ms via the slider steps; ±1 beat when the song's grid is known), and the CARVE
///      button. Audition runs through the shared `StudioEngine` sample chain windowed to the SONG's
///      slice (never the whole shared-album side), so the playhead + marks are song-relative.
///
/// Source resolution ladder (spec §10 — never a silent dead end):
///   1. BURNED locally (`BurnStore.localURLForPlaybackPreferringCut`) → carve directly;
///   2. in the rips manifest but NOT burned → **burn-on-demand** (the `StemAuditionPanel`
///      burning → ready → failed + Retry phase pattern), then carve;
///   3. no manifest entry at all (Apple-Music-only) → an explicit "Rip first" state pointing at the
///      existing rip flows.
///
/// ANALOG offset (load-bearing): when the resolved local file is the shared ALBUM file (not a
/// per-song cut), region ms are FILE-relative — the carve window is `startMs(forSong:) + region`;
/// when `isCut` is true the file already starts at the song's 0:00, so the window is the region as
/// typed. The stored `StudioSource.track` region is always SONG-relative (spec §8), so the editor's
/// "From <song> a–b" label and any re-carve read the same numbers regardless of file shape.
struct StudioNewSampleFromTrackView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(StudioEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @Environment(BurnStore.self) private var burns
    @Environment(RipsStore.self) private var rips
    @Environment(\.dismiss) private var dismiss

    /// Restrict the picker to tracks already downloaded to the device (fully offline sampling) — the
    /// "From downloaded track" entry point. Default false = browse the whole catalog (a non-downloaded
    /// pick streams / burns on demand, the normal "From track" flow).
    var restrictToDownloaded = false

    /// The source-resolution phase for the selected song (the ladder above).
    private enum SourcePhase: Equatable {
        case idle            // nothing selected
        case resolving       // resolving the ladder for the selection
        case ready           // burned local file loaded — carve enabled
        case needsBurn       // in the manifest, not burned — offer burn-on-demand
        case burning         // burn in flight
        case burnFailed(String)
        case ripFirst        // no manifest entry (Apple-Music-only)
    }

    // Picker.
    @State private var searchText = ""
    /// The chosen song — @State only (survives sub-tab hops while the shell keeps the sheet alive;
    /// nothing to persist — a carve is a one-shot).
    @State private var selectedSongId: String?

    // Region editor.
    @State private var phase: SourcePhase = .idle
    /// Region marks in SONG-relative ms (what `StudioSource.track` stores; the file-relative carve
    /// window is derived at carve time from `isCut` + the analog `startMs`).
    @State private var regionStartMs = 0
    @State private var regionEndMs = 0
    /// The song's start offset WITHIN the resolved audition file — 0 for a per-song cut, the analog
    /// album offset for a shared file. Kept so the transport can map the engine's file-seconds
    /// playhead back to song-relative for display + mark in/out.
    @State private var fileStartMs = 0
    /// The song's measured tempo (sidecar → manifest → catalog), for the ±1-beat nudge. Resolved
    /// once on `ready` so the body never touches the disk per render.
    @State private var gridBpm: Double?
    /// The loaded audition preview's marker id (`StudioEngine.loadedSampleId` gates the transport).
    @State private var previewId: String?
    @State private var peaks: [Float] = []
    @State private var carving = false
    @State private var carveError: String?

    /// The minimum carveable window — a zero-frame carve is refused by `StudioRender` anyway; the
    /// floor keeps the handles from crossing (the sample-editor trim contract).
    private static let minWindowMs = 50

    private var query: String { searchText.trimmingCharacters(in: .whitespaces).lowercased() }
    private var selectedSong: IndexSong? { selectedSongId.flatMap { app.songsById[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            if let song = selectedSong, query.isEmpty {
                ScrollView { regionEditor(song).padding(16) }
            } else {
                pickerSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
        // Resolve the ladder (and load / unload the audition preview) whenever the selection moves.
        .task(id: selectedSongId) { await resolveSource() }
        // Closing the sheet stops the audition + releases the source file's security scope (held by
        // the engine since the preview load — the editor's onDisappear contract).
        .onDisappear {
            if let pid = previewId, engine.loadedSampleId == pid { engine.unloadSample() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(restrictToDownloaded ? "Sample from downloaded" : "Sample from track")
                    .font(.headline).foregroundStyle(Theme.fg)
                Text(selectedSong == nil
                     ? (restrictToDownloaded ? "Pick a downloaded track to carve" : "Pick a track to carve")
                     : "Set the in/out points")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("sample-track-cancel")
        }
    }

    // MARK: - Song picker

    private var pickerSection: some View {
        VStack(spacing: 10) {
            TextField("Search artist or title", text: $searchText)
                .pocketField()
                .padding(.horizontal, 16)
                .accessibilityIdentifier("sample-track-search")
            ScrollView {
                let items = matches()
                if items.isEmpty {
                    Text(query.isEmpty
                         ? "Burn a track first (or search the whole catalog) to carve a sample from it."
                         : "No tracks match “\(searchText)”.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32).padding(.top, 24)
                } else {
                    // LazyVStack (not List): this lives inside a ScrollView; a nested List would
                    // fight it for scroll gestures and collapse to zero height (the Cues lesson).
                    LazyVStack(spacing: 2) {
                        ForEach(items) { trackRow($0) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }

    /// Search matches, BURNED FIRST (burned tracks are the ones that carve exactly, so they belong
    /// at the top). Empty query browses the burned subset instead of dumping the whole multi-
    /// thousand-song catalog; a query searches artist/title across everything. Capped for render
    /// cost — the field narrows past the cap.
    private func matches() -> [IndexSong] {
        let all = app.songsById.values
        let filtered: [IndexSong]
        if query.isEmpty {
            let burnedSet = Set(burns.readyBurnedIds(in: all.map(\.id)))
            filtered = all.filter { burnedSet.contains($0.id) }
        } else if restrictToDownloaded {
            // Offline mode: even a typed query only surfaces downloaded tracks, so every pick
            // resolves through the instant-carve (ready) branch — never a stream/burn.
            let burnedSet = Set(burns.readyBurnedIds(in: all.map(\.id)))
            filtered = all.filter {
                burnedSet.contains($0.id)
                    && ($0.name.lowercased().contains(query) || $0.artist.lowercased().contains(query))
            }
        } else {
            filtered = all.filter {
                $0.name.lowercased().contains(query) || $0.artist.lowercased().contains(query)
            }
        }
        let burned = Set(burns.readyBurnedIds(in: filtered.map(\.id)))
        let sorted = filtered.sorted { a, b in
            let ba = burned.contains(a.id), bb = burned.contains(b.id)
            if ba != bb { return ba }
            if a.artist.lowercased() != b.artist.lowercased() {
                return a.artist.lowercased() < b.artist.lowercased()
            }
            return a.name.lowercased() < b.name.lowercased()
        }
        return Array(sorted.prefix(120))
    }

    private func trackRow(_ song: IndexSong) -> some View {
        let isBurned = !burns.readyBurnedIds(in: [song.id]).isEmpty
        return Button {
            selectedSongId = song.id
            searchText = ""   // collapse results → the region editor shows
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(song.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
                Spacer()
                if isBurned {
                    // The same glyph Storage/Burn use for on-device music.
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
        .accessibilityIdentifier("sample-track-row-\(song.id)")
    }

    // MARK: - Region editor

    @ViewBuilder
    private func regionEditor(_ song: IndexSong) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            songHeader(song)
            switch phase {
            case .ready:
                waveformStrip(song)
                transport(song)
                handleControls(song)
                carveBar(song)
            case .needsBurn:
                burnPrompt(song)
            case .burning:
                phaseRow(spinner: true, "Burning this track for offline carving…", a11y: "sample-burning")
            case .burnFailed(let msg):
                burnFailedRow(msg)
            case .ripFirst:
                ripFirstState
            case .idle, .resolving:
                phaseRow(spinner: true, "Loading track…", a11y: "sample-resolving")
            }
        }
    }

    private func songHeader(_ song: IndexSong) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name).font(.headline).foregroundStyle(Theme.fg).lineLimit(1)
                Text(song.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            Text(Fmt.duration(song.length))
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            Button("Change") {
                selectedSongId = nil   // → the picker (task-id change unloads the preview)
            }
            .buttonStyle(.borderless).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("sample-track-change")
        }
    }

    // MARK: Waveform + region overlay

    private func waveformStrip(_ song: IndexSong) -> some View {
        let len = CGFloat(max(1, songLengthMs(song)))
        return ZStack {
            MixWaveformView(peaks: peaks)   // flat baseline while peaks are empty
            GeometryReader { geo in
                let s = min(1, CGFloat(regionStartMs) / len)
                let e = min(1, CGFloat(regionEndMs) / len)
                let w = geo.size.width
                // Region shade + the two colored handle lines (blue in / gold out — the trim
                // section's colors).
                Rectangle().fill(Theme.accent.opacity(0.18))
                    .frame(width: max(2, (e - s) * w))
                    .offset(x: s * w)
                Rectangle().fill(Theme.accent).frame(width: 2).offset(x: s * w)
                Rectangle().fill(Theme.accent2).frame(width: 2).offset(x: max(0, e * w - 2))
            }
            .allowsHitTesting(false)
            // Live playhead — SAMPLED on a TimelineView (never observed), so the 10 Hz tick redraws
            // only this overlay and never invalidates the transport buttons (the inline-player lesson).
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                GeometryReader { geo in
                    let f = min(1, max(0, playheadSongSeconds() / songLengthSeconds(song)))
                    Rectangle().fill(Theme.fg).frame(width: 1.5)
                        .offset(x: CGFloat(f) * max(0, geo.size.width - 1.5))
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Transport (audition the SONG window; mark in/out at the playhead)

    private func transport(_ song: IndexSong) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            HStack(spacing: 14) {
                Button { markIn() } label: {
                    Label("Mark in", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.iconOnly).font(.title3)
                        .frame(width: 40, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("sample-mark-in")

                Spacer()

                Text(StudioFmt.clock(playheadSongSeconds()))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)

                Button {
                    guard engine.loadedSampleId == previewId else { return }
                    if engine.isPlayingSample { engine.pauseSample() } else { engine.playSample() }
                } label: {
                    Image(systemName: engine.isPlayingSample ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 46, height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("sample-audition-play")

                Button { engine.stopSample() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3).frame(width: 40, height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("sample-audition-stop")

                Spacer()

                Button { markOut() } label: {
                    Label("Mark out", systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly).font(.title3)
                        .frame(width: 40, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent2)
                .accessibilityIdentifier("sample-mark-out")
            }
        }
    }

    // MARK: Start / end handles (±10 ms via the slider steps; ±1 beat when the grid is known)

    @ViewBuilder
    private func handleControls(_ song: IndexSong) -> some View {
        let len = Double(max(1, songLengthMs(song)))
        VStack(alignment: .leading, spacing: 12) {
            // Reusing `StudioEditSlider` gives the iPhone-portrait fixed-width popover for free
            // (its slider is too narrow to drag beside a label on a phone — spec §10).
            StudioEditSlider(title: "In", systemImage: "arrow.right.to.line",
                             range: 0...len, step: 10, value: Double(regionStartMs),
                             format: { StudioFmt.mmssTenths(Int($0)) },
                             a11y: "sample-region-start") { v in
                regionStartMs = min(Int(v), regionEndMs - Self.minWindowMs)
                if regionStartMs < 0 { regionStartMs = 0 }
            }
            beatNudgeRow(a11yPrefix: "sample-region-start-beat", isStart: true)

            StudioEditSlider(title: "Out", systemImage: "arrow.left.to.line",
                             range: 0...len, step: 10, value: Double(regionEndMs),
                             format: { StudioFmt.mmssTenths(Int($0)) },
                             a11y: "sample-region-end") { v in
                regionEndMs = max(min(Int(v), Int(len)), regionStartMs + Self.minWindowMs)
            }
            beatNudgeRow(a11yPrefix: "sample-region-end-beat", isStart: false)

            Text("Length \(StudioFmt.mmssTenths(regionEndMs - regionStartMs))"
                 + (gridBpm != nil ? " · grid \(Fmt.trim(gridBpm!)) BPM (inherited)" : " · no grid — set one in the editor"))
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    /// A ±1-beat nudge for one handle, shown only when the song's tempo is known — the fine musical
    /// step the ±10 ms slider steps can't express.
    @ViewBuilder
    private func beatNudgeRow(a11yPrefix: String, isStart: Bool) -> some View {
        if let bpm = gridBpm, bpm > 0 {
            let beat = Int((60_000.0 / bpm).rounded())
            HStack(spacing: 8) {
                Text("beat").font(.caption2).foregroundStyle(Theme.fgDim)
                    .frame(width: 108, alignment: .leading)
                Button { nudge(isStart: isStart, by: -beat) } label: {
                    Label("−1 beat", systemImage: "minus").labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.bgOverlay, in: Capsule())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier(a11yPrefix + "-minus")
                Button { nudge(isStart: isStart, by: beat) } label: {
                    Label("+1 beat", systemImage: "plus").labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.bgOverlay, in: Capsule())
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier(a11yPrefix + "-plus")
                Spacer()
            }
        }
    }

    // MARK: Carve

    private func carveBar(_ song: IndexSong) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let carveError {
                Label(carveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            Button { Task { await carve(song) } } label: {
                HStack(spacing: 8) {
                    if carving { ProgressView().controlSize(.small) }
                    Text(carving ? "Carving…" : "Create sample")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(carving || regionEndMs - regionStartMs < Self.minWindowMs)
            .accessibilityIdentifier("sample-carve")
        }
    }

    // MARK: Burn-on-demand / rip-first phases

    private func burnPrompt(_ song: IndexSong) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This track isn’t on the device yet. Burn it to carve a sample offline.",
                  systemImage: "opticaldisc")
                .font(.callout).foregroundStyle(Theme.fg)
            Button { Task { await burnThenReady(song) } } label: {
                Text("Burn for carving").font(.callout.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("sample-burn")
        }
    }

    private func burnFailedRow(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.accent2)
            Text(msg).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("sample-burn-failed")
            Spacer()
            Button("Retry") { if let s = selectedSong { Task { await burnThenReady(s) } } }
                .font(.caption).buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("sample-burn-retry")
        }
    }

    private var ripFirstState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rip this track first", systemImage: "waveform.badge.plus")
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.fg)
            Text("This song streams from Apple Music and has no local rip yet, so there’s nothing "
                 + "to carve from. Rip it (▶/⤓ on the song, or Rip in a collection / setlist) — "
                 + "once it’s ripped, come back and it’ll burn + carve here.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("sample-rip-first")
        }
    }

    private func phaseRow(spinner: Bool, _ text: String, a11y: String) -> some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text).font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier(a11y)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Source resolution (the ladder)

    private func resolveSource() async {
        // Drop the previous song's audition preview + its held scope before resolving the new one.
        if let pid = previewId, engine.loadedSampleId == pid { engine.unloadSample() }
        previewId = nil
        peaks = []
        gridBpm = nil
        fileStartMs = 0
        carveError = nil
        guard let song = selectedSong else { phase = .idle; return }
        phase = .resolving
        // A fresh region: 0 → the first ~8 s (or the whole song when it's shorter). A sample is
        // short, so an 8 s default is a useful starting window the user tightens.
        let len = songLengthMs(song)
        regionStartMs = 0
        regionEndMs = min(len, 8_000)
        if regionEndMs < Self.minWindowMs { regionEndMs = len }   // degenerate: tiny/unknown length
        if await enterReady(song) { return }
        // Not burned: manifest membership decides burn-on-demand vs. Apple-Music-only.
        phase = rips.manifest[song.id] != nil ? .needsBurn : .ripFirst
    }

    /// Resolve the burned local file, load it into the audition chain (the engine HOLDS the file's
    /// security scope for the load's lifetime), extract the waveform, and resolve the tempo for the
    /// beat nudge. Returns false when no local file resolves (→ the caller falls to burn/rip).
    @discardableResult
    private func enterReady(_ song: IndexSong) async -> Bool {
        guard let handle = burns.localURLForPlaybackPreferringCut(forSong: song.id) else { return false }
        // The song's offset within the resolved file: 0 for a per-song cut, the analog album offset
        // for a shared side. The audition window is the WHOLE SONG in FILE ms — never the whole
        // album side (a shared file would otherwise play the neighboring tracks).
        let offset = handle.isCut ? 0 : (burns.startMs(forSong: song.id) ?? 0)
        fileStartMs = offset
        let pid = StudioFactory.newSampleId()
        var windowEdit = StudioSampleEdit.neutral
        windowEdit.trimStartMs = offset
        windowEdit.trimEndMs = offset + songLengthMs(song)   // >0 ⇒ honored (engine clamps to EOF)
        let preview = StudioSample(id: pid, name: song.name, fileName: "",
                                   durationMs: songLengthMs(song),
                                   source: .track(songId: song.id, startMs: 0, endMs: songLengthMs(song)),
                                   edit: windowEdit)
        engine.loadSample(preview, url: handle.url, release: handle.release)
        previewId = pid
        gridBpm = burns.localBeatGrid(forSong: song.id)?.beatGridBpm
            ?? burns.beatGrid(forSong: song.id)?.bpm ?? song.bpm
        phase = .ready
        // Local, deterministic, offline waveform — windowed to the song's slice by MixWaveform.
        peaks = await MixWaveform.peaks(forSong: song.id, lengthMs: song.length, burns: burns)
        return true
    }

    /// Burn-on-demand (the StemAuditionPanel phase pattern): burn the single song, then re-enter
    /// `ready`. A burn that can't produce a local file maps to a specific failure + Retry.
    private func burnThenReady(_ song: IndexSong) async {
        phase = .burning
        let r = await burns.burn([(id: song.id, title: song.name, artist: song.artist)])
        if r.burned > 0 {
            if await enterReady(song) { return }
        }
        if r.notRipped > 0 {
            phase = .burnFailed("This track hasn’t been ripped yet — rip it first, then carve.")
        } else if r.folderUnavailable {
            phase = .burnFailed("Your burn folder isn’t reachable right now (Settings ▸ Storage).")
        } else if r.outOfSpace {
            phase = .burnFailed("Not enough space to burn this track.")
        } else {
            phase = .burnFailed("Couldn’t burn this track for carving.")
        }
    }

    // MARK: - Carve

    private func carve(_ song: IndexSong) async {
        carving = true
        carveError = nil
        defer { carving = false }
        // Re-resolve the source for the carve (the engine holds the AUDITION scope; this opens its
        // own): source scope released after the carve read, dest scope after the write (defer).
        guard let src = burns.localURLForPlaybackPreferringCut(forSong: song.id) else {
            carveError = "This track isn’t on the device anymore. Burn it again, then carve."
            return
        }
        defer { src.release?() }
        guard let dest = StudioFolders.folder(.samples, bookmark: studio.bookmark(for: .samples)) else {
            carveError = "Your samples folder isn’t reachable right now (Settings ▸ Storage)."
            return
        }
        defer { dest.release?() }
        // File-relative window: a shared album file needs the song's startMs added; a cut already
        // starts at the song's 0:00 (the analog-offset contract).
        let offset = src.isCut ? 0 : (burns.startMs(forSong: song.id) ?? 0)
        let fileStart = offset + regionStartMs
        let fileEnd = offset + regionEndMs
        let sampleId = StudioFactory.newSampleId()
        let fileName = StudioFolders.fileName(.samples, id: sampleId)
        let destURL = dest.url.appendingPathComponent(fileName)
        do {
            let carved = try await StudioRender.shared.carveTrackRegion(
                sourceURL: src.url, startMs: fileStart, endMs: fileEnd, to: destURL)
            let grid = await inheritedGrid(song: song)
            studio.addSample(StudioSample(
                id: sampleId, name: song.name, fileName: fileName,
                wasUserFolder: dest.isUserFolder,
                createdAt: Date().timeIntervalSince1970 * 1000,
                durationMs: carved.durationMs,
                source: .track(songId: song.id, startMs: regionStartMs, endMs: regionEndMs),
                grid: grid, edit: .neutral))
            if let pid = previewId, engine.loadedSampleId == pid { engine.unloadSample() }
            dismiss()   // the samples list opens the editor on the new row's tap
        } catch {
            carveError = "Couldn’t carve this region. Try a slightly different in/out point."
        }
    }

    /// The sample's inherited beat grid. FULL grid: the song's per-beat sidecar (song-relative ms),
    /// offset-shifted into region-relative ms, keeping only beats inside the region; the first kept
    /// downbeat (else the first kept beat) becomes `firstDownbeatMs`. Falls back to a CONSTANT grid
    /// from the scalar tempo, else nil — a grid-less sample gets one via tap-tempo in the editor.
    private func inheritedGrid(song: IndexSong) async -> StudioGrid? {
        var sidecar = burns.localBeatGrid(forSong: song.id)
        if sidecar == nil { sidecar = await burns.burnBeatGrid(forSong: song.id) }
        if let sc = sidecar, !sc.beatsMs.isEmpty {
            let kept = sc.beatsMs.filter { $0 >= regionStartMs && $0 <= regionEndMs }
                .map { $0 - regionStartMs }
            if !kept.isEmpty {
                let keptDown = sc.downbeatsMs.filter { $0 >= regionStartMs && $0 <= regionEndMs }
                    .map { $0 - regionStartMs }
                let firstDown = keptDown.first ?? kept.first ?? 0
                let bpm = sc.beatGridBpm ?? Self.bpm(fromBeatsMs: kept) ?? gridBpm ?? 120
                return StudioGrid(bpm: bpm, firstDownbeatMs: firstDown, beatsMs: kept)
            }
        }
        if let bpm = burns.beatGrid(forSong: song.id)?.bpm ?? song.bpm, bpm > 0 {
            return StudioGrid(bpm: bpm)   // constant grid — loops slice on this tempo
        }
        return nil
    }

    /// Median-interval BPM from a beat list — the fallback when a measured sidecar carries beats but
    /// no explicit tempo (median, not mean: one ragged interval must not skew it). nil for < 2 beats.
    private static func bpm(fromBeatsMs beats: [Int]) -> Double? {
        guard beats.count >= 2 else { return nil }
        let diffs = zip(beats.dropFirst(), beats).map { Double($0 - $1) }.filter { $0 > 0 }.sorted()
        guard !diffs.isEmpty else { return nil }
        let median = diffs[diffs.count / 2]
        return median > 0 ? (60_000.0 / median) : nil
    }

    // MARK: - Marks / nudges / playhead

    private func markIn() {
        let ph = Int((playheadSongSeconds() * 1000).rounded())
        regionStartMs = max(0, min(ph, regionEndMs - Self.minWindowMs))
    }

    private func markOut() {
        guard let song = selectedSong else { return }
        let ph = Int((playheadSongSeconds() * 1000).rounded())
        regionEndMs = min(songLengthMs(song), max(ph, regionStartMs + Self.minWindowMs))
    }

    private func nudge(isStart: Bool, by deltaMs: Int) {
        guard let song = selectedSong else { return }
        let len = songLengthMs(song)
        if isStart {
            regionStartMs = max(0, min(regionStartMs + deltaMs, regionEndMs - Self.minWindowMs))
        } else {
            regionEndMs = min(len, max(regionEndMs + deltaMs, regionStartMs + Self.minWindowMs))
        }
    }

    /// The audition playhead mapped to SONG-relative seconds (the engine reports FILE seconds; a
    /// shared-album file's song starts at `fileStartMs`). Clamped ≥ 0 for the shade/label.
    private func playheadSongSeconds() -> Double {
        guard engine.loadedSampleId == previewId else { return 0 }
        return max(0, engine.samplePlayheadSeconds() - Double(fileStartMs) / 1000)
    }

    // MARK: Length helpers (catalog first — always present for indexed songs and stable)

    private func songLengthMs(_ song: IndexSong) -> Int {
        if let len = song.length, len > 0 { return len }
        if let d = rips.manifest[song.id]?.durationMs, d > 0 { return d }
        return 1
    }

    private func songLengthSeconds(_ song: IndexSong) -> Double {
        max(0.001, Double(songLengthMs(song)) / 1000)
    }
}
