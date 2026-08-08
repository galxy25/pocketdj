import Foundation
import Observation
import AppIntents

/// A navigation request raised by an intent (e.g. a Spotlight "Open" action) for
/// RootView to consume: it switches to the Playlists section and pushes the item.
enum IntentRoute: Hashable {
    case playlist(String)
    case pocket(String)
    /// The Up Next collection button's extra targets (a running set's origin can be a
    /// frozen setlist, a catalog album/artist, or a read-only source playlist).
    case setlist(String)
    case album(String)
    case artist(String)
    case sourcePlaylist(String)
    /// Land on the Browser tab (the system.search intent parks the query separately
    /// on `pendingBrowseQuery` — BrowseView owns the search field's state).
    case browseSearch
}

/// The bridge App Intents use to reach the LIVE app-scoped stores/engines.
///
/// The app's state objects (AppModel, CollectionsStore, SetlistPlayer, MixEngine, …)
/// are `@State` on `PocketDJApp` and travel only through the SwiftUI environment —
/// but intents run OUTSIDE the view hierarchy (Siri/Shortcuts/Spotlight, possibly a
/// background app launch with no scene). `PocketDJApp.init()` therefore registers one
/// instance of this class with `AppDependencyManager`, and every intent/entity query
/// resolves it via `@Dependency`. All intent OPERATIONS live here (thin, testable);
/// the intent structs themselves are adapters.
///
/// `@MainActor` (all wrapped stores are main-actor); a global-actor-isolated class is
/// implicitly Sendable, which `@Dependency` requires. `@Observable` so it travels the
/// SwiftUI environment and RootView can watch `pendingRoute`.
@MainActor
@Observable
final class IntentServices {
    let app: AppModel
    let settings: SettingsStore
    let collections: CollectionsStore
    let setlistPlayer: SetlistPlayer
    let mix: MixEngine
    let burns: BurnStore
    let studio: StudioStore
    let rips: RipsStore
    /// Per-profile favorites (the ♥). The CarPlay scene runs OUTSIDE the SwiftUI environment
    /// (a separate `UIScene`), so it reaches the live store through this bridge — the same
    /// gateway CarPlay already uses for every other store. `CarPlayModel` toggles the current
    /// track's favorite here (its `onChanged` reaches Apple Music only for an owner install).
    let favorites: FavoritesStore
    /// Async "Create pocket" builder — kept observable so UI can surface progress later.
    let pocketBuilder: PocketBuilderService

    /// Pending intent-driven navigation (Open Playlist/Pocket). RootView observes and
    /// consumes it (it owns the NavigationPath); set-then-clear, never queued.
    var pendingRoute: IntentRoute?

    /// Pending in-app search term ("Search PocketDJ for …" — the system.search
    /// intent). BrowseView observes and consumes it into its search field; paired
    /// with `pendingRoute == .browseSearch`, which lands the user on the Browser.
    var pendingBrowseQuery: String?

    /// One-shot guard so `ensureReady()` kicks the rips-manifest refresh only once per
    /// process (RootView.task does the same on a windowed launch — both are idempotent).
    private var kickedManifestRefresh = false

    /// ONBOARDING VETO (R4): true while the zero-to-hero flow is unresolved. Siri/
    /// Shortcuts/CarPlay can cold-launch the app WITHOUT RootView (and its onboarding
    /// gate), and a playback intent writes the synced collections/session documents —
    /// which would break the fresh-install cloud-restore invariant. Mutating intents
    /// throw `.setupIncomplete` instead; wired in PocketDJApp to
    /// `{ !onboarding.isComplete }`. nil ⇒ never veto (tests).
    @ObservationIgnored var onboardingIncomplete: (() -> Bool)?

    private func vetoDuringOnboarding() throws {
        if onboardingIncomplete?() == true { throw PocketDJIntentError.setupIncomplete }
    }

