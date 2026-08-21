import Foundation
import CoreGraphics

// ============================================================================
// MARK: - Now Playing resize math (req 7)
// ============================================================================

/// Pure geometry for the RESIZABLE Now Playing surface: clamping a dragged size,
/// deciding docked vs expanded, snapping the iPhone-portrait sheet, and the
/// platter-centering arithmetic (`platterSide`/`flankLength`). Everything here is
/// nonisolated + value-in/value-out so the drag behavior is unit-tested without a
/// view; RootView owns the gestures and the two persisted fractions.
enum NowPlayingResize {
    /// Dragging past the dock edge by this many points commits to EXPANDED on
    /// release; anything less springs back to the docked panel.
    static let dockThreshold: CGFloat = 40
    /// iPhone-portrait snap points, as fractions of the window height:
    /// 0 = docked (the overlay dismisses), half sheet, full screen.
    static let portraitSnaps: [CGFloat] = [0, 0.5, 1]
    /// A release faster than this (pt/s) is a FLING: the sheet snaps one step in
    /// the fling's direction instead of to the nearest point.
    static let flingVelocity: CGFloat = 300

    /// Persisted expanded-width fraction (of the window width) for the horizontal
    /// lane — iPhone landscape, iPad, macOS, visionOS. 0 = docked. Separate
    /// defaults domains per OS make this per-platform persistence for free.
    static let wideFractionKey = "npPanelWideFraction"
    /// Persisted iPhone-portrait sheet fraction (of the window height); always one
    /// of `portraitSnaps`. 0 = docked.
    static let portraitFractionKey = "npPortraitFraction"

    /// A dragged size, kept between the docked size and the window edge.
    nonisolated static func clampedSize(_ proposed: CGFloat, window: CGFloat,
                                        dock: CGFloat) -> CGFloat {
        min(max(proposed, dock), max(dock, window))
    }

    /// Released past the dock edge by more than the threshold ⇒ the drag meant it.
    nonisolated static func isExpanded(size: CGFloat, dock: CGFloat) -> Bool {
        size > dock + dockThreshold
    }

    /// Snap a released portrait fraction: nearest of `portraitSnaps`, unless the
    /// release was a FLING — then the next snap in the fling's direction (up =
    /// toward full, down = toward docked), regardless of which is nearest.
    nonisolated static func snappedPortraitFraction(_ f: CGFloat,
                                                    velocity: CGFloat) -> CGFloat {
        let f = min(max(f, 0), 1)
        if velocity > flingVelocity {
            return portraitSnaps.first(where: { $0 >= f }) ?? 1
        }
        if velocity < -flingVelocity {
            return portraitSnaps.last(where: { $0 <= f }) ?? 0
        }
        return portraitSnaps.min(by: { abs($0 - f) < abs($1 - f) }) ?? 0
    }

    /// The platter's diameter for a panel of `size` — proportional to the short
    /// edge so the record reads as the centerpiece at every shape, clamped so a
    /// slim overlay never shrinks it below the docked size class and a wall-sized
    /// window never inflates it past legibility.
    nonisolated static func platterSide(in size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * 0.42, 150), 440)
    }

    /// Length of EACH flank beside/around the deck cluster. Equal flanks are what
    /// keep the platter dead-center: 2·flank + deck == panel (when it fits).
    nonisolated static func flankLength(panel: CGFloat, deck: CGFloat) -> CGFloat {
        max(0, (panel - deck) / 2)
    }

    /// Wide vs tall layout for the expanded surface: side flanks when the panel is
    /// desktop-wide or clearly landscape, top/bottom bands otherwise.
    nonisolated static func isWideShape(_ size: CGSize) -> Bool {
        size.width >= 640 || size.width > 1.4 * size.height
    }
}
