import SwiftUI
import AVFoundation

/// The native GUEST PANEL for a jukebox this device JOINED. PUSHED (not a sheet) from the Jukebox
/// home's joined-sessions list — a real in-app screen with Back. It owns its OWN live poll of the
/// public `state.json` via `.task` (auto-cancelled on close), and (when the host has Hear mode on)
/// can TUNE IN to the party's audio — the current track's public stream, position-synced — just like
/// the web guest page's "Listen in". This device is a CLIENT: only the device that STARTED the
/// jukebox is the lead.
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
    // Tune in — a dedicated player for the party's public stream (mirrors the web "Listen in").
    @State private var streamPlayer: AVPlayer?
    @State private var tunedIn = false

    private var ended: Bool { state?.ended == true }
    private var canTuneIn: Bool { state?.hear == true && (state?.nowPlaying?.streamUrl?.isEmpty == false) }

    var body: some View {
        List {
            statusSection
            nowPlayingSection
            requestSection          // ← directly under Now playing (Levi)
            upNextSection
            yourRequestsSection
            playedSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(state?.name ?? entry.name ?? "Jukebox")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { leave() } label: { Text("Leave") }
                    .accessibilityIdentifier("jukebox-join-leave")
            }
        }
        .task(id: entry.id) { await poll() }
        // Follow the party: re-point the stream at the new track (position-synced) when it changes.
        .onChange(of: state?.nowPlaying?.streamUrl) { _, _ in if tunedIn { retuneToCurrent() } }
        .onDisappear { stopStream() }
    }

    // MARK: Sections

    @ViewBuilder private var statusSection: some View {
        if state == nil, let err = joinError {
            Section { Label(err, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(Theme.danger) }
        } else if state == nil, loading {
            Section { HStack(spacing: 8) { ProgressView(); Text("Connecting…").foregroundStyle(Theme.fgDim) } }
        }
        if ended {
            Section { Label("This jukebox has ended.", systemImage: "moon.zzz").foregroundStyle(Theme.fgDim) }
        }
    }

    @ViewBuilder private var nowPlayingSection: some View {
        if let np = state?.nowPlaying, (np.title ?? "").isEmpty == false || (np.artist ?? "").isEmpty == false {
            Section("Now playing") {
                trackRow(np.title, np.artist, titleFont: .headline)
                    .accessibilityIdentifier("jukebox-join-nowplaying")
                if canTuneIn {
                    Button { tunedIn ? stopStream() : tuneIn() } label: {
                        Label(tunedIn ? "Stop" : "Tune in",
                              systemImage: tunedIn ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
                            .foregroundStyle(tunedIn ? Theme.danger : Theme.accent)
                    }
                    .accessibilityIdentifier("jukebox-join-tunein")
                }
            }
        }
    }

    @ViewBuilder private var requestSection: some View {
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
    }

    @ViewBuilder private var upNextSection: some View {
        if let up = state?.upNext, !up.isEmpty {
            Section("Up next") { ForEach(up) { t in trackRow(t.title, t.artist) } }
        }
    }

    @ViewBuilder private var yourRequestsSection: some View {
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
    }

    @ViewBuilder private var playedSection: some View {
        if let played = state?.played, !played.isEmpty {
            Section("Recently played") { ForEach(played.prefix(10)) { t in trackRow(t.title, t.artist) } }
        }
    }

    // MARK: Poll + request + tune-in

    private func poll() async {
        guard let link = jukebox.link(for: entry) else {
            loading = false; joinError = "This jukebox link is invalid."; return
        }
        while !Task.isCancelled {
            do {
                let s = try await jukebox.guestState(link)
                state = s; loading = false; joinError = nil
                jukebox.updateJoinedName(id: entry.id, name: s.name)
                if s.ended == true { stopStream(); break }
            } catch {
                loading = false
                if case JukeboxClient.ClientError.http(let code) = error, code == 404 || code == 410 {
                    var s = state ?? .empty; s.ended = true; state = s; joinError = nil; stopStream(); break
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

    /// Start playing the party's current track from its public stream, seeking to the host's live
    /// position (like the web page's "Listen in" — the DJ's own prepared copy over a session link).
    private func tuneIn() {
        guard let urlStr = state?.nowPlaying?.streamUrl, let url = URL(string: urlStr) else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let p = AVPlayer(url: url)
        if let ms = state?.nowPlaying?.positionMs, ms > 0 {
            p.seek(to: CMTime(seconds: Double(ms) / 1000, preferredTimescale: 600))
        }
        p.play()
        streamPlayer = p
        tunedIn = true
    }

    /// The now-playing track changed while tuned in → follow it (new stream, re-synced position).
    private func retuneToCurrent() {
        guard tunedIn else { return }
        guard let urlStr = state?.nowPlaying?.streamUrl, let url = URL(string: urlStr) else { stopStream(); return }
        streamPlayer?.replaceCurrentItem(with: AVPlayerItem(url: url))
        if let ms = state?.nowPlaying?.positionMs, ms > 0 {
            streamPlayer?.seek(to: CMTime(seconds: Double(ms) / 1000, preferredTimescale: 600))
        }
        streamPlayer?.play()
    }

    private func stopStream() {
        streamPlayer?.pause()
        streamPlayer = nil
        tunedIn = false
    }

    private func leave() {
        stopStream()
        jukebox.removeJoined(id: entry.id)
        dismiss()
    }

    // MARK: Row helpers

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
