import Foundation

// ============================================================================
// MARK: - Multiplayer Mix (SharePlay, Phase 2) — wire kinds + the authoritative model
// ============================================================================
//
// Multiplayer Mix rides the Phase-1 Remote session: the SAME transport, the SAME versioned
// envelope, new `kind` strings (a Phase-1 build ignores them — the forward-compat rule in
// `RemoteWire.swift`). Audio is NEVER streamed between devices: every device renders both decks
// LOCALLY from shared state (its own burned / streamable files), and the wire carries only ids,
// titles, control values and shared-clock anchors. See docs/design/mix-audio-graph.md
// § Multiplayer Mix for what is synced, what stays local, and the timing.

enum MixWireKind {
    /// host → all / one: the full authoritative mix (on start, on request, after a hand-over).
    static let snapshot = "mix.snapshot"
    /// participant → host: a PROPOSED event · host → all: the same event, host-ordered.
    static let event = "mix.event"
    /// participant → host: "send me a snapshot" (join, a sequence gap, a refused gesture).
    static let request = "mix.request"
    /// any → all: whether a deck's song is loaded / loading / unavailable on the sender.
    static let ready = "mix.ready"
    /// deck owner → all, every 2 s, best-effort: where the deck is (the drift reference).
    static let beat = "mix.beat"
    /// host → the sender: a proposal was refused (not the deck's owner, deck taken…).
    static let reject = "mix.reject"
    /// participant → the (new) host: "your mix is older / empty — here is the live one I mirror"
    /// (a host election that landed on a device that never had the mix). The host adopts it only
    /// when its own model is inactive or behind; a live mix is never ended by an empty host.
    static let handover = "mix.handover"
}

/// The `RemoteHello.caps` entry a device that can own a deck advertises (a Phase-1-only build
/// sends no caps; an Apple TV renders the mix but has no deck UI, so it never advertises it).
enum MixCapability {
    static let deckOwner = "mix"
}

/// The sync-layer event kinds beyond the engine's gesture kinds (`MixEventKind` rawValues +
/// `MixEngine.Gesture`'s load / eject / loop / loopUnits).
enum MixSyncKind {
    static let play = "play", pause = "pause", seek = "seek"
    static let load = MixEngine.Gesture.load, eject = MixEngine.Gesture.eject
    static let loop = MixEngine.Gesture.loop, loopUnits = MixEngine.Gesture.loopUnits
    static let crossfader = "crossfader", resetDeck = "resetDeck", lead = "lead"
    static let tempo = "tempo", sync = "sync"
    /// participant → host proposals; the host answers with an `owner` event.
    static let claim = "claim", release = "release"
    /// host-only: a deck's owner changed (`MixSyncEvent.owner`, nil = free).
    static let owner = "owner"
    /// host-only: the mix session started (`flag` true) / ended (false).
    static let session = "session"

    /// Transport kinds carry a full `MixSyncAnchor` (play / pause / seek are one shape:
    /// "this deck is at P at shared time T, playing or not").
    static let transport: Set<String> = [play, pause, seek]

    /// Continuous surfaces (sliders / knobs / drags): proposals are COALESCED to one per
    /// `MixSync.continuousIntervalMs` per control, with a trailing send of the final value.
    static let continuous: Set<String> = [tempo, "pitch", "volume", "eq", "effectStrength", "stemVolume",
                                          "effectMod", crossfader]
}

/// "Deck at `positionMs` (source ms) at shared time `atSharedTime`, playing or paused". A
/// participant whose clock isn't synced yet sends `atSharedTime == nil` and the host stamps it
/// on receipt (error ≤ one-way latency, corrected by the next heartbeat).
struct MixSyncAnchor: Codable, Equatable, Sendable {
    var positionMs: Int
    var atSharedTime: Double?
    var isPlaying: Bool

    /// The deck's position at shared time `t` (a playing deck advances at `rate` × wall time).
    func position(at t: Double, rate: Double) -> Int {
        guard isPlaying, let at = atSharedTime else { return positionMs }
        return max(0, positionMs + Int(((t - at) * rate).rounded()))
    }
}

/// One mix event — the `MixSessionEvent` fields (kind / deck / song / param / value / flag /
/// slot / posMs) plus what crossing devices needs: the Apple Music id + song attributes for a
/// `load` (each device resolves the song against ITS OWN library — never a rip URL or a token),
/// a shared-clock anchor for transport, and the new owner for an `owner` event.
struct MixSyncEvent: Codable, Equatable, Sendable {
    var kind: String
    var deck: String?
    var songId: String? = nil
    var title: String? = nil
    var artist: String? = nil
    var appleMusicId: String? = nil
    var bpm: Double? = nil
    var camelot: String? = nil
    var key: String? = nil
    var albumId: String? = nil
    var lengthMs: Int? = nil
    var param: String? = nil
    var value: Double? = nil
    var flag: Bool? = nil
    var slot: Int? = nil
    var posMs: Int? = nil
    var anchor: MixSyncAnchor? = nil
    var owner: String? = nil
    /// `loop`: the exact window (source ms) the owner's deck loops — every device loops THESE
    /// frames (nil from an older sender ⇒ the receiver derives a window around its playhead).
    var loopStartMs: Int? = nil
    var loopEndMs: Int? = nil

