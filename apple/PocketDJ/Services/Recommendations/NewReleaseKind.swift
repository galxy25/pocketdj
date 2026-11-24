import Foundation

// ============================================================================
// MARK: - New ▸ albums vs singles
// ============================================================================
//
// Design: docs/design/foryou-new-kind-filter.md. Levi, 2026-11-23: "for New we should be able to
// hide or sort albums vs singles; for me I would only want to see albums, for others singles, and
// others albums first and then singles — as three separate user stories".
//
// ONE pure function decides what a mode shows, because FOUR places derive "the New list" (the
// screen, the grid's count, the tile's ▶ menu, CarPlay) and two implementations kept in step by
// hand is how a tile promises 4 and its screen shows 3. Pure and platform-free on purpose: the
// Android twin (`NewReleaseKind.kt`) mirrors it case for case.

/// What a release IS for filtering purposes — not what Apple's `releaseKind` claims it is.
enum ReleaseKindClass: String, Equatable, Sendable {
    case album, ep, single

    /// The filter has two buckets: album = {album, EP, compilation}; single = {single}. An EP is a
    /// body of work; someone saying "only albums" is avoiding the trickle of one-song drops.
    var isAlbumBucket: Bool { self != .single }
}

/// Which releases New shows, and in what order. Raw values are PERSISTED — never rename them.
/// `.all` is the default for fresh installs AND upgrades and must reproduce today's screen exactly.
enum NewReleaseKindFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, albums, singles, albumsFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:         return "Everything"
        case .albums:      return "Albums only"
        case .singles:     return "Singles only"
        case .albumsFirst: return "Albums, then singles"
        }
    }

    var systemImage: String {
        switch self {
        case .all:         return "square.stack"
        case .albums:      return "opticaldisc"
        case .singles:     return "music.note"
        case .albumsFirst: return "list.number"
        }
    }

    /// Missing or unknown raw → `.all` (upgrade-safe).
    static func from(_ raw: String?) -> NewReleaseKindFilter {
        raw.flatMap(NewReleaseKindFilter.init(rawValue:)) ?? .all
    }
}

enum NewReleaseKinds {

    // MARK: classify

    /// First match wins. Apple suffixes catalog names with " - Single" / " - EP", so the NAME is the
    /// most trustworthy signal (`AppModel`'s mapping never yields "ep" and calls every non-single
    /// "album"); the flag comes next; the track count only guesses WHEN THERE IS NO FLAG (Apple's own rule: 1–3 tracks
    /// single, 4–6 EP). An Apple-declared single with many tracks (a remix bundle) stays a single.
    static func classify(kind: String?, name: String?, trackCount: Int?) -> ReleaseKindClass {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.hasSuffix(" - single") || n.hasSuffix(" – single") { return .single }
        if n.hasSuffix(" - ep") || n.hasSuffix(" – ep") { return .ep }
        switch kind?.lowercased() {
        case "single"?: return .single
        case "ep"?:     return .ep
        case "album"?, "compilation"?:
            // Apple's (or the feed's) own word wins over the track-count guess: a 2-track classical
            // work or a pre-order announced with its lead tracks is still an album, and a
            // 5-track compilation is still a compilation.
            return .album
        default:        break
        }
        if let t = trackCount {
            if (1...3).contains(t) { return .single }
            if (4...6).contains(t) { return .ep }
        }
        return .album
    }

    /// The row badge: the CLASS, so a 2-track "album" under Singles only doesn't wear "Album".
    /// Compilation keeps its own word (it filters as an album).
    static func badge(kind: String?, cls: ReleaseKindClass) -> String {
        if cls == .album, kind?.lowercased() == "compilation" { return "Compilation" }
        switch cls {
        case .album:  return "Album"
        case .ep:     return "EP"
        case .single: return "Single"
        }
    }

    // MARK: arrange

    struct Arranged<T> {
        /// Album bucket in display order (empty in `.singles`). In `.all` it holds everything.
        var albums: [T]
        /// Single bucket in display order (empty in `.albums` and `.all`).
        var singles: [T]
        /// True only for `.albumsFirst`: render the two group headers.
        var grouped: Bool
        /// What renders / plays, in order. `.all` → `sink(items)` untouched.
        var flat: [T]
        var hiddenAlbums: Int   // includes EPs
        var hiddenEPs: Int      // subset of hiddenAlbums, for the copy
        var hiddenSingles: Int

        var hiddenTotal: Int { hiddenAlbums + hiddenSingles }
    }

