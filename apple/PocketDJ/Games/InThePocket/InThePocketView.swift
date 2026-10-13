import SwiftUI

/// Route value for the Games tab → In the Pocket push.
struct InThePocketRoute: Hashable {}

/// "In the Pocket": PocketDJ bets on 3–4 songs you'll play straight through — right now, here —
/// using what your listening pockets found. Every round is training data for them, and the
/// feedback field (type, or tap the mic and talk) says how the pocket felt.
///
/// Shared code only — no platform fence in this file. Dictation availability is the
/// controller's business (`FeedbackDictationController.isAvailable` is false on tvOS), so the
/// mic simply isn't shown there.
struct InThePocketView: View {
    @Environment(InThePocketStore.self) private var game
    @Environment(ListeningPocketsService.self) private var pockets: ListeningPocketsService?
    @Environment(GameScoreboardStore.self) private var scores

    @State private var dictation = FeedbackDictationController.system()
    @State private var draft = ""
    @State private var rating: Int?
    /// Which round `draft`/`rating` were loaded from — a new round reloads them.
    @State private var draftRoundId: UUID?

    var body: some View {
        Group {
            if let pockets, pockets.isEnabled {
                content(pockets)
            } else if let pockets {
                ListeningPocketsOptInView(
                    pockets: pockets, title: "Play In the Pocket?",
                    lead: "In the Pocket picks 3–4 songs it predicts you'll play straight through, right now, wherever you are. It needs listening pockets on — and every round you play teaches them.")
            } else {
                Text("In the Pocket isn't available.")
                    .foregroundStyle(Theme.fgDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(GameKind.inThePocket.label)
        .background(Theme.bg)
        .onDisappear {
            dictation.stop()
            saveFeedback()
        }
    }

    // MARK: - Main

    private func content(_ pockets: ListeningPocketsService) -> some View {
        List {
            Section { statsRow }
            if let round = game.current {
                Section { roundCard(round) }
                if round.startedAtMs != nil { Section("How does it feel?") { feedbackEditor(round) } }
            } else {
                Section { buildCard }
            }
            Section {
                Text("Rounds upload with your listening pockets as training data. Spoken feedback is transcribed on this device — the audio never leaves it; only the text you write or dictate is sent.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("itp-privacy-note")
            }
        }
        .scrollContentBackground(.hidden)
        .task {
            game.resumeTrackingIfNeeded()
            await pockets.refreshIfStale()
        }
        .onChange(of: game.currentRoundId, initial: true) { _, _ in loadDraft() }
        .accessibilityIdentifier("itp-screen")
    }

    private var statsRow: some View {
        let s = scores.inThePocketStats()
        return HStack(spacing: 0) {
            stat("\(s.rounds)", "rounds", id: "itp-stat-rounds")
            stat(s.pocketRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "in the pocket", id: "itp-stat-rate")
            stat("\(s.bestStreak)", "best streak", id: "itp-stat-streak")
        }
    }

    private func stat(_ value: String, _ label: String, id: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.fg)
            Text(label).font(.caption2).foregroundStyle(Theme.fgDim)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private var buildCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PocketDJ reads the time, the day and — if places & trips is on — where you are, then bets on songs you'll play straight through. Skip one and the pocket breaks. Pausing is fine.")
                .font(.subheadline).foregroundStyle(Theme.fgDim)
            if case .failed(let msg) = game.buildState {
                Text(msg).font(.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("itp-build-error")
            }
            Button {
                Task { await game.buildRound() }
            } label: {
                HStack {
                    if game.buildState == .building { ProgressView() }
                    Text(game.buildState == .building ? "Finding your pocket…" : "Build a round")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(game.buildState == .building)
            .accessibilityIdentifier("itp-build")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Round

    @ViewBuilder private func roundCard(_ round: InThePocketRound) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            chips(game.chips(for: round))
            Text(Self.modeNote(round.mode))
                .font(.caption).foregroundStyle(Theme.fgDim)
                .accessibilityIdentifier("itp-mode-\(round.mode.rawValue)")
            dots(round)
            ForEach(Array(round.songs.enumerated()), id: \.offset) { i, song in
                songRow(song, index: i, isCurrent: game.currentSongIndex == i && round.isActive)
            }
            outcomeBanner(round)
            controls(round)
        }
        .padding(.vertical, 4)
    }

    static func modeNote(_ mode: InThePocketMode) -> String {
        switch mode {
        case .cloud: return "Built from your listening pockets for this moment."
        case .history: return "No pocket results for this moment yet — built from what you've played through at this time of day."
        case .cold: return "No pocket results yet — built from everything you've played through. Play more and the bets get sharper."
        }
    }

    private func chips(_ items: [String]) -> some View {
        Text(items.joined(separator: " · "))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.accent2)
            .accessibilityIdentifier("itp-chips")
    }

    /// One dot per song: hollow = to come, half = playing, filled = played through, ✕ = skipped.
    private func dots(_ round: InThePocketRound) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(round.songs.enumerated()), id: \.offset) { _, s in
                ZStack {
                    Circle().stroke(Theme.border, lineWidth: 2)
                    switch s.state {
                    case .completed: Circle().fill(Theme.accent)
                    case .playing: Circle().trim(from: 0, to: 0.5).fill(Theme.accent.opacity(0.7)).rotationEffect(.degrees(90))
                    case .skipped: Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.danger)
                    case .notPlayed: Circle().fill(Theme.border.opacity(0.4))
                    case .pending: EmptyView()
                    }
                }
                .frame(width: 22, height: 22)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.progressLabel(round))
        .accessibilityIdentifier("itp-dots")
    }

    static func progressLabel(_ round: InThePocketRound) -> String {
        let done = round.songs.filter { $0.state == .completed }.count
        return "\(done) of \(round.songs.count) songs played through"
    }

    private func songRow(_ song: InThePocketSong, index: Int, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.fgDim).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.body.weight(isCurrent ? .semibold : .regular)).foregroundStyle(Theme.fg).lineLimit(1)
                Text(song.artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
                if !song.why.isEmpty {
                    Text(song.why.prefix(3).joined(separator: " · ")).font(.caption2).foregroundStyle(Theme.fgDim).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: Self.stateSymbol(song.state))
                .foregroundStyle(song.state == .skipped ? Theme.danger : song.state == .completed ? Theme.accent : Theme.fgDim)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("itp-song-\(index)")
    }

