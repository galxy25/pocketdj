import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Route value for the Games tab → MwF session push.
struct MwFSessionRoute: Hashable { let sessionId: String }

// MARK: - Create sheet

struct MwFCreateSheet: View {
    @Environment(MusicWithFriendsStore.self) private var friends
    @Environment(SettingsStore.self) private var settings
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss

    @State private var sessionName = ""
    @State private var theme = ""
    @State private var displayName = ""
    @State private var turnSeconds = 120
    @State private var acceptOutsideTurn = false
    @State private var turnEndsOnFirstSuggestion = true
    @State private var seeded = false
    /// THIS sheet's error (never the store's shared field — a poll in another window
    /// must not clear or forge the message the user is reading).
    @State private var createError: String?

    private static let themeMax = 144

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Session name", text: $sessionName)
                        .accessibilityIdentifier("mwf-create-session-name")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Theme (what should friends suggest?)", text: Binding(
                            get: { theme },
                            set: { theme = String($0.prefix(Self.themeMax)) }), axis: .vertical)
                            .lineLimit(2...4)
                            .accessibilityIdentifier("mwf-create-theme")
                        Text("\(theme.count)/\(Self.themeMax)")
                            .font(.caption2).foregroundStyle(Theme.fgDim)
                            .accessibilityIdentifier("mwf-create-theme-count")
                    }
                    TextField("Your display name", text: $displayName)
                        .accessibilityIdentifier("mwf-create-name")
                }
                Section("Turns") {
                    Picker("Turn length", selection: $turnSeconds) {
                        Text("30 s").tag(30)
                        Text("1 m").tag(60)
                        Text("2 m").tag(120)
                        Text("5 m").tag(300)
                    }
                    .accessibilityIdentifier("mwf-create-turn")
                    Toggle("Accept suggestions outside turns", isOn: $acceptOutsideTurn)
                        .accessibilityIdentifier("mwf-create-outside")
                    Toggle("Turn ends on first suggestion", isOn: $turnEndsOnFirstSuggestion)
                        .accessibilityIdentifier("mwf-create-first")
                }
                if settings.jukeboxServerURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Text("No jukebox server configured — set one in Settings ▸ Jukebox Hero.")
                            .font(.footnote).foregroundStyle(Theme.danger)
                    }
                }
                if let err = createError {
                    Section { Text(err).font(.footnote).foregroundStyle(Theme.danger) }
                }
                Section {
                    Button(friends.creating ? "Creating…" : "Create") {
                        Task {
                            createError = await friends.create(
                                name: sessionName, theme: theme, displayName: displayName,
                                settings: MwFSettings(turnSeconds: turnSeconds,
                                                      acceptOutsideTurn: acceptOutsideTurn,
                                                      turnEndsOnFirstSuggestion: turnEndsOnFirstSuggestion))
                            if createError == nil { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(friends.creating
                              || theme.trimmingCharacters(in: .whitespaces).isEmpty
                              || settings.jukeboxServerURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("mwf-create-submit")
                }
            }
            .navigationTitle("New Session")
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            guard !seeded else { return }
            seeded = true
            let name = (friends.profileNameProvider?() ?? profile.name)
                .trimmingCharacters(in: .whitespaces)
            displayName = name.isEmpty ? "Player" : name   // the JukeboxView.defaultName convention
            sessionName = name.isEmpty ? "Music with Friends" : "\(name)'s Music with Friends"
        }
    }
}

// MARK: - Join sheet

struct MwFJoinSheet: View {
    /// Pre-parsed link when opened from a tapped URL (hides the paste field).
    let link: MwFLink?
    @Environment(MusicWithFriendsStore.self) private var friends
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss

    @State private var pastedLink = ""
    @State private var displayName = ""
    @State private var themePreview: String?
    @State private var seeded = false
    /// THIS sheet's error (see MwFCreateSheet.createError).
    @State private var joinError: String?
    /// The in-flight preview fetch — cancelled + debounced on every edit, so a slow
    /// response for an OLD link can never overwrite a newer one's theme
    /// (the CollectorsPuzzleView.recount() pattern).
    @State private var previewTask: Task<Void, Never>?

    private var parsedLink: MwFLink? {
        if let link { return link }
        guard let url = URL(string: pastedLink.trimmingCharacters(in: .whitespaces)) else { return nil }
        return MwFLink(url: url)
    }

