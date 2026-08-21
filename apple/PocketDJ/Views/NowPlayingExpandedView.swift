import SwiftUI

/// The RESIZABLE Now Playing surface (req 7): a window-level overlay RootView
/// raises when the panel is dragged past its dock edge, sized continuously by
/// the drag (bottom sheet on iPhone portrait; left-anchored width everywhere
/// else). The PLATTER is the centerpiece and stays geometrically CENTERED at
/// every size — equal flanks on the deck cluster's either side (wide shapes) or
/// equal flexible bands above/below it (tall shapes); the queue and played
/// lists reflow into the flanks.
///
/// Deliberately NOT the docked panel re-parented: the panel's `.searchable`
/// placement is sidebar-load-bearing, and this surface needs its own platter-
/// first layout. All meaningful state lives in the shared stores, so the two
/// surfaces never disagree; adding songs here goes through the queue builder
/// (the ＋ top-left — RootView passes the same presentation the docked ＋ uses).
struct NowPlayingExpandedView: View {
    @Environment(AppModel.self) private var app
    @Environment(SetlistPlayer.self) private var sequencer

    /// Present the queue-builder sheet (RootView owns it).
    var openBuilder: () -> Void
    /// Animate back to the docked panel (RootView zeroes the persisted fraction).
    var collapse: () -> Void

    /// Song-detail sheet for the record's context menu (same door as the panel's).
    @State private var detailSong: IndexSong?
    @State private var detailPath = NavigationPath()
    /// Windowed queue flank (RowWindow) — a shuffled 26k-track set must not build
    /// a row per queued track just because the surface expanded.
    @State private var queueShown = RowWindow.page
    @State private var playedShown = RowWindow.page

