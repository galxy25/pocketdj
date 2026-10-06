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
    /// The archived session pending export + its text (captured on tap so the exporter document
    /// isn't re-read from disk on every body render).
    @State private var exportSession: DebugSessionStore.DebugSession?
    @State private var exportText = ""
    @State private var confirmDeleteAll = false
    @State private var diagKeyID = ""
    @State private var diagKeySecret = ""
    @State private var diagKeyStored = DiagCredentialStore().load() != nil

    private var diag: MixDiag { MixDiag.shared }
    private var archive: DebugSessionStore { DebugSessionStore.shared }

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
            Section {
                Toggle("Remote telemetry", isOn: telemetryBinding)
                    .accessibilityIdentifier("debug-telemetry-toggle")
            } footer: {
                Text("Streams every action and screen to PocketDJ's private diagnostic bucket while you use the app — including CarPlay — so a session can be debugged remotely. TestFlight/debug builds only; turn off when not needed.")
            }
            diagKeySection
            sessionsSection
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
                      document: DebugLogDocument(text: exportText),
                      contentType: .plainText,
                      defaultFilename: exportFilename) { _ in }
        .confirmationDialog("Delete all saved sessions?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { archive.deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The archived sessions: each exportable (tap) and deletable (swipe / right-click), with a
    /// Delete-all below. Replaces the old single-ephemeral-session panel — captures now persist.
    @ViewBuilder private var sessionsSection: some View {
        let sessions = archive.sessions
        Section {
            if sessions.isEmpty {
                Text("No saved sessions yet. Turn capture on, reproduce the issue, then off — "
                     + "the session is saved here.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("debug-no-sessions")
            }
            ForEach(sessions) { s in
                Button {
                    exportText = archive.text(for: s)
                    exportSession = s
                    showExporter = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionTitle(s)).foregroundStyle(Theme.fg)
                        Text("\(s.lineCount) lines").font(.caption2).foregroundStyle(Theme.fgDim)
                    }
                }
                .accessibilityIdentifier("debug-session-\(s.id)")
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { archive.delete(s) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { archive.delete(s) } label: {
                        Label("Delete session", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Saved sessions")
        } footer: {
            if !sessions.isEmpty {
                Text("Tap a session to export it (iCloud Drive / AirDrop). Swipe or right-click to delete one.")
            }
        }
        if !sessions.isEmpty {
            Section {
                Button(role: .destructive) { confirmDeleteAll = true } label: {
                    Label("Delete all sessions", systemImage: "trash")
                }
                .accessibilityIdentifier("debug-delete-all")
            }
        }
    }

    private func sessionTitle(_ s: DebugSessionStore.DebugSession) -> String {
        s.startedAt.formatted(date: .abbreviated, time: .standard)
    }

    /// Export filename derived from the pending session's start time.
    private var exportFilename: String {
        guard let s = exportSession else { return "pocketdj-debug-session" }
        return "pocketdj-debug-\(Int(s.startedAt.timeIntervalSince1970))"
    }

    private func copyToPasteboard(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }

    /// The S3 diag-writer key lives ONLY in the Keychain (iCloud-synced to the owner's other
    /// devices) — never in the binary, git, or SettingsStore. Fields clear after Save so the
    /// secret is never re-displayed.
    private var diagKeySection: some View {
        Section {
            if diagKeyStored {
                LabeledContent("Diag key", value: "Stored")
                Button("Remove diag key", role: .destructive) {
                    DiagCredentialStore().clear()
                    diagKeyStored = false
                    DiagLog.shared.reloadCredentials()
                }
                .accessibilityIdentifier("debug-diagkey-remove")
            }
            TextField("Access key ID", text: $diagKeyID)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("debug-diagkey-id")
            SecureField("Secret access key", text: $diagKeySecret)
                .accessibilityIdentifier("debug-diagkey-secret")
            Button("Save diag key") {
                DiagCredentialStore().save(accessKeyID: diagKeyID, secret: diagKeySecret)
                diagKeyID = ""; diagKeySecret = ""
                diagKeyStored = DiagCredentialStore().load() != nil
                DiagLog.shared.reloadCredentials()
            }
            .disabled(diagKeyID.isEmpty || diagKeySecret.isEmpty)
            .accessibilityIdentifier("debug-diagkey-save")
        } header: {
            Text("Remote diagnostics key")
        } footer: {
            Text("Write-only S3 key for the diagnostic bucket. Stored in the Keychain and synced via iCloud Keychain; with no key, remote logging does nothing.")
        }
    }

    /// Persisted preference + live push into the logger (whose singleton may already exist);
    /// the launch path does the same push so a relaunch resumes streaming.
    private var telemetryBinding: Binding<Bool> {
        Binding(get: { settings.remoteTelemetryEnabled },
                set: { on in
                    settings.remoteTelemetryEnabled = on
                    settings.persist()
                    DiagLog.shared.telemetryEnabled = on
                })
    }

    /// The toggle drives BOTH the persisted preference (so a relaunch mid-repro resumes
    /// capturing) and the live session lifecycle.
    private var captureBinding: Binding<Bool> {
        Binding(get: { settings.debugLoggingEnabled },
                set: { on in
                    settings.debugLoggingEnabled = on
                    settings.persist()
                    if on {
                        MixDiag.shared.start()
                    } else {
                        MixDiag.shared.stop()
                        // Freeze → archive: persist the just-captured buffer so it survives
                        // relaunch and joins earlier sessions (each exportable + deletable).
                        let d = MixDiag.shared
                        archive.archive(startedAt: d.startedAt ?? Date(), endedAt: d.endedAt,
                                        lineCount: d.lines.count, text: d.dump())
                    }
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
