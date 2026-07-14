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

    private var lastPublished: NowPlayingSnapshot?
    private var lastCoverSongId: String??      // nil = never set; .some(nil) = idle published
    private var coverVersion = 0
    private var coverToken = 0

    init(setlist: SetlistPlayer, player: PlayerEngine, rips: RipsStore,
         coordinator: PlaybackCoordinator, artCandidates: @escaping (String) -> [URL]) {
        self.setlist = setlist
        self.player = player
        self.rips = rips
        self.coordinator = coordinator
        self.artCandidates = artCandidates
        // Wire the widget's transport buttons → the SAME entry points the lock screen uses.
        WidgetPlaybackController.shared.toggle = { [weak player] in player?.toggle() }
        WidgetPlaybackController.shared.next = { [weak setlist] in setlist?.skipNext() }
        WidgetPlaybackController.shared.previous = { [weak setlist] in setlist?.skipPrevious() }
        // Drain a widget transport command the INSTANT it arrives (a widget click doesn't
        // foreground the app, so we can't wait for scenePhase — the Darwin notification does).
        WidgetCommandBridge.onCommand = { [weak self] in
            self?.drainPendingCommand(now: Date().timeIntervalSince1970)
        }
        WidgetCommandBridge.observe()
        arm()
        publish()
    }

    /// Drain a transport command a widget tap dropped while the app was fully quit — call when
    /// the app becomes active (`scenePhase == .active`). Stale commands are discarded by `drain`.
    func drainPendingCommand(now: TimeInterval) {
        guard let c = WidgetCommandChannel.drain(now: now) else { return }
        switch c {
        case .toggle:   player.toggle()
        case .next:     setlist.skipNext()
        case .previous: setlist.skipPrevious()
        }
    }

    // MARK: - Observation

    private func arm() {
        withObservationTracking {
            _ = setlist.isRunning
            _ = setlist.currentSongId
            _ = setlist.index
            _ = setlist.queue.count
            _ = player.isPlaying
            _ = rips.nowPlaying?.songId
            _ = coordinator.activeBackend
        } onChange: { [weak self] in
            Task { @MainActor in self?.publish(); self?.arm() }
        }
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
        let playing = player.isPlaying || coordinator.isPlaying
        // Refresh the cover only when the current song id actually changes (async; it bumps
        // coverVersion + republishes so the widget re-reads the new image).
        if lastCoverSongId != .some(base.songId) {
            lastCoverSongId = .some(base.songId)
            refreshCover(for: base.songId)
        }
        let snap = NowPlayingSnapshot(isPlaying: playing, hasContent: base.hasContent,
                                      title: base.title, artist: base.artist, songId: base.songId,
                                      coverVersion: coverVersion, upNext: base.upNext)
        guard snap != lastPublished else { return }
        lastPublished = snap
        NowPlayingShared.write(snap)
        // WidgetKit reached visionOS only in visionOS 26; the app itself targets visionOS 2.0,
        // so gate the reload there (always runs on iOS/macOS — the `*` covers them).
        if #available(visionOS 26.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Cover-art candidate URLs for `songId`. For an Apple Music stream the MusicKit catalog
    /// artwork comes FIRST — our AM-Local catalog carries no `artCandidates`, so it's the only
    /// cover the widget can show (the system card shows art only because MusicKit auto-fills it).
    private func candidateArtURLs(for songId: String) -> [URL] {
        var urls: [URL] = []
        if coordinator.activeBackend == .appleMusic,
           coordinator.appleMusic.nowPlaying?.songId == songId,
           let amURL = coordinator.appleMusic.nowPlaying?.artworkURL {
            urls.append(amURL)
        }
        urls.append(contentsOf: artCandidates(songId))
        return urls
    }

    private func refreshCover(for songId: String?) {
        coverToken += 1
        let token = coverToken
        guard let url = NowPlayingShared.coverURL else { return }
        guard let songId else { try? FileManager.default.removeItem(at: url); return }   // idle
        let urls = candidateArtURLs(for: songId)
        guard !urls.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            coverVersion += 1
            publish()
            return
        }
        Task { @MainActor [weak self] in
            let img = await PlayerEngine.loadFirstImage(urls)
            guard let self, self.coverToken == token else { return }   // song changed → drop
            if let img, let data = Self.pngData(img) {
                try? data.write(to: url)
            } else {
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
