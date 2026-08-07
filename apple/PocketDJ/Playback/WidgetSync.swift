import Foundation
import WidgetKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Publishes the app's Now Playing state into the shared App Group container so the
/// `PocketDJWidgets` extension can render it, and wires the widget's transport buttons back
/// to real playback. The widget process can't read the app's live `@Observable` stores, so
/// this is the bridge: on every playback change it writes a small `NowPlayingSnapshot` (+ a
/// cover PNG) and calls `WidgetCenter.reloadAllTimelines()`.
///
/// Source of truth mirrors CarPlay (`CarPlayModel`): the running **`SetlistPlayer`** queue is
/// the current track + Up Next; a single-row play with no set falls back to `RipsStore` /
/// the Apple Music now-playing. Play/pause reads `PlayerEngine`/coordinator.
@MainActor
final class WidgetSync {
    private let setlist: SetlistPlayer
    private let player: PlayerEngine
    private let rips: RipsStore
    private let coordinator: PlaybackCoordinator
    /// Resolves a song id → its ordered cover-art candidate URLs (same source the lock-screen
    /// card uses: `AppModel.album(forSongId:)?.artCandidates`).
    private let artCandidates: (String) -> [URL]
    /// Per-profile favorites store — the widget's ♥ toggles the current track here, and the
    /// published snapshot reflects `isFavorite` from it.
    private let favorites: FavoritesStore
    /// Resolves a song id → its Apple Music catalog id (nil for vinyl / My Digital / Studio),
    /// so a widget ♥ carries the id `FavoritesStore.toggle` needs for the owner-gated push.
    private let appleMusicId: (String) -> String?

    private var lastPublished: NowPlayingSnapshot?
    /// Cover identity = songId + its (late-arriving) AM artwork URL — see `publish()`.
    private var lastCoverKey: String?
    private var coverVersion = 0
    private var coverToken = 0

    init(setlist: SetlistPlayer, player: PlayerEngine, rips: RipsStore,
         coordinator: PlaybackCoordinator, artCandidates: @escaping (String) -> [URL],
         favorites: FavoritesStore, appleMusicId: @escaping (String) -> String?) {
        self.setlist = setlist
        self.player = player
        self.rips = rips
        self.coordinator = coordinator
        self.artCandidates = artCandidates
        self.favorites = favorites
        self.appleMusicId = appleMusicId
        // Wire the widget's transport buttons → the SAME entry points the lock screen uses.
        WidgetPlaybackController.shared.toggle = { [weak self] in self?.transportToggle() }
        WidgetPlaybackController.shared.next = { [weak setlist] in setlist?.skipNext() }
        WidgetPlaybackController.shared.previous = { [weak setlist] in setlist?.skipPrevious() }
        // The widget's ♥ flips the CURRENT track's favorite — same store the in-app control uses.
        WidgetPlaybackController.shared.toggleFavorite = { [weak self] in self?.toggleFavoriteForCurrent() }
        // Repeat/shuffle drive the running set's modes — same methods the in-app deck toggles call.
        WidgetPlaybackController.shared.cycleRepeat = { [weak setlist] in setlist?.cycleRepeatMode() }
        WidgetPlaybackController.shared.toggleShuffle = { [weak setlist] in setlist?.toggleShuffle() }
        // Drain a widget transport command the INSTANT it arrives (a widget click doesn't
        // foreground the app, so we can't wait for scenePhase — the Darwin notification does).
        WidgetCommandBridge.onCommand = { [weak self] in
            self?.drainPendingCommand(now: Date().timeIntervalSince1970)
        }
        WidgetCommandBridge.observe()
        arm()
        publish()
    }

