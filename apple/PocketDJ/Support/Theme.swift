import SwiftUI

/// Design tokens mirrored from the PWA (`src/styles/index.css`). Dark, "night-sky".
enum Theme {
    static let bg        = Color(hex: 0x0b0f1a)
    static let bgRaised  = Color(hex: 0x131a2b)
    static let bgOverlay = Color(hex: 0x1b2540)
    static let fg        = Color(hex: 0xe8ecf6)
    static let fgDim     = Color(hex: 0x97a2c0)
    static let accent    = Color(hex: 0x6ea8ff)   // blue
    static let accent2   = Color(hex: 0xffce6e)   // gold
    static let danger    = Color(hex: 0xff6e8a)
    static let border    = Color(hex: 0x283250)
    static let radius: CGFloat = 10
}

// MARK: - Dark text-field style

/// A dark, on-theme text-entry look so `TextField`/`SecureField` stop rendering as
/// the muddy light-gray macOS default. Renders a plain field (no system border),
/// `Theme.fg` text, an `accent` caret/tint, a `bgOverlay` fill, modest padding,
/// a small rounded rect, and a subtle `Theme.border` stroke. Reads correctly on
/// both macOS and iOS. Apply via `.pocketField()`.
struct PocketFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.fg)
            .tint(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.bgOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    /// Dark, on-theme styling for a native `TextField`/`SecureField`. See `PocketFieldModifier`.
    func pocketField() -> some View { modifier(PocketFieldModifier()) }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue:  Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Cross-platform image bridging

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension Image { init(platformImage: NSImage) { self.init(nsImage: platformImage) } }
#else
import UIKit
typealias PlatformImage = UIImage
extension Image { init(platformImage: UIImage) { self.init(uiImage: platformImage) } }
#endif
