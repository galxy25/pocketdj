import SwiftUI

/// The queue-builder sheet (the Now Playing ＋, req 2): search On-device or Cloud
/// (bottom omni bars, req 3/4), one-click ＋ per result with a long-press /
/// right-click position menu (req 5), and a DRAFT list whose Play hands the ids to
/// the `playNow` funnel via `IntentServices`.
///
/// The draft and Play are shown on `draft.isEmpty` ALONE — never on
/// `sequencer.isRunning` (see QueueBuilderState's semantics doc: that gate made the
/// sheet a dead end for a paused set and for every cold launch that restored a
/// session). While a set runs, a second action flushes the draft into the live
/// queue instead of replacing it.
///
/// The VIEW is thin by contract: `QueueBuilderState` owns search/mode/draft/adds
/// (unit-tested there); this file renders its state and wires the environment.
/// Device results ride the BrowseState `refreshExternal` lane (never the shared
/// browse memo); cloud rides the Discover machinery. Both lists are windowed
/// (`RowWindow`) — a broad query must not build 100k rows.
struct QueueBuilderView: View {
    @Environment(AppModel.self) private var app
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(MixEngine.self) private var mix
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
                // The draft is the ONE receipt an add can land in, so it renders on
                // its own emptiness alone; with nothing in it, its slot carries the
                // first-run guidance instead of collapsing to a blank sheet.
                if builder.draft.isEmpty { guidanceSection } else { draftSection }
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
        // Cloud-add seam only. The external BASE binding deliberately does NOT live
        // here: two sibling `.task`s have no ordering guarantee, and when this one
        // lost, the recompute below filtered a nil base. `refreshDevice` binds it
        // itself, so the order is a call sequence, not a scheduling coin-flip.
        .task {
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
        #if os(macOS)
        // The SortSheet/FilterSheet idiom — without it a macOS sheet presents at
        // intrinsic content size, which for a windowed list is unusably small.
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    /// Is "Up next" a REAL destination right now? Only when the panel's set owns
    /// the audio: `sequencer.isRunning` alone also covers the Mix-superseded case,
    /// where the queue is neither audible nor rendered on any surface, so appending
    /// to it would be one more invisible add. Play still replaces playback there.
    private var canFlushToLiveQueue: Bool {
        NowPlayingPanel.isVisible(sequencer: sequencer, mix: mix)
    }

    private func refreshCloudIfNeeded() {
        guard builder.mode == .cloud else { return }
        builder.refreshCloud(rips: rips, catalog: streaming.appleMusicProvider)
    }

    /// The EXPLICIT submit (return key, or the ⌕ button): search NOW in whichever
    /// mode is up. Device forces past BrowseState's "already current" memo — typing
    /// the same term twice and hitting return must still produce a search — and
    /// cloud skips the 400 ms debounce rather than restarting it.
    private func submitSearch() {
        shownResults = RowWindow.page
        if builder.mode == .cloud {
            builder.refreshCloud(rips: rips, catalog: streaming.appleMusicProvider,
                                 immediate: true)
        } else {
            Task { await builder.refreshDevice(app, force: true) }
        }
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

    // MARK: - First-run guidance (shown wherever the draft would be, when empty)

    /// What a first-time user needs to know in one breath: search, ＋, Play. The
    /// second line names the RUNNING-set choice, because that is where the shipped
    /// build silently did something else than the user expected.
    @ViewBuilder private var guidanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Build a queue", systemImage: "text.badge.plus")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.fg)
                Text("Search below, then tap ＋ on any song to add it here. "
                     + "Hold ＋ to choose where it lands.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
                Text(canFlushToLiveQueue
                     ? "Play replaces what’s playing now; Up next adds to the end of the current set."
                     : "Then hit Play to start the set.")
                    .font(.caption2).foregroundStyle(Theme.fgDim)
            }
            .padding(.vertical, 2)
            .listRowBackground(Theme.bg)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("np-builder-hint")
        }
    }

    // MARK: - Draft (the ONE accumulator — running or idle)