    /// Process-wide handle to the live bridge, for scene delegates that run OUTSIDE the SwiftUI
    /// environment and can't receive `.environment`-injected stores — specifically the CarPlay
    /// scene (a separate `UIScene`). Set once in `init` (there is one instance, built in
    /// `PocketDJApp.init`); mirrors the `TransferCoordinator.shared` escape hatch. Must not
    /// construct its own stores — that would silently fork a second catalog/mix graph.
    @MainActor static private(set) var shared: IntentServices?

    init(app: AppModel, settings: SettingsStore, collections: CollectionsStore,
         setlistPlayer: SetlistPlayer, mix: MixEngine, burns: BurnStore, studio: StudioStore,
         rips: RipsStore, favorites: FavoritesStore) {
        self.app = app
        self.settings = settings
        self.collections = collections
        self.setlistPlayer = setlistPlayer
        self.mix = mix
        self.burns = burns
        self.studio = studio
        self.rips = rips
        self.favorites = favorites
        self.pocketBuilder = PocketBuilderService(app: app, collections: collections)
        Self.shared = self
    }

    /// Make the catalog usable before an intent acts. Store cross-wiring happens in
    /// `PocketDJApp.init()` (so even a background intent launch is wired); this awaits
    /// the offline-first catalog load (disk cache seeds synchronously — fast after the
    /// first ever launch) and fires the rips-manifest refresh once.
    func ensureReady() async {
        if !kickedManifestRefresh {
            kickedManifestRefresh = true
            Task { await rips.refreshManifest() }
        }
        await app.loadIfNeeded()
    }

    /// Rehydrate the durable playback session on a scene that never runs `RootView` — in practice
    /// the CarPlay scene, which is its own `UIScene` and so never reaches the launch task where
    /// `restorePersistedSessionIfIdle()` normally lives (RootView).
    ///
    /// THE BUG THIS FIXES: plug the phone into the car after a force-quit and PocketDJ came up
    /// with an EMPTY deck — the set was still on disk, nothing had read it. Worse, before the
    /// companion fix in `SetlistPlayer.restore(from:)`, the CarPlay restore also WROTE the session
    /// file from a scene that had never pulled from iCloud, so connecting to the car could push a
    /// stale local session over a newer one from another device.
    ///
    /// Held, never auto-playing (the underlying restore's contract), so connecting to CarPlay
    /// never starts sound on its own — the driver taps ▶. Idempotent: no-op once a set is running,
    /// so it can be called on every scene connect. Vetoed during onboarding for the same reason
    /// every mutating intent is: a pre-setup device must not materialize synced documents.
    func restorePlaybackSessionIfIdle() {
        guard onboardingIncomplete?() != true else { return }
        setlistPlayer.restorePersistedSessionIfIdle()
    }

    // MARK: - Play playlist / pocket

    /// ▶/🔀 a playlist: snapshot into the reserved Now Playing setlist and start the
    /// app-scoped sequencer (the same path the detail views drive, minus navigation).
    /// Returns the playlist's display name for the spoken dialog.
    @discardableResult
    func playPlaylist(id: String, shuffle: Bool) async throws -> String {
        try vetoDuringOnboarding()
        await ensureReady()
        guard let playlist = collections.playlist(id) else { throw PocketDJIntentError.playlistNotFound }
        guard let set = collections.playNow(playlistId: id, shuffle: shuffle), !set.tracks.isEmpty else {
            throw PocketDJIntentError.emptyCollection(collections.playlist(id)?.name ?? "that playlist")
        }
        startNowPlaying(set)
        return playlist.name
    }

    /// ▶/🔀 a pocket (DAG-resolved order). Returns the pocket's name for the dialog.
    @discardableResult
    func playPocket(id: String, shuffle: Bool) async throws -> String {
        try vetoDuringOnboarding()
        await ensureReady()
        guard let pocket = collections.pocket(id) else { throw PocketDJIntentError.pocketNotFound }
        guard let set = collections.playNow(pocketId: id, shuffle: shuffle), !set.tracks.isEmpty else {
            throw PocketDJIntentError.emptyCollection(pocket.name)
        }
        startNowPlaying(set)
        return pocket.name
    }