    var body: some View {
        NavigationStack {
            Form {
                if link == nil {
                    Section("Session link") {
                        TextField("https://jukebox.pocket-dj.com/mwf/…", text: $pastedLink)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("mwf-join-link")
                    }
                }
                if let theme = themePreview, !theme.isEmpty {
                    Section("Theme") {
                        Text(theme).font(.subheadline).foregroundStyle(Theme.fg)
                            .accessibilityIdentifier("mwf-join-theme")
                    }
                }
                Section("Your name") {
                    TextField("Display name", text: $displayName)
                        .accessibilityIdentifier("mwf-join-name")
                }
                if let err = joinError {
                    Section { Text(err).font(.footnote).foregroundStyle(Theme.danger) }
                }
                Section {
                    Button(friends.joining ? "Joining…" : "Join") {
                        guard let target = parsedLink else { return }
                        Task {
                            joinError = await friends.join(link: target, name: displayName)
                            if joinError == nil { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedLink == nil || friends.joining)
                    .accessibilityIdentifier("mwf-join-submit")
                }
            }
            .navigationTitle("Join Session")
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { friends.pendingJoin = nil; dismiss() }
                }
            }
        }
        .task {
            guard !seeded else { return }
            seeded = true
            let name = (friends.profileNameProvider?() ?? profile.name)
                .trimmingCharacters(in: .whitespaces)
            displayName = name.isEmpty ? "Player" : name
            await loadPreview()
        }
        .onChange(of: pastedLink) { _, _ in
            previewTask?.cancel()
            // The edited link may point at a DIFFERENT session (or none): the old theme
            // must never render over the new target — the user would join B believing
            // it is A. Clear first; the debounced fetch repaints when it lands.
            themePreview = nil
            previewTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await loadPreview()
            }
        }
        .onDisappear { previewTask?.cancel() }
    }

    private func loadPreview() async {
        guard let target = parsedLink, let stateURL = target.stateURL else { return }
        let client = MwFClient(baseURL: "", token: "")
        guard let pub = try? await client.publicState(url: stateURL) else { return }
        // The field may have moved on while this 12 s fetch was in flight — a late
        // response for an older link must never render over the current one.
        guard !Task.isCancelled, target == parsedLink else { return }
        themePreview = pub.theme
    }
}

// MARK: - Session screen

struct MusicWithFriendsSessionView: View {
    let sessionId: String
    @Binding var path: NavigationPath
    @Environment(MusicWithFriendsStore.self) private var friends
    @Environment(CollectionsStore.self) private var collections
    @Environment(\.dismiss) private var dismiss

    @State private var suggestTitle = ""
    @State private var suggestArtist = ""
    @State private var suggestError: String?
    @State private var approving: Set<String> = []
    @State private var showEndConfirm = false
    @State private var downloadedPocketId: String?
    @State private var showDownloadDone = false

    private var entry: MwFSessionEntry? { friends.entry(sessionId) }
    private var state: MwFState? { friends.lastState[sessionId] }
    private var youId: String? { entry?.memberId }
    private var isLeader: Bool { entry?.isLeader == true }
    private var ended: Bool { state?.ended == true }

    var body: some View {
        List {
            if let entry {
                header(entry)
                if ended {
                    endedBanner
                } else {
                    turnBanner
                }
                shareSection(entry)
                // Leader-verb failures (approve/reject/+1/settings/end) surface HERE, where
                // they happen — keyed by session id, so another session's window never
                // paints THIS session's banner. The create/join sheets keep their own local
                // messages, and the 4 s poll reports on `pollError` below, so these three
                // never overwrite each other across windows.
                if let err = friends.lastErrors[sessionId] {
                    Section {
                        Text(err).font(.footnote).foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("mwf-session-error")
                    }
                }
                // The poll's own channel: a dead/unreachable broker must not masquerade as
                // a live session — say the leaderboard is STALE and since when.
                if !ended, let perr = friends.pollErrors[sessionId] {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Can’t reach the server — showing the last known state.")
                                .font(.footnote).foregroundStyle(Theme.danger)
                            Text(perr).font(.caption2).foregroundStyle(Theme.fgDim)
                            if let at = state?.updatedAt {
                                Text("Last updated \(Date(timeIntervalSince1970: at / 1000), style: .relative) ago")
                                    .font(.caption2).foregroundStyle(Theme.fgDim)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("mwf-poll-error")
                    }
                }
                leaderboard
                if !ended {
                    suggestComposer
                }
                suggestionsFeed
                if isLeader && !ended {
                    leaderInbox
                    leaderSettings
                }
                collectionSection
                Section {
                    if isLeader && !ended {
                        Button("End Session", role: .destructive) { showEndConfirm = true }
                            .accessibilityIdentifier("mwf-end")
                    } else if !isLeader {
                        Button("Leave", role: .destructive) {
                            friends.leave(sessionId)
                            if !path.isEmpty { path.removeLast() } else { dismiss() }
                        }
                        .accessibilityIdentifier("mwf-leave")
                    }
                }
            } else {
                ContentUnavailableView("Session not found", systemImage: "person.3")
            }
        }
        .navigationTitle(entry?.name ?? "Music with Friends")
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .confirmationDialog("End this session for everyone?", isPresented: $showEndConfirm) {
            Button("End Session", role: .destructive) {
                Task { await friends.endSession(sessionId) }
            }
        }
        .alert("Collection downloaded", isPresented: $showDownloadDone) {
            Button("Open") {
                if let pid = downloadedPocketId, let pocket = collections.pocket(pid) {
                    path.append(pocket)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Saved to My Collections as a pocket.")
        }
        // The screen owns its own 4 s poll (auto-cancelled off-screen); pushes make it
        // feel instant but polling is the source of truth.
        .task(id: sessionId) {
            while !Task.isCancelled {
                _ = await friends.refresh(sessionId)
                if friends.lastState[sessionId]?.ended == true { break }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Sections

    private func header(_ entry: MwFSessionEntry) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(state?.theme ?? entry.theme ?? "")
                    .font(.headline).foregroundStyle(Theme.fg)
                    .accessibilityIdentifier("mwf-theme")
                if let expires = state?.expiresAt ?? entry.expiresAt {
                    Text(GamesView.expiresLabel(expires))
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
            }
        }
    }

    private var endedBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Session over").font(.headline).foregroundStyle(Theme.accent2)
                if let st = state {
                    Text("Your score: \(friends.myScore(st)) — recorded to Scoreboard")
                        .font(.subheadline).foregroundStyle(Theme.fgDim)
                }
            }
            .accessibilityIdentifier("mwf-ended-banner")
        }
    }

