import UniformTypeIdentifiers

extension UTType {
    /// The app's exported collection type (playlist / pocket transfer). Mirrors the
    /// `com.pocketdj.collection` UTExportedTypeDeclaration in the Info.plist (project.yml).
    /// The payload is genuinely a zip, so this conforms to `.zip` — which also means any
    /// picker/importer that accepts `.zip` still accepts a `.pdjcollection` file. The
    /// identifier MUST match the plist exactly or the type resolves to nothing (a
    /// unit test guards the `.zip` conformance).
    static let pocketDJCollection = UTType(exportedAs: "com.pocketdj.collection", conformingTo: .zip)

    /// Pasteboard/drag type for a list of song ids (multi-select drag & copy/paste).
    /// Mirrors the second com.pocketdj UTExportedTypeDeclaration in project.yml.
    static let pocketDJSongList = UTType(exportedAs: "com.pocketdj.songlist", conformingTo: .json)
}
