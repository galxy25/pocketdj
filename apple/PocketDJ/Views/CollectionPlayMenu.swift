import SwiftUI

// ============================================================================
// MARK: - Starting a set
// ============================================================================

/// The ONE way a "named list of CATALOG songs" starts playing from a menu item or a floating
/// toolbar button — `IntentServices.playSongIds`, the app's existing *start a set with no
/// navigation* door (the one History's Rewind already uses). That buys the onboarding veto,
/// `ensureReady()`, the reserved Now Playing setlist, the lock screen, CarPlay and the durable
/// session. It is deliberately NOT `collections.playNow` on its own, which builds the setlist but
/// starts nothing.
///
/// `onStarted` runs AFTER the play, never before: `CollectionsStore.playNow` clears any previous
/// recommendation scope on its way through, so a feedback stamp made first would be wiped.
///
/// NOT the door for a record the owner does not own — `playNow` drops every id the catalog cannot
/// resolve, which is *every* track of an unowned Apple Music release. That case has its own
/// existing door (`ReleaseStreaming`, which queues `am:<storeID>` ids straight onto the sequencer,
/// exactly as the Jukebox and Music with Friends already do for an Apple-Music-only match).
@MainActor
enum CollectionPlayback {
    static func start(_ ids: [String], title: String, shuffle: Bool,
                      source: PlayHistoryStore.PlaySource = .browser,
                      intents: IntentServices?,
                      onStarted: (([String]) -> Void)? = nil) {
        guard !ids.isEmpty, let intents else { return }
        Task { @MainActor in
            _ = try? await intents.playSongIds(ids, name: title, shuffle: shuffle, source: source)
            onStarted?(ids)
        }
    }
}

// ============================================================================
// MARK: - The floating toolbar every "list of songs" screen wears
// ============================================================================

/// 📱/☁️ **mode** · ▶ **Play** · ▶▶ **Play All** · 🔀 **Shuffle** · ⋯ **menu** — the primary-action
/// items a PocketDJ list-of-songs screen floats in its navigation bar.
///
/// ── WHY THIS IS A MODIFIER AND NOT FOUR COPIES ───────────────────────────────────────────────
/// Owner, verbatim: *"i want the native menu controls that float in too like in a playlist we have
/// the cloud or on device toggle play and shuffle and … menu item for the context menus."*
/// `PlaylistDetailView` and `PocketDetailView` had already drifted from each other while shipping
/// exactly this (one used `Label`, the other a bare `Image`), which is what hand-copying it onto
/// the three For You tile screens would have compounded. So the arrangement — the ORDER, the
/// placement, the SF Symbols, the wording and the accessibility ids — lives here once, and each
/// screen supplies only what is genuinely its own: whether it can play, what Play does, what
/// Play All does, and what goes in the ⋯.
///
/// ── THE DEVICE/CLOUD TOGGLE IS GLOBAL, WHICH IS WHY EVERY PLAYING SCREEN WEARS IT ────────────
/// `PlaybackModeToggle` flips `SettingsStore.playbackMode`, which `SetlistPlayer` reads for EVERY
/// queue regardless of where it came from: `.device` plays only what is burned on the device and
/// SKIPS the rest, `.cloud` streams what is not. A tile's ▶ ends in that same `SetlistPlayer`, so
/// the toggle is exactly as live on a tile screen as on a playlist screen — including on **New**,
/// where cloud mode is the only thing that can play a record the owner does not own yet. Owner,
/// verbatim: *"we want to be able to play or shuffle New as well, that is the equivalent of cloud
/// mode for a collection."* It is therefore shown wherever the screen can play at all.
///
/// ── PLAY, PLAY ALL AND SHUFFLE ALL SHOW, ALWAYS ──────────────────────────────────────────────
/// Owner, verbatim: *"always show play and play all and shuffle."* This overrules the earlier
/// judgement that ▶▶ should hide where it resolves to the same act as ▶. A screen that supplies a
/// `playAll` gets all three every time; where the two are identical for a given list that is
/// accepted, because a control that appears and disappears depending on the data is worse than a
/// redundant one. The distinction is kept where it is REAL: on a recommendation list ▶ takes the
/// live picks and ▶▶ takes everything, including the rows thumbed down and sunk to the bottom.
struct CollectionToolbar<MenuItems: View>: ViewModifier {
    /// Accessibility-id stem: `"<idPrefix>-play"` / `"-play-all"` / `"-shuffle"` / `"-menu"`.
    /// Must be unique app-wide — two live registrations of one id make BOTH unqueryable in
    /// XCUITest (`foryou-menu` is already History's For You tab menu, hence `foryou-list-`).
    let idPrefix: String
    /// Fills the help text: "Play this <noun> now".
    let noun: String
    /// Greys ▶ and 🔀 — the two that play the LIVE list (an empty playlist still shows them, like
    /// every music app).
    var canPlay: Bool = true
    /// Greys ▶▶ **Play All**, which plays a DIFFERENT (larger) list. Defaults to `canPlay`, which
    /// is right wherever the two lists are the same thing.
    ///
    /// ── WHY THIS IS A SEPARATE GATE (a shipped bug, not a hypothetical) ──────────────────────
    /// The New screen enabled its whole transport on `!outNow.isEmpty` while ▶ played `live(outNow)`
    /// — so thumbing down every out-now release left ▶ LIT over an empty queue, and the tap hit an
    /// `isEmpty` guard and did nothing. One `canPlay` cannot describe two lists. Splitting it also
    /// fixes the mirror-image error the other tile screens had: they gated everything on the LIVE
    /// half, so a fully-thumbed-down list greyed out ▶▶ Play All — the one control whose entire
    /// purpose is to play the tail that was thumbed down.
    var canPlayAll: Bool? = nil
    /// Set false where the screen has no context actions to carry — an empty ⋯ is furniture
    /// pretending to be a control.
    var showsMenu: Bool = true
    /// `true` = shuffle.
    var play: (Bool) -> Void = { _ in }
    /// ▶▶ **Play All**. Every screen that floats this toolbar supplies one — owner, verbatim:
    /// *"always show play and play all and shuffle."* On a playlist or pocket it resolves to the
    /// same act as ▶ (there is no thumbed-down tail to add), and that redundancy is the accepted
    /// cost of the three controls never moving between screens.
    var playAll: (() -> Void)? = nil
    /// The ▶▶ help text. Defaults to the plain reading; a recommendation list overrides it, because
    /// there ▶▶ genuinely takes MORE than ▶ and the tooltip is where that is explained.
    var playAllHelp: String? = nil
    /// The context actions. Everything beyond the transport belongs here. (Built by the
    /// `collectionToolbar` modifier below, which is where the `@ViewBuilder` lives — a stored
    /// builder property would re-apply the transform to an already-built closure.)
    var menuItems: () -> MenuItems

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .primaryAction) { PlaybackModeToggle() }
            ToolbarItem(placement: .primaryAction) {
                Button { play(false) } label: { Label("Play", systemImage: "play.fill") }
                    .help("Play this \(noun) now")
                    .disabled(!canPlay)
                    .accessibilityIdentifier("\(idPrefix)-play")
            }
            if let playAll {
                ToolbarItem(placement: .primaryAction) {
                    CollectionPlayAllButton(idPrefix: idPrefix, action: playAll)
                        .help(playAllHelp ?? "Play everything in this \(noun)")
                        .disabled(!(canPlayAll ?? canPlay))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { play(true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .help("Shuffle-play this \(noun) now")
                    .disabled(!canPlay)
                    .accessibilityIdentifier("\(idPrefix)-shuffle")
            }
            if showsMenu {
                ToolbarItem(placement: .primaryAction) {
                    Menu { menuItems() } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityIdentifier("\(idPrefix)-menu")
                }
            }
        }
    }
}

