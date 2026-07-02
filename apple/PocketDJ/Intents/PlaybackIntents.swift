import Foundation
import AppIntents

// ▶/🔀 playlist + pocket intents. All conform to `AudioPlaybackIntent`, so the system
// runs them IN THE APP PROCESS without foregrounding the UI (background app launch if
// needed) and suppresses spoken dialog that would talk over the music — playback then
// continues under the existing `audio` background mode.
//
// Play and Shuffle are SEPARATE intent types (not one intent with a bool) because a
// Siri phrase can carry only one parameter — "Shuffle <playlist> in PocketDJ" needs its
// own AppShortcut. Play intents still expose a Shuffle toggle for Shortcuts editing.

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays a PocketDJ playlist from the top (or shuffled).")

    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?")
    var playlist: PlaylistEntity
    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") { \.$shuffle }
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await services.playPlaylist(id: playlist.id, shuffle: shuffle)
        return .result(dialog: shuffle ? "Shuffling \(name)." : "Playing \(name).")
    }
}

struct ShufflePlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Playlist"
    static let description = IntentDescription("Shuffles a PocketDJ playlist.")

    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?")
    var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Shuffle \(\.$playlist)")
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await services.playPlaylist(id: playlist.id, shuffle: true)
        return .result(dialog: "Shuffling \(name).")
    }
}

struct PlayPocketIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Pocket"
    static let description = IntentDescription("Plays a PocketDJ pocket (its songs, albums, and nested pockets, in order).")

    @Parameter(title: "Pocket", requestValueDialog: "Which pocket?")
    var pocket: PocketEntity
    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$pocket)") { \.$shuffle }
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await services.playPocket(id: pocket.id, shuffle: shuffle)
        return .result(dialog: shuffle ? "Shuffling \(name)." : "Playing \(name).")
    }
}

struct ShufflePocketIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Pocket"
    static let description = IntentDescription("Shuffles a PocketDJ pocket.")

    @Parameter(title: "Pocket", requestValueDialog: "Which pocket?")
    var pocket: PocketEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Shuffle \(\.$pocket)")
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await services.playPocket(id: pocket.id, shuffle: true)
        return .result(dialog: "Shuffling \(name).")
    }
}

// MARK: - Open (Spotlight → app deep-link)

// Spotlight indexes PlaylistEntity/PocketEntity (see CollectionsSpotlight); an
// `OpenIntent` per indexed type is what makes tapping a result open the item in the
// app. These foreground the app and hand RootView a pending route.

struct OpenPlaylistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Playlist"
    static let description = IntentDescription("Opens a playlist in PocketDJ.")
    static let openAppWhenRun = true

    @Parameter(title: "Playlist")
    var target: PlaylistEntity

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult {
        services.pendingRoute = .playlist(target.id)
        return .result()
    }
}

struct OpenPocketIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Pocket"
    static let description = IntentDescription("Opens a pocket in PocketDJ.")
    static let openAppWhenRun = true

    @Parameter(title: "Pocket")
    var target: PocketEntity

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult {
        services.pendingRoute = .pocket(target.id)
        return .result()
    }
}
