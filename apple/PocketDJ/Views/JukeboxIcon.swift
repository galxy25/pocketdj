import SwiftUI

/// The Jukebox Hero mark — a classic arched jukebox drawn in PRIDE colors (the
/// six-stripe rainbow), replacing the placeholder `qrcode` SF Symbol everywhere the
/// feature shows its face (sidebar row, create-screen hero, live-session header).
///
/// Behavior contract (Levi, 2026-07-18):
///   • no active jukebox session → STATIC icon (rainbow, but frozen)
///   • session active            → the colors CHANGE (randomly for now; the seam for
///                                 music-synced color is `JukeboxIconClock.rotation`)
///   • session active + playing  → the whole box PULSES on top of the color cycling
///
/// All the animation math lives in `JukeboxIconClock` as pure functions of wall-clock
/// time so it's unit-testable and, later, swappable for a beat-grid clock (the same
/// trick the Mix beat pulse pulled with `truePlayhead`).
enum JukeboxIconMode: Equatable {
    /// No session — frozen rainbow.
    case staticIcon
    /// Session up, nothing audible — colors wander.
    case colorCycle
    /// Session up + music playing — colors wander AND the box breathes.
    case pulse

    static func resolve(sessionActive: Bool, isPlaying: Bool) -> JukeboxIconMode {
        guard sessionActive else { return .staticIcon }
        return isPlaying ? .pulse : .colorCycle
    }

    var animatesColors: Bool { self != .staticIcon }
    var pulses: Bool { self == .pulse }
}

/// Pure animation math — deterministic per (time, step) so tests can pin it.
enum JukeboxIconClock {
    /// The six-stripe pride flag, tuned bright for the app's near-black background.
    static let pride: [Color] = [
        Color(hex: 0xff5d5d),  // red
        Color(hex: 0xff9d3b),  // orange
        Color(hex: 0xffe14d),  // yellow
        Color(hex: 0x4ddb7a),  // green
        Color(hex: 0x5da8ff),  // blue
        Color(hex: 0xc07dff),  // violet
    ]

    /// One color step every 0.6 s — fast enough to feel alive, slow enough to read.
    static let colorStepSeconds: TimeInterval = 0.6
    /// Breath period while playing ("for now"; the music-sync follow-up replaces this
    /// with the beat grid, like the Mix pulse).
    static let pulsePeriodSeconds: TimeInterval = 0.9
    /// Pulse amplitude: scale oscillates in [1, 1 + amplitude].
    static let pulseAmplitude: Double = 0.08

    static func colorStep(at t: TimeInterval) -> Int {
        Int(t / colorStepSeconds)
    }

    /// The "random for now" palette shuffle: a deterministic hash of the step picks how
    /// far the six stripes rotate, so consecutive steps jump unpredictably but every
    /// frame is reproducible (and testable). Splitmix64-style avalanche.
    static func rotation(step: Int, count: Int = pride.count) -> Int {
        guard count > 0 else { return 0 }
        var z = UInt64(bitPattern: Int64(step)) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Int(z % UInt64(count))
    }

    /// Region i's color at a given step (region indices are stable; the rotation slides
    /// the whole flag past them).
    static func color(region: Int, step: Int) -> Color {
        pride[(region + rotation(step: step)) % pride.count]
    }

    /// Scale factor while pulsing: 1 at phase 0, peaking at 1+amplitude, sinusoidal.
    static func pulseScale(at t: TimeInterval) -> Double {
        let phase = (t.truncatingRemainder(dividingBy: pulsePeriodSeconds)) / pulsePeriodSeconds
        return 1 + pulseAmplitude * (0.5 - 0.5 * cos(2 * .pi * phase))
    }
}

/// The jukebox glyph + its animation driver. Scales to any frame (drawn against a
/// 100×130 design grid). Decorative: hidden from accessibility wherever it appears
/// next to a text label.
struct JukeboxIcon: View {
    var mode: JukeboxIconMode = .staticIcon

    var body: some View {
        switch mode {
        case .staticIcon:
            glyph(step: 0, scale: 1)
        case .colorCycle:
            // Periodic at exactly the color cadence — no wasted frames.
            TimelineView(.periodic(from: .now, by: JukeboxIconClock.colorStepSeconds)) { ctx in
                glyph(step: JukeboxIconClock.colorStep(at: ctx.date.timeIntervalSince1970), scale: 1)
            }
        case .pulse:
            // Smooth breathing needs animation-rate frames.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSince1970
                glyph(step: JukeboxIconClock.colorStep(at: t),
                      scale: JukeboxIconClock.pulseScale(at: t))
            }
        }
    }

    private func glyph(step: Int, scale: Double) -> some View {
        JukeboxGlyph(colors: (0..<6).map { JukeboxIconClock.color(region: $0, step: step) })
            .scaleEffect(scale)
            .accessibilityHidden(true)
    }
}

/// The drawing itself: arch body, inner window with a spinning-record dot, two button
/// pills, the coin slot, and a slatted grille — each region takes one stripe color so
/// the whole flag is always on screen (regions 0…5).
private struct JukeboxGlyph: View {
    let colors: [Color]

    var body: some View {
        Canvas { context, size in
            // Fit the 100×130 design grid into the frame, centered.
            let s = min(size.width / 100, size.height / 130)
            let dx = (size.width - 100 * s) / 2
            let dy = (size.height - 130 * s) / 2
            context.translateBy(x: dx, y: dy)
            context.scaleBy(x: s, y: s)

            func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                    _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
            }

            // Body: full-height arch (top corners fully round, bottom slightly).
            var body = Path()
            body.move(to: CGPoint(x: 0, y: 124))
            body.addLine(to: CGPoint(x: 0, y: 50))
            body.addArc(center: CGPoint(x: 50, y: 50), radius: 50,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            body.addLine(to: CGPoint(x: 100, y: 124))
            body.addRoundedRect(in: CGRect(x: 0, y: 118, width: 100, height: 12),
                                cornerSize: CGSize(width: 4, height: 4))
            body.closeSubpath()
            context.fill(body, with: .color(Color(hex: 0x131a2b)))          // chassis
            context.stroke(body, with: .color(colors[0]), lineWidth: 5)     // neon rim

            // Inner arch window.
            var window = Path()
            window.move(to: CGPoint(x: 16, y: 62))
            window.addArc(center: CGPoint(x: 50, y: 62), radius: 34,
                          startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            window.closeSubpath()
            context.stroke(window, with: .color(colors[1]), lineWidth: 4)

            // The record: solid disc + punched hole, sitting in the window.
            let disc = Path(ellipseIn: CGRect(x: 36, y: 34, width: 28, height: 28))
            context.fill(disc, with: .color(colors[2]))
            let hole = Path(ellipseIn: CGRect(x: 45, y: 43, width: 10, height: 10))
            context.fill(hole, with: .color(Color(hex: 0x131a2b)))

            // Button pills row.
            context.fill(rr(18, 72, 26, 10, 5), with: .color(colors[3]))
            context.fill(rr(56, 72, 26, 10, 5), with: .color(colors[4]))

            // Coin slot.
            context.fill(rr(38, 88, 24, 6, 3), with: .color(colors[5]))

            // Grille: three vertical slats.
            for (i, x) in [24, 44, 64].enumerated() {
                context.fill(rr(CGFloat(x), 100, 12, 16, 4),
                             with: .color(colors[(i * 2) % colors.count].opacity(0.85)))
            }
        }
        .aspectRatio(100.0 / 130.0, contentMode: .fit)
    }
}
