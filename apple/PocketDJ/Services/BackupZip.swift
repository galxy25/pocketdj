import Foundation
import ZIPFoundation

/// Reads / writes the full backup `.pocketdj.zip` — the SHARED-SUBSET that the
/// native (client-only) apps own. This is the same envelope the PWA's
/// `src/storage/exportZip.ts` / `importZip.ts` produce/consume, but native does
/// NOT bundle the remote catalog (`items.json` / `art/`): the catalog is the same
/// auto-seeded index on both ends, so collections reference songs/albums by id and
/// resolve at display. We therefore set `portable:false` and zero those counts.
///
/// Entry filenames MATCH the PWA exactly so a native backup imports there and vice
/// versa:
///   • `manifest.json`  — `{ app:"pocketdj", kind:"backup", schemaVersion, exportedAt,
///                           portable:false, counts:{sources,items,art,pockets,playlists,setlists} }`
///   • `sources.json`   — the SettingsStore `SourceConfig[]` (native shape; see note).
///   • `pockets.json`   — `[Pocket]`
///   • `playlists.json` — `[Playlist]`
///   • `setlists.json`  — `[Setlist]`
///   • `edits.json`     — the `EditsDocument` (native-only addition; the PWA currently
///                         ignores it — see the PWA-side changes report).
///
/// NOTE on `sources.json`: the PWA writes full `DataSource` objects (derived from an
/// indexed index.json); native writes its `SourceConfig` (name + index URL + enabled).
/// They are different shapes. Native's importer reads `sources.json` LENIENTLY and
/// only adopts entries that decode as `SourceConfig` (a PWA backup's DataSource[] is
/// skipped, not fatal). The PWA's importer would likewise not adopt native sources.
enum BackupZip {

    // MARK: - Manifest

    /// Mirrors the PWA's `ExportManifest`. `kind` is absent in PWA exports; native
    /// writes `kind:"backup"` so the router can dispatch. All fields decode leniently.
    struct Manifest: Codable {
        var app: String
        var kind: String?
        var schemaVersion: Int
        var portable: Bool?
        var exportedAt: String
        var counts: Counts

        struct Counts: Codable {
            var sources: Int
            var items: Int
            var art: Int
            var pockets: Int
            var playlists: Int
            var setlists: Int

            init(sources: Int = 0, items: Int = 0, art: Int = 0,
                 pockets: Int = 0, playlists: Int = 0, setlists: Int = 0) {
                self.sources = sources; self.items = items; self.art = art
                self.pockets = pockets; self.playlists = playlists; self.setlists = setlists
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                sources = (try? c.decode(Int.self, forKey: .sources)) ?? 0
                items = (try? c.decode(Int.self, forKey: .items)) ?? 0
                art = (try? c.decode(Int.self, forKey: .art)) ?? 0
                pockets = (try? c.decode(Int.self, forKey: .pockets)) ?? 0
                playlists = (try? c.decode(Int.self, forKey: .playlists)) ?? 0
                setlists = (try? c.decode(Int.self, forKey: .setlists)) ?? 0
            }
        }

        init(app: String = "pocketdj", kind: String? = "backup", schemaVersion: Int = 2,
             portable: Bool? = false, exportedAt: String, counts: Counts) {
            self.app = app; self.kind = kind; self.schemaVersion = schemaVersion
            self.portable = portable; self.exportedAt = exportedAt; self.counts = counts
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = (try? c.decode(String.self, forKey: .app)) ?? ""
            kind = try? c.decode(String.self, forKey: .kind)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
            portable = try? c.decode(Bool.self, forKey: .portable)
            exportedAt = (try? c.decode(String.self, forKey: .exportedAt)) ?? ""
            counts = (try? c.decode(Counts.self, forKey: .counts)) ?? Counts()
        }
    }

    enum BackupZipError: Error, LocalizedError {
        case archiveUnreadable
        case notABackup

        var errorDescription: String? {
            switch self {
            case .archiveUnreadable: return "Couldn't read the backup zip."
            case .notABackup: return "Not a PocketDJ backup."
            }
        }
    }

    static let filenameSuffix = ".pocketdj.zip"

