import SwiftUI

/// Detail card for one detected chord (tapped on the Demuxer timeline): the triad rendered as
/// NOTATION (treble + bass clef staves, close-position voicings) or as a GUITAR shape (fretboard
/// diagram + tab string), toggled with a segmented picker. Pure value-in views — safe in a
/// popover on macOS/iPad and a sheet on iPhone.
struct DemuxChordDetailView: View {
    let chord: DemuxChordSegment
    @State private var form: Form = .notation

    enum Form: String, CaseIterable, Identifiable {
        case notation = "Notation", guitar = "Guitar"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(chord.name).font(.title2.weight(.bold)).foregroundStyle(Theme.fg)
                Text(chord.minor ? "minor" : "major").font(.caption).foregroundStyle(Theme.fgDim)
                Spacer()
                Text("\(StemAuditionPanel.clock(Double(chord.startMs) / 1_000))–\(StemAuditionPanel.clock(Double(chord.endMs) / 1_000))")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
            Picker("Form", selection: $form) {
                ForEach(Form.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("demux-chord-form")

            switch form {
            case .notation:
                HStack(spacing: 18) {
                    StaffChordView(clef: .treble, midiNotes: chord.midiNotes(base: 60))
                    StaffChordView(clef: .bass, midiNotes: chord.midiNotes(base: 48))
                }
                .frame(maxWidth: .infinity)
            case .guitar:
                VStack(spacing: 8) {
                    GuitarChordView(frets: chord.guitarFrets)
                    Text(chord.tabText)
                        .font(.callout.monospaced()).foregroundStyle(Theme.fg)
                        .accessibilityIdentifier("demux-chord-tab")
                    Text("low E → high e").font(.caption2).foregroundStyle(Theme.fgDim)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 260)
        .background(Theme.bgRaised)
    }
}

// MARK: - Staff rendering

/// A five-line staff with a clef and one close-position triad drawn as stacked note heads
/// (sharps drawn as ♯ to the head's left). Canvas-drawn — no engraving dependency; the
/// ScorePDF engraver is for full scores, this is a glanceable chord card.
struct StaffChordView: View {
    enum Clef { case treble, bass }
    let clef: Clef
    let midiNotes: [Int]

    private static let lineGap: CGFloat = 8
    private static let width: CGFloat = 120
    private static let height: CGFloat = 96

    var body: some View {
        Canvas { ctx, size in
            let gap = Self.lineGap
            let top = (size.height - 4 * gap) / 2
            let bottomY = top + 4 * gap
            let staffLeft: CGFloat = 6, staffRight = size.width - 6

            // Five staff lines.
            for i in 0..<5 {
                let y = top + CGFloat(i) * gap
                var p = Path()
                p.move(to: CGPoint(x: staffLeft, y: y))
                p.addLine(to: CGPoint(x: staffRight, y: y))
                ctx.stroke(p, with: .color(Theme.fgDim.opacity(0.8)), lineWidth: 1)
            }
            // Clef (unicode musical symbols render in the system font).
            let clefText = Text(clef == .treble ? "𝄞" : "𝄢")
                .font(.system(size: clef == .treble ? 40 : 30))
                .foregroundStyle(Theme.fg)
            ctx.draw(ctx.resolve(clefText),
                     at: CGPoint(x: staffLeft + 12, y: top + 2 * gap), anchor: .center)

            // Note heads, stacked at one x (close position); a second-interval collision
            // nudges the upper head right (the engraving convention, simplified).
            let noteX = size.width * 0.62
            /// Diatonic step index of the staff's BOTTOM LINE (treble: E4, bass: G2).
            let bottomStep = clef == .treble ? diatonicStep(64) : diatonicStep(43)
            // nil sentinel, NOT Int.min: `stepsUp - Int.min` overflows (Swift trap) for any
            // first note at/above the bottom line — the scrub-while-playing field crash
            // (build 1784413084, DemuxChordDetailView.swift:101 arithmetic overflow).
            var lastStepsUp: Int?
            for midi in midiNotes.sorted() {
                let (step, sharp) = pitch(midi)
                let stepsUp = step - bottomStep
                let y = bottomY - CGFloat(stepsUp) * gap / 2
                let collides = lastStepsUp.map { stepsUp - $0 == 1 } ?? false
                let x = collides ? noteX + 9 : noteX
                lastStepsUp = stepsUp

                // Ledger lines for heads below/above the staff (even steps sit ON a line).
                if stepsUp < 0 || stepsUp > 8 {
                    let range = stepsUp < 0 ? stride(from: -2, through: stepsUp, by: -2)
                                            : stride(from: 10, through: stepsUp, by: 2)
                    for s in range {
                        let ly = bottomY - CGFloat(s) * gap / 2
                        var p = Path()
                        p.move(to: CGPoint(x: x - 8, y: ly))
                        p.addLine(to: CGPoint(x: x + 8, y: ly))
                        ctx.stroke(p, with: .color(Theme.fgDim.opacity(0.8)), lineWidth: 1)
                    }
                }
                // The head (a slightly oblong filled ellipse) + its accidental.
                let head = Path(ellipseIn: CGRect(x: x - 5.5, y: y - 4, width: 11, height: 8))
                ctx.fill(head, with: .color(Theme.fg))
                if sharp {
                    ctx.draw(ctx.resolve(Text("♯").font(.system(size: 12)).foregroundStyle(Theme.fg)),
                             at: CGPoint(x: x - 14, y: y), anchor: .center)
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityLabel("\(clef == .treble ? "Treble" : "Bass") clef chord")
    }

    /// MIDI note → (diatonic step index, needs-sharp). Black keys spell as sharps of the letter
    /// below (C♯, D♯, F♯, G♯, A♯ — matching `DemuxChordSegment.noteNames`' flat-free majors).
    private func pitch(_ midi: Int) -> (step: Int, sharp: Bool) {
        let letterOfPC = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]   // C C♯ D D♯ E F F♯ G G♯ A A♯ B
        let sharpPC: Set<Int> = [1, 3, 6, 8, 10]
        let pc = ((midi % 12) + 12) % 12
        let octave = midi / 12 - 1
        return (octave * 7 + letterOfPC[pc], sharpPC.contains(pc))
    }

    private func diatonicStep(_ midi: Int) -> Int { pitch(midi).step }
}

// MARK: - Guitar diagram

/// A standard vertical chord box: 6 strings × a 5-fret window, dots on fretted strings, a thick
/// nut when the window starts at the nut, otherwise a "Nfr" position label.
struct GuitarChordView: View {
    /// Frets low-E → high-e; nil = muted (an "x" above the string).
    let frets: [Int?]

    var body: some View {
        let fretted = frets.compactMap { $0 }.filter { $0 > 0 }
        let base = (fretted.min() ?? 1) <= 1 ? 1 : fretted.min()!
        Canvas { ctx, size in
            let left: CGFloat = 18, right = size.width - 8
            let top: CGFloat = 16, bottom = size.height - 8
            let stringGap = (right - left) / 5
            let fretGap = (bottom - top) / 5

            // Nut / top line.
            var nut = Path()
            nut.move(to: CGPoint(x: left, y: top))
            nut.addLine(to: CGPoint(x: right, y: top))
            ctx.stroke(nut, with: .color(Theme.fg), lineWidth: base == 1 ? 4 : 1)
            if base > 1 {
                ctx.draw(ctx.resolve(Text("\(base)fr").font(.caption2).foregroundStyle(Theme.fgDim)),
                         at: CGPoint(x: left - 10, y: top + fretGap / 2), anchor: .center)
            }
            // Grid.
            for s in 0..<6 {
                let x = left + CGFloat(s) * stringGap
                var p = Path()
                p.move(to: CGPoint(x: x, y: top))
                p.addLine(to: CGPoint(x: x, y: bottom))
                ctx.stroke(p, with: .color(Theme.fgDim.opacity(0.8)), lineWidth: 1)
            }
            for f in 1...5 {
                let y = top + CGFloat(f) * fretGap
                var p = Path()
                p.move(to: CGPoint(x: left, y: y))
                p.addLine(to: CGPoint(x: right, y: y))
                ctx.stroke(p, with: .color(Theme.fgDim.opacity(0.8)), lineWidth: 1)
            }
            // Dots + open/muted markers.
            for (s, fret) in frets.enumerated() {
                let x = left + CGFloat(s) * stringGap
                guard let fret else {
                    ctx.draw(ctx.resolve(Text("×").font(.caption).foregroundStyle(Theme.fgDim)),
                             at: CGPoint(x: x, y: top - 8), anchor: .center)
                    continue
                }
                if fret == 0 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - 3.5, y: top - 12, width: 7, height: 7)),
                               with: .color(Theme.fg), lineWidth: 1)
                } else {
                    let row = fret - base   // 0-based row inside the window
                    guard row >= 0, row < 5 else { continue }
                    let y = top + (CGFloat(row) + 0.5) * fretGap
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)),
                             with: .color(Theme.accent))
                }
            }
        }
        .frame(width: 130, height: 120)
        .accessibilityLabel("Guitar chord diagram")
    }
}
