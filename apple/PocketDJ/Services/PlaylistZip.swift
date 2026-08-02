import Foundation
import ZIPFoundation

/// Reads / writes the PWA's single-playlist transfer format — a
/// `.playlist.pocketdj.zip` (see `src/storage/playlistTransfer.ts`) — so a playlist
/// moves LOSSLESSLY between the PWA and the native apps.
///
/// The zip carries:
///   • `manifest.json` — `{ app:"pocketdj", kind:"playlist", schemaVersion:1,
///     portable, exportedAt, playlistName, counts:{items,pockets,setlists,art} }`.
///   • `playlist.json` — a `Playlist` (same shape as native `Playlist`/`PlaylistNode`,
///     both ported from the PWA's `collections.ts`).
///   • `pockets.json` — the pockets the playlist references, DAG-expanded (may be `[]`).
///   • PORTABLE mode also bundles `items.json` — the referenced catalog items in the
///     PWA's `MusicItem[]` shape (see `PortableItems`) — so the transfer is
///     self-contained across catalogs: the importer materializes unknown ids as
///     provisional "Imported" entries (browse/play/burn/stems by id — acceptance A).
///     The PWA additionally bundles `art/<key>.webp` + `setlists.json`; the native
///     importer tolerates but doesn't consume those (art loads from its URLs;
///     set-list history stays deferred).
///
/// The native app exports PORTABLE whenever the caller hands it the catalog (the
/// CollectionsStore path always does); `export` without a catalog stays the slim
/// pass-1 shape byte-for-byte.
enum PlaylistZip {

    // MARK: - Manifest

    /// The transfer manifest. All fields decode leniently so a newer/older peer's
    /// extra/missing keys never break the import (version-tolerant).
    struct Manifest: Codable {
        var app: String
        var kind: String
        var schemaVersion: Int
        var portable: Bool?
        var exportedAt: String
        var playlistName: String
        var counts: Counts

        struct Counts: Codable {
            var items: Int
            var pockets: Int
            var setlists: Int
            var art: Int

            init(items: Int = 0, pockets: Int = 0, setlists: Int = 0, art: Int = 0) {
                self.items = items; self.pockets = pockets; self.setlists = setlists; self.art = art
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                items = (try? c.decode(Int.self, forKey: .items)) ?? 0
                pockets = (try? c.decode(Int.self, forKey: .pockets)) ?? 0
                setlists = (try? c.decode(Int.self, forKey: .setlists)) ?? 0
                art = (try? c.decode(Int.self, forKey: .art)) ?? 0
            }
        }

        init(app: String = "pocketdj", kind: String = "playlist", schemaVersion: Int = 1,
             portable: Bool? = false, exportedAt: String, playlistName: String, counts: Counts) {
            self.app = app; self.kind = kind; self.schemaVersion = schemaVersion
            self.portable = portable; self.exportedAt = exportedAt
            self.playlistName = playlistName; self.counts = counts
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = (try? c.decode(String.self, forKey: .app)) ?? ""
            kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
            portable = try? c.decode(Bool.self, forKey: .portable)
            exportedAt = (try? c.decode(String.self, forKey: .exportedAt)) ?? ""
            playlistName = (try? c.decode(String.self, forKey: .playlistName)) ?? ""
            counts = (try? c.decode(Counts.self, forKey: .counts)) ?? Counts()
        }
    }

    enum PlaylistZipError: Error, LocalizedError {
        case notAPlaylistExport
        case archiveUnreadable
        case missingPlaylist

        var errorDescription: String? {
            switch self {
            case .notAPlaylistExport: return "Not a PocketDJ playlist export."
            case .archiveUnreadable: return "Couldn't read the playlist zip."
            case .missingPlaylist: return "Playlist export is missing playlist.json."
            }
        }
    }

    /// The fixed magic the format is recognised by (so the importer can route a
    /// .zip to here vs. a native .json to importCollection).
    static let filenameSuffix = ".playlist.pocketdj.zip"

    // Encoder/decoder match the PWA: compact JSON, nil optionals OMITTED (Swift's
    // default), so `description`/`targetMs`/notes absent ⇒ no key, exactly like fflate.
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
    private static let decoder = JSONDecoder()

    // MARK: - Export