    /// ▶ a single catalog song (the iOS 27 playAudio schema's song case): a
    /// one-track Now Playing setlist, so the transport/lock-screen behave exactly
    /// as for any other Now Playing set. Returns the title for dialogs.
    @discardableResult
    func playSong(id: String) async throws -> String {
        try vetoDuringOnboarding()
        await ensureReady()
        guard let song = app.songsById[id] else { throw PocketDJIntentError.songNotFound }
        guard let set = collections.playNow(songIds: [id], name: song.name, source: .browser), !set.tracks.isEmpty else {
            throw PocketDJIntentError.songNotFound
        }
        startNowPlaying(set)
        return song.name
    }

    /// ▶/🔀 an album: its tracks (in order, or shuffled) into the reserved Now Playing setlist.
    /// Mirrors AlbumDetailView.play (source: .album). Returns the album name for dialogs.
    @discardableResult
    func playAlbum(id: String, shuffle: Bool = false) async throws -> String {
        try vetoDuringOnboarding()
        await ensureReady()
        guard let album = app.albumsById[id] else { throw PocketDJIntentError.songNotFound }
        guard let set = collections.playNow(songIds: album.trackList, name: album.name,
                                            shuffle: shuffle, source: .album),
              !set.tracks.isEmpty else { throw PocketDJIntentError.emptyCollection(album.name) }
        startNowPlaying(set)
        return album.name
    }

    /// ▶/🔀 an arbitrary list of song ids into the reserved Now Playing setlist — for collections
    /// that have NO stored setlist (e.g. an Apple Music / source playlist from the catalog). A
    /// fresh snapshot is built each call, so replaying picks up the source's current songs.
    @discardableResult
    func playSongIds(_ ids: [String], name: String, shuffle: Bool = false,
                     source: PlayHistoryStore.PlaySource) async throws -> String {
        try vetoDuringOnboarding()
        await ensureReady()
        guard let set = collections.playNow(songIds: ids, name: name, shuffle: shuffle, source: source),
              !set.tracks.isEmpty else { throw PocketDJIntentError.emptyCollection(name) }
        startNowPlaying(set)
        return name
    }

    /// Start the sequencer on the freshly-upserted Now Playing setlist — the same
    /// track→item mapping SetlistDetailView.playableItems does (text cues stripped).
    private func startNowPlaying(_ set: Setlist) {
        let items = set.tracks
            .filter { $0.isText != true && !$0.songId.isEmpty }
            .map { SetlistPlayer.Item(id: $0.songId, title: $0.name, artist: $0.artist,
                                      lengthMs: $0.shownMs, variant: $0.songVariant) }
        setlistPlayer.play(items, sourceSetlistId: nowPlayingSetlistId)
    }

    // MARK: - Auto-mix

    /// Start an Auto-DJ mix from a pocket or setlist — the same path as MixView's
    /// ▶/🔀 (resolver → AutoMixItems → engine), including the Settings pushes MixView
    /// does on tab-open (an intent may start a mix before the Mix tab ever opened).
    /// Returns (display name, loadable track count) for the dialog.
    @discardableResult
    func startAutoMix(source: MixSource, shuffle: Bool) async throws -> (name: String, count: Int) {
        try vetoDuringOnboarding()
        await ensureReady()
        let name: String
        switch source {
        case .pocket(let id):
            guard let p = collections.pocket(id) else { throw PocketDJIntentError.mixSourceNotFound }
            name = p.name
        case .setlist(let id):
            guard let s = collections.setlist(id) else { throw PocketDJIntentError.mixSourceNotFound }
            name = s.name ?? "Set list"
        }
        // Mirror MixView.task's settings pushes so an intent-started mix behaves
        // identically to one started from the tab (glide/skip lengths, cue side, pulse).
        mix.setCueOnRight(settings.cueOutputChannel.onRight)
        mix.setBeatPulseEnabled(settings.beatPulseEnabled)
        mix.setMixGlideSeconds(settings.mixGlideSeconds)
        mix.setSkipFadeSeconds(settings.skipFadeSeconds)
        let loadables = MixResolver(app: app, collections: collections, burns: burns, studio: studio).loadables(for: source)
        guard !loadables.isEmpty else { throw PocketDJIntentError.noBurnedSongs(name) }
        let items = loadables.map { MixEngine.AutoMixItem(loadable: $0, durationMs: $0.lengthMs ?? 180_000) }
        mix.startAutoMix(items, shuffled: shuffle,
                         lead: settings.autoMixLeadSeconds, fade: settings.autoMixFadeSeconds,
                         label: name)
        return (name, items.count)
    }

