import Foundation
import Observation
import CryptoKit
import SwiftUI

/// The Pocket Wheel's colour language (§2.4, W3): 12 perceptually spaced OKLCH colours, assigned
/// to collections AUTOMATICALLY and kept STABLE — a slot, once given to a collection, never moves,
/// and is freed only 30 days after that collection stops being dominant anywhere (or is deleted).
///
/// Synced across devices (CloudSync key "pocket-palette") so iPhone, iPad and Mac paint the same
/// collection the same colour. The merge is convergent: per collection the EARLIER assignment
/// wins (tiebreak: lower slot), a slot claimed twice after a merge stays with its earlier owner and
/// the later one is re-seated, `lastSeen` is MAX-merged.
@MainActor
@Observable
final class PocketPaletteStore {

    nonisolated static let slotCount = 12
    nonisolated static let freeAfterMs: Double = 30 * 86_400_000

    struct Entry: Codable, Equatable, Sendable {
        var slot: Int
        var assignedAtMs: Double
        var lastSeenMs: Double
    }

    struct Document: Codable, Equatable {
        var schemaVersion = 1
        var entries: [String: Entry] = [:]
        init(entries: [String: Entry] = [:]) { self.entries = entries }
        enum CodingKeys: String, CodingKey { case schemaVersion, entries }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            // Per-entry lenient: one malformed entry must not drop the palette.
            let raw = (try? c.decode([String: LenientEntry].self, forKey: .entries)) ?? [:]
            entries = raw.compactMapValues(\.entry)
        }
        private struct LenientEntry: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var revision = 0
    @ObservationIgnored private let fileURL: URL
    var syncFileURL: URL { fileURL }

    init(fileURL: URL = PocketPaletteStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let doc = try? JSONDecoder().decode(Document.self, from: data) {
            entries = Self.normalized(doc.entries)
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-pocket-palette.json")
    }

    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-pocket-palette.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    // MARK: - Reads

    /// The slot of a collection, or nil (overflow / never dominant).
    func slot(for id: String) -> Int? { entries[id]?.slot }

    /// The colour reference for a collection id: a palette slot, or the overflow hash.
    func swatch(for id: String?) -> PocketSwatch {
        guard let id else { return .mixed }
        if let s = entries[id]?.slot { return .slot(s) }
        return .overflow(Self.overflowHue(id))
    }

    // MARK: - Assignment

    /// Fold one wheel build in: `dominantOrder` is every collection that is dominant in at least
    /// one cell, in DESCENDING global dominance. New collections take free slots in that order;
    /// every dominant collection's `lastSeen` moves to now; collections unseen for 30 days (or
    /// `deleted`) free their slots first. Returns whether anything changed (then it saved).
    @discardableResult
    func assign(dominantOrder: [String], deleted: Set<String> = [], nowMs: Double) -> Bool {
        var next = entries
        // Free stale + deleted slots.
        for (id, e) in next where deleted.contains(id) || nowMs - e.lastSeenMs > Self.freeAfterMs {
            if dominantOrder.contains(id), !deleted.contains(id) { continue }
            next[id] = nil
        }
        // Touch survivors.
        for id in dominantOrder {
            guard var e = next[id] else { continue }
            e.lastSeenMs = max(e.lastSeenMs, nowMs)
            next[id] = e
        }
        // Seat newcomers.
        var used = Set(next.values.map(\.slot))
        for id in dominantOrder where next[id] == nil && !deleted.contains(id) {
            guard let free = (0..<Self.slotCount).first(where: { !used.contains($0) }) else { break }
            next[id] = Entry(slot: free, assignedAtMs: nowMs, lastSeenMs: nowMs)
            used.insert(free)
        }
        guard next != entries else { return false }
        entries = next
        revision &+= 1
        save()
        return true
    }

    /// Merge a peer's document (CloudSync pull) — see the type doc for the convergent rule.
    /// Saves only when we hold something the pulled doc lacks (the PlayHistoryStore doctrine:
    /// an unconditional save after every pull ping-pongs two devices forever).
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        let merged = Self.merge(entries, doc.entries)
        let docNormalized = Self.normalized(doc.entries)
        if merged != entries { entries = merged; revision &+= 1 }
        guard merged != docNormalized else { return false }
        save()
        return true
    }

    /// The pure merge.
    nonisolated static func merge(_ a: [String: Entry], _ b: [String: Entry]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for id in Set(a.keys).union(b.keys) {
            switch (a[id], b[id]) {
            case let (x?, y?):
                let winner = (x.assignedAtMs, x.slot) <= (y.assignedAtMs, y.slot) ? x : y
                out[id] = Entry(slot: winner.slot, assignedAtMs: winner.assignedAtMs,
                                lastSeenMs: max(x.lastSeenMs, y.lastSeenMs))
            case let (x?, nil): out[id] = x
            case let (nil, y?): out[id] = y
            default: break
            }
        }
        return normalized(out)
    }