    private var turnBanner: some View {
        Section {
            let turn = state?.turn
            let member = state?.members?.first { $0.memberId == turn?.memberId }
            let isYou = turn?.memberId != nil && turn?.memberId == youId
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isYou ? "Your turn!" : "\(member?.name ?? "…")'s turn")
                        .font(.headline)
                        .foregroundStyle(isYou ? Theme.accent2 : Theme.fg)
                    if let deadline = turn?.deadline {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let remaining = max(0, Int((deadline - Date().timeIntervalSince1970 * 1000) / 1000))
                            Text(String(format: "%d:%02d left", remaining / 60, remaining % 60))
                                .font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mwf-turn-banner")
        }
    }

    private func shareSection(_ entry: MwFSessionEntry) -> some View {
        Section("Invite friends") {
            if let urlString = entry.url, let url = URL(string: urlString) {
                HStack {
                    Spacer()
                    PDJQRCodeView(text: urlString)
                        .frame(width: 160, height: 160)
                        .accessibilityIdentifier("mwf-share-qr")
                    Spacer()
                }
                ShareLink(item: url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("mwf-share-link")
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlString, forType: .string)
                    #else
                    UIPasteboard.general.string = urlString
                    #endif
                } label: {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("mwf-share-copy")
            }
        }
    }