extension View {
    /// The standard collection/tile toolbar. See `CollectionToolbar`.
    func collectionToolbar<MenuItems: View>(
        idPrefix: String, noun: String,
        canPlay: Bool = true, canPlayAll: Bool? = nil, showsMenu: Bool = true,
        play: @escaping (Bool) -> Void = { _ in },
        playAll: (() -> Void)? = nil,
        playAllHelp: String? = nil,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) -> some View {
        modifier(CollectionToolbar(idPrefix: idPrefix, noun: noun, canPlay: canPlay,
                                   canPlayAll: canPlayAll, showsMenu: showsMenu,
                                   play: play, playAll: playAll, playAllHelp: playAllHelp,
                                   menuItems: menuItems))
    }
}

// ============================================================================
// MARK: - "Device mode played nothing" — the banner, reachable from every start surface
// ============================================================================

/// 📱 **Device mode, and not one track was on the device.** `SetlistPlayer` raises
/// `deviceQueueUnplayable` when a whole run finishes without ever loading a burned file — it skips
/// each unplayable row, so without a banner the outcome is silence and no explanation.
///
/// ── TWO SEPARATE REASONS IT COULD NOT FIRE, BOTH FIXED HERE ─────────────────────────────────
/// 1. **It bound on a torn-down value.** It shipped inside `SetlistDetailView` as
///    `deviceQueueUnplayable && sequencer.sourceSetlistId == setlistId` — but `advanceToNext`
///    calls `stop()` (which nils `sourceSetlistId`) on the line before it raises the flag, so the
///    comparison was nil-vs-id for every run on every screen. `SetlistPlayer` now publishes
///    `deviceUnplayableSourceId`, captured before the teardown, and that is what this binds on.
/// 2. **It lived on one screen.** The For You tile screens deliberately do NOT push Now Playing
///    (the point is to stay on the rows with the 👍/👎 in reach), and the New screen's queue is not
///    a collection at all — so even a working condition would have had nowhere to land. The
///    condition therefore lives here, once, and every surface that can START a queue wears it for
///    the id it starts under.
///
/// `clearDeviceUnplayable()` is one-shot, so whichever surface is on screen shows it and the signal
/// is spent.
struct DeviceQueueUnplayableAlert: ViewModifier {
    @Environment(SetlistPlayer.self) private var sequencer
    /// The `sourceSetlistId` this screen's ▶ starts runs under — so a screen only ever answers for
    /// its own run, never for one some other surface started.
    let sourceId: String?
    /// Stand down. TWO screens can share one `sourceId` and be in the hierarchy at once — the For
    /// You GRID (whose tile card can start a New queue) is still mounted underneath the New SCREEN
    /// it pushed, and two live bindings on one condition is a presentation conflict in one window.
    /// The ancestor passes `path.isEmpty` so the screen actually in front owns the alert.
    var isActive: Bool = true

