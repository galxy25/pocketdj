import Foundation
import CryptoKit

/// POCKETS × COLLECTIONS — the upload half (docs/design/pockets-collections.md): the flattened
/// membership snapshot + the song-level add history, built from the same flattening the rec
/// engine's snapshot uses (`CollectionFlattener`). PURE — values in, values out.
///
/// Privacy: ids only. Collection NAMES never reach this wire (the server titles nothing with
/// them; the app re-labels `collection` features on device).
enum ListeningPocketsCollections {

    /// Everything the builder reads — the app wires one closure that produces it, shared by the
    /// upload and by "In the Pocket".
    struct Input: Sendable {
        var source: CollectionFlattener.Source
        var activity: [CollectionActivityStore.ActivityEvent]

        init(source: CollectionFlattener.Source = .init(), activity: [CollectionActivityStore.ActivityEvent] = []) {
            self.source = source; self.activity = activity
        }
    }

    struct Payload: Equatable {
        var collections: [ListeningPocketsCollectionWire]
        var addEvents: [ListeningPocketsAddEventWire]
        /// Content hash over both lists (no timestamps of the send) — the re-send gate.
        var hash: String
        var isEmpty: Bool { collections.isEmpty && addEvents.isEmpty }
    }

    // MARK: - Caps (mirror rec-engine cleanSnapshot)

    static let collectionCap = 500
    static let songCap = 5_000
    static let totalSongCap = 100_000
    static let addEventsCap = 5_000
    static let addEventsWindowDays: Double = 365
    /// Re-send an unchanged snapshot at least this often (the server's copy may have been dropped).
    static let resendAfterMs: Double = 24 * 3_600_000
    /// Keep the encoded payload well under the server's 4 MB body ceiling.
    static let byteCap = 3_500_000

    /// The flattened, capped membership. A SOURCE playlist bigger than one collection's cap is a
    /// library-sized "everything" list, not a vibe — it is left out rather than truncated (and
    /// would otherwise spend the whole-snapshot budget). Pockets and playlists come first, so the
    /// user's own collections always fit.
    static func flattened(_ source: CollectionFlattener.Source) -> [CollectionFlattener.Collection] {
        var src = source
        src.sourcePlaylists = source.sourcePlaylists.filter { $0.songIds.count <= songCap }
        return CollectionFlattener.capped(CollectionFlattener.flatten(src), collectionCap: collectionCap,
                                          songCap: songCap, totalCap: totalSongCap)
    }

    /// The capped, flattened membership + add history. `floorMs` (the "Delete cloud data" floor)
    /// bounds the add history from below on top of the 365-day window.
    static func build(_ input: Input, nowMs: Double, floorMs: Double = 0) -> Payload {
        let flat = flattened(input.source)
        let adds = CollectionFlattener.addTimes(collections: flat, activity: input.activity,
                                                pockets: input.source.pockets,
                                                albumTracks: input.source.albumTracks)
        let collections = flat.map { c -> ListeningPocketsCollectionWire in
            let a = adds[c.id] ?? [:]
            return ListeningPocketsCollectionWire(
                id: c.id, kind: c.kind, songIds: c.songIds,
                adds: c.songIds.compactMap { s in a[s].map { .init(songId: s, atMs: Int64($0)) } })
        }
        let since = max(nowMs - addEventsWindowDays * 86_400_000, floorMs)
        let events = CollectionFlattener.addEvents(activity: input.activity, pockets: input.source.pockets,
                                                   albumTracks: input.source.albumTracks,
                                                   sinceMs: since, cap: addEventsCap)
            .map { ListeningPocketsAddEventWire(songId: $0.songId, collectionId: $0.collectionId,
                                                atMs: Int64($0.atMs), kind: $0.kind) }
        return Payload(collections: collections, addEvents: events, hash: hash(collections, events))
    }

    static func hash(_ collections: [ListeningPocketsCollectionWire], _ events: [ListeningPocketsAddEventWire]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(collections.count + 1)
        for c in collections {
            let adds = c.adds.map { "\($0.songId)@\($0.atMs)" }.joined(separator: ",")
            lines.append("c|\(c.id)|\(c.kind)|\(c.songIds.joined(separator: ","))|\(adds)")
        }
        lines.sort()
        lines.append("e|" + events.map { "\($0.songId)|\($0.collectionId)|\($0.atMs)|\($0.kind)" }.joined(separator: ";"))
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Is a payload with `hash` due? Changed content, or the last send is ≥ 24 h old.
    static func isDue(hash: String, lastHash: String?, lastSentAtMs: Double?, nowMs: Double) -> Bool {
        guard hash == lastHash, let last = lastSentAtMs else { return true }
        return nowMs - last >= resendAfterMs || nowMs < last
    }

    /// Every album id a source could need expanded (pockets, playlist leaves, activity items) —
    /// lets the app build `albumTracks` for just these instead of the whole catalog.
    static func referencedAlbumCandidates(pockets: [Pocket], playlists: [Playlist],
                                          activity: [CollectionActivityStore.ActivityEvent]) -> Set<String> {
        var ids = Set<String>()
        for p in pockets { ids.formUnion(p.albumIds) }
        func walk(_ nodes: [PlaylistNode]) {
            for n in nodes {
                if n.kind == .album, let a = n.albumId { ids.insert(a) }
                if let kids = n.children { walk(kids) }
            }
        }
        for pl in playlists { walk(pl.sequences) }
        for e in activity where e.collectionId != nil && (e.kind == .add || e.kind == .remove) { ids.insert(e.itemId) }
        return ids
    }

    // MARK: - Event context

    /// `contextKind` for a play: from the collection id it started from (prefix first — the
    /// factories mint `pkt_` / `pls_` / `set_`), else from its source surface. The reserved
    /// Now Playing setlist is NOT a collection (it is a queue), so it never rides as a context.
    static func context(contextId: String?, source: PlayHistoryStore.PlaySource) -> (id: String, kind: String)? {
        guard let id = contextId, !id.isEmpty, id != nowPlayingSetlistId else { return nil }
        if id.hasPrefix("pkt_") { return (id, "pocket") }
        if id.hasPrefix("pls_") { return (id, "playlist") }
        if id.hasPrefix("set_") { return (id, "setlist") }
        // Pocket Wheel run rows: a run tag is never a context, the synthetic Favorites set is not
        // a collection the server knows, and a catalog source playlist (`pl_`) is a source whatever
        // surface played it.
        if id.hasPrefix(PocketWheelIds.runTagPrefix) || id == PocketWheelIds.favorites { return nil }
        if id.hasPrefix("pl_") { return (id, "source") }
        switch source {
        case .pocket: return (id, "pocket")
        case .playlist: return (id, "source")   // a non-`pls_` playlist id is a catalog source playlist
        default: return nil   // game runs (`itp_…` ride as .setlist), mix sessions, albums, artists
        }
    }
}
