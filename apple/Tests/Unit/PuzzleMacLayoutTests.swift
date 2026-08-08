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

        let view = NavigationStack {
            CollectorsPuzzleView(path: .constant(NavigationPath()))
        }
        .environment(engine)
        .environment(collections)
        .environment(scoreboard)
        .environment(sequencer)

        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
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
        return found
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
}
#endif
