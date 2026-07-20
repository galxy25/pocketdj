import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Debug — capture-session diagnostics for REMOTE (TestFlight) debugging. The flow is
/// deliberate: turn capture ON → reproduce the issue → turn it OFF → the frozen session appears
/// below for export (save straight into iCloud Drive / AirDrop and ship it back). The capture is
/// `MixDiag`: the mix engine's 1 Hz liveness heartbeat plus every recovery/transport event —
/// exactly what's needed to see WHICH layer died during a silent audio failure. os_log runs
/// unconditionally regardless of the toggle; this buffer only exists while capturing.
struct DebugView: View {
    @Bindable var settings: SettingsStore
    @State private var showExporter = false
    @State private var copiedBuild = false

    private var diag: MixDiag { MixDiag.shared }

    var body: some View {
        Form {
            Section {
                Toggle("Capture debug log", isOn: captureBinding)
                    .accessibilityIdentifier("debug-capture-toggle")
            } footer: {
                Text(diag.isCapturing
                     ? "Capturing — reproduce the issue, then turn this off to freeze the session for export."
                     : "Turn on, reproduce the issue, then turn off. The captured session appears below, ready to export.")
            }
            if !diag.isCapturing, !diag.lines.isEmpty {
                Section {
                    LabeledContent("Lines", value: "\(diag.lines.count)")
                    if let s = diag.startedAt {
                        LabeledContent("Window", value: "\(s.formatted(date: .omitted, time: .standard)) – "
                                       + (diag.endedAt?.formatted(date: .omitted, time: .standard) ?? "…"))
                    }
                    Button {
                        showExporter = true
                    } label: {
                        Label("Export session…", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("debug-export")
                } header: {
                    Text("Captured session")
                } footer: {
                    Text("Save it to iCloud Drive (or AirDrop it) to ship it off this device.")
                }
            }
            // Both diagnostic values here exist to be QUOTED somewhere else — the build
            // identity into a bug report, the iCloud hash into Config.ownerICloudHashes — so
            // both get the same treatment: selectable text AND a one-tap Copy. Selection
            // alone isn't enough on iPhone, where long-press-to-select inside a Form row is
            // fiddly and frequently steals the scroll gesture.
            Section("Build") {
                LabeledContent("Version") {
                    Text(MixDiag.buildIdentity())
                        .font(.caption2.monospaced())
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("debug-build-version")
                Button {
                    copyToPasteboard(MixDiag.buildIdentity())
                    copiedBuild = true
                } label: {
                    Label(copiedBuild ? "Copied" : "Copy version", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("debug-build-copy")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Debug")
        .scrollContentBackground(.hidden).background(Theme.bg)
        .fileExporter(isPresented: $showExporter,
                      document: DebugLogDocument(text: diag.dump()),
                      contentType: .plainText,
                      defaultFilename: "pocketdj-debug-session") { _ in }
    }

    private func copyToPasteboard(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }

    /// The toggle drives BOTH the persisted preference (so a relaunch mid-repro resumes
    /// capturing) and the live session lifecycle.
    private var captureBinding: Binding<Bool> {
        Binding(get: { settings.debugLoggingEnabled },
                set: { on in
                    settings.debugLoggingEnabled = on
                    settings.persist()
                    if on { MixDiag.shared.start() } else { MixDiag.shared.stop() }
                })
    }
}

/// Plain-text `FileDocument` for the session export.
struct DebugLogDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
