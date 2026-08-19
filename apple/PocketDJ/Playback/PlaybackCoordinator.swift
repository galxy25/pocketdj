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
    /// Is THIS install the catalog owner (Levi)? Gates the passive rip fan-out so a hybrid
    /// user's streaming never enqueues captures on the shared server. Wired in PocketDJApp to
    /// `OwnerIdentity`; defaults false (safe — a non-owner never fans out).
    var isCatalogOwner: () -> Bool = { false }
    /// Catalog id lookup for an id-only play() call — so the AM streaming provider can enter the
    /// chain for a row the coordinator only knows by id (review catch: `IndexSong.minimal` drops
    /// `appleMusicId`, so a serverless streamable row's ▶ enabled but always fell through to the
    /// rip provider's error). Injected in PocketDJApp, mirroring `sourceOfSong`.
    var appleMusicIdOfSong: (String) -> String? = { _ in nil }
    /// VARIANT catalog id lookup (base song id + edition → the edition's catalog id, per
    /// `IndexSong.appleMusicId(for:)`) — feeds the variant-play path below so a cleanOnly
    /// substitution streams the CLEAN catalog row. Injected in PocketDJApp; nil-returning
    /// default keeps tests inert (the variant song then resolves via edition-constrained
    /// search, else the variant rip).
    var variantAppleMusicIdOfSong: (String, SongVariant) -> String? = { _, _ in nil }
    /// EDITION fields for an id-only `play(id:…)` — the three values `appleMusicId(for:)`
    /// needs. Without them the minimal projection below carries only the PRIMARY id, so a
    /// prefer-explicit substitution could never be computed downstream and every ordinary ▶
    /// streamed the primary (usually clean) cut. Injected in PocketDJApp, mirroring
    /// `appleMusicIdOfSong`; the nil-returning default keeps tests unchanged.
    var editionsOfSong: (String) -> (explicit: Bool?, explicitId: String?, cleanId: String?) = { _ in (nil, nil, nil) }

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
    /// Wired at app init to `PlayCountService.notePlayed`; nil in tests.
    ///
    /// The BACKEND rides along because it decides how the play may be counted: an
    /// `.appleMusic` play is one APPLE ALSO COUNTS, so it will arrive again in the next
    /// `AMPlayBaselineStore` snapshot and must be recorded provisionally rather than added to a
    /// lifetime total twice. Every other backend is ours alone and accumulates permanently.
    @ObservationIgnored var onPlay: ((String, PlaybackBackend) -> Void)?

    init(ripProvider: RipServerPlaybackProvider, appleMusic: AppleMusicPlaybackProvider) {
        self.ripProvider = ripProvider
        self.appleMusic = appleMusic
    }

    /// TEST SEAM — force the Apple Music readiness predicate; nil (production) asks the
    /// provider. `AppleMusicPlaybackProvider.isReady` reads the live `MusicAuthorization`
    /// state, which a unit test cannot set: without this an ordering assertion silently
    /// degrades to the not-ready branch and proves nothing about the ordering it names.
    var appleMusicReadyOverrideForTests: Bool?
    private var appleMusicReady: Bool { appleMusicReadyOverrideForTests ?? appleMusic.isReady }

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
        // BASE id on purpose: a VARIANT of an AM-sourced song ("sng_…_clean") must inherit
        // its base song's source so the clean edition streams first, not rip-first.
        let source = sourceOfSong(SongVariant.baseId(song.id))
        let appleMusicSourced = source == Config.appleMusicSourceName
            || source == AppleMusicLibraryStore.sourceName
        let amBySource = (appleMusicSourced || amNamespaced) && appleMusicReady
        // STREAMING FALLBACK for every OTHER row carrying a catalog id (Discover adds,
        // imports, vinyl/digital with a matched id): normally AFTER the rip provider on
        // purpose — a rip is the user's OWN recording and must always win when it exists
        // (the prefer-the-user's-cut doctrine); streaming only rescues the row when the rip
        // path can't deliver (the public no-server case).
        let amAsFallback = !(appleMusicSourced || amNamespaced)
            && song.appleMusicId != nil && appleMusicReady

        // …and "can't deliver" has to include "can't deliver YET". `tryPlay` on a rip that is
        // merely QUEUED (or in flight) does not fail — it PARKS inside `ensureURL(allowLive:)`
        // waiting for the capture to go live, which is minutes while the rip server drains a
        // backfill queue. The cycle is sequential, so a fallback behind it never gets its turn:
        // the deck advances to a row that never starts, the previous track keeps sounding under
        // the new title, and ▶ resumes THAT (Levi, 2026-08-17 — "queued shouldn't block me from
        // streaming via the cloud"). So when the rip can't start instantly and Apple Music can,
        // stream now. The doctrine is intact: a DURABLE rip still wins outright, and the pending
        // rip still lands for next time.
        let ripStartsNow = ripProvider.canPlayImmediately(song.id)
        let amFirst = amBySource || (amAsFallback && !ripStartsNow)

        if amFirst { ordered.append(appleMusic) }
        ordered.append(ripProvider)
        if amAsFallback, !amFirst { ordered.append(appleMusic) }
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
    /// `statsId` (internal, default nil) — the id to RECORD as played when it differs from
    /// the resolving id: a variant play resolves under "<baseId>_clean" but history/stats/
    /// favorites must key the BASE song (the real catalog identity). Callers other than the
    /// id-convenience below pass nothing.
    func play(_ song: IndexSong, atMs: Int? = nil, statsId: String? = nil) async {
        lastErrorMessage = nil
        for provider in providers(for: song) {
            // Switching backends: stop the previously-active one so two engines don't both
            // play (e.g. Apple Music wins after a prior rip, or vice-versa).
            if let active = activeBackend, active != provider.backend {
                providerFor(active)?.stop()
            }
            if await provider.tryPlay(song, atMs: atMs) {
                activeBackend = provider.backend
                onPlay?(statsId ?? song.id, provider.backend)
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
                // OWNER-ONLY (integrity audit): the passive rip fan-out only fires for the
                // CATALOG OWNER. A hybrid user streaming from their subscription must never
                // silently enqueue a capture on the shared server keyed by a shared id — that
                // both mutates the owner's public bucket and runs work on their machine. When
                // per-user server auth lands, this widens back with the server enforcing scope.
                if isCatalogOwner(), provider.backend == .appleMusic,
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
    /// cue offset, threaded through exactly like `play(_:atMs:)`. `variant` (a cleanOnly
    /// substitution) plays the song UNDER ITS VARIANT identity — the minimal song's id
    /// becomes "<id>_clean|_explicit" and its `appleMusicId` the edition's catalog id —
    /// while `statsId` keeps history/stats keyed on the base song.
    func play(id: String, title: String, artist: String, atMs: Int? = nil,
              variant: SongVariant? = nil) async {
        let song = projectedSong(id: id, title: title, artist: artist, variant: variant)
        // A variant play resolves under its variant identity but must still SCORE as the
        // base song, so history/stats/favorites key the real catalog identity.
        await play(song, atMs: atMs, statsId: variant == nil ? nil : id)
    }

    /// The EXACT `IndexSong` the row-▶ path hands to the provider chain for `id`. Split out
    /// of `play(id:…)` so the projection is reachable from tests: everything the streaming
    /// side decides about EDITION is derived from these fields, and a projection that drops
    /// them makes `AppleMusicProvider.streamCandidates` offer a bare, unverified primary —
    /// which streams the clean cut with the prefer-explicit toggle on. Testing the pure
    /// resolver instead of this projection is exactly how that shipped once already.
    func projectedSong(id: String, title: String, artist: String,
                       variant: SongVariant?) -> IndexSong {
        if let variant {
            return IndexSong.minimal(id: SongVariant.variantId(id, variant),
                                     name: title, artist: artist,
                                     appleMusicId: variantAppleMusicIdOfSong(id, variant))
        }
        // Carry the catalog id (looked up) so the AM streaming provider is eligible — the
        // provider chain reads `appleMusicId` for a source-less streamable row — AND the
        // EDITION fields, without which `AppleMusicProvider.streamCandidates` can only ever
        // offer the primary id and the prefer-explicit preference silently does nothing.
        let ed = editionsOfSong(id)
        return IndexSong.minimal(id: id, name: title, artist: artist,
                                 appleMusicId: appleMusicIdOfSong(id),
                                 explicit: ed.explicit,
                                 appleMusicIdExplicit: ed.explicitId,
                                 appleMusicIdClean: ed.cleanId)
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
    ///
    /// BASE-ID TOLERANT, deliberately: an edition-substituted row streams under its VARIANT
    /// id ("sng_…_clean"/"_explicit") while every caller asks with the BASE id the row
    /// displays. Exact `==` left the gate closed for the whole track, so the deck's tonearm
    /// read the idle local engine's 0:00 all song and the artwork URL was never consulted —
    /// the "progress stuck at 0:00 / no art" pair on substituted streams. Same dual-id
    /// tolerance as `SetlistPlayer.Item.matches`; the base-id derivation can never match a
    /// DIFFERENT song.
    func isAppleMusicNowPlaying(_ songId: String) -> Bool {
        guard activeBackend == .appleMusic, let np = appleMusic.nowPlaying?.songId else { return false }
        return SongVariant.baseId(np) == SongVariant.baseId(songId)
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
