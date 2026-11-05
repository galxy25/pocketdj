import SwiftUI
import AppIntents

/// ONSCREEN CONTEXT for Siri / Apple Intelligence: while the Now Playing deck is visible, the
/// view's user activity names the playing song as a `SongEntity`, so "add this song to Workout"
/// resolves "this song" to the track on screen (Siri passes it as the intent's song parameter).
/// Without the activity the phrase still works — `AddCurrentSongToCollectionIntent` and a nil
/// song both fall back to `IntentServices.currentSongId()` — this just lets Siri AI see it too.
struct NowPlayingSiriContext: ViewModifier {
    static let activityType = "com.pocketdj.now-playing"

    @Environment(IntentServices.self) private var intents

    func body(content: Content) -> some View {
        let entity = intents.currentSongId().flatMap { intents.songEntity(id: $0) }
        content.userActivity(Self.activityType, isActive: entity != nil) { activity in
            guard let entity else { return }
            activity.title = "\(entity.title) — \(entity.artist)"
            if #available(iOS 18.2, macOS 15.2, tvOS 18.2, visionOS 2.2, *) {
                activity.appEntityIdentifier = EntityIdentifier(for: entity)
            }
        }
    }
}

extension View {
    /// Attach the Now Playing song as Siri's onscreen context (see `NowPlayingSiriContext`).
    func nowPlayingSiriContext() -> some View { modifier(NowPlayingSiriContext()) }
}