    var engineDeck: MixEngine.Deck? { deck.flatMap(MixEngine.Deck.init(rawValue:)) }
    var isTransport: Bool { MixSyncKind.transport.contains(kind) }
    /// Carries a shared-clock anchor the host re-times into the future (transport, and ↺ —
    /// which rewinds every device at ONE shared instant, not on arrival).
    var carriesAnchor: Bool { isTransport || kind == MixSyncKind.resetDeck }

    /// The CONTROL this event sets — latest-wins per key (the snapshot keeps one event per key,
    /// and a sender's own un-echoed proposal on a key shadows other senders' older ones).
    /// Every transport-ish kind (load / eject / play / pause / seek / reset / loop) shares one
    /// key per deck: they all rewrite "what this deck is doing".
    var controlKey: String {
        let d = deck ?? "-"
        switch kind {
        case MixSyncKind.load, MixSyncKind.eject, MixSyncKind.play, MixSyncKind.pause, MixSyncKind.seek:
            return "transport:\(d)"
        case MixSyncKind.tempo, MixSyncKind.sync: return "rate:\(d)"
        case MixSyncKind.crossfader: return "crossfader"
        case MixSyncKind.loop, MixSyncKind.loopUnits: return "loop:\(d)"   // one loop state per deck
        default:
            let sub = slot.map { "#\($0)" } ?? param ?? ""
            return "\(kind):\(d):\(sub)"
        }
    }
}

/// A proposal (participant → host: `hostSeq == nil`) or an ordered event (host → all).
struct MixSyncEventMessage: Codable, Equatable, Sendable {
    /// The ORIGIN's own monotonic counter — pairs an echo with the proposal it answers.
    var originSeq: Int
    /// Who made the gesture (host-stamped; a proposal's sender is the transport's `from`).
    var origin: String? = nil
    /// Host order. Every device applies ordered events strictly by this.
    var hostSeq: Int? = nil
    /// The host that ordered it (its id). A new host starts a new epoch with a snapshot.
    var epoch: String? = nil
    var event: MixSyncEvent
}

/// One deck of the authoritative mix.
struct MixSyncDeckState: Codable, Equatable, Sendable {
    /// The participant id whose gestures drive this deck (nil = free, claimable).
    var owner: String? = nil
    /// The `load` event that put the current track here (nil = empty deck).
    var track: MixSyncEvent? = nil
    var anchor: MixSyncAnchor? = nil
    /// The deck's tempo multiplier (anchors advance at it).
    var rate: Double = 1
    /// The latest event per `controlKey` (never transport), in host order.
    var controls: [MixSyncEvent] = []

    mutating func setControl(_ e: MixSyncEvent) {
        let k = e.controlKey
        controls.removeAll { $0.controlKey == k }
        controls.append(e)
    }

    mutating func dropControls(where drop: (MixSyncEvent) -> Bool) { controls.removeAll(where: drop) }
}

/// The full authoritative mix (a `mix.snapshot` body).
struct MixSyncSnapshot: Codable, Equatable, Sendable {
    var epoch: String
    var active: Bool
    /// The last host sequence number folded into this snapshot.
    var hostSeq: Int
    var decks: [String: MixSyncDeckState]
    var crossfader: Double?
    /// Deck B's first-joiner default was already handed out this session.
    var assignedB: Bool
}

/// Deck readiness on ONE device.
struct MixSyncReady: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case ready, loading, unavailable, empty }
    var deck: String
    var songId: String?
    var status: Status
}

struct MixSyncBeat: Codable, Equatable, Sendable {
    var deck: String
    var songId: String
    var anchor: MixSyncAnchor
    var epoch: String
    /// The owner's own clock uncertainty (best RTT / 2 to the host, 0 on the host) — a receiver
    /// adds it to its own before calling a difference "drift". Optional: older senders omit it.
    var uncertaintyMs: Double? = nil
}

/// `mix.handover` body: a mirror's snapshot with every anchor re-expressed on the SENDER's local
/// clock (`sentAtLocal` = the sender's clock when it sent) — the receiving host maps them onto
/// its own timeline as "that long before / after now" (error ≤ one-way latency; heartbeats trim it).
struct MixSyncHandover: Codable, Equatable, Sendable {
    var snapshot: MixSyncSnapshot
    var sentAtLocal: Double
}

