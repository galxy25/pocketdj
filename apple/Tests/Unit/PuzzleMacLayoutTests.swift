#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import PocketDJ

/// macOS LAYOUT guard for the Collectors Puzzle setup screen.
///
/// Why a unit test and not an XCUITest: macOS UI automation is unavailable on the build host
/// ("Timed out while enabling automation mode"), which is exactly how a setup form whose
/// controls all rendered off the right edge reached a user past a green suite. So this hosts
/// the REAL view in an offscreen `NSWindow`, runs a REAL AppKit layout pass, and reads the
/// resulting ACCESSIBILITY FRAMES. No display required.
///
/// It asserts on FRAMES, not on pixels. An earlier draft of this file measured "is anything
/// drawn in the bottom strip of the window" — and passed against the broken build, because a
/// scrolling list of collections draws there too. Frames name the actual control: a Start
/// button at y≈2800 in a 700pt window is unreachable, and ink elsewhere cannot disguise it.
/// (Verified both ways: with the fix reverted these tests fail; with it in place they pass.)
///
/// The two defects pinned here:
///   • `Form` defaults to `FormStyle.columns` on macOS, whose content column takes the widest
///     row's ideal width. The collection rows are `HStack { Text … Spacer() }`, and a
///     `Spacer`'s ideal width is unbounded, so the grid grew past the window and pushed every
///     control off the right edge — the reported "collections shoved to the right of the
///     screen and no other controls visible or usable".
///   • Start was a Form ROW at the bottom of the scroll, so it left the screen entirely once
///     the user had more than a couple of collections.
@MainActor
final class PuzzleMacLayoutTests: XCTestCase {

    /// Offscreen hosts are RETAINED for the life of the test process, never closed: tearing
    /// one down while another `NSHostingView` is alive crashes AppKit here, and a test that
    /// crashes teaches nothing.
    private static var hosts: [NSWindow] = []

