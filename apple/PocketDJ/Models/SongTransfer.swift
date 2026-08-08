import CoreTransferable
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The drag / clipboard payload for songs: bare catalog ids (stable per source index,
/// namespaced sng_/amrec_/smp_… — the same prefix-agnostic strings CollectionsStore
/// membership uses), so the payload survives cross-window AND cross-process (JSON on
/// the system pasteboard). `text` is a human-readable fallback for external apps.
struct SongTransfer: Codable, Hashable, Sendable {
    var songIds: [String]
    var text: String?

    /// Cap the plain-text fallback so a 96k-song select-all still starts a drag instantly.
    static let textLineCap = 200
    static func make(ids: [String], songsById: [String: IndexSong]) -> SongTransfer {
        let lines = ids.prefix(textLineCap).compactMap { songsById[$0].map { "\($0.artist) — \($0.name)" } }
        let extra = ids.count - min(ids.count, textLineCap)
        let text = lines.isEmpty ? nil : (lines.joined(separator: "\n") + (extra > 0 ? "\n…and \(extra) more" : ""))
        return SongTransfer(songIds: ids, text: text)
    }
    var plainTextExport: String { text ?? songIds.joined(separator: "\n") }
}

extension SongTransfer: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pocketDJSongList)   // rich type FIRST (internal drops prefer it)
        ProxyRepresentation(exporting: { $0.plainTextExport })  // text fallback for external apps
    }
}

/// Pasteboard twin (same #if idiom as JukeboxView/DebugView string copies), but typed:
/// JSON under the custom UTI + a plain-text sibling.
enum SongPasteboard {
    static let utiString = "com.pocketdj.songlist"

    static func write(_ t: SongTransfer) {
        guard let data = try? JSONEncoder().encode(t) else { return }
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.declareTypes([NSPasteboard.PasteboardType(utiString), .string], owner: nil)
        pb.setData(data, forType: NSPasteboard.PasteboardType(utiString))
        pb.setString(t.plainTextExport, forType: .string)
        #else
        UIPasteboard.general.items = [[
            utiString: data,
            UTType.utf8PlainText.identifier: t.plainTextExport
        ]]
        #endif
    }
    /// Any process can author the UTI, so refuse to even DECODE a payload beyond what a
    /// legitimate one can be: `SongDrop.maxIds` ids × a real id's size + the capped text
    /// fallback is single-digit MB — a hostile multi-GB blob must fail before JSONDecoder
    /// materializes it.
    static let maxPayloadBytes = 8 * 1024 * 1024
    static func read() -> SongTransfer? {
        #if os(macOS)
        guard let data = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(utiString)) else { return nil }
        #else
        guard let data = UIPasteboard.general.data(forPasteboardType: utiString) else { return nil }
        #endif
        return decode(data)
    }
    /// The byte-capped decode boundary, separated from the live pasteboard for unit tests.
    static func decode(_ data: Data) -> SongTransfer? {
        guard data.count <= maxPayloadBytes else { return nil }
        return try? JSONDecoder().decode(SongTransfer.self, from: data)
    }
    /// Cheap availability probe (does NOT read contents — no iPadOS paste banner).
    static var hasSongs: Bool {
        #if os(macOS)
        return NSPasteboard.general.availableType(from: [NSPasteboard.PasteboardType(utiString)]) != nil
        #else
        return UIPasteboard.general.contains(pasteboardTypes: [utiString])
        #endif
    }
}

/// Drop/paste validation, pure for unit tests: keep ids the current catalog can resolve
/// (or studio ids the caller's lookup backs), order-preserving, deduped — and BOUNDED. The
/// payload crosses a process boundary (any app can author the pasteboard type), so per-id
/// length and total count are capped before anything touches the persisted document.
enum SongDrop {
    /// Above any real select-all (the full catalog is ~96k), below OOM/document-bloat scale.
    static let maxIds = 100_000
    /// Above any real namespaced id (sng_/amrec_/smp_… + uuid), below junk-string scale.
    static let maxIdLength = 128

    static func acceptableIds(_ items: [SongTransfer], resolves: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in items.lazy.flatMap(\.songIds) {
            guard out.count < maxIds else { break }
            guard id.count <= maxIdLength, seen.insert(id).inserted, resolves(id) else { continue }
            out.append(id)
        }
        return out
    }
}
