import Foundation
import CoreGraphics
import CoreText

// MARK: - Score layout + rendering (spec §7)
//
// Three layers, split so the SwiftUI ScoreView (a later stage) and the PDF export draw the SAME
// score from ONE implementation:
//
//   • `ScoreLayout` — PURE geometry: paginates a `ScoreDocument` into `ScorePage`s of positioned
//     `ScoreGlyph` primitives (staff lines, clefs, heads, stems, flags, dots, sharps, ledger
//     lines, rests, barlines, header text). No drawing, no CGContext — unit-testable positions.
//   • `ScoreRenderer` — draws one laid page into a CGContext whose coordinates are TOP-LEFT
//     origin / y-down (the SwiftUI Canvas convention): ScoreView calls it inside
//     `GraphicsContext.withCGContext`, and ScorePDF flips the (bottom-left, y-up) PDF context to
//     match before calling — one renderer, two hosts, zero drift between screen and export.
//   • `ScorePDF.makePDF` — vector CGContext PDF pagination (spec §7: vector, not rasters).
//
// GLYPH CHOICE (spec §7 asked for the more reliable option, documented): clefs/rests/accidentals
// are drawn as simple VECTOR PATHS, not font glyphs ('𝄞' U+1D11E etc.). The musical-symbol
// codepoints live in fallback fonts (Apple Symbols / STIX) whose presence and metrics differ
// between iOS and macOS, and a bare CGContext PDF has no UIKit/AppKit font-cascade machinery —
// a missing glyph silently prints a .notdef box INTO THE EXPORTED FILE. Vector paths render
// identically on both platforms, embed nothing, and keep the shared renderer geometry-only.
// They are stylized simplifications, not engravings — deliberate for v1.

// MARK: - Glyph vocabulary (what layout emits, what renderers draw)

/// One positioned drawable primitive. Everything is in page coordinates, top-left origin,
/// y-down. Kept small on purpose: a renderer (CG or Canvas-native) is a switch over ~8 shapes.
enum ScoreGlyph: Sendable {
    /// Any straight stroke — staff lines, barlines, stems, ledger lines, the grand-staff brace.
    case line(from: CGPoint, to: CGPoint, width: CGFloat)
    /// Note head ellipse; open (stroked) for half/whole, filled otherwise.
    case noteHead(center: CGPoint, rx: CGFloat, ry: CGFloat, filled: Bool)
    /// 1 (8th) or 2 (16th) flags hanging off a stem tip, curving toward the staff.
    case flags(tip: CGPoint, count: Int, stemUp: Bool, spacing: CGFloat)
    /// Augmentation dot (also the F-clef's two dots).
    case dot(center: CGPoint, radius: CGFloat)
    /// Sharp sign centered on its note head's y. The DERIVED spelling (no override) uses only this
    /// — black keys spell as the natural-below + ♯, matching `ScoreLayout.staffPosition`.
    case sharp(center: CGPoint, size: CGFloat)
    /// Flat sign centered on its note head's y — emitted only for a note whose spelling was
    /// OVERRIDDEN to `.flat` (score editing, spec §7). Never produced by the derived spelling.
    case flat(center: CGPoint, size: CGFloat)
    /// A rest. `center` = the staff's MIDDLE line at the item's x; the shape per duration is
    /// the renderer's (always the BASE duration — dotted rests get a separate `.dot` glyph).
    case rest(NoteDuration, center: CGPoint, spacing: CGFloat)
    /// Clef at the start of a staff: `x` = glyph center, `topLineY` = the staff's top line.
    case clef(StaffRole, x: CGFloat, topLineY: CGFloat, spacing: CGFloat)
    /// Header text; `at` = the text baseline's left end. The renderer picks the font (Helvetica
    /// — ships on both platforms) so layout stays font-metric-free.
    case text(String, at: CGPoint, size: CGFloat, bold: Bool)
}

/// One laid-out page: fixed size + its glyphs in z-order (staff furniture first, notes after).
struct ScorePage: Sendable {
    var size: CGSize
    var glyphs: [ScoreGlyph]
}

// MARK: - Layout engine (pure)

/// Paginates a `ScoreDocument` into positioned glyphs. All statics — geometry in, geometry out.
enum ScoreLayout {

