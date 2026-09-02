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
    /// The 👍/👎 log behind every recommendation surface. Reached through this bridge for the
    /// same reason `favorites` is: CarPlay is its own `UIScene` and App Intents run outside the
    /// SwiftUI environment entirely, so the widget/lock-screen/car controls need a way to the ONE
    /// live store rather than a second copy. Optional so a test host can build the bridge without
    /// the recommendation graph.
    var recFeedback: RecFeedbackStore?
    /// The FROZEN For You ranking. CarPlay's For You tab renders this snapshot verbatim — it never
    /// triggers a refresh, and that is deliberate: a refresh is two catalog sweeps (~96k rows each,
    /// once per collection), which is not something to start because a car connected. The phone owns
    /// the refresh (its tab task + the 4:20 schedule); the car reads the result.
    /// Optional so a test host can build the bridge without the recommendation graph.
    var forYouFeed: ForYouFeedStore?
    /// The New tile's content. Read-only from CarPlay for the same reason as `forYouFeed`: its
    /// fetches ride PLAY events and the one-shot seed, never a render — least of all a render in a
    /// moving car.
    var releaseFeed: ReleaseFeedService?
    /// Streaming accounts — CarPlay needs exactly one thing from it, the Apple Music library
    /// contributor that expands a New release into its tracks (`ReleaseStreaming.tracks`). nil ⇒
    /// the expansion falls through to the rip server's subscription-free proxy, which is the same
    /// degradation the phone takes.
    var streaming: StreamingStore?
    /// The Mix tab's collection download pipeline. An intent-started auto-mix must kick the same
    /// download run MixView's ▶/🔀 does (the mix may start before the Mix tab ever opened), so the
    /// bridge carries the ONE app-scoped downloader. Optional so a test host can build the bridge
    /// without it.
    var mixDownloader: CollectionMixDownloader?
    /// Async "Create pocket" builder — kept observable so UI can surface progress later.
    let pocketBuilder: PocketBuilderService

    /// Pending intent-driven navigation (Open Playlist/Pocket). RootView observes and
    /// consumes it (it owns the NavigationPath); set-then-clear, never queued.
    var pendingRoute: IntentRoute?

    /// Pending in-app search term ("Search PocketDJ for …" — the system.search
    /// intent). BrowseView observes and consumes it into its search field; paired
    /// with `pendingRoute == .browseSearch`, which lands the user on the Browser.
    var pendingBrowseQuery: String?

    /// Why a pending route could NOT be honoured (e.g. an album that is no longer in the
    /// catalog and can't be previewed either). RootView surfaces it and clears it.
    /// A navigation request must always produce a VISIBLE result — silently doing nothing
    /// is indistinguishable from the blank-screen bug it replaced.
    var routeMessage: String?

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
        if isOnboardingIncomplete { throw PocketDJIntentError.setupIncomplete }
    }

    /// The same veto, as a QUESTION rather than a throw — for the one playback path that does not
    /// run through `playSongIds` and so cannot inherit its guard: a New-tile queue, whose ids are
    /// unowned `am:<storeID>` streams that `CollectionsStore.playNow` would drop on the floor (see
    /// `ReleaseStreaming`). It goes straight to the sequencer, so it has to ask.
    var isOnboardingIncomplete: Bool { onboardingIncomplete?() == true }

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
        // Kick the collection's download run (same pipeline as MixView's ▶/🔀 — idempotent per
        // source). Deliberately BEFORE the loadables guard: an all-undownloaded collection still
        // starts pulling, so a retried intent finds tracks on disk.
        mixDownloader?.begin(source: source)
        let loadables = MixResolver(app: app, collections: collections, burns: burns, studio: studio).loadables(for: source)
        guard !loadables.isEmpty else { throw PocketDJIntentError.noBurnedSongs(name) }
        let items = loadables.map { MixEngine.AutoMixItem(loadable: $0, durationMs: $0.lengthMs ?? 180_000) }
        mix.startAutoMix(items, shuffled: shuffle,
                         lead: settings.autoMixLeadSeconds, fade: settings.autoMixFadeSeconds,
                         label: name)
        // Progressive eligibility: tracks that finish downloading join this mix's queue.
        mixDownloader?.noteAutoStarted(initialIds: Set(loadables.map(\.songId)),
                                       lead: settings.autoMixLeadSeconds,
                                       fade: settings.autoMixFadeSeconds, label: name)
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

    // MARK: - Recommendation feedback (👍 / 👎 on what is playing)

    /// The song the tuning controls act on, and the For You list it is a recommendation IN — nil
    /// when the running queue did not come from one, or when the current track is not one of that
    /// list's rows. Every SYNC surface hides its controls on nil rather than guessing at a scope,
    /// which is the honest answer: there is no tile to sink it in.
    @MainActor
    func currentRecTarget() -> (songId: String, scope: String)? {
        guard let recFeedback else { return nil }
        let p = setlistPlayer
        guard p.isRunning, p.index < p.queue.count else { return nil }
        let songId = p.queue[p.index].id
        guard let scope = recFeedback.scope(forPlaying: songId) else { return nil }
        return (songId, scope)
    }

    /// The verdict standing for the current track, for a surface that must render a filled or
    /// hollow thumb.
    @MainActor
    func currentRecVerdict() -> RecFeedbackStore.Verdict? {
        guard let t = currentRecTarget() else { return nil }
        return recFeedback?.verdict(songId: t.songId, scope: t.scope)
    }

    /// Record a verdict for whatever is playing RIGHT NOW. The single entry point every SYNC
    /// surface uses — widget intent, lock screen, CarPlay, the in-app deck — so "the same store,
    /// the same intent, the same wire event" is enforced by there being exactly one function.
    ///
    /// Returns the verdict that LANDED (nil = the tap cleared an existing one), so a caller can
    /// re-render its glyph without re-reading the store.
    ///
    /// ── IT DOES NOT TOUCH PLAYBACK ───────────────────────────────────────────────────────────
    /// No stop, no re-shuffle, no jump, and specifically NO SKIP on a reject. See
    /// `RecFeedbackButtons` for the full reasoning; the short version is that ⏭ already means "get
    /// this off now", and a thumbs-down that also skipped would make a mis-tap in a moving car
    /// instantly unrecoverable.
    ///
    /// Deliberately NOT vetoed during onboarding, unlike the playback intents: this writes a
    /// device-local, CloudKit-synced opinion document and starts no playback, materializes no
    /// collection, and creates no synced setlist — the invariant that veto protects. Vetoing it
    /// would mean a thumbs-down given from a widget before setup completed is silently lost.
    @discardableResult
    @MainActor
    func recordNowPlayingFeedback(_ verdict: RecFeedbackStore.Verdict,
                                  surface: RecFeedbackStore.Surface) -> RecFeedbackStore.Verdict? {
        guard let store = recFeedback, let t = currentRecTarget() else { return nil }
        let song = app.songsById[t.songId]
        let landed = store.toggle(songId: t.songId, to: verdict, scope: t.scope, surface: surface,
                                  artistKey: song.map { PuzzleSimilarity.artistKey($0.artist) },
                                  genre: SimilarityFamilies.canonicalGenre(
                                      song?.albumId.flatMap { app.albumsById[$0] }?.genre))
        // A 👍 that LANDS accepted also ADDS. The owner's contract for the tile rows — "send
        // positive signal to the recommendation engine AND add the song to the collection" — holds
        // unqualified, and for a collection tile the playing scope IS the target collection, so
        // the transport surfaces (car, widget, lock screen) honour it too. Reserved scopes
        // (zone/new) resolve to no target and stay pure feedback; the undo tap (landed == nil)
        // never un-adds — removal from a crate is a deliberate act, not a side effect.
        if landed == .accepted { collections.addAcceptedSong(t.songId, scopedTo: t.scope) }
        return landed
    }

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
