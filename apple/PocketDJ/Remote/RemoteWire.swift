import Foundation

// ============================================================================
// MARK: - Remote (SharePlay) wire format
// ============================================================================
//
// Every message between PocketDJ devices in a Remote session rides ONE versioned envelope:
//
//     { "v": 1, "kind": "<kind>", "payload": <base64 JSON of the kind's body> }
//
// Forward-compat rules (Phase 2 — multiplayer Mix — adds kinds over the SAME session):
//   • `kind` is an open string, never a closed enum on the wire. A receiver that doesn't know a
//     kind IGNORES the message (it never fails the session) — so a newer peer can speak Mix
//     events to an older one that only understands playback.
//   • `v` is the ENVELOPE version. A receiver drops envelopes with `v` above what it speaks.
//   • Bodies follow the app's additive-optional doctrine (new fields optional/defaulted), and a
//     body that fails to decode (e.g. an unknown `RemoteCommand` case) is dropped, not fatal.
//
// Song identity crosses devices as ids + title/artist (+ the Apple Music store id when known).
// Never a rip URL, a presigned link, or a token: each device resolves the row against its OWN
// catalog / Apple Music subscription (`RemoteSongResolver`).

enum RemoteWire {
    /// The envelope version this build speaks.
    static let version = 1
}

/// The two flavours of session. Rides the GroupActivity itself (so a joiner knows the mode
/// before any message arrives) and every state broadcast.
enum RemoteSessionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Everyone plays the music in sync; anyone may drive.
    case listenTogether
    /// The starter's phone is a REMOTE CONTROL (no local audio); the joiner (a passenger's phone
    /// on the car stereo) is the speaker.
    case backseat
    var id: String { rawValue }
    var title: String { self == .backseat ? "Backseat" : "Listen Together" }
}

/// What THIS device does in the session. Any participant may flip its own role.
enum RemoteDeviceRole: String, Codable, Sendable {
    /// Plays the session's audio locally, in sync.
    case speaker
    /// Plays nothing — drives the speakers (the Backseat remote).
    case controller
}

/// Known message kinds. The wire carries `rawValue`; unknown strings are ignored on receipt.
enum RemoteMessageKind: String, Sendable {
    case hello            // RemoteHello — who I am + my role (re-sent when the roster changes)
    case state            // RemotePlaybackState — host → all (on every revision, a join, a request)
    case heartbeat        // RemoteHeartbeat — host → all every 2 s (small: revision + position)
    case stateRequest     // RemoteStateRequest — anyone → a host ("send me your full state")
    case command          // RemoteCommandMessage — anyone → host
    case ping             // RemotePing — participant → host (unreliable)
    case pong             // RemotePong — host → that participant (unreliable)
    case availability     // RemoteAvailability — "these rows can't play on <device>"
}

/// The versioned envelope (see the file header).
struct RemoteEnvelope: Codable, Sendable, Equatable {
    var v: Int
    var kind: String
    var payload: Data

    static func make<T: Encodable>(_ kind: RemoteMessageKind, _ body: T) throws -> RemoteEnvelope {
        RemoteEnvelope(v: RemoteWire.version, kind: kind.rawValue, payload: try JSONEncoder().encode(body))
    }

    /// The known kind, or nil (unknown kind / newer envelope) — the receiver then ignores it.
    var knownKind: RemoteMessageKind? {
        guard v <= RemoteWire.version else { return nil }
        return RemoteMessageKind(rawValue: kind)
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: payload) }
}

// MARK: - Bodies

/// One queue row on the wire: the durable-session `Row` (songId/title/artist/length/edition)
/// plus a HOST-ASSIGNED per-instance id (`rid`) — a song can repeat in a set, so commands
/// (jump / remove / move) address rows by `rid`, never by songId or a racy index.
struct RemoteRow: Codable, Equatable {
    var rid: String
    var row: PlaybackSessionStore.Row

    var songId: String { row.songId }
    var title: String { row.title }
    var artist: String { row.artist }

    init(rid: String = UUID().uuidString, row: PlaybackSessionStore.Row) {
        self.rid = rid
        self.row = row
    }

    init(item: SetlistPlayer.Item, rid: String? = nil, appleMusicId: String? = nil) {
        self.rid = rid ?? item.uid.uuidString
        self.row = PlaybackSessionStore.Row(songId: item.id, title: item.title, artist: item.artist,
                                            lengthMs: item.lengthMs, repeatCount: item.repeatCount,
                                            variant: item.variant?.rawValue,
                                            editionLocked: item.editionLocked ? true : nil,
                                            appleMusicId: appleMusicId)
    }
}