    /// Tunable page/staff geometry. `.a4` is the export default; ScoreView passes its own
    /// (canvas-width) metrics and gets identical relative layout.
    struct Metrics: Sendable {
        /// A4 in PDF points (595.2 × 841.8 at 72 dpi) — spec §7's "A4-ish page".
        var pageSize = CGSize(width: 595.2, height: 841.8)
        var margin: CGFloat = 46
        /// Distance between adjacent staff LINES; every other measurement scales off it.
        var staffSpacing: CGFloat = 7
        /// ~4 measures per system (spec §7). The last system may hold fewer.
        var measuresPerSystem = 4
        /// Horizontal room reserved at a system's start for the clef(s).
        var clefZoneWidth: CGFloat = 34
        /// Vertical gap between systems (beyond each system's own ledger padding).
        var systemGap: CGFloat = 26
        /// Treble bottom line → bass top line inside a grand staff.
        var grandStaffGap: CGFloat = 42
        /// Vertical room for title + instrument/bpm subtitle on page 1.
        var headerHeight: CGFloat = 58
        /// Ledger-line headroom above/below each staff strip (3 spaces ≈ up to ~3 ledgers).
        var ledgerPad: CGFloat { staffSpacing * 3 }

        static let a4 = Metrics()
    }

    // MARK: Pure position helpers (unit-tested directly)

    /// An item's head-center x inside its measure: proportional to onset (16 slots across the
    /// measure's inner width). Strictly monotonic in `onset16ths` — the layout invariant the
    /// smoke test pins (items can never render out of reading order).
    nonisolated static func xPosition(onset16ths: Int, measureX: CGFloat,
                                      measureWidth: CGFloat) -> CGFloat {
        let pad: CGFloat = 10                       // keep heads off the barlines
        return measureX + pad + (measureWidth - 2 * pad) * CGFloat(onset16ths) / 16
    }

    /// Vertical staff position of a MIDI note on a clef: DIATONIC half-line steps above the
    /// staff's bottom line (bottom line = 0, first space = 1, …, top line = 8; negative =
    /// below). Black keys spell as the natural BELOW plus a sharp (C major + sharps — no key
    /// signatures in v1, spec §7 "sharps for black-key notes"). References: treble bottom line
    /// = E4 (diatonic 30), bass bottom line = G2 (diatonic 18).
    nonisolated static func staffPosition(midi: Int, clef: StaffRole)
        -> (position: Int, sharp: Bool) {
        // Per pitch-class: diatonic letter index (C=0 D=1 E=2 F=3 G=4 A=5 B=6) + sharp flag.
        let letter = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
        let sharps = [false, true, false, true, false, false, true, false, true, false, true, false]
        let pc = ((midi % 12) + 12) % 12
        let octave = midi / 12 - 1                  // MIDI 60 = C4
        let diatonic = octave * 7 + letter[pc]
        let reference = clef == .treble ? 30 : 18   // E4 / G2 (each clef's bottom line)
        return (diatonic - reference, sharps[pc])
    }

    /// The accidental glyph a note's spelling resolves to. `.natural` ⇒ nothing drawn (v1 has no
    /// key signatures, so a white-key note needs no ♮).
    enum RenderedAccidental: Sendable { case natural, sharp, flat }

    /// Staff position + accidental glyph, honouring an optional spelling OVERRIDE. Without one it
    /// derives C-major sharps (`staffPosition`). `.flat`/`.sharp` put the head on the natural staff
    /// line ABOVE/BELOW and draw the accidental — so E♭ reads as the E line + ♭, not the D♯ line.
    /// `.natural` on a black-key MIDI (an inconsistent override) falls back to the derived spelling.
    nonisolated static func spelledPosition(midi: Int, clef: StaffRole, accidental: Accidental?)
        -> (position: Int, accidental: RenderedAccidental) {
        switch accidental {
        case .flat:
            return (staffPosition(midi: midi + 1, clef: clef).position, .flat)
        case .sharp:
            return (staffPosition(midi: midi - 1, clef: clef).position, .sharp)
        case .natural, nil:
            let base = staffPosition(midi: midi, clef: clef)
            return (base.position, base.sharp ? .sharp : .natural)
        }
    }

