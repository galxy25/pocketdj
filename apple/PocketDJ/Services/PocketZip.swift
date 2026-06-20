import Foundation
import ZIPFoundation

/// Reads / writes a standalone single-pocket transfer — a `.pocket.pocketdj.zip` —
/// symmetric to `PlaylistZip`. A pocket moves LOSSLESSLY between devices (and is the
/// native counterpart the PWA's future `pocketTransfer.ts` would read).
///
/// The zip carries:
///   • `manifest.json` — `{ app:"pocketdj", kind:"pocket", schemaVersion:1,
///     portable:false, exportedAt, pocketName, counts:{pockets,art} }`. `pockets`
///     counts the EXPORTED pocket plus every transitively-referenced child pocket.
///   • `pocket.json` — the root `Pocket` being exported.
///   • `pockets.json` — the child pockets it references, DAG-expanded (cycle-guarded);
///     may be `[]`. The root is NOT duplicated here.
///
/// Like `PlaylistZip`, this is SLIM (`portable:false`): songs/albums stay referenced
/// by catalog id (the same auto-seeded index resolves them on both ends), so neither
/// `items.json` nor `art/` is bundled.
enum PocketZip {

    // MARK: - Manifest

    struct Manifest: Codable {
        var app: String
        var kind: String
        var schemaVersion: Int
        var portable: Bool?
        var exportedAt: String
        var pocketName: String
        var counts: Counts

        struct Counts: Codable {
            var pockets: Int
            var art: Int

            init(pockets: Int = 0, art: Int = 0) { self.pockets = pockets; self.art = art }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                pockets = (try? c.decode(Int.self, forKey: .pockets)) ?? 0
                art = (try? c.decode(Int.self, forKey: .art)) ?? 0
            }
        }

        init(app: String = "pocketdj", kind: String = "pocket", schemaVersion: Int = 1,
             portable: Bool? = false, exportedAt: String, pocketName: String, counts: Counts) {
            self.app = app; self.kind = kind; self.schemaVersion = schemaVersion
            self.portable = portable; self.exportedAt = exportedAt
            self.pocketName = pocketName; self.counts = counts
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = (try? c.decode(String.self, forKey: .app)) ?? ""
            kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
            portable = try? c.decode(Bool.self, forKey: .portable)
            exportedAt = (try? c.decode(String.self, forKey: .exportedAt)) ?? ""
            pocketName = (try? c.decode(String.self, forKey: .pocketName)) ?? ""
            counts = (try? c.decode(Counts.self, forKey: .counts)) ?? Counts()
        }
    }

    enum PocketZipError: Error, LocalizedError {
        case notAPocketExport
        case archiveUnreadable
        case missingPocket

        var errorDescription: String? {
            switch self {
            case .notAPocketExport: return "Not a PocketDJ pocket export."
            case .archiveUnreadable: return "Couldn't read the pocket zip."
            case .missingPocket: return "Pocket export is missing pocket.json."
            }
        }
    }

    static let filenameSuffix = ".pocket.pocketdj.zip"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }
    private static let decoder = JSONDecoder()

    // MARK: - Export

    /// Build a `.pocket.pocketdj.zip` (slim) for `pocket`, bundling its child pockets
    /// DAG-expanded (resolved from `pocketsById`, cycle-guarded).
    static func export(pocket: Pocket, pocketsById: [String: Pocket]) throws -> Data {
        let children = referencedChildren(of: pocket, pocketsById: pocketsById)

        let manifest = Manifest(
            portable: false,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            pocketName: pocket.name,
            counts: .init(pockets: children.count + 1, art: 0)
        )

        let files: [String: Data] = [
            "manifest.json": try encoder.encode(manifest),
            "pocket.json": try encoder.encode(pocket),
            "pockets.json": try encoder.encode(children),
        ]

        guard let archive = try? Archive(accessMode: .create) else { throw PocketZipError.archiveUnreadable }
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                let start = data.index(data.startIndex, offsetBy: Int(position))
                let end = data.index(start, offsetBy: size)
                return data[start..<end]
            }
        }
        guard let out = archive.data else { throw PocketZipError.archiveUnreadable }
        return out
    }

    /// The child pockets a pocket references, DAG-expanded (grandchildren too),
    /// resolved against `pocketsById`. Cycle-guarded. The root pocket is excluded.
    static func referencedChildren(of pocket: Pocket, pocketsById: [String: Pocket]) -> [Pocket] {
        var out: [Pocket] = []
        var seen = Set<String>([pocket.id])
        var queue = pocket.childPocketIds
        while let pid = queue.popLast() {
            if !seen.insert(pid).inserted { continue }
            guard let p = pocketsById[pid] else { continue }
            out.append(p)
            queue.append(contentsOf: p.childPocketIds)
        }
        return out
    }

    // MARK: - Import

    /// Read a `.pocket.pocketdj.zip` and return the root pocket + its child pockets,
    /// with FRESH ids minted for every pocket; child refs are remapped to the new ids.
    /// Songs/albums stay referenced by catalog id. Version-tolerant: a missing manifest
    /// is allowed (presence of pocket.json is enough), extra manifest fields ignored.
    static func `import`(data: Data) throws -> (pocket: Pocket, children: [Pocket]) {
        guard let archive = try? Archive(data: data, accessMode: .read) else {
            throw PocketZipError.archiveUnreadable
        }

        func extract(_ name: String) -> Data? {
            guard let entry = archive[name] else { return nil }
            var out = Data()
            _ = try? archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: true) { out.append($0) }
            return out
        }

        if let manRaw = extract("manifest.json"),
           let man = try? decoder.decode(Manifest.self, from: manRaw) {
            if man.app != "pocketdj" || man.kind != "pocket" {
                throw PocketZipError.notAPocketExport
            }
        }

        guard let rootRaw = extract("pocket.json") else { throw PocketZipError.missingPocket }
        let srcRoot: Pocket
        do { srcRoot = try decoder.decode(Pocket.self, from: rootRaw) }
        catch { throw PocketZipError.notAPocketExport }

        let srcChildren: [Pocket] = extract("pockets.json")
            .flatMap { try? decoder.decode([Pocket].self, from: $0) } ?? []

        return remintBundle(root: srcRoot, children: srcChildren)
    }

    /// Mint fresh ids for the imported root + every child pocket, remapping child refs
    /// (childPocketIds) to the new ids. Refs to pockets NOT in the bundle are left as-is.
    static func remintBundle(root: Pocket, children: [Pocket]) -> (pocket: Pocket, children: [Pocket]) {
        let now = Date().timeIntervalSince1970 * 1000

        var idMap: [String: String] = [:]
        idMap[root.id] = CollectionsFactory.newPocketId()
        for c in children { idMap[c.id] = CollectionsFactory.newPocketId() }

        func remint(_ p: Pocket) -> Pocket {
            var p = p
            p.id = idMap[p.id] ?? CollectionsFactory.newPocketId()
            p.childPocketIds = p.childPocketIds.map { idMap[$0] ?? $0 }
            p.createdAt = now; p.updatedAt = now
            return p
        }

        return (remint(root), children.map(remint))
    }
}