    /// Suspend a running Auto-DJ. Uses the lock-screen seam (`remotePause`) — the ONLY
    /// pause that freezes the transition machine's wall clock and can later resume; the
    /// in-app `pauseAuto()` keeps audio playing and `pauseBoth()` would END the mix.
    func pauseAutoMix() throws {
        try vetoDuringOnboarding()
        guard mix.autoMixing else { throw PocketDJIntentError.noAutoMixRunning }
        mix.remotePause()
    }

    /// Resume a suspended Auto-DJ via the lock-screen seam (`remotePlay`): unfreezes the
    /// clock, resumes only the decks the pause silenced, and re-arms the machine. Never
    /// resurrects a deliberate in-app hand-mixing pause (that flag isn't set by us).
    func resumeAutoMix() throws {
        try vetoDuringOnboarding()
        guard mix.autoMixing else { throw PocketDJIntentError.noAutoMixRunning }
        guard mix.autoPaused else { throw PocketDJIntentError.autoMixNotPaused }
        mix.remotePlay()
    }

    // MARK: - Create pocket (async build)

    /// Kick off the on-device-LLM pocket build and return immediately (the intent's
    /// dialog promises the pocket "shortly"). Throws up-front when the model is
    /// unavailable so Siri can say WHY instead of silently never delivering.
    func createPocket(brief: String, targetMinutes: Int) async throws {
        try vetoDuringOnboarding()
        let model = try PocketBriefModelFactory.make()
        await ensureReady()
        pocketBuilder.kickOff(brief: brief, targetMinutes: targetMinutes, model: model)
    }
}

/// User-facing intent failures — each maps to a Siri-speakable sentence.
enum PocketDJIntentError: Error, CustomLocalizedStringResourceConvertible {
    case playlistNotFound
    case pocketNotFound
    case songNotFound
    case songOnlyAction
    case mixSourceNotFound
    case emptyCollection(String)
    case noBurnedSongs(String)
    case noAutoMixRunning
    case autoMixNotPaused
    case intelligenceUnavailable(String)
    case setupIncomplete

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .playlistNotFound:
            return "I couldn't find that playlist in PocketDJ."
        case .pocketNotFound:
            return "I couldn't find that pocket in PocketDJ."
        case .songNotFound:
            return "I couldn't find that song in your PocketDJ sources."
        case .songOnlyAction:
            return "That works on individual songs, not playlists or pockets."
        case .mixSourceNotFound:
            return "I couldn't find that pocket or set list in PocketDJ."
        case .emptyCollection(let name):
            return "\(name) has no playable songs yet."
        case .setupIncomplete:
            return "Finish setting up PocketDJ in the app first."
        case .noBurnedSongs(let name):
            return "\(name) has no burned songs on this device — auto-mix plays local files only. Burn it first."
        case .noAutoMixRunning:
            return "There's no auto-mix running."
        case .autoMixNotPaused:
            return "The auto-mix isn't paused."
        case .intelligenceUnavailable(let why):
            return "\(why)"
        }
    }
}