    // MARK: Pagination

    /// Lay the whole score out into pages: header (page 1), then systems of up to
    /// `measuresPerSystem` measures, flowing onto new pages when a system won't fit. An empty
    /// score yields one header-only page (the export is still a valid, openable PDF).
    nonisolated static func paginate(score: ScoreDocument, title: String,
                                     instrument: InstrumentKey,
                                     metrics m: Metrics = .a4) -> [ScorePage] {
        let s = m.staffSpacing
        let stripH = 4 * s
        let plan = score.clefPlan
        // A system's full height: ledger headroom + staves (+ inter-staff gap when grand).
        let blockH = plan == .grandStaff
            ? m.ledgerPad + stripH + m.grandStaffGap + stripH + m.ledgerPad
            : m.ledgerPad + stripH + m.ledgerPad
        let left = m.margin
        let right = m.pageSize.width - m.margin

        var pages: [ScorePage] = []
        var glyphs: [ScoreGlyph] = []

        // Header — title + "Instrument — N BPM" (spec §7), first page only.
        let heading = title.trimmingCharacters(in: .whitespaces)
        glyphs.append(.text(heading.isEmpty ? "Untitled take" : heading,
                            at: CGPoint(x: left, y: m.margin + 14), size: 16, bold: true))
        let bpm = score.bpm == score.bpm.rounded()
            ? String(Int(score.bpm)) : String(format: "%.1f", score.bpm)
        glyphs.append(.text("\(instrument.displayName) — \(bpm) BPM",
                            at: CGPoint(x: left, y: m.margin + 32), size: 11, bold: false))
        var y = m.margin + m.headerHeight

        for start in stride(from: 0, to: score.measures.count, by: m.measuresPerSystem) {
            let chunk = Array(score.measures[start..<min(start + m.measuresPerSystem,
                                                         score.measures.count)])
            if y + blockH > m.pageSize.height - m.margin, !glyphs.isEmpty {
                pages.append(ScorePage(size: m.pageSize, glyphs: glyphs))
                glyphs = []
                y = m.margin
            }
            appendSystem(chunk, plan: plan, y: y, left: left, right: right, m: m, into: &glyphs)
            y += blockH + m.systemGap
        }
        pages.append(ScorePage(size: m.pageSize, glyphs: glyphs))
        return pages
    }

    // MARK: System / item layout

    /// One system: staff lines + clefs + barlines for `measures`, then every item's glyphs.
    private nonisolated static func appendSystem(_ measures: [ScoreMeasure], plan: ClefPlan,
                                                 y: CGFloat, left: CGFloat, right: CGFloat,
                                                 m: Metrics, into glyphs: inout [ScoreGlyph]) {
        let s = m.staffSpacing
        let stripH = 4 * s
        // Staff strips, top-first: (role, top-line y). The strip order matches `plan.staves`.
        var strips: [(role: StaffRole, top: CGFloat)] = []
        var stripTop = y + m.ledgerPad
        for role in plan.staves {
            strips.append((role, stripTop))
            stripTop += stripH + m.grandStaffGap
        }
        // Fixed measure width (right-aligned slack on a short last system keeps every measure
        // the same width — simpler and steadier to read than stretching the remainder).
        let measureWidth = (right - left - m.clefZoneWidth) / CGFloat(m.measuresPerSystem)
        let systemRight = left + m.clefZoneWidth + measureWidth * CGFloat(measures.count)

        for strip in strips {
            for i in 0..<5 {
                let ly = strip.top + CGFloat(i) * s
                glyphs.append(.line(from: CGPoint(x: left, y: ly),
                                    to: CGPoint(x: systemRight, y: ly), width: 0.8))
            }
            glyphs.append(.clef(strip.role, x: left + m.clefZoneWidth * 0.4,
                                topLineY: strip.top, spacing: s))
        }

        let sysTop = strips.first!.top
        let sysBottom = strips.last!.top + stripH
        if plan == .grandStaff {
            // Brace stand-in: a thick rule joining the staves (a curly brace is font territory —
            // see the header's glyph-choice note).
            glyphs.append(.line(from: CGPoint(x: left - 3, y: sysTop),
                                to: CGPoint(x: left - 3, y: sysBottom), width: 2.4))
        }
        // System-start barline + one at each measure's end, spanning ALL staves (standard
        // grand-staff barring).
        glyphs.append(.line(from: CGPoint(x: left, y: sysTop),
                            to: CGPoint(x: left, y: sysBottom), width: 1.1))
        for i in 0..<measures.count {
            let bx = left + m.clefZoneWidth + measureWidth * CGFloat(i + 1)
            glyphs.append(.line(from: CGPoint(x: bx, y: sysTop),
                                to: CGPoint(x: bx, y: sysBottom), width: 1.1))
        }

        for (i, measure) in measures.enumerated() {
            let mx = left + m.clefZoneWidth + measureWidth * CGFloat(i)
            for item in measure.items {
                let x = xPosition(onset16ths: item.onset16ths, measureX: mx,
                                  measureWidth: measureWidth)
                appendItem(item, plan: plan, strips: strips, x: x, spacing: s, into: &glyphs)
            }
        }
    }

