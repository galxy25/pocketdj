import Foundation

// Native port of the PWA browser's filter/sort model
// (src/engine/fieldRegistry.ts · filterEngine.ts · sortEngine.ts).

enum ItemKind: String, CaseIterable, Identifiable, Codable { case album, song; var id: String { rawValue } }

/// A browsable row: an album, or a song (with its album name for display).
/// `source` carries the origin source name (e.g. "My Vinyl") so the filter engine
/// can match on it; nil when unknown (e.g. online hits built before tagging).
enum BrowseItem: Identifiable, Hashable {
    case album(IndexAlbum, source: String? = nil)
    /// `genre` is the song's top-tier CATEGORY, resolved from its owning album at
    /// construction time (IndexSong has no genre field of its own). Mirrors the PWA's
    /// `SongItem.genre`, which carries the derived category — so the genre filter/sort
    /// reads it directly here just like the PWA reads `song.genre`.
    case song(IndexSong, albumName: String, source: String? = nil, genre: String? = nil)

    var id: String {
        switch self {
        case .album(let a, _): return a.id
        case .song(let s, _, _, _): return s.id
        }
    }
    var kind: ItemKind {
        switch self { case .album: return .album; case .song: return .song }
    }
    var source: String? {
        switch self {
        case .album(_, let s): return s
        case .song(_, _, let s, _): return s
        }
    }
}

enum FieldKind { case string, number, bool, stringArray }
enum FilterOp: String, CaseIterable, Identifiable, Codable {
    case eq, neq, inList, notInList, between
    var id: String { rawValue }
    var label: String {
        switch self {
        case .eq: "is"; case .neq: "is not"; case .inList: "any of"
        case .notInList: "none of"; case .between: "between"
        }
    }
}

/// One typed value pulled from an item for a field.
enum FieldValue {
    case string(String), number(Double), bool(Bool), strings([String]), none
}

struct Field: Identifiable, Hashable {
    let id: String
    let label: String
    let kind: FieldKind
    let numeric: Bool
    let sortable: Bool
    let appliesTo: Set<ItemKind>
    let ops: [FilterOp]
    /// Closed value set drives a multi-select instead of free text (genre/key/camelot…).
    var hasOptions: Bool

