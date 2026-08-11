import SwiftUI

/// THE ONE TRUE TIMELINE — the Collection tab's opt-in view of the WHOLE catalog on a single axis:
/// when it entered the library.
///
/// The Collection tab still OPENS on its Activity feed (adds / hearts / removes, newest first) —
/// that default is untouched, and this view is never on screen until the grain picker is moved off
/// `.activity`. What it adds, one segment away:
///
///  • **Grain** — one row per SONG, or one row per ALBUM.
///  • **Added after a date** — off by default; on, a cutoff.
///  • **Direction** — ascending (oldest first, "watch the library grow") or descending (newest
///    first, the reading the default view has always had).
///  • **Progress** — how much of the window he has actually heard, in the header AND per row.
///  • **Cue points** — named bookmarks in the stream (`TimelineCueStore`), droppable and jumpable.
///
/// ## Performance — the rule this screen exists under
/// ~96,000 songs. NOTHING here is derived in a view body: `CollectionTimeline.build` runs on a
/// DETACHED task and publishes a finished `[Row]` plus a pre-counted `Summary`, and the list renders
/// a WINDOW of that array. The two expensive main-actor reads (the add-time union, the play-count
/// snapshot) are cached against the revisions that invalidate them, so flipping direction or moving
/// the date does not re-walk the catalog on the main thread.
///
/// ## Why a WINDOW and not a growing prefix
/// The Browser's paging grows a prefix from row 0. That cannot serve a cue jump: landing on a
/// bookmark 80,000 rows down would mean materialising 80,000 rows to reach it. So the render window
/// has a movable `windowStart` — a jump re-anchors it, which costs one page no matter how deep the
/// cue sits. Scrolling to the bottom grows the window forward automatically (append is safe);
/// moving BACKWARD is an explicit "Show earlier" button rather than an `onAppear` trigger, because
/// prepending rows under a live scroll offset makes the list jump under the user's thumb.
struct CollectionTimelineView: View {
    @Environment(AppModel.self) private var app
    /// Optional exactly like `PlayCountsFeed` reads it: always injected by the app, but a
    /// preview/test host that renders this standalone degrades to "no play data", not a trap.
    @Environment(PlayCountService.self) private var playCounts: PlayCountService?
    @Environment(TimelineCueStore.self) private var cueStore
    @Binding var path: NavigationPath
    /// Songs or albums — `.activity` never reaches here (the Collection tab shows its feed instead).
    let grain: TimelineGrain
    /// The History search field's text, so one query filters whichever tab is up.
    let query: String

    // MARK: - Published build output (never derived in a body)

    @State private var rows: [CollectionTimeline.Row] = []
    @State private var summary = CollectionTimeline.Summary()
    @State private var builtKey = ""
    @State private var building = false

    // MARK: - Filters (ephemeral — see `HistoryView.collectionGrain` for why)

    @State private var ascending = false
    @State private var dateFilterOn = false
    @State private var since = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()

    // MARK: - Render window

    @State private var windowStart = 0
    @State private var visible = BrowsePaging.pageSize
    /// The result set the window refers to; a rebuild that changes it re-anchors to the top.
    @State private var windowKey = ""

    // MARK: - Cue chrome

    @State private var showCueSheet = false
    @State private var showCueEditor = false
    @State private var cueName = ""
    @State private var cueDate = Date()
    @State private var renaming: TimelineCueStore.Cue?
    @State private var renameText = ""
    /// Set by a jump so the scroll lands on the cue row after the window re-anchors.
    @State private var scrollTarget: String?

    // MARK: - Cached main-actor inputs

    /// The play-count snapshot is an O(56k) build; the add-time union is O(96k). Both are rebuilt
    /// ONLY when the revision behind them moves, so changing grain / direction / date / query
    /// re-runs the (off-main) sort without re-paying either.
    @State private var playSnapshot: [String: Int] = [:]
    @State private var playSnapshotRev = -1
    @State private var addedAt: [String: Double] = [:]
    @State private var addedAtRev = -1

