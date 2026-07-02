import SwiftUI

/// Easter egg: "Reset all app state" is the app's nuclear option, so confirming it
/// detonates one — a stylized mushroom cloud rises from the bottom of the screen
/// (white-hot flash → fireball cap on a rising stem with a ground skirt → smoke
/// drift + fade), then removes itself. Pure decoration: hit-testing is disabled so
/// it never blocks the UI it's drawn over, and the whole thing lives ~2.5 s.
struct MushroomCloudView: View {
    /// Called once the cloud has fully faded (the host clears its `if` state).
    var onFinished: () -> Void = {}

    @State private var flash: Double = 0        // white-hot detonation flash opacity
    @State private var growth: CGFloat = 0.02   // stem height + cap scale, 0→1
    @State private var skirt: CGFloat = 0.1     // ground ring expansion, 0→1
    @State private var fade: Double = 1         // whole-cloud opacity at the end

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Detonation flash.
                RadialGradient(colors: [.white, Theme.accent2.opacity(0.9), .clear],
                               center: .bottom, startRadius: 0, endRadius: h)
                    .opacity(flash)

                // The cloud (bottom-center), scaling up as it "rises".
                ZStack {
                    // Ground skirt — the expanding base ring.
                    Ellipse()
                        .fill(Color(hex: 0xffa04d).opacity(0.55))
                        .frame(width: w * 0.75 * skirt, height: h * 0.07)
                        .position(x: w / 2, y: h * 0.93)
                        .blur(radius: 6)

                    // Stem — grows upward from the ground.
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0xff7a3c),
                                                      Color(hex: 0xffce6e),
                                                      Color(hex: 0x8a8fa3)],
                                             startPoint: .bottom, endPoint: .top))
                        .frame(width: w * 0.16, height: max(8, h * 0.5 * growth))
                        .position(x: w / 2, y: h * 0.93 - h * 0.25 * growth)
                        .blur(radius: 2)

                    // Cap — the fireball head: one core + two shoulders.
                    ZStack {
                        Circle().fill(fireball).frame(width: w * 0.30)
                            .offset(x: -w * 0.13, y: h * 0.02)
                        Circle().fill(fireball).frame(width: w * 0.30)
                            .offset(x: w * 0.13, y: h * 0.02)
                        Circle().fill(fireball).frame(width: w * 0.42)
                    }
                    .blur(radius: 3)
                    .scaleEffect(0.25 + 0.75 * growth, anchor: .bottom)
                    .position(x: w / 2, y: h * 0.93 - h * 0.52 * growth)
                }
                .opacity(fade)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityIdentifier("nuke-cloud")
        .task {
            // Detonate → rise → drift away. Timings staged by sleeps; every stage
            // is a plain withAnimation so an early teardown can't strand state.
            withAnimation(.easeOut(duration: 0.22)) { flash = 1 }
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) { flash = 0 }
            withAnimation(.easeOut(duration: 1.3)) { growth = 1 }
            withAnimation(.easeOut(duration: 1.0)) { skirt = 1 }
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            withAnimation(.easeIn(duration: 0.7)) { fade = 0 }
            try? await Task.sleep(nanoseconds: 750_000_000)
            onFinished()
        }
    }

    private var fireball: RadialGradient {
        RadialGradient(colors: [Color(hex: 0xfff3c4),
                                Color(hex: 0xffce6e),
                                Color(hex: 0xff7a3c),
                                Color(hex: 0x6b7089)],
                       center: .center, startRadius: 4, endRadius: 120)
    }
}
