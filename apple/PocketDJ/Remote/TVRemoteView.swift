#if os(tvOS)
import SwiftUI

/// The Apple TV's Remote tab. The TV never STARTS a session (no share UI on tvOS) — it joins
/// one a FaceTime / SharePlay peer offers (`startObservingGroupSessions` runs app-wide) and plays as a
/// speaker. This tab shows the session, who's in it, and the session's transport.
struct TVRemoteView: View {
    @Environment(RemoteSessionController.self) private var remote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if remote.isActive {
                    activeBody
                } else {
                    idleBody
                }
            }
            .padding(60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    @ViewBuilder private var idleBody: some View {
        Label("No SharePlay session", systemImage: "shareplay").font(.title2.bold())
        Text("""
        To play a PocketDJ session on this TV, open the Remote tab in PocketDJ on your iPhone or iPad \
        during a FaceTime call with this Apple TV and choose Listen Together, or start SharePlay \
        from the call's controls. The TV joins automatically and plays the music in sync.
        """)
        .foregroundStyle(Theme.fgDim)
        // A TV tab must always offer something focusable (scrolling needs a focus target).
        Button("Refresh") {}
            .accessibilityIdentifier("tv-remote-refresh")
    }

    @ViewBuilder private var activeBody: some View {
        Label("\(remote.mode.title) — \(remote.isHost ? "hosting" : "joined")", systemImage: "shareplay")
            .font(.title2.bold())
        if let cur = remote.state?.currentRow {
            VStack(alignment: .leading, spacing: 6) {
                Text(cur.title).font(.title3.bold())
                Text(cur.artist).foregroundStyle(Theme.fgDim)
            }
        } else {
            Text("Waiting for the host…").foregroundStyle(Theme.fgDim)
        }
        HStack(spacing: 40) {
            Button { remote.send(.skipPrevious) } label: { Image(systemName: "backward.fill") }
            Button { remote.send(.playPause) } label: {
                Image(systemName: remote.state?.isPlaying == true ? "pause.fill" : "play.fill")
            }
            Button { remote.send(.skipNext) } label: { Image(systemName: "forward.fill") }
        }
        VStack(alignment: .leading, spacing: 14) {
            Text("Participants").font(.headline)
            ForEach(remote.peers) { RemotePeerRow(peer: $0) }
        }
        HStack(spacing: 30) {
            Button(remote.localRole == .speaker ? "Stop playing here" : "Play here") {
                remote.setLocalRole(remote.localRole == .speaker ? .controller : .speaker)
            }
            Button("Leave Session", role: .destructive) { remote.leave() }
        }
    }
}
#endif
