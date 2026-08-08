#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import PocketDJ

/// macOS LAYOUT guard for the Collectors Puzzle setup screen.
///
/// Why a unit test and not an XCUITest: macOS UI automation is unavailable on the build
/// host ("Timed out while enabling automation mode"), which is exactly how the shipped
/// regression — a setup form whose controls all rendered off the right edge — reached a
/// user past a green suite. So this hosts the REAL view in an offscreen `NSWindow`, runs a
/// REAL AppKit layout + draw pass, and measures the PIXELS. No display required.
///
/// The bug it pins: `Form` defaults to `FormStyle.columns` on macOS, whose content column
/// takes the widest row's ideal width. The collection rows are `HStack { Text … Spacer() }`
/// and a `Spacer`'s ideal width is unbounded, so the grid grew far past the window and only
/// the tail of the label column stayed on screen — the left ~95% of the form drew nothing.
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
    /// collections and return its drawn bitmap.
    private func renderSetup(size: CGSize, collectionCount: Int) async throws -> NSBitmapImageRep {
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
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "no bitmap for the hosted view")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Fraction of pixels in `rect` (in POINT coordinates, top-left origin) that differ from
    /// the window's background — i.e. how much of that region actually has UI drawn in it.
    private func inkFraction(_ rep: NSBitmapImageRep, _ rect: CGRect, size: CGSize) -> Double {
        let sx = Double(rep.pixelsWide) / size.width
        let sy = Double(rep.pixelsHigh) / size.height
        // The background is whatever fills the very top-left corner of the form area.
        let bg = rep.colorAt(x: 2, y: 2)
        var total = 0, ink = 0
        var y = Int(rect.minY * sy)
        while y < Int(rect.maxY * sy), y < rep.pixelsHigh {
            var x = Int(rect.minX * sx)
            while x < Int(rect.maxX * sx), x < rep.pixelsWide {
                total += 1
                if let c = rep.colorAt(x: x, y: y), let b = bg, !similar(c, b) { ink += 1 }
                x += 2
            }
            y += 2
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private func similar(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.deviceRGB), let y = b.usingColorSpace(.deviceRGB)
        else { return false }
        return abs(x.redComponent - y.redComponent) < 0.04
            && abs(x.greenComponent - y.greenComponent) < 0.04
            && abs(x.blueComponent - y.blueComponent) < 0.04
    }

    // MARK: - Assertions

    /// The setup form must actually PAINT in the left half of a normal Mac window. Pre-fix
    /// the columns-Form grid overflowed to the right and the left half was bare background.
    func testSetupFormPaintsAcrossTheWindowOnMac() async throws {
        let size = CGSize(width: 900, height: 700)
        let rep = try await renderSetup(size: size, collectionCount: 4)
        // Form body only — exclude the title bar strip and the pinned bottom bar.
        let leftHalf = CGRect(x: 0, y: 60, width: size.width / 2, height: size.height - 140)
        let rightHalf = CGRect(x: size.width / 2, y: 60, width: size.width / 2, height: size.height - 140)
        let left = inkFraction(rep, leftHalf, size: size)
        let right = inkFraction(rep, rightHalf, size: size)
        XCTAssertGreaterThan(left, 0.02,
            "the LEFT half of the setup form drew nothing (ink \(left)) — the controls are shoved off to the right")
        XCTAssertGreaterThan(right, 0.02,
            "the RIGHT half of the setup form drew nothing (ink \(right))")
    }

    /// The pinned Start bar must paint at the bottom of the window even when the target
    /// list is far longer than the screen — the "never able to start the game" defect.
    func testStartBarPaintsAtTheBottomWithManyCollections() async throws {
        let size = CGSize(width: 900, height: 700)
        let rep = try await renderSetup(size: size, collectionCount: 60)
        let bottomBar = CGRect(x: 0, y: size.height - 64, width: size.width, height: 60)
        let ink = inkFraction(rep, bottomBar, size: size)
        XCTAssertGreaterThan(ink, 0.05,
            "no Start bar painted in the bottom \(Int(bottomBar.height))pt of the window (ink \(ink)) — Start is unreachable with 60 collections")
    }

    /// …and in a narrow window too (a split Mac window / a small pane).
    func testStartBarPaintsInANarrowWindow() async throws {
        let size = CGSize(width: 520, height: 640)
        let rep = try await renderSetup(size: size, collectionCount: 12)
        let bottomBar = CGRect(x: 0, y: size.height - 74, width: size.width, height: 70)
        let ink = inkFraction(rep, bottomBar, size: size)
        XCTAssertGreaterThan(ink, 0.05,
            "no Start bar painted at the bottom of the narrow \(size) window (ink \(ink))")
    }
}
#endif