    /// Build a `.playlist.pocketdj.zip` for `playlist`, bundling the pockets it
    /// references (DAG-expanded, resolved from `pocketsById`). PORTABLE when a catalog
    /// is provided: `items.json` carries every referenced song/album (PWA `MusicItem[]`
    /// shape — see `PortableItems`), so the zip imports fully on a device whose enabled
    /// sources don't cover these ids. Without a catalog: the slim pass-1 shape.
    static func export(playlist: Playlist, pocketsById: [String: Pocket],
                       songsById: [String: IndexSong] = [:],
                       albumsById: [String: IndexAlbum] = [:]) throws -> Data {
        let pockets = referencedPockets(of: playlist, pocketsById: pocketsById)

        let portable = !songsById.isEmpty || !albumsById.isEmpty
        var itemsData: Data? = nil
        var itemCount = 0
        if portable {
            let ids = PortableItems.referencedIds(playlist: playlist, pockets: pockets)
            let data = try PortableItems.encode(songIds: ids.songs, albumIds: ids.albums,
                                                songsById: songsById, albumsById: albumsById)
            itemsData = data
            itemCount = ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.count ?? 0
        }

        let manifest = Manifest(
            portable: portable,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            playlistName: playlist.name,
            counts: .init(items: itemCount, pockets: pockets.count, setlists: 0, art: 0)
        )

        var files: [String: Data] = [
            "manifest.json": try encoder.encode(manifest),
            "playlist.json": try encoder.encode(playlist),
            "pockets.json": try encoder.encode(pockets),
        ]
        if let itemsData { files["items.json"] = itemsData }

        let archive: Archive
        do { archive = try Archive(accessMode: .create) } catch { throw PlaylistZipError.archiveUnreadable }
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                let start = data.index(data.startIndex, offsetBy: Int(position))
                let end = data.index(start, offsetBy: size)
                return data[start..<end]
            }
        }
        guard let out = archive.data else { throw PlaylistZipError.archiveUnreadable }
        return out
    }

    /// The pockets a playlist references, DAG-expanded (child pockets pulled in too),
    /// resolved against `pocketsById`. Cycle-guarded. Matches the PWA's `buildPlaylistZip`
    /// walk: only USER pockets travel (catalog items stay referenced by id).
    static func referencedPockets(of playlist: Playlist, pocketsById: [String: Pocket]) -> [Pocket] {
        var rootPocketIds: [String] = []
        func walk(_ nodes: [PlaylistNode]) {
            for n in nodes {
                switch n.kind {
                case .pocket: if let pid = n.pocketId { rootPocketIds.append(pid) }
                case .sequence: walk(n.children ?? [])
                default: break
                }
            }
        }
        for seq in playlist.sequences { walk(seq.children ?? []) }

        var out: [Pocket] = []
        var seen = Set<String>()
        var queue = rootPocketIds
        while let pid = queue.popLast() {
            if !seen.insert(pid).inserted { continue }
            guard let p = pocketsById[pid] else { continue }
            out.append(p)
            queue.append(contentsOf: p.childPocketIds)
        }
        return out
    }

    // MARK: - Import

    /// Read a `.playlist.pocketdj.zip` and return its playlist + referenced pockets,
    /// with FRESH ids minted for the playlist, every pocket, and every node id; intra-
    /// bundle references (pocket-node `pocketId`s, child pockets) are remapped to the
    /// new ids. Songs/albums stay referenced by catalog id — `items` carries the
    /// PORTABLE catalog snapshot (empty for slim zips) so the caller can materialize
    /// unknown ids as provisional entries. Version-tolerant: a missing manifest is
    /// allowed (presence of playlist.json is enough), extra manifest fields ignored.
    static func `import`(data: Data) throws -> (playlist: Playlist, pockets: [Pocket],
                                                items: PortableItems.Payload) {
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) } catch { throw PlaylistZipError.archiveUnreadable }

        func extract(_ name: String) -> Data? {
            guard let entry = archive[name] else { return nil }
            var out = Data()
            _ = try? archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: true) { out.append($0) }
            return out
        }

        // Manifest is optional but, when present, must self-identify as a playlist export.
        if let manRaw = extract("manifest.json"),
           let man = try? decoder.decode(Manifest.self, from: manRaw) {
            if man.app != "pocketdj" || man.kind != "playlist" {
                throw PlaylistZipError.notAPlaylistExport
            }
        }

        guard let plRaw = extract("playlist.json") else { throw PlaylistZipError.missingPlaylist }
        let srcPlaylist: Playlist
        do { srcPlaylist = try decoder.decode(Playlist.self, from: plRaw) }
        catch { throw PlaylistZipError.notAPlaylistExport }

        let srcPockets: [Pocket] = extract("pockets.json")
            .flatMap { try? decoder.decode([Pocket].self, from: $0) } ?? []

        // PORTABLE catalog snapshot (PWA MusicItem[] or this app's own export) —
        // leniently parsed; absent/unreadable ⇒ empty (the slim pass-1 behavior).
        // art/ + setlists.json stay unconsumed (art loads from URLs; setlists deferred).
        let items = extract("items.json").map(PortableItems.decode) ?? PortableItems.Payload()

        let bundle = remintBundle(playlist: srcPlaylist, pockets: srcPockets)
        return (bundle.playlist, bundle.pockets, items)
    }

    /// Mint fresh ids for the imported playlist + all its pockets + every nodeId, and
    /// remap intra-bundle references (pocket node `pocketId`s, child pockets). Refs to
    /// pockets NOT in the bundle are left as-is (they may resolve against pockets that
    /// already exist on the device).
    static func remintBundle(playlist: Playlist, pockets: [Pocket]) -> (playlist: Playlist, pockets: [Pocket]) {
        let now = Date().timeIntervalSince1970 * 1000

        var pocketIdMap: [String: String] = [:]
        for p in pockets { pocketIdMap[p.id] = CollectionsFactory.newPocketId() }

        var newPockets: [Pocket] = []
        for var p in pockets {
            p.id = pocketIdMap[p.id] ?? CollectionsFactory.newPocketId()
            p.childPocketIds = p.childPocketIds.map { pocketIdMap[$0] ?? $0 }
            p.createdAt = now; p.updatedAt = now
            // NEVER carry the sharer's Apple Music playlist link into an imported copy — it is a
            // handle into THEIR library, and a synced copy would push the importer's edits there.
            p.amPlaylistId = nil
            newPockets.append(p)
        }

        var pl = playlist
        pl.id = CollectionsFactory.newPlaylistId()
        pl.sequences = pl.sequences.map { remintNode($0, pocketIdMap: pocketIdMap) }
        pl.createdAt = now; pl.updatedAt = now
        pl.amPlaylistId = nil   // see the pocket note above

        return (pl, newPockets)
    }

    private static func remintNode(_ node: PlaylistNode, pocketIdMap: [String: String]) -> PlaylistNode {
        var n = node
        n.nodeId = CollectionsFactory.newNodeId()
        if let pid = n.pocketId, let mapped = pocketIdMap[pid] { n.pocketId = mapped }
        if let kids = n.children { n.children = kids.map { remintNode($0, pocketIdMap: pocketIdMap) } }
        return n
    }
}
