import Foundation

/// One LOADABLE deck candidate — a song that is actually present on disk as a BURNED file
/// (so a deck's AVAudioFile can open it). Notes/text/un-burned songs never become a
/// MixLoadable (the resolver drops them — "degrade gracefully"). Snapshot metadata is inlined so
/// the picker row reads standalone, exactly like a setlist freezes its tracks.
struct MixLoadable: Identifiable, Hashable {
    let songId: String
    let title: String
    let artist: String
    let bpm: Double?
    let camelot: String?
    let key: String?
    let albumId: String?
    let lengthMs: Int?      // song length (ms) — bounds an analog shared-album fallback to its slice
    var id: String { songId }
}

/// Resolves a chosen `MixSource` into the ordered list of LOADABLE `MixLoadable`s. @MainActor —
/// it reads the `@Observable` stores. A plain value type (no state); the Mix loader sheet builds
/// one per call from the env stores.
@MainActor
struct MixResolver {
    let app: AppModel
    let collections: CollectionsStore
    let burns: BurnStore
    /// Studio store — resolves PERFORMANCE ITEMS (`smp_`/`lp_`/`ptn_`/`tk_`), which have no
    /// BurnStore file, into loadable decks with their on-device beat grid + detected key.
    let studio: StudioStore

    /// Ordered LOADABLE items for a deck source. Pocket → DAG-resolved song ids; playlist →
    /// catalog-resolved song ids (albums/pockets expanded, same walk playback already uses —
    /// task #61: no materialization into a pocket/setlist needed); setlist → frozen tracks
    /// (snapshot metadata). Keeps ONLY ids whose burned file (or studio file) exists on disk
    /// (drops notes/text/un-burned). Deduped by songId, first-seen wins.
    func loadables(for source: MixSource) -> [MixLoadable] {
        switch source {
        case .pocket(let id):   return loadables(songIds: collections.playableIds(forPocket: id))
        case .playlist(let id): return loadables(songIds: collections.playableIds(forPlaylist: id))
        case .setlist(let id):  return setlistLoadables(id)
        }
    }

    /// A pocket (or any ordered id list): resolve each id against the catalog (or the studio store
    /// for a performance item), keep loadables.
    private func loadables(songIds: [String]) -> [MixLoadable] {
        var seen = Set<String>()
        return songIds.compactMap { id -> MixLoadable? in
            guard seen.insert(id).inserted else { return nil }
            if StudioFactory.isStudioId(id) { return studioLoadable(id) }
            if ProfileSourceStore.isProfileSongId(id) { return profileLoadable(id) }
            guard let song = app.songsById[id], isLoadable(id) else { return nil }
            return MixLoadable(songId: id, title: song.name, artist: song.artist,
                               bpm: song.bpm, camelot: song.camelot, key: song.key, albumId: song.albumId,
                               lengthMs: song.length)
        }
    }

    /// A performance item → a MixLoadable carrying its bpm (constant beat grid) + detected key
    /// (Camelot, for glide). Loadable iff its local audio resolves; artist is the user's PocketDJ
    /// name (`collections.studioArtist`).
    private func studioLoadable(_ id: String) -> MixLoadable? {
        guard let h = studio.localURLForPlayback(id: id) else { return nil }
        h.release?()   // existence check only — the deck re-acquires a held handle when it loads
        guard let info = studio.displayInfo(forStudioId: id) else { return nil }
        return MixLoadable(songId: id, title: info.title, artist: collections.studioArtist,
                           bpm: info.bpm, camelot: studio.camelot(forStudioId: id),
                           key: nil, albumId: nil, lengthMs: info.lengthMs)
    }

    /// A "Pocket DJ" profile item → a MixLoadable from its catalog row, loadable iff its ORIGINAL
    /// asset is on THIS device. `pdj_` items ARE full `songsById` citizens (injectProfileItem), so
    /// this reads them like a catalog song — no BurnStore file, no studio seam.
    private func profileLoadable(_ id: String) -> MixLoadable? {
        guard app.profileSource?.hasLocalAsset(id) == true, let song = app.songsById[id] else { return nil }
        return MixLoadable(songId: id, title: song.name, artist: song.artist,
                           bpm: song.bpm, camelot: song.camelot, key: song.key, albumId: song.albumId,
                           lengthMs: song.length)
    }

    /// A setlist: iterate FROZEN tracks in order (snapshots carry artist/name/bpm/camelot),
    /// skipping text cues + blanks, keeping loadables. Falls back to the catalog for albumId +
    /// key (snapshots don't store them) and any field the snapshot left nil.
    private func setlistLoadables(_ setlistId: String) -> [MixLoadable] {
        guard let setlist = collections.setlist(setlistId) else { return [] }
        var seen = Set<String>()
        return setlist.tracks.compactMap { t -> MixLoadable? in
            guard t.isText != true, !t.songId.isEmpty, seen.insert(t.songId).inserted else { return nil }
            if StudioFactory.isStudioId(t.songId) {
                // Frozen studio track: prefer its live studio resolution; fall back to the snapshot
                // camelot/bpm if the item was deleted but the snapshot survives.
                if let l = studioLoadable(t.songId) { return l }
                return nil
            }
            if ProfileSourceStore.isProfileSongId(t.songId) { return profileLoadable(t.songId) }
            guard isLoadable(t.songId) else { return nil }
            let song = app.songsById[t.songId]
            return MixLoadable(songId: t.songId,
                               title: t.name.isEmpty ? (song?.name ?? t.songId) : t.name,
                               artist: t.artist.isEmpty ? (song?.artist ?? "") : t.artist,
                               bpm: t.bpm ?? song?.bpm,
                               camelot: t.camelot ?? song?.camelot,
                               key: song?.key,
                               albumId: song?.albumId,
                               lengthMs: t.lengthMs ?? song?.length)
        }
    }

    /// A song is loadable IFF its burned file exists on disk. Uses the NON-HOLDING existence
    /// check (`BurnStore.localURL`) so enumerating a long source never opens N security scopes —
    /// the deck re-acquires a HELD handle (`localURLForPlayback`) only when it actually loads.
    private func isLoadable(_ songId: String) -> Bool { burns.localURL(forSong: songId) != nil }
}
