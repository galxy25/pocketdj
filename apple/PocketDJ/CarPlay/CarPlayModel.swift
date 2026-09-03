import Foundation

/// The template-agnostic heart of the CarPlay app: it turns the shared stores into the row lists
/// CarPlay browses (Playlists / Pockets / For You → songs) and routes
/// the two write actions — play a collection/song, add a song to a pocket/playlist.
///
/// Deliberately free of any `CarPlay` import, so it unit-tests on the plain test host and compiles
/// on every platform; the CarPlay scene (iOS-only) is a THIN adapter that maps these `Row`s to
/// CPListTemplate / CPListItem and fetches thumbnails. All playback routes through the SAME unified
/// sequencer the rest of the app uses (via `IntentServices`), so CarPlay shares one Now-Playing.
@MainActor
final class CarPlayModel {

    /// One browsable/actionable row. `id` is a collection id, album id, or (for song rows) a song
    /// id; add-to target rows encode the kind as a `pkt:`/`pls:` prefix.
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String?
        /// Album id to resolve a thumbnail from (nil → generic icon).
        let artworkAlbumId: String?
        /// True for a CATALOG SONG row — one with an `IndexSong` behind it.
        ///
        /// False covers two different things and the distinction matters at the action sheet: a
        /// drill-in row (a playlist, a For You tile), and a For You **release** row, which IS
        /// playable but is a record the owner does not own. Only a true `isSong` row can be added
        /// to a pocket or playlist, because only it has a song id to add.
        let isSong: Bool
    }

    let services: IntentServices
    private var app: AppModel { services.app }
    private var collections: CollectionsStore { services.collections }

    init(services: IntentServices) { self.services = services }

    /// Make the catalog usable before building lists (the scene can connect before it's warm).
    ///
    /// Restores the durable session FIRST, and deliberately before the catalog await: the restore
    /// is self-contained (title/artist ride the snapshot) so it does not need a warm catalog, and
    /// doing it first means the root template is built with the resumable set already known — no
    /// second template pass, no O(catalog) rebuild on the main actor.
    func ensureReady() async {
        services.restorePlaybackSessionIfIdle()
        await services.ensureReady()
    }

    /// A restored-but-not-yet-playing set the driver can resume, or nil. Drives the one-shot
    /// "Continue" row at the top of the CarPlay root — the affordance that makes the restore
    /// reachable without the phone.
    func resumableSession() -> Row? {
        let p = services.setlistPlayer
        guard p.isRunning, p.isHeldForResume, p.queue.indices.contains(p.index) else { return nil }
        let item = p.queue[p.index]
        let artist = item.artist.trimmingCharacters(in: .whitespaces)
        return Row(id: "resume:\(item.uid)", title: item.title,
                   subtitle: artist.isEmpty ? "Continue" : "\(artist) · Continue",
                   artworkAlbumId: firstAlbumId([item.id]), isSong: true)
    }

    /// Resume the held set (the "Continue" row's action). No-op when nothing is held.
    func resumeHeldSession() {
        let p = services.setlistPlayer
        guard p.isRunning, p.isHeldForResume else { return }
        p.resumeFromHold()
    }

    // MARK: - Browse lists

    /// All browsable playlists: the user's PocketDJ playlists AND the catalog's source playlists
    /// (Apple Music / iTunes mirrors, from `app.indexPlaylists`) — source rows are id-prefixed
    /// "src:" and carry a source badge in the subtitle.
    func playlists() -> [Row] {
        let mine = collections.playlists.map { pl -> Row in
            let ids = collections.playableIds(forPlaylist: pl.id)
            return Row(id: pl.id, title: pl.name, subtitle: songsSubtitle(resolvedCount(ids)),
                       artworkAlbumId: firstAlbumId(ids), isSong: false)
        }
        let source = app.indexPlaylists.map { sp -> Row in
            Row(id: "src:\(sp.id)", title: sp.name,
                subtitle: "\(songsSubtitle(resolvedCount(sp.songIds))) · \(sp.sourceName)",
                artworkAlbumId: firstAlbumId(sp.songIds), isSong: false)
        }
        return mine + source
    }

    private func sourcePlaylist(_ rowId: String) -> SourcePlaylist? {
        guard rowId.hasPrefix("src:") else { return nil }
        let realId = String(rowId.dropFirst(4))
        return app.indexPlaylists.first { $0.id == realId }
    }

    func pockets() -> [Row] {
        collections.pockets.map { pk in
            let ids = collections.playableIds(forPocket: pk.id)
            return Row(id: pk.id, title: pk.name, subtitle: songsSubtitle(resolvedCount(ids)),
                       artworkAlbumId: firstAlbumId(ids), isSong: false)
        }
    }

    // ── THERE IS NO `albums()` / `artists()` ANY MORE ────────────────────────────────────────
    // The CarPlay tab bar is Playlists · Pockets · For You. Owner, verbatim: *"in CarPlay replace
    // artists & albums (if both exist, otherwise replace what does so we only have Playlists,
    // Pockets & For You) with For You"*. Both existed, so both went, and the browse lists that
    // existed ONLY to fill those two tabs (`albums`, `artists`, `albums(byArtist:)`,
    // `songs(byArtist:)`, `songs(inAlbum:)`, `playArtist`, `playAlbum`) went with them rather than
    // staying behind as unreachable code that still has to compile and still looks supported.
    //
    // Nothing was lost that the car can still reach: an album or an artist is a KEYBOARD search
    // away on the phone, and hands-free it is one App Intent away ("play Night Drive in PocketDJ").
    // The A–Z quick-scroll those tabs carried was the keyboard-free way to find a record; For You
    // answers the question that actually comes up while driving — *what should I put on* — which is
    // the trade the owner asked for.

    func songs(inPlaylist id: String) -> [Row] {
        if let sp = sourcePlaylist(id) { return songRows(sp.songIds) }
        return songRows(collections.playableIds(forPlaylist: id))
    }
    func songs(inPocket id: String) -> [Row] { songRows(collections.playableIds(forPocket: id)) }

    // MARK: - Play (all through the one unified sequencer)

    func playPlaylist(id: String, shuffle: Bool = false) async {
        if let sp = sourcePlaylist(id) {
            try? await services.playSongIds(sp.songIds, name: sp.name, shuffle: shuffle, source: .playlist)
        } else {
            try? await services.playPlaylist(id: id, shuffle: shuffle)
        }
    }
    func playPocket(id: String, shuffle: Bool = false) async { try? await services.playPocket(id: id, shuffle: shuffle) }
    func playSong(id: String) async { try? await services.playSong(id: id) }

    // MARK: - Add-to (pocket / playlist)

    /// Add-to destinations: pockets then playlists, each with a kind-prefixed target id.
    func addTargets() -> [Row] {
        collections.pockets.map { Row(id: "pkt:\($0.id)", title: $0.name, subtitle: "Pocket", artworkAlbumId: nil, isSong: false) }
        + collections.playlists.map { Row(id: "pls:\($0.id)", title: $0.name, subtitle: "Playlist", artworkAlbumId: nil, isSong: false) }
    }

    /// Add `songId` to the target encoded by `addTargets` (a `pkt:`/`pls:`-prefixed id). Playlists
    /// append to the default chapter. Returns the target's display name (for a confirmation), or
    /// nil for an unknown/deleted target.
    @discardableResult
    func addSong(_ songId: String, toTargetId targetRowId: String) -> String? {
        if let id = strip(targetRowId, "pkt:"), let p = collections.pocket(id) {
            collections.addSong(songId, to: AddTarget(kind: .pocket, id: id))
            return p.name
        }
        if let id = strip(targetRowId, "pls:"), let pl = collections.playlist(id) {
            collections.addSong(songId, to: AddTarget(kind: .playlist, id: id))
            return pl.name
        }
        return nil
    }

    // MARK: - Up Next (the running sequencer's upcoming queue)

    /// One upcoming row. Identified by `uid` (a song can repeat in the queue), matching how
    /// SetlistPlayer's live-queue edits key rows.
    struct UpNextItem: Identifiable, Equatable {
        let uid: UUID
        let title: String
        let artist: String
        let albumId: String?
        var id: UUID { uid }
    }

    /// The tracks after the current one in the running set (empty when nothing/queue-less is playing).
    /// WINDOWED to 200: CPListTemplate truncates around its own item cap anyway, and building
    /// a CPListItem (plus an album-art lookup) for all 26k rows of a huge set would stall the
    /// head-unit push. 200 covers hours of listening; the list refreshes as the set advances.
    func upNext() -> [UpNextItem] {
        services.setlistPlayer.upcoming.prefix(200).map {
            UpNextItem(uid: $0.uid, title: $0.title, artist: $0.artist, albumId: app.songsById[$0.id]?.albumId)
        }
    }

    /// The track the sequencer is currently ON (nil when idle). CarPlay's SYSTEM Now Playing
    /// card is fed by whichever engine owns the audio (MusicKit for Apple Music, `PlayerEngine`
    /// for rips/burns) — but PocketDJ's OWN CarPlay UI otherwise has no "now playing" cue: the
    /// Up Next list starts at the NEXT track. So a set started from the phone (e.g. shuffling an
    /// Apple Music playlist) shows a correct upcoming queue with no in-app marker of what's
    /// playing right now. This pins that current track above the queue. Read straight off
    /// `queue[index]` (not `rips.nowPlaying`, which the Apple Music path never sets).
    func nowPlaying() -> UpNextItem? {
        let p = services.setlistPlayer
        guard p.isRunning, p.index < p.queue.count else { return nil }
        let it = p.queue[p.index]
        return UpNextItem(uid: it.uid, title: it.title, artist: it.artist, albumId: app.songsById[it.id]?.albumId)
    }

    /// The current track's song id (nil when idle) — the identity every favorite op keys on.
    /// Read straight off `queue[index]` like `nowPlaying()`, so it's correct for an Apple Music
    /// set too (which never sets `rips.nowPlaying`).
    private func currentSongId() -> String? {
        let p = services.setlistPlayer
        guard p.isRunning, p.index < p.queue.count else { return nil }
        return p.queue[p.index].id
    }

    // MARK: - Favorite (the ♥ on the CarPlay Now Playing template)

    /// Is the currently-playing track favorited? Drives the heart button's filled/outline glyph.
    /// False when nothing is playing.
    func isCurrentFavorite() -> Bool {
        guard let id = currentSongId() else { return false }
        return services.favorites.isFavorite(id)
    }

    /// Flip the current track's favorite — resolves its Apple Music catalog id (nil for vinyl /
    /// My Digital / Studio, still favorited local-only) and calls `FavoritesStore.toggle`, whose
    /// `onChanged` reaches Apple Music only for an owner install carrying a catalog id. A no-op
    /// when nothing is playing.
    func toggleCurrentFavorite() {
        guard let id = currentSongId() else { return }
        services.favorites.toggle(id, appleMusicId: app.songsById[id]?.appleMusicId)
    }

    // MARK: - 👍 / 👎 on the CarPlay Now Playing template

    /// The current track's verdict, or nil when nothing is playing / no verdict is set — drives
    /// which of the two thumb glyphs renders filled.
    ///
    /// CarPlay is the purest case of the SYNC half of the tuning loop: the driver hears a
    /// suggestion and judges it without leaving playback, hands on the wheel. It writes the SAME
    /// `RecFeedbackStore` row the tile writes, so the decision is already there when the tile is
    /// next opened on the phone.
    func currentFeedback() -> RecFeedbackStore.Verdict? { services.currentRecVerdict() }

    /// Is the running queue a recommendation at all? CarPlay shows the pair only then — there is
    /// no list to sink a song in otherwise, so the buttons would be inert, and the Now Playing
    /// template's five-button budget is too tight to spend on inert controls.
    func isRecQueue() -> Bool { services.currentRecTarget() != nil }

    /// Record 👍 / 👎 for the current track. Tapping the already-lit control clears it (the same
    /// `toggle` semantics every other surface uses — one function, so the car and the phone cannot
    /// disagree about what a second tap means, and a driver's instinctive second tap is the undo).
    ///
    /// DOES NOT SKIP. A rejection is a statement about the recommendation, not a transport
    /// command; auto-skipping on a mis-tap in a moving car is exactly the wrong failure mode, and
    /// CarPlay already has a ⏭ six inches away for the other intent.
    ///
    /// Routed through `IntentServices` rather than reaching the store directly, so the car, the
    /// widget and the lock screen are provably ONE code path.
    @discardableResult
    func recordCurrentFeedback(_ verdict: RecFeedbackStore.Verdict) -> RecFeedbackStore.Verdict? {
        services.recordNowPlayingFeedback(verdict, surface: .carPlay)
    }

    // MARK: - CarPlay repeat / shuffle (mirror the Now Playing deck + widget)

    /// Whether a set is running — CarPlay shows the repeat + shuffle buttons only then (they're
    /// meaningless for a single-track play, matching the in-app deck + widget gating).
    func isSetRunning() -> Bool { services.setlistPlayer.isRunning }
    /// Live shuffle of the running queue's upcoming tail.
    func isShuffleOn() -> Bool { services.setlistPlayer.shuffleEnabled }
    func toggleShuffle() { services.setlistPlayer.toggleShuffle() }
    /// Whole-session repeat mode (off / all / one).
    func repeatMode() -> RepeatMode { services.setlistPlayer.repeatMode }
    func cycleRepeat() { services.setlistPlayer.cycleRepeatMode() }

    func removeFromQueue(uid: UUID) { services.setlistPlayer.removeUpcoming(uids: [uid]) }
    func playNext(uid: UUID) { services.setlistPlayer.moveUpcomingNext(uid: uid) }
    func moveToEnd(uid: UUID) { services.setlistPlayer.moveUpcomingToEnd(uid: uid) }
    /// "Play now" on an Up Next row — shift playback to exactly that queue row.
    func jump(uid: UUID) { services.setlistPlayer.jumpToUpcoming(uid: uid) }

    // MARK: - Mix (two-crate Auto DJ — the Mix tab)

    /// A pickable crate for a Mix deck: pockets + set lists, the two `MixSource` kinds
    /// (playlists must become set lists first — same rule as the phone's Mix tab).
    struct MixCrate: Identifiable, Equatable {
        let id: String            // MixSource.id encoding ("pocket:<id>" / "setlist:<id>")
        let title: String
        let source: MixSource
    }

    func mixCrates() -> (pockets: [MixCrate], setlists: [MixCrate]) {
        (collections.pockets.map {
            MixCrate(id: MixSource.pocket($0.id).id, title: $0.name, source: .pocket($0.id))
        },
         collections.visibleSetlists.map {
            MixCrate(id: MixSource.setlist($0.id).id, title: $0.name ?? "Set list", source: .setlist($0.id))
        })
    }

    func crateName(_ source: MixSource?) -> String? {
        switch source {
        case .pocket(let id):  return collections.pocket(id)?.name
        case .setlist(let id): return collections.setlist(id)?.name ?? "Set list"
        case nil:              return nil
        }
    }

    // Live mix state the template renders from.
    func autoMixRunning() -> Bool { services.mix.autoMixing }
    func autoMixPaused() -> Bool { services.mix.autoPaused }
    func autoMixLabel() -> String? { services.mix.autoSourceLabel }
    func mixNowPlaying() -> (title: String, artist: String)? {
        services.mix.onAirTrack.map { ($0.title, $0.artist) }
    }
    func fxGlideOn() -> Bool { services.mix.fxGlideEnabled }
    func audioGlideOn() -> Bool { services.mix.mixGlideEnabled }
    func setFXGlide(_ on: Bool) { services.mix.setFXGlide(on) }
    func setAudioGlide(_ on: Bool) { services.mix.setMixGlide(on) }

    enum MixStart { case playing, downloading, failed(String) }

    /// Start the two-crate SHUFFLED Auto DJ (deck B nil ⇒ same crate on both decks — the
    /// ordinary single-source mix). The car's mix is always shuffled auto-mix: no manual deck
    /// loading, no song picking — that is the surface's contract, not a missing feature.
    /// `.downloading` = the zero-start armed (nothing on disk yet; the first landing starts
    /// the mix), same contract as the phone's Mix tab.
    func startMix(deckA: MixSource, deckB: MixSource?) async -> MixStart {
        do {
            let (_, count) = try await services.startAutoMix(deckA: deckA, deckB: deckB ?? deckA,
                                                             shuffle: true, allowPendingStart: true)
            return count == 0 ? .downloading : .playing
        } catch {
            return .failed(String(localized: (error as? PocketDJIntentError)?.localizedStringResource
                ?? "That can’t start a mix right now."))
        }
    }

    /// Download-run readout for the Mix tab (nil when idle or complete).
    func mixDownloadState() -> (downloaded: Int, total: Int)? {
        guard let d = services.mixDownloader, d.isActive,
              d.downloadedCount < d.totalCount else { return nil }
        return (d.downloadedCount, d.totalCount)
    }

    /// Whole-mix transport — exclusively the lock-screen seam: `remotePause` is the ONE pause
    /// that silences both decks AND freezes the transition wall clock (in-app `pauseBoth` would
    /// END a running Auto-DJ), and `remoteSkip` un-suspends a paused machine before sweeping.
    func pauseMix() { services.mix.remotePause() }
    func resumeMix() {
        let m = services.mix
        m.remotePlay()
        // The lock-screen ▶ deliberately never resumes an IN-APP (hand-mixing) pause — its play
        // gesture is ambiguous. This surface's row literally says "Resume Mix", so a machine
        // still suspended after remotePlay (the phone's `pauseAuto` state, which remotePlay's
        // three steps each no-op on) resumes explicitly; without this the row was a dead
        // control whenever the pause originated in-app.
        if m.autoMixing, m.autoPaused { m.resumeAuto() }
    }
    /// FAST skip: the 5 s sweep (the lock-screen ⏭ precedent).
    func skipMixFast() { services.mix.remoteSkip(fadeSeconds: 5) }
    /// SLOW skip: the long blend (`skipFadeSeconds`, default 15 s — the lock-screen ⏮ mapping).
    func skipMixSlow() { services.mix.remoteSkip(fadeSeconds: services.settings.skipFadeSeconds) }
    /// The slow skip's length, for the row's detail text.
    func slowSkipSeconds() -> Double { services.settings.skipFadeSeconds }
    func stopMix() { services.mix.stopAutoMix() }

    /// Surface-open hook: a durable mix session restored at launch stays PARKED until a Mix
    /// surface materializes it (cued + suspended, never self-playing). The car is such a
    /// surface — same contract as MixView's `.task`.
    func materializeMixRestoreIfNeeded() { services.mix.materializePendingRestoreIfNeeded() }

    // MARK: - Artwork (URLs; the CarPlay adapter fetches → UIImage)

    /// Bundled candidates, else the streaming fallback through the bridge — the answer that was
    /// missing here is exactly why covers were "usually missing" in the car: the dominant
    /// "Apple Music (Local)" catalog ships NO `artCandidates`, and only the in-app `CoverImage`
    /// knew the fallback lane.
    func artURLs(albumId: String?) async -> [URL] {
        guard let albumId else { return [] }
        return await services.artworkURLs(forAlbumId: albumId)
    }

    // MARK: - Helpers

    private func strip(_ s: String, _ prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
    }
    private func songRows(_ ids: [String]) -> [Row] { ids.compactMap { app.songsById[$0] }.map { songRow($0) } }
    /// Count of ids that resolve to a CATALOG song — i.e. the rows the drill-in list actually
    /// renders. (playableIds also keeps STUDIO ids, which have no IndexSong and are dropped from
    /// the list, so counting playableIds directly would overstate the row count.)
    private func resolvedCount(_ ids: [String]) -> Int { ids.reduce(0) { app.songsById[$1] != nil ? $0 + 1 : $0 } }
    private func songRow(_ s: IndexSong) -> Row {
        Row(id: s.id, title: s.name, subtitle: s.artist, artworkAlbumId: s.albumId, isSong: true)
    }
    private func firstAlbumId(_ songIds: [String]) -> String? {
        for id in songIds { if let a = app.songsById[id]?.albumId { return a } }
        return nil
    }
    private func songsSubtitle(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }
}
