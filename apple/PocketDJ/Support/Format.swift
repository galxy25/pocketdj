import SwiftUI

enum Fmt {
    /// Milliseconds → "m:ss".
    static func duration(_ ms: Int?) -> String {
        guard let ms, ms > 0 else { return "–" }
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Milliseconds → a compact runtime SUMMARY: "1d 3h" (≥ a day), "2h 25m" (≥ an hour),
    /// else "25m" (and "–" for nil/zero). For COLLECTION / setlist TOTALS, which read as an
    /// unwieldy pure-minute count via `duration` ("145:23") — per-track lengths keep `m:ss`.
    static func longDuration(_ ms: Int?) -> String {
        guard let ms, ms > 0 else { return "–" }
        let totalMinutes = ms / 60_000
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func bpm(_ value: Double?) -> String {
        guard let value, value > 0 else { return "–" }
        return String(Int(value.rounded()))
    }

    /// Compact number: drop a trailing ".0" (240.0 → "240", 12.5 → "12.5").
    static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// Camelot-wheel model for harmonic mixing — mirrors `src/lib/camelot.ts`.
/// Code is "<num><A|B>": num 1–12 = wheel position, A = minor, B = major.
enum Camelot {
    /// All 24 codes in wheel order: 1A, 1B, 2A … 12B.
    static let keys: [String] = (1...12).flatMap { ["\($0)A", "\($0)B"] }

    /// Parse "<num><A|B>" → (num, isMajor).
    static func parse(_ code: String?) -> (num: Int, major: Bool)? {
        guard let code else { return nil }
        let t = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = t.last, last == "A" || last == "B" else { return nil }
        guard let n = Int(t.dropLast()), (1...12).contains(n) else { return nil }
        return (n, last == "B")
    }

    /// Comparable rank (A=even, B=odd, contiguous) → numeric compare yields wheel order.
    static func rank(_ code: String?) -> Int? {
        guard let p = parse(code) else { return nil }
        return p.num * 2 + (p.major ? 1 : 0)
    }

    /// 12 hues around the circle; B (major) brighter, A (minor) deeper.
    /// HSL(hue, 68%, major ? 50% : 38%) from the PWA, converted to SwiftUI HSB.
    static func color(_ code: String?) -> Color {
        guard let p = parse(code) else { return Theme.fgDim }
        let hue = Double(p.num - 1) / 12.0
        let l = p.major ? 0.50 : 0.38, s = 0.68
        let v = l + s * min(l, 1 - l)
        let sb = v == 0 ? 0 : 2 * (1 - l / v)
        return Color(hue: hue, saturation: sb, brightness: v)
    }
}
