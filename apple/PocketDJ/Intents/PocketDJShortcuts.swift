import Foundation
import AppIntents

/// The ≤10 App Shortcuts (Apple's hard cap) — live for Siri/Spotlight/Action button
/// at INSTALL time, no Shortcuts-app setup. Every phrase must carry
/// `\(.applicationName)`; a phrase can interpolate at most ONE parameter, and only
/// entity/enum parameters whose values Siri pre-learns from `suggestedEntities()` —
/// which is why `PocketDJShortcuts.updateAppShortcutParameters()` is called at launch
/// and after every collections change (playlist/pocket renames re-teach Siri).
///
/// SLOT BUDGET (1.0.4, all 10 used): add-to-collection gets TWO (the playing song; a named song,
/// which Siri then asks for — "Which song?"), Mix Mode one (on/off rides the phrase's one enum
/// parameter), stems two (mute / unmute; the stem rides the enum). To make room, Play/Shuffle
/// Playlist + Play/Shuffle Pocket became Play/Shuffle COLLECTION (one entity covers both kinds),
/// and Pause/Resume Auto-Mix left the list — Siri's own "pause" / "resume" already reach the mix
/// through the lock-screen remote commands (`MixEngine.remotePause/remotePlay`), and both intents
/// stay in the Shortcuts app and as Siri AI tools. Every older intent TYPE still exists, so a
/// shortcut someone saved keeps running.
struct PocketDJShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddCurrentSongToCollectionIntent(),
                    phrases: [
                        "Add this song to \(\.$collection) in \(.applicationName)",
                        "Add this to \(\.$collection) in \(.applicationName)",
                        "Add the song to \(\.$collection) in \(.applicationName)",
                        "Put this song in \(\.$collection) in \(.applicationName)",
                        "Save this song to \(\.$collection) in \(.applicationName)",
                        "Add this song to a collection in \(.applicationName)",
                    ],
                    shortTitle: "Add This Song",
                    systemImageName: "text.badge.plus")
        AppShortcut(intent: AddSongToCollectionIntent(),
                    phrases: [
                        "Add a song to \(\.$collection) in \(.applicationName)",
                        "Add a track to \(\.$collection) in \(.applicationName)",
                        "Add a song to a collection in \(.applicationName)",
                    ],
                    shortTitle: "Add a Song",
                    systemImageName: "music.note.list")
        AppShortcut(intent: PlayCollectionIntent(),
                    phrases: [
                        "Play \(\.$collection) in \(.applicationName)",
                        "Play the playlist \(\.$collection) in \(.applicationName)",
                        "Play the pocket \(\.$collection) in \(.applicationName)",
                        "Play \(\.$collection) pocket in \(.applicationName)",
                        "Play a playlist in \(.applicationName)",
                        "Play a pocket in \(.applicationName)",
                    ],
                    shortTitle: "Play Collection",
                    systemImageName: "play.circle")
        AppShortcut(intent: ShuffleCollectionIntent(),
                    phrases: [
                        "Shuffle \(\.$collection) in \(.applicationName)",
                        "Shuffle the playlist \(\.$collection) in \(.applicationName)",
                        "Shuffle the pocket \(\.$collection) in \(.applicationName)",
                        "Shuffle \(\.$collection) pocket in \(.applicationName)",
                    ],
                    shortTitle: "Shuffle Collection",
                    systemImageName: "shuffle.circle")
        AppShortcut(intent: PlayPocketForNowIntent(),
                    phrases: [
                        "Play my pocket in \(.applicationName)",
                        "Play the pocket for now in \(.applicationName)",
                        "Play something that fits in \(.applicationName)",
                    ],
                    shortTitle: "Play My Pocket",
                    systemImageName: "circle.circle")
        AppShortcut(intent: SetMixModeIntent(),
                    phrases: [
                        "Turn \(\.$state) Mix Mode in \(.applicationName)",
                        "Turn Mix Mode \(\.$state) in \(.applicationName)",
                        "Switch \(\.$state) Mix Mode in \(.applicationName)",
                        "Mix Mode \(\.$state) in \(.applicationName)",
                    ],
                    shortTitle: "Mix Mode",
                    systemImageName: "waveform.badge.plus")
        AppShortcut(intent: MuteStemIntent(),
                    phrases: [
                        "Mute the \(\.$stem) in \(.applicationName)",
                        "Mute \(\.$stem) in \(.applicationName)",
                        "Turn off the \(\.$stem) in \(.applicationName)",
                        "Kill the \(\.$stem) in \(.applicationName)",
                        "Drop the \(\.$stem) in \(.applicationName)",
                    ],
                    shortTitle: "Mute Stem",
                    systemImageName: "speaker.slash")
        AppShortcut(intent: UnmuteStemIntent(),
                    phrases: [
                        "Unmute the \(\.$stem) in \(.applicationName)",
                        "Unmute \(\.$stem) in \(.applicationName)",
                        "Turn on the \(\.$stem) in \(.applicationName)",
                        "Bring back the \(\.$stem) in \(.applicationName)",
                    ],
                    shortTitle: "Unmute Stem",
                    systemImageName: "speaker.wave.2")
        AppShortcut(intent: StartAutoMixIntent(),
                    phrases: [
                        "Auto mix \(\.$source) in \(.applicationName)",
                        "Auto mix using \(\.$source) in \(.applicationName)",
                        "Start an auto mix in \(.applicationName)",
                        "Start a mix in \(.applicationName)",
                    ],
                    shortTitle: "Auto-Mix",
                    systemImageName: "slider.horizontal.3")
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
