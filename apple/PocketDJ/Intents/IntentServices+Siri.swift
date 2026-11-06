import Foundation

// The 1.0.4 Siri operations: add a song to a collection by name, Now Playing Mix Mode on/off, and
// stems muted / unmuted by name. Same contract as the rest of `IntentServices`: the intent structs
// are adapters, everything observable happens here, and every operation goes through the SAME
// code path its in-app control uses —
//   • adds: `AddToActions` (the Add-to sheet / context menu's membership + add logic),
//   • Mix Mode: `SetlistPlayer.setMixMode` (the panel's Mix Mode capsule),
//   • stems: `SetlistPlayer.engageMix` → `NowPlayingDSP.setStemMode` / `toggleStemMute` (the
//     panel's Stems toggle + stem pads, which call exactly these in exactly this order).

extension IntentServices {

    // MARK: - "This song"

    /// The song "this song" means: the AUDIBLE owner's track. A Mix-tab session that owns the
    /// audio wins over a parked Now Playing set; otherwise the Now Playing track (playing or
    /// paused). nil when nothing is loaded anywhere.
    func currentSongId() -> String? {
        let p = setlistPlayer
        let npAudible = p.isRunning && p.isNowPlayingOwner
        if !npAudible, mix.isRunning || mix.autoMixing, let t = mix.nowPlaying { return t.songId }
        return p.currentSongId ?? mix.nowPlaying?.songId
    }

    /// An entity for a song id — catalog rows, or (a studio / not-in-catalog track) whatever the
    /// running queue knows about it.
    func songEntity(id: String) -> SongEntity? {
        if let s = app.songsById[id] { return SongEntity(s) }
        if let it = setlistPlayer.queue.first(where: { $0.id == id }) {
            return SongEntity(id: id, title: it.title, artist: it.artist)
        }
        if let t = mix.nowPlaying, t.songId == id { return SongEntity(id: id, title: t.title, artist: t.artist) }
        return nil
    }

    // MARK: - Song resolution

    /// Spoken title (optionally "by <artist>") → the catalog's best-tier songs, one per
    /// recording. The playing song and songs already in a collection win ties between copies.
    func matchSongs(_ query: String, limit: Int = 8) -> [IndexSong] {
        let current = currentSongId()
        let rows = songMatchRows()
        let members = collectionMemberIds()
        return IntentSongMatcher.rank(query, rows: rows,
                                      prefer: { $0 == current || members.contains($0) },
                                      limit: limit)
            .compactMap { app.songsById[$0.id] }
    }

    /// The matcher's pre-normalized catalog, rebuilt only when the catalog changes.
    private func songMatchRows() -> [IntentSongMatcher.Row] {
        if let c = songMatchCache, c.revision == app.catalogRevision, c.count == app.songs.count { return c.rows }
        let rows = app.songs.map(IntentSongMatcher.Row.init)
        songMatchCache = .init(revision: app.catalogRevision, count: app.songs.count, rows: rows)
        return rows
    }

    private func collectionMemberIds() -> Set<String> {
        var s = Set<String>()
        for p in collections.pockets { s.formUnion(p.songIds) }
        for pl in collections.playlists where pl.id != nowPlayingPlaylistId {
            s.formUnion(collections.playlistSongIdSet(pl.id))
        }
        return s
    }

    // MARK: - Add a song to a collection

    struct AddToCollectionResult: Equatable {
        let songTitle: String
        let collectionName: String
        /// The song was ALREADY in the collection — nothing was written (toggle semantics: the
        /// Add sheet shows a ✓ there and a tap would REMOVE; Siri never removes, it says so).
        let alreadyMember: Bool

        var dialog: String {
            alreadyMember ? "\(songTitle) is already in \(collectionName)."
                          : "Added \(songTitle) to \(collectionName)."
        }
    }

    /// Add `songId` (nil ⇒ the song playing now) to the collection `collectionId` names
    /// (`CollectionEntity.id`). Lands exactly where the Add-to sheet's row tap lands it: a pocket's
    /// membership, or a playlist's FIRST (default) chapter — through `AddToActions.add`, so the
    /// Recent row, History ▸ Activity and Apple Music write-back all see a normal add.
    @discardableResult
    func addSongToCollection(songId: String?, collectionId: String) async throws -> AddToCollectionResult {
        try vetoDuringOnboarding()
        await ensureReady()
        guard let id = songId ?? currentSongId() else { throw PocketDJIntentError.nothingPlaying }
        guard let song = songEntity(id: id) else { throw PocketDJIntentError.songNotFound }
        guard var target = CollectionEntity.addTarget(from: collectionId) else {
            throw PocketDJIntentError.collectionNotFound
        }
        let name: String
        switch target.kind {
        case .pocket:
            guard let p = collections.pocket(target.id) else { throw PocketDJIntentError.collectionNotFound }
            name = p.name
        case .playlist:
            guard target.id != nowPlayingPlaylistId, let pl = collections.playlist(target.id) else {
                throw PocketDJIntentError.collectionNotFound
            }
            name = pl.name
            target.sequenceId = pl.sequences.first?.nodeId    // the sheet's row-tap chapter
        }
        let actions = AddToActions(item: .song(id), collections: collections)
        if actions.isMember(target) {
            return AddToCollectionResult(songTitle: song.title, collectionName: name, alreadyMember: true)
        }
        actions.add(target, donate: false)
        DiagLog.shared.telemetry("action", "siri add song=\(id) target=\(target.kind.rawValue):\(target.id)")
        return AddToCollectionResult(songTitle: song.title, collectionName: name, alreadyMember: false)
    }