    /// Route play/pause to whichever engine OWNS the audio right now (the in-app panel's proven
    /// branch). Blindly toggling PlayerEngine while Apple Music owned playback toggled an IDLE
    /// AVPlayer: no audible effect, a wrong `isPlaying`, and (before the engine's idle guard) a
    /// resurrected stale Now Playing card on macOS.
    private func transportToggle() {
        // A RESTORED (held) deck has no audio loaded yet — the widget's ▶ resumes it at the
        // saved position, exactly like the in-app panel's toggle.
        if setlist.isHeldForResume {
            NPLog.trace("widgetSync toggle → resumeFromHold (restored session)")
            setlist.resumeFromHold()
            return
        }
        NPLog.trace("widgetSync toggle → \(coordinator.activeBackend == .appleMusic ? "appleMusic" : "engine")")
        if coordinator.activeBackend == .appleMusic { coordinator.togglePlayPause() }
        else { player.toggle() }
    }

    /// Flip the CURRENT track's favorite — resolves the running song id + its Apple Music catalog
    /// id and calls `FavoritesStore.toggle`, whose `onChanged` already reaches Apple Music when
    /// (and only when) the user is the owner and the song carries a catalog id. The observation in
    /// `arm()` (`favorites.favoriteIds`) then republishes the snapshot so the ♥ glyph reflects it.
    private func toggleFavoriteForCurrent() {
        // Prefer the live current track. If the app is mid-cold-launch with no deck restored
        // yet (the app-was-quit widget-tap path), fall back to the snapshot the widget was
        // actually showing when the ♥ was tapped — persisted in the App Group — so a favorite
        // tapped while quit targets that track instead of being silently dropped.
        let base = currentBase()
        let snap = base.songId == nil ? NowPlayingShared.read() : nil
        guard let songId = base.songId ?? snap?.songId else { return }
        let catalogId = appleMusicId(songId) ?? snap?.appleMusicId
        NPLog.trace("widgetSync toggleFavorite songId=\(songId)")
        favorites.toggle(songId, appleMusicId: catalogId)
    }

    /// Drain a transport command a widget tap dropped while the app was fully quit — call when
    /// the app becomes active (`scenePhase == .active`). Stale commands are discarded by `drain`.
    func drainPendingCommand(now: TimeInterval) {
        guard let c = WidgetCommandChannel.drain(now: now) else { return }
        NPLog.trace("widgetSync drain cmd=\(c.rawValue)")
        switch c {
        case .toggle:        transportToggle()
        case .next:          setlist.skipNext()
        case .previous:      setlist.skipPrevious()
        case .favorite:      toggleFavoriteForCurrent()
        case .cycleRepeat:   setlist.cycleRepeatMode()
        case .toggleShuffle: setlist.toggleShuffle()
        }
    }

    // MARK: - Observation

    private func arm() {
        withObservationTracking {
            _ = setlist.isRunning
            _ = setlist.currentSongId
            _ = setlist.index
            _ = setlist.queue.count
            // Repeat/shuffle mode changes (from the deck, the widget, or a lock-screen command)
            // must republish so the widget's glyphs reflect the running set's state.
            _ = setlist.repeatMode
            _ = setlist.shuffleEnabled
            _ = player.isPlaying
            _ = rips.nowPlaying?.songId
            _ = coordinator.activeBackend
            // Apple Music state lands ASYNC (after the MusicKit resolve) and can also change from
            // OUTSIDE the app (MusicKit's own macOS card) — without these two reads the widget
            // missed the artwork URL arriving and drifted out of sync on play/pause.
            _ = coordinator.appleMusic.nowPlaying
            _ = coordinator.appleMusic.isPlaying
            // A ♥ toggled ANYWHERE (widget, in-app row, an Apple Music pull) must republish so the
            // widget's heart fills/empties — reading the derived set arms the tracking on it.
            _ = favorites.favoriteIds
        } onChange: { [weak self] in
            Task { @MainActor in self?.publish(); self?.fanOutNowPlayingFavorite(); self?.arm() }
        }
    }