    /// One item's glyphs. Rests draw ONCE on the topmost staff (single-voice model — mirroring
    /// the same rest onto the grand staff's bass staff would read as a second voice). A chord on
    /// a grand staff splits at middle C (`ClefPlan.staff(forNote:)`), each side getting its own
    /// stem/flags/dots.
    private nonisolated static func appendItem(_ item: ScoreItem, plan: ClefPlan,
                                               strips: [(role: StaffRole, top: CGFloat)],
                                               x: CGFloat, spacing s: CGFloat,
                                               into glyphs: inout [ScoreGlyph]) {
        switch item.kind {
        case .rest:
            let middle = strips[0].top + 2 * s
            glyphs.append(.rest(item.duration.base, center: CGPoint(x: x, y: middle), spacing: s))
            if item.duration.isDotted {
                glyphs.append(.dot(center: CGPoint(x: x + 1.5 * s, y: middle - s / 2),
                                   radius: 0.19 * s))
            }
        case .notes(let notes):
            for strip in strips {
                let mine = notes.filter { plan.staff(forNote: $0) == strip.role }
                guard !mine.isEmpty else { continue }
                appendChord(mine, spellings: item.spellings, clef: strip.role, top: strip.top, x: x,
                            duration: item.duration, spacing: s, into: &glyphs)
            }
        }
    }

    /// Heads + sharps + ledger lines + dots + one shared stem (+ flags) for the notes of one
    /// item that landed on one staff. v1 simplifications, on purpose: all heads share the
    /// chord's x (no second-interval offset), and dots sit beside every head.
    private nonisolated static func appendChord(_ notes: [Int], spellings: [Int: Accidental],
                                                clef: StaffRole, top: CGFloat,
                                                x: CGFloat, duration: NoteDuration,
                                                spacing s: CGFloat,
                                                into glyphs: inout [ScoreGlyph]) {
        let bottomLine = top + 4 * s
        let rx = 0.62 * s, ry = 0.45 * s
        var headYs: [CGFloat] = []
        var positions: [Int] = []
        var ledgers = Set<Int>()

        for note in notes.sorted() {
            let sp = spelledPosition(midi: note, clef: clef, accidental: spellings[note])
            let hy = bottomLine - CGFloat(sp.position) * s / 2
            positions.append(sp.position)
            headYs.append(hy)
            switch sp.accidental {
            case .sharp: glyphs.append(.sharp(center: CGPoint(x: x - 2.6 * rx, y: hy), size: s))
            case .flat:  glyphs.append(.flat(center: CGPoint(x: x - 2.6 * rx, y: hy), size: s))
            case .natural: break
            }
            glyphs.append(.noteHead(center: CGPoint(x: x, y: hy), rx: rx, ry: ry,
                                    filled: duration.filledHead))
            if duration.isDotted {
                // Dots live in SPACES: a head ON a line (even position) nudges its dot up half
                // a space; a head in a space keeps its own y.
                let dy = sp.position.isMultiple(of: 2) ? hy - s / 2 : hy
                glyphs.append(.dot(center: CGPoint(x: x + rx + 0.5 * s, y: dy), radius: 0.19 * s))
            }
            // Ledger lines: every even position from the staff outward through the head's.
            if sp.position <= -2 {
                for p in stride(from: -2, through: sp.position, by: -2) { ledgers.insert(p) }
            }
            if sp.position >= 10 {
                for p in stride(from: 10, through: sp.position, by: 2) { ledgers.insert(p) }
            }
        }

        for p in ledgers {
            let ly = bottomLine - CGFloat(p) * s / 2
            glyphs.append(.line(from: CGPoint(x: x - 1.7 * rx, y: ly),
                                to: CGPoint(x: x + 1.7 * rx, y: ly), width: 1.0))
        }

        if duration.hasStem {
            // Stem up when the chord sits below the middle line (position 4); the middle-line
            // convention (stem down) falls out of `avg < 4` being false at exactly 4.
            let avg = Double(positions.reduce(0, +)) / Double(positions.count)
            let up = avg < 4
            let stemLen = 3.4 * s
            let minY = headYs.min()!, maxY = headYs.max()!
            let sx = up ? x + rx - 0.4 : x - rx + 0.4   // attach to the head's edge
            let tip = CGPoint(x: sx, y: up ? minY - stemLen : maxY + stemLen)
            glyphs.append(.line(from: CGPoint(x: sx, y: up ? maxY : minY), to: tip, width: 1.1))
            if duration.flags > 0 {
                glyphs.append(.flags(tip: tip, count: duration.flags, stemUp: up, spacing: s))
            }
        }
    }
}

