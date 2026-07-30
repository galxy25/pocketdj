import Foundation
import Observation

/// The matching engine behind the ▶ button. Given a song, it builds a SOURCE-AWARE
/// ordered list of `TrackPlaybackProvider`s and cycles them — calling `tryPlay` on each
/// until one resolves + starts the track. The first to return `true` becomes the active
/// backend; if none does, it surfaces an error.
///
/// Ordering rule (milestone 1): for a song whose origin source is the user's "Apple Music
/// (Local)" catalog, put the Apple Music STREAMING provider FIRST when it `isReady`
/// (enabled + authorized) — so tapping ▶ plays it via Apple Music. The rip server is
/// ALWAYS appended as the terminal fallback (rip-on-demand), so any song still plays even
/// when Apple Music can't resolve/play it. Other streaming backends could slot into the
/// same ordered list later.
///
/// The UI reads one unified, observable surface off this coordinator: `activeBackend`,
/// `isPlaying`, and the per-backend now-playing handoffs — plus `togglePlayPause()` /
/// `stop()` that delegate to whichever provider won. The rip path is transparent: its
/// provider just drives the same `PlayerEngine` the inline waveform/scrubber already binds
/// to, so that verified UI is untouched.
/// Item 7 — the SHARED "play a burned local file" helper, used by BOTH the
/// `SetlistPlayer` sequencer AND the single-row transport so `RipsStore.nowPlaying`
/// (and therefore the inline player + the row pause/resume toggle) stays consistent no
/// matter which surface started the burned file. It mirrors `RipServerPlaybackProvider.tryPlay`
/// for the rip path: stamp `nowPlaying`, then load the SAME `PlayerEngine` the inline
/// waveform/scrubber binds to. `startMs` is the analog seek offset within a shared album mp3.
///
/// `atMs` (optional, spec §9) is a CUE offset in ms from the SONG's 0:00 — the burned-file
/// path of the Studio Cues tab (sample-exact, unlike the streaming providers). It shifts
/// ONLY the load/seek position (`startMs + atMs`, `RipsStore.cueSeekMs`); `NowPlaying.startMs`
/// and the caller's `endBoundaryMs` keep anchoring on the song's TRUE start, so a cue play
/// inside a shared analog album mp3 still ends at the song's own end, not `atMs` past it.
@MainActor
func playLocalFile(_ url: URL, songId: String, title: String, artist: String,
                   startMs: Int?, rips: RipsStore, player: PlayerEngine,
                   endBoundaryMs: Int? = nil, atMs: Int? = nil, release: (() -> Void)? = nil) {
    let seekMs = RipsStore.cueSeekMs(sharedFileStartMs: startMs, atMs: atMs, live: false)
    let np = RipsStore.NowPlaying(songId: songId, title: title, artist: artist,
                                  url: url, live: false, startMs: startMs, seekMs: seekMs,
                                  waveform: nil)
    rips.setNowPlaying(np)
    player.load(url: url, live: false, startMs: seekMs, title: title, artist: artist,
                songId: songId, endBoundaryMs: endBoundaryMs, scopeRelease: release)
}

@MainActor
@Observable
final class PlaybackCoordinator {
    /// The rip-on-demand fallback (always present, always last).
    let ripProvider: RipServerPlaybackProvider
    /// Apple Music streaming (tried first for Apple Music (Local) songs when ready).
    let appleMusic: AppleMusicPlaybackProvider

    /// Resolves a song id → its origin source name (e.g. "Apple Music (Local)"), so the
    /// engine can order providers by source. Injected (the app passes `AppModel`'s map) to
    /// keep the coordinator decoupled + unit-testable. Returns nil when unknown.
    var sourceOfSong: (String) -> String? = { _ in nil }
    /// Catalog id lookup for an id-only play() call — so the AM streaming provider can enter the
    /// chain for a row the coordinator only knows by id (review catch: `IndexSong.minimal` drops
    /// `appleMusicId`, so a serverless streamable row's ▶ enabled but always fell through to the
    /// rip provider's error). Injected in PocketDJApp, mirroring `sourceOfSong`.
    var appleMusicIdOfSong: (String) -> String? = { _ in nil }

    /// Which backend last won the cycle (nil = nothing playing). Drives the inline player's
    /// branch (rip waveform vs. Apple Music position scrubber) + the "via …" badge.
    private(set) var activeBackend: PlaybackBackend?

    #if DEBUG
    /// Test seam — pairs with `AppleMusicPlaybackProvider.setNowPlayingForTests` so unit
    /// tests can put the coordinator in the "Apple Music owns audio" state without MusicKit.
    func setActiveBackendForTests(_ backend: PlaybackBackend?) { activeBackend = backend }
    #endif

    /// A user-presentable failure from the last `play` (e.g. no rip server). UI binds an
    /// alert to it; cleared on dismiss / next successful play.
    var lastErrorMessage: String?

