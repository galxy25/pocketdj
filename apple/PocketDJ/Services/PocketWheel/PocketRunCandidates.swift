import Foundation

/// Builds the run planner's candidate universe OFF the main actor: every PLAYABLE song (the
/// `InThePocketStore` playability rule — rip manifest / burned / Apple Music with a store id)
/// with its features (credit-artist keys, album, genre category, year, BPM, key, timbre) and its
/// hard collection memberships (add-time recency) plus a soft ≤ 0.6 membership for non-members of
/// the profile's collections that sound like them.
enum PocketRunCandidates {

    nonisolated static func build(songs: [String: IndexSong], albums: [String: IndexAlbum],
                                  availability: CollectorsPuzzleEngine.AudioAvailability,
                                  collections: ListeningPocketsCollections.Input,
                                  favorites: Set<String>,
                                  timbre: [String: SimilarityFamilies.TimbreVector],
                                  nowMs: Double) -> [String: PocketRunPlanner.Candidate] {
        var playable = Set(availability.ripManifest.keys).union(availability.burnedIds)
        if availability.canStreamAppleMusic {
            for s in songs.values where s.appleMusicId != nil { playable.insert(s.id) }
        }
        playable = playable.filter { songs[$0] != nil }
        // Hard memberships (the same flattening the wheel and the upload use).
        let flat = CollectionFlattener.flatten(collections.source)
        let adds = CollectionFlattener.addTimes(collections: flat, activity: collections.activity,
                                                pockets: collections.source.pockets,
                                                albumTracks: collections.source.albumTracks)
        var memberships: [String: [String: Double]] = [:]
        for c in flat {
            for s in c.songIds where playable.contains(s) {
                memberships[s, default: [:]][c.id] = PocketMomentEngine.membershipScale(adds[c.id]?[s], nowMs: nowMs)
            }
        }
        for s in favorites where playable.contains(s) {
            memberships[s, default: [:]][PocketWheelIds.favorites] = PocketMomentEngine.unknownAddScale
        }
        var genreByAlbum: [String: String?] = [:]
        var out: [String: PocketRunPlanner.Candidate] = [:]
        out.reserveCapacity(playable.count)
        for id in playable {
            guard let s = songs[id] else { continue }
            var genre: String?
            if let aid = s.albumId {
                if let g = genreByAlbum[aid] { genre = g } else {
                    let cat = Genre.category(albums[aid]?.genre)
                    genre = cat == Genre.other ? nil : cat.lowercased()
                    genreByAlbum[aid] = genre
                }
            }
            let keys = RecVersionIdentity.creditArtistKeys(s.artist)
            out[id] = PocketRunPlanner.Candidate(
                id: id, title: s.name, artist: s.artist, lengthMs: s.length,
                features: .init(artistKeys: keys.isEmpty ? [s.artist.lowercased()] : keys, album: s.albumId,
                                genre: genre, year: s.year, bpm: s.bpm, timbre: timbre[id]),
                camelot: s.camelot, memberships: memberships[id] ?? [:],
                startsInstantly: availability.burnedIds.contains(id))
        }
        return out
    }
}