    private var sinceMs: Double? {
        dateFilterOn ? Calendar.current.startOfDay(for: since).timeIntervalSince1970 * 1000 : nil
    }

    /// Everything that changes the RESULT SET. The two revisions cover the catalog and the play
    /// data; the rest is the user's own filter state.
    private var buildKey: String {
        let cutoff = sinceMs.map { String(Int($0)) } ?? "all"
        return "\(app.catalogRevision)-\(playCounts?.revision ?? 0)-\(grain.rawValue)-\(ascending)-\(cutoff)-\(query)"
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            progressHeader
            if rows.isEmpty {
                emptyState
            } else {
                timelineList
            }
        }
        .task(id: buildKey) { await rebuild() }
        .sheet(isPresented: $showCueSheet) { cueSheet }
        .sheet(isPresented: $showCueEditor) { cueEditor }
        .alert("Rename cue", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming) { cue in
            TextField("Name", text: $renameText)
            Button("Save") {
                cueStore.rename(cue.id, to: renameText)
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { _ in Text("What do you call this point in your collection?") }
    }

    // MARK: - Controls

    /// Cutoff · direction · cues. One compact row, identical on iOS / macOS / visionOS — no
    /// platform fences, so a shared control can never end up inside an `#if os(iOS)` by accident
    /// (the `platform-fence-breaks-mac-vision-archive` lesson).
    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                dateFilterOn.toggle()
                resetWindow()
            } label: {
                Label(dateFilterOn ? "Since" : "All time",
                      systemImage: dateFilterOn ? "calendar.badge.clock" : "calendar")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(dateFilterOn ? Theme.accent.opacity(0.25) : Theme.bgOverlay,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(Theme.fg)
            .accessibilityIdentifier("timeline-date-toggle")

            if dateFilterOn {
                DatePicker("", selection: $since, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .onChange(of: since) { resetWindow() }
                    .accessibilityIdentifier("timeline-date")
            }

            Spacer(minLength: 0)

            Button {
                ascending.toggle()
                resetWindow()
            } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(Theme.fg)
            .help(ascending ? "Oldest additions first" : "Newest additions first")
            .accessibilityIdentifier("timeline-order")

            cueMenu
        }
        .padding(.horizontal).padding(.bottom, 8)
    }

    /// The cue-point control: jump to a bookmark, or drop one where you are.
    private var cueMenu: some View {
        Menu {
            if cueStore.cues.isEmpty {
                Text("No cue points yet")
            } else {
                // Newest first in the menu regardless of the stream's direction: the list of
                // bookmarks is a menu, not the timeline, and recent ones are the ones being used.
                ForEach(cueStore.cues.reversed()) { cue in
                    Button { jump(to: cue) } label: {
                        Label("\(cue.name) — \(Self.dayLabel(cue.atMs))", systemImage: "flag")
                    }
                    .accessibilityIdentifier("timeline-cue-\(cue.id.uuidString)")
                }
            }
            Divider()
            Button {
                cueName = ""
                cueDate = Date(timeIntervalSince1970: anchorMs / 1000)
                showCueSheet = true
            } label: { Label("Set cue here…", systemImage: "flag.badge.ellipsis") }
                .disabled(rows.isEmpty)
                .accessibilityIdentifier("timeline-cue-add")
            Button { showCueEditor = true } label: { Label("Edit cues…", systemImage: "list.bullet") }
                .disabled(cueStore.cues.isEmpty)
                .accessibilityIdentifier("timeline-cue-edit")
        } label: {
            Image(systemName: cueStore.cues.isEmpty ? "flag" : "flag.fill")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(cueStore.cues.isEmpty ? Theme.fg : Theme.accent2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Named points in your collection you can jump back to")
        .accessibilityIdentifier("timeline-cues")
    }

    // MARK: - Progress header

    /// "Heard 4,213 of 21,908 · 19%" plus a bar, and — the honest part — a footnote naming the
    /// items that are NOT on the axis at all.
    ///
    /// 47.8% of the catalog has no play data, so a per-row "unheard" marker would be a wall of
    /// grey. The design inverts it: unheard rows are PLAIN and heard rows earn an accent mark, so
    /// what stands out is what he has actually listened to. This header is where the size of the
    /// unheard remainder is stated, once, as a number.
    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(headline).font(.caption.weight(.semibold)).foregroundStyle(Theme.fg)
                if building {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Text("\(Int((summary.progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(summary.heard > 0 ? Theme.accent2 : Theme.fgDim)
            }
            ProgressView(value: summary.progress)
                .tint(Theme.accent2)
                .accessibilityIdentifier("timeline-progress-bar")
            if !footnote.isEmpty {
                Text(footnote).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(2)
            }
        }
        .padding(.horizontal).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-progress")
    }

    /// "Heard 4,213 of 21,908 songs" — plus, in the ALBUMS grain only, how many albums those songs
    /// are spread across. In the songs grain the row count IS the song count, and saying it twice
    /// ("… of 6 songs in 6 songs") reads like a bug.
    private var headline: String {
        let scope = dateFilterOn ? " since \(Self.dayLabel(since.timeIntervalSince1970 * 1000))" : ""
        var s = "Heard \(summary.heard.formatted()) of \(summary.songs.formatted()) songs"
        if grain == .albums {
            let n = summary.rows
            s += " in \(n.formatted()) album\(n == 1 ? "" : "s")"
        }
        return s + scope
    }

    /// What is NOT on the axis, said out loud. Both counts describe the LIBRARY, not the window.
    private var footnote: String {
        var parts: [String] = []
        if summary.undated > 0 {
            let n = summary.undated
            let unit = grain == .albums ? "album" : "song"
            parts.append(n == 1
                         ? "1 \(unit) has no add date and isn’t placed in the timeline"
                         : "\(n.formatted()) \(unit)s have no add date and aren’t placed in the timeline")
        }
        if summary.ungrouped > 0 {
            let n = summary.ungrouped
            parts.append(n == 1
                         ? "1 song isn’t on an indexed album — switch to Songs to see it"
                         : "\(n.formatted()) songs aren’t on an indexed album — switch to Songs to see them")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - The stream

    private var page: ArraySlice<CollectionTimeline.Row> {
        guard !rows.isEmpty else { return [] }
        let lo = min(windowStart, rows.count - 1)
        let hi = min(rows.count, lo + max(visible, 1))
        return rows[lo..<hi]
    }

    /// Where "Set cue here" prefills from: the instant at the TOP of the current window. Read off
    /// `windowStart` rather than tracked through per-row `onAppear` on purpose — writing `@State`
    /// from 120 rows' `onAppear` would re-render the list on every scroll tick, which is precisely
    /// the kind of churn this screen is built to avoid. The sheet carries a date picker, so the
    /// prefill only has to be close.
    private var anchorMs: Double {
        guard !rows.isEmpty else { return Date().timeIntervalSince1970 * 1000 }
        return rows[min(windowStart, rows.count - 1)].addedAtMs
    }

    private var timelineList: some View {
        ScrollViewReader { proxy in
            List {
                if windowStart > 0 {
                    Button {
                        let step = BrowsePaging.pageSize
                        windowStart = max(0, windowStart - step)
                        visible += step
                    } label: {
                        Label("Show \(min(windowStart, BrowsePaging.pageSize)) earlier "
                              + "(\(windowStart.formatted()) above)", systemImage: "chevron.up")
                            .font(.caption).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("timeline-show-earlier")
                }
                ForEach(page) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        if row.startsMonth { monthDivider(row.monthLabel) }
                        timelineRow(row)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { open(row) }
                    .onAppear { growIfLast(row) }
                    .id(row.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline-row-\(row.itemId)")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: scrollTarget) {
                guard let target = scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
    }

    private func monthDivider(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.top, 8).padding(.bottom, 4)
        .accessibilityIdentifier("timeline-month")
    }

    @ViewBuilder private func timelineRow(_ row: CollectionTimeline.Row) -> some View {
        switch row.kind {
        case .song:
            VStack(alignment: .leading, spacing: 2) {
                if let song = app.songsById[row.itemId] {
                    SongRowView(data: SongRowData(song: song,
                                                  album: song.albumId.flatMap { app.albumsById[$0] }))
                } else {
                    // The catalog changed under a built row (a source was toggled off mid-scroll).
                    // Render what the row itself carries rather than dropping it — a hole in the
                    // stream reads as a bug.
                    Text(row.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                }
                rowFooter(row).padding(.leading, 52)
            }
        case .album:
            VStack(alignment: .leading, spacing: 4) {
                if let album = app.albumsById[row.itemId] {
                    AlbumRow(album: album)
                } else {
                    Text(row.title).font(.callout).foregroundStyle(Theme.fg).lineLimit(1)
                }
                albumProgress(row)
                rowFooter(row).padding(.leading, 8)
            }
        }
    }

    /// The add date, plus the heard mark. Unheard rows deliberately get NO badge (see
    /// `progressHeader`) — the accent check is reserved for what he has actually played.
    private func rowFooter(_ row: CollectionTimeline.Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.system(size: 9))
            Text(Self.dayLabel(row.addedAtMs))
            if row.heard > 0 {
                Text("·")
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9)).foregroundStyle(Theme.accent2)
                Text(row.kind == .album
                     ? "\(row.heard)/\(row.total) heard"
                     : "\(row.plays) play\(row.plays == 1 ? "" : "s")")
                    .foregroundStyle(Theme.accent2)
                    .accessibilityIdentifier("timeline-heard-\(row.itemId)")
            }
            Spacer()
        }
        .font(.caption2).foregroundStyle(Theme.fgDim)
    }

    /// Albums always show the bar — "3 of 12" is informative in a way a bare unheard marker is not.
    private func albumProgress(_ row: CollectionTimeline.Row) -> some View {
        ProgressView(value: row.total > 0 ? Double(row.heard) / Double(row.total) : 0)
            .tint(row.fullyHeard ? Theme.accent2 : Theme.accent)
            .padding(.horizontal, 8)
            .accessibilityIdentifier("timeline-album-progress-\(row.itemId)")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40)).foregroundStyle(Theme.fgDim)
            Text(building ? "Building your timeline…" : "Nothing in this window")
                .font(.headline).foregroundStyle(Theme.fg)
            Text(dateFilterOn
                 ? "No \(grain == .albums ? "albums" : "songs") were added on or after this date. Move it back, or switch to All time."
                 : "Songs need an add date to sit on the timeline.")
                .font(.caption).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("timeline-empty")
    }

    // MARK: - Cue sheets

    private var cueSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $cueName)
                        .accessibilityIdentifier("timeline-cue-name")
                    DatePicker("Point in time", selection: $cueDate, in: ...Date(),
                               displayedComponents: .date)
                } footer: {
                    Text("A cue point bookmarks a moment in your collection — jump back to it any "
                         + "time from the flag menu.")
                }
            }
            .navigationTitle("New cue point")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCueSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        cueStore.add(name: cueName,
                                     atMs: cueDate.timeIntervalSince1970 * 1000)
                        showCueSheet = false
                    }
                    .disabled(cueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("timeline-cue-save")
                }
            }
        }
    }

    private var cueEditor: some View {
        NavigationStack {
            List {
                ForEach(cueStore.cues) { cue in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cue.name).font(.callout).foregroundStyle(Theme.fg)
                            Text(Self.dayLabel(cue.atMs)).font(.caption2).foregroundStyle(Theme.fgDim)
                        }
                        Spacer()
                        Button("Rename") {
                            renameText = cue.name
                            renaming = cue
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
                    }
                    .swipeActions {
                        Button(role: .destructive) { cueStore.remove(cue.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .accessibilityIdentifier("timeline-cue-edit-\(cue.id.uuidString)")
                }
                .onDelete { offsets in
                    for i in offsets where cueStore.cues.indices.contains(i) {
                        cueStore.remove(cueStore.cues[i].id)
                    }
                }
            }
            .navigationTitle("Cue points")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showCueEditor = false }
                }
            }
        }
    }

    // MARK: - Actions

    /// Re-anchor the window on a cue and scroll to it. O(log n) to find the row and ONE page to
    /// render it, however deep the bookmark sits.
    private func jump(to cue: TimelineCueStore.Cue) {
        guard let idx = CollectionTimeline.jumpIndex(rows: rows, atMs: cue.atMs, ascending: ascending)
        else { return }
        windowStart = idx
        visible = BrowsePaging.pageSize
        scrollTarget = rows[idx].id
    }

    private func open(_ row: CollectionTimeline.Row) {
        switch row.kind {
        case .song:  if let s = app.songsById[row.itemId] { path.append(s) }
        case .album: if let a = app.albumsById[row.itemId] { path.append(a) }
        }
    }

    /// Grow the window forward when its last row scrolls in (append only — see the type doc).
    private func growIfLast(_ row: CollectionTimeline.Row) {
        guard row.id == page.last?.id, windowStart + visible < rows.count else { return }
        visible = min(rows.count - windowStart, visible + BrowsePaging.pageSize)
    }

    private func resetWindow() {
        windowStart = 0
        visible = BrowsePaging.pageSize
    }

    // MARK: - Build

    /// Snapshot the main-actor inputs (cached against their revisions), then build OFF the main
    /// actor and publish. Driven by `.task(id: buildKey)`, so a changed input auto-cancels the
    /// in-flight run — the same debounce shape `BrowseState.refreshExternal` uses.
    private func rebuild() async {
        if builtKey == buildKey { return }
        // Debounce the TEXT QUERY only, and before any expensive work: filters and direction apply
        // at once, but a burst of keystrokes must coalesce into one build.
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
        }
        building = true
        defer { building = false }

        let pcRev = playCounts?.revision ?? 0
        if playSnapshotRev != pcRev {
            playSnapshot = playCounts?.snapshot() ?? [:]
            playSnapshotRev = pcRev
        }
        // The add-time union is derived from the CATALOG, so the catalog revision is what
        // invalidates it. Its off-main core takes value copies of the two catalog maps
        // (copy-on-write ⇒ O(1) to hand over, not a deep copy).
        if addedAtRev != app.catalogRevision {
            let songs = app.songsById
            let sources = app.songSourceById
            let scoped = app.addDatesScopedToOwnLibrary
            let overrides = app.addTimeOverrides()
            addedAt = await Task.detached(priority: .userInitiated) {
                AppModel.addedAtBySongId(songsById: songs, songSourceById: sources,
                                         filterToOwnLibrary: scoped, overrides: overrides)
            }.value
            if Task.isCancelled { return }
            addedAtRev = app.catalogRevision
        }

        let input = CollectionTimeline.Input(songsById: app.songsById, albumsById: app.albumsById,
                                             addedAt: addedAt, playCounts: playSnapshot,
                                             grain: grain, afterMs: sinceMs,
                                             ascending: ascending, query: query)
        let key = buildKey
        let result = await Task.detached(priority: .userInitiated) {
            CollectionTimeline.build(input)
        }.value
        if Task.isCancelled { return }
        rows = result.rows
        summary = result.summary
        builtKey = key
        // A new result set invalidates any window anchored in the old one.
        if windowKey != key {
            windowKey = key
            resetWindow()
        }
    }

    // MARK: - Formatting

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func dayLabel(_ epochMs: Double) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: epochMs / 1000))
    }
}