    /// Play-stats hook: fired when a provider claims a play. Covers the Apple Music
    /// streaming path, which never touches `RipsStore.nowPlaying`; the rip path fires
    /// `RipsStore.onPlay` too, and the stats store's re-count window absorbs the overlap.
    /// Wired at app init to `PlayStatsStore.notePlayed`; nil in tests.
    @ObservationIgnored var onPlay: ((String) -> Void)?

    init(ripProvider: RipServerPlaybackProvider, appleMusic: AppleMusicPlaybackProvider) {
        self.ripProvider = ripProvider
        self.appleMusic = appleMusic
    }

    /// All providers, in the SOURCE-AWARE order to try for `song`:
    ///   • Apple Music FIRST when the song came from the Apple Music (Local) source AND
    ///     the Apple Music provider is ready (enabled + authorized),
    ///   • the rip server ALWAYS last (the universal fallback).
    /// (Another streaming backend would insert ahead of the rip server here later.)
    func providers(for song: IndexSong) -> [any TrackPlaybackProvider] {
        var ordered: [any TrackPlaybackProvider] = []
        // A namespaced `am:<storeID>` id (a Jukebox request matched only in the Apple
        // Music catalog — no indexed source) resolves directly via MusicKit, so it gets
        // the Apple Music provider on the same terms as an Apple Music (Local) song.
        let amNamespaced = AppleMusicCatalog.storeID(fromSongID: song.id) != nil
        // BOTH Apple Music sources stream FIRST (public-user audit fix): the private catalog's
        // "Apple Music (Local)" AND the on-device "Apple Music" library.
        let source = sourceOfSong(song.id)
        let appleMusicSourced = source == Config.appleMusicSourceName
            || source == AppleMusicLibraryStore.sourceName
        if appleMusicSourced || amNamespaced, appleMusic.isReady {
            ordered.append(appleMusic)
        }
        ordered.append(ripProvider)
        // STREAMING FALLBACK for every OTHER row carrying a catalog id (Discover adds,
        // imports, vinyl/digital with a matched id): AFTER the rip provider on purpose — a
        // rip is the user's OWN recording and must always win when it exists (the
        // prefer-the-user's-cut doctrine); streaming only rescues the row when the rip path
        // can't deliver at all (the public no-server case).
        if !(appleMusicSourced || amNamespaced), song.appleMusicId != nil, appleMusic.isReady {
            ordered.append(appleMusic)
        }
        return ordered
    }

    /// Can the Apple Music streaming backend play RIGHT NOW (enabled + authorized)? The
    /// row-transport reads this so a streamable-only song's ▶ enables with no rip server.
    var canStreamAppleMusic: Bool { appleMusic.isReady }

    /// Run the matching engine: try each provider for `song` in order; the first that
    /// returns true wins (record it as `activeBackend`); if none does, surface the rip
    /// provider's error (the terminal fallback's failure is the actionable one).
    ///
    /// `atMs` (optional, default nil = from the top) is a CUE offset in ms from the
    /// song's 0:00 (spec §9 — the Studio Cues tab's tap-to-play-from-here). It threads
    /// straight through to the winning provider's `tryPlay`; see the protocol doc for
    /// each backend's seek mechanism and the live-HLS "cannot seek" caveat (CuesView
    /// should pre-check `cueSeekSupported(for:)` and show the "still ripping" disabled
    /// state instead of playing a cue that would silently start at 0:00).
    func play(_ song: IndexSong, atMs: Int? = nil) async {
        lastErrorMessage = nil
        for provider in providers(for: song) {
            // Switching backends: stop the previously-active one so two engines don't both
            // play (e.g. Apple Music wins after a prior rip, or vice-versa).
            if let active = activeBackend, active != provider.backend {
                providerFor(active)?.stop()
            }
            if await provider.tryPlay(song, atMs: atMs) {
                activeBackend = provider.backend
                onPlay?(song.id)
                // Ask the server to prepare this user's OWN copy, if they have one.
                //
                // SERVER CONTRACT (enforced server-side, not here): `/rip` processes ONLY
                // audio the user uploaded for their own collection. A song the user has no
                // uploaded media for is a MISS — the server returns nothing and does not
                // acquire the audio from anywhere. Playback stays on whatever backend won
                // above. The miss is the correct outcome, never a gap for the server to fill.
                //
                // #TOUPDATE: the contract above is the TARGET. The server does not enforce
                // user-owned-media-only yet, and it currently runs unauthenticated. Remove
                // this marker once the server rejects anything the requesting user did not
                // upload, and authenticates the requester.
                //
                // Fire-and-forget: unawaited, never blocks or delays playback, failures are
                // silent. `requestRipIfNeeded` is idempotent and suspends (not blocks) on
                // the POST; a plain `Task` inherits this @MainActor.
                //
                // #TOUPDATE: the CONDITION below is still the pre-D6 one and does not match
                // the contract above. Gating on `.appleMusic` means the POST fires exactly
                // when the user is LEAST likely to have their own copy, and a reviewer
                // reading this binary sees "Apple Music playback → POST /rip", which is what
                // guideline 5.2.3 describes regardless of what the server does. Re-gate on
                // "user has unprocessed uploaded media for this song" once that signal
                // exists client-side.
                if provider.backend == .appleMusic,
                   AppleMusicCatalog.storeID(fromSongID: song.id) == nil {
                    Task { await self.ripProvider.requestAsyncRip(song.id) }
                }
                return
            }
        }
        // No provider claimed the song — surface the rip server's error if it had one.
        if let err = ripProvider.takeLastError() {
            lastErrorMessage = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
        } else {
            lastErrorMessage = "Couldn’t play this track."
        }
    }

