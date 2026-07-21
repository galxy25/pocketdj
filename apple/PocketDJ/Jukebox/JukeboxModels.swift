import Foundation

// Jukebox Hero wire types — the session broker's API surface (docs/design/jukebox-hero.md).
// The jukebox server manages the SESSION between web-page guests and this app (the host):
// guests submit requests through it; the host polls them and posts decisions; the host also
// posts player-state snapshots, which the server merges with request statuses and publishes
// to S3 as the guests' `state.json` (S3 is the distribution — guests never poll the host).
//
// A jukebox is a PRIVATE EVENT. The session is token-gated (on by default), holds a capped
// number of listeners, and expires. Anything a guest can HEAR is the DJ's own prepared copy
// of media the DJ owns in their cloud library, over a link scoped to this session — never
// audio captured from Apple Music, never another user's copy.
//
// #TOUPDATE: "token-gated" and "capped" are the TARGET. jukebox-server.mjs serves the guest
// page as a public object with no guest credential — tokenOk (:413) gates session CREATION
// only and fail-opens when JUKEBOX_TOKEN is unset — and the server's own header (:9) says it
// takes "any number of listeners"; the only limit is a per-IP request rate window. True when
// the guest routes reject a request carrying no valid per-session token and the server turns
// guests away once the listener cap is reached.
//
// #TOUPDATE: "expires" is the TARGET. `timeless` (below) is a shipped opt-out from both the
// auto-end and the 7-day delete sweep, so no session is guaranteed to end. True when expiry
// is unconditional — see the cut listed on the field.
//
// #TOUPDATE: "the DJ's own prepared copy … never audio captured from Apple Music" is the
// TARGET. Today the guest audio URL is the flat, public-read `rips/<songId>.mp3` object —
// one namespace shared by every user, unauthenticated, non-expiring — and rip-server.mjs:798
// routes every digital id to Apple Music capture regardless of the cloud-source flag. True
// when prepared copies are per-user, the guest link is minted per session and dies with it,
// and the server fails closed on media the DJ does not own in their cloud library.

/// A live jukebox session, as returned by `POST /jukebox` and persisted across launches
/// (UserDefaults) so an app restart doesn't strand a running party.
///
/// Lifecycle: every session EXPIRES 24 h after creation (guests see "ended") and the
/// server's sweeper DELETES it — page, state, request log — after 7 days. The server owns
/// all of that; the app just displays it.
struct JukeboxSessionInfo: Codable, Equatable {
    let jukeboxId: String
    /// Host-only bearer credential for state/requests/decision/end — NEVER shown to guests.
    let hostKey: String
    let name: String
    /// The guest page URL (the QR code's payload), e.g. `https://<jukebox host>/jukebox/<id>/`
    /// — it carries this session's guest token, so the code you show someone is what admits
    /// them, not the bare link.
    ///
    /// #TOUPDATE: there is no guest token. The server returns a bare public page URL
    /// (`${CFG.siteBase}/jukebox/${s.id}/`, jukebox-server.mjs:247) and the guest request
    /// route is explicitly public — anyone who gets the link is in. True when the URL carries
    /// a per-session token and both the guest page and its state.json refuse a request
    /// without one.
    let url: String
    /// Whether this session requires a per-session guest access token: guests need the code
    /// baked into `url` to get in. Seeded at create from Settings ▸ Jukebox Hero (ON by
    /// default) and overridable per session. Optional so older persisted sessions decode as
    /// nil (= treat as off). The token itself, once minted, never expires (a permanent code).
    ///
    /// #TOUPDATE: the server does not mint or enforce the guest token yet. `url` is still the
    /// bare public page (jukebox-server.mjs:247) and the guest request route is public (:446),
    /// so today this flag only records intent — it admits no one and turns no one away. True
    /// when the server mints the token into `url` and refuses tokenless guest requests.
    var requiresToken: Bool?
    /// Never expires / never auto-deletes. Optional: older persisted sessions decode as nil (= off).
    ///
    /// #TOUPDATE: this field must not exist — a jukebox session always expires. Deleting it
    /// alone strands the persisted sessions that already carry it, so it goes with the rest
    /// of the cut: JukeboxClient.configure's `/config` call, JukeboxStore.start(timeless:)
    /// and setTimeless, both Toggles in JukeboxView, and in jukebox-server.mjs expiryOf
    /// (:121), the /config route (:250) and both `!s.timeless` gates (:339, :362) — plus a
    /// backfill stamping an expiresAt on sessions already persisted as timeless, or they
    /// outlive the removal.
    var timeless: Bool?
    /// Epoch ms the session auto-ends (nil only on a legacy `timeless` session).
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
        /// View + Hear mode only: the current track's audio for the guest page to play +
        /// position-sync — the DJ's OWN prepared copy, over a link scoped to this session
        /// and dying with it. nil ⇒ the track is view-only even in hear mode, which is what
        /// a track playing through Apple Music always is: Apple Music is playback, nothing
        /// is captured from it, so there is no copy to hand a guest.
        ///
        /// #TOUPDATE: "the DJ's own prepared copy, over a link scoped to this session" is
        /// the TARGET. Today this carries the PUBLIC, unauthenticated, NON-EXPIRING
        /// `rips/<songId>.mp3` object (JukeboxStore.hearStreamURL → RipsStore.cachedURL) out
        /// of the flat namespace shared by every user — no token, no listener cap, and it
        /// outlives the session's 7-day sweep — and rip-server.mjs:798 captures Apple Music
        /// audio into that same namespace, so an Apple-Music-sourced track CAN have an
        /// object here. Until this is a per-user copy behind a per-session signed URL with a
        /// listener cap, and capture is gone, NO user-facing copy may call a jukebox private
        /// or bounded.
        ///
        /// #TOUPDATE: the "hear-only" guard above is CLIENT-side (JukeboxStore.hearStreamURL);
        /// the broker's sanitizeNowPlaying (jukebox-server.mjs:183) gates only on https, not
        /// on `hear` — an unauthenticated broker does not enforce our invariant. True when
        /// the server drops streamUrl unless the session's own hear flag is on.
        var streamUrl: String?
    }
    struct Track: Codable, Equatable {
        var title: String
        var artist: String
    }
    /// View + Hear mode (the DJ's toggle): guests may PLAY the current track from
    /// `nowPlaying.streamUrl` — the DJ's own prepared copy, nothing else. Off (the default)
    /// ⇒ a pure request line, view only. Enforced host-side when composing the snapshot; the
    /// broker does not re-check it (see the `streamUrl` markers above).
    var hear: Bool = false
    var nowPlaying: NowPlaying?
    var upNext: [Track]
}
