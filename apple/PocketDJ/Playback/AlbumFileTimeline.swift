import Foundation

/// The song layout of ONE shared analog album file (a vinyl side ripped as a single
/// `rips/<albumId>.mp3`, every song a `startMs` offset into it — see `rip-server.mjs`
/// `runAnalogJob`). Built from the rips manifest (the starts playback actually seeks to) plus
/// the catalog's side layout (`SegmentOverrides`): user boundary edits, the detected song ends,
/// and which songs really belong to the album.
///
/// Why it exists (Levi, 2026-11-07): a song on a vinyl side used to END at `startMs + catalog
/// length`, and the catalog length (iTunes / Discogs) rarely matches the record — songs were cut
/// off mid-phrase, or the next song's opening played under the previous title. Now a song ends
/// at its DETECTED end plus a fade grace (detection ends a quiet fade early — the median
/// detected gap between songs is ~9 s on a record whose real gaps are 2–4 s), never past the
/// next song's start; a user-edited end is exact. The set glides from one song to the next
/// inside the same file, skipping a long gap (a side flip, the run-out groove) with an in-place
/// seek instead of playing a minute of needle noise.
struct AlbumFileTimeline: Equatable {
    struct Segment: Equatable {
        let songId: String
        let startMs: Int
    }

    /// How far past a DETECTED end a song keeps playing (capped at the next song's start).
    static let fadeGraceMs = 15_000

    /// The manifest key of the shared file (`rips/<albumId>.mp3`).
    let key: String
    /// Sorted by `startMs`, strictly increasing (a duplicate start keeps the first id).
    let segments: [Segment]
    /// Per-song ends known from the catalog: `exact` (a user edit) or detected (+ grace).
    let exactEndMs: [String: Int]
    let detectedEndMs: [String: Int]

    init(key: String, segments: [Segment], exactEndMs: [String: Int] = [:], detectedEndMs: [String: Int] = [:]) {
        self.key = key
        var out: [Segment] = []
        for s in segments.sorted(by: { ($0.startMs, $0.songId) < ($1.startMs, $1.songId) })
        where out.last?.startMs != s.startMs {
            out.append(s)
        }
        self.segments = out
        self.exactEndMs = exactEndMs
        self.detectedEndMs = detectedEndMs
    }

    /// The timeline of the shared file `songId` plays from, or nil when the song isn't a slice
    /// of a multi-song file (not in the manifest, no `startMs`, a per-song digital rip).
    /// O(manifest) — callers run it once per track start / view appearance, never per frame.
    static func forSong(_ songId: String, manifest: [String: RipsStore.ManifestEntry],
                        layout: SegmentOverrides.Snapshot = .init()) -> AlbumFileTimeline? {
        guard let entry = manifest[songId], entry.startMs != nil else { return nil }
        return forKey(entry.key, manifest: manifest, layout: layout,
                      members: layout.albumOfSong[songId].flatMap { layout.albumTracks[$0] })
    }

    /// The timeline of the file at manifest `key` (nil when no song sits in it). `members`
    /// (the album's track list) drops stale manifest entries that still point at the file
    /// under a song id the album no longer has (a re-split) — they'd end a real song early.
    static func forKey(_ key: String, manifest: [String: RipsStore.ManifestEntry],
                       layout: SegmentOverrides.Snapshot = .init(),
                       members: Set<String>? = nil) -> AlbumFileTimeline? {
        var segs: [Segment] = []
        for (id, e) in manifest where e.key == key {
            if let members, !members.contains(id) { continue }
            if let s = layout.startMs[id] ?? e.startMs { segs.append(Segment(songId: id, startMs: s)) }
        }
        guard !segs.isEmpty else { return nil }
        return AlbumFileTimeline(key: key, segments: segs, exactEndMs: layout.endMs,
                                 detectedEndMs: layout.detectedEndMs)
    }

    func segment(for songId: String) -> Segment? { segments.first { $0.songId == songId } }

    /// The segment right after `songId` on the record (nil when it's the last, or unknown).
    func next(after songId: String) -> Segment? {
        guard let i = segments.firstIndex(where: { $0.songId == songId }), i + 1 < segments.count
        else { return nil }
        return segments[i + 1]
    }

