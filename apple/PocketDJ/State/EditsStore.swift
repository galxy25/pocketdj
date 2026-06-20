import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// On-device store of user metadata edits, persisted as the versioned
/// `EditsDocument` (see EditSchema). Export/Import use the same schema so an edit
/// made on any device round-trips through the iMac merge tool unchanged.
@MainActor
@Observable
final class EditsStore {
    private(set) var doc: EditsDocument
    private let fileURL: URL

    init(fileURL: URL = EditsStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let loaded = try? EditsCodec.decode(data) {
            doc = loaded
        } else {
            doc = EditsDocument()
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-edits.json")
    }

    /// UI tests get an isolated, fresh edits file.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-edits.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    var count: Int { doc.albums.count + doc.songs.count }
    func albumEdit(_ id: String) -> AlbumEdit? { doc.albums[id] }
    func songEdit(_ id: String) -> SongEdit? { doc.songs[id] }

    func setAlbum(_ id: String, _ edit: AlbumEdit) {
        doc.albums[id] = edit.isEmpty ? nil : edit
        save()
    }
    func setSong(_ id: String, _ edit: SongEdit) {
        doc.songs[id] = edit.isEmpty ? nil : edit
        save()
    }
    func clearAll() { doc = EditsDocument(); save() }

    // MARK: Export / Import (Settings ▸ Edits)

    /// Encoded document with fresh `meta`, for the file exporter.
    func exportData() throws -> Data {
        var out = doc
        out.schemaVersion = editsSchemaVersion
        out.meta = EditsDocument.Meta(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            platform: EditsStore.platform)
        return try EditsCodec.encode(out)
    }

    /// Merge an imported document in (imported value wins per id). Auto-migrates.
    func importData(_ data: Data) throws {
        let incoming = try EditsCodec.decode(data)
        for (id, edit) in incoming.albums { doc.albums[id] = edit }
        for (id, edit) in incoming.songs { doc.songs[id] = edit }
        save()
    }

    private func save() {
        doc.schemaVersion = editsSchemaVersion
        if let data = try? EditsCodec.encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }

    static var platform: String {
        #if os(macOS)
        return "macOS"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }
}
