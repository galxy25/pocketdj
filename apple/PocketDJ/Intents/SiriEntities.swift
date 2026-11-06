import Foundation
import AppIntents

// The entities + enums behind the 1.0.4 Siri layer (add a song to a collection by name, Mix Mode,
// stems by voice). Same rules as `CollectionEntities.swift`: value snapshots whose resolution goes
// back through the registered `IntentServices`; the reserved Now Playing scratch collections are
// never offered.
//
// Siri AI (iOS/macOS/visionOS 27.3+) finds these through the queries below — `CollectionEntity`
// is ENUMERABLE (a few dozen rows), `SongEntity` is string-queried (the catalog is ~100k rows, far
// too many to enumerate or bulk-index). The 27.3-only property descriptions can't be attached to
// types that deploy back to iOS 18, so the titles + display representations carry the meaning.

// MARK: - Collection (a pocket OR a playlist — whatever "Add to…" targets)

/// One of the user's collections as the in-app "Add to…" menus see them: a POCKET or a
/// PLAYLIST. Folded into one entity because a Siri phrase carries a single parameter, and people
/// say "add it to Workout" without knowing (or caring) which kind Workout is. The id reuses
/// `MixSource.id`'s encoding ("pocket:<id>" / "playlist:<id>").
struct CollectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Collection",
        numericFormat: "\(placeholder: .int) collections")
    static let defaultQuery = CollectionEntityQuery()

    let id: String
    let name: String
    /// "Pocket" / "Playlist" — shown as the subtitle so two same-named collections disambiguate.
    let kindLabel: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(kindLabel)",
                              image: .init(systemName: kindLabel == "Pocket" ? "square.stack.3d.up" : "music.note.list"),
                              synonyms: ["\(name) \(kindLabel.lowercased())", "my \(name) \(kindLabel.lowercased())"])
    }

    init(pocket: Pocket) {
        id = MixSource.pocket(pocket.id).id
        name = pocket.name
        kindLabel = "Pocket"
    }
    init(playlist: Playlist) {
        id = MixSource.playlist(playlist.id).id
        name = playlist.name
        kindLabel = "Playlist"
    }

    /// The Add-to target this entity names (nil for a stale / foreign id).
    var addTarget: AddTarget? { Self.addTarget(from: id) }
    static func addTarget(from id: String) -> AddTarget? {
        switch AutoMixSourceEntity.mixSource(from: id) {
        case .pocket(let pid): return AddTarget(kind: .pocket, id: pid)
        case .playlist(let plid): return AddTarget(kind: .playlist, id: plid)
        default: return nil
        }
    }

    /// Pockets then playlists, A–Z — the order the Add-to sheet lists them. Now Playing filtered.
    @MainActor static func all(in collections: CollectionsStore) -> [CollectionEntity] {
        collections.pocketsAZ.map(CollectionEntity.init(pocket:))
        + collections.playlistsAZ.filter { $0.id != nowPlayingPlaylistId }.map(CollectionEntity.init(playlist:))
    }

    @MainActor static func resolve(ids: [String], in collections: CollectionsStore) -> [CollectionEntity] {
        ids.compactMap { id in
            switch addTarget(from: id) {
            case .some(let t) where t.kind == .pocket:
                return collections.pocket(t.id).map(CollectionEntity.init(pocket:))
            case .some(let t):
                guard t.id != nowPlayingPlaylistId else { return nil }
                return collections.playlist(t.id).map(CollectionEntity.init(playlist:))
            case nil:
                return nil
            }
        }
    }

    /// Typo-tolerant name match — the SAME ranker the Add-to sheet's search field uses
    /// (`FuzzyMatch`), cut to its best tier so an exact name never comes with a "which one?".
    @MainActor static func matching(_ string: String, in collections: CollectionsStore) -> [CollectionEntity] {
        rankByName(string, all(in: collections), name: \.name)
    }

    /// The ranked best tier of `items` for a spoken name: exact names win outright; otherwise
    /// everything within one FuzzyMatch tier of the best hit. Leading "my"/"the" and a trailing
    /// "playlist"/"pocket"/"collection" are ignored ("my workout playlist" → "workout").
    ///
    /// Stricter than the Add sheet's filter field because an add WRITES and Siri runs a lone
    /// result without asking: only literal hits (the name equals / starts with / contains the
    /// request), else — when nothing is literal — a whole-name typo. FuzzyMatch's subsequence
    /// pass (typed initials: "fnm" → "Friday Night Mix") is never used: a spoken "Rap" must not
    /// land silently in "Rainy Afternoon Pop", and neither must a typo hit buried in a longer name.
    static func rankByName<T>(_ raw: String, _ items: [T], name: (T) -> String) -> [T] {
        let q = spokenName(raw)
        let qc = FuzzyMatch.compact(q)
        guard !qc.isEmpty else { return [] }
        let candidates = items.map { (item: $0, chars: FuzzyMatch.compact(name($0))) }
        func contains(_ c: [Character]) -> Bool {
            c.count >= qc.count && (0...(c.count - qc.count)).contains { Array(c[$0..<$0 + qc.count]) == qc }
        }
        var scored = candidates.compactMap { cand -> (T, Double)? in
            guard contains(cand.chars) else { return nil }
            return FuzzyMatch.score(query: q, candidate: name(cand.item)).map { (cand.item, $0) }
        }
        if scored.isEmpty {
            let budget = FuzzyMatch.errorBudget(qc.count)
            scored = candidates.compactMap { cand -> (T, Double)? in
                guard budget > 0, abs(cand.chars.count - qc.count) <= budget else { return nil }
                let d = FuzzyMatch.approximateDistance(qc, cand.chars)
                return d <= budget ? (cand.item, 300 - Double(d) * 40) : nil
            }
        }
        scored.sort { $0.1 > $1.1 }
        guard let best = scored.first?.1 else { return [] }
        let band: Double = best >= 1000 ? 0 : 60
        return scored.filter { best - $0.1 <= band }.map(\.0)
    }

    static func spokenName(_ raw: String) -> String {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’"))
        for prefix in ["my ", "the "] where q.lowercased().hasPrefix(prefix) { q = String(q.dropFirst(prefix.count)) }
        for suffix in [" playlist", " pocket", " collection"] where q.lowercased().hasSuffix(suffix) {
            q = String(q.dropLast(suffix.count))
        }
        return q.trimmingCharacters(in: .whitespaces)
    }
}