    private var leaderboard: some View {
        Section("Leaderboard") {
            let members = (state?.members ?? []).sorted { ($0.score ?? 0) > ($1.score ?? 0) }
            ForEach(members) { m in
                HStack(spacing: 6) {
                    if m.isLeader == true {
                        Image(systemName: "crown.fill").font(.caption).foregroundStyle(Theme.accent2)
                    }
                    Text(m.name ?? "Player").foregroundStyle(Theme.fg)
                    if m.memberId == youId {
                        Text("(you)").font(.caption).foregroundStyle(Theme.fgDim)
                    }
                    Spacer()
                    Text("\(m.score ?? 0)")
                        .font(.body.monospacedDigit()).foregroundStyle(Theme.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mwf-member-\(m.id)")
            }
        }
    }

    /// Whose turn + whether I can suggest right now (the server enforces regardless).
    private var canSuggestNow: Bool {
        guard let st = state else { return true }
        if st.turn?.memberId == youId { return true }
        return st.settings?.acceptOutsideTurn ?? false
    }

    private var suggestComposer: some View {
        Section("Suggest a song") {
            TextField("Title", text: $suggestTitle)
                .accessibilityIdentifier("mwf-suggest-title")
            TextField("Artist", text: $suggestArtist)
                .accessibilityIdentifier("mwf-suggest-artist")
            Button("Suggest") {
                let title = suggestTitle.trimmingCharacters(in: .whitespaces)
                let artist = suggestArtist.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return }
                suggestError = nil
                Task {
                    do {
                        try await friends.suggest(sessionId, title: title, artist: artist)
                        suggestTitle = ""
                        suggestArtist = ""
                    } catch JukeboxClient.ClientError.http(let code) where code == 409 {
                        suggestError = "Not your turn yet — hang tight."
                    } catch {
                        suggestError = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSuggestNow || suggestTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("mwf-suggest-submit")
            if let err = suggestError {
                Text(err).font(.footnote).foregroundStyle(Theme.danger)
            }
            if !canSuggestNow {
                let name = state?.members?.first { $0.memberId == state?.turn?.memberId }?.name ?? "someone else"
                Text("Wait for your turn — \(name) is up")
                    .font(.footnote).foregroundStyle(Theme.fgDim)
            }
        }
    }

    private var suggestionsFeed: some View {
        Section("Suggestions") {
            let rows = (state?.suggestions ?? []).sorted { ($0.seq ?? 0) > ($1.seq ?? 0) }
            if rows.isEmpty {
                Text("No suggestions yet.").font(.footnote).foregroundStyle(Theme.fgDim)
            }
            ForEach(rows) { sg in
                suggestionRow(sg)
            }
        }
    }

    private func memberName(_ id: String?) -> String {
        state?.members?.first { $0.memberId == id }?.name ?? "Player"
    }

    private func suggestionRow(_ sg: MwFSuggestion) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sg.title ?? "?") — \(sg.artist ?? "?")")
                    .font(.subheadline).foregroundStyle(Theme.fg)
                Text(memberName(sg.memberId))
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            Spacer()
            statusChip(sg.status ?? "pending")
            if sg.status == "accepted", let sgId = sg.id {
                let mine = sg.memberId == youId
                let already = (sg.plusOnes ?? []).contains(youId ?? "")
                Button("+1 (\((sg.plusOnes ?? []).count))") {
                    Task { await friends.plusOne(sessionId, suggestionId: sgId) }
                }
                .buttonStyle(.bordered)
                .disabled(mine || already || ended)
                .accessibilityIdentifier("mwf-plusone-\(sgId)")
            }
        }
    }

    private func statusChip(_ status: String) -> some View {
        let color: Color = switch status {
        case "accepted": .green
        case "rejected": Theme.danger
        default: Theme.accent2
        }
        return Text(status)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var leaderInbox: some View {
        Section("Leader inbox") {
            let pending = (state?.suggestions ?? []).filter { $0.status == "pending" }
            if pending.isEmpty {
                Text("No pending suggestions.").font(.footnote).foregroundStyle(Theme.fgDim)
            }
            ForEach(pending) { sg in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sg.title ?? "?") — \(sg.artist ?? "?")")
                            .font(.subheadline).foregroundStyle(Theme.fg)
                        Text(memberName(sg.memberId)).font(.caption).foregroundStyle(Theme.fgDim)
                    }
                    Spacer()
                    if let sgId = sg.id {
                        if approving.contains(sgId) {
                            ProgressView()
                        } else {
                            Button("Accept") {
                                approving.insert(sgId)
                                Task {
                                    await friends.approve(sessionId, suggestion: sg)
                                    approving.remove(sgId)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("mwf-approve-\(sgId)")
                            Button("Reject") {
                                Task { await friends.reject(sessionId, suggestion: sg) }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("mwf-reject-\(sgId)")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var leaderSettings: some View {
        Section("Session settings") {
            @Bindable var friends = friends
            let s = state?.settings
            Picker("Turn length", selection: Binding(
                get: { s?.turnSeconds ?? 120 },
                set: { newValue in
                    Task {
                        await friends.updateSettings(sessionId, MwFSettings(turnSeconds: newValue))
                    }
                })) {
                Text("30 s").tag(30)
                Text("1 m").tag(60)
                Text("2 m").tag(120)
                Text("5 m").tag(300)
            }
            .accessibilityIdentifier("mwf-config-turn")
            Toggle("Accept suggestions outside turns", isOn: Binding(
                get: { s?.acceptOutsideTurn ?? false },
                set: { on in Task { await friends.updateSettings(sessionId, MwFSettings(acceptOutsideTurn: on)) } }))
                .accessibilityIdentifier("mwf-config-outside")
            Toggle("Turn ends on first suggestion", isOn: Binding(
                get: { s?.turnEndsOnFirstSuggestion ?? true },
                set: { on in Task { await friends.updateSettings(sessionId, MwFSettings(turnEndsOnFirstSuggestion: on)) } }))
                .accessibilityIdentifier("mwf-config-first")
            Toggle("Queue accepted songs", isOn: $friends.queueAccepted)
                .accessibilityIdentifier("mwf-queue-accepted")
        }
    }

    private var collectionSection: some View {
        Section {
            let count = state?.collection?.count ?? 0
            Text("Session collection · \(count) song\(count == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(Theme.fg)
            Button("Download to My Collections") {
                guard let st = state else { return }
                Task {
                    downloadedPocketId = await friends.downloadCollection(sessionId, state: st)
                    showDownloadDone = downloadedPocketId != nil
                }
            }
            .disabled((state?.collection ?? []).isEmpty)
            .accessibilityIdentifier("mwf-download-collection")
        }
    }
}
