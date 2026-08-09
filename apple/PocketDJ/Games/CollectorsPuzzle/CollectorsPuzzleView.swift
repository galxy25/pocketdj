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
    @State private var poolStats: PuzzleSampler.PoolStats?
    @State private var countTask: Task<Void, Never>?
    @State private var showReplaceConfirm = false
    @State private var showNewPocket = false
    @State private var newPocketName = ""
    /// Non-nil ⇒ the Add-to picker is up for THIS song (change 3: tap the card / "File into…"
    /// to file it into ANY collection, not just a preselected target). Carrying the SONG (not
    /// a Bool) means a mid-sheet drift or top-up can never make the sheet file the wrong card.
    /// Nil-ing it — Done, swipe-down, Esc — is also the moment the filing SETTLES: the engine
    /// scores the whole opening once and advances (see the `.sheet`/`onChange` pair below).
    /// Declared here in the body-level `@State` block on purpose — the only platform fence in
    /// this file is inside `yearRow`, and a shared property that lands inside an `#if os(iOS)`
    /// ships on iOS while the macOS/visionOS ARCHIVES fail at ship time.
    @State private var filingSong: IndexSong?

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
        .navigationTitle(GameKind.collectorsPuzzle.label)
        .background(Theme.bg)
        // THE "file into ANY collection" PATH (change 3). Reuses the app's ONE add-to sheet
        // verbatim — same fuzzy search field, same pockets/playlists/source lists — so the
        // player can search and file the card anywhere, targets or no targets.
        .sheet(item: $filingSong) { song in
            AddToCollectionView(item: .song(song.id)) { target in
                // MULTI-COLLECTION FILING (Levi 2026-08-08): note the add and STAY OPEN. This
                // is the app's one multi-select picker and it never self-dismisses for any
                // other caller; Gem Collector was the sole exception (`filingSong = nil` right
                // here), which is exactly what stopped a player filing one card into several
                // crates. No score here either — see the settle point below.
                puzzle.noteFiled(to: target)
            }
        }
        // Dismiss (Done / swipe-down / Esc) is the ONE place a filing settles: `endFiling`
        // credits the held clock, scores the card ONCE for the whole opening however many
        // collections it landed in, advances, and re-arms audio. An opening that added
        // nothing — or whose adds were all toggled back off — is a cancel: no point, no
        // advance, the card stays. `endFiling` stays idempotent for the legacy callers.
        .onChange(of: filingSong) { _, new in
            if new == nil { puzzle.endFiling(assignedTo: nil) }
        }
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
            let n = await puzzle.poolStats()
            guard !Task.isCancelled else { return }
            poolStats = n
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
            Section {
                // Similarity only means something with a target to be similar TO.
                if !draft.targetCollectionIds.isEmpty {
                    Picker("Draw", selection: $draft.similarity) {
                        Text("Anything").tag(PuzzleSettings.Similarity.off)
                        Text("Similar").tag(PuzzleSettings.Similarity.on)
                        Text("Very similar").tag(PuzzleSettings.Similarity.strict)
                    }
                    .accessibilityIdentifier("puzzle-similarity")
                }
                targetList
                Button("New Pocket…") { showNewPocket = true }
                    .accessibilityIdentifier("puzzle-new-pocket")
            } header: {
                Text("Targets (optional, up to 3)")
            } footer: {
                Text(draft.targetCollectionIds.isEmpty
                     ? "No targets: every card opens the full Add-to picker, so you can file it into any collection. Cards come from your whole catalog."
                     : "One-tap buttons during the round — plus “Other…” for anything else. Combine with the “Not in” collection filter to hunt songs LIKE these crates that aren’t in them yet.")
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
        Text(poolCountText)
            .font(.footnote).foregroundStyle(Theme.fgDim)
            .lineLimit(1)
            .accessibilityIdentifier("puzzle-pool-count")
    }

    /// "N songs match", plus "· M similar" when the similarity ranker is actually shortlisting.
    private var poolCountText: String {
        guard let stats = poolStats else { return "… songs match" }
        guard let similar = stats.similar else { return "\(stats.matched) songs match" }
        return "\(stats.matched) match · \(similar) similar"
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
        // Targets are OPTIONAL — the ONLY thing a round needs is songs to show. With no
        // targets every card is filed through the Add-to picker (`puzzle-file`), which is a
        // complete scoring path on its own.
        .disabled(poolStats?.matched == 0)
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

            actionButtons
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

    /// THE CARD IS A BUTTON (change 3): tapping the song opens the Add-to picker for it. The
    /// `plus.circle` in the corner is not decoration — a bare tappable card is invisible UI.
    private func currentCard(_ song: IndexSong) -> some View {
        Button {
            beginFiling()
        } label: {
            VStack(spacing: 6) {
                HStack(alignment: .top) {
                    Spacer(minLength: 0)
                    Text(song.name).font(.title2.weight(.semibold)).foregroundStyle(Theme.fg)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "plus.circle").foregroundStyle(Theme.accent2)
                }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `puzzle-current` stays on the OUTER element: `GamesUITests` matches it through
        // `descendants(matching: .any)`, which survives the change from static text to button.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double tap to file this song into any collection")
        .accessibilityIdentifier("puzzle-current")
    }

    /// The scoring controls: 0–3 one-tap target buttons plus the ALWAYS-present "file into any
    /// collection" button. Full-width stack where narrow, one row where wide (`ViewThatFits`
    /// — no os fences).
    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { assignButtonList; fileIntoButton }
            VStack(spacing: 10) { assignButtonList; fileIntoButton }
        }
    }

    /// ALWAYS present — the "any collection" path. With no targets it is the ONLY scoring
    /// control (and therefore the prominent one); with targets it sits beside them as the
    /// escape hatch for a song that belongs somewhere else.
    @ViewBuilder private var fileIntoButton: some View {
        if puzzle.settings.targetCollectionIds.isEmpty {
            Button { beginFiling() } label: { fileIntoLabel("File into…") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("puzzle-file")
        } else {
            Button { beginFiling() } label: { fileIntoLabel("Other…") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("puzzle-file")
        }
    }

    private func fileIntoLabel(_ text: String) -> some View {
        Label(text, systemImage: "plus.rectangle.on.folder")
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    /// Open the Add-to picker for the current card — engine first (it holds the round clock
    /// and refuses when there is nothing to file), then present.
    private func beginFiling() {
        guard let song = puzzle.current, puzzle.beginFiling() else { return }
        filingSong = song
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
