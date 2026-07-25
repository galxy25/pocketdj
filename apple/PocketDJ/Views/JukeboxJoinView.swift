import SwiftUI

/// The native GUEST PANEL for a jukebox this device JOINED. PUSHED (not a sheet) from the Jukebox
/// home's joined-sessions list, so it's a normal in-app screen with a Back button. It owns its OWN
/// live poll of the public `state.json` via `.task` — which SwiftUI cancels automatically when the
/// panel closes, so exactly one session polls at a time and leaving stops it. This device is a
/// CLIENT: it never hosts; only the device that STARTED the jukebox is the lead.
struct JukeboxJoinView: View {
    @Environment(JukeboxStore.self) private var jukebox
    @Environment(\.dismiss) private var dismiss
    let entry: JukeboxStore.JoinedEntry

    @State private var state: JukeboxGuestState?
    @State private var joinError: String?
    @State private var loading = true
    @State private var myKeys: Set<String> = []
    @State private var reqTitle = ""
    @State private var reqArtist = ""
    @State private var submitting = false

    private var ended: Bool { state?.ended == true }

    var body: some View {
        List {
            if state == nil, let err = joinError {
                Section {
                    Label(err, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(Theme.danger)
                }
            } else if state == nil, loading {
                Section {
                    HStack(spacing: 8) { ProgressView(); Text("Connecting…").foregroundStyle(Theme.fgDim) }
                }
            }

            if ended {
                Section {
                    Label("This jukebox has ended.", systemImage: "moon.zzz").foregroundStyle(Theme.fgDim)
                }
            }

            if let np = state?.nowPlaying, (np.title ?? "").isEmpty == false || (np.artist ?? "").isEmpty == false {
                Section("Now playing") {
                    trackRow(np.title, np.artist, titleFont: .headline)
                        .accessibilityIdentifier("jukebox-join-nowplaying")
                }
            }

            if let up = state?.upNext, !up.isEmpty {
                Section("Up next") { ForEach(up) { t in trackRow(t.title, t.artist) } }
            }

            if !ended {
                Section("Request a song") {
                    TextField("Title", text: $reqTitle)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("jukebox-join-req-title")
                    TextField("Artist (optional)", text: $reqArtist)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("jukebox-join-req-artist")
                    Button { submit() } label: {
                        HStack(spacing: 6) { if submitting { ProgressView() }; Text("Request").fontWeight(.semibold) }
                    }
                    .disabled(reqTitle.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
                    .accessibilityIdentifier("jukebox-join-request")
                    if state != nil, let err = joinError {
                        Text(err).font(.caption).foregroundStyle(Theme.danger)
                    }
                }
            }

            let mine = state?.requests.filter(isMine) ?? []
            if !mine.isEmpty {
                Section("Your requests") {
                    ForEach(mine) { r in
                        HStack {
                            trackRow(r.title, r.artist)
                            Spacer(minLength: 8)
                            Text((r.status ?? "pending").capitalized)
                                .font(.caption).foregroundStyle(statusColor(r.status))
                        }
                    }
                }
            }

            if let played = state?.played, !played.isEmpty {
                Section("Recently played") { ForEach(played.prefix(10)) { t in trackRow(t.title, t.artist) } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(state?.name ?? entry.name ?? "Jukebox")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { jukebox.removeJoined(id: entry.id); dismiss() } label: {
                    Text("Leave")
                }
                .accessibilityIdentifier("jukebox-join-leave")
            }
        }
        // Owns the live poll while visible; cancelled automatically on disappear (Back / Leave).
        .task(id: entry.id) { await poll() }
    }

    private func poll() async {
        guard let link = jukebox.link(for: entry) else {
            loading = false; joinError = "This jukebox link is invalid."; return
        }
        while !Task.isCancelled {
            do {
                let s = try await jukebox.guestState(link)
                state = s; loading = false; joinError = nil
                jukebox.updateJoinedName(id: entry.id, name: s.name)
                if s.ended == true { break }   // party over — stop polling, keep the final snapshot
            } catch {
                loading = false
                // Deleted / expired jukebox → show ended and stop (don't hammer the dead URL).
                if case JukeboxClient.ClientError.http(let code) = error, code == 404 || code == 410 {
                    var s = state ?? .empty; s.ended = true; state = s; joinError = nil; break
                }
                joinError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func submit() {
        let t = reqTitle.trimmingCharacters(in: .whitespaces)
        let a = reqArtist.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        submitting = true
        Task {
            do {
                try await jukebox.submitGuestRequest(jukeboxId: entry.id, apiBase: state?.apiBase,
                                                     title: t, artist: a)
                myKeys.insert(t.lowercased() + "|" + a.lowercased())
                joinError = nil; reqTitle = ""; reqArtist = ""
            } catch {
                joinError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            submitting = false
        }
    }

    @ViewBuilder
    private func trackRow(_ title: String?, _ artist: String?, titleFont: Font = .subheadline) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text((title ?? "").isEmpty ? "—" : title!).font(titleFont).foregroundStyle(Theme.fg).lineLimit(1)
            if let a = artist, !a.isEmpty {
                Text(a).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
        }
    }

    private func isMine(_ r: JukeboxGuestState.GuestRequest) -> Bool {
        myKeys.contains((r.title ?? "").lowercased() + "|" + (r.artist ?? "").lowercased())
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "queued", "played": return Theme.accent
        case "denied":           return Theme.danger
        default:                 return Theme.fgDim
        }
    }
}
