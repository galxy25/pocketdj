import SwiftUI
import UniformTypeIdentifiers

/// Drives a `.pdjdiagkey` import end to end for the UI: run the importer, hold the mismatch
/// confirmation, then offer to delete the file (default: delete — it holds the key in clear).
/// One shared instance; `origin` routes the alerts to the surface that started the import
/// (Settings ▸ Debug's picker/drop, or a file opened from Finder/Files via onOpenURL).
@MainActor
@Observable
final class DiagKeyImportModel {
    enum Origin: Equatable { case settings, openedFile }

    enum Presentation: Equatable {
        /// Key is for another account than the active logs bucket — confirm or cancel.
        case mismatch(DiagKeyImporter.Mismatch, URL)
        /// Imported; offer to delete the source file.
        case imported(message: String, file: URL)
        case message(title: String, text: String)

        var title: String {
            switch self {
            case .mismatch: return "Key doesn't match the active logs bucket"
            case .imported: return "Upload key imported"
            case .message(let t, _): return t
            }
        }
    }

    static let shared = DiagKeyImportModel()

    private(set) var origin: Origin = .settings
    var presentation: Presentation?
    /// Bumped after every successful import so Settings ▸ Debug re-reads "key stored".
    private(set) var importCount = 0
    /// Built per import so the push closure targets the live CloudSyncService.
    var makeImporter: (() -> DiagKeyImporter)?

    init(makeImporter: (() -> DiagKeyImporter)? = nil) { self.makeImporter = makeImporter }

    /// True for a URL this model should handle (onOpenURL routing).
    static func handles(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == DiagKeyFile.fileExtension
    }

    func begin(_ url: URL, origin: Origin, force: Bool = false) async {
        guard let importer = makeImporter?() else {
            self.origin = origin
            presentation = .message(title: "Import unavailable", text: "The app isn't ready yet — try again in a moment.")
            return
        }
        self.origin = origin
        switch await importer.importFile(at: url, force: force) {
        case .imported(let env, let account, let mismatch):
            importCount += 1
            var text = "The \(env) key (account \(account)) is stored and syncing to your other devices through iCloud."
            if let mismatch { text += "\n\n" + mismatch.warning }
            text += "\n\nDelete \(url.lastPathComponent)? It holds the key in clear."
            presentation = .imported(message: text, file: url)
        case .needsConfirmation(let m):
            presentation = .mismatch(m, url)
        case .invalid(let why):
            presentation = .message(title: "Couldn't import key", text: "The file was refused: \(why).")
        case .saveFailed(let status):
            presentation = .message(title: "Couldn't import key", text: "Keychain save failed (OSStatus \(status)).")
        }
    }

    /// The default answer to the post-import prompt.
    func deleteImported(_ url: URL) {
        presentation = nil
        if let err = DiagKeyImporter.deleteFile(url) {
            presentation = .message(title: "File not deleted", text: err)
        }
    }

    func dismiss() { presentation = nil }
}

/// Presents `DiagKeyImportModel`'s alerts for one origin.
struct DiagKeyImportAlerts: ViewModifier {
    @Bindable var model: DiagKeyImportModel
    let origin: DiagKeyImportModel.Origin

    private var isPresented: Binding<Bool> {
        Binding(get: { model.origin == origin && model.presentation != nil },
                set: { if !$0 { model.dismiss() } })
    }

    func body(content: Content) -> some View {
        content.alert(model.presentation?.title ?? "", isPresented: isPresented,
                      presenting: model.presentation) { p in
            switch p {
            case .mismatch(_, let url):
                Button("Import Anyway") {
                    model.dismiss()
                    Task { await model.begin(url, origin: origin, force: true) }
                }
                Button("Cancel", role: .cancel) { model.dismiss() }
            case .imported(_, let url):
                Button("Delete File") { model.deleteImported(url) }
                    .keyboardShortcut(.defaultAction)
                Button("Keep File") { model.dismiss() }
            case .message:
                Button("OK", role: .cancel) { model.dismiss() }
            }
        } message: { p in
            switch p {
            case .mismatch(let m, _): Text(m.warning + "\n\nImport anyway?")
            case .imported(let text, _): Text(text)
            case .message(_, let text): Text(text)
            }
        }
    }
}

extension View {
    @MainActor
    func diagKeyImportAlerts(_ model: DiagKeyImportModel = .shared, origin: DiagKeyImportModel.Origin) -> some View {
        modifier(DiagKeyImportAlerts(model: model, origin: origin))
    }
}