    /// Convenience for the row ▶ given only (id, title, artist) — projects a minimal
    /// `IndexSong` and plays it. (The provider chain only needs id/name/artist + the
    /// source map keyed by id, so a minimal projection is sufficient.) `atMs` = optional
    /// cue offset, threaded through exactly like `play(_:atMs:)`.
    func play(id: String, title: String, artist: String, atMs: Int? = nil) async {
        // Carry the catalog id (looked up) so the AM streaming provider is eligible — the
        // provider chain reads `appleMusicId` for a source-less streamable row.
        await play(IndexSong.minimal(id: id, name: title, artist: artist,
                                     appleMusicId: appleMusicIdOfSong(id)), atMs: atMs)
    }

    /// Whether a cue offset passed to `play(_:atMs:)` would actually be APPLIED for
    /// `song` RIGHT NOW (spec §9). Derivation mirrors `providers(for:)` ordering:
    ///   • Apple Music would win (source match + ready) → true — play-then-seek works
    ///     regardless of rip state;
    ///   • otherwise the rip path decides: only a DURABLE cached S3 mp3 can seek. A song
    ///     whose rip is still IN FLIGHT (or not started) resolves to live HLS, which
    ///     cannot seek — CuesView shows those slots as a "still ripping" disabled state.
    /// Best-effort: if Apple Music is predicted to win here but its `resolve` MISSES at
    /// play time, the cycle falls through to the rip provider, which records the dropped
    /// cue in `ripProvider.lastCueDropped` (the after-the-fact backstop signal).
    /// NOTE for burned songs: local files don't route through the coordinator at all —
    /// CuesView plays those via `playLocalFile(..., startMs: cue + BurnStore.startMs(forSong:))`,
    /// which always seeks exactly; check `BurnStore.localURLForPlayback` FIRST, then this.
    func cueSeekSupported(for song: IndexSong) -> Bool {
        // Mirror providers()'s AM-first predicate (review catch: was checking only the private
        // "Apple Music (Local)" source, so cues were disabled on the on-device "Apple Music"
        // library + namespaced rows that stream-and-seek fine).
        let source = sourceOfSong(song.id)
        if (source == Config.appleMusicSourceName
            || source == AppleMusicLibraryStore.sourceName
            || AppleMusicCatalog.storeID(fromSongID: song.id) != nil),
           appleMusic.isReady { return true }
        return ripProvider.canCueSeek(song.id)
    }

    // MARK: Unified transport (delegate to the active provider)

    /// Whether the active backend is currently playing (unified play/pause glyph).
    var isPlaying: Bool { activeProvider?.isPlaying ?? false }

    func togglePlayPause() { activeProvider?.togglePlayPause() }

    /// Seek the Apple Music streaming backend (the rip backend scrubs via `PlayerEngine`
    /// directly, so it doesn't route through here).
    func seekAppleMusic(to seconds: Double) { appleMusic.seek(to: seconds) }

    func stop() {
        activeProvider?.stop()
        activeBackend = nil
    }

    /// Stop the Apple Music stream IF it's the active backend. Local files (burned/studio) play
    /// through `PlayerEngine` directly, bypassing this coordinator, so when the setlist advances
    /// from a streamed track to a local one nothing else stops MusicKit — without this the
    /// previous song keeps playing underneath the new one.
    func stopAppleMusicIfActive() {
        guard activeBackend == .appleMusic else { return }
        appleMusic.stop()
        activeBackend = nil
    }

    /// Is `songId` the Apple Music now-playing song? (The rip path keeps keying off
    /// `RipsStore.nowPlaying` directly — the coordinator doesn't duplicate that state — so
    /// this only answers the Apple Music branch. The row ▶ ORs the two together.)
    func isAppleMusicNowPlaying(_ songId: String) -> Bool {
        activeBackend == .appleMusic && appleMusic.nowPlaying?.songId == songId
    }

    // MARK: Provider lookup

    private var activeProvider: (any TrackPlaybackProvider)? {
        activeBackend.flatMap(providerFor)
    }

    private func providerFor(_ backend: PlaybackBackend) -> (any TrackPlaybackProvider)? {
        switch backend {
        case .ripServer:  return ripProvider
        case .appleMusic: return appleMusic
        }
    }
}
