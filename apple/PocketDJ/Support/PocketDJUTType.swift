import UniformTypeIdentifiers

extension UTType {
    /// The app's exported collection type (playlist / pocket transfer). Mirrors the
    /// `com.pocketdj.collection` UTExportedTypeDeclaration in the Info.plist (project.yml).
    /// The payload is genuinely a zip, so this conforms to `.zip` — which also means any
    /// picker/importer that accepts `.zip` still accepts a `.pdjcollection` file. The
    /// identifier MUST match the plist exactly or the type resolves to nothing (a
    /// unit test guards the `.zip` conformance).
    static let pocketDJCollection = UTType(exportedAs: "com.pocketdj.collection", conformingTo: .zip)
}
