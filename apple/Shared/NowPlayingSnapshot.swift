import Foundation

/// The Now Playing state the app publishes and the widget reads — the ONLY thing that
/// crosses the app↔widget process boundary (plus the cover PNG next to it). Deliberately
/// tiny + `Codable` so it round-trips through the shared App Group `UserDefaults`.
///
/// Compiled into BOTH the app target (writer) and `PocketDJWidgets` (reader). The cover
/// image is kept as a file (PNG bytes) rather than in the struct so the defaults blob stays
/// small; `coverVersion` bumps whenever the file changes so the widget's timeline reloads.
struct NowPlayingSnapshot: Codable, Equatable {
    /// Whether audio is actually playing right now (drives the ▶/⏸ glyph).
    var isPlaying: Bool
    /// True when there IS a current track (a set is running or a single track plays); false
    /// shows the widget's idle "Nothing playing" state.
    var hasContent: Bool
    var title: String
    var artist: String
    /// The current song id (for the widget's deep-link + cover correlation); nil when idle.
    var songId: String?
    /// Bumps each time the cover PNG file is rewritten, so the widget re-reads it.
    var coverVersion: Int
    /// The not-yet-played tail of the running set (empty for a single-track play or idle).
    var upNext: [Track]
    /// Whether the current track is favorited — drives the widget's ♥ (heart.fill / heart) glyph.
    /// Decode-tolerant (see `init(from:)`): a stale blob written by an OLD app build that predates
    /// this field decodes with `false` rather than fail-decoding the whole snapshot to `.empty`.
    var isFavorite: Bool
    /// The current track's Apple Music catalog id when it has one (nil for vinyl / My Digital /
    /// Studio). Carried so a widget ♥ reaches Apple Music via the owner-gated sync; a local track
    /// without one still favorites, it just never syncs upstream.
    var appleMusicId: String?
    /// The running set's whole-session repeat mode (`RepeatMode` rawValue: "off"/"all"/"one"), or
    /// "off" when no set is running. Drives the widget's repeat glyph. Decode-tolerant (a blob from
    /// an OLD app build that predates this field decodes to "off").
    var repeatMode: String
    /// Whether the running set's upcoming tail is live-shuffled — drives the widget's shuffle glyph.
    /// Decode-tolerant (defaults false for pre-existing blobs).
    var shuffleEnabled: Bool

    struct Track: Codable, Equatable, Identifiable {
        /// Per-row identity (the setlist `Item.uid`), so repeats render as distinct rows.
        var id: String
        var songId: String
        var title: String
        var artist: String
    }

    init(isPlaying: Bool, hasContent: Bool, title: String, artist: String, songId: String?,
         coverVersion: Int, upNext: [Track], isFavorite: Bool = false, appleMusicId: String? = nil,
         repeatMode: String = "off", shuffleEnabled: Bool = false) {
        self.isPlaying = isPlaying
        self.hasContent = hasContent
        self.title = title
        self.artist = artist
        self.songId = songId
        self.coverVersion = coverVersion
        self.upNext = upNext
        self.isFavorite = isFavorite
        self.appleMusicId = appleMusicId
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
    }

    /// Custom decode ONLY to tolerate blobs written before `isFavorite`/`appleMusicId` existed:
    /// the two new keys are `decodeIfPresent` so a stale snapshot from an older app build still
    /// decodes (missing `isFavorite` → false) instead of throwing and yielding `.empty`. Every
    /// pre-existing key stays required, exactly as the synthesized decoder had them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
        hasContent = try c.decode(Bool.self, forKey: .hasContent)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        songId = try c.decodeIfPresent(String.self, forKey: .songId)
        coverVersion = try c.decode(Int.self, forKey: .coverVersion)
        upNext = try c.decode([Track].self, forKey: .upNext)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        appleMusicId = try c.decodeIfPresent(String.self, forKey: .appleMusicId)
        repeatMode = try c.decodeIfPresent(String.self, forKey: .repeatMode) ?? "off"
        shuffleEnabled = try c.decodeIfPresent(Bool.self, forKey: .shuffleEnabled) ?? false
    }

    static let empty = NowPlayingSnapshot(isPlaying: false, hasContent: false,
                                          title: "", artist: "", songId: nil,
                                          coverVersion: 0, upNext: [],
                                          isFavorite: false, appleMusicId: nil)
}

/// The shared App Group container the app writes and the widget reads. One place owns the
/// group id, the keys, and the cover file path so the two targets can't drift.
enum NowPlayingShared {
    /// MUST match the App Group in every entitlements file (app + widget, all SDKs).
    static let appGroup = "group.com.levi.pocketdj"
    private static let snapshotKey = "nowPlayingSnapshot.v1"
    static let coverFileName = "nowplaying-cover.png"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
    /// The current track's cover PNG (written by the app, read by the widget). nil if the
    /// shared container is unavailable (e.g. the App Group isn't provisioned yet).
    static var coverURL: URL? { containerURL?.appendingPathComponent(coverFileName) }

    static func write(_ snapshot: NowPlayingSnapshot) {
        guard let d = defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        d.set(data, forKey: snapshotKey)
    }

    /// The last-published snapshot, or `.empty` when nothing has been written / decode fails.
    static func read() -> NowPlayingSnapshot {
        guard let d = defaults, let data = d.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        else { return .empty }
        return snap
    }

    /// Read the current cover PNG bytes (widget side), or nil if none has been written.
    static func readCoverData() -> Data? {
        guard let url = coverURL else { return nil }
        return try? Data(contentsOf: url)
    }
}
