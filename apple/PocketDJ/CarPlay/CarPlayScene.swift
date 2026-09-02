#if os(iOS)
import CarPlay
import UIKit

/// CarPlay scene entry point. Declared as the CarPlay scene's delegate in the Info.plist
/// UIApplicationSceneManifest (see project.yml). SwiftUI keeps owning the phone's window scene;
/// this owns the head-unit templates. It reaches the SAME app-scoped stores as the phone UI
/// through `IntentServices.shared` (a separate `UIScene` gets no SwiftUI environment) — never
/// its own stores, which would fork a second catalog/mix graph.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        let controller = CarPlayController(interfaceController: interfaceController)
        self.controller = controller
        controller.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller = nil
    }
}

/// Builds + drives the CarPlay template hierarchy from `CarPlayModel`.
/// Root = a tab bar: **Playlists · Pockets · For You**. Collections drill into their songs
/// (with a "Play all" row); a song opens an action sheet (Play now / Add to…). Everything plays
/// through the shared sequencer, so the head unit's Now Playing matches the phone.
///
/// Albums and Artists used to be the third and fourth tabs; the owner replaced both with For You
/// (see `CarPlayModel`'s note where their browse lists were). For You's own rows are New first,
/// In Da Zone second, then a row per collection with suggestions — the phone's order, guaranteed by
/// both surfaces calling `ForYouGrid.tiles` rather than by two lists being kept in step.
@MainActor
final class CarPlayController {
    /// The live controller for the connected head unit (nil when no CarPlay scene is up). The
    /// app-scoped favorites observer (WidgetSync) fans a ♥ change out to this so the Now Playing
    /// heart rebuilds — CarPlay's own scene runs OUTSIDE the SwiftUI environment, so a single
    /// shared observer reaches it through this weak hook rather than a second observation.
    static weak var current: CarPlayController?

