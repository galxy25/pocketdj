import SwiftUI

/// The queue-builder sheet (the Now Playing ＋, req 2): search On-device or Cloud
/// (bottom omni bars, req 3/4), one-click ＋ per result with a long-press /
/// right-click position menu (req 5), and — with nothing running — a DRAFT list
/// whose Play hands the ids to the `playNow` funnel via `IntentServices`.
///
/// The VIEW is thin by contract: `QueueBuilderState` owns search/mode/draft/adds
/// (unit-tested there); this file renders its state and wires the environment.
/// Device results ride the BrowseState `refreshExternal` lane (never the shared
/// browse memo); cloud rides the Discover machinery. Both lists are windowed
/// (`RowWindow`) — a broad query must not build 100k rows.
struct QueueBuilderView: View {
    @Environment(AppModel.self) private var app
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(RipsStore.self) private var rips
    @Environment(CollectionsStore.self) private var collections
    @Environment(StreamingStore.self) private var streaming
    @Environment(IntentServices.self) private var intents
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @Bindable var builder: QueueBuilderState

    /// Render windows (view-state, per the ProgressiveRows idiom — the controller
    /// deliberately does not own render budgets).
    @State private var shownResults = RowWindow.page
    @State private var draftShown = RowWindow.page
    @State private var showFilter = false
    @State private var showSort = false

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            List {
                if !sequencer.isRunning { draftSection }
                if builder.mode == .device { deviceResultsSection } else { cloudResultsSection }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 30)
        }
        // Bottom omni bars via safeAreaInset — the discoverRefineRow idiom, NOT
        // `.searchable` (top-bar placement, and the macOS NSToolbar double-search
        // crash class the panel documents).
        .safeAreaInset(edge: .bottom) { omniBar }
        .background(Theme.bg)
        .sheet(isPresented: $showSort) { SortSheet(browse: builder.browse) }
        .sheet(isPresented: $showFilter) {
            FilterSheet(browse: builder.browse, app: app, collections: collections)
        }
        // The "Plays" sort needs the same play-count snapshot the Browser gets.
        .playCountsFeed(builder.browse)
        .task {
            builder.bindExternalBase(app)
            builder.cloudAdder = DiscoverQueueBuilderCloudAdder(
                app: app, rips: rips,
                library: streaming.providers.libraryContributors.first)
        }
        // Device recompute — the History `.task(id:)` idiom; the id carries mode so
        // returning from cloud re-fires for the current query. Every recompute
        // restarts the render window (new result set, new budget).
        .task(id: "\(builder.mode.rawValue)|\(builder.deviceSignature(app))") {
            guard builder.mode == .device else { return }
            shownResults = RowWindow.page
            await builder.refreshDevice(app)
        }
        .onChange(of: builder.songQuery) { refreshCloudIfNeeded() }
        .onChange(of: builder.artistQuery) { refreshCloudIfNeeded() }
        .onChange(of: builder.mode) { _, mode in
            shownResults = RowWindow.page
            if mode == .cloud { refreshCloudIfNeeded() }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-builder")
    }

    private func refreshCloudIfNeeded() {
        guard builder.mode == .cloud else { return }
        builder.refreshCloud(rips: rips, catalog: streaming.appleMusicProvider)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Queue Builder").font(.headline).foregroundStyle(Theme.fg)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.fg, Theme.bgOverlay)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)   // Esc closes, like the detail sheet
            .accessibilityLabel("Close")
            .accessibilityIdentifier("np-builder-close")
        }
        .padding(.horizontal, 14).padding(.top, 10)
    }

    // MARK: - Draft (idle regime only)

    /// The no-set accumulator: rows land here until Play starts the set. Swipe
    /// removes; drag reorders (macOS drags directly; iOS also has swipe-delete).
    @ViewBuilder private var draftSection: some View {
        let draft = builder.draft
        if !draft.isEmpty {
            Section {
                ForEach(Array(draft.prefix(draftShown).enumerated()),
                        id: \.element.uid) { offset, item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                            Text(item.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { builder.removeDraft(uids: [item.uid]) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.fgDim)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("np-builder-draft-remove-\(offset)")
                    }
                    .contentShape(Rectangle())
                    .listRowBackground(Theme.bg)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("np-builder-draft-\(offset)")
                }
                .onMove { from, to in builder.moveDraft(fromOffsets: from, toOffset: to) }
                .onDelete { offsets in
                    builder.removeDraft(uids: Set(offsets.compactMap { i in
                        builder.draft.indices.contains(i) ? builder.draft[i].uid : nil
                    }))
                }
                RowWindowSentinel(total: draft.count, shown: $draftShown)
                    .listRowBackground(Theme.bg)
            } header: {
                Text("Draft queue (\(draft.count))")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
            }
        }
    }

    // MARK: - Device results

    @ViewBuilder private var deviceResultsSection: some View {
        let results = builder.deviceResults
        Section {
            ForEach(Array(results.prefix(shownResults).enumerated()),
                    id: \.element.id) { offset, item in
                if case .song(let song, _, _, _, _) = item {
                    HStack(spacing: 8) {
                        SongRowView(data: SongRowData(song: song,
                                                      album: app.album(forSongId: song.id)))
                        addButton(offset: offset) { pos in
                            builder.add([Self.item(for: song)], at: pos, sequencer: sequencer)
                        }
                    }
                    .listRowBackground(Theme.bg)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("np-builder-row-\(offset)")
                }
            }
            RowWindowSentinel(total: results.count, shown: $shownResults)
                .listRowBackground(Theme.bg)
        } header: {
            Text("On-device (\(results.count))")
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
        }
    }

    static func item(for song: IndexSong) -> SetlistPlayer.Item {
        SetlistPlayer.Item(id: song.id, title: song.name, artist: song.artist,
                           lengthMs: song.length)
    }

    // MARK: - Cloud results

    /// Edition-preference re-rank at display time — the DiscoverResultsList rule.
    private var rankedHits: [RipsStore.DiscoverHit] {
        RipsStore.DiscoverExplicitRanking.rank(builder.discover.hits,
                                               preferExplicit: settings.preferExplicitVersions)
    }

    @ViewBuilder private var cloudResultsSection: some View {
        let hits = rankedHits
        Section {
            switch builder.discover.state {
            case .idle:
                Text("Search Apple Music — ＋ adds the song to your library and queues it.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .listRowBackground(Theme.bg)
                    .accessibilityIdentifier("np-builder-cloud-hint")
            case .loading:
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonSongRow().listRowBackground(Theme.bg)
                }
            case .loaded:
                if hits.isEmpty {
                    Text("No matches.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                        .listRowBackground(Theme.bg)
                } else {
                    ForEach(Array(hits.prefix(shownResults).enumerated()),
                            id: \.element.songId) { offset, hit in
                        cloudRow(hit: hit, offset: offset)
                    }
                    RowWindowSentinel(total: hits.count, shown: $shownResults)
                        .listRowBackground(Theme.bg)
                }
            }
        } header: {
            Text("Apple Music")
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
        }
    }

    /// Slim cloud row — DiscoverHit fields only. Deliberately NOT `DiscoverRow`
    /// (that row is BrowseView-coupled: album-preview pushes, rip-phase spinners).
    private func cloudRow(hit: RipsStore.DiscoverHit, offset: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                    if hit.explicit == true {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Theme.fgDim.opacity(0.3),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.fg)
                    }
                }
                Text([hit.artist, hit.album ?? ""].filter { !$0.isEmpty }
                        .joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hit.ripped == true || rips.manifest[hit.songId] != nil {
                Image(systemName: "checkmark.icloud")
                    .font(.caption).foregroundStyle(Theme.accent)
                    .help("Ready to play")
            }
            if let ms = hit.durationMs, ms > 0 {
                Text(String(format: "%d:%02d", ms / 60_000, (ms / 1000) % 60))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
            addButton(offset: offset) { pos in
                builder.addCloudHit(hit, at: pos, sequencer: sequencer)
            }
        }
        .listRowBackground(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-builder-row-\(offset)")
    }

    // MARK: - The ＋ (one-click add + position menu, req 5)

    /// Plain tap = bottom (the default); long-press (iOS) / right-click (macOS)
    /// picks the slot — the SetlistPlayer primitives' three positions, with
    /// "Surprise" matching the Jukebox naming for the random slot.
    private func addButton(offset: Int,
                           add: @escaping (QueueBuilderState.AddPosition) -> Void) -> some View {
        Button { add(.bottom) } label: {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { add(.bottom) } label: {
                Label("Add to end", systemImage: "text.append")
            }
            Button { add(.top) } label: {
                Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { add(.random) } label: {
                Label("Surprise", systemImage: "dice")
            }
        }
        .accessibilityIdentifier("np-builder-add-\(offset)")
    }

    // MARK: - Bottom omni bars (req 3/4)

    private var omniBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                modeToggle
                TextField("Song or album", text: $builder.songQuery)
                    .pocketField()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("np-builder-song-field")
                TextField("Artist", text: $builder.artistQuery)
                    .pocketField()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("np-builder-artist-field")
            }
            HStack(spacing: 10) {
                if builder.mode == .device {
                    Button { showFilter = true } label: {
                        Image(systemName: builder.browse.activeFilterCount > 0
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .foregroundStyle(Theme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Filter")
                    .accessibilityIdentifier("np-builder-filters")
                    Button { showSort = true } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(Theme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Sort")
                    .accessibilityIdentifier("np-builder-sort")
                }
                Spacer()
                if !sequencer.isRunning && !builder.draft.isEmpty {
                    playButton
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.bgRaised)
    }

    /// One-click device ⇄ cloud (req 4). A single button that shows the CURRENT
    /// source and flips on tap — no menu, no segmented control.
    private var modeToggle: some View {
        Button { builder.mode = builder.mode == .device ? .cloud : .device } label: {
            Image(systemName: builder.mode == .device ? "internaldrive" : "cloud")
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(builder.mode == .device
              ? "Searching on-device — tap for Cloud (Apple Music)"
              : "Searching Cloud (Apple Music) — tap for on-device")
        .accessibilityLabel("Search source")
        .accessibilityValue(builder.mode == .device ? "On-device" : "Cloud")
        .accessibilityIdentifier("np-builder-mode")
    }

    /// Draft regime only: start the set through the ONE playNow funnel (reserved
    /// Now Playing setlist ⇒ history/recs/durable session all inherit).
    private var playButton: some View {
        Button {
            // Consume-only-on-success: `playDraft` keeps the draft (and queries)
            // intact when playNow refuses — onboarding veto, or every id dropped —
            // so a failed Play never dismisses the sheet with the set silently gone.
            Task {
                let played = await builder.playDraft { ids in
                    _ = try await intents.playSongIds(ids, name: "Queue", source: .browser)
                }
                if played { dismiss() }
            }
        } label: {
            Label("Play", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(Theme.accent))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("np-builder-play")
    }
}
