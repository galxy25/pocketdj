import Foundation

// Music with Friends wire types — the broker's member-state / public-state payloads.
// ALL fields optional / lenient decode (the JukeboxGuest doctrine): a newer server's
// extra fields — or an older server's missing ones — must never break the app.

struct MwFSettings: Codable, Equatable {
    var turnSeconds: Int?
    var acceptOutsideTurn: Bool?
    var turnEndsOnFirstSuggestion: Bool?

    init(turnSeconds: Int? = nil, acceptOutsideTurn: Bool? = nil, turnEndsOnFirstSuggestion: Bool? = nil) {
        self.turnSeconds = turnSeconds
        self.acceptOutsideTurn = acceptOutsideTurn
        self.turnEndsOnFirstSuggestion = turnEndsOnFirstSuggestion
    }
}

struct MwFMember: Codable, Equatable, Identifiable {
    var memberId: String?
    var name: String?
    var joinedAt: Double?
    var score: Int?
    var isLeader: Bool?
    var id: String { memberId ?? "" }
}

struct MwFMatch: Codable, Equatable {
    var songId: String?
    var appleMusicId: String?
    var title: String?
    var artist: String?
    var lengthMs: Int?
}

struct MwFSuggestion: Codable, Equatable, Identifiable {
    var id: String?
    var seq: Int?
    var memberId: String?
    var title: String?
    var artist: String?
    var createdAt: Double?
    /// pending | accepted | rejected
    var status: String?
    var decidedAt: Double?
    var plusOnes: [String]?
    var match: MwFMatch?
}

struct MwFCollectionEntry: Codable, Equatable {
    var songId: String?
    var appleMusicId: String?
    var title: String?
    var artist: String?
    var lengthMs: Int?
    var suggestedBy: String?
    var acceptedAt: Double?
}

struct MwFTurn: Codable, Equatable {
    var memberId: String?
    var index: Int?
    /// Epoch ms the current turn expires.
    var deadline: Double?
}

struct MwFYou: Codable, Equatable {
    var memberId: String?
}

/// The member-state payload (`GET /mwf/:id/state`) — also the shape of the public
/// `state.json` (which just omits `you`).
struct MwFState: Codable, Equatable {
    var v: Int?
    var sessionId: String?
    var name: String?
    var theme: String?
    var updatedAt: Double?
    var ended: Bool?
    var expiresAt: Double?
    var settings: MwFSettings?
    var members: [MwFMember]?
    var turn: MwFTurn?
    var suggestions: [MwFSuggestion]?
    var collection: [MwFCollectionEntry]?
    var you: MwFYou?
    /// The broker's public request base (the jukebox state.json convention) — lets a
    /// scanned link join without any pre-configured server URL.
    var apiBase: String?

    /// The caller's derived score from the members list (nil memberId ⇒ 0).
    func score(of memberId: String?) -> Int {
        guard let memberId else { return 0 }
        return members?.first { $0.memberId == memberId }?.score ?? 0
    }
}

/// ONE persisted shape for leader + joined sessions (UserDefaults `pdj.mwf.sessions.v1`).
/// `leaderKey != nil` ⇒ this device is the leader. All-optional additive fields so a
/// future build's extras never wipe the list.
struct MwFSessionEntry: Codable, Identifiable, Hashable {
    var id: String            // sessionId
    var memberId: String
    var memberKey: String
    var leaderKey: String?
    var name: String?
    var theme: String?
    var url: String?          // share URL (the landing page)
    var apiBase: String?      // broker base for absolute calls (from public state.json)
    var expiresAt: Double?
    var pocketId: String?     // local pocket materialized by Download (idempotence)
    var joinedAt: Double

    var isLeader: Bool { leaderKey != nil }
}