    func body(content: Content) -> some View {
        content.alert("No burned files", isPresented: Binding(
            get: {
                isActive && sequencer.deviceQueueUnplayable
                    && sequencer.deviceUnplayableSourceId == sourceId
            },
            set: { if !$0 { sequencer.clearDeviceUnplayable() } })) {
            Button("OK", role: .cancel) { sequencer.clearDeviceUnplayable() }
        } message: {
            Text("Device playback is on, but none of these tracks are burned to this device. Burn them, or switch to cloud streaming.")
        }
    }
}

extension View {
    /// See `DeviceQueueUnplayableAlert`. Wear it on any screen whose transport can start a run.
    func deviceQueueUnplayableAlert(sourceId: String?, isActive: Bool = true) -> some View {
        modifier(DeviceQueueUnplayableAlert(sourceId: sourceId, isActive: isActive))
    }
}

// ============================================================================
// MARK: - ▶▶ Play All
// ============================================================================

/// ▶▶ **Play All** — the whole list *including* the tail the listener thumbed down.
///
/// ONE definition, worn by both surfaces that offer it: the tile screen's floating toolbar and the
/// tile card's context menu in the grid. Where a list has no sunk tail this plays exactly what ▶
/// plays; that redundancy is deliberate (see `CollectionToolbar`), because the owner asked for the
/// three controls to be present every time rather than to appear and disappear with the data.
struct CollectionPlayAllButton: View {
    let idPrefix: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label("Play All", systemImage: "play.square.stack") }
            .accessibilityIdentifier("\(idPrefix)-play-all")
    }
}

// ============================================================================
// MARK: - The same trio, as menu items
// ============================================================================

/// ▶ **Play** · ▶▶ **Play All** · 🔀 **Shuffle** as standard iOS *menu items*, for the one surface
/// that has no toolbar of its own to float them in: a **For You tile CARD** in the grid, where
/// long-press / right-click is the only place a card's actions can live.
///
/// All three, always — the same rule the toolbar follows, so the card menu and the screen it opens
/// cannot offer different sets of controls.
///
/// It is NOT used on collection rows. That shipped once and the owner rejected it outright ("i
/// dont want a row level play menu") — a playlist row long-press is for rename/move/delete, and
/// playing belongs to the detail screen's toolbar (`CollectionToolbar`).
struct CollectionPlayMenuItems: View {
    @Environment(IntentServices.self) private var intents: IntentServices?

    /// Display name for the Now Playing set.
    let title: String
    /// The list as offered — the live rows, in order.
    let songIds: [String]
    /// Rows this list SINKS but still shows; only `Play All` includes them.
    var sunkIds: [String] = []
    /// What History files these plays under.
    var source: PlayHistoryStore.PlaySource = .browser
    /// Accessibility-id stem: `"<idPrefix>-play"` / `"-play-all"` / `"-shuffle"`.
    let idPrefix: String
    /// Ran with the queue that was actually started — For You uses it to stamp the feedback scope
    /// so the now-playing 👍/👎 file against the right tile.
    var onStarted: (([String]) -> Void)? = nil

    private var everything: [String] { songIds + sunkIds.filter { !songIds.contains($0) } }

    var body: some View {
        Button { start(songIds, shuffle: false) } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(songIds.isEmpty)
        .accessibilityIdentifier("\(idPrefix)-play")

        CollectionPlayAllButton(idPrefix: idPrefix) { start(everything, shuffle: false) }
            .disabled(everything.isEmpty)

        Button { start(songIds, shuffle: true) } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        .disabled(songIds.isEmpty)
        .accessibilityIdentifier("\(idPrefix)-shuffle")
    }

    private func start(_ ids: [String], shuffle: Bool) {
        CollectionPlayback.start(ids, title: title, shuffle: shuffle, source: source,
                                 intents: intents, onStarted: onStarted)
    }
}