    var body: some View {
        GeometryReader { geo in
            let deck = NowPlayingResize.platterSide(in: geo.size)
            if NowPlayingResize.isWideShape(geo.size) {
                wideLayout(size: geo.size, deck: deck)
            } else {
                tallLayout(deck: deck)
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { builderButton }
        .overlay(alignment: .topTrailing) { collapseButton }
        .sheet(item: $detailSong) { song in
            // Same stack-owning presentation as the docked panel's detail sheet, so
            // artist/album hotlinks push in place instead of landing blank.
            NavigationStack(path: $detailPath) {
                SongDetailView(song: song, path: $detailPath)
                    .pocketDJDestinations(path: $detailPath)
            }
            .overlay(alignment: .topLeading) {
                Button { detailSong = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.fg, Theme.bgOverlay)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(10)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("np-x-detail-close")
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-expanded-panel")
    }

    // MARK: - Layouts (equal flanks ⇒ the platter is dead-center)

    /// Wide: played list | deck | queue. The deck column takes a fixed width and
    /// each flank takes `flankLength` — 2·flank + deck == panel, so the platter
    /// sits on the horizontal center at any width.
    private func wideLayout(size: CGSize, deck: CGFloat) -> some View {
        let deckColumn = min(size.width, deck + 60)
        let flank = NowPlayingResize.flankLength(panel: size.width, deck: deckColumn)
        return HStack(spacing: 0) {
            playedFlank
                .frame(width: flank)
            deckCluster(recordSize: deck)
                .frame(width: deckColumn)
                .frame(maxHeight: .infinity)
            queueFlank
                .frame(width: flank)
        }
        .frame(maxHeight: .infinity)
    }

    /// Tall: two EQUALLY-flexible bands sandwich the deck — the VStack hands the
    /// leftover height out evenly, which is what keeps the platter vertically
    /// centered without measuring the cluster.
    private func tallLayout(deck: CGFloat) -> some View {
        VStack(spacing: 0) {
            playedFlank
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            deckCluster(recordSize: deck)
                .frame(maxWidth: .infinity)
            queueFlank
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func deckCluster(recordSize: CGFloat) -> some View {
        NowPlayingDeckCluster(recordSize: recordSize,
                              openDetail: { item in
                                  detailSong = app.songsById[item.id]
                                      ?? IndexSong.minimal(id: item.id, name: item.title,
                                                           artist: item.artist)
                              })
            .padding(.vertical, 8)
    }

    // MARK: - Flanks

    /// Read-only "previously played" (newest first) — context, not controls; the
    /// docked panel's ⟲ section keeps the full menu. Empty state stays blank on
    /// purpose (a flank is padding first, content second).
    private var playedFlank: some View {
        let played = Array(sequencer.played.reversed())
        return List {
            if !played.isEmpty {
                Section {
                    ForEach(Array(played.prefix(playedShown).enumerated()),
                            id: \.element.uid) { offset, item in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                            Text(item.artist).font(.caption2).foregroundStyle(Theme.fgDim.opacity(0.7)).lineLimit(1)
                        }
                        .listRowBackground(Theme.bg)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("np-x-played-\(offset)")
                    }
                    RowWindowSentinel(total: played.count, shown: $playedShown)
                        .listRowBackground(Theme.bg)
                } header: {
                    Text("Previously played (\(played.count))")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 30)
    }

    /// The upcoming queue: tap = jump (uid-exact), swipe/context = remove. A slim
    /// windowed list — deliberately NOT the panel's `upNextSection` (its eager
    /// per-row 4-item context menus are the documented Shuffle-perf hazard).
    private var queueFlank: some View {
        let upcoming = sequencer.upcoming
        return List {
            Section {
                ForEach(Array(upcoming.prefix(queueShown).enumerated()),
                        id: \.element.uid) { offset, item in
                    Button { sequencer.jumpToUpcoming(uid: item.uid) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                            Text(item.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            sequencer.removeUpcoming(uids: [item.uid])
                        } label: {
                            Label("Remove", systemImage: "xmark")
                        }
                    }
                    .listRowBackground(Theme.bg)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("np-x-queue-\(offset)")
                }
                .onDelete { offsets in
                    // Offset→uid via the sequencer's bridge — `upcoming` is a
                    // parent-indexed slice (the docked panel's lesson).
                    sequencer.removeUpcoming(uids: Set(offsets.compactMap {
                        sequencer.upcomingUid(atOffset: $0)
                    }))
                }
                RowWindowSentinel(total: upcoming.count, shown: $queueShown)
                    .listRowBackground(Theme.bg)
            } header: {
                Text("Up next (\(upcoming.count))")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 30)
    }

    // MARK: - Corner controls (the docked panel's dress, mirrored)

    private var builderButton: some View {
        Button(action: openBuilder) {
            Image(systemName: "plus")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.fgDim)
                .padding(8)
                .background(Theme.bgRaised.opacity(0.85), in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6).padding(.leading, 10)
        .help("Build a queue")
        .accessibilityLabel("Build a queue")
        .accessibilityIdentifier("np-x-builder-open")
    }

    private var collapseButton: some View {
        Button(action: collapse) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.fgDim)
                .padding(8)
                .background(Theme.bgRaised.opacity(0.85), in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6).padding(.trailing, 10)
        .help("Back to the docked panel")
        .accessibilityLabel("Collapse Now Playing")
        .accessibilityIdentifier("np-x-collapse")
    }
}

// MARK: - Resize grabber

/// The req-7 drag affordance: a slim capsule reading as a handle. RootView
/// attaches the actual `DragGesture` (it owns the window geometry + persisted
/// fractions) and overlays this on the panel's leading drag edge.
///
/// The grab band is SHALLOW across the panel edge. The grabber is an overlay
/// painted above the panel's list, and a hit-testable overlay swallows every tap
/// beneath it: a 44pt-DEEP rect reached past the panel's ~22pt chrome margin and
/// covered the first list row, so the Albums/Songs section headers could not be
/// collapsed at all (their tap point fell inside the handle). `bandDepth` pulls
/// the rect back inside that margin; `bandLength` stays at the original 44 so the
/// grab area is a strict SUBSET of what it was — this can only stop swallowing
/// taps, never start.
struct ResizeGrabber: View {
    enum GrabAxis { case horizontal, vertical }
    let axis: GrabAxis

    /// Across the panel edge — must stay inside the panel's chrome margin.
    private let bandDepth: CGFloat = 20
    /// Along the panel edge.
    private let bandLength: CGFloat = 44

    var body: some View {
        Capsule()
            .fill(Theme.fgDim.opacity(0.55))
            .frame(width: axis == .vertical ? 5 : 44,
                   height: axis == .vertical ? 44 : 5)
            .frame(width: axis == .vertical ? bandDepth : bandLength,
                   height: axis == .vertical ? bandLength : bandDepth)
            .contentShape(Rectangle())
            .accessibilityLabel("Resize Now Playing")
            .accessibilityIdentifier("np-resize-handle")
    }
}
