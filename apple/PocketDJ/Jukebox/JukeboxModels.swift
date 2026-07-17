import Foundation

// Jukebox Hero wire types — the session broker's API surface (docs/design/jukebox-hero.md).
// The jukebox server manages the SESSION between web-page guests and this app (the host):
// guests submit requests through it; the host polls them and posts decisions; the host also
// posts player-state snapshots, which the server merges with request statuses and publishes
// to S3 as the guests' `state.json` (S3 is the distribution — guests never poll the host).

/// A live jukebox session, as returned by `POST /jukebox` and persisted across launches
/// (UserDefaults) so an app restart doesn't strand a running party.
///
/// Lifecycle: a session EXPIRES 24 h after creation (guests see "ended") and the server's
/// sweeper DELETES it — page, state, request log — after 7 days… unless `timeless` is on
/// (set at creation or flipped later via `POST …/config`). The server owns all of that;
/// the app just displays it and lets the DJ toggle timeless.
struct JukeboxSessionInfo: Codable, Equatable {
    let jukeboxId: String
    /// Host-only bearer credential for state/requests/decision/end — NEVER shown to guests.
    let hostKey: String
    let name: String
    /// The guest page URL (the QR code's payload), e.g. `https://…cloudfront.net/jukebox/<id>/`.
    let url: String
    /// Never expires / never auto-deletes. Optional: older persisted sessions decode as nil (= off).
    var timeless: Bool?
    /// Epoch ms the session auto-ends (nil when timeless).
    var expiresAt: Double?
}

/// One guest song request. `seq` is the server's monotonic cursor (the host polls
/// `?since=<last seq>`); `status` is the server-side lifecycle guests see on the page.
struct JukeboxRequest: Codable, Equatable, Identifiable {
    let id: String
    let seq: Int
    let title: String
    let artist: String
    let createdAt: Double
    var status: String   // pending | queued | denied | played
}

/// The host's verdict on a request — the wire actions of `POST …/decision`.
/// `denied` refuses it; the rest are queue placements (all report "queued" to guests).
enum JukeboxDecisionAction: String, Codable, CaseIterable {
    case denied, next, end, random

    /// The host-facing verb (inbox buttons / context menu).
    var label: String {
        switch self {
        case .denied: return "Deny"
        case .next:   return "Play Next"
        case .end:    return "Play Last"
        case .random: return "Surprise Slot"
        }
    }
}

/// The player-state snapshot the host posts (`POST …/state`). The server stamps
/// `updatedAt`, merges the request statuses, and publishes the result for guests.
struct JukeboxStatePayload: Codable, Equatable {
    struct NowPlaying: Codable, Equatable {
        var title: String
        var artist: String
        var lengthMs: Int?
        /// Position at snapshot time — the guest page interpolates between polls.
        var positionMs: Int?
        /// View + Hear mode only: the current track's PUBLIC S3 rip mp3, when one exists
        /// — the guest page plays + position-syncs it. Only our own rips-bucket audio
        /// ever rides here (a live Apple Music stream is never redistributed; its
        /// stream-through-rip shows up on a later snapshot once durable). nil ⇒ this
        /// track is view-only even in hear mode.
        var streamUrl: String?
    }
    struct Track: Codable, Equatable {
        var title: String
        var artist: String
    }
    /// View + Hear mode (the DJ's toggle): guests may PLAY the current track from
    /// `nowPlaying.streamUrl`. Off (the default) ⇒ a pure request line — view only.
    var hear: Bool = false
    var nowPlaying: NowPlaying?
    var upNext: [Track]
}