    private let interfaceController: CPInterfaceController
    private var model: CarPlayModel?
    /// Tiny artwork cache (albumId → image) so re-browsing doesn't refetch.
    private var artCache: [String: UIImage] = [:]
    /// The currently-pushed Up Next list, kept so an edit can refresh it in place.
    private var upNextTemplate: CPListTemplate?
    /// The Playlists tab + its (expensive, catalog-walked) row section, kept so the one-row
    /// "Continue" section above them can be added/removed without rebuilding the rows.
    private var playlistsTemplate: CPListTemplate?
    private var playlistsRowSection: CPListSection?
    /// The Mix tab, kept so its sections rebuild in place (`updateSections`) on every mix-state
    /// change — CarPlay templates are not observed, so each action + the now-playing fan-out
    /// re-renders it, the same discipline as the Continue row.
    private var mixTemplate: CPListTemplate?
    /// The car's chosen crates. Session-local (a fresh connect starts blank): the durable mix
    /// SESSION is what survives — these two only parameterize the next Start.
    private var mixDeckA: MixSource?
    private var mixDeckB: MixSource?
    private lazy var nowPlayingObserver = CarPlayNowPlayingObserver(controller: self)

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        CarPlayController.current = self
    }

    func start() {
        // A brief loading root until the catalog is warm, then the real tab bar.
        let loading = CPListTemplate(title: "PocketDJ", sections: [
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ])
        interfaceController.setRootTemplate(loading, animated: false, completion: nil)
        Task { await buildRoot() }
    }

    private func buildRoot() async {
        guard let services = IntentServices.shared else { return }
        let model = CarPlayModel(services: services)
        self.model = model
        await model.ensureReady()

        let playlists = listTemplate(title: "Playlists", tabImageName: "music.note.list",
                                     rows: model.playlists()) { [weak self] row in
            self?.pushSongs(title: row.title, rows: model.songs(inPlaylist: row.id),
                            playAll: { await model.playPlaylist(id: row.id) },
                            shuffleAll: { await model.playPlaylist(id: row.id, shuffle: true) })
        }
        // Keep the tab + its CATALOG-WALKED row section so the one-row "Continue" header above them
        // can be added and removed in place. Walking the playlists is the expensive part and happens
        // exactly once; the resume row is cheap and must stay TRUE, so it is rebuilt on every track
        // change rather than advertising a finished track for the rest of the drive.
        playlistsTemplate = playlists
        playlistsRowSection = playlists.sections.first
        refreshResumeRow()
        let pockets = listTemplate(title: "Pockets", tabImageName: "square.stack.fill",
                                   rows: model.pockets()) { [weak self] row in
            self?.pushSongs(title: row.title, rows: model.songs(inPocket: row.id),
                            playAll: { await model.playPocket(id: row.id) },
                            shuffleAll: { await model.playPocket(id: row.id, shuffle: true) })
        }
        let forYou = forYouTemplate(model)
        let mixTab = mixTabTemplate(model)

        // NO Search tab: CarPlay's keyboard search left the app frozen in the vehicle until a
        // force-quit (the head-unit keyboard is blocked in motion and never returned control), so
        // it was removed — and nothing here reintroduces one. For You is a fixed, short list of
        // tiles, built off the FROZEN feed with no catalog sweep and no network on this path, so
        // opening the tab does no work that could block the head unit. Hands-free find is available
        // via Siri / the App Intents.
        //
        // Mix takes the FOURTH and last slot an audio app gets on a CPTabBarTemplate — the tab
        // budget is now spent, so the next tab idea costs one of these four.
        let tabBar = CPTabBarTemplate(templates: [playlists, pockets, forYou, mixTab])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
        configureNowPlaying()
        // A durable mix session restored at launch stays parked until a Mix surface shows up;
        // the car connecting IS one showing up. Cued + suspended — never self-playing audio.
        model.materializeMixRestoreIfNeeded()
        refreshMixTab()
        armMixObservation()
    }

    /// Re-armed observation of the MIX state the tab renders from. The now-playing fan-out
    /// (`WidgetSync.arm`) deliberately observes ZERO MixEngine state, so relying on it left the
    /// Mix tab frozen on engine-driven changes — a lock-screen ⏸, a phone-started mix, or a
    /// plain track transition never re-rendered here, and the stale "⏸ Pause Mix" row's tap
    /// then no-opped on `remotePause`'s idempotency guard (a dead control at 70 mph). This is
    /// the standard re-arming `withObservationTracking` loop; the controller deallocating on
    /// disconnect ends it via the weak self.
    private func armMixObservation() {
        guard let model else { return }
        let mix = model.services.mix
        withObservationTracking {
            _ = mix.autoMixing
            _ = mix.autoPaused
            _ = mix.autoSourceLabel
            // Track changes arrive via `autoStatus` (inequality-guarded "n / count · deck"
            // readout). `onAirTrack` is tracked too — its getter registers the whole
            // DeckState, which glide transitions mutate ~10 Hz for the full pre+post-roll
            // (probed: `mutate` fires observation on every write, changed value or not), but
            // `refreshMixTab`'s signature guard makes each over-fire a string compare, never a
            // template push — and it's what keeps a track hand-loaded onto the live deck from
            // the phone (reachable during a hand-mixing pause) fresh on the car's state row.
            _ = mix.autoStatus
            _ = mix.onAirTrack?.songId
            _ = mix.fxGlideEnabled
            _ = mix.mixGlideEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshMixTab()
                self.armMixObservation()
            }
        }
    }

    // MARK: - Mix tab (two-crate Auto DJ remote)

    /// The Mix tab: a REMOTE CONTROL for the shared `MixEngine`, not a DJ board. Setup = pick a
    /// crate per deck + two glide toggles + one Start (always shuffled auto-mix — no manual deck
    /// loading, no song picking in a car). Live = pause/resume the WHOLE mix, fast/slow skip,
    /// stop. Everything routes through `CarPlayModel` → `IntentServices`/lock-screen seams, so
    /// the phone's Mix tab, the lock screen, and the car all drive the same engine state.
    private func mixTabTemplate(_ model: CarPlayModel) -> CPListTemplate {
        let template = CPListTemplate(title: "Mix", sections: mixSections(model))
        template.tabImage = UIImage(systemName: "dial.medium.fill")
        template.tabTitle = "Mix"
        mixTemplate = template
        return template
    }

    /// The rendered facts of the last Mix-tab build — rebuilds are skipped when nothing the
    /// tab SHOWS changed, so an over-firing observation costs a string compare, never a
    /// template push over the head-unit link.
    private var lastMixSignature: String?

    /// Rebuild the Mix tab's sections in place. Called after every Mix action, from the
    /// now-playing fan-out, and from `armMixObservation`'s change loop, so state changed from
    /// the phone or the lock screen re-renders here too.
    func refreshMixTab() {
        guard let model, let mixTemplate else { return }
        let np = model.mixNowPlaying()
        let sig = [model.autoMixRunning() ? "1" : "0", model.autoMixPaused() ? "1" : "0",
                   model.autoMixLabel() ?? "", np?.title ?? "", np?.artist ?? "",
                   model.fxGlideOn() ? "1" : "0", model.audioGlideOn() ? "1" : "0",
                   "\(Int(model.slowSkipSeconds()))",
                   model.crateName(mixDeckA) ?? "", model.crateName(mixDeckB) ?? ""]
            .joined(separator: "|")
        guard sig != lastMixSignature else { return }
        lastMixSignature = sig
        mixTemplate.updateSections(mixSections(model))
    }

    private func mixSections(_ model: CarPlayModel) -> [CPListSection] {
        model.autoMixRunning() ? mixLiveSections(model) : mixSetupSections(model)
    }

    private func mixSetupSections(_ model: CarPlayModel) -> [CPListSection] {
        let deckA = CPListItem(text: "Deck A", detailText: model.crateName(mixDeckA) ?? "Choose a crate…")
        deckA.accessoryType = .disclosureIndicator
        deckA.handler = { [weak self] _, completion in
            self?.pushCratePicker(deck: .a, model: model); completion()
        }
        let deckB = CPListItem(text: "Deck B",
                               detailText: model.crateName(mixDeckB) ?? "Same as Deck A")
        deckB.accessoryType = .disclosureIndicator
        deckB.handler = { [weak self] _, completion in
            self?.pushCratePicker(deck: .b, model: model); completion()
        }
        let start = CPListItem(text: "▶ Start Mix",
                               detailText: mixDeckA == nil ? "Pick Deck A first"
                                                          : "Shuffled auto-mix")
        start.handler = { [weak self] _, completion in
            guard let self, let a = self.mixDeckA else { completion(); return }
            Task { @MainActor in
                if let error = await model.startMix(deckA: a, deckB: self.mixDeckB) {
                    self.toast(error)
                } else {
                    self.showNowPlaying()
                }
                self.refreshMixTab()
                completion()
            }
        }
        return [CPListSection(items: [deckA, deckB], header: "Decks", sectionIndexTitle: nil),
                CPListSection(items: [fxGlideItem(model), audioGlideItem(model)],
                              header: "Transitions", sectionIndexTitle: nil),
                CPListSection(items: [start])]
    }

    private func mixLiveSections(_ model: CarPlayModel) -> [CPListSection] {
        var rows: [CPListItem] = []
        let np = model.mixNowPlaying()
        let paused = model.autoMixPaused()
        let state = CPListItem(text: np.map { "\($0.title) — \($0.artist)" } ?? "Auto DJ",
                               detailText: paused ? "Paused" : "Playing")
        state.handler = { [weak self] _, completion in self?.showNowPlaying(); completion() }
        rows.append(state)
        let pause = CPListItem(text: paused ? "▶ Resume Mix" : "⏸ Pause Mix", detailText: nil)
        pause.handler = { [weak self] _, completion in
            // Decide at TAP time, not render time: even a momentarily-stale row must act on the
            // engine's real state (the render-time branch made a stale row a dead control).
            model.autoMixPaused() ? model.resumeMix() : model.pauseMix()
            self?.refreshMixTab(); completion()
        }
        rows.append(pause)
        let fast = CPListItem(text: "⏭ Skip — quick", detailText: "5 second sweep")
        fast.handler = { [weak self] _, completion in
            model.skipMixFast(); self?.refreshMixTab(); completion()
        }
        rows.append(fast)
        let slow = CPListItem(text: "⏭ Skip — long blend",
                              detailText: "\(Int(model.slowSkipSeconds())) second crossfade")
        slow.handler = { [weak self] _, completion in
            model.skipMixSlow(); self?.refreshMixTab(); completion()
        }
        rows.append(slow)
        let stop = CPListItem(text: "⏹ Stop Mix", detailText: nil)
        stop.handler = { [weak self] _, completion in
            model.stopMix(); self?.refreshMixTab(); completion()
        }
        return [CPListSection(items: rows,
                              header: model.autoMixLabel().map { "Auto DJ — \($0)" } ?? "Auto DJ",
                              sectionIndexTitle: nil),
                CPListSection(items: [fxGlideItem(model), audioGlideItem(model), stop],
                              header: "Transitions", sectionIndexTitle: nil)]
    }

    /// FX Glide row — tap toggles; takes effect on the NEXT transition (engine contract).
    private func fxGlideItem(_ model: CarPlayModel) -> CPListItem {
        let on = model.fxGlideOn()
        let item = CPListItem(text: "FX Glide", detailText: on ? "On" : "Off")
        item.handler = { [weak self] _, completion in
            model.setFXGlide(!on); self?.refreshMixTab(); completion()
        }
        return item
    }

    /// Audio Glide row (bpm + pitch harmonic glide; off = plain equal-power crossfade).
    private func audioGlideItem(_ model: CarPlayModel) -> CPListItem {
        let on = model.audioGlideOn()
        let item = CPListItem(text: "Audio Glide", detailText: on ? "On" : "Off")
        item.handler = { [weak self] _, completion in
            model.setAudioGlide(!on); self?.refreshMixTab(); completion()
        }
        return item
    }

    private enum MixDeck { case a, b }

    /// The crate picker for one deck: pockets + set lists (the two mixable kinds). Deck B also
    /// offers "Same as Deck A" (clears the override).
    private func pushCratePicker(deck: MixDeck, model: CarPlayModel) {
        let crates = model.mixCrates()
        // `[weak self]`: these closures escape into CPListItem handlers on a template this
        // controller retains — a strong self here is a controller↔template cycle that would
        // leak the whole CarPlay graph past disconnect.
        let pick: (MixSource?) -> Void = { [weak self] source in
            guard let self else { return }
            DiagLog.shared.telemetry(
                "car", "mix deck \(deck == .a ? "A" : "B") = \(source.flatMap { model.crateName($0) } ?? "same as A")")
            switch deck {
            case .a: self.mixDeckA = source
            case .b: self.mixDeckB = source
            }
            self.refreshMixTab()
            self.interfaceController.popTemplate(animated: true, completion: nil)
        }
        var sections: [CPListSection] = []
        if deck == .b {
            let same = CPListItem(text: "Same as Deck A", detailText: nil)
            same.handler = { _, completion in pick(nil); completion() }
            sections.append(CPListSection(items: [same]))
        }
        if !crates.pockets.isEmpty {
            sections.append(CPListSection(items: crates.pockets.map { crate in
                let item = CPListItem(text: crate.title, detailText: nil)
                item.handler = { _, completion in pick(crate.source); completion() }
                return item
            }, header: "Pockets", sectionIndexTitle: nil))
        }
        if !crates.setlists.isEmpty {
            sections.append(CPListSection(items: crates.setlists.map { crate in
                let item = CPListItem(text: crate.title, detailText: nil)
                item.handler = { _, completion in pick(crate.source); completion() }
                return item
            }, header: "Set lists", sectionIndexTitle: nil))
        }
        if sections.isEmpty {
            sections = [CPListSection(items: [
                CPListItem(text: "No pockets or set lists yet",
                           detailText: "Build one on iPhone, iPad, or Mac")])]
        }
        let template = CPListTemplate(title: deck == .a ? "Deck A" : "Deck B", sections: sections)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// The one-row "Continue" section, or nil when there is nothing held to resume.
    private func resumeSection(_ model: CarPlayModel)
        -> (header: String, row: CarPlayModel.Row, action: () -> Void)? {
        model.resumableSession().map { row in
            (header: "Continue", row: row, action: { [weak self] in
                model.resumeHeldSession()
                self?.refreshResumeRow()          // it just stopped being resumable
                self?.showNowPlaying()
            })
        }
    }

    /// Add or drop the "Continue" row in place. Called after the row is tapped and from the
    /// track-change fan-out, so a set that was resumed from the phone (or skipped past) stops
    /// advertising a track that already finished. Only the one-row section is rebuilt — the
    /// catalog-walked playlist rows are reused, so this is cheap enough for a track-change hook.
    func refreshResumeRow() {
        guard let template = playlistsTemplate, let rows = playlistsRowSection,
              let model else { return }
        var sections: [CPListSection] = []
        if let lead = resumeSection(model) {
            sections.append(CPListSection(items: [listItem(lead.row, showsDisclosure: false) { lead.action() }],
                                          header: lead.header, sectionIndexTitle: nil))
        }
        sections.append(rows)
        template.updateSections(sections)
    }

    /// The shared Now Playing template is reachable via the system Now Playing button once audio is
    /// playing (that's why we set MPNowPlayingInfoCenter.playbackState in the engines). Enable its
    /// "Up Next" button and observe taps so the driver can see + edit the upcoming queue.
    private func configureNowPlaying() {
        let np = CPNowPlayingTemplate.shared
        np.isUpNextButtonEnabled = true
        np.add(nowPlayingObserver)
        refreshNowPlayingButtons()
    }

    /// Build the ♥ button for the shared Now Playing template, filled/outline by the current
    /// track's favorite state. CarPlay buttons are IMMUTABLE — a state change means REPLACING the
    /// whole `nowPlayingButtons` array (see `refreshNowPlayingButtons`), not mutating a button.
    private func heartButton() -> CPNowPlayingImageButton {
        let on = model?.isCurrentFavorite() ?? false
        let image = UIImage(systemName: on ? "heart.fill" : "heart") ?? UIImage()
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            self?.model?.toggleCurrentFavorite()
            self?.refreshNowPlayingButtons()   // rebuild — the tapped button can't mutate in place
        }
    }

    /// Shuffle button for the shared Now Playing template. Toggles live shuffle of the running
    /// queue's upcoming tail (the SAME `SetlistPlayer.toggleShuffle` the deck + widget call), then
    /// rebuilds (CarPlay buttons are immutable). Shown only while a set is running.
    private func shuffleButton() -> CPNowPlayingImageButton {
        // Reflect on/off state at a glance (like the heart + repeat.1): SF Symbols has no
        // `shuffle.fill`, so use the circled/filled variant for ON. Rebuilt on every toggle.
        let on = model?.isShuffleOn() ?? false
        let image = UIImage(systemName: on ? "shuffle.circle.fill" : "shuffle") ?? UIImage()
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            self?.model?.toggleShuffle()
            self?.refreshNowPlayingButtons()
        }
    }

    /// Repeat button — cycles off → session → song (`SetlistPlayer.cycleRepeatMode`). The glyph
    /// shows `repeat.1` in repeat-song mode so the driver can tell that state apart at a glance.
    private func repeatButton() -> CPNowPlayingImageButton {
        let one = (model?.repeatMode() ?? .off) == .one
        let image = UIImage(systemName: one ? "repeat.1" : "repeat") ?? UIImage()
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            self?.model?.cycleRepeat()
            self?.refreshNowPlayingButtons()
        }
    }

    /// 👍 / 👎 — the SAME matched SF Symbol pair the app and the widgets use, so the control means
    /// one thing on every surface. They record a verdict into the shared `RecFeedbackStore` and
    /// DO NOT touch the transport: no skip, no pause. A driver mis-tapping a thumbs-down at speed
    /// must not lose the song, and CarPlay already has a ⏭ for the other intent.
    ///
    /// VERIFICATION NOTE: the CarPlay UI itself is not headless-testable in this repo (see the
    /// CarPlay + History work) — the command layer under these two closures is what the unit
    /// tests cover (`CarPlayModelTests`), and the template rendering is unverified.
    private func feedbackButton(_ verdict: RecFeedbackStore.Verdict) -> CPNowPlayingImageButton {
        let on = model?.currentFeedback() == verdict
        let accept = verdict == .accepted
        let name = accept ? (on ? "hand.thumbsup.fill" : "hand.thumbsup")
                          : (on ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        let image = UIImage(systemName: name) ?? UIImage()
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            self?.model?.recordCurrentFeedback(verdict)
            self?.refreshNowPlayingButtons()   // immutable buttons — rebuild to re-glyph
        }
    }

    /// Rebuild the Now Playing template's buttons — called on a track change, a favorite change, AND
    /// a repeat/shuffle change (all fan out through the shared observer → `CarPlayController.current`),
    /// because the glyphs depend on that state and the button objects are immutable. Shuffle + repeat
    /// appear only while a set is running (meaningless for a single-track play); CarPlay allows up to
    /// five Now Playing buttons, so the ♥ + the two mode buttons fit comfortably.
    /// CarPlay's documented ceiling for `updateNowPlayingButtons`.
    static let maxNowPlayingButtons = 5

    func refreshNowPlayingButtons() {
        var buttons: [CPNowPlayingButton] = []
        if model?.isSetRunning() == true {
            buttons.append(shuffleButton())
            buttons.append(repeatButton())
        }
        buttons.append(heartButton())
        // CarPlay caps Now Playing at FIVE buttons, and shuffle + repeat + ♥ + 👍 + 👎 is exactly
        // five while a set runs — so the pair is appended LAST and only while the running queue is
        // a recommendation (otherwise the two controls would be inert).
        //
        // The pair is ALL-OR-NOTHING against the cap. A blind `prefix(5)` could keep 👍 and drop
        // 👎, which is worse than showing neither: the two only mean anything as a matched pair,
        // and a lone thumbs-up on a car screen reads as "this is a favorite button".
        if model?.isRecQueue() == true, buttons.count + 2 <= Self.maxNowPlayingButtons {
            buttons.append(feedbackButton(.accepted))
            buttons.append(feedbackButton(.rejected))
        }
        buttons = Array(buttons.prefix(Self.maxNowPlayingButtons))
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
        // Same fan-out point covers the resume row: a set resumed/skipped from the phone stops
        // being "held", so the Continue row must stop offering it.
        refreshResumeRow()
        // …and the Mix tab: a mix started/paused/stopped from the phone or the lock screen
        // re-renders the car's remote too (templates aren't observed — this IS the observer).
        refreshMixTab()
    }

    // MARK: - List templates

    /// Build a browsable list template from rows; `onSelect` handles a row tap (drill-in).
    /// Tabs always use an SF Symbol `tabImage` (+ `tabTitle`) — NOT `tabSystemItem`, whose fixed
    /// system icon/label would override them (e.g. a `.more` item renders a misleading "•••").
    private func listTemplate(title: String, tabImageName: String, rows: [CarPlayModel.Row],
                              onSelect: @escaping (CarPlayModel.Row) -> Void) -> CPListTemplate {
        let items = rows.map { row -> CPListItem in listItem(row, showsDisclosure: true) { onSelect(row) } }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        template.tabImage = UIImage(systemName: tabImageName)
        template.tabTitle = title
        return template
    }

    // MARK: - For You

    /// The **For You** tab: one row per tile, in the phone's order — New, In Da Zone, then the
    /// collections with something worth adding. Built once on connect, off the FROZEN feed, so this
    /// costs a pass over a few thousand cached ids and never a catalog sweep.
    ///
    /// A cold cache (a device that has never opened History) gets a sentence saying where the
    /// recommendations come from, not a blank list — the car must never be the surface that
    /// computes a ranking, so it has to be able to say why there isn't one yet.
    private func forYouTemplate(_ model: CarPlayModel) -> CPListTemplate {
        let rows = model.forYouTiles()
        let items = rows.map { row -> CPListItem in
            listItem(row, showsDisclosure: true) { [weak self] in self?.pushForYou(row, model) }
        }
        let section = CPListSection(items: items.isEmpty
            ? [CPListItem(text: "Nothing yet", detailText: CarPlayModel.coldFeedNote)] : items)
        let template = CPListTemplate(title: "For You", sections: [section])
        template.tabImage = UIImage(systemName: "sparkles")
        template.tabTitle = "For You"
        return template
    }

    /// Drill into one tile (depth 2 = tab root → this list, within CarPlay's audio-app template
    /// stack limit). Its rows are songs for In Da Zone / a collection, and RELEASES for New — both
    /// playable, which is the requirement; the action sheet is what differs.
    private func pushForYou(_ tile: CarPlayModel.Row, _ model: CarPlayModel) {
        let releases = model.isReleaseTile(tile.id)
        pushRows(title: tile.title, rows: model.forYouRows(tileId: tile.id),
                 header: releases ? "Releases" : "Songs",
                 emptyText: releases ? "No new releases to play" : "Nothing to suggest right now",
                 playAll: { await model.playForYouTile(tile.id) },
                 shuffleAll: { await model.playForYouTile(tile.id, shuffle: true) },
                 onSelect: { [weak self] row in self?.presentForYouActions(row, inTile: tile, model) })
    }

    /// A For You row tap → Play now (from here), Add to… (catalog songs only), Cancel.
    ///
    /// A RELEASE row carries no song id — it is a record the owner does not own — so "Add to pocket
    /// / playlist" is genuinely impossible for it and is omitted rather than offered and failed.
    private func presentForYouActions(_ row: CarPlayModel.Row, inTile tile: CarPlayModel.Row,
                                      _ model: CarPlayModel) {
        var actions: [CPAlertAction] = [
            CPAlertAction(title: "Play now", style: .default) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                Task { [weak self] in
                    if await model.playForYouRow(row.id, inTile: tile.id) { self?.showNowPlaying() }
                    else { self?.toast(CarPlayController.couldNotPlay) }
                }
            }
        ]
        if row.isSong {
            actions.append(CPAlertAction(title: "Add to pocket / playlist", style: .default) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true) { _, _ in
                    self?.pushAddTargets(for: row)
                }
            })
        }
        actions.append(CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        })
        let sheet = CPActionSheetTemplate(title: row.title, message: row.subtitle, actions: actions)
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    /// What a tap that produced no audio says. A New expansion needs the network and can legitimately
    /// come back with nothing; saying so is the difference between "Apple Music didn't answer" and a
    /// button the driver thinks is broken.
    static let couldNotPlay = "Couldn’t start that — check your connection and try again"

    // MARK: - Drill-in list

    /// Drill into a collection's songs, with "Play all" + "Shuffle all" rows on top; a song opens
    /// the action sheet.
    private func pushSongs(title: String, rows: [CarPlayModel.Row],
                           playAll: @escaping () async -> Void, shuffleAll: @escaping () async -> Void) {
        // Telemetry: what the head unit is presenting (list + size); taps ride `listItem`.
        DiagLog.shared.telemetry("car", "present songs '\(title)' rows=\(rows.count)")
        pushRows(title: title, rows: rows, header: "Songs", emptyText: "No songs",
                 playAll: { await playAll() }, shuffleAll: { await shuffleAll() },
                 onSelect: { [weak self] row in self?.presentSongActions(row) })
    }

    /// The one drill-in list: "▶ Play all" / "🔀 Shuffle all" on top, then the rows. Shared by
    /// collections and For You tiles so the two cannot drift apart in layout, wording or the
    /// push-then-show-Now-Playing sequence; only the header, the empty line and the row action
    /// differ.
    private func pushRows(title: String, rows: [CarPlayModel.Row], header: String, emptyText: String,
                          playAll: @escaping () async -> Void, shuffleAll: @escaping () async -> Void,
                          onSelect: @escaping (CarPlayModel.Row) -> Void) {
        var sections: [CPListSection] = []
        if !rows.isEmpty {
            let playAllItem = CPListItem(text: "▶ Play all", detailText: nil)
            playAllItem.handler = { [weak self] _, completion in
                Task { await playAll(); self?.showNowPlaying(); completion() }
            }
            let shuffleItem = CPListItem(text: "🔀 Shuffle all", detailText: nil)
            shuffleItem.handler = { [weak self] _, completion in
                Task { await shuffleAll(); self?.showNowPlaying(); completion() }
            }
            sections.append(CPListSection(items: [playAllItem, shuffleItem]))
        }
        let rowItems = rows.map { row -> CPListItem in
            listItem(row, showsDisclosure: false) { onSelect(row) }
        }
        sections.append(CPListSection(items: rowItems.isEmpty
            ? [CPListItem(text: emptyText, detailText: nil)] : rowItems,
            header: header, sectionIndexTitle: nil))
        let template = CPListTemplate(title: title, sections: sections)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// A song tap → an action sheet: Play now, Add to…, Cancel (CarPlay has no row context menu).
    private func presentSongActions(_ row: CarPlayModel.Row) {
        guard let model else { return }
        let play = CPAlertAction(title: "Play now", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            Task { await model.playSong(id: row.id); self?.showNowPlaying() }
        }
        let add = CPAlertAction(title: "Add to pocket / playlist", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true) { _, _ in
                self?.pushAddTargets(for: row)
            }
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let sheet = CPActionSheetTemplate(title: row.title, message: row.subtitle, actions: [play, add, cancel])
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    /// Push the list of add-to destinations; selecting one adds the song and pops back.
    private func pushAddTargets(for song: CarPlayModel.Row) {
        guard let model else { return }
        let targets = model.addTargets()
        let items = targets.map { target -> CPListItem in
            let item = CPListItem(text: target.title, detailText: target.subtitle)
            item.handler = { [weak self] _, completion in
                let name = model.addSong(song.id, toTargetId: target.id)
                self?.interfaceController.popTemplate(animated: true, completion: nil)
                if let name { self?.toast("Added to \(name)") }
                completion()
            }
            return item
        }
        let section = CPListSection(items: items.isEmpty
            ? [CPListItem(text: "No pockets or playlists yet", detailText: nil)] : items)
        let template = CPListTemplate(title: "Add “\(song.title)”", sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Helpers

    /// Build a CPListItem for a row, wiring its tap handler and kicking off async artwork.
    private func listItem(_ row: CarPlayModel.Row, showsDisclosure: Bool,
                          onTap: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: row.title, detailText: row.subtitle)
        if showsDisclosure { item.accessoryType = .disclosureIndicator }
        item.handler = { _, completion in
            // Telemetry: every head-unit row tap, by title — the driver's actions half of
            // "stream my CarPlay session"; template pushes below are the presented half.
            DiagLog.shared.telemetry("car", "tap \(row.title)")
            onTap(); completion()
        }
        loadArtwork(albumId: row.artworkAlbumId, into: item)
        return item
    }

    /// Resolve the first working cover-art URL → UIImage and set it on the item. The URL list
    /// resolves asynchronously (the streaming fallback goes through MusicKit for albums with no
    /// bundled cover — most of the library); `CPListItem.setImage` after the template is already
    /// on screen is the supported live-update path, so rows fill in as covers land.
    private func loadArtwork(albumId: String?, into item: CPListItem) {
        guard let albumId else { return }
        if let cached = artCache[albumId] { item.setImage(cached); return }
        guard let model else { return }
        Task { [weak self] in
            let urls = await model.artURLs(albumId: albumId)
            for url in urls {
                if let (data, resp) = try? await URLSession.shared.data(from: url),
                   (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                   let image = UIImage(data: data) {
                    self?.artCache[albumId] = image
                    item.setImage(image)
                    return
                }
            }
        }
    }

    private func showNowPlaying() {
        // Avoid stacking duplicate Now Playing templates.
        if interfaceController.topTemplate is CPNowPlayingTemplate { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    // MARK: - Up Next (queue view + edit)

    /// Push the upcoming-queue list (Now Playing "Up Next" button → here).
    func showUpNext() {
        let template = CPListTemplate(title: "Up Next", sections: upNextSections())
        upNextTemplate = template
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// A "Now Playing" section (the current track, pinned on top) above the "Up Next" queue —
    /// so PocketDJ's own CarPlay UI shows what's playing NOW, not just what's next (the system
    /// Now Playing card is separate). Omitted when idle. Tapping the current row opens the full
    /// Now Playing template.
    private func upNextSections() -> [CPListSection] {
        var sections: [CPListSection] = []
        if let current = model?.nowPlaying() {
            let li = CPListItem(text: current.title, detailText: current.artist)
            li.handler = { [weak self] _, completion in self?.showNowPlaying(); completion() }
            loadArtwork(albumId: current.albumId, into: li)
            sections.append(CPListSection(items: [li], header: "Now Playing", sectionIndexTitle: nil))
        }
        sections.append(upNextSection())
        return sections
    }

    private func upNextSection() -> CPListSection {
        guard let model else { return CPListSection(items: []) }
        let items = model.upNext().map { item -> CPListItem in
            let li = CPListItem(text: item.title, detailText: item.artist)
            li.handler = { [weak self] _, completion in self?.presentUpNextActions(item); completion() }
            loadArtwork(albumId: item.albumId, into: li)
            return li
        }
        // Header only when there's a Now Playing section above it to distinguish the two;
        // the single-section (idle-queue-view) case reads fine without one.
        let header = model.nowPlaying() != nil ? "Up Next" : nil
        return CPListSection(items: items.isEmpty
            ? [CPListItem(text: "Nothing up next", detailText: nil)] : items,
            header: header, sectionIndexTitle: nil)
    }

    /// A tap on an Up Next row → Play now / Remove / Play next / Move to end (CarPlay has no
    /// swipe-to-delete or row context menu).
    private func presentUpNextActions(_ item: CarPlayModel.UpNextItem) {
        guard let model else { return }
        let playNow = CPAlertAction(title: "Play now", style: .default) { [weak self] _ in
            model.jump(uid: item.uid)
            self?.refreshUpNext()
            self?.interfaceController.dismissTemplate(animated: true) { _, _ in
                // Land on the Now Playing card (same outcome as presentSongActions's Play now).
                // Up Next is only ever pushed FROM the shared CPNowPlayingTemplate (its Up Next
                // button), so that template sits directly beneath us — POP back to it. Pushing
                // `CPNowPlayingTemplate.shared` again would put the one-instance-only template
                // in the hierarchy twice (CarPlay rejects that).
                self?.interfaceController.popTemplate(animated: true, completion: nil)
            }
        }
        let remove = CPAlertAction(title: "Remove from queue", style: .destructive) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            model.removeFromQueue(uid: item.uid)
            self?.refreshUpNext()
        }
        let playNext = CPAlertAction(title: "Play next", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            model.playNext(uid: item.uid)
            self?.refreshUpNext()
        }
        let toEnd = CPAlertAction(title: "Move to end", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            model.moveToEnd(uid: item.uid)
            self?.refreshUpNext()
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let sheet = CPActionSheetTemplate(title: item.title, message: item.artist,
                                          actions: [playNow, remove, playNext, toEnd, cancel])
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    /// Rebuild the Up Next list in place after an edit.
    private func refreshUpNext() { upNextTemplate?.updateSections(upNextSections()) }

    private func toast(_ message: String) {
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPActionSheetTemplate(title: message, message: nil, actions: [ok])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}

/// Observes the shared Now Playing template — routes the "Up Next" button tap to the controller so
/// the driver can see + edit the upcoming queue.
final class CarPlayNowPlayingObserver: NSObject, CPNowPlayingTemplateObserver {
    private weak var controller: CarPlayController?
    init(controller: CarPlayController) { self.controller = controller }
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { controller?.showUpNext() }
    }
}

#endif
