import XCTest
import SwiftUI
@testable import PocketDJ

/// Levi 2026-11-03: the Now Playing Mix panel's status chip was CUT OFF on an iPhone, and the
/// FX Lock status line cost a row of height. The chip now sits centered inline when its one
/// line fits (no added height) and otherwise drops to its own centered line, wrapping to 2 —
/// never truncated. The FX Lock's held / paused words moved into the lock's VoiceOver value.
final class NPMixStatusChipLayoutTests: XCTestCase {

    /// Every chip text that can appear, with the rule-A edition note on the longest ones.
    private static let longest: [(NPMixMode.Indicator, String?)] = [
        (.readyFromAppleMusic, "Clean edition"),
        (.rippingEdition("explicit"), "Clean edition"),
        (.ripping, nil),
        (.suspended, nil),
        (.unavailable("Apple Music only"), nil),
        (.unavailable("Device mode — downloads only"), nil),
        (.unavailable("Cellular — buffering off"), nil),
        (.buffering(0.42), "Explicit edition"),
    ]

    func testChipContentIsNilOnlyWhenModeOff() {
        XCTAssertNil(MixModeChipLabel.Content(indicator: .off, note: nil))
        let c = MixModeChipLabel.Content(indicator: .suspended, note: "Clean edition")
        XCTAssertEqual(c?.text, "Paused — Mix tab is live")
        XCTAssertEqual(c?.spoken, "Paused — Mix tab is live · Clean edition")
        XCTAssertEqual(MixModeChipLabel.Content(indicator: .ready, note: nil)?.spoken, "Ready")
    }

    func testFXLockHeldStatesCarryTheirWordsForVoiceOver() {
        XCTAssertTrue(FXLock.Indicator.waiting.isHeld)
        XCTAssertTrue(FXLock.Indicator.dormant.isHeld)
        for i in [FXLock.Indicator.off, .idle, .applied] {
            XCTAssertFalse(i.isHeld)
            XCTAssertNil(i.statusText(mixable: true))
            XCTAssertNil(i.statusText(mixable: false))
        }
        XCTAssertEqual(FXLock.Indicator.waiting.statusText(mixable: false),
                       "effects can't apply to this track — kept for the next")
        XCTAssertEqual(FXLock.Indicator.waiting.statusText(mixable: true), "tap a control to apply")
        XCTAssertEqual(FXLock.Indicator.dormant.statusText(mixable: false), "paused while the Mix tab plays")
    }

    #if os(iOS)
    /// A stand-in header with the real toggle / switch footprint ("› ≡ Mix" · "Mix Mode" capsule).
    @MainActor private func header(_ chip: MixModeChipLabel.Content?) -> some View {
        MixPanelHeaderLayout(chip: chip) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption2)
                Image(systemName: "slider.horizontal.3").font(.caption)
                Text("Mix").font(.caption.weight(.semibold))
            }
        } modeSwitch: {
            HStack(spacing: 4) { Image(systemName: "waveform.badge.plus"); Text("Mix Mode") }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
        }
    }

    @MainActor private func height(_ chip: MixModeChipLabel.Content?, width: CGFloat,
                                   size: DynamicTypeSize) -> CGFloat {
        let host = UIHostingController(rootView: header(chip).dynamicTypeSize(size))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// Short chips add NO height (inline); long ones take their own line and at most 2 lines,
    /// at iPhone SE (375 pt) and iPhone 17 Pro (402 pt) panel widths, default + one size larger.
    @MainActor func testChipNeverAddsHeightWhenShortAndWrapsToAtMostTwoLines() {
        for screen in [CGFloat(375), 402] {
            let width = screen - 2 * 12 - 2 * 12     // deck gutter + the panel's own padding
            for size in [DynamicTypeSize.large, .xLarge] {
                let bare = height(nil, width: width, size: size)
                XCTAssertEqual(height(MixModeChipLabel.Content(indicator: .ready, note: nil), width: width, size: size),
                               bare, accuracy: 0.5, "\"Ready\" rides inline — no added height (\(screen) pt, \(size))")
                XCTAssertEqual(height(MixModeChipLabel.Content(indicator: .buffering(0.42), note: nil), width: width, size: size),
                               bare, accuracy: 0.5, "\"Buffering 42%\" rides inline (\(screen) pt, \(size))")

                let line = UIFont.preferredFont(forTextStyle: .caption2,
                                                compatibleWith: UITraitCollection(preferredContentSizeCategory:
                                                    size == .large ? .large : .extraLarge))
                for (ind, note) in Self.longest {
                    let c = MixModeChipLabel.Content(indicator: ind, note: note)!
                    // The text fits in two lines of the chip's width without scaling below 0.8.
                    let textWidth = (c.spoken as NSString).size(withAttributes: [.font: line]).width
                    XCTAssertLessThanOrEqual(textWidth * 0.8, 2 * (width - 20),
                                             "\"\(c.spoken)\" can't fit 2 lines at \(screen) pt")
                    let h = height(c, width: width, size: size)
                    XCTAssertLessThan(h, bare + 3 + 2.5 * line.lineHeight,   // 3 lines would be ≥ 3 × lineHeight
                                             "\"\(c.spoken)\" took more than 2 lines (\(screen) pt, \(size))")
                }
            }
        }
    }
    #endif
}