struct MixSyncReject: Codable, Equatable, Sendable {
    var originSeq: Int
    var reason: String
}

struct MixSyncRequest: Codable, Equatable, Sendable {
    var reason: String
}

// MARK: - The authoritative model (pure)

/// The mix as the HOST orders it — mirrored on every device by applying ordered events in host
/// order, so any device can become the host (hand-over) or answer a joiner, and a deck whose
/// song is unavailable on THIS device is still described exactly (snapshots come from here, never
/// from the local engine).
struct MixSyncModel: Equatable, Sendable {
    var epoch: String = ""
    var active = false
    var hostSeq = 0
    var decks: [MixEngine.Deck: MixSyncDeckState] = [.a: MixSyncDeckState(), .b: MixSyncDeckState()]
    var crossfader: Double?
    var assignedB = false

    init() {}

    init(_ s: MixSyncSnapshot) {
        epoch = s.epoch
        active = s.active
        hostSeq = s.hostSeq
        crossfader = s.crossfader
        assignedB = s.assignedB
        for d in MixEngine.Deck.allCases { decks[d] = s.decks[d.rawValue] ?? MixSyncDeckState() }
    }

    func snapshot() -> MixSyncSnapshot {
        MixSyncSnapshot(epoch: epoch, active: active, hostSeq: hostSeq,
                        decks: Dictionary(uniqueKeysWithValues: decks.map { ($0.key.rawValue, $0.value) }),
                        crossfader: crossfader, assignedB: assignedB)
    }

    func deck(_ d: MixEngine.Deck) -> MixSyncDeckState { decks[d] ?? MixSyncDeckState() }
    func owner(of d: MixEngine.Deck) -> String? { decks[d]?.owner }
    func decks(ownedBy id: String) -> [MixEngine.Deck] { MixEngine.Deck.allCases.filter { owner(of: $0) == id } }

    /// Controls a fresh LOAD returns to default (the engine's `commitLoad` resets them).
    private static let resetByLoad: Set<String> = [MixSyncKind.tempo, MixSyncKind.sync, "pitch", "stemMode",
                                                   "stemMute", "stemVolume", MixSyncKind.loop,
                                                   MixSyncKind.loopUnits, MixSyncKind.lead]
    /// Controls ↺ returns to default (`resetDeck` keeps the rack LAYOUT, stem mode, lead, loop).
    private static let resetByReset: Set<String> = [MixSyncKind.tempo, MixSyncKind.sync, "pitch", "volume",
                                                    "effectToggle", "effectStrength", "eq", "stemMute", "stemVolume"]

    /// Fold one ORDERED event in. `sharedNow` stamps an anchor that arrived without a time.
    mutating func apply(_ e: MixSyncEvent, sharedNow: Double) {
        if e.kind == MixSyncKind.session { active = e.flag ?? false; return }
        if e.kind == MixSyncKind.crossfader { crossfader = e.value; return }
        guard let d = e.engineDeck else { return }
        var ds = deck(d)
        switch e.kind {
        case MixSyncKind.owner:
            ds.owner = e.owner
            if d == .b, e.owner != nil { assignedB = true }
        case MixSyncKind.load:
            ds.track = e
            ds.anchor = MixSyncAnchor(positionMs: 0, atSharedTime: sharedNow, isPlaying: false)
            ds.rate = 1
            ds.dropControls { Self.resetByLoad.contains($0.kind) }
        case MixSyncKind.eject:
            ds.track = nil
            ds.anchor = nil
            ds.rate = 1
            ds.controls = []
        case MixSyncKind.play, MixSyncKind.pause, MixSyncKind.seek:
            if var a = e.anchor {
                if a.atSharedTime == nil { a.atSharedTime = sharedNow }
                ds.anchor = a
            }
        case MixSyncKind.resetDeck:
            ds.rate = 1
            ds.dropControls { Self.resetByReset.contains($0.kind) }
            // ↺ rewinds and keeps the play state — at the host's shared instant when it says one.
            if var a = e.anchor {
                if a.atSharedTime == nil { a.atSharedTime = sharedNow }
                ds.anchor = a
            } else {
                let playing = ds.anchor?.isPlaying ?? false
                ds.anchor = MixSyncAnchor(positionMs: 0, atSharedTime: sharedNow, isPlaying: playing)
            }
        case MixSyncKind.tempo, MixSyncKind.sync:
            if let v = e.value { ds.rate = v }
            ds.setControl(e)
        case MixSyncKind.lead:
            ds.setControl(e)
            // Lead is exclusive across decks.
            if e.flag == true {
                for other in MixEngine.Deck.allCases where other != d {
                    decks[other]?.dropControls { $0.kind == MixSyncKind.lead }
                }
            }
        default:
            ds.setControl(e)
        }
        decks[d] = ds
    }
}
