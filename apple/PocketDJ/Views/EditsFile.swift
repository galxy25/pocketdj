import SwiftUI
import UniformTypeIdentifiers

/// A JSON document wrapper so the edits payload can be written/read by SwiftUI's
/// native `.fileExporter` / `.fileImporter` on iPhone, iPad, and Mac.
struct EditsFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data
    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// An mp3-document wrapper for `.fileExporter`, used by the song-row ⤓ transport to let
/// the user CHOOSE where a ripped song is saved (NSSavePanel on macOS, the document
/// picker in export mode on iOS/iPadOS) rather than dropping it in Documents + sharing.
/// Holds the already-downloaded mp3 `Data`; the OS writes it to the picked location.
struct RippedAudioFile: FileDocument {
    /// `.mp3` when the system can resolve it, else `.mpeg4Audio`, else generic `.audio`.
    static let mp3Type: UTType =
        UTType(filenameExtension: "mp3") ?? UTType.mpeg4Audio ?? .audio
    static var readableContentTypes: [UTType] { [mp3Type] }

    var data: Data
    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A zip-document wrapper for `.fileExporter`, used to write a
/// `.playlist.pocketdj.zip` (the PWA single-playlist transfer format) so the PWA can
/// read a native-exported playlist.
struct PlaylistZipFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data
    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
