import SwiftUI

/// The native GUEST view for a jukebox this device JOINED via a shared link (`JukeboxLink`).
/// Mirrors the web guest page: it renders the live now-playing / up-next / recently-played (polled
/// from the public `state.json` every ~4 s by `JukeboxStore.joinTick`) and lets the guest request a
/// song. This device is a CLIENT — it never hosts; only the device that STARTED the jukebox is the
/// lead. Presented as a sheet from `PocketDJApp` when `jukebox.joinedLink != nil`; dismissing leaves.
struct JukeboxJoinView: View {
    @Environment(JukeboxStore.self) private var jukebox
    @Environment(\.dismiss) private var dismiss
    @State private var reqTitle = ""
    @State private var reqArtist = ""
    @State private var submitting = false

    private var state: JukeboxGuestState? { jukebox.joined }
    private var ended: Bool { state?.ended == true }

    var body: some View {
        NavigationStack {
            List {
                if state == nil, let err = jukebox.joinError {
                    Section {
                        Label(err, systemImage: "wifi.exclamationmark")
                            .font(.callout).foregroundStyle(Theme.danger)
                    }
                } else if state == nil, jukebox.joining {
                    Section {
                        HStack(spacing: 8) { ProgressView(); Text("Joining…").foregroundStyle(Theme.fgDim) }
                    }
                }

                if ended {
                    Section {
                        Label("This jukebox has ended.", systemImage: "moon.zzz")
                            .foregroundStyle(Theme.fgDim)
                    }
                }

                if let np = state?.nowPlaying, (np.title ?? "").isEmpty == false || (np.artist ?? "").isEmpty == false {
                    Section("Now playing") {
                        trackRow(np.title, np.artist, titleFont: .headline)
                            .accessibilityIdentifier("jukebox-join-nowplaying")
                    }
                }

                if let up = state?.upNext, !up.isEmpty {
                    Section("Up next") {
                        ForEach(up) { t in trackRow(t.title, t.artist) }
                    }
                }

                if !ended {
                    Section("Request a song") {
                        TextField("Title", text: $reqTitle)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("jukebox-join-req-title")
                        TextField("Artist (optional)", text: $reqArtist)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("jukebox-join-req-artist")
                        Button {
                            Task {
                                submitting = true
                                await jukebox.submitJoinedRequest(title: reqTitle, artist: reqArtist)
                                submitting = false
                                if jukebox.joinError == nil { reqTitle = ""; reqArtist = "" }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if submitting { ProgressView() }
                                Text("Request").fontWeight(.semibold)
                            }
                        }
                        .disabled(reqTitle.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
                        .accessibilityIdentifier("jukebox-join-request")
                        if state != nil, let err = jukebox.joinError {
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
                    Section("Recently played") {
                        ForEach(played.prefix(10)) { t in trackRow(t.title, t.artist) }
                    }
                }
            }
            .navigationTitle(state?.name ?? "Jukebox")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Leave") { dismiss() }
                        .accessibilityIdentifier("jukebox-join-leave")
                }
            }
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
        jukebox.myRequestKeys.contains((r.title ?? "").lowercased() + "|" + (r.artist ?? "").lowercased())
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "queued", "played": return Theme.accent
        case "denied":           return Theme.danger
        default:                 return Theme.fgDim
        }
    }
}
