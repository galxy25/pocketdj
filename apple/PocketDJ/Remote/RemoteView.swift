import SwiftUI
#if canImport(GroupActivities)
import GroupActivities
#endif
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// ============================================================================
// MARK: - Shared pieces (every platform, incl. the TV tab)
// ============================================================================

/// One participant row: name, host / role badges, and an "N songs unavailable" warning.
struct RemotePeerRow: View {
    let peer: RemoteSessionController.Peer
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peer.role == .speaker ? "hifispeaker.fill" : "iphone.radiowaves.left.and.right")
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.isLocal ? "\(peer.name) (this device)" : peer.name)
                if peer.unavailableCount > 0 {
                    Label("\(peer.unavailableCount) song\(peer.unavailableCount == 1 ? "" : "s") can’t play here",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if peer.isHost { RemoteBadge(text: "Host", tint: Theme.accent) }
            RemoteBadge(text: peer.role == .speaker ? "Speaker" : "Controller", tint: Theme.fgDim)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote-peer-\(peer.id)")
    }
}

struct RemoteBadge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// ⏮ ▶/⏸ ⏭ for the SESSION (commands to the host, never the local player directly).
struct RemoteTransportRow: View {
    @Environment(RemoteSessionController.self) private var remote
    var body: some View {
        HStack(spacing: 28) {
            Button { remote.send(.skipPrevious) } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            .accessibilityLabel("Previous")
            .accessibilityIdentifier("remote-prev")
            Button { remote.send(.playPause) } label: {
                Image(systemName: remote.state?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            .accessibilityLabel(remote.state?.isPlaying == true ? "Pause" : "Play")
            .accessibilityIdentifier("remote-playpause")
            Button { remote.send(.skipNext) } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .accessibilityLabel("Next")
            .accessibilityIdentifier("remote-next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
    }
}

extension RemoteSessionController {
    /// The window's upcoming rows (after the current one), for the Up Next list.
    var upcomingRows: [RemoteRow] {
        guard let s = state else { return [] }
        let rows = s.rows
        let i = s.snapshot.index
        return i + 1 < rows.count ? Array(rows[(i + 1)...]) : []
    }

    var hostName: String? { peers.first(where: \.isHost)?.name }
}

#if !os(tvOS)
// ============================================================================
// MARK: - The Remote tab (iPhone / iPad / Mac / Vision Pro)
// ============================================================================

/// The Remote tab: start a SharePlay session (Listen Together / Backseat), see who's in it, and
/// drive the session — now playing, transport, scrubber, Up Next, and search-to-add.
struct RemoteView: View {
    @Environment(RemoteSessionController.self) private var remote
    @Environment(AppModel.self) private var app
    /// Multiplayer Mix over this session (nil in previews/tests).
    @Environment(MixSync.self) private var mixSync: MixSync?
    /// The mode whose share sheet (Messages / nearby) is up.
    @State private var shareMode: RemoteSessionMode?
    @State private var starting: RemoteSessionMode?
    @State private var query = ""
    @State private var results: [IndexSong] = []
    /// The scrubber's in-flight drag value (ms) — nil while not dragging.
    @State private var scrubMs: Double?

    var body: some View {
        List {
            if let msg = remote.statusMessage {
                Section { Label(msg, systemImage: "info.circle").foregroundStyle(Theme.fgDim) }
            }
            if remote.isActive {
                sessionSection
                mixTogetherSection
                participantsSection
                nowPlayingSection
                upNextSection
                addSection
            } else {
                startSection
            }
        }
        .navigationTitle("Remote")
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .accessibilityIdentifier("remote-view")
        #if canImport(GroupActivities)
        .sheet(item: $shareMode) { mode in
            RemoteShareSheet(mode: mode) { shareMode = nil }
        }
        #endif
        .task(id: query) { await runSearch() }
    }

    // MARK: Start

    @ViewBuilder private var startSection: some View {
        Section {
            startButton(.listenTogether, icon: "person.2.wave.2.fill",
                        blurb: "Everyone plays the same music in sync — anyone in the session can change it.")
            startButton(.backseat, icon: "car.fill",
                        blurb: "Your device becomes the remote. A passenger’s phone on the car stereo plays the music.")
        } header: {
            Text("Start SharePlay")
        } footer: {
            Text("Starts in your FaceTime call, or invite someone through Messages or by bringing devices together. Each device plays from its own library or Apple Music.")
        }
    }

    private func startButton(_ mode: RemoteSessionMode, icon: String, blurb: String) -> some View {
        Button { begin(mode) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.headline)
                    Text(blurb).font(.subheadline).foregroundStyle(Theme.fgDim)
                }
                Spacer(minLength: 0)
                if starting == mode { ProgressView() }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(starting != nil)
        .accessibilityIdentifier("remote-start-\(mode.rawValue)")
    }

    private func begin(_ mode: RemoteSessionMode) {
        #if canImport(GroupActivities)
        starting = mode
        remote.statusMessage = nil
        Task {
            let outcome = await remote.start(mode)
            starting = nil
            switch outcome {
            case .activated, .cancelled: break
            case .needsShareSheet: shareMode = mode
            case .failed(let msg): remote.statusMessage = "Couldn’t start SharePlay: \(msg)"
            }
        }
        #endif
    }

    // MARK: Session

    @ViewBuilder private var sessionSection: some View {
        Section {
            LabeledContent("Mode", value: remote.mode.title)
            LabeledContent("Host", value: remote.isHost ? "This device" : (remote.hostName ?? "Connecting…"))
            Picker("This device", selection: Binding(get: { remote.localRole },
                                                     set: { remote.setLocalRole($0) })) {
                Text("Speaker").tag(RemoteDeviceRole.speaker)
                Text("Remote control").tag(RemoteDeviceRole.controller)
            }
            .accessibilityIdentifier("remote-role")
            Button(role: .destructive) { remote.leave() } label: {
                Label("Leave Session", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("remote-leave")
        } header: {
            Text("Session")
        } footer: {
            Text(remote.localRole == .speaker ? "This device plays the session’s music."
                                              : "This device plays nothing — it controls the speakers.")
        }
    }

    // MARK: Mix together (multiplayer Mix — Phase 2)

    @ViewBuilder private var mixTogetherSection: some View {
        if let mixSync {
            Section {
                if mixSync.isActive {
                    LabeledContent("DJs", value: mixSync.participantNames.joined(separator: ", "))
                    LabeledContent("Your deck", value: mixSync.myDecks.isEmpty
                                   ? "None — claim a free deck in Mix"
                                   : mixSync.myDecks.map { "Deck \($0.rawValue)" }.joined(separator: " + "))
                    if remote.isHost {
                        Button(role: .destructive) { mixSync.end() } label: {
                            Label("End Mix Together", systemImage: "stop.circle")
                        }
                        .accessibilityIdentifier("remote-mix-end")
                    }
                } else {
                    Button { mixSync.start() } label: {
                        Label("Mix Together", systemImage: "slider.horizontal.2.square")
                    }
                    .disabled(!mixSync.canStart)
                    .accessibilityIdentifier("remote-mix-start")
                }
            } header: {
                Text("Mix Together")
            } footer: {
                Text(mixSync.startBlockedReason
                     ?? (mixSync.isActive
                         ? "Open the Mix tab. Every device plays both decks from its own library — you drive the deck you own; anyone can move the crossfader."
                         : "Two DJs, two decks: you take Deck A, the first person who joined takes Deck B. Each device plays the mix from its own library — no audio is sent between devices."))
            }
        }
    }

    @ViewBuilder private var participantsSection: some View {
        Section("Participants") {
            ForEach(remote.peers) { RemotePeerRow(peer: $0) }
        }
    }

    // MARK: Now playing

    @ViewBuilder private var nowPlayingSection: some View {
        Section("Now Playing") {
            if let cur = remote.state?.currentRow {
                HStack(spacing: 12) {
                    SongThumbnail(album: app.album(forSongId: cur.songId), studioId: cur.songId)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cur.title).font(.headline).lineLimit(2)
                        Text(cur.artist).font(.subheadline).foregroundStyle(Theme.fgDim).lineLimit(1)
                        unavailableNote(cur.rid)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("remote-now-playing")
                scrubber(lengthMs: cur.row.lengthMs)
                RemoteTransportRow()
                HStack {
                    Button { remote.send(.setRepeat((remote.state?.repeatMode ?? .off).next)) } label: {
                        Image(systemName: remote.state?.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(remote.state?.repeatMode == .off ? Theme.fgDim : Theme.accent)
                    }
                    .accessibilityLabel("Repeat")
                    Spacer()
                    Button { remote.send(.setShuffle(!(remote.state?.shuffleEnabled ?? false))) } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(remote.state?.shuffleEnabled == true ? Theme.accent : Theme.fgDim)
                    }
                    .accessibilityLabel("Shuffle")
                }
                .buttonStyle(.plain)
            } else {
                Text(remote.isHost ? "Nothing queued yet — add songs below."
                                   : "Waiting for the host…")
                    .foregroundStyle(Theme.fgDim)
            }
        }
    }

    @ViewBuilder private func scrubber(lengthMs: Int?) -> some View {
        let total = Double(max(lengthMs ?? 0, 1))
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let live = Double(remote.positionNow())
            let shown = min(scrubMs ?? live, total)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { shown }, set: { scrubMs = $0 }), in: 0...total) { editing in
                    if !editing, let ms = scrubMs {
                        remote.send(.seek(ms: Int(ms)))
                        scrubMs = nil
                    }
                }
                .disabled(lengthMs == nil)
                .accessibilityIdentifier("remote-scrubber")
                HStack {
                    Text(Self.clock(shown)); Spacer(); Text(lengthMs == nil ? "–:––" : Self.clock(total))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.fgDim)
            }
        }
    }

    static func clock(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder private func unavailableNote(_ rid: String) -> some View {
        let devices = remote.unavailableDevices(for: rid)
        if !devices.isEmpty {
            Label("Unavailable on \(devices.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Up next

    @ViewBuilder private var upNextSection: some View {
        let rows = remote.upcomingRows
        if !rows.isEmpty {
            Section("Up Next") {
                ForEach(rows, id: \.rid) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).lineLimit(1)
                        Text(row.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                        unavailableNote(row.rid)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button { remote.send(.jumpTo(rid: row.rid)) } label: { Label("Play Now", systemImage: "play") }
                        Button { remote.send(.move(rid: row.rid, toUpcomingOffset: 0)) } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button(role: .destructive) { remote.send(.remove(rid: row.rid)) } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets where i < rows.count { remote.send(.remove(rid: rows[i].rid)) }
                }
                .onMove { src, dest in
                    guard let s = src.first, s < rows.count else { return }
                    remote.send(.move(rid: rows[s].rid, toUpcomingOffset: dest > s ? dest - 1 : dest))
                }
            }
        }
    }

    // MARK: Add

    @ViewBuilder private var addSection: some View {
        Section("Add Songs") {
            TextField("Search your library", text: $query)
                .autocorrectionDisabled()
                .accessibilityIdentifier("remote-search")
            ForEach(results, id: \.id) { song in
                HStack(spacing: 10) {
                    SongThumbnail(album: app.album(forSongId: song.id), studioId: song.id)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.name).lineLimit(1)
                        Text(song.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Menu {
                        Button { add(song, .now) } label: { Label("Play Now", systemImage: "play") }
                        Button { add(song, .next) } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { add(song, .end) } label: {
                            Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                    } label: {
                        Image(systemName: "plus.circle").font(.title3).foregroundStyle(Theme.accent)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("remote-add-\(song.id)")
                }
            }
        }
    }

    private enum Placement { case now, next, end }

    private func add(_ song: IndexSong, _ placement: Placement) {
        let rows = remote.rows(for: [SetlistPlayer.Item(id: song.id, title: song.name,
                                                        artist: song.artist, lengthMs: song.length)])
        switch placement {
        case .now:  remote.send(remote.state?.currentRow == nil ? .play(rows: rows, startIndex: 0) : .playNow(rows: rows))
        case .next: remote.send(.enqueueNext(rows: rows))
        case .end:  remote.send(.append(rows: rows))
        }
    }

    /// Debounced library search (title / artist containment), off the main actor.
    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let songs = app.songs
        let hits = await Task.detached(priority: .userInitiated) {
            RemoteView.search(q, in: songs, cap: 25)
        }.value
        guard !Task.isCancelled else { return }
        results = hits
    }

    nonisolated static func search(_ q: String, in songs: [IndexSong], cap: Int) -> [IndexSong] {
        let needle = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out: [IndexSong] = []
        for s in songs {
            let hay = (s.name + " " + s.artist).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if hay.contains(needle) {
                out.append(s)
                if out.count >= cap { break }
            }
        }
        return out
    }
}

#if canImport(GroupActivities)
// MARK: - Share sheet (Messages / nearby) when there's no FaceTime call

#if os(macOS)
/// The system SharePlay invite UI (`GroupActivitySharingController`, AppKit flavour).
struct RemoteShareSheet: NSViewControllerRepresentable {
    let mode: RemoteSessionMode
    let done: () -> Void
    @Environment(RemoteSessionController.self) private var remote

    func makeNSViewController(context: Context) -> NSViewController {
        remote.pendingStartMode = mode
        guard let vc = try? GroupActivitySharingController(PocketDJSessionActivity(mode: mode)) else {
            // The invite UI couldn't be built: undo the pending start (else the NEXT peer session
            // would be treated as ours to host), close the sheet, and say why.
            let remote = remote
            Task { @MainActor in
                remote.pendingStartMode = nil
                remote.statusMessage = "Couldn’t open the SharePlay invite. Try again from a FaceTime call."
                done()
            }
            return NSViewController()
        }
        Task { @MainActor in
            let result = await vc.result
            if result != .success { remote.pendingStartMode = nil }
            done()
        }
        return vc
    }
    func updateNSViewController(_ vc: NSViewController, context: Context) {}
}
#else
/// The system SharePlay invite UI (`GroupActivitySharingController`, UIKit flavour).
struct RemoteShareSheet: UIViewControllerRepresentable {
    let mode: RemoteSessionMode
    let done: () -> Void
    @Environment(RemoteSessionController.self) private var remote

    func makeUIViewController(context: Context) -> UIViewController {
        remote.pendingStartMode = mode
        guard let vc = try? GroupActivitySharingController(PocketDJSessionActivity(mode: mode)) else {
            // The invite UI couldn't be built: undo the pending start (else the NEXT peer session
            // would be treated as ours to host), close the sheet, and say why.
            let remote = remote
            Task { @MainActor in
                remote.pendingStartMode = nil
                remote.statusMessage = "Couldn’t open the SharePlay invite. Try again from a FaceTime call."
                done()
            }
            return UIViewController()
        }
        Task { @MainActor in
            let result = await vc.result
            if result != .success { remote.pendingStartMode = nil }
            done()
        }
        return vc
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
#endif
#endif
#endif
