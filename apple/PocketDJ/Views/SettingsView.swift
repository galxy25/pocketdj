import SwiftUI
import UniformTypeIdentifiers

/// Settings — mirrors the PWA's: data sources, online-search credentials, the
/// rip-server config, an Edits export/import, plus a nuclear reset. No refresh /
/// data-migration controls: the App Store ships those with each new version.
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(AppModel.self) private var app
    @Environment(EditsStore.self) private var edits
    @Environment(CollectionsStore.self) private var collections

    @State private var ripTesting = false
    @State private var ripStatus: RipStatus?
    @State private var confirmingReset = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showCollectionsImporter = false
    @State private var exportDoc = EditsFile(data: Data())

    enum RipStatus { case ok(String), bad(String) }

    var body: some View {
        Form {
            sourcesSection
            searchSection
            ripSection
            editsSection
            collectionsSection
            resetSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .background(Theme.bg)
        .onDisappear { settings.persist() }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .json,
                      defaultFilename: "pocketdj-edits") { _ in }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                try? edits.importData(data)
                app.applyEdits()
            }
        }
        .fileImporter(isPresented: $showCollectionsImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { try? collections.importCollection(data: data) }
        }
    }

    // MARK: Collections (import a pocket / playlist export)

    private var collectionsSection: some View {
        Section {
            Button { showCollectionsImporter = true } label: {
                Label("Import pocket / playlist…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("collections-import")
        } header: {
            Text("Collections")
        } footer: {
            Text("\(collections.pockets.count) pocket\(collections.pockets.count == 1 ? "" : "s"), \(collections.playlists.count) playlist\(collections.playlists.count == 1 ? "" : "s"). Import a single pocket or playlist exported from another device — fresh ids are minted so it never overwrites an existing one. Export from an item’s detail-view ▸ menu.")
        }
    }

    // MARK: Edits (export / import)

    private var editsSection: some View {
        Section {
            Button {
                if let data = try? edits.exportData() { exportDoc = EditsFile(data: data); showExporter = true }
            } label: { Label("Export edits…", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("edits-export")
                .disabled(edits.count == 0)
            Button { showImporter = true } label: { Label("Import edits…", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("edits-import")
        } header: {
            Text("Edits")
        } footer: {
            Text("\(edits.count) local metadata edit\(edits.count == 1 ? "" : "s"). Export to JSON (schema v\(editsSchemaVersion)) to merge into the main index on the iMac; Import merges another export in.")
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        Section {
            ForEach($settings.sources) { $source in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $source.name)
                            .textFieldStyle(.roundedBorder)
                        Toggle("", isOn: $source.enabled).labelsHidden()
                        Button(role: .destructive) {
                            settings.removeSource(source.id)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings-source-remove")
                    }
                    TextField("Index URL", text: $source.urlString)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                .padding(.vertical, 2)
            }
            Button { settings.addSource() } label: { Label("Add source", systemImage: "plus") }
                .accessibilityIdentifier("settings-add-source")
            if !settings.hasAppleMusic {
                Button {
                    settings.loadAppleMusic()
                    Task { await app.reload() }
                } label: { Label("Load Apple Music (Local) library", systemImage: "music.note.house") }
                    .accessibilityIdentifier("settings-load-apple-music")
            }
            Button {
                settings.persist()
                Task { await app.reload() }
            } label: { Label("Reload catalog", systemImage: "arrow.clockwise") }
                .accessibilityIdentifier("settings-reload")
        } header: {
            Text("Data sources")
        } footer: {
            Text("Choose which sources to show across the app. Each is a PocketDJ index URL served from CloudFront/S3.")
        }
    }

    // MARK: Online search

    private var searchSection: some View {
        Section {
            TextField("Access key ID", text: $settings.searchAccessKeyID)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("settings-search-akid")
            SecureField("Secret access key", text: $settings.searchSecretKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings-search-secret")
            TextField("Endpoint (optional)", text: $settings.searchEndpoint)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            HStack {
                Button("Save") { settings.persist() }
                    .accessibilityIdentifier("settings-search-save")
                Spacer()
                Button("Clear", role: .destructive) {
                    settings.searchAccessKeyID = ""; settings.searchSecretKey = ""
                    settings.searchEndpoint = ""; settings.persist()
                }
                if settings.searchConfigured {
                    Label("Configured", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                }
            }
        } header: {
            Text("Online search (OpenSearch)")
        } footer: {
            Text("Enables full-text search across the whole collection. Leave blank to stay fully offline.")
        }
    }

    // MARK: Rip server

    private var ripSection: some View {
        Section {
            TextField("Rip server URL", text: $settings.ripServerURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("settings-rip-url")
            TextField("Token (optional)", text: $settings.ripToken)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings-rip-token")
            HStack {
                Button {
                    settings.persist()
                    Task { await testRip() }
                } label: {
                    if ripTesting { ProgressView() } else { Text("Test connection") }
                }
                .disabled(ripTesting)
                .accessibilityIdentifier("settings-rip-test")
                Spacer()
                ripStatusView
            }
        } header: {
            Text("Rip server")
        } footer: {
            Text("The iMac rip-on-demand server (over Tailscale). Streams/downloads any song; only needed to create a rip — once ripped it plays from S3 anywhere.")
        }
    }

    @ViewBuilder private var ripStatusView: some View {
        switch ripStatus {
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                .accessibilityIdentifier("settings-rip-status")
        case .bad(let msg):
            Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.caption)
                .accessibilityIdentifier("settings-rip-status")
        case nil:
            EmptyView()
        }
    }

    private func testRip() async {
        ripTesting = true; ripStatus = nil
        let result = await RipServerService.health(urlString: settings.ripServerURL, token: settings.ripToken)
        switch result {
        case .success(let h):
            var parts: [String] = []
            if let c = h.catalog { parts.append("\(c.songs ?? 0) songs") }
            if let v = h.version { parts.append("v\(v)") }
            if h.hls == true { parts.append("HLS") }
            if let v = h.version, v < RipServerService.expectedVersion { parts.append("⚠︎ outdated") }
            ripStatus = .ok(parts.isEmpty ? "Online" : parts.joined(separator: " · "))
        case .failure(let e):
            ripStatus = .bad((e as? URLError)?.code == .timedOut ? "Timed out" : "Unreachable")
        }
        ripTesting = false
    }

    // MARK: Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) { confirmingReset = true } label: {
                Label("Reset all app state", systemImage: "trash")
            }
            .accessibilityIdentifier("settings-reset")
            .confirmationDialog("Reset everything on this device?",
                                isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset everything", role: .destructive) {
                    settings.resetEverything()
                    Task { await app.reload() }
                }
                .accessibilityIdentifier("settings-reset-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes sources, search & rip-server config, and cached covers. Your collections are cleared too. This can’t be undone.")
            }
        } footer: {
            Text("PocketDJ \(appVersion). App updates (new views + data migrations) ship via the App Store.")
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? ""
    }
}
