import Foundation
import AppIntents

// PocketDJ 1.0.4 — Siri: add songs to collections by name, Now Playing Mix Mode, stems by voice,
// and one "play a collection" door for pockets + playlists alike. Thin adapters over
// `IntentServices+Siri` (all logic + tests live there). Every title, description and parameter
// description is written for Siri AI to read (iOS/macOS/visionOS 27.3: these become tools in
// `SiriAITools.swift`); on every other OS they work through App Shortcuts phrases, the Shortcuts
// app and Spotlight.

// MARK: - Add to collection

struct AddSongToCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Song to Collection"
    static let description = IntentDescription("""
        Adds a song from your PocketDJ sources to one of your pockets or playlists, found by name. \
        If the song is already in that collection, nothing changes.
        """)

    @Parameter(title: "Song",
               description: "The song to add, by title — optionally “by” the artist, e.g. “Make Me Proud by Drake”.",
               requestValueDialog: "Which song?")
    var song: SongEntity

    @Parameter(title: "Collection",
               description: "The pocket or playlist to add the song to, by name.",
               requestValueDialog: "Which pocket or playlist?")
    var collection: CollectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$song) to \(\.$collection)")
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = try await services.addSongToCollection(songId: song.id, collectionId: collection.id)
        return .result(dialog: "\(r.dialog)")
    }
}

struct AddCurrentSongToCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add This Song to Collection"
    static let description = IntentDescription("""
        Adds the song playing now in PocketDJ to one of your pockets or playlists. \
        If it's already there, nothing changes.
        """)

    @Parameter(title: "Collection",
               description: "The pocket or playlist to add the playing song to, by name.",
               requestValueDialog: "Which pocket or playlist?")
    var collection: CollectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Add the playing song to \(\.$collection)")
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = try await services.addSongToCollection(songId: nil, collectionId: collection.id)
        return .result(dialog: "\(r.dialog)")
    }
}

// MARK: - Play a collection (pocket or playlist)

struct PlayCollectionIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Collection"
    static let description = IntentDescription("Plays one of your PocketDJ pockets or playlists, from the top or shuffled.")

    @Parameter(title: "Collection",
               description: "The pocket or playlist to play, by name.",
               requestValueDialog: "Which pocket or playlist?")
    var collection: CollectionEntity
    @Parameter(title: "Shuffle", description: "Whether to shuffle the songs.", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$collection)") { \.$shuffle }
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await services.playCollection(id: collection.id, shuffle: shuffle)
        return .result(dialog: shuffle ? "Shuffling \(name)." : "Playing \(name).")
    }
}

struct ShuffleCollectionIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Collection"
    static let description = IntentDescription("Shuffles one of your PocketDJ pockets or playlists.")

    @Parameter(title: "Collection",
               description: "The pocket or playlist to shuffle, by name.",
               requestValueDialog: "Which pocket or playlist?")
    var collection: CollectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Shuffle \(\.$collection)")
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await services.playCollection(id: collection.id, shuffle: true)
        return .result(dialog: "Shuffling \(name).")
    }
}

// MARK: - Mix Mode + stems (Now Playing mini-mix)

struct SetMixModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Mix Mode"
    static let description = IntentDescription("""
        Turns Now Playing's Mix Mode on or off. With Mix Mode on, PocketDJ buffers the playing \
        song and the next ones on the device so stems, effects, tempo and pitch work on them.
        """)

    @Parameter(title: "Mix Mode", description: "On or off.", default: .on)
    var state: MixModeSwitch

    static var parameterSummary: some ParameterSummary {
        Summary("Turn Mix Mode \(\.$state)")
    }

    init() {}
    init(state: MixModeSwitch) { self.state = state }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = try services.setNowPlayingMixMode(state == .on)
        return .result(dialog: "\(said)")
    }
}

struct MuteStemIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Stem"
    static let description = IntentDescription("""
        Mutes one part of the song playing now — the vocals, drums, bass, or other instruments — \
        using its separated stems. Turns on Mix Mode first if it's off.
        """)

    @Parameter(title: "Stem",
               description: "The part to mute: vocals, drums, bass, or other (the remaining instruments).",
               requestValueDialog: "Which part — vocals, drums, bass, or other?")
    var stem: StemPart

    static var parameterSummary: some ParameterSummary {
        Summary("Mute \(\.$stem)")
    }

    init() {}
    init(stem: StemPart) { self.stem = stem }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = try services.setStem(stem, muted: true)
        return .result(dialog: "\(said)")
    }
}

struct UnmuteStemIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmute Stem"
    static let description = IntentDescription("""
        Brings back a muted part of the song playing now — the vocals, drums, bass, or other instruments.
        """)

    @Parameter(title: "Stem",
               description: "The part to unmute: vocals, drums, bass, or other (the remaining instruments).",
               requestValueDialog: "Which part — vocals, drums, bass, or other?")
    var stem: StemPart

    static var parameterSummary: some ParameterSummary {
        Summary("Unmute \(\.$stem)")
    }

    init() {}
    init(stem: StemPart) { self.stem = stem }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = try services.setStem(stem, muted: false)
        return .result(dialog: "\(said)")
    }
}