    /// F10 fan-out — the SINGLE now-playing-state observer (this `arm()`) is also what keeps the ♥
    /// in sync on the OTHER now-playing surfaces, so a favorite (or track) change anywhere reflects
    /// everywhere without a second observation:
    ///   • in-app SwiftUI ♥ — updates itself off `FavoritesStore` (@Observable), nothing to do here;
    ///   • lock screen — re-push the system card so `likeCommand.isActive` (the ♥ fill) is current;
    ///   • CarPlay — rebuild the immutable Now Playing heart button (no-op when no head unit).
    /// Fires on track changes too (the arm tracks `currentSongId`/`index`), which is exactly when
    /// both surfaces must re-evaluate the NEW track's favorite state.
    private func fanOutNowPlayingFavorite() {
        player.refreshFavoriteState()
        #if os(iOS)
        CarPlayController.current?.refreshNowPlayingButtons()
        #endif
    }

    // MARK: - Publish

    private struct Base {
        var title = ""; var artist = ""; var songId: String?
        var upNext: [NowPlayingSnapshot.Track] = []; var hasContent = false
    }

    private func currentBase() -> Base {
        if setlist.isRunning, setlist.index < setlist.queue.count {
            let it = setlist.queue[setlist.index]
            let up = setlist.upcoming.prefix(6).map {
                NowPlayingSnapshot.Track(id: $0.uid.uuidString, songId: $0.id, title: $0.title, artist: $0.artist)
            }
            return Base(title: it.title, artist: it.artist, songId: it.id, upNext: Array(up), hasContent: true)
        }
        if let np = rips.nowPlaying {
            return Base(title: np.title, artist: np.artist, songId: np.songId, hasContent: true)
        }
        if let am = coordinator.appleMusic.nowPlaying {
            return Base(title: am.title, artist: am.artist, songId: am.songId, hasContent: true)
        }
        return Base()
    }

