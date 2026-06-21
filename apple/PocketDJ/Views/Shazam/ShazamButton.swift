import SwiftUI

/// The literal "?♪?" recognition button: two question-mark glyphs flanking a music
/// note, inside a `Capsule` whose tint + animation track the recognizer's phase.
/// Three separate glyphs (not one SF Symbol) so the marks can animate independently
/// of the note. References only `AppModel` (for the catalog snapshot) and an owned
/// `ShazamRecognizer` — zero coupling to native playback / streaming.
struct ShazamButton: View {
    @Environment(AppModel.self) private var app

    /// Owned recognizer; rebuilt nowhere — it reads `app.songs` lazily at match time
    /// via the autoclosure, so a later catalog load is still seen.
    @State private var recognizer: ShazamRecognizer?
    /// Drives the result sheet. Set when phase becomes `.matched`.
    @State private var presentedMatch: PresentedMatch?

    var body: some View {
        Button {
            tapped()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Identify the song playing")
        .accessibilityValue(accessibilityValue)
        .onChange(of: phase) { _, new in
            if case .matched(let m) = new { presentedMatch = PresentedMatch(match: m) }
        }
        .sheet(item: $presentedMatch, onDismiss: { recognizer?.reset() }) { pm in
            ShazamResultSheet(match: pm.match) { recognizer?.reset() }
        }
        .task { if recognizer == nil { recognizer = ShazamRecognizer(songs: app.songs) } }
    }

    // MARK: Phase

    private var phase: ShazamPhase { recognizer?.phase ?? .idle }

    private func tapped() {
        if recognizer == nil { recognizer = ShazamRecognizer(songs: app.songs) }
        switch phase {
        case .listening, .recognizing: recognizer?.stop()
        case .denied: openSettings()
        default: recognizer?.start()
        }
    }

    // MARK: Label

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark")
                .opacity(markOpacity)
            noteImage
            Image(systemName: "questionmark")
                .opacity(markOpacity)
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            ZStack {
                Capsule().fill(Theme.bgRaised)
                Capsule().stroke(tint.opacity(0.6), lineWidth: 1)
                if phase.isActive { sonarRing }
            }
        )
        .overlay(alignment: .trailing) {
            if case .recognizing = phase {
                ProgressView().controlSize(.mini).padding(.trailing, 4)
            }
        }
        .modifier(ShakeIfDenied(active: isDenied))
        .animation(.easeInOut(duration: 0.25), value: tint)
    }

    /// The center note morphs by phase (note → checkmark on match, mic.slash on
    /// denial, exclamation on failure) and carries the symbol animations.
    @ViewBuilder private var noteImage: some View {
        switch phase {
        case .idle, .noMatch:
            Image(systemName: "music.note")
        case .listening:
            Image(systemName: "music.note")
                .symbolEffect(.bounce, options: .repeating)
                .scaleEffect(notePulse)
        case .recognizing:
            Image(systemName: "music.note")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .matched:
            Image(systemName: "checkmark")
                .symbolEffect(.bounce, options: .nonRepeating)
        case .denied:
            Image(systemName: "mic.slash")
        case .failed:
            Image(systemName: "exclamationmark")
        }
    }

    // MARK: Phase-driven styling

    private var tint: Color {
        switch phase {
        case .idle, .noMatch:   return Theme.fgDim
        case .listening:        return Theme.accent
        case .recognizing:      return Theme.accent2
        case .matched:          return .green
        case .denied, .failed:  return Theme.danger
        }
    }

    private var markOpacity: Double {
        switch phase {
        case .listening:        return 0.55
        case .denied, .failed:  return 0.4
        default:                return 1.0
        }
    }

    private var isDenied: Bool { if case .denied = phase { return true }; return false }

    // Pulse + sonar are time-driven; `TimelineView` keeps them animating while
    // active without an explicit repeating animation that fights the symbol effect.
    private var notePulse: CGFloat { phase.isActive ? 1.0 : 1.0 }

    private var sonarRing: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phaseFraction = (t.truncatingRemainder(dividingBy: 1.2)) / 1.2
            Capsule()
                .stroke(tint.opacity(1 - phaseFraction), lineWidth: 2)
                .scaleEffect(1 + 0.25 * phaseFraction)
                .opacity(1 - phaseFraction)
        }
    }

    private var accessibilityValue: String {
        switch phase {
        case .idle:        return "Idle"
        case .listening:   return "Listening"
        case .recognizing: return "Identifying"
        case .matched:     return "Match found"
        case .noMatch:     return "No match"
        case .denied:      return "Microphone access denied"
        case .failed(let m): return m
        }
    }

    private func openSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

/// Identifiable wrapper so a `ShazamMatch` can drive `.sheet(item:)`.
private struct PresentedMatch: Identifiable {
    let id = UUID()
    let match: ShazamMatch
}

/// A small horizontal shake applied once when recognition is denied.
private struct ShakeIfDenied: ViewModifier {
    let active: Bool
    @State private var shake = false
    func body(content: Content) -> some View {
        content
            .offset(x: shake ? -6 : 0)
            .onChange(of: active) { _, now in
                guard now else { return }
                withAnimation(.spring(response: 0.15, dampingFraction: 0.2).repeatCount(3, autoreverses: true)) {
                    shake = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { shake = false }
            }
    }
}

#if canImport(UIKit)
import UIKit
#endif
