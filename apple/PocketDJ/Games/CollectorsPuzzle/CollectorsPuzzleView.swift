import SwiftUI

/// Route value for the Games tab → Collectors Puzzle push.
struct CollectorsPuzzleRoute: Hashable {}

/// The Collectors Puzzle screen — one view switching on the engine's phase:
/// setup (filters/weights/targets) → countdown → running (timer/score/assign) → summary.
struct CollectorsPuzzleView: View {
    @Binding var path: NavigationPath
    @Environment(CollectorsPuzzleEngine.self) private var puzzle
    @Environment(CollectionsStore.self) private var collections
    @Environment(GameScoreboardStore.self) private var gameScores
    @Environment(SetlistPlayer.self) private var sequencer
    @Environment(\.dismiss) private var dismiss

    /// Editable working copy — pushed to the engine (persisted) on every change.
    @State private var draft = PuzzleSettings()
    @State private var draftLoaded = false
    @State private var poolCount: Int?
    @State private var countTask: Task<Void, Never>?
    @State private var showReplaceConfirm = false
    @State private var showNewPocket = false
    @State private var newPocketName = ""

    var body: some View {
        Group {
            switch puzzle.phase {
            case .idle:
                setupForm
            case .sampling:
                ProgressView("Sampling…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .countdown(let n):
                countdownView(n)
            case .running:
                runningView
            case .finished:
                summaryView
            }
        }
        .navigationTitle("Collectors Puzzle")
        .background(Theme.bg)
        .task {
            guard !draftLoaded else { return }
            draft = puzzle.settings
            draftLoaded = true
            recount()
        }
        .onChange(of: draft) { _, newValue in
            guard draftLoaded else { return }
            puzzle.updateSettings(newValue)
            recount()
        }
    }

    /// Debounced, single-flight "N songs match" refresh (year keystrokes must not
    /// pile detached samples up).
    private func recount() {
        countTask?.cancel()
        countTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let n = await puzzle.poolCount()
            guard !Task.isCancelled else { return }
            poolCount = n
        }
    }

    // MARK: - Setup