    private func tempURL(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-maclayout-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Host the setup screen offscreen over a fixture catalog with `collectionCount`
    /// collections and return every identified control with its frame in the window.
    private func probeSetup(size: CGSize, collectionCount: Int) async throws -> [String: CGRect] {
        try await probe(size: size, collectionCount: collectionCount, startRound: false, targets: 1)
    }

    /// The RUNNING screen, measured the same way. Added with the "file into any collection"
    /// change (2026-08): that change puts a NEW button row and a tappable card on a screen this
    /// file had never measured, and all three of this game's shipped defects were macOS layout
    /// — on a platform where XCUITest cannot run headlessly, so nothing else would catch a
    /// repeat. `targets: 0` drives the no-targets mode, where `puzzle-file` is the ONLY scoring
    /// control and therefore the one that absolutely must be on screen.
    private func probeRunning(size: CGSize, collectionCount: Int,
                              targets: Int) async throws -> [String: CGRect] {
        try await probe(size: size, collectionCount: collectionCount, startRound: true, targets: targets)
    }

    private func probe(size: CGSize, collectionCount: Int,
                       startRound: Bool, targets: Int) async throws -> [String: CGRect] {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let burns = BurnStore(rips: rips, fileURL: tempURL("burns"))
        let player = PlayerEngine()
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let sequencer = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        let collections = CollectionsStore(fileURL: tempURL("coll"))
        collections.app = app
        for i in 1...collectionCount { _ = collections.createPlaylist("Crate \(i)") }
        let scoreboard = GameScoreboardStore(fileURL: tempURL("scores"))
        let engine = CollectorsPuzzleEngine(
            app: app, sequencer: sequencer, collections: collections,
            favorites: FavoritesStore(fileURL: tempURL("fav")),
            playStats: PlayStatsStore(fileURL: tempURL("stats")),
            scoreboard: scoreboard,
            decisions: PuzzleDecisionStore(fileURL: tempURL("dec")),
            defaults: UserDefaults(suiteName: "test.maclayout.\(UUID().uuidString)")!)
        if startRound {
            var settings = engine.settings
            settings.targetCollectionIds = collections.playlists.prefix(targets).map(\.id)
            engine.updateSettings(settings)
            engine.countdownEnabled = false
            engine.rng = PRNG.seededRng("mac-layout")
            await engine.startRound()
            XCTAssertEqual(engine.phase, .running, "the probe needs a live round to measure")
        }

        // `AppModel` is injected too: the running screen presents `AddToCollectionView`, which
        // requires it NON-optionally from the environment — a probe that reaches the running
        // phase without it traps the moment the sheet is built.
        let view = NavigationStack {
            CollectorsPuzzleView(path: .constant(NavigationPath()))
        }
        .environment(engine)
        .environment(collections)
        .environment(scoreboard)
        .environment(sequencer)
        .environment(app)

        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        // Order the window in (no display server needed): without this an offscreen
        // `NSHostingView` never "appears" in the headless GUI-runner host, so SwiftUI never
        // builds the platform ACCESSIBILITY tree and the walk below finds ZERO ids — every
        // assertion failed "… is not in the layout at all — ids: []" the first time the macOS
        // suite ran in CI. An interactive/Aqua session happened to build the tree without
        // this, which is why it passed when first written. `MacScreenshotRenderTests` learned
        // the identical lesson for its offscreen render.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.hosts.append(window)
        // SwiftUI lays out asynchronously and the screen's `.task` loads the draft settings;
        // pump the run loop until it settles.
        for _ in 0..<60 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()

        var found: [String: CGRect] = [:]
        walk(host as AnyObject, into: &found, host: host)
        if found.isEmpty {
            print("PDJ-DIAG: host=\(host) subviews=\(host.subviews.count) isHiddenOrHasHiddenAncestor=\(host.isHiddenOrHasHiddenAncestor) window=\(String(describing: host.window)) windowNumber=\(host.window?.windowNumber ?? -999) isVisible=\(host.window?.isVisible ?? false)")
            dumpTree(host as AnyObject, depth: 0)
        }
        return found
    }

    /// DIAGNOSTIC ONLY: dump every node's class + role + identifier + child count regardless
    /// of whether it carries an identifier, to see whether the walk reaches real content at all.
    private func dumpTree(_ element: AnyObject, depth: Int) {
        guard depth < 6 else { return }
        let cls = String(describing: type(of: element))
        let role = (element as? NSAccessibility)?.accessibilityRole()?.rawValue ?? "?"
        let id = element.accessibilityIdentifier?() ?? "(nil)"
        let kids = element.accessibilityChildren?() ?? []
        print("PDJ-DIAG:\(String(repeating: "  ", count: depth))[\(cls)] role=\(role) id=\(id) kids=\(kids.count)")
        for child in kids {
            dumpTree(child as AnyObject, depth: depth + 1)
        }
    }

    /// Depth-first walk of the hosted view's accessibility tree, keeping the FIRST frame seen
    /// for each identifier (SwiftUI can vend a control more than once).
    private func walk(_ element: AnyObject, into out: inout [String: CGRect], host: NSView, depth: Int = 0) {
        guard depth < 40 else { return }
        if let id = element.accessibilityIdentifier?(), !id.isEmpty, out[id] == nil {
            var frame = element.accessibilityFrame?() ?? .zero
            if frame != .zero, let window = host.window {
                frame = host.convert(window.convertFromScreen(frame), from: nil)
            }
            out[id] = frame
        }
        for child in (element.accessibilityChildren?() ?? []) {
            walk(child as AnyObject, into: &out, host: host, depth: depth + 1)
        }
    }

    private func frame(_ probes: [String: CGRect], _ id: String) throws -> CGRect {
        try XCTUnwrap(probes[id],
                      "\(id) is not in the layout at all — ids: \(probes.keys.sorted())")
    }

    // MARK: - Assertions

    /// No control may be pushed off the RIGHT edge — the columns-Form overflow, where the grid
    /// grew wider than the window and slid everything out of view.
    func testSetupControlsStayInsideTheWindowWidthOnMac() async throws {
        let size = CGSize(width: 900, height: 700)
        let probes = try await probeSetup(size: size, collectionCount: 4)
        XCTAssertFalse(probes.isEmpty, "the setup screen exposed no identified controls at all")
        for id in ["puzzle-round-length", "puzzle-playcount-bias", "puzzle-favorite-bias",
                   "puzzle-genres", "puzzle-membership-mode", "puzzle-pool-count", "puzzle-start"] {
            let f = try frame(probes, id)
            XCTAssertGreaterThanOrEqual(f.minX, 0, "\(id) starts left of the window: \(f)")
            XCTAssertLessThanOrEqual(f.maxX, size.width,
                                     "\(id) runs past the right edge of a \(Int(size.width))pt window: \(f)")
        }
        // A target-collection row must sit at the leading edge, not be squeezed into a
        // trailing content column (the reported "collections jammed to the right").
        let target = try XCTUnwrap(probes.first { $0.key.hasPrefix("puzzle-target-") }?.value,
                                   "no target-collection row in the layout")
        XCTAssertLessThan(target.minX, size.width / 2,
                          "the target row starts in the right half of the window: \(target)")
    }

    /// Start must be ON SCREEN — the whole button, inside the window — however long the target
    /// list is. As a Form row below every collection it was thousands of points down.
    func testStartIsOnScreenWithManyCollections() async throws {
        let size = CGSize(width: 900, height: 700)
        let probes = try await probeSetup(size: size, collectionCount: 60)
        let start = try frame(probes, "puzzle-start")
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(start),
                      "Start is not inside the \(size) window with 60 collections: \(start)")
        // …and it is PINNED near the bottom, not merely somewhere in a long scroll.
        XCTAssertGreaterThan(start.minY, size.height / 2,
                             "Start is not pinned near the bottom of the window: \(start)")
    }