struct CollectionEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @Dependency private var services: IntentServices

    @MainActor func entities(for identifiers: [String]) async throws -> [CollectionEntity] {
        CollectionEntity.resolve(ids: identifiers, in: services.collections)
    }
    @MainActor func allEntities() async throws -> [CollectionEntity] {
        CollectionEntity.all(in: services.collections)
    }
    @MainActor func suggestedEntities() async throws -> [CollectionEntity] {
        // Recently-added-to first (the Add sheet's Recent row), then everything else.
        let all = CollectionEntity.all(in: services.collections)
        let recent = services.collections.recentAddTargets.map { MixSource(addTarget: $0).id }
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return all.enumerated().sorted {
            (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
    }
    @MainActor func entities(matching string: String) async throws -> [CollectionEntity] {
        CollectionEntity.matching(string, in: services.collections)
    }
}

extension MixSource {
    /// The Mix-source spelling of an Add-to target (the shared entity-id encoding).
    init(addTarget t: AddTarget) {
        switch t.kind {
        case .pocket: self = .pocket(t.id)
        case .playlist: self = .playlist(t.id)
        }
    }
}

// MARK: - Song (a catalog song, by spoken title)

/// A catalog song — what "add Make Me Proud to Workout" names. Resolved by `IntentSongMatcher`
/// (title, optional "by <artist>", typo tolerant, deduplicated by recording).
struct SongEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Song",
        numericFormat: "\(placeholder: .int) songs")
    static let defaultQuery = SongEntityQuery()

    let id: String
    let title: String
    let artist: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: "\(artist)",
                              image: .init(systemName: "music.note"),
                              synonyms: ["\(title) by \(artist)"])
    }

    init(id: String, title: String, artist: String) {
        self.id = id
        self.title = title
        self.artist = artist
    }
    init(_ song: IndexSong) { self.init(id: song.id, title: song.name, artist: song.artist) }
}

struct SongEntityQuery: EntityStringQuery {
    @Dependency private var services: IntentServices

    @MainActor func entities(for identifiers: [String]) async throws -> [SongEntity] {
        await services.ensureReady()
        return identifiers.compactMap { services.songEntity(id: $0) }
    }
    /// The song playing right now — "this song" in a Shortcuts picker.
    @MainActor func suggestedEntities() async throws -> [SongEntity] {
        await services.ensureReady()
        return services.currentSongId().flatMap { services.songEntity(id: $0) }.map { [$0] } ?? []
    }
    @MainActor func entities(matching string: String) async throws -> [SongEntity] {
        await services.ensureReady()
        return services.matchSongs(string).map(SongEntity.init)
    }
}

// MARK: - Stems + Mix Mode enums

/// The four Demucs parts, by every name people say for them.
enum StemPart: String, AppEnum, CaseIterable {
    case vocals, drums, bass, other

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Stem")
    static let caseDisplayRepresentations: [StemPart: DisplayRepresentation] = [
        .vocals: DisplayRepresentation(title: "Vocals",
                                       synonyms: ["vocal", "vocals", "voice", "voices", "singing", "singer", "lyrics", "acapella"]),
        .drums: DisplayRepresentation(title: "Drums",
                                      synonyms: ["drum", "drums", "percussion", "beat", "the beat"]),
        .bass: DisplayRepresentation(title: "Bass",
                                     synonyms: ["bass", "bassline", "bass line", "low end"]),
        .other: DisplayRepresentation(title: "Other",
                                      synonyms: ["other", "others", "instruments", "instrumental", "music", "melody", "keys", "guitar"]),
    ]

    /// The engine's stem name (`MixEngine.stemNames`).
    var stemName: String { rawValue }
    /// How Siri says it back ("Muted the vocals").
    var spoken: String {
        switch self {
        case .vocals: return "the vocals"
        case .drums: return "the drums"
        case .bass: return "the bass"
        case .other: return "the other instruments"
        }
    }
}

/// On / off — the one parameter of "Turn on Mix Mode" (a phrase carries ONE parameter, so the
/// switch state rides it instead of two App Shortcut slots).
enum MixModeSwitch: String, AppEnum, CaseIterable {
    case on, off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mix Mode State")
    static let caseDisplayRepresentations: [MixModeSwitch: DisplayRepresentation] = [
        .on: DisplayRepresentation(title: "On", synonyms: ["on", "enable", "start"]),
        .off: DisplayRepresentation(title: "Off", synonyms: ["off", "disable", "stop"]),
    ]
}