    private var setupForm: some View {
        Form {
            Section {
                Text("Best: \(gameScores.bestScore(.collectorsPuzzle) ?? 0)")
                    .font(.subheadline).foregroundStyle(Theme.accent2)
            }
            Section("Round") {
                Picker("Length", selection: $draft.roundSeconds) {
                    Text("1:00").tag(60)
                    Text("2:00").tag(120)
                    Text("3:00").tag(180)
                    Text("5:00").tag(300)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("puzzle-round-length")
            }
            Section("Weighting") {
                Picker("Play count", selection: $draft.playCountBias) {
                    Text("Off").tag(PuzzleSettings.Bias.off)
                    Text("Most played").tag(PuzzleSettings.Bias.favor)
                    Text("Least played").tag(PuzzleSettings.Bias.avoid)
                }
                .accessibilityIdentifier("puzzle-playcount-bias")
                Picker("Favorites", selection: $draft.favoriteBias) {
                    Text("Off").tag(PuzzleSettings.Bias.off)
                    Text("Favorites").tag(PuzzleSettings.Bias.favor)
                    Text("Non-favorites").tag(PuzzleSettings.Bias.avoid)
                }
                .accessibilityIdentifier("puzzle-favorite-bias")
            }
            Section("Filters") {
                NavigationLink {
                    genrePicker
                } label: {
                    HStack {
                        Text("Genres")
                        Spacer()
                        Text(draft.genreCategories.isEmpty ? "All genres" : "\(draft.genreCategories.count)")
                            .foregroundStyle(Theme.fgDim)
                    }
                }
                .accessibilityIdentifier("puzzle-genres")
                yearRow(label: "Year from", value: $draft.yearMin, a11y: "puzzle-year-min")
                yearRow(label: "Year to", value: $draft.yearMax, a11y: "puzzle-year-max")
                Picker("Collection filter", selection: $draft.membershipMode) {
                    Text("Off").tag(PuzzleSettings.MembershipMode.off)
                    Text("In").tag(PuzzleSettings.MembershipMode.inAny)
                    Text("Not in").tag(PuzzleSettings.MembershipMode.notInAny)
                }
                .accessibilityIdentifier("puzzle-membership-mode")
                if draft.membershipMode != .off {
                    membershipList
                }
            }
            Section("Targets (1–3)") {
                targetList
                Button("New Pocket…") { showNewPocket = true }
                    .accessibilityIdentifier("puzzle-new-pocket")
            }
        }
        // macOS `Form` defaults to `FormStyle.columns`, a two-column grid whose CONTENT
        // column is sized to the widest row content. Every membership/target/genre row here
        // is `HStack { Text … Spacer() … }`, and a `Spacer`'s ideal width is unbounded — so
        // the content column grew past the window and shoved the whole grid off the right
        // edge (only the tail of the label column stayed visible: the reported "collections
        // jammed to the right, nothing else usable"). `.grouped` is the full-width,
        // System-Settings-style form layout on macOS and the platform default look on iOS,
        // so ONE style pins every platform to the layout this screen was designed for.
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // The primary action is PINNED, never a row at the bottom of the scroll. As a Form
        // row it sat below every target collection, so it left the screen entirely once the
        // user had more than a couple of playlists/pockets — "I can select my settings but
        // never am able to start the game". A safe-area inset keeps it on screen at every
        // window size, on every platform, regardless of how long the lists get.
        .safeAreaInset(edge: .bottom) { startBar }
        .alert("Start round?", isPresented: $showReplaceConfirm) {
            Button("Start", role: .destructive) { Task { await puzzle.startRound() } }
                .accessibilityIdentifier("puzzle-confirm-replace")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces your current queue.")
        }
        .alert("New Pocket", isPresented: $showNewPocket) {
            TextField("Name", text: $newPocketName)
            Button("Create") {
                let name = newPocketName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let pocket = collections.createPocket(name, songIds: [], description: nil)
                if draft.targetCollectionIds.count < 3 {
                    draft.targetCollectionIds.append(pocket.id)
                }
                newPocketName = ""
            }
            Button("Cancel", role: .cancel) { newPocketName = "" }
        }
    }

    /// The pinned bottom bar: match count, the last sampler error, and Start. Lives OUTSIDE
    /// the scrolling Form (see `.safeAreaInset` above) so it is reachable with zero scrolling
    /// no matter how many collections the user has.
    private var startBar: some View {
        VStack(spacing: 6) {
            if let err = puzzle.lastError {
                Text(err).font(.footnote).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("puzzle-error")
            }
            // Wide windows put the count beside the button; narrow ones stack it above, so
            // the button never gets squeezed below its tap target (no os fences).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { poolCountLabel; Spacer(minLength: 12); startButton }
                VStack(spacing: 8) { poolCountLabel; startButton }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var poolCountLabel: some View {
        Text("\(poolCount.map(String.init) ?? "…") songs match")
            .font(.footnote).foregroundStyle(Theme.fgDim)
            .accessibilityIdentifier("puzzle-pool-count")
    }

    private var startButton: some View {
        Button("Start Round") {
            if sequencer.isRunning {
                showReplaceConfirm = true
            } else {
                Task { await puzzle.startRound() }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(draft.targetCollectionIds.isEmpty || poolCount == 0)
        .accessibilityIdentifier("puzzle-start")
    }

    private func yearRow(label: String, value: Binding<Int?>, a11y: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("Any", text: Binding(
                get: { value.wrappedValue.map(String.init) ?? "" },
                set: { value.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)) }))
                .frame(width: 76)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .accessibilityIdentifier(a11y)
            if value.wrappedValue != nil {
                Button { value.wrappedValue = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.fgDim)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var genrePicker: some View {
        List {
            ForEach(Genre.categoryNames, id: \.self) { name in
                Button {
                    if draft.genreCategories.contains(name) {
                        draft.genreCategories.remove(name)
                    } else {
                        draft.genreCategories.insert(name)
                    }
                } label: {
                    HStack {
                        Text(name).foregroundStyle(Theme.fg)
                        Spacer()
                        if draft.genreCategories.contains(name) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("puzzle-genre-\(name)")
            }
        }
        .navigationTitle("Genres")
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    /// All playlists + pockets the membership filter can reference.
    private var allCollections: [(id: String, name: String)] {
        collections.pockets.map { ($0.id, $0.name) } + collections.playlists.map { ($0.id, $0.name) }
    }

    private var membershipList: some View {
        ForEach(allCollections, id: \.id) { c in
            Button {
                if draft.membershipCollectionIds.contains(c.id) {
                    draft.membershipCollectionIds.remove(c.id)
                } else {
                    draft.membershipCollectionIds.insert(c.id)
                }
            } label: {
                HStack {
                    Text(c.name).foregroundStyle(Theme.fg)
                    Spacer()
                    if draft.membershipCollectionIds.contains(c.id) {
                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("puzzle-membership-\(c.id)")
        }
        .accessibilityIdentifier("puzzle-membership-list")
    }

    private var targetList: some View {
        ForEach(allCollections, id: \.id) { c in
            Button {
                if let i = draft.targetCollectionIds.firstIndex(of: c.id) {
                    draft.targetCollectionIds.remove(at: i)
                } else if draft.targetCollectionIds.count < 3 {
                    draft.targetCollectionIds.append(c.id)
                }
            } label: {
                HStack {
                    Text(c.name).foregroundStyle(Theme.fg)
                    Spacer()
                    if draft.targetCollectionIds.contains(c.id) {
                        Image(systemName: "checkmark").foregroundStyle(Theme.accent2)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("puzzle-target-\(c.id)")
        }
    }

    // MARK: - Countdown

    private func countdownView(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 120, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.accent2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("puzzle-countdown")
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: 18) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let remaining = puzzle.remainingSeconds
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .font(.system(size: 44, weight: .semibold).monospacedDigit())
                    .foregroundStyle(remaining < 10 ? Theme.danger : Theme.fg)
                    .accessibilityIdentifier("puzzle-timer")
            }
            Text("★ \(puzzle.score)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Theme.bgRaised, in: Capsule())
                .foregroundStyle(Theme.accent2)
                .accessibilityIdentifier("puzzle-score")

            if let song = puzzle.current {
                currentCard(song)
            } else if puzzle.poolExhausted {
                VStack(spacing: 8) {
                    Text("Catalog exhausted!").font(.title3).foregroundStyle(Theme.accent2)
                    Text("Every matching song has been shown.").font(.footnote).foregroundStyle(Theme.fgDim)
                }
            } else {
                ProgressView()
            }

            assignButtons
                .disabled(puzzle.current == nil)

            HStack(spacing: 16) {
                Button("Skip") { puzzle.skip() }
                    .buttonStyle(.bordered)
                    .disabled(puzzle.current == nil)
                    .accessibilityIdentifier("puzzle-skip")
                Button("End Round", role: .destructive) { puzzle.endRound() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("puzzle-end")
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func currentCard(_ song: IndexSong) -> some View {
        VStack(spacing: 6) {
            Text(song.name).font(.title2.weight(.semibold)).foregroundStyle(Theme.fg)
                .multilineTextAlignment(.center)
            Text(song.artist).font(.headline).foregroundStyle(Theme.fgDim)
            HStack(spacing: 8) {
                if let year = song.year {
                    Text(String(year)).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.bgOverlay, in: Capsule())
                        .foregroundStyle(Theme.fgDim)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("puzzle-current")
    }

    /// 1–3 big assign buttons: full-width stack where narrow, one row where wide
    /// (`ViewThatFits` — no os fences).
    private var assignButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { assignButtonList }
            VStack(spacing: 10) { assignButtonList }
        }
    }

    private var assignButtonList: some View {
        ForEach(Array(puzzle.settings.targetCollectionIds.enumerated()), id: \.offset) { i, cid in
            Button {
                puzzle.assign(toTargetIndex: i)
            } label: {
                Text(puzzle.collectionName(cid))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("puzzle-assign-\(i)")
        }
    }

    // MARK: - Summary

    private var summaryView: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Text("★ \(puzzle.score)")
                        .font(.system(size: 56, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.accent2)
                        .accessibilityIdentifier("puzzle-summary-score")
                    if puzzle.isNewHighScore {
                        Text("New high score! 🏆").font(.headline).foregroundStyle(Theme.accent2)
                    }
                    Text("Best: \(gameScores.bestScore(.collectorsPuzzle) ?? puzzle.score)")
                        .font(.subheadline).foregroundStyle(Theme.fgDim)
                }
                .frame(maxWidth: .infinity)
            }
            if !puzzle.assignedThisRound.isEmpty {
                Section("Filed this round") {
                    ForEach(Array(puzzle.assignedThisRound.enumerated()), id: \.offset) { _, row in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(.subheadline).foregroundStyle(Theme.fg)
                                Text(row.artist).font(.caption).foregroundStyle(Theme.fgDim)
                            }
                            Spacer()
                            Text("→ \(row.collectionName)").font(.caption).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            Section {
                Button("Play Again") { puzzle.reset() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("puzzle-again")
                Button("Done") {
                    puzzle.reset()
                    if !path.isEmpty { path.removeLast() } else { dismiss() }
                }
                .accessibilityIdentifier("puzzle-done")
            }
        }
        .scrollContentBackground(.hidden)
    }
}
