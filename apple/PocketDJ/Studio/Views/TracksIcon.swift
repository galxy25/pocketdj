import SwiftUI

/// The Producer ▸ Tracks identity glyph: four horizontal bars in the stem palette
/// (drums·yellow, bass·red, other·green, vocals·purple), each broken into discontinuous segments —
/// the "gaps" are silence (parts where a stem isn't sounding: the singer between lines, the piano
/// paused). A `.segmented` Picker template-tints its images, so a multicolour Canvas glyph can't
/// live in the tiny segment; this is the tab's header + empty-state mark instead. Pattern-matches
/// the sidebar Canvas glyphs (`DiamondIcon`/`JukeboxGlyph`) — normalized fills, no external assets.
struct TracksIcon: View {
    /// Per-bar colour + its sounding segments, as (start, width) fractions of the full width [0,1].
    /// Deliberately uneven so the mark reads as real, gapped multitrack content.
    private static let bars: [(color: Color, segments: [(CGFloat, CGFloat)])] = [
        (.yellow, [(0.00, 0.28), (0.34, 0.40), (0.80, 0.20)]),   // drums
        (.red,    [(0.00, 0.46), (0.56, 0.44)]),                 // bass
        (.green,  [(0.12, 0.22), (0.40, 0.18), (0.66, 0.34)]),   // other
        (.purple, [(0.06, 0.34), (0.50, 0.50)]),                 // vocals
    ]

    var body: some View {
        Canvas { ctx, size in
            let rows = Self.bars.count
            let gap = size.height * 0.14                                   // vertical gap between bars
            let barH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let radius = min(barH * 0.35, size.width * 0.05)
            for (i, bar) in Self.bars.enumerated() {
                let y = (barH + gap) * CGFloat(i)
                for seg in bar.segments {
                    let rect = CGRect(x: seg.0 * size.width, y: y,
                                      width: max(1, seg.1 * size.width), height: barH)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(bar.color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
