import Foundation
import AppIntents

/// The ≤10 App Shortcuts (Apple's hard cap) — live for Siri/Spotlight/Action button
/// at INSTALL time, no Shortcuts-app setup. Every phrase must carry
/// `\(.applicationName)`; a phrase can interpolate at most ONE parameter, and only
/// entity/enum parameters whose values Siri pre-learns from `suggestedEntities()` —
/// which is why `PocketDJShortcuts.updateAppShortcutParameters()` is called at launch
/// and after every collections change (playlist/pocket renames re-teach Siri).
struct PocketDJShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPlaylistIntent(),
                    phrases: [
                        "Play \(\.$playlist) in \(.applicationName)",
                        "Play the playlist \(\.$playlist) in \(.applicationName)",
                        "Play a playlist in \(.applicationName)",
                    ],
                    shortTitle: "Play Playlist",
                    systemImageName: "play.circle")
        AppShortcut(intent: ShufflePlaylistIntent(),
                    phrases: [
                        "Shuffle \(\.$playlist) in \(.applicationName)",
                        "Shuffle the playlist \(\.$playlist) in \(.applicationName)",
                    ],
                    shortTitle: "Shuffle Playlist",
                    systemImageName: "shuffle.circle")
        AppShortcut(intent: PlayPocketIntent(),
                    phrases: [
                        "Play the pocket \(\.$pocket) in \(.applicationName)",
                        "Play \(\.$pocket) pocket in \(.applicationName)",
                        "Play a pocket in \(.applicationName)",
                    ],
                    shortTitle: "Play Pocket",
                    systemImageName: "play.square.stack")
        AppShortcut(intent: ShufflePocketIntent(),
                    phrases: [
                        "Shuffle the pocket \(\.$pocket) in \(.applicationName)",
                        "Shuffle \(\.$pocket) pocket in \(.applicationName)",
                    ],
                    shortTitle: "Shuffle Pocket",
                    systemImageName: "shuffle.circle.fill")
        AppShortcut(intent: StartAutoMixIntent(),
                    phrases: [
                        "Auto mix \(\.$source) in \(.applicationName)",
                        "Auto mix using \(\.$source) in \(.applicationName)",
                        "Start an auto mix in \(.applicationName)",
                        "Start a mix in \(.applicationName)",
                    ],
                    shortTitle: "Auto-Mix",
                    systemImageName: "slider.horizontal.3")
        AppShortcut(intent: PauseAutoMixIntent(),
                    phrases: [
                        "Pause the auto mix in \(.applicationName)",
                        "Pause the mix in \(.applicationName)",
                    ],
                    shortTitle: "Pause Auto-Mix",
                    systemImageName: "pause.circle")
        AppShortcut(intent: ResumeAutoMixIntent(),
                    phrases: [
                        "Resume the auto mix in \(.applicationName)",
                        "Resume the mix in \(.applicationName)",
                    ],
                    shortTitle: "Resume Auto-Mix",
                    systemImageName: "play.circle.fill")
        AppShortcut(intent: CreatePocketIntent(),
                    phrases: [
                        "Create a pocket in \(.applicationName)",
                        "Build me a pocket in \(.applicationName)",
                        "Make a pocket in \(.applicationName)",
                    ],
                    shortTitle: "Create Pocket",
                    systemImageName: "wand.and.stars")
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