    /// The PWA's backup schema versions native tolerates (1 = pre-collections,
    /// 2 = +pockets/playlists/setlists). Native writes 2.
    static let schemaVersion = 2

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }
    private static let decoder = JSONDecoder()

    // MARK: - Export

    /// The decoded payload of a native full backup (for export AND for the importer's
    /// merge step). `edits` is the raw EditsDocument bytes (kept as Data so the
    /// EditsStore's own codec / migration owns its decode).
    struct Payload {
        var sources: [SourceConfig]
        var pockets: [Pocket]
        var playlists: [Playlist]
        var setlists: [Setlist]
        var folders: [PlaylistFolder]
        var editsData: Data?

        init(sources: [SourceConfig], pockets: [Pocket], playlists: [Playlist],
             setlists: [Setlist], folders: [PlaylistFolder] = [], editsData: Data?) {
            self.sources = sources; self.pockets = pockets; self.playlists = playlists
            self.setlists = setlists; self.folders = folders; self.editsData = editsData
        }
    }

    /// Build a `.pocketdj.zip` from the collections + sources + edits. `items.json`
    /// and `art/` are intentionally OMITTED (client-only catalog); their counts are 0.
    static func export(sources: [SourceConfig], pockets: [Pocket], playlists: [Playlist],
                       setlists: [Setlist], folders: [PlaylistFolder] = [], editsData: Data) throws -> Data {
        let manifest = Manifest(
            schemaVersion: schemaVersion,
            portable: false,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            counts: .init(sources: sources.count, items: 0, art: 0,
                          pockets: pockets.count, playlists: playlists.count, setlists: setlists.count)
        )

        let files: [String: Data] = [
            "manifest.json": try encoder.encode(manifest),
            "sources.json": try encoder.encode(sources),
            "pockets.json": try encoder.encode(pockets),
            "playlists.json": try encoder.encode(playlists),
            "setlists.json": try encoder.encode(setlists),
            "folders.json": try encoder.encode(folders),
            "edits.json": editsData,
        ]

        let archive: Archive
        do { archive = try Archive(accessMode: .create) } catch { throw BackupZipError.archiveUnreadable }
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                let start = data.index(data.startIndex, offsetBy: Int(position))
                let end = data.index(start, offsetBy: size)
                return data[start..<end]
            }
        }
        guard let out = archive.data else { throw BackupZipError.archiveUnreadable }
        return out
    }

    // MARK: - Import

    /// Number of catalog items / art entries present in a backup but NOT consumed by
    /// native (the remote catalog resolves them by id). Logged so the skip is visible.
    struct SkippedCatalog { var items: Int; var art: Int }

    /// Read a `.pocketdj.zip` into its decoded `Payload`. Tolerates the PWA's
    /// schemaVersion 1|2, a missing `kind`, and a backup that omits `items.json`/`art`.
    /// `sources.json` entries that don't decode as native `SourceConfig` (e.g. PWA
    /// `DataSource[]`) are dropped (not fatal). Returns the payload + a count of the
    /// skipped catalog entries (items + art) for logging.
    static func `import`(data: Data) throws -> (payload: Payload, skipped: SkippedCatalog) {
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) } catch { throw BackupZipError.archiveUnreadable }

        func extract(_ name: String) -> Data? {
            guard let entry = archive[name] else { return nil }
            var out = Data()
            _ = try? archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: true) { out.append($0) }
            return out
        }

        // Manifest, if present, must self-identify as PocketDJ. A bare backup with no
        // manifest is still accepted if it carries any collections/sources/edits entry.
        if let manRaw = extract("manifest.json"),
           let man = try? decoder.decode(Manifest.self, from: manRaw) {
            if man.app != "pocketdj" { throw BackupZipError.notABackup }
        }

        // Sources: try native SourceConfig[]; if that fails (PWA DataSource[]), drop.
        let sources: [SourceConfig] = extract("sources.json")
            .flatMap { try? decoder.decode([SourceConfig].self, from: $0) } ?? []

        let pockets: [Pocket] = extract("pockets.json")
            .flatMap { try? decoder.decode([Pocket].self, from: $0) } ?? []
        let playlists: [Playlist] = extract("playlists.json")
            .flatMap { try? decoder.decode([Playlist].self, from: $0) } ?? []
        let setlists: [Setlist] = extract("setlists.json")
            .flatMap { try? decoder.decode([Setlist].self, from: $0) } ?? []
        let folders: [PlaylistFolder] = extract("folders.json")
            .flatMap { try? decoder.decode([PlaylistFolder].self, from: $0) } ?? []

        let editsData = extract("edits.json")

        // Catalog entries that travel in a PWA portable backup but native ignores.
        let itemCount = extract("items.json")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }?.count ?? 0
        var artCount = 0
        for entry in archive where entry.path.hasPrefix("art/") && entry.path.hasSuffix(".webp") { artCount += 1 }

        let payload = Payload(sources: sources, pockets: pockets, playlists: playlists,
                              setlists: setlists, folders: folders, editsData: editsData)
        return (payload, SkippedCatalog(items: itemCount, art: artCount))
    }
}
