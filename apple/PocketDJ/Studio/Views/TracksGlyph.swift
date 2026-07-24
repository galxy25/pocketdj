import SwiftUI

/// A **monochrome, template-tinted** rendering of the Tracks mark — the four gapped bars as one
/// fillable silhouette. The full-colour `TracksIcon` Canvas can't live in the `.segmented` sub-tab
/// Picker (it template-tints its images), but this silhouette CAN: rasterized once via `ImageRenderer`
/// and rendered `.template`, it tints with the segment like an SF Symbol while still reading as
/// multitrack lanes — unlike `rectangle.stack`, which collides with the Pockets glyph.
struct TracksGlyphShape: Shape {
    /// Same bar geometry as `TracksIcon` — (start, width) fractions per row; the empty spans are the
    /// "gaps" (silence) that make the mark evocative of tracks.
    static let bars: [[(CGFloat, CGFloat)]] = [
        [(0.00, 0.28), (0.34, 0.40), (0.80, 0.20)],
        [(0.00, 0.46), (0.56, 0.44)],
        [(0.12, 0.22), (0.40, 0.18), (0.66, 0.34)],
        [(0.06, 0.34), (0.50, 0.50)],
    ]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let rows = Self.bars.count
        let gap = rect.height * 0.16
        let barH = (rect.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let radius = min(barH * 0.4, rect.width * 0.06)
        for (i, segs) in Self.bars.enumerated() {
            let y = rect.minY + (barH + gap) * CGFloat(i)
            for s in segs {
                let r = CGRect(x: rect.minX + s.0 * rect.width, y: y,
                               width: max(1, s.1 * rect.width), height: barH)
                p.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius))
            }
        }
        return p
    }
}

@MainActor
enum TracksGlyph {
    private static var cached: Image?

    /// A `.template` Image of the gapped-bars silhouette for the segmented sub-tab Picker (rendered
    /// once, then cached). Falls back to `rectangle.stack` only if rasterization ever fails.
    static func templateImage() -> Image {
        if let cached { return cached }
        let renderer = ImageRenderer(content: TracksGlyphShape().fill(Color.black).frame(width: 24, height: 18))
        renderer.scale = 3
        let image: Image
        #if os(macOS)
        if let ns = renderer.nsImage {
            ns.isTemplate = true
            image = Image(nsImage: ns)
        } else {
            image = Image(systemName: "rectangle.stack")
        }
        #else
        if let ui = renderer.uiImage {
            image = Image(uiImage: ui).renderingMode(.template)
        } else {
            image = Image(systemName: "rectangle.stack")
        }
        #endif
        cached = image
        return image
    }
}
