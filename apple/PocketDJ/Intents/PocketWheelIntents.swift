import Foundation
import AppIntents

/// "Play my pocket" — the Pocket Wheel's centre ▶, hands-free (§2.1). Plays the pocket that best
/// matches now (time, day, CarPlay / motion, place, what you were just listening to).
struct PlayPocketForNowIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play My Pocket"
    static let description = IntentDescription("Plays the pocket that best fits right now: the time, the day, whether you're driving or moving, and what you've been listening to.")

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let caption = try await services.playPocketForNow()
        return .result(dialog: "Playing your pocket: \(caption).")
    }
}