    /// …and in a narrow window too (a split Mac window / a small pane).
    func testStartIsOnScreenInANarrowWindow() async throws {
        let size = CGSize(width: 520, height: 640)
        let probes = try await probeSetup(size: size, collectionCount: 12)
        let start = try frame(probes, "puzzle-start")
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(start),
                      "Start is outside the narrow \(size) window: \(start)")
    }

    // MARK: - The RUNNING screen (never measured before the "file into any collection" change)

    /// With NO targets, `puzzle-file` is the ONLY way to score a point. If it renders
    /// off-screen or zero-sized on macOS the game is unplayable in exactly the way the last
    /// three defects were — and no iOS test and no XCUITest can see it.
    func testRunningControlsAreOnScreenWithNoTargets() async throws {
        let size = CGSize(width: 900, height: 700)
        let probes = try await probeRunning(size: size, collectionCount: 6, targets: 0)
        let window = CGRect(origin: .zero, size: size)
        for id in ["puzzle-timer", "puzzle-score", "puzzle-current", "puzzle-file",
                   "puzzle-skip", "puzzle-end"] {
            let f = try frame(probes, id)
            XCTAssertFalse(f.isEmpty, "\(id) has an EMPTY frame — it draws nothing: \(f)")
            XCTAssertTrue(window.contains(f), "\(id) is outside the \(size) window: \(f)")
        }
        XCTAssertNil(probes["puzzle-assign-0"], "no targets ⇒ no one-tap assign buttons")
        let file = try frame(probes, "puzzle-file")
        XCTAssertLessThanOrEqual(file.width, size.width,
                                 "the File-into button is wider than the window: \(file)")
        XCTAssertGreaterThanOrEqual(file.height, 30, "…and it is a real tap target: \(file)")
    }

    /// With three targets the row is at its widest — three assign buttons PLUS the "Other…"
    /// escape hatch. `ViewThatFits` has to fall back to the vertical stack rather than let a
    /// button run off the edge.
    func testRunningControlsAreOnScreenWithThreeTargetsPlusTheEscapeHatch() async throws {
        let size = CGSize(width: 900, height: 700)
        let probes = try await probeRunning(size: size, collectionCount: 6, targets: 3)
        let window = CGRect(origin: .zero, size: size)
        for id in ["puzzle-current", "puzzle-assign-0", "puzzle-assign-1", "puzzle-assign-2",
                   "puzzle-file", "puzzle-skip", "puzzle-end"] {
            let f = try frame(probes, id)
            XCTAssertFalse(f.isEmpty, "\(id) has an EMPTY frame: \(f)")
            XCTAssertTrue(window.contains(f), "\(id) is outside the \(size) window: \(f)")
        }
    }

    /// …and in a narrow window, where the horizontal button row cannot possibly fit.
    func testRunningControlsAreOnScreenInANarrowWindow() async throws {
        let size = CGSize(width: 520, height: 700)
        let probes = try await probeRunning(size: size, collectionCount: 6, targets: 2)
        let window = CGRect(origin: .zero, size: size)
        for id in ["puzzle-current", "puzzle-assign-0", "puzzle-assign-1", "puzzle-file",
                   "puzzle-skip", "puzzle-end"] {
            let f = try frame(probes, id)
            XCTAssertFalse(f.isEmpty, "\(id) has an EMPTY frame in a narrow window: \(f)")
            XCTAssertTrue(window.contains(f), "\(id) is outside the narrow \(size) window: \(f)")
        }
    }
}
#endif