    static func stateSymbol(_ s: InThePocketSongState) -> String {
        switch s {
        case .pending: return "circle"
        case .playing: return "waveform"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "forward.end.fill"
        case .notPlayed: return "minus.circle"
        }
    }

    @ViewBuilder private func outcomeBanner(_ round: InThePocketRound) -> some View {
        if let outcome = round.outcome {
            Text(Self.outcomeText(outcome))
                .font(.headline)
                .foregroundStyle(outcome == .pocket ? Theme.accent2 : Theme.fg)
                .accessibilityIdentifier("itp-outcome")
        } else if round.isActive {
            Text("Play straight through — skipping breaks the pocket. Pausing doesn't.")
                .font(.caption).foregroundStyle(Theme.fgDim)
        }
    }

    static func outcomeText(_ o: InThePocketOutcome) -> String {
        switch o {
        case .pocket: return "In the pocket!"
        case .broke(let n): return "Broke at song \(n)"
        case .abandoned: return "Round ended early"
        }
    }

    @ViewBuilder private func controls(_ round: InThePocketRound) -> some View {
        HStack(spacing: 12) {
            if round.startedAtMs == nil {
                Button("Start") { game.start() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("itp-start")
                Button("Different songs") { Task { await game.buildRound() } }
                    .buttonStyle(.bordered)
                    .disabled(game.buildState == .building)
                    .accessibilityIdentifier("itp-reroll")
            } else if round.isActive {
                Button("End round", role: .destructive) { game.endActiveRound() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("itp-end")
            } else {
                Button("New round") {
                    saveFeedback()
                    game.dismissCurrent()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("itp-new")
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feedback

    private func feedbackEditor(_ round: InThePocketRound) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        rating = rating == n ? nil : n
                        saveFeedback()
                    } label: {
                        Image(systemName: (rating ?? 0) >= n ? "star.fill" : "star")
                            .foregroundStyle((rating ?? 0) >= n ? Theme.accent2 : Theme.fgDim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
                    .accessibilityIdentifier("itp-rating-\(n)")
                }
                Text("optional").font(.caption2).foregroundStyle(Theme.fgDim).padding(.leading, 6)
            }
            HStack(alignment: .top, spacing: 8) {
                TextField("How does this pocket feel? Is the algorithm getting you?", text: $draft, axis: .vertical)
                    .lineLimit(3...8)
                    .onChange(of: draft) { _, new in
                        // Hard cap while typing/dictating — the stored + uploaded text never exceeds it.
                        if let capped = InThePocketRound.capFeedback(new), capped.utf16.count < new.utf16.count,
                           new.utf16.count > InThePocketRound.maxFeedbackChars {
                            draft = capped
                        }
                    }
                    .accessibilityIdentifier("itp-feedback")
                if dictation.isAvailable {
                    Button {
                        Task { await dictation.toggle(current: draft) { draft = $0 } }
                    } label: {
                        Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                            .font(.title3)
                            .foregroundStyle(dictation.isListening ? Theme.danger : Theme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(dictation.state == .denied || dictation.state == .unavailable)
                    .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate feedback")
                    .accessibilityIdentifier("itp-mic")
                }
            }
            if let why = dictation.explanation {
                Text(why).font(.caption).foregroundStyle(Theme.fgDim)
                    .accessibilityIdentifier("itp-mic-explanation")
            }
            HStack {
                Text("\(draft.utf16.count)/\(InThePocketRound.maxFeedbackChars)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                Spacer()
                Button(feedbackSaved(round) ? "Saved" : "Save") {
                    dictation.stop()
                    saveFeedback()
                }
                .buttonStyle(.borderless)
                .disabled(feedbackSaved(round))
                .accessibilityIdentifier("itp-feedback-save")
            }
        }
    }

    private func feedbackSaved(_ round: InThePocketRound) -> Bool {
        InThePocketRound.capFeedback(draft) == round.feedback && rating == round.rating
    }

    private func loadDraft() {
        guard draftRoundId != game.currentRoundId else { return }
        dictation.stop()
        draftRoundId = game.currentRoundId
        draft = game.current?.feedback ?? ""
        rating = game.current?.rating
    }

    private func saveFeedback() {
        guard let id = draftRoundId, game.rounds.contains(where: { $0.id == id }) else { return }
        game.saveFeedback(roundId: id, text: draft, rating: rating)
    }
}