    /// Where `songId` ends inside the file: its edited end, else its detected end + the fade
    /// grace — never past the next song's start (and never at or before its own). With no
    /// known end it runs to the next song's start; nil = the last song with no known end (it
    /// runs to the file's natural end) or a song this timeline doesn't hold.
    func endMs(of songId: String) -> Int? {
        guard let seg = segment(for: songId) else { return nil }
        let nextStart = next(after: songId)?.startMs
        let own = exactEndMs[songId] ?? detectedEndMs[songId].map { $0 + Self.fadeGraceMs }
        guard let own, own > seg.startMs else { return nextStart }
        return nextStart.map { min(own, $0) } ?? own
    }

    /// The song playing at absolute file position `ms` (a position before the first song's
    /// start — the lead-in groove — belongs to the first song).
    func segment(atMs ms: Int) -> Segment? {
        guard let first = segments.first else { return nil }
        return segments.last { $0.startMs <= ms } ?? first
    }
}

/// The catalog's layout of every vinyl side, keyed by song id: the user's boundary edits
/// (where a song STARTS / ENDS inside its side — exact), the detected song ends, and album
/// membership. Derived from the synced `EditsDocument` (`AlbumEdit.audioTracks`) + the indexed
/// albums by `AppModel` on every overlay, so an edit made on one device re-times playback on
/// every device. A shared main-actor singleton because the playback layer (`RipsStore`,
/// `BurnStore`, `SetlistPlayer`) has no `AppModel` to ask.
@MainActor
@Observable
final class SegmentOverrides {
    static let shared = SegmentOverrides()

    struct Snapshot: Equatable, Sendable {
        /// User-edited starts / ends (exact).
        var startMs: [String: Int] = [:]
        var endMs: [String: Int] = [:]
        /// The indexer's detected song ends (edits applied), for albums whose segments pair 1:1
        /// with their track list.
        var detectedEndMs: [String: Int] = [:]
        var albumOfSong: [String: String] = [:]
        var albumTracks: [String: Set<String>] = [:]
    }

    private(set) var snapshot = Snapshot()

    func update(_ s: Snapshot) { if s != snapshot { snapshot = s } }

    /// The edited start of `songId` inside its shared file (nil = keep the detected start).
    func startMs(_ songId: String) -> Int? { snapshot.startMs[songId] }

    /// Pure: the layout an edits document + the effective (edit-overlaid) albums imply. Each
    /// album edit's segment deltas are matched onto the RAW album's detected segments exactly
    /// like the display overlay (`trackNumber` first, else array position), and segment `i`
    /// belongs to the album's `i`-th song in track order — the same order `apply-audio.mjs`
    /// stamped the songs' `pointer.startMs` from. An album whose segment count doesn't match its
    /// song count is skipped (the pairing would be a guess).
    nonisolated static func derive(albumEdits: [String: AlbumEdit],
                                   rawAlbum: (String) -> IndexAlbum?,
                                   orderedSongIds: (String) -> [String],
                                   effectiveAlbums: [IndexAlbum] = []) -> Snapshot {
        var out = Snapshot()
        for album in effectiveAlbums {
            guard let segs = album.audioTracks, !segs.isEmpty, segs.count == album.trackList.count else { continue }
            out.albumTracks[album.id] = Set(album.trackList)
            for (i, id) in album.trackList.enumerated() {
                out.albumOfSong[id] = album.id
                if let e = segs[i].endMs { out.detectedEndMs[id] = e }
            }
        }
        for (albumId, edit) in albumEdits {
            guard let deltas = edit.audioTracks, !deltas.isEmpty,
                  let segs = rawAlbum(albumId)?.audioTracks, !segs.isEmpty else { continue }
            let songs = orderedSongIds(albumId)
            guard songs.count == segs.count else { continue }
            for (i, seg) in segs.enumerated() {
                let byNumber = seg.trackNumber.flatMap { n in deltas.first { $0.trackNumber == n } }
                let positional = (i < deltas.count && deltas[i].trackNumber == nil) ? deltas[i] : nil
                guard let d = byNumber ?? positional else { continue }
                if let s = d.startMs { out.startMs[songs[i]] = s }
                if let e = d.endMs { out.endMs[songs[i]] = e }
            }
        }
        return out
    }
}