// MARK: - Renderer (CGContext, shared by PDF + Canvas)

/// Draws laid pages. The context's coordinates MUST be top-left origin / y-down (the SwiftUI
/// Canvas convention) — `ScorePDF` flips the PDF context to match, so both hosts feed the same
/// space and the score can never mirror or offset differently between screen and export.
enum ScoreRenderer {

    nonisolated static func draw(_ page: ScorePage, in ctx: CGContext) {
        ctx.saveGState()
        // Paper-white background in BOTH hosts, deliberately: notation is black-on-white by
        // design, a PDF viewed in a dark-mode viewer must not composite onto near-black, and
        // ScoreView showing the same white "sheet" keeps screen == export.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: page.size))
        let ink = CGColor(gray: 0, alpha: 1)
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
        ctx.setLineCap(.round)
        for glyph in page.glyphs { draw(glyph, in: ctx) }
        ctx.restoreGState()
    }

    private nonisolated static func draw(_ glyph: ScoreGlyph, in ctx: CGContext) {
        switch glyph {
        case .line(let from, let to, let width):
            ctx.setLineWidth(width)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case .noteHead(let center, let rx, let ry, let filled):
            let rect = CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry)
            if filled {
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setLineWidth(1.1)
                ctx.strokeEllipse(in: rect)
            }

        case .flags(let tip, let count, let stemUp, let s):
            // Each flag: a short curve off the stem, sweeping toward the staff; the 2nd flag
            // (16ths) repeats 0.7 spaces further down/up the stem.
            let dir: CGFloat = stemUp ? 1 : -1
            ctx.setLineWidth(1.6)
            for i in 0..<count {
                let start = CGPoint(x: tip.x, y: tip.y + dir * CGFloat(i) * 0.7 * s)
                ctx.move(to: start)
                ctx.addCurve(to: CGPoint(x: start.x + 1.0 * s, y: start.y + dir * 1.6 * s),
                             control1: CGPoint(x: start.x + 0.2 * s, y: start.y + dir * 0.5 * s),
                             control2: CGPoint(x: start.x + 0.9 * s, y: start.y + dir * 0.9 * s))
                ctx.strokePath()
            }

        case .dot(let center, let r):
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r,
                                       width: 2 * r, height: 2 * r))

        case .sharp(let c, let s):
            // Two verticals + two slightly-rising thick horizontals — the classic ♯ skeleton.
            ctx.setLineWidth(0.9)
            for dx in [-0.32 * s, 0.32 * s] {
                ctx.move(to: CGPoint(x: c.x + dx, y: c.y - 0.85 * s))
                ctx.addLine(to: CGPoint(x: c.x + dx, y: c.y + 0.85 * s))
                ctx.strokePath()
            }
            ctx.setLineWidth(1.5)
            for dy in [-0.27 * s, 0.27 * s] {
                ctx.move(to: CGPoint(x: c.x - 0.72 * s, y: c.y + dy + 0.15 * s))
                ctx.addLine(to: CGPoint(x: c.x + 0.72 * s, y: c.y + dy - 0.15 * s))
                ctx.strokePath()
            }

        case .flat(let c, let s):
            // A tall left ascender + a bowl curving out to the right and back — the ♭ skeleton.
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: c.x - 0.30 * s, y: c.y - 1.15 * s))
            ctx.addLine(to: CGPoint(x: c.x - 0.30 * s, y: c.y + 0.55 * s))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: c.x - 0.30 * s, y: c.y - 0.15 * s))
            ctx.addQuadCurve(to: CGPoint(x: c.x - 0.30 * s, y: c.y + 0.55 * s),
                             control: CGPoint(x: c.x + 0.60 * s, y: c.y + 0.05 * s))
            ctx.strokePath()

        case .rest(let duration, let c, let s):
            drawRest(duration, at: c, spacing: s, in: ctx)

        case .clef(let role, let x, let topLineY, let s):
            switch role {
            case .treble: drawTrebleClef(x: x, topLineY: topLineY, spacing: s, in: ctx)
            case .bass: drawBassClef(x: x, topLineY: topLineY, spacing: s, in: ctx)
            }

        case .text(let string, let at, let size, let bold):
            drawText(string, at: at, size: size, bold: bold, in: ctx)
        }
    }

    // MARK: Rests (vector approximations; `center` = the staff's middle line)

    private nonisolated static func drawRest(_ d: NoteDuration, at c: CGPoint, spacing s: CGFloat,
                                             in ctx: CGContext) {
        switch d {
        case .whole:
            // Hangs BELOW the 4th line (one space above middle) — the standard placement.
            ctx.fill(CGRect(x: c.x - 0.8 * s, y: c.y - s, width: 1.6 * s, height: 0.45 * s))
        case .half:
            // Sits ON the middle line.
            ctx.fill(CGRect(x: c.x - 0.8 * s, y: c.y - 0.45 * s, width: 1.6 * s, height: 0.45 * s))
        case .quarter:
            // The zigzag squiggle, simplified to three strokes + a hook.
            ctx.setLineWidth(1.8)
            ctx.move(to: CGPoint(x: c.x - 0.2 * s, y: c.y - 1.6 * s))
            ctx.addLine(to: CGPoint(x: c.x + 0.5 * s, y: c.y - 0.7 * s))
            ctx.addLine(to: CGPoint(x: c.x - 0.3 * s, y: c.y + 0.1 * s))
            ctx.addCurve(to: CGPoint(x: c.x + 0.4 * s, y: c.y + 1.3 * s),
                         control1: CGPoint(x: c.x - 0.5 * s, y: c.y + 0.7 * s),
                         control2: CGPoint(x: c.x + 0.6 * s, y: c.y + 0.9 * s))
            ctx.strokePath()
        case .eighth, .sixteenth:
            // Slash with one curl-dot per flag (two for the 16th).
            ctx.setLineWidth(1.4)
            let bottom = d == .sixteenth ? 1.4 * s : 1.0 * s
            ctx.move(to: CGPoint(x: c.x + 0.45 * s, y: c.y - 0.9 * s))
            ctx.addLine(to: CGPoint(x: c.x - 0.4 * s, y: c.y + bottom))
            ctx.strokePath()
            let r = 0.22 * s
            ctx.fillEllipse(in: CGRect(x: c.x - 0.15 * s - r, y: c.y - 0.55 * s - r,
                                       width: 2 * r, height: 2 * r))
            if d == .sixteenth {
                ctx.fillEllipse(in: CGRect(x: c.x - 0.38 * s - r, y: c.y + 0.15 * s - r,
                                           width: 2 * r, height: 2 * r))
            }
        default:
            // Dotted rests never reach the renderer (layout passes `.base` + a `.dot` glyph);
            // draw the base shape if a caller hands one in anyway.
            drawRest(d.base, at: c, spacing: s, in: ctx)
        }
    }

    // MARK: Clefs (stylized vector paths — see the file-header glyph-choice note)

    private nonisolated static func drawTrebleClef(x: CGFloat, topLineY t: CGFloat,
                                                   spacing s: CGFloat, in ctx: CGContext) {
        let g = t + 3 * s                            // the G line (2nd from bottom) it marks
        ctx.setLineWidth(1.4)
        // Spine: a gentle S from above the staff down past the bottom line.
        ctx.move(to: CGPoint(x: x + 0.3 * s, y: t - 1.6 * s))
        ctx.addCurve(to: CGPoint(x: x, y: g + 1.6 * s),
                     control1: CGPoint(x: x + 1.3 * s, y: t + 0.4 * s),
                     control2: CGPoint(x: x - 1.1 * s, y: t + 2.6 * s))
        ctx.strokePath()
        // The curl around the G line — the part that actually says "this line is G".
        ctx.strokeEllipse(in: CGRect(x: x - 0.75 * s, y: g - 0.75 * s,
                                     width: 1.5 * s, height: 1.5 * s))
        // Bottom ball terminating the spine.
        let r = 0.3 * s
        ctx.fillEllipse(in: CGRect(x: x - r, y: g + 1.6 * s - r, width: 2 * r, height: 2 * r))
    }

    private nonisolated static func drawBassClef(x: CGFloat, topLineY t: CGFloat,
                                                 spacing s: CGFloat, in ctx: CGContext) {
        let f = t + s                                // the F line (2nd from top) it marks
        // Head dot on the F line, then the swash arcing up over the top line and down.
        let hr = 0.35 * s
        ctx.fillEllipse(in: CGRect(x: x - 0.8 * s - hr, y: f - hr, width: 2 * hr, height: 2 * hr))
        ctx.setLineWidth(1.4)
        ctx.move(to: CGPoint(x: x - 0.8 * s, y: f - 0.1 * s))
        ctx.addCurve(to: CGPoint(x: x + 0.9 * s, y: f + 0.2 * s),
                     control1: CGPoint(x: x - 0.6 * s, y: t - 1.0 * s),
                     control2: CGPoint(x: x + 1.2 * s, y: t - 0.6 * s))
        ctx.addCurve(to: CGPoint(x: x - 0.2 * s, y: t + 3.6 * s),
                     control1: CGPoint(x: x + 0.7 * s, y: f + 1.4 * s),
                     control2: CGPoint(x: x + 0.4 * s, y: t + 3.0 * s))
        ctx.strokePath()
        // The two dots bracketing the F line.
        let dr = 0.22 * s
        for dy in [-0.4 * s, 0.4 * s] {
            ctx.fillEllipse(in: CGRect(x: x + 1.6 * s - dr, y: f + dy - dr,
                                       width: 2 * dr, height: 2 * dr))
        }
    }

    // MARK: Text (CoreText; Helvetica ships on both platforms)

    private nonisolated static func drawText(_ string: String, at: CGPoint, size: CGFloat,
                                             bold: Bool, in ctx: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString,
                                        size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attrs))
        ctx.saveGState()
        // CoreText draws y-UP; our page space is y-DOWN — flip locally around the baseline so
        // the glyphs come out upright without disturbing the rest of the page transform.
        ctx.textMatrix = .identity
        ctx.translateBy(x: at.x, y: at.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

// MARK: - PDF export

/// Vector PDF of a score (spec §7): CGContext PDF pagination, one PDF page per laid page. Bytes
/// only — the `.fileExporter` wiring (`score-export-pdf`) lives with the Instruments UI.
enum ScorePDF {

    nonisolated static func makePDF(score: ScoreDocument, title: String,
                                    instrument: InstrumentKey) -> Data {
        let metrics = ScoreLayout.Metrics.a4
        let pages = ScoreLayout.paginate(score: score, title: title, instrument: instrument,
                                         metrics: metrics)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: metrics.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            // CG only fails here on resource exhaustion; empty Data lets the caller show a
            // plain "export failed" instead of writing a corrupt file.
            return Data()
        }
        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // PDF space is bottom-left/y-up; flip to the renderer's top-left/y-down contract
            // (identical to what SwiftUI Canvas hands `withCGContext`).
            ctx.translateBy(x: 0, y: mediaBox.height)
            ctx.scaleBy(x: 1, y: -1)
            ScoreRenderer.draw(page, in: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
