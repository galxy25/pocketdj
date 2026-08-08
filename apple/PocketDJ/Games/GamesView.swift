import SwiftUI

/// The Games tab home: the Collectors Puzzle card, the Music with Friends card (+ live
/// session rows and the New/Join sheets), and the scoreboard. Pure List — collapses on
/// iPhone, two-column detail elsewhere; no platform fences needed.
struct GamesView: View {
    @Binding var path: NavigationPath
    @Environment(GameScoreboardStore.self) private var gameScores
    @Environment(MusicWithFriendsStore.self) private var friends
    @Environment(CollectorsPuzzleEngine.self) private var puzzle
    @Environment(SettingsStore.self) private var settings
    @Environment(ProfileStore.self) private var profile

    @State private var showCreateSheet = false
    @State private var showJoinSheet = false

    var body: some View {
        List {
            Section {
                puzzleCard
            }
            Section {
                friendsCard
                ForEach(friends.sessions) { entry in
                    NavigationLink(value: MwFSessionRoute(sessionId: entry.id)) {
                        sessionRow(entry)
                    }
                    .accessibilityIdentifier("mwf-session-\(entry.id)")
                }
                HStack(spacing: 12) {
                    Button("New Session") { showCreateSheet = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mwf-new")
                    Button("Join Session") { showJoinSheet = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("mwf-join")
                }
                .buttonStyle(.plain)
            }
            scoreboardSection
        }
        .navigationTitle("Games")
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .sheet(isPresented: $showCreateSheet) { MwFCreateSheet() }
        .sheet(isPresented: $showJoinSheet) { MwFJoinSheet(link: nil) }
        // A tapped link for an UNKNOWN session drives the Join sheet from anywhere.
        .sheet(isPresented: Binding(get: { friends.pendingJoin != nil },
                                    set: { if !$0 { friends.pendingJoin = nil } })) {
            MwFJoinSheet(link: friends.pendingJoin)
        }
    }

    // MARK: - Cards

    private var puzzleCard: some View {
        Button {
            path.append(CollectorsPuzzleRoute())
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "diamond.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent2)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(GameKind.collectorsPuzzle.label).font(.headline).foregroundStyle(Theme.fg)
                        if puzzleInProgress {
                            Text("Round in progress")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accent2.opacity(0.2), in: Capsule())
                                .foregroundStyle(Theme.accent2)
                        }
                    }
                    Text("Timed rush — file songs into any collection. One point per song.")
                        .font(.subheadline).foregroundStyle(Theme.fgDim)
                    Text("Best: \(gameScores.bestScore(.collectorsPuzzle) ?? 0)")
                        .font(.caption).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("games-best-collectorsPuzzle")
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.fgDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("games-card-puzzle")
    }

    private var puzzleInProgress: Bool {
        switch puzzle.phase {
        case .running, .countdown, .sampling: return true
        default: return false
        }
    }

    private var friendsCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Music with Friends").font(.headline).foregroundStyle(Theme.fg)
                Text("Turn-based suggestions with friends. Points for accepted songs.")
                    .font(.subheadline).foregroundStyle(Theme.fgDim)
                Text("Best: \(gameScores.bestScore(.musicWithFriends) ?? 0)")
                    .font(.caption).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("games-best-musicWithFriends")
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("games-card-friends")
    }

    private func sessionRow(_ entry: MwFSessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if entry.isLeader {
                    Image(systemName: "crown.fill").font(.caption).foregroundStyle(Theme.accent2)
                }
                Text(entry.name ?? "Music with Friends").font(.body).foregroundStyle(Theme.fg)
            }
            if let theme = entry.theme, !theme.isEmpty {
                Text(theme).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
            HStack(spacing: 8) {
                if let expires = entry.expiresAt {
                    Text(Self.expiresLabel(expires)).font(.caption2).foregroundStyle(Theme.fgDim)
                }
                if let st = friends.lastState[entry.id] {
                    Text("your score: \(friends.myScore(st))")
                        .font(.caption2).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    static func expiresLabel(_ expiresAtMs: Double, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let remaining = expiresAtMs - nowMs
        guard remaining > 0 else { return "ended" }
        let mins = Int(remaining / 60000)
        return mins >= 60 ? "ends in \(mins / 60)h \(mins % 60)m" : "ends in \(mins)m"
    }

    // MARK: - Scoreboard

    private var scoreboardSection: some View {
        Section("Scoreboard") {
            if gameScores.runs.isEmpty {
                Text("No runs yet — play a game!")
                    .font(.subheadline).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("games-scoreboard-empty")
            } else {
                ForEach(GameKind.allCases, id: \.rawValue) { game in
                    if let best = gameScores.bestRun(game) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                            HStack(spacing: 6) {
                                Text("Best \(best.score)").font(.caption).foregroundStyle(Theme.accent2)
                                Text(Self.dateLabel(best.at)).font(.caption).foregroundStyle(Theme.fgDim)
                                if let s = best.settingsSummary {
                                    Text(s).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                                }
                            }
                        }
                        ForEach(Array(gameScores.recentRuns(game, limit: 5).enumerated()), id: \.element.id) { i, run in
                            HStack {
                                Text("★ \(run.score)").font(.caption.monospacedDigit()).foregroundStyle(Theme.fg)
                                Text(Self.dateLabel(run.at)).font(.caption).foregroundStyle(Theme.fgDim)
                                Spacer()
                                if let s = run.settingsSummary {
                                    Text(s).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("games-run-\(game.rawValue)-\(i)")
                        }
                    }
                }
            }
        }
    }

    static func dateLabel(_ atMs: Double) -> String {
        Date(timeIntervalSince1970: atMs / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}
