import SwiftUI

/// A Camelot key chip (coloured by wheel position) with the musical key beside it.
struct KeyChip: View {
    let key: String?
    let camelot: String?

    var body: some View {
        if let camelot, !camelot.isEmpty {
            HStack(spacing: 5) {
                Text(camelot)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Camelot.color(camelot).opacity(0.22), in: Capsule())
                    .overlay(Capsule().strokeBorder(Camelot.color(camelot), lineWidth: 1))
                    .foregroundStyle(Camelot.color(camelot))
                if let key { Text(shortKey(key)).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1) }
            }
            .accessibilityIdentifier("keychip-\(camelot)")
        } else {
            Text("–").foregroundStyle(Theme.fgDim)
        }
    }

    /// "F# major" → "F#", "A minor" → "Am".
    private func shortKey(_ k: String) -> String {
        k.replacingOccurrences(of: " major", with: "")
         .replacingOccurrences(of: " minor", with: "m")
    }
}