/// The host's authoritative playback state. The queue/index/repeat/shuffle/position fields are
/// the durable-session `Snapshot` verbatim (one codable shape for "a run" across the app); the
/// remote-only fields ride beside it.
///
/// The snapshot's queue is a WINDOW of the host's queue (a 26k-row set must never exceed the
/// messenger's payload limit): `windowStart` is the absolute index of `snapshot.queue[0]`,
/// `snapshot.index` is RELATIVE to the window, and `rowIds[i]` is `snapshot.queue[i]`'s rid.
struct RemotePlaybackState: Codable, Equatable {
    /// Monotonic, host-assigned. Receivers apply structure only from a NEWER revision.
    var revision: Int
    var hostId: String
    var mode: RemoteSessionMode
    var snapshot: PlaybackSessionStore.Snapshot
    var rowIds: [String]
    var windowStart: Int
    var totalCount: Int
    /// The position was `snapshot.positionMs` at THIS shared-clock time (ms on the host's clock).
    /// While playing, position(now) = positionMs + (sharedNow − anchorSharedTime).
    var anchorSharedTime: Double
    /// The host's session has something going (a queue, or a Phase-2 extension such as Mix
    /// Together). Optional/additive: absent (an older build) ⇒ derived from the rows. A host
    /// never yields to — and a participant never switches to — an INACTIVE host's state while
    /// the one it follows is active (an empty self-elected host must not wipe a real session).
    var sessionActive: Bool? = nil

    var isActiveSession: Bool { sessionActive ?? !rowIds.isEmpty }

    var rows: [RemoteRow] {
        zip(rowIds, snapshot.queue).map { RemoteRow(rid: $0, row: $1) }
    }
    var currentRow: RemoteRow? {
        let i = snapshot.index
        guard i >= 0, i < snapshot.queue.count, i < rowIds.count else { return nil }
        return RemoteRow(rid: rowIds[i], row: snapshot.queue[i])
    }
    var isPlaying: Bool { snapshot.isPlaying }
    var repeatMode: RepeatMode { snapshot.repeatMode.flatMap(RepeatMode.init(rawValue:)) ?? .off }
    var shuffleEnabled: Bool { snapshot.shuffleEnabled ?? false }

    /// Song-relative position at shared time `sharedNow`.
    func positionMs(at sharedNow: Double) -> Int {
        guard snapshot.isPlaying else { return snapshot.positionMs }
        return max(0, snapshot.positionMs + Int((sharedNow - anchorSharedTime).rounded()))
    }
}

/// A transport/queue command. Participants send these to the host; the host applies them to its
/// `RemoteQueueModel` and broadcasts the new state. A case this build doesn't know fails to
/// decode and the message is dropped (the forward-compat rule).
enum RemoteCommand: Codable, Equatable {
    case play(rows: [RemoteRow], startIndex: Int)
    /// Insert right after the current row and start it (the "Play Now" of a search result).
    case playNow(rows: [RemoteRow])
    case playPause
    case setPlaying(Bool)
    case seek(ms: Int)
    case skipNext
    case skipPrevious
    case jumpTo(rid: String)
    case enqueueNext(rows: [RemoteRow])
    case append(rows: [RemoteRow])
    case remove(rid: String)
    /// Move an upcoming row to a 0-based offset within the upcoming tail.
    case move(rid: String, toUpcomingOffset: Int)
    /// Re-order the listed upcoming rids into exactly this relative order (rows not listed —
    /// e.g. unavailable on the sender — keep their slots). A speaker's local drag-reorder.
    case reorder(rids: [String])
    case setRepeat(RepeatMode)
    case setShuffle(Bool)
    /// A speaker's track ENDED and it advanced on its own. Applied only while `fromRid` is still
    /// current, so N speakers reporting the same natural advance move the set exactly once.
    case advanced(fromRid: String)
}

/// The host's small periodic beat (every `heartbeatMs`): enough for a receiver to keep its
/// position anchor fresh and to notice a MISSED revision (→ `stateRequest`), without re-sending
/// the whole window. The full state goes out only on a revision change, a join, or a request.
struct RemoteHeartbeat: Codable, Equatable, Sendable {
    var revision: Int
    var hostId: String
    var currentRid: String?
    var positionMs: Int
    var isPlaying: Bool
    var anchorSharedTime: Double
    var sessionActive: Bool
}

/// "Send me your full state" — the revision the requester holds (-1 ⇒ none).
struct RemoteStateRequest: Codable, Equatable, Sendable {
    var haveRevision: Int
}

struct RemoteCommandMessage: Codable, Equatable {
    var id: String = UUID().uuidString
    var command: RemoteCommand
}

struct RemoteHello: Codable, Equatable, Sendable {
    var name: String
    var role: RemoteDeviceRole
    var platform: String
    /// What this build can do beyond Phase 1 (`MixCapability.deckOwner`…). Optional: a Phase-1
    /// build sends none, and is never handed a deck.
    var caps: [String]? = nil
}

/// "These rows can't play on this device" — shown on the controller surface so the driver
/// knows the car will skip them.
struct RemoteAvailability: Codable, Equatable, Sendable {
    var unavailableRids: [String]
}

struct RemotePing: Codable, Equatable, Sendable {
    var id: String
    /// Sender's local clock at send (ms).
    var t0: Double
}

struct RemotePong: Codable, Equatable, Sendable {
    var id: String
    var t0: Double
    /// Host's clock when the ping arrived / when this pong left (ms).
    var t1: Double
    var t2: Double
}
