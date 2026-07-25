import SwiftUI
import CoreImage.CIFilterBuiltins

/// Pushed-navigation route to the Jukebox view — the Mix tab's Broadcast button pushes
/// this onto ITS NavigationStack, so Back lands the DJ right back on the decks.
struct JukeboxRoute: Hashable {}

/// Pushed-navigation route to a JOINED jukebox's live guest panel — tapping a joined session on the
/// Jukebox home pushes `JukeboxJoinView` (a native in-app screen, not a popup sheet).
struct JukeboxJoinRoute: Hashable { let entry: JukeboxStore.JoinedEntry }

// #TOUPDATE: "token-gated" and "capped" describe the target, not today. jukebox-server.mjs
// serves the guest page as a public object with no guest credential — tokenOk (:413) gates
// session CREATION only and fail-opens when JUKEBOX_TOKEN is unset — and the server's own
// header (:9) says it takes "any number of listeners"; the only limit is a per-IP request
// rate window. True when the guest route rejects a request carrying no valid per-session
// token and the server turns guests away once the listener cap is reached.
// #TOUPDATE: "only ever plays from media the DJ owns — nothing is captured" is the target.
// Today JukeboxStore.acceptIntoMix calls burns.startRipAndBurn for an Apple-Music-only
// match during a broadcast, and rip-server.mjs:798 routes every digital id to Apple Music
// capture regardless of the cloud-source flag. True when the server fails closed on media
// the DJ does not own in their cloud library and an unowned request resolves as a miss.
/// The JUKEBOX HERO tab (⌘J): turn the room into a request line for a private event. Start
/// a jukebox and a QR code appears — guests scan it, land on the hosted guest page (now
/// playing + up next, live), and type in requests. The code is token-gated and the room is
/// capped, so the party stays the one you're standing in. Each request arrives here matched
/// against the catalog (FM pick / Apple Music search — see JukeboxMatcher); the host DJ
/// decides: Deny, Play Next, Play Last, or Surprise Slot (a random spot in the queue).
/// A placed request only ever plays from media the DJ owns — Apple Music matches stream
/// through MusicKit, nothing is captured. Queue and playback are the same app-scoped
/// SetlistPlayer the Now Playing panel drives.
struct JukeboxView: View {
    @Environment(JukeboxStore.self) private var jukebox
    @Environment(SettingsStore.self) private var settings
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(PlayerEngine.self) private var player
    @Environment(PlaybackCoordinator.self) private var coordinator

    @State private var name = ""
    @State private var timeless = false
    /// Per-session override of Settings ▸ Jukebox Hero ▸ "Require access token" — seeded from
    /// that default in createView's .onAppear, then adjustable for this one session.
    @State private var requiresToken = true
    @State private var confirmEnd = false

    var body: some View {
        Group {
            if let session = jukebox.session {
                liveView(session)
            } else {
                createView
            }
        }
        .navigationTitle("Jukebox Hero")
        .background(Theme.bg)
        // Jukeboxes this device JOINED (as a guest) appear as a strip at the top of the home;
        // tapping one pushes its live native panel. Levi's flow: join → in the list → tap → panel.
        .safeAreaInset(edge: .top) {
            if !jukebox.joinedSessions.isEmpty { joinedSessionsStrip }
        }
    }

    // MARK: - Joined jukeboxes (this device is a guest of)

