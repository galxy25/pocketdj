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
    /// Optional on purpose: this panel is reachable from Settings, which is only ever hosted by
    /// the app's own window (where the service IS injected) — but a preview or a future test host
    /// that renders it standalone should degrade to "unavailable", not trap.
    @Environment(FavoritesSyncService.self) private var favoritesSync: FavoritesSyncService?
    @State private var showExporter = false
    /// This install's owner hash, resolved once on appear (CloudKit round-trip, then cached
    /// inside OwnerIdentity). `loadedHash` distinguishes "still asking" from "no answer".
    @State private var ownerHash: String?
    @State private var loadedHash = false
    @State private var copiedHash = false
    @State private var copiedBuild = false
    @State private var showSeedExporter = false
    @State private var seedDoc = EditsFile(data: Data())

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
            ownerIdentitySection
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
        // The seed rides the same fileExporter idiom as the Edits/Backup exports — save it
        // into iCloud Drive, then upload it to `Config.favoritesSeedURL` on the catalog CDN.
        .fileExporter(isPresented: $showSeedExporter, document: seedDoc, contentType: .json,
                      defaultFilename: "favorites-seed") { _ in }
        .task {
            ownerHash = await OwnerIdentity.currentHash()
            loadedHash = true
        }
    }

    // MARK: - Owner identity (the two-way-sync bootstrap)

    /// THE BOOTSTRAP ROW. `Config.ownerICloudHashes` ships EMPTY — deliberately, so every
    /// install is favorites-local-only until proven otherwise — which means the allowlist can
    /// only ever be filled from here: run the build, copy this hash, paste it into Config, ship.
    /// Capture BOTH the Development and Production values: `CKContainer.userRecordID` is
    /// container-scoped, so a TestFlight build silently fails the gate with only the dev hash.
    private var ownerIdentitySection: some View {
        Section {
            LabeledContent("iCloud hash") {
                Text(hashDisplay)
                    .font(.caption2.monospaced())
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("owner-identity-hash")
            Button {
                if let ownerHash { copyToPasteboard(ownerHash); copiedHash = true }
            } label: {
                Label(copiedHash ? "Copied" : "Copy hash", systemImage: "doc.on.doc")
            }
            .disabled(ownerHash == nil)
            .accessibilityIdentifier("owner-identity-copy")

            LabeledContent("Favorites sync", value: gateLine)
                .accessibilityIdentifier("owner-identity-gate")
            if let error = favoritesSync?.lastError {
                LabeledContent("Last error", value: error)
                    .font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("owner-identity-error")
            }
            if let ms = favoritesSync?.lastSyncedAtMs {
                LabeledContent("Last synced", value: Date(timeIntervalSince1970: ms / 1000)
                    .formatted(date: .abbreviated, time: .shortened))
                    .accessibilityIdentifier("owner-identity-last-synced")
            }
            // Owner-only: the seed is the OWNER's Apple Music ♥, and exporting it from a
            // non-owner install would publish a tester's own favorites to every other tester.
            if (favoritesSync?.isOwner ?? nil) == true {
                Button {
                    exportSeed()
                } label: {
                    Label("Export favorites seed…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("owner-export-seed")
            }
        } header: {
            Text("Owner identity")
        } footer: {
            Text("""
                 Two-way Apple Music favorites sync is owner-only. Copy this device's hash into \
                 `Config.ownerICloudHashes` (both the Development and Production CloudKit values) \
                 and ship — until then every install keeps its ♥ to itself, which is the safe default.

                 UN-FAVORITING IS LOSSY ON APPLE MUSIC. Apple ships no delete counterpart to \
                 `POST /v1/me/favorites`, so removing a ♥ here deletes the love RATING (which is \
                 what recommendations and this app read) but cannot retract the ★ — the track stays \
                 in Apple Music's "Favorite Songs" until you remove it there yourself.
                 """)
        }
    }

    private var hashDisplay: String {
        if let ownerHash { return ownerHash }
        return loadedHash ? "unavailable" : "…"
    }

    private var gateLine: String {
        // Flattened deliberately: `favoritesSync?.isOwner` is a DOUBLE optional (no service
        // vs. gate unresolved), and both of those mean the same thing to the reader here.
        guard let isOwner = favoritesSync?.isOwner ?? nil else { return "Checking…" }
        return isOwner ? "Owner: two-way Apple Music sync on"
                       : "Not owner: favorites stay on this profile"
    }

    /// Encode the owner's Apple-Music-sourced ♥ and hand them to the file exporter.
    /// The version is a UNIX timestamp: `applySeed` only applies a seed NEWER than the one a
    /// tester already has, so each export must outrank the last, and wall-clock does that
    /// without any state to remember between exports.
    private func exportSeed() {
        guard let favoritesSync else { return }
        let seed = favoritesSync.exportSeed(version: Int(Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(seed) else { return }
        seedDoc = EditsFile(data: data)
        showSeedExporter = true
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
