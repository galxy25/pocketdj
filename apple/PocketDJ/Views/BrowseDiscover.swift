import SwiftUI
import Observation

/// Debounced driver for Browse ▸ Discover. Kept out of BrowseView (and BrowseState)
/// so the on-device filter/sort pipeline stays untouched — this owns only the query
/// debounce + the current hit list. The network call itself lives on RipsStore
/// (`discoverSearch`), which owns the rip-server config + error surface.
@MainActor
@Observable
final class DiscoverSearchModel {
    enum State: Equatable { case idle, loading, loaded }

    var state: State = .idle
    private(set) var hits: [RipsStore.DiscoverHit] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    /// ~400 ms debounce so a burst of keystrokes coalesces into one server round-trip
    /// (the on-device recompute's `.task(id:)` debounce doesn't run in discover mode).
    /// Re-triggering cancels the pending run; an all-empty query clears to idle.
    /// `artist` is the Discover tab's refine field: it WIDENS the server term (iTunes
    /// term search matches across fields) and NARROWS the hit list client-side.
    func searchDebounced(_ query: String, artist: String = "", rips: RipsStore) {
        task?.cancel()
        guard let term = Self.term(title: query, artist: artist) else {
            hits = []; state = .idle; return
        }
        let refine = artist.trimmingCharacters(in: .whitespaces)
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.state = .loading
            let results = await rips.discoverSearch(term)
            guard !Task.isCancelled else { return }
            self.hits = Self.refine(results, artist: refine)
            self.state = .loaded
        }
    }

    /// The server search term: title + artist joined (either alone works — an
    /// artist-only search is a valid way in). nil ⇒ nothing to search.
    static func term(title: String, artist: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        let a = artist.trimmingCharacters(in: .whitespaces)
        let joined = [t, a].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Client-side artist narrowing — iTunes term search matches across fields, so a
    /// refine like "daft" must still drop hits whose artist doesn't carry it.
    static func refine(_ hits: [RipsStore.DiscoverHit], artist: String) -> [RipsStore.DiscoverHit] {
        let a = artist.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return hits }
        return hits.filter { $0.artist.localizedCaseInsensitiveContains(a) }
    }

    func cancel() { task?.cancel(); task = nil; hits = []; state = .idle }
}

/// Browse ▸ Discover — search the ENTIRE Apple Music catalog through the rip server's
/// `/search` proxy. "＋ Add" asks the iMac to capture the song (the ad-hoc `amrec_`
/// rip path); once ripped it lands in the PUBLIC rips manifest, streamable/burnable
/// by every user, and the row flips to a ▶ wired to the standard rip-play path.
struct DiscoverResultsList: View {
    @Environment(RipsStore.self) private var rips
    let model: DiscoverSearchModel
    let query: String
    var artist: String = ""

    var body: some View {
        Group {
            if DiscoverSearchModel.term(title: query, artist: artist) == nil {
                hint
            } else {
                switch model.state {
                case .idle, .loading: loading
                case .loaded:
                    if let message = rips.discoverError {
                        failure(message)
                    } else if model.hits.isEmpty {
                        noMatches
                    } else {
                        list
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var hint: some View {
        ContentUnavailableView {
            Label("Discover Apple Music", systemImage: "sparkle.magnifyingglass")
        } description: {
            Text("Search Apple Music — added songs are ripped to the shared catalog.")
        }
        .accessibilityIdentifier("discover-hint")
    }

    private var loading: some View {
        VStack(spacing: 12) { ProgressView(); Text("Searching Apple Music…").foregroundStyle(Theme.fgDim) }
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Label("No matches", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing in the Apple Music catalog matched “\(query)”.")
        }
        .accessibilityIdentifier("discover-empty")
    }

    /// Server unreachable / bad token — `discoverError` strings already name the
    /// Settings ▸ Rip server field to fix.
    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Discover unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        }
        .accessibilityIdentifier("discover-error")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Index-keyed a11y ids (`discover-row-<i>`), identity by songId.
                ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                    DiscoverRow(hit: hit, index: index)
                    // Same inline player the browser song rows get — a playing
                    // discover hit shows the standard transport under its row.
                    InlinePlayerSlot(songId: hit.songId).padding(.horizontal, 2)
                    Divider().overlay(Theme.border)
                }
            }
            .padding(.horizontal, 8)
        }
        .accessibilityIdentifier("discover-list")
    }
}

/// One Discover result row: artwork · title / artist · album · duration · trailing
/// action. The trailing action is state-driven per songId: ripped → ▶ (standard play
/// path) · rip job in flight → spinner + phase · else → ＋ Add.
private struct DiscoverRow: View {
    @Environment(RipsStore.self) private var rips
    @Environment(PlayerEngine.self) private var player
    let hit: RipsStore.DiscoverHit
    let index: Int

    /// Ripped = the server said so at search time OR the manifest has flipped since
    /// (the add-completion `refreshManifest` is what moves a row here live).
    private var ripped: Bool { hit.ripped == true || rips.manifest[hit.songId] != nil }
    private var phase: RipsStore.Phase? { rips.jobs[hit.songId]?.phase }

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.callout.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            Spacer()
            if let ms = hit.durationMs, ms > 0 {
                Text(Self.mmss(ms)).font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim)
            }
            trailing
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        // `.contain` keeps the row a container so the nested play/add buttons keep
        // their own ids under the row id (the browser SongRow lesson).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover-row-\(index)")
    }

    private var subtitle: String {
        [hit.artist, hit.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var artwork: some View {
        AsyncImage(url: hit.artworkUrl.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 6).fill(Theme.border)
                .overlay(Image(systemName: "music.note").foregroundStyle(Theme.fgDim))
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Non-terminal rip phases → the working spinner (mirrors RipsStore.inFlightPhases).
    private static let working: Set<RipsStore.Phase> = [.queued, .searching, .ripping, .streaming, .uploading]

    @ViewBuilder private var trailing: some View {
        if ripped {
            Button { play() } label: {
                Image(systemName: rips.nowPlaying?.songId == hit.songId
                      ? "waveform.circle.fill" : "play.circle.fill")
                    .font(.title3).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("discover-play-\(index)")
            .help("In the shared catalog — play")
        } else if let phase, Self.working.contains(phase) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(Self.phaseLabel(phase)).font(.caption).foregroundStyle(Theme.fgDim)
            }
            .accessibilityIdentifier("discover-progress-\(index)")
        } else {
            Button { let h = hit; Task { await rips.discoverAdd(h) } } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("discover-add-\(index)")
            .help("Rip this song into the shared catalog")
        }
    }

    /// Standard single-song play: RipsStore resolves the manifest mp3 (a ripped
    /// discover hit is always cached, so this never falls into a live rip) and the
    /// caller owns the one-and-only `player.load` — the InlinePlayerSlot contract.
    private func play() {
        if rips.nowPlaying?.songId == hit.songId { player.toggle(); return }
        let song = (id: hit.songId, title: hit.title, artist: hit.artist)
        Task {
            if let now = try? await rips.play(song) {
                player.load(url: now.url, live: now.live, startMs: now.startMs,
                            title: now.title, artist: now.artist, songId: now.songId)
            }
        }
    }

    private static func phaseLabel(_ p: RipsStore.Phase) -> String {
        switch p {
        case .queued:              return "Queued"
        case .searching:           return "Searching…"
        case .ripping, .streaming: return "Ripping…"
        case .uploading:           return "Uploading…"
        case .ready, .error:       return ""
        }
    }

    private static func mmss(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