    /// Every ＋ lands here. Swipe removes; drag reorders (macOS drags directly; iOS
    /// also has swipe-delete). Play starts it; Up next appends it to a running set.
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
                    .accessibilityIdentifier("np-builder-draft-header")
            }
        }
    }

    // MARK: - Device results

    @ViewBuilder private var deviceResultsSection: some View {
        let results = builder.deviceResults
        Section {
            // In-flight ≠ empty ≠ never-ran. The shipped header said `On-device (0)`
            // for all three (including a base that never bound), which reads as
            // "there is nothing and no way to search".
            if results.isEmpty {
                switch builder.deviceState {
                case .idle, .searching:
                    statusRow("Searching…")
                case .loaded:
                    emptyRow(builder.hasSearchTerm
                             ? "No matches on this device. Try the ☁ Apple Music source."
                             : "Nothing on this device yet — add music in Settings ▸ Sources.")
                }
            }
            ForEach(Array(results.prefix(shownResults).enumerated()),
                    id: \.element.id) { offset, item in
                if case .song(let song, _, _, _, _) = item {
                    HStack(spacing: 8) {
                        SongRowView(data: SongRowData(song: song,
                                                      album: app.album(forSongId: song.id)))
                        addButton(offset: offset) { pos in
                            builder.add([Self.item(for: song)], at: pos)
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

    // MARK: - Result-state rows (the `discover-*` idiom, in List form)

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(Theme.fgDim)
        }
        .listRowBackground(Theme.bg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("np-builder-status")
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(Theme.fgDim)
            .listRowBackground(Theme.bg)
            .accessibilityIdentifier("np-builder-empty")
    }

    private func errorRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "wifi.exclamationmark").font(.caption)
            Text(text).font(.caption)
        }
        .foregroundStyle(Theme.danger)
        .listRowBackground(Theme.bg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("np-builder-error")
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

    /// FOUR states, mirroring Browse ▸ Discover (`discover-hint` / in-flight /
    /// `discover-empty` / `discover-error`). The shipped sheet had three and read
    /// `rips.discoverError` nowhere, so an unreachable import server, a rejected
    /// token and a genuinely-empty catalog answer all rendered as "No matches."
    @ViewBuilder private var cloudResultsSection: some View {
        let hits = rankedHits
        Section {
            if !builder.hasSearchTerm {
                // Wording matches what ＋ ACTUALLY does now: it drafts. The shipped
                // line promised "queues it", which was untrue in the draft regime.
                Text("Search Apple Music — ＋ adds the song to your library and to the draft below.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .listRowBackground(Theme.bg)
                    .accessibilityIdentifier("np-builder-cloud-hint")
            } else {
                switch builder.discover.state {
                case .idle, .loading:
                    statusRow("Searching Apple Music…")
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonSongRow().listRowBackground(Theme.bg)
                    }
                case .loaded:
                    if hits.isEmpty {
                        // MusicKit hits render even when the rip-server half errored, so
                        // the error line is reached only when there is nothing to show.
                        if let message = rips.discoverError {
                            errorRow(message)
                        } else {
                            emptyRow("Nothing in the Apple Music catalog matched that.")
                        }
                    } else {
                        ForEach(Array(hits.prefix(shownResults).enumerated()),
                                id: \.element.songId) { offset, hit in
                            cloudRow(hit: hit, offset: offset)
                        }
                        RowWindowSentinel(total: hits.count, shown: $shownResults)
                            .listRowBackground(Theme.bg)
                    }
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
                builder.addCloudHit(hit, at: pos)
            }
        }
        .listRowBackground(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-builder-row-\(offset)")
    }

    // MARK: - The ＋ (one-click add + position menu, req 5)

    /// Plain tap = end of the draft (the default); long-press (iOS) / right-click
    /// (macOS) picks the slot. The labels are DRAFT-relative in both regimes now:
    /// the shipped menu said "Play next", which in the draft regime played nothing
    /// next — it inserted at draft index 0.
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
                Label("Add to top", systemImage: "text.line.first.and.arrowtriangle.forward")
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
            if let notice = builder.notice { noticeRow(notice) }
            HStack(spacing: 8) {
                TextField("Song or album", text: $builder.songQuery)
                    .pocketField()
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(submitSearch)
                    .accessibilityIdentifier("np-builder-song-field")
                TextField("Artist", text: $builder.artistQuery)
                    .pocketField()
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(submitSearch)
                    .accessibilityIdentifier("np-builder-artist-field")
                searchButton
            }
            HStack(spacing: 10) {
                modeToggle
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
                Spacer(minLength: 4)
                // The count rides the ALWAYS-visible bar, so the receipt for an add
                // can never be scrolled off the top with the draft section.
                if !builder.draft.isEmpty {
                    Text("\(builder.draft.count) queued")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
                        .lineLimit(1)
                        .accessibilityIdentifier("np-builder-draft-count")
                }
            }
            // The two exits, on their own row so neither is ever crowded out: Play
            // (always, whenever there is something to play) and — only while a set
            // runs — Up next, which appends the draft instead of replacing the set.
            if builder.canPlay {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if canFlushToLiveQueue { flushButton }
                    playButton
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.bgRaised)
        .animation(.default, value: builder.draft.count)
    }

    /// The inline receipt / refusal line (`Added 3 songs to Up next.`, or WHY a Play
    /// refused). The sheet covers the Now Playing panel on iPhone, so a confirmation
    /// behind it would not be seen at all.
    private func noticeRow(_ notice: QueueBuilderState.Notice) -> some View {
        let ok = notice.kind == .confirmation
        return HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
            Text(notice.text).font(.caption).lineLimit(2)
            Spacer(minLength: 0)
            Button { builder.clearNotice() } label: {
                Image(systemName: "xmark").font(.caption2)
                    .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("np-builder-notice-dismiss")
        }
        .foregroundStyle(ok ? Theme.fg : Theme.danger)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityElement(children: .contain)
        .accessibilityValue(ok ? "Confirmation" : "Problem")
        .accessibilityIdentifier(ok ? "np-builder-notice" : "np-builder-notice-problem")
    }

    /// The EXPLICIT trigger (req 1). The return key submits too (`.submitLabel(.search)`
    /// + `.onSubmit` on both fields); this is the visible twin for anyone who never
    /// reaches for the keyboard's Search key.
    private var searchButton: some View {
        Button(action: submitSearch) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search")
        .accessibilityLabel("Search")
        .accessibilityIdentifier("np-builder-search")
    }

    /// One-click device ⇄ cloud (req 4). A single button that shows the CURRENT
    /// source and flips on tap — no menu, no segmented control. The source is
    /// SPELLED OUT beside the glyph: the mode persists across launches, and an
    /// icon-only control left users stuck in a mode they never chose to be in.
    private var modeToggle: some View {
        Button { builder.mode = builder.mode == .device ? .cloud : .device } label: {
            HStack(spacing: 5) {
                Image(systemName: builder.mode == .device ? "internaldrive" : "cloud")
                Text(builder.mode == .device ? "On-device" : "Apple Music")
                    .font(.caption.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(builder.mode == .device
              ? "Searching on-device — tap for Apple Music"
              : "Searching Apple Music — tap for on-device")
        .accessibilityLabel("Search source")
        .accessibilityValue(builder.mode == .device ? "On-device" : "Cloud")
        .accessibilityIdentifier("np-builder-mode")
    }

    /// Exit 1 — ALWAYS available when there is something to play (never gated on
    /// `sequencer.isRunning`): start the set through the ONE playNow funnel
    /// (reserved Now Playing setlist ⇒ history/recs/durable session all inherit),
    /// which REPLACES whatever is playing. That is the original requirement: "hit
    /// play to switch the current playback section to playing this ad hoc queue".
    private var playButton: some View {
        Button {
            // Consume-only-on-success: `playDraft` keeps the draft (and queries)
            // intact when playNow refuses — onboarding veto, or every id dropped —
            // so a failed Play never dismisses the sheet with the set silently gone.
            // It also parks the refusal in `builder.notice`, which the bar renders.
            Task {
                let played = await builder.playDraft { ids in
                    _ = try await intents.playSongIds(ids, name: "Queue", source: .browser)
                }
                if played { dismiss() }
            }
        } label: {
            Label(sequencer.isRunning ? "Play now" : "Play", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(Theme.accent))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // NO `.keyboardShortcut(.defaultAction)`: both omni bars take ⏎ as SEARCH
        // (`.onSubmit(submitSearch)`), and on macOS a focused field's Return also
        // fires the window's default button — one keystroke doing both would race.
        // A typing user means "search"; Play is a deliberate tap.
        .help(sequencer.isRunning
              ? "Play these now — replaces what’s playing"
              : "Play these now")
        .accessibilityIdentifier("np-builder-play")
    }

    /// Exit 2 — running sets only: append the draft to the LIVE queue and clear it,
    /// with an inline receipt (the panel behind this sheet is covered on iPhone).
    /// Long-press / right-click picks the slot, so the three live-edit primitives
    /// the shipped build spent the plain ＋ on are all still one gesture away.
    private var flushButton: some View {
        Button { builder.flushToQueue(at: .bottom, sequencer: sequencer) } label: {
            Label("Up next", systemImage: "text.append")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().stroke(Theme.accent, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { builder.flushToQueue(at: .bottom, sequencer: sequencer) } label: {
                Label("Add to end of the set", systemImage: "text.append")
            }
            Button { builder.flushToQueue(at: .top, sequencer: sequencer) } label: {
                Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { builder.flushToQueue(at: .random, sequencer: sequencer) } label: {
                Label("Surprise", systemImage: "dice")
            }
        }
        .help("Add these to the end of what’s playing")
        .accessibilityIdentifier("np-builder-flush")
    }
}
