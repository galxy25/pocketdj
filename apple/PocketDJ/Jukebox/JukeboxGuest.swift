import Foundation

/// The public guest view of a jukebox — the `state.json` the broker publishes to CloudFront and the
/// web guest page polls. A native device that JOINED a jukebox via link (`JukeboxLink`) reads the
/// SAME object to render now-playing / up-next / played and to know where to POST requests.
///
/// Every field is optional/defaulted so a partial or older `state.json` decodes leniently — the app
/// must never crash on a broker payload it only half-recognizes (the durable-JSON doctrine).
struct JukeboxGuestState: Codable, Equatable {
    var jukeboxId: String?
    var name: String?
    /// The session ended (auto-expiry or the host ended it) — the client shows a sign-off.
    var ended: Bool?
    /// View+Hear mode: guests may play `nowPlaying.streamUrl`. Off ⇒ request-line only.
    var hear: Bool?
    var nowPlaying: NowPlaying?
    var upNext: [Track]
    var played: [PlayedTrack]
    var requests: [GuestRequest]
    /// The broker's public request-endpoint base (the Funnel publicBase). Added to `state.json` so a
    /// native client that joined via link can POST requests without pre-configuring a server URL.
    /// Optional: when absent (older broker), the client falls back to its own configured jukebox
    /// server URL. See `JukeboxClient.submitGuestRequest`.
    var apiBase: String?

    struct NowPlaying: Codable, Equatable {
        var title: String?
        var artist: String?
        var lengthMs: Int?
        var positionMs: Int?
        var streamUrl: String?
    }
    struct Track: Codable, Equatable, Identifiable {
        var title: String?
        var artist: String?
        var id: String { (title ?? "") + "|" + (artist ?? "") }
    }
    struct PlayedTrack: Codable, Equatable, Identifiable {
        var title: String?
        var artist: String?
        var endedAt: Double?
        var id: String { (title ?? "") + "|" + (artist ?? "") + "|" + String(endedAt ?? 0) }
    }
    struct GuestRequest: Codable, Equatable, Identifiable {
        var id: String
        var title: String?
        var artist: String?
        /// pending | queued | denied | played
        var status: String?
    }

    init(jukeboxId: String?, name: String?, ended: Bool?, hear: Bool?, nowPlaying: NowPlaying?,
         upNext: [Track], played: [PlayedTrack], requests: [GuestRequest], apiBase: String?) {
        self.jukeboxId = jukeboxId; self.name = name; self.ended = ended; self.hear = hear
        self.nowPlaying = nowPlaying; self.upNext = upNext; self.played = played
        self.requests = requests; self.apiBase = apiBase
    }

    /// Lenient decode: a missing array (older/partial `state.json`) yields `[]` rather than throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jukeboxId = try c.decodeIfPresent(String.self, forKey: .jukeboxId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        ended = try c.decodeIfPresent(Bool.self, forKey: .ended)
        hear = try c.decodeIfPresent(Bool.self, forKey: .hear)
        nowPlaying = try c.decodeIfPresent(NowPlaying.self, forKey: .nowPlaying)
        upNext = (try? c.decode([Track].self, forKey: .upNext)) ?? []
        played = (try? c.decode([PlayedTrack].self, forKey: .played)) ?? []
        requests = (try? c.decode([GuestRequest].self, forKey: .requests)) ?? []
        apiBase = try c.decodeIfPresent(String.self, forKey: .apiBase)
    }

    static let empty = JukeboxGuestState(jukeboxId: nil, name: nil, ended: nil, hear: nil,
                                         nowPlaying: nil, upNext: [], played: [], requests: [],
                                         apiBase: nil)
}