    static func == (l: Field, r: Field) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Fields {
    static let all: [Field] = [
        Field(id: "artist", label: "Artist", kind: .string, numeric: false, sortable: true,
              appliesTo: [.album, .song], ops: [.eq, .neq, .inList], hasOptions: false),
        Field(id: "name", label: "Title", kind: .string, numeric: false, sortable: true,
              appliesTo: [.album, .song], ops: [.eq, .neq, .inList], hasOptions: false),
        Field(id: "year", label: "Year", kind: .number, numeric: true, sortable: true,
              appliesTo: [.album, .song], ops: [.eq, .neq, .inList, .between], hasOptions: false),
        // Genre filters on the TOP-LEVEL category for BOTH albums and songs (same as
        // the PWA / star map). Albums map their raw genre through Genre.category here;
        // songs carry the category resolved from their owning album at construction.
        Field(id: "genre", label: "Genre", kind: .string, numeric: false, sortable: true,
              appliesTo: [.album, .song], ops: [.eq, .neq, .inList, .notInList], hasOptions: true),
        Field(id: "fileType", label: "File type", kind: .string, numeric: false, sortable: true,
              appliesTo: [.album, .song], ops: [.eq, .neq, .inList], hasOptions: true),
        // Origin source (e.g. "My Vinyl", "Apple Music (Local)") — threaded onto
        // each BrowseItem when built from the merged catalog.
        Field(id: "source", label: "Source", kind: .string, numeric: false, sortable: true,
              appliesTo: [.album, .song], ops: [.eq, .neq, .inList], hasOptions: true),
        // album-only
        Field(id: "country", label: "Country", kind: .string, numeric: false, sortable: true,
              appliesTo: [.album], ops: [.eq, .neq, .inList], hasOptions: true),
        Field(id: "trackCount", label: "Track count", kind: .number, numeric: true, sortable: true,
              appliesTo: [.album], ops: [.eq, .neq, .inList, .between], hasOptions: false),
        // song-only
        Field(id: "trackNumber", label: "Track #", kind: .number, numeric: true, sortable: true,
              appliesTo: [.song], ops: [.eq, .neq, .inList, .between], hasOptions: false),
        Field(id: "length", label: "Length", kind: .number, numeric: true, sortable: true,
              appliesTo: [.song], ops: [.eq, .neq, .inList, .between], hasOptions: false),
        Field(id: "bpm", label: "BPM", kind: .number, numeric: true, sortable: true,
              appliesTo: [.song], ops: [.eq, .neq, .inList, .between], hasOptions: false),
        Field(id: "key", label: "Key", kind: .string, numeric: false, sortable: true,
              appliesTo: [.song], ops: [.eq, .neq, .inList], hasOptions: true),
        Field(id: "camelot", label: "Key (Camelot)", kind: .string, numeric: false, sortable: true,
              appliesTo: [.song], ops: [.eq, .neq, .inList], hasOptions: true),
        Field(id: "explicit", label: "Explicit", kind: .bool, numeric: false, sortable: true,
              appliesTo: [.song], ops: [.eq], hasOptions: false),
        Field(id: "sentiment", label: "Sentiment", kind: .stringArray, numeric: false, sortable: false,
              appliesTo: [.song], ops: [.inList, .eq, .neq], hasOptions: true),
    ]

    static let byID: [String: Field] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static func forKind(_ kind: ItemKind) -> [Field] { all.filter { $0.appliesTo.contains(kind) } }

    /// Value extractor — album fields return `.none` for songs and vice-versa.
    static func value(_ item: BrowseItem, _ fieldID: String) -> FieldValue {
        // Origin source is carried on the BrowseItem itself (both kinds).
        if fieldID == "source" { return item.source.map { .string($0) } ?? .none }
        switch item {
        case .album(let a, _):
            switch fieldID {
            case "artist": return .string(a.artist)
            case "name": return .string(a.name)
            case "year": return a.year.map { .number(Double($0)) } ?? .none
            // Collapse the raw genre into its top-tier category (same mapping as
            // the PWA constellation grid), so the filter list matches the PWA.
            case "genre": return .string(Genre.category(a.genre))
            case "fileType": return a.fileType.map { .string($0) } ?? .none
            case "country": return a.country.map { .string($0) } ?? .none
            case "trackCount": return .number(Double(a.trackList.count))
            default: return .none
            }
        case .song(let s, _, _, let genre):
            switch fieldID {
            case "artist": return .string(s.artist)
            case "name": return .string(s.name)
            case "year": return s.year.map { .number(Double($0)) } ?? .none
            // Top-tier category resolved from the owning album at construction time.
            case "genre": return genre.map { .string($0) } ?? .none
            case "fileType": return s.fileType.map { .string($0) } ?? .none
            case "trackNumber": return s.trackNumber.map { .number(Double($0)) } ?? .none
            case "length": return s.length.map { .number(Double($0)) } ?? .none
            case "bpm": return s.bpm.map { .number($0) } ?? .none
            case "key": return s.key.map { .string($0) } ?? .none
            case "camelot": return s.camelot.map { .string($0) } ?? .none
            case "explicit": return .bool(s.explicit ?? false)
            case "sentiment": return .strings(s.sentimentKeywords ?? [])
            default: return .none
            }
        }
    }
}

// MARK: - Filtering

struct Clause: Identifiable, Hashable, Codable {
    var id = UUID()
    var field: String
    var op: FilterOp
    var value: String = ""
    var values: Set<String> = []
    var min: Double?
    var max: Double?

    var isIncomplete: Bool {
        switch op {
        case .eq, .neq:           return value.isEmpty && values.isEmpty
        case .inList, .notInList: return values.isEmpty
        case .between:            return min == nil && max == nil
        }
    }
}

private func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }

enum FilterEngine {
    static func matches(_ item: BrowseItem, _ c: Clause) -> Bool {
        guard let field = Fields.byID[c.field] else { return true }
        if c.isIncomplete { return true }
        if !field.appliesTo.contains(item.kind) { return true }
        let raw = Fields.value(item, c.field)

        switch field.kind {
        case .stringArray:
            let arr: [String] = { if case .strings(let v) = raw { return v.map(norm) }; return [] }()
            switch c.op {
            case .inList: return c.values.isEmpty ? true : c.values.map(norm).contains { arr.contains($0) }
            case .eq:     return arr.contains(norm(c.value))
            case .neq:    return !arr.contains(norm(c.value))
            default:      return true
            }
        case .bool:
            let b: Bool = { if case .bool(let v) = raw { return v }; return false }()
            if c.op == .eq { return b == (c.value == "true") }
            return true
        case .number:
            let n: Double? = { if case .number(let v) = raw { return v }; return nil }()
            switch c.op {
            case .eq:      return n != nil && n == Double(c.value)
            case .neq:     return n == nil || n != Double(c.value)
            case .inList:  return n != nil && c.values.compactMap(Double.init).contains(n!)
            // none-of for numbers: keep when value is absent or not among the selected.
            case .notInList: return n == nil || !c.values.compactMap(Double.init).contains(n!)
            case .between:
                guard let n else { return false }
                return n >= (c.min ?? -.infinity) && n <= (c.max ?? .infinity)
            }
        case .string:
            let s: String? = { if case .string(let v) = raw { return v }; return nil }()
            let ns = norm(s ?? "")
            switch c.op {
            case .eq:        return ns == norm(c.value)
            case .neq:       return ns != norm(c.value)
            case .inList:    return c.values.map(norm).contains(ns)
            // none-of: keep when the value is NOT among the selected. An ungenred
            // song (ns == "") is kept — symmetric with .neq and HIDE membership.
            case .notInList: return !c.values.map(norm).contains(ns)
            default:         return true
            }
        }
    }

    static func apply(_ items: [BrowseItem], _ clauses: [Clause]) -> [BrowseItem] {
        guard !clauses.isEmpty else { return items }
        return items.filter { it in clauses.allSatisfy { matches(it, $0) } }
    }
}

// MARK: - Sorting (multi-key, stable, nulls last)

enum SortDir: String, Codable { case asc, desc }
struct SortKey: Identifiable, Hashable, Codable { var id = UUID(); var field: String; var dir: SortDir = .asc }

enum SortEngine {
    private struct Resolved { let field: Field; let dir: Int; let isCamelot: Bool; let numeric: Bool }

    static func apply(_ items: [BrowseItem], _ keys: [SortKey]) -> [BrowseItem] {
        let valid: [Resolved] = keys.compactMap { k in
            guard let f = Fields.byID[k.field] else { return nil }
            let isCamelot = f.id == "camelot"
            return Resolved(field: f, dir: k.dir == .desc ? -1 : 1, isCamelot: isCamelot,
                            numeric: f.numeric || isCamelot)
        }
        guard !valid.isEmpty else { return items }

        // Decorate once in input order; `i` is the stable tiebreak.
        let decorated = items.enumerated().map { (i, item) -> (item: BrowseItem, i: Int, vs: [FieldValue]) in
            let vs = valid.map { r -> FieldValue in
                let raw = Fields.value(item, r.field.id)
                if r.isCamelot {
                    if case .string(let code) = raw, let rank = Camelot.rank(code) { return .number(Double(rank)) }
                    return .none
                }
                return raw
            }
            return (item, i, vs)
        }

        let sorted = decorated.sorted { a, b in
            for k in valid.indices {
                let av = a.vs[k], bv = b.vs[k]
                let aNull = isNull(av), bNull = isNull(bv)
                if aNull && bNull { continue }
                if aNull { return false }          // nulls last (a after b)
                if bNull { return true }
                let cmp: Int
                if valid[k].numeric { cmp = compareNum(av, bv) }
                else if valid[k].field.kind == .bool { cmp = compareBool(av, bv) }
                else { cmp = compareStr(av, bv) }
                if cmp != 0 { return cmp * valid[k].dir < 0 }
            }
            return a.i < b.i
        }
        return sorted.map { $0.item }
    }

    private static func isNull(_ v: FieldValue) -> Bool {
        switch v {
        case .none: return true
        case .string(let s): return s.isEmpty
        default: return false
        }
    }
    private static func num(_ v: FieldValue) -> Double {
        if case .number(let n) = v { return n }; return 0
    }
    private static func compareNum(_ a: FieldValue, _ b: FieldValue) -> Int {
        let d = num(a) - num(b); return d < 0 ? -1 : (d > 0 ? 1 : 0)
    }
    private static func compareBool(_ a: FieldValue, _ b: FieldValue) -> Int {
        func bit(_ v: FieldValue) -> Int { if case .bool(let x) = v { return x ? 1 : 0 }; return 0 }
        return bit(a) - bit(b)
    }
    private static func compareStr(_ a: FieldValue, _ b: FieldValue) -> Int {
        func str(_ v: FieldValue) -> String { if case .string(let s) = v { return s }; return "" }
        return str(a).compare(str(b), options: .caseInsensitive) == .orderedAscending ? -1
             : (str(a).compare(str(b), options: .caseInsensitive) == .orderedDescending ? 1 : 0)
    }
}