    /// Filter + order ONE section. `sink` is the existing rejected-sinks-last rule, applied INSIDE
    /// each group so a 👎'd album sinks below the live albums but stays above the singles.
    static func arrange<T>(_ items: [T], mode: NewReleaseKindFilter,
                           cls: (T) -> ReleaseKindClass,
                           sink: ([T]) -> [T] = { $0 }) -> Arranged<T> {
        switch mode {
        case .all:
            let flat = sink(items)
            return Arranged(albums: flat, singles: [], grouped: false, flat: flat,
                            hiddenAlbums: 0, hiddenEPs: 0, hiddenSingles: 0)
        case .albums:
            let a = items.filter { cls($0).isAlbumBucket }
            let hidden = items.count - a.count
            let albums = sink(a)
            return Arranged(albums: albums, singles: [], grouped: false, flat: albums,
                            hiddenAlbums: 0, hiddenEPs: 0, hiddenSingles: hidden)
        case .singles:
            let s = items.filter { !cls($0).isAlbumBucket }
            let hiddenAlbums = items.count - s.count
            let eps = items.filter { cls($0) == .ep }.count
            let singles = sink(s)
            return Arranged(albums: [], singles: singles, grouped: false, flat: singles,
                            hiddenAlbums: hiddenAlbums, hiddenEPs: eps, hiddenSingles: 0)
        case .albumsFirst:
            let albums = sink(items.filter { cls($0).isAlbumBucket })
            let singles = sink(items.filter { !cls($0).isAlbumBucket })
            return Arranged(albums: albums, singles: singles, grouped: true, flat: albums + singles,
                            hiddenAlbums: 0, hiddenEPs: 0, hiddenSingles: 0)
        }
    }

    /// "3 singles hidden" · "1 single hidden" · "2 albums hidden" · "2 albums & EPs hidden" (any EP
    /// among them) · nil when nothing is hidden. Albums and singles are never hidden together.
    static func hiddenNote(albums: Int, eps: Int, singles: Int) -> String? {
        var parts: [String] = []
        if albums > 0 {
            parts.append("\(albums) \(eps > 0 ? "albums & EPs" : (albums == 1 ? "album" : "albums"))")
        }
        if singles > 0 { parts.append("\(singles) \(singles == 1 ? "single" : "singles")") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ") + " hidden"
    }

    /// The Albums-only footer caveat: the feed keeps ONE latest release per artist, so a newer
    /// single can displace that artist's album. Nil outside `.albums` or when no single is hidden.
    static func footerCaveat(mode: NewReleaseKindFilter, hiddenSingles: Int) -> String? {
        mode == .albums && hiddenSingles > 0 ? "A newer single can hide an artist's album." : nil
    }

    /// The word for what a mode is looking at, for "No new albums" / "No new singles".
    static func shownNoun(_ mode: NewReleaseKindFilter) -> String {
        mode == .singles ? "singles" : "albums"
    }

    /// The filter-emptied tile / car line: "No new albums · 3 singles hidden".
    static func emptyNote(mode: NewReleaseKindFilter, hidden: String) -> String {
        "No new \(shownNoun(mode)) · \(hidden)"
    }

    // MARK: the live out-now list (tile menu + CarPlay)

    /// What ▶/🔀 plays for the New tile: out now, not yet 👍'd, arranged by `mode`, 👎 dropped.
    /// ONE derivation for the tile menu and CarPlay so the car plays what the phone's screen plays.
    /// `ReleaseStreaming.maxReleases` caps AFTER this ordering, so in `.albumsFirst` the singles
    /// are the ones cut — which follows directly from "albums first".
    @MainActor
    static func liveOutNow(outNow: [ReleaseFeedItem], feedback: RecFeedbackStore?, scope: String,
                           mode: NewReleaseKindFilter, nowMs: Double) -> [ReleaseFeedItem] {
        let sunk = feedback?.activeTombstones(scope: scope, nowMs: nowMs) ?? [:]
        let accepted = feedback?.acceptedInScope(scope) ?? [:]
        let offered = outNow.filter { accepted[$0.feedbackId] == nil }
        let arranged = arrange(offered, mode: mode, cls: { $0.entry.kindClass },
                               sink: { items in
                                   items.filter { sunk[$0.feedbackId] == nil }
                                       + items.filter { sunk[$0.feedbackId] != nil }
                               })
        return arranged.flat.filter { sunk[$0.feedbackId] == nil }
    }
}

extension ArtistReleaseEntry {
    var kindClass: ReleaseKindClass {
        NewReleaseKinds.classify(kind: releaseKind, name: releaseName, trackCount: trackCount)
    }
}

extension LikedRelease {
    var kindClass: ReleaseKindClass {
        NewReleaseKinds.classify(kind: kind, name: title, trackCount: trackCount)
    }
}