    // MARK: - Play a collection

    /// ▶/🔀 a `CollectionEntity` id (pocket or playlist) — the existing per-kind play doors.
    @discardableResult
    func playCollection(id: String, shuffle: Bool) async throws -> String {
        guard let t = CollectionEntity.addTarget(from: id) else { throw PocketDJIntentError.collectionNotFound }
        switch t.kind {
        case .pocket: return try await playPocket(id: t.id, shuffle: shuffle)
        case .playlist: return try await playPlaylist(id: t.id, shuffle: shuffle)
        }
    }

    // MARK: - Now Playing Mix Mode

    /// Turn the Now Playing session's Mix Mode on/off — the panel's Mix Mode capsule
    /// (`SetlistPlayer.setMixMode`). Returns the sentence Siri says.
    @discardableResult
    func setNowPlayingMixMode(_ on: Bool) throws -> String {
        guard SetlistPlayer.mixModeSupported else { throw PocketDJIntentError.mixModeUnsupported }
        let p = setlistPlayer
        guard p.isRunning else { throw PocketDJIntentError.nothingPlaying }
        guard p.mixMode.enabled != on else { return on ? "Mix Mode is already on." : "Mix Mode is already off." }
        p.setMixMode(on)
        guard on else { return "Mix Mode is off." }
        if mix.isRunning || mix.autoMixing { return "Mix Mode is on. It starts buffering once the Mix tab stops." }
        return "Mix Mode is on — buffering this song and the next ones so stems and effects work on them."
    }

    // MARK: - Stems by name

    /// Mute or unmute one stem of the Now Playing track, mirroring the mini-mix panel: a mute
    /// first turns Mix Mode on (when off), engages the DSP (`engageMix`, the first-touch
    /// hand-off), puts the Stems toggle on (`setStemMode(true)`), then mutes the pad
    /// (`toggleStemMute`). An unmute only ever touches a stem that IS muted. Returns the sentence
    /// Siri says; throws only when there is nothing to act on.
    @discardableResult
    func setStem(_ stem: StemPart, muted: Bool) throws -> String {
        let p = setlistPlayer
        guard p.isRunning else { throw PocketDJIntentError.nothingPlaying }
        // One DSP surface at a time: with the Mix tab live the Now Playing mini-mix is off
        // (`mixAvailable(mixActive:)`), exactly as the panel hides its controls.
        guard !(mix.isRunning || mix.autoMixing) else { throw PocketDJIntentError.mixTabLive }
        guard let dsp = p.dsp else { throw PocketDJIntentError.stemsUnavailable("Stems aren't available on this device.") }
        let name = stem.stemName

        if !muted {
            guard p.mixEngaged, dsp.stemMode || dsp.stemsLoading, dsp.isStemMuted(name) else {
                return "\(stem.spoken.capitalizedFirst) \(stem == .bass ? "is" : "are") already playing."
            }
            dsp.toggleStemMute(name)
            return "Unmuted \(stem.spoken)."
        }

        if p.mixEngaged, dsp.stemMode || dsp.stemsLoading, dsp.isStemMuted(name) {
            return "\(stem.spoken.capitalizedFirst) \(stem == .bass ? "is" : "are") already muted."
        }
        var turnedOn = false
        if SetlistPlayer.mixModeSupported, !p.mixMode.enabled {
            p.setMixMode(true)                      // the NP capsule — buffers this + upcoming
            turnedOn = true
        }
        let lead = turnedOn ? "Mix Mode is on, but " : ""
        guard p.mixAvailable(mixActive: false) else {
            // Why the panel's controls aren't live yet — its own status chip, in words.
            let why = p.mixModeIndicator.chipText ?? "this song isn't on the device"
            switch p.mixModeIndicator {
            case .buffering, .holding, .waiting, .ripping, .rippingEdition:
                return "\(lead)I can't mute \(stem.spoken) yet — this song is still downloading (\(why)). Ask again in a moment."
            default:
                return "\(lead)I can't mute \(stem.spoken) on this song: \(why)."
            }
        }
        p.engageMix()
        guard p.mixEngaged else {
            return "\(lead)I couldn't open this song for mixing, so \(stem.spoken) can't be muted."
        }
        if !dsp.stemMode, !dsp.stemsLoading {
            guard dsp.setStemMode(true) else {
                return "\(lead)this song has no stems yet, so \(stem.spoken) can't be muted."
            }
        }
        if !dsp.isStemMuted(name) { dsp.toggleStemMute(name) }
        let done = turnedOn ? "Turned on Mix Mode and muted \(stem.spoken)" : "Muted \(stem.spoken)"
        return dsp.stemsLoading ? "\(done) — the stems are loading, so it takes effect in a moment." : "\(done)."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
