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