    private var joinedSessionsStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Joined jukeboxes")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.fgDim)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            ForEach(jukebox.joinedSessions) { entry in
                NavigationLink(value: JukeboxJoinRoute(entry: entry)) {
                    HStack(spacing: 10) {
                        Image(systemName: "qrcode.viewfinder").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name ?? "Jukebox").font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.fg).lineLimit(1)
                            Text(entry.id).font(.caption2).foregroundStyle(Theme.fgDim)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.fgDim)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("jukebox-joined-\(entry.id)")
                .contextMenu {
                    Button(role: .destructive) { jukebox.removeJoined(id: entry.id) } label: {
                        Label("Leave jukebox", systemImage: "xmark.circle")
                    }
                }
            }
            Divider().overlay(Theme.border)
        }
        .background(Theme.bgRaised)
    }

    // MARK: - Create (no session)

    private var createView: some View {
        VStack(spacing: 18) {
            Spacer()
            JukeboxIcon(mode: .staticIcon)
                .frame(width: 84, height: 110)
            Text("Start a jukebox")
                .font(.title2.weight(.semibold)).foregroundStyle(Theme.fg)
            // #TOUPDATE: mint a per-session guest token (default on) and carry it in the QR
            // payload and the share link, so the CODE is what admits a guest, not the URL.
            // Today jukebox-server.mjs hands back a bare `${siteBase}/jukebox/${id}/` public
            // object URL (:247) and the guest request route is explicitly public — anyone who
            // gets the link is in. True when the guest page and its state.json refuse a
            // request that carries no valid session token.
            Text("Guests scan a QR code, see what's playing, and request songs.\nYou stay the DJ — every request is yours to place or deny.\nThe code carries this session's token, so only the people you show it to get in.")
                .font(.callout).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
            TextField("Jukebox name", text: $name, prompt: Text(defaultName))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("jukebox-name")
                .onSubmit { start() }
            // #TOUPDATE: Timeless has to go — every jukebox session must expire, and this
            // opt-out is why the footer below can't be believed. Deleting the Toggle alone
            // only moves the affordance, so it stays until the functional cut lands; the cut
            // is: this Toggle + @State timeless, the `timeless:` argument on
            // JukeboxStore.start, the live-session Toggle and JukeboxStore.setTimeless in
            // modeSection, the expiryText "Stays up until you end it." branch,
            // JukeboxModels' `timeless` field and JukeboxClient's /config call, and in
            // jukebox-server.mjs expiryOf (:121), the /config route (:250) and both
            // `!s.timeless` sweeper gates (:339, :362) — plus a backfill giving sessions
            // already persisted with timeless:true an expiresAt, or they outlive the removal.
            Toggle("Timeless — never expires", isOn: $timeless)
                .font(.caption).foregroundStyle(Theme.fgDim)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("jukebox-timeless")
            Toggle("Require access token", isOn: $requiresToken)
                .font(.caption).foregroundStyle(Theme.fgDim)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("jukebox-require-token")
            Button {
                start()
            } label: {
                if jukebox.starting {
                    ProgressView().frame(minWidth: 120)
                } else {
                    Text("Start Jukebox").frame(minWidth: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(jukebox.starting)
            .accessibilityIdentifier("jukebox-start")
            if let err = jukebox.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("jukebox-error")
            }
            // #TOUPDATE: two claims here run ahead of the code. (1) "Every session runs for
            // 24 hours and cleans itself up after 7 days" is only true once Timeless is gone
            // — jukebox-server.mjs skips both the auto-end and the delete sweep for timeless
            // sessions (:339, :362), and the Toggle above is right there. (2) There is no
            // listener cap: the server accepts any number of listeners and only rate-limits
            // requests per IP (ipWindowMax, :62). True when expiry is unconditional and the
            // server refuses guests past a configured cap.
            Text("Every session runs for 24 hours and cleans itself up after 7 days, and only so many guests can be on at once. Uses the jukebox server in Settings ▸ Jukebox Hero.")
                .font(.caption2).foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Seed the per-session toggle from the Settings default each time the create view
        // appears (so a change in Settings is reflected for the next session).
        .onAppear { requiresToken = settings.jukeboxTokensRequiredByDefault }
    }

    private var defaultName: String { Self.defaultName(settings) }

    /// Shared with the Mix tab's Broadcast button (which creates a session directly).
    static func defaultName(_ settings: SettingsStore) -> String {
        let dj = settings.pocketDJName.trimmingCharacters(in: .whitespaces)
        return dj.isEmpty ? "PocketDJ Jukebox" : "\(dj)'s Jukebox"
    }

    private func start() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await jukebox.start(name: trimmed.isEmpty ? defaultName : trimmed, timeless: timeless, requiresToken: requiresToken) }
    }

    // MARK: - Live session

    private func liveView(_ session: JukeboxSessionInfo) -> some View {
        List {
            qrSection(session)
            modeSection(session)
            nowPlayingSection
            requestsSection
            endSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .confirmationDialog("End this jukebox?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End Jukebox", role: .destructive) {
                Task { await jukebox.end() }
            }
        } message: {
            // #TOUPDATE: ending a session must revoke the guest link — page AND audio. Today
            // the guest page flips to "ended", but the rips/<songId>.mp3 URL guests already
            // hold keeps playing forever (same fix as the View + Hear marker: per-session,
            // expiring guest audio URLs).
            Text("Guests' pages will show the jukebox as ended and their link stops working. Playback keeps going.")
        }
    }

    /// The live mark: colors wander while the session is up; breathes while the
    /// guests can actually hear something (same audibility rule as the sidebar row).
    private var liveIconMode: JukeboxIconMode {
        let audible = sequencer.isRunning &&
            (coordinator.activeBackend == .appleMusic ? coordinator.isPlaying : player.isPlaying)
        return JukeboxIconMode.resolve(sessionActive: true, isPlaying: audible)
    }

    @ViewBuilder private func qrSection(_ session: JukeboxSessionInfo) -> some View {
        Section {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    JukeboxIcon(mode: liveIconMode)
                        .frame(width: 34, height: 44)
                    Text(session.name)
                        .font(.headline).foregroundStyle(Theme.fg)
                        .accessibilityIdentifier("jukebox-live-name")
                }
                // White card + quiet zone are load-bearing: phone cameras need the
                // contrast against the app's near-black background.
                JukeboxQRView(text: session.url)
                    .frame(width: 220, height: 220)
                Text("Scan to see what's playing and request a song")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                HStack(spacing: 12) {
                    if let url = URL(string: session.url) {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("jukebox-share")
                    }
                    Button {
                        copyToPasteboard(session.url)
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("jukebox-copy")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                if let err = jukebox.lastError {
                    Label(err, systemImage: "wifi.exclamationmark")
                        .font(.caption2).foregroundStyle(Theme.danger)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Theme.bg)
            .listRowSeparator(.hidden)
        }
    }

    // #TOUPDATE: "the DJ's own prepared copy, over a link scoped to this session" is the
    // target. Today JukeboxStore.hearStreamURL returns RipsStore.cachedURL — the flat,
    // public-read rips/<songId>.mp3 object, one namespace shared across every user, with no
    // auth and no expiry, so it stays playable long after the session is swept. True when
    // prepared copies are per-user and the guest audio URL is minted per session and dies
    // with it. (Timeless itself should not exist — see the create-view marker.)
    /// The DJ's session controls: View + Hear (guests may play the DJ's own prepared copy of
    /// the current track, over a link scoped to this session — off by default: a pure
    /// request line) and Timeless (opt out of the 24 h / 7 d server lifecycle), plus the
    /// expiry readout.
    @ViewBuilder private func modeSection(_ session: JukeboxSessionInfo) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { jukebox.hearEnabled },
                set: { jukebox.hearEnabled = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("View + Hear").font(.caption).foregroundStyle(Theme.fg)
                    // #TOUPDATE: session-scoped, expiring guest audio, off your own copy.
                    // Today hearStreamURL hands guests the flat public rips/<songId>.mp3
                    // object — unauthenticated, shared across users, outliving the session.
                    // True when each user's prepared copy is per-user and the guest link is
                    // minted per session and expires with it. The "only if your copy is
                    // ready" half is already true: hearStreamURL returns nil for any track
                    // with no manifest entry, so it stays view-only.
                    Text(jukebox.hearEnabled
                         ? "Guests hear the current track once your own copy of it is ready — over a link that belongs to this session and dies with it. Anything else stays view-only. Playing to a room needs licences PocketDJ can't give you."
                         : "View only — guests see what's playing, they don't hear it.")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
            }
            .accessibilityIdentifier("jukebox-hear")
            .listRowBackground(Theme.bg)
            Toggle(isOn: Binding(
                get: { session.timeless ?? false },
                set: { on in Task { await jukebox.setTimeless(on) } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Timeless").font(.caption).foregroundStyle(Theme.fg)
                    Text(expiryText(session)).font(.caption2).foregroundStyle(Theme.fgDim)
                }
            }
            .accessibilityIdentifier("jukebox-timeless-live")
            .listRowBackground(Theme.bg)
            Toggle(isOn: Binding(
                get: { session.requiresToken ?? false },
                set: { on in jukebox.setRequiresToken(on) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Require access token").font(.caption).foregroundStyle(Theme.fg)
                    // #TOUPDATE: flipping this on a live session must make the server mint/revoke
                    // the guest token and re-publish the guest page — see JukeboxStore.setRequiresToken.
                    Text((session.requiresToken ?? false)
                         ? "Only guests with this session's code (in the link) can join."
                         : "Anyone with the link can join.")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
            }
            .accessibilityIdentifier("jukebox-require-token-live")
            .listRowBackground(Theme.bg)
        } header: {
            Text("Session").font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
        }
    }

    private func expiryText(_ session: JukeboxSessionInfo) -> String {
        if session.timeless == true { return "Stays up until you end it." }
        guard let ms = session.expiresAt else { return "Ends 24 hours after start; cleaned up in 7 days." }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let rel = date.formatted(.relative(presentation: .named))
        return "Ends \(rel); cleaned up 7 days after start."
    }

    @ViewBuilder private var nowPlayingSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: sequencer.isRunning ? "waveform" : "waveform.slash")
                    .foregroundStyle(sequencer.isRunning ? Theme.accent : Theme.fgDim)
                if sequencer.isRunning, sequencer.index < sequencer.queue.count {
                    let it = sequencer.queue[sequencer.index]
                    VStack(alignment: .leading, spacing: 0) {
                        Text(it.title).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                        Text(it.artist).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                    }
                    Spacer()
                    Text("\(sequencer.upcoming.count) up next")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                } else {
                    Text("Nothing playing — the first accepted request starts the music.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
            }
            .listRowBackground(Theme.bg)
            .accessibilityIdentifier("jukebox-now-playing")
        } header: {
            Text("On air").font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
        }
    }

    @ViewBuilder private var requestsSection: some View {
        Section {
            if jukebox.inbox.isEmpty {
                Text("No requests yet — they'll appear here as guests send them.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .listRowBackground(Theme.bg)
                    .accessibilityIdentifier("jukebox-no-requests")
            }
            ForEach(jukebox.inbox) { item in
                JukeboxRequestRow(item: item)
                    .listRowBackground(Theme.bg)
            }
        } header: {
            Text("Requests (\(jukebox.inbox.count))")
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.fgDim)
        }
    }

    @ViewBuilder private var endSection: some View {
        Section {
            Button(role: .destructive) {
                confirmEnd = true
            } label: {
                if jukebox.ending { ProgressView() } else { Label("End Jukebox", systemImage: "stop.circle") }
            }
            .disabled(jukebox.ending)
            .accessibilityIdentifier("jukebox-end")
            .listRowBackground(Theme.bg)
        }
    }

    private func copyToPasteboard(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}

// MARK: - One request row

/// A guest request: what they typed, what the matcher found, and the verdict buttons.
/// Deny is always available; placements need a playable match.
private struct JukeboxRequestRow: View {
    @Environment(JukeboxStore.self) private var jukebox
    let item: JukeboxStore.InboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2")
                    .font(.caption).foregroundStyle(Theme.accent2)
                Text("\(item.request.title) — \(item.request.artist.isEmpty ? "?" : item.request.artist)")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
            }
            matchLine
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    jukebox.deny(item)
                } label: {
                    Text("Deny").font(.caption)
                }
                .accessibilityIdentifier("jukebox-deny-\(item.request.id)")
                Spacer()
                placementButton(.next, icon: "text.line.first.and.arrowtriangle.forward")
                placementButton(.end, icon: "text.append")
                placementButton(.random, icon: "dice")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("jukebox-request-\(item.request.id)")
    }

    @ViewBuilder private var matchLine: some View {
        switch item.match {
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Matching…").font(.caption2).foregroundStyle(Theme.fgDim)
            }
        case .some(.catalog(let song)):
            Label("\(song.name) — \(song.artist)", systemImage: "checkmark.circle")
                .font(.caption2).foregroundStyle(Theme.accent).lineLimit(1)
        case .some(.appleMusic(_, let title, let artist)):
            Label("\(title) — \(artist) (Apple Music)", systemImage: "music.note")
                .font(.caption2).foregroundStyle(Theme.accent).lineLimit(1)
        case .some(.none):
            Label("No match found", systemImage: "questionmark.circle")
                .font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    @ViewBuilder private func placementButton(_ action: JukeboxDecisionAction, icon: String) -> some View {
        Button {
            jukebox.accept(item, placement: action)
        } label: {
            Label(action.label, systemImage: icon)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        }
        .disabled(!playable)
        .accessibilityIdentifier("jukebox-\(action.rawValue)-\(item.request.id)")
    }

    private var playable: Bool {
        switch item.match {
        case .catalog, .appleMusic: return true
        default: return false
        }
    }
}

// MARK: - QR code

/// The scannable code: CoreImage's QR generator, rendered crisp (no interpolation) on a
/// white rounded card whose padding doubles as the spec's quiet zone. First QR use in
/// the app — kept tiny and self-contained.
struct JukeboxQRView: View {
    let text: String

    var body: some View {
        Group {
            if let cg = Self.qrImage(for: text) {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 80)).foregroundStyle(Theme.bg)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityLabel("Jukebox QR code")
        .accessibilityIdentifier("jukebox-qr")
    }

    static func qrImage(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Integer-scale the ~30px module grid up so each module stays a sharp square.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