    private func publish() {
        let base = currentBase()
        // Play state follows the engine that OWNS the audio — OR-ing both let an idle
        // PlayerEngine (or a stale AM mirror) contradict what's actually sounding.
        let playing = coordinator.activeBackend == .appleMusic ? coordinator.isPlaying
                                                               : player.isPlaying
        // Refresh the cover when the song OR its AM artwork URL changes. The AM URL arrives
        // AFTER the song id (the MusicKit resolve is async) — keying on the id alone fetched
        // too early, found no art, and never retried (the "no album art in the widget" bug).
        let amURL = amArtworkURL(for: base.songId)
        // While that resolve is still in flight (Apple Music owns audio but its now-playing
        // hasn't landed on this song yet) there are NO candidates — clearing the cover then
        // flashed the placeholder on every AM track change. DEFER instead: keep the previous
        // art on screen; the resolve republishes with the real URL within ~1s and overwrites.
        let amPending = coordinator.activeBackend == .appleMusic
            && coordinator.appleMusic.nowPlaying?.songId != base.songId
        let coverKey = (base.songId ?? "") + "|" + (amURL?.absoluteString ?? (amPending ? "pending" : ""))
        if lastCoverKey != coverKey {
            lastCoverKey = coverKey
            if amPending, amURL == nil, let songId = base.songId, artCandidates(songId).isEmpty {
                NPLog.trace("cover DEFER (AM resolve pending) songId=\(songId)")
            } else {
                refreshCover(for: base.songId)
            }
        }
        // Favorite state + the current track's Apple Music id ride the snapshot so the widget's ♥
        // reflects the store and a widget-originated toggle carries the id the push needs.
        let isFavorite = base.songId.map { favorites.isFavorite($0) } ?? false
        let amCatalogId = base.songId.flatMap { appleMusicId($0) }
        // Repeat/shuffle are set-level modes — surface them only while a set is running (a single
        // track / Apple Music play has no queue to repeat or shuffle, so the glyphs read off).
        let repeatRaw = setlist.isRunning ? setlist.repeatMode.rawValue : "off"
        let shuffleOn = setlist.isRunning ? setlist.shuffleEnabled : false
        let snap = NowPlayingSnapshot(isPlaying: playing, hasContent: base.hasContent,
                                      title: base.title, artist: base.artist, songId: base.songId,
                                      coverVersion: coverVersion, upNext: base.upNext,
                                      isFavorite: isFavorite, appleMusicId: amCatalogId,
                                      repeatMode: repeatRaw, shuffleEnabled: shuffleOn)
        guard snap != lastPublished else { return }
        lastPublished = snap
        NPLog.trace("widgetSync publish title=\(snap.title) playing=\(snap.isPlaying) hasContent=\(snap.hasContent) upNext=\(snap.upNext.count) coverV=\(snap.coverVersion) groupOK=\(NowPlayingShared.defaults != nil)")
        NowPlayingShared.write(snap)
        // WidgetKit reached visionOS only in visionOS 26; the app itself targets visionOS 2.0,
        // so gate the reload there (always runs on iOS/macOS — the `*` covers them).
        if #available(visionOS 26.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// The MusicKit catalog artwork URL for `songId`, when it IS the Apple Music now-playing
    /// track. nil otherwise (idle, local playback, or the async resolve hasn't landed yet).
    private func amArtworkURL(for songId: String?) -> URL? {
        guard let songId, coordinator.activeBackend == .appleMusic,
              coordinator.appleMusic.nowPlaying?.songId == songId else { return nil }
        return coordinator.appleMusic.nowPlaying?.artworkURL
    }

    /// Cover-art candidate URLs for `songId`. For an Apple Music stream the MusicKit catalog
    /// artwork comes FIRST — our AM-Local catalog carries no `artCandidates`, so it's the only
    /// cover the widget can show (the system card shows art only because MusicKit auto-fills it).
    private func candidateArtURLs(for songId: String) -> [URL] {
        var urls: [URL] = []
        if let amURL = amArtworkURL(for: songId) { urls.append(amURL) }
        urls.append(contentsOf: artCandidates(songId))
        return urls
    }

    private func refreshCover(for songId: String?) {
        // Fixture/test runs must never touch the SHARED App Group cover file — it is
        // system state outside the test sandbox (the CollectionsSpotlight doctrine).
        // Also load-bearing for headless macOS test bootstrap: a wedged filesystem op
        // on that shared path (observed: a kernel-stalled unlink) would otherwise hang
        // the test host's launch inside PocketDJApp.init.
        guard ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] == nil else { return }
        coverToken += 1
        let token = coverToken
        guard let url = NowPlayingShared.coverURL else {
            NPLog.trace("cover ABORT: shared container URL is nil (App Group entitlement missing?)")
            return
        }
        guard let songId else {
            NPLog.trace("cover clear (idle)")
            try? FileManager.default.removeItem(at: url)
            return
        }
        let urls = candidateArtURLs(for: songId)
        NPLog.trace("cover refresh songId=\(songId) amURL=\(amArtworkURL(for: songId) != nil) candidates=\(urls.count) first=\(urls.first?.host() ?? "-")")
        guard !urls.isEmpty else {
            NPLog.trace("cover NONE (no candidates) → clearing file")
            try? FileManager.default.removeItem(at: url)
            coverVersion += 1
            publish()
            return
        }
        Task { @MainActor [weak self] in
            let img = await PlayerEngine.loadFirstImage(urls)
            guard let self, self.coverToken == token else { return }   // song changed → drop
            if let img, let data = Self.pngData(img) {
                do {
                    try data.write(to: url)
                    NPLog.trace("cover WROTE \(data.count) bytes → \(url.path)")
                } catch {
                    NPLog.trace("cover WRITE FAILED: \(error.localizedDescription) → \(url.path)")
                }
            } else {
                NPLog.trace("cover FETCH FAILED (no decodable image from \(urls.count) candidates)")
                try? FileManager.default.removeItem(at: url)
            }
            self.coverVersion += 1
            self.publish()   // republish with the bumped coverVersion so the widget reloads
        }
    }

    private static func pngData(_ image: PlatformImage) -> Data? {
        #if canImport(UIKit)
        return image.pngData()
        #elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}
