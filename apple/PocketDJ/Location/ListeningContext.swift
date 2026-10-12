import Foundation

// ─────────────────────────────────────────────────────────────────────────────────────────────
// LISTENING CONTEXT — the FROZEN contract between the on-device location engine
// (ListeningLocationStore, iOS) and the play-history → listening-pockets pipeline.
//
// Added BYTE-IDENTICAL by two parallel branches (feat/pockets-location owns it; feat/pockets-app
// carries a verbatim copy so it compiles) — git merges identical additions cleanly. Do not edit
// it in either branch; change it in a follow-up once both have landed.
//
// Naming: "Listening…" everywhere — the app already has `Pocket` collections (the Pocket DAG) and
// `PlaySource.pocket`; nothing here may collide with them.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Where a play happened, as OPAQUE identifiers only — never coordinates, never a name.
/// Persisted on `PlayHistoryStore.PlayEvent.listeningContext` and uploaded verbatim as `ctx`.
///
/// `kind` is a String (not an enum) and decoding is LENIENT for the `LenientEvent` reason:
/// PlayEvent decodes per element, so a field that THROWS on a token from a newer build would drop
/// the whole play from history. An unknown kind decodes fine and reads as "no context".
struct ListeningContextTag: Codable, Hashable, Sendable {
    static let kindPlace = "place"
    static let kindTrip = "trip"
    static let kindNone = "none"

    /// "place" | "trip" | "none" (resolved: neither at a known place nor on a known trip).
    var kind: String
    /// `plc_<16 lowercase hex>` — set when kind == place.
    var placeId: String?
    /// `trp_<16 lowercase hex>` — set when kind == trip. ONE id per ORDERED (origin, destination)
    /// pair, so A→B and B→A are different trips: direction of travel is a feature.
    var tripId: String?
    /// Trip origin place id (kind == trip).
    var origin: String?
    /// Trip destination place id (kind == trip); nil = the trip never arrived anywhere known.
    var destination: String?

    init(kind: String, placeId: String? = nil, tripId: String? = nil,
         origin: String? = nil, destination: String? = nil) {
        self.kind = kind; self.placeId = placeId; self.tripId = tripId
        self.origin = origin; self.destination = destination
    }

    static func place(_ id: String) -> ListeningContextTag {
        ListeningContextTag(kind: kindPlace, placeId: id)
    }
    static func trip(_ id: String, origin: String, destination: String?) -> ListeningContextTag {
        ListeningContextTag(kind: kindTrip, tripId: id, origin: origin, destination: destination)
    }
    static let none = ListeningContextTag(kind: kindNone)

    var isPlace: Bool { kind == Self.kindPlace && placeId != nil }
    var isTrip: Bool { kind == Self.kindTrip && tripId != nil && origin != nil }

    enum CodingKeys: String, CodingKey { case kind, placeId, tripId, origin, destination }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? Self.kindNone
        placeId = (try? c.decodeIfPresent(String.self, forKey: .placeId)) ?? nil
        tripId = (try? c.decodeIfPresent(String.self, forKey: .tripId)) ?? nil
        origin = (try? c.decodeIfPresent(String.self, forKey: .origin)) ?? nil
        destination = (try? c.decodeIfPresent(String.self, forKey: .destination)) ?? nil
    }
}

/// The answer to "what was the listening context at time T?".
enum ListeningContextLookup: Equatable, Sendable {
    /// Never stamp: platform without location, feature off, permission missing, or T predates
    /// tracking (before the user turned location on / before retained history).
    case unavailable
    /// Not decidable YET — e.g. mid-trip with the destination unknown, or T is so recent that a
    /// back-dated CLVisit could still claim it. Ask again later. GUARANTEE: a T older than
    /// `ListeningContextConstants.pendingHorizon` before now is NEVER `.pending`.
    case pending
    /// Final. May be `.none` (resolved, but neither a known place nor a trip).
    case settled(ListeningContextTag)
}

enum ListeningContextConstants {
    /// See `ListeningContextLookup.pending`.
    static let pendingHorizon: TimeInterval = 6 * 60 * 60
}

/// A place as the UI shows it. Rank is computed at DISPLAY time from share of dwell time over
/// the trailing rank window; the id is stable forever (ranks may reshuffle, ids never do).
struct ListeningPlaceLabel: Hashable, Sendable, Identifiable {
    var id: String            // "plc_…"
    var rank: Int             // 1-based; 1 = where the most time is spent
    var label: String         // "Location A" (rank 1 → A … 26 → Z, 27 → AA)
    var shareOfTime: Double   // 0…1
}

/// A recurring trip as the UI shows it.
struct ListeningTripLabel: Hashable, Sendable, Identifiable {
    var id: String            // "trp_…"
    var origin: String        // place id
    var destination: String?  // place id; nil = never arrived anywhere known
    var label: String         // "A → B" | "A ↺" (same place) | "Leaving A" (no destination)
    var occurrences: Int
}

/// The location engine as the rest of the app sees it. @MainActor: every consumer
/// (PlayHistoryStore, ListeningPocketsService, SwiftUI) is main-actor.
@MainActor
protocol ListeningContextProviding: AnyObject {
    /// This platform can produce context at all (iOS true; macOS/tvOS/visionOS false).
    var isSupported: Bool { get }
    /// Supported AND the user opted in AND permission granted — lookups can return non-unavailable.
    var isActive: Bool { get }
    /// Bumps whenever places/trips/labels change (UI recompute key).
    var revision: Int { get }
    /// Context at `date` (see `ListeningContextLookup`). Pure read; cheap (called per event).
    func context(at date: Date) -> ListeningContextLookup
    /// Places ranked by share of time (display-time ranking), only places with enough dwell.
    func placeLabels() -> [ListeningPlaceLabel]
    /// Trips seen at least twice, most frequent first.
    func tripLabels() -> [ListeningTripLabel]
    /// "Location A" / "A → B" / "Leaving A" / "A ↺"; nil for kind none or an id this device no
    /// longer knows (pruned/erased → the UI says "Earlier place").
    func label(for tag: ListeningContextTag) -> String?
}

/// The provider for platforms/tests with no location: always `.unavailable`.
@MainActor
final class NoopListeningContextProvider: ListeningContextProviding {
    init() {}
    var isSupported: Bool { false }
    var isActive: Bool { false }
    var revision: Int { 0 }
    func context(at date: Date) -> ListeningContextLookup { .unavailable }
    func placeLabels() -> [ListeningPlaceLabel] { [] }
    func tripLabels() -> [ListeningTripLabel] { [] }
    func label(for tag: ListeningContextTag) -> String? { nil }
}
