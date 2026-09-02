#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import PocketDJ

/// Mac App Store screenshot RENDERER — a unit test because this machine has no window
/// server: `screencapture` fails and XCUITest cannot enable automation mode headlessly.
/// The PuzzleMacLayoutTests precedent proves the way out: host the REAL SwiftUI views in
/// an offscreen `NSWindow`, run a REAL AppKit layout pass, and (here) `cacheDisplay` into
/// a 2× bitmap — 1440×900 points → exactly 2880×1800 pixels, the APP_DESKTOP size ASC wants.
///
/// Everything renders against the bundled `screenshot-index` fixture catalog (the same
/// invented sample library the iPhone App Store shots used), with seeded collections,
/// play history, and loaded Mix decks so no screen ships empty. Output PNGs land in
/// /tmp/shots-final/mac/ (falling back to NSTemporaryDirectory if the host is sandboxed —
/// the fallback path is printed so the runner can copy them out).
///
/// NOT part of the product test surface: it asserts only that each PNG exists, is exactly
/// 2880×1800, and is visually non-empty — enough to fail loudly if a view renders blank.
@MainActor
final class MacScreenshotRenderTests: XCTestCase {

    /// Offscreen hosts are RETAINED for the life of the test process, never closed:
    /// tearing one down while another `NSHostingView` is alive crashes AppKit (see
    /// PuzzleMacLayoutTests, which learned this the hard way).
    private static var hosts: [NSWindow] = []

    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-shots-\(tag)-\(UUID().uuidString).json")
    }

    // MARK: - The app graph (fixture catalog + seeded stores)

    /// Every store the four rendered surfaces (and their row subviews) look up
    /// NON-optionally from the environment. Optional lookups (FavoritesStore,
    /// ProfileSourceStore, PlayCountService, PlaylistWriteBack, AlbumArtworkStore…)
    /// degrade gracefully and are injected only where cheap.
    private struct Graph {
        let app: AppModel
        let settings: SettingsStore
        let collections: CollectionsStore
        let rips: RipsStore
        let player: PlayerEngine
        let burns: BurnStore
        let coordinator: PlaybackCoordinator
        let sequencer: SetlistPlayer
        let mix: MixEngine
        let mixSessions: MixSessionStore
        let recorder: MixRecorder
        let downloader: CollectionMixDownloader
        let studio: StudioStore
        let favorites: FavoritesStore
        let intents: IntentServices
        let streaming: StreamingStore
        let history: PlayHistoryStore
        let activity: CollectionActivityStore
        let skips: SkipTracker
        let jukebox: JukeboxStore
        let rowSelection: RowSelection

        /// One injection list shared by all four shots, so a view gaining a new
        /// non-optional store dependency fails all shots identically (loudly).
        @MainActor func inject<V: View>(_ view: V) -> AnyView {
            AnyView(view
                .environment(app)
                .environment(settings)
                .environment(collections)
                .environment(rips)
                .environment(player)
                .environment(burns)
                .environment(coordinator)
                .environment(sequencer)
                .environment(mix)
                .environment(mixSessions)
                .environment(recorder)
                .environment(downloader)
                .environment(studio)
                .environment(favorites)
                .environment(intents)
                .environment(streaming)
                .environment(history)
                .environment(activity)
                .environment(skips)
                .environment(jukebox)
                .environment(rowSelection))
        }
    }

    private func makeGraph() async throws -> Graph {
        let app = AppModel(loader: FixtureCatalog(resource: "screenshot-index"))
        await app.loadIfNeeded()
        XCTAssertFalse(app.albums.isEmpty, "screenshot-index fixture must load — nothing renders from an empty catalog")

        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.shots.\(UUID().uuidString)")!)
        let collections = CollectionsStore(fileURL: tempURL("coll"))
        collections.app = app
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        // REAL on-disk burns for the songs the Mix decks load — `MixEngine.load` resolves
        // through the BurnStore and silently no-ops for an unburned id.
        let burns = try MixBurnFixture.burnStore(ids: ["sng_16", "sng_18"], rips: rips)
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let mix = MixEngine(burns: burns)
        let mixSessions = MixSessionStore(fileURL: tempURL("mixsessions"))
        let recorder = MixRecorder(engine: mix, sessions: mixSessions)
        let downloader = CollectionMixDownloader(engine: mix, burns: burns, rips: rips, transfers: nil)
        let studio = StudioStore(fileURL: tempURL("studio"))
        let favorites = FavoritesStore(fileURL: tempURL("fav"))
        let intents = IntentServices(app: app, settings: settings, collections: collections,
                                     setlistPlayer: sequencer, mix: mix, burns: burns,
                                     studio: studio, rips: rips, favorites: favorites)
        let streaming = StreamingStore()
        let history = PlayHistoryStore(fileURL: tempURL("history"))
        let activity = CollectionActivityStore(fileURL: tempURL("activity"))
        let jukebox = JukeboxStore(app: app, sequencer: sequencer, player: player,
                                   coordinator: coordinator, rips: rips,
                                   mix: mix, burns: burns,
                                   defaults: UserDefaults(suiteName: "test.shots.jb.\(UUID().uuidString)")!)
        jukebox.makePickModel = { nil }

        let graph = Graph(app: app, settings: settings, collections: collections, rips: rips,
                          player: player, burns: burns, coordinator: coordinator,
                          sequencer: sequencer, mix: mix, mixSessions: mixSessions,
                          recorder: recorder, downloader: downloader, studio: studio,
                          favorites: favorites, intents: intents, streaming: streaming,
                          history: history, activity: activity, skips: SkipTracker(),
                          jukebox: jukebox, rowSelection: RowSelection())
        seed(graph)
        return graph
    }

    /// Seed collections + history + activity + favorites with fixture-catalog songs so each
    /// surface shows a lived-in library, and load both Mix decks (harmonic 1A/1A pair, no audio
    /// is ever started).
    private func seed(_ g: Graph) {
        // Collections — two playlists, two pockets, all resolving against the fixture catalog.
        let warmup = g.collections.createPlaylist("Friday Night Warmup")
        for id in ["sng_16", "sng_17", "sng_18", "sng_19", "sng_20", "sng_1"] {
            g.collections.addSong(id, toPlaylist: warmup.id)
        }
        let rooftop = g.collections.createPlaylist("Golden Hour Rooftop")
        for id in ["sng_5", "sng_24", "sng_21", "sng_2"] {
            g.collections.addSong(id, toPlaylist: rooftop.id)
        }
        let peak = g.collections.createPocket("Peak Hour Energy")
        for id in ["sng_4", "sng_18", "sng_20"] { g.collections.addSong(id, toPocket: peak.id) }
        let windDown = g.collections.createPocket("Late Night Wind-Down")
        for id in ["sng_6", "sng_9", "sng_10"] { g.collections.addSong(id, toPocket: windDown.id) }

        // Favorites — a few hearts so ♥ badges show where rows render them.
        for id in ["sng_16", "sng_5", "sng_9"] { _ = g.favorites.toggle(id, appleMusicId: nil) }

        // Play history — a believable evening across sources, newest ~5 minutes ago.
        let now = Date().timeIntervalSince1970 * 1000
        let min = 60_000.0
        typealias Ctx = PlayHistoryStore.PlayContext
        let plays: [(id: String, title: String, artist: String, ctx: Ctx, ago: Double)] = [
            ("sng_18", "Midnight Lemonade", "DJ Meridian West",
             Ctx(source: .mix, contextId: "mx1", contextName: "Friday Night Mix"), 5 * min),
            ("sng_16", "Elevator to the Moon", "DJ Meridian West",
             Ctx(source: .mix, contextId: "mx1", contextName: "Friday Night Mix"), 9 * min),
            ("sng_20", "Fifth Floor Funk", "DJ Meridian West",
             Ctx(source: .playlist, contextId: warmup.id, contextName: "Friday Night Warmup"), 24 * min),
            ("sng_4", "Pulse", "Aria",
             Ctx(source: .pocket, contextId: peak.id, contextName: "Peak Hour Energy"), 47 * min),
            ("sng_5", "Golden Hour", "Aria",
             Ctx(source: .playlist, contextId: rooftop.id, contextName: "Golden Hour Rooftop"), 80 * min),
            ("sng_2", "Afterglow", "Aria", Ctx.browser, 3 * 60 * min),
            ("sng_9", "Blue Hour", "Velvet Meridian",
             Ctx(source: .pocket, contextId: windDown.id, contextName: "Late Night Wind-Down"), 26 * 60 * min),
            ("sng_11", "Cassette Days", "The Paper Suns", Ctx.browser, 28 * 60 * min),
            ("sng_23", "Sleepwalker's Waltz", "Luna Vale",
             Ctx(source: .playlist, contextId: rooftop.id, contextName: "Golden Hour Rooftop"), 50 * 60 * min),
        ]
        for p in plays {
            g.history.record(songId: p.id, title: p.title, artist: p.artist,
                             context: p.ctx, at: now - p.ago)
        }

        // Collection activity — a few adds for the History ▸ Collection tab.
        g.activity.record(kind: .add, itemId: "sng_16", itemTitle: "Elevator to the Moon",
                          itemArtist: "DJ Meridian West", collectionId: warmup.id,
                          collectionKind: "playlist", collectionName: "Friday Night Warmup",
                          at: now - 30 * min)
        g.activity.record(kind: .add, itemId: "sng_4", itemTitle: "Pulse", itemArtist: "Aria",
                          collectionId: peak.id, collectionKind: "pocket",
                          collectionName: "Peak Hour Energy", at: now - 55 * min)

        // Mix decks — a harmonic 1A/1A pair from the burned fixture files. Loaded, never played.
        g.mix.load(songId: "sng_16", title: "Elevator to the Moon", artist: "DJ Meridian West",
                   bpm: 122.6, camelot: "1A", key: "Ab minor", albumId: "alb_4",
                   lengthMs: 164_663, on: .a)
        g.mix.load(songId: "sng_18", title: "Midnight Lemonade", artist: "DJ Meridian West",
                   bpm: 124.0, camelot: "1A", key: "Ab minor", albumId: "alb_4",
                   lengthMs: 318_519, on: .b)
    }

    // MARK: - The window shell (sidebar + detail, mirroring RootView's chrome)

    /// A screenshot-only stand-in for RootView: the same sidebar rows (same custom icons)
    /// and a detail NavigationStack, WITHOUT RootView's onboarding gate / launch pipeline /
    /// intent plumbing — none of which belong in (or would survive) a hermetic render.
    private struct ShotShell: View {
        let selected: RootView.Section
        let content: (Binding<NavigationPath>) -> AnyView
        @State private var path = NavigationPath()

        var body: some View {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                List(RootView.Section.allCases, selection: .constant(Optional(selected))) { item in
                    rowLabel(item).tag(item)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            } detail: {
                NavigationStack(path: $path) { content($path) }
            }
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
        }

        /// RootView.rowLabel's custom marks, minus the private Pan-African shade (cosmetic).
        @ViewBuilder private func rowLabel(_ item: RootView.Section) -> some View {
            switch item {
            case .mix:
                Label { Text(item.title) } icon: { AutoMixIcon().frame(width: 25, height: 15) }
            case .jukebox:
                Label { Text(item.rawValue) } icon: {
                    JukeboxIcon(mode: .staticIcon).frame(width: 16, height: 20)
                }
            case .playlists:
                Label { Text(item.title) } icon: { DiamondIcon().frame(width: 20, height: 18) }
            default:
                Label(item.title, systemImage: item.icon)
            }
        }
    }

    // MARK: - Offscreen render → 2× PNG

    private static let pointSize = NSSize(width: 1440, height: 900)
    private static let pixelSize = (w: 2880, h: 1800)

    /// Host `view` in an offscreen window, settle layout, and capture a 2× opaque PNG.
    private func capture(_ view: AnyView, settleSeconds: Double = 3.0) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Self.pointSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        Self.hosts.append(window)

        // SwiftUI lays out asynchronously and the surfaces run `.task` work (catalog reads,
        // engine prepare) — pump the run loop until it settles.
        let deadline = Date().addingTimeInterval(settleSeconds)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()

        // 2×: a rep with double the pixel density of its point size. `cacheDisplay` honors
        // the rep's resolution, so this renders crisp Retina text with no display server.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Self.pixelSize.w, pixelsHigh: Self.pixelSize.h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            throw NSError(domain: "shots", code: 1, userInfo: [NSLocalizedDescriptionKey: "rep alloc failed"])
        }
        rep.size = Self.pointSize
        host.cacheDisplay(in: host.bounds, to: rep)

        // FLATTEN onto the app background — App Store screenshots must not carry alpha.
        guard let flat = NSBitmapImageRep(bitmapDataPlanes: nil,
                                          pixelsWide: Self.pixelSize.w, pixelsHigh: Self.pixelSize.h,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .calibratedRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: flat) else {
            throw NSError(domain: "shots", code: 2, userInfo: [NSLocalizedDescriptionKey: "flatten ctx failed"])
        }
        flat.size = Self.pointSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // Theme.bg (0x0b0f1a) as the ground, then the capture over it.
        NSColor(srgbRed: 0x0b / 255.0, green: 0x0f / 255.0, blue: 0x1a / 255.0, alpha: 1).setFill()
        NSRect(origin: .zero, size: Self.pointSize).fill()
        rep.draw(in: NSRect(origin: .zero, size: Self.pointSize))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = flat.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "shots", code: 3, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
        }
        return png
    }

    /// The output directory: /tmp/shots-final/mac, or the test host's temp dir when the
    /// host can't write there (sandboxed Mac App Store build) — printed either way.
    private func outputDir() -> URL {
        let preferred = URL(fileURLWithPath: "/tmp/shots-final/mac", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil,
           FileManager.default.isWritableFile(atPath: preferred.path) {
            return preferred
        }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("shots-final-mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    // MARK: - The test

    func testRenderMacAppStoreScreenshots() async throws {
        let g = try await makeGraph()
        let dir = outputDir()
        print("PDJ-SHOTS-DIR: \(dir.path)")

        let shots: [(name: String, section: RootView.Section,
                     make: (Binding<NavigationPath>) -> AnyView)] = [
            ("mac-01-browse", .browse, { AnyView(BrowseView(path: $0)) }),
            ("mac-02-history", .history, { AnyView(HistoryView(path: $0)) }),
            ("mac-03-collections", .playlists, { AnyView(PlaylistsView(path: $0)) }),
            ("mac-04-mix", .mix, { AnyView(MixView(path: $0)) }),
        ]

        for shot in shots {
            let shell = ShotShell(selected: shot.section, content: shot.make)
            let png = try capture(g.inject(shell))
            let url = dir.appendingPathComponent("\(shot.name).png")
            try png.write(to: url)

            // Verify: exact ASC pixel size + visually non-empty (a blank render encodes tiny).
            guard let written = NSBitmapImageRep(data: png) else {
                XCTFail("\(shot.name): unreadable PNG"); continue
            }
            XCTAssertEqual(written.pixelsWide, Self.pixelSize.w, "\(shot.name): wrong pixel width")
            XCTAssertEqual(written.pixelsHigh, Self.pixelSize.h, "\(shot.name): wrong pixel height")
            XCTAssertGreaterThan(png.count, 50_000,
                "\(shot.name): suspiciously small PNG (\(png.count) bytes) — likely a blank render")
            print("PDJ-SHOT: \(url.path) \(written.pixelsWide)x\(written.pixelsHigh) \(png.count) bytes")
        }
    }
}
#endif