    /// Resolve slot collisions deterministically: the earliest assignment keeps a slot; later
    /// claimants move to the lowest free slot (or drop to overflow when none is free). Also drops
    /// out-of-range slots.
    nonisolated static func normalized(_ entries: [String: Entry]) -> [String: Entry] {
        let ordered = entries.filter { (0..<slotCount).contains($0.value.slot) }
            .sorted { ($0.value.assignedAtMs, $0.value.slot, $0.key) < ($1.value.assignedAtMs, $1.value.slot, $1.key) }
        var used = Set<Int>()
        var out: [String: Entry] = [:]
        var bumped: [(String, Entry)] = []
        for (id, e) in ordered {
            if used.insert(e.slot).inserted { out[id] = e } else { bumped.append((id, e)) }
        }
        for (id, e) in bumped {
            guard let free = (0..<slotCount).first(where: { !used.contains($0) }) else { continue }
            used.insert(free)
            out[id] = Entry(slot: free, assignedAtMs: e.assignedAtMs, lastSeenMs: e.lastSeenMs)
        }
        return out
    }

    /// Overflow hue (degrees) from sha256(id) — stable on every device.
    nonisolated static func overflowHue(_ id: String) -> Double {
        let digest = SHA256.hash(data: Data(id.utf8))
        let bytes = Array(digest)
        let v = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(v) / 65_536 * 360
    }

    func clear() {
        entries = [:]
        revision &+= 1
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Document(entries: entries)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// What a wheel cell is painted with.
enum PocketSwatch: Equatable, Sendable, Hashable {
    case slot(Int)
    /// A 13th+ dominant collection: hashed hue at low chroma (drawn hatched).
    case overflow(Double)
    /// No collection ≥ 25 % — neutral grey with a fine stripe.
    case mixed

    var isHatched: Bool { if case .overflow = self { return true }; return false }

    /// The palette (OKLCH L 0.72 / C 0.15 dark, L 0.58 light; sRGB, gamut-clipped). Hue order
    /// 25,145,265,85,205,325,55,175,295,115,235,355 so the first slots handed out are far apart.
    nonisolated static let darkRGB: [(Double, Double, Double)] = [
        (0.9574, 0.4822, 0.4539), (0.3811, 0.7399, 0.4024), (0.4629, 0.6302, 1.0),
        (0.8128, 0.6094, 0.0), (0.0, 0.7447, 0.8191), (0.8276, 0.5068, 0.8465),
        (0.9206, 0.5328, 0.2301), (0.0, 0.761, 0.6243), (0.6748, 0.5624, 0.9718),
        (0.6363, 0.6854, 0.1612), (0.0691, 0.6965, 0.9577), (0.9242, 0.4752, 0.6639),
    ]
    nonisolated static let lightRGB: [(Double, Double, Double)] = [
        (0.7659, 0.3107, 0.2939), (0.1985, 0.5662, 0.2358), (0.3051, 0.4584, 0.8247),
        (0.6368, 0.4402, 0.0), (0.0, 0.5694, 0.6434), (0.6483, 0.3394, 0.6684),
        (0.7338, 0.3628, 0.0), (0.0, 0.5857, 0.4595), (0.5102, 0.3935, 0.7862),
        (0.4732, 0.5143, 0.0), (0.0, 0.5225, 0.7735), (0.7353, 0.3057, 0.497),
    ]

    /// sRGB components for this swatch in the given scheme.
    func rgb(dark: Bool) -> (Double, Double, Double) {
        switch self {
        case .slot(let i):
            let table = dark ? Self.darkRGB : Self.lightRGB
            return table[((i % table.count) + table.count) % table.count]
        case .overflow(let hue):
            return Self.oklchToSRGB(L: dark ? 0.72 : 0.58, C: 0.08, h: hue)
        case .mixed:
            return dark ? (0.55, 0.57, 0.62) : (0.62, 0.63, 0.66)
        }
    }

    func color(dark: Bool) -> Color {
        let c = rgb(dark: dark)
        return Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: 1)
    }

    /// OKLCH → gamma-encoded sRGB (clipped) — Björn Ottosson's matrices.
    nonisolated static func oklchToSRGB(L: Double, C: Double, h: Double) -> (Double, Double, Double) {
        let a = C * cos(h * .pi / 180), b = C * sin(h * .pi / 180)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func enc(_ x: Double) -> Double {
            let c = min(1, max(0, x))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return (enc(r), enc(g), enc(bl))
    }
}
