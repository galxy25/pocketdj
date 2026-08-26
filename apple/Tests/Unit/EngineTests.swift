import XCTest
import MediaPlayer
@testable import PocketDJ

final class CamelotTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Camelot.parse("8A")?.num, 8)
        XCTAssertEqual(Camelot.parse("8A")?.major, false)
        XCTAssertEqual(Camelot.parse("12B")?.major, true)
        XCTAssertNil(Camelot.parse("13A"))
        XCTAssertNil(Camelot.parse("xx"))
        XCTAssertNil(Camelot.parse(nil))
    }

    func testRankOrdersWheel() {
        // 1A < 1B < 2A < … (A even, B odd, contiguous)
        XCTAssertEqual(Camelot.rank("1A"), 2)
        XCTAssertEqual(Camelot.rank("1B"), 3)
        XCTAssertLessThan(Camelot.rank("7A")!, Camelot.rank("7B")!)
        XCTAssertLessThan(Camelot.rank("8B")!, Camelot.rank("9A")!)
    }

    func testKeysAreWheelOrdered() {
        XCTAssertEqual(Camelot.keys.first, "1A")
        XCTAssertEqual(Camelot.keys.last, "12B")
        XCTAssertEqual(Camelot.keys.count, 24)
    }
}

final class GenreTests: XCTestCase {
    func testCategorizeRoutesToTopTier() {
        XCTAssertEqual(Genre.category("Electronic"), "electronic")
        XCTAssertEqual(Genre.category("Jazz"), "jazz")
        XCTAssertEqual(Genre.category("Funk / Soul"), "funk")   // funk precedes soul in priority
        XCTAssertEqual(Genre.category("Hip hop"), "hip-hop")
        XCTAssertEqual(Genre.category("Synthpop"), "electronic")
        XCTAssertEqual(Genre.category("Contemporary R&B"), "r&b")
        // Priority is ordered: "soul" precedes "r&b", so a glued "r&bsoul" routes
        // to soul (matches the PWA's first-keyword-wins behaviour), not r&b.
        XCTAssertEqual(Genre.category("R&Bsoul"), "soul")
    }
    func testCategorizeUnmappableIsOther() {
        XCTAssertEqual(Genre.category(nil), "Other")
        XCTAssertEqual(Genre.category(""), "Other")
        XCTAssertEqual(Genre.category("   "), "Other")
        XCTAssertEqual(Genre.category("qwertyuiop"), "Other")
    }
    func testCategoryNames() {
        XCTAssertEqual(Genre.categoryNames.first, "holiday")
        XCTAssertEqual(Genre.categoryNames.last, "Other")
        XCTAssertEqual(Genre.categoryNames.count, 16)  // 15 categories + Other
    }

    /// A seasonal tag outranks the parent genre it is glued to — the whole point of putting
    /// `holiday` first. Before this, "Holiday" and "Christmas" both fell through to "Other"
    /// and `build-rec-features` then dropped the row's genre field entirely, which is why a
    /// 62-song holiday crate profiled itself off its 11 non-holiday members.
    func testHolidayOutranksTheParentGenre() {
        XCTAssertEqual(Genre.category("Holiday"), "holiday")
        XCTAssertEqual(Genre.category("Christmas"), "holiday")
        XCTAssertEqual(Genre.category("Christmas: R&B"), "holiday")
        XCTAssertEqual(Genre.category("Christmas: Pop"), "holiday")
        XCTAssertEqual(Genre.category("Christmas: Country"), "holiday")
    }

    /// The second pass exists so a broad parent tag loses to any specific genre in the SAME
    /// string. If these ever collapse into one pass, "Alternative Folk" silently becomes rock.
    func testBroadTagsLoseToASpecificGenreInTheSameString() {
        XCTAssertEqual(Genre.category("Alternative"), "rock")
        XCTAssertEqual(Genre.category("Indie"), "rock")
        XCTAssertEqual(Genre.category("Alternative Folk"), "folk")
        XCTAssertEqual(Genre.category("Indie, Pop, Alternative"), "pop")
        XCTAssertEqual(Genre.category("Alternative Rap"), "hip-hop")
        XCTAssertEqual(Genre.category("Soundtrack"), "classical")
        XCTAssertEqual(Genre.category("Christian"), "soul")
        XCTAssertEqual(Genre.category("Ambient"), "electronic")
    }

    /// Labels that are not a genre stay "Other" ON PURPOSE. Inventing a category for
    /// "Instrumental" or "Hörspiele" would be fabricating signal, not recovering it.
    func testNonGenreLabelsStayOther() {
        XCTAssertEqual(Genre.category("Instrumental"), "Other")
        XCTAssertEqual(Genre.category("Hörspiele"), "Other")
        XCTAssertEqual(Genre.category("Unknown Genre"), "Other")
    }
}

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Fmt.duration(222000), "3:42")
        XCTAssertEqual(Fmt.duration(201000), "3:21")
        XCTAssertEqual(Fmt.duration(nil), "–")
        XCTAssertEqual(Fmt.duration(0), "–")
    }
    func testBpm() {
        XCTAssertEqual(Fmt.bpm(128), "128")
        XCTAssertEqual(Fmt.bpm(127.6), "128")
        XCTAssertEqual(Fmt.bpm(nil), "–")
    }
}

final class BPMTierTests: XCTestCase {
    func testTierBuckets() {
        XCTAssertEqual(BPMTier.tier(60), 1)    // slow
        XCTAssertEqual(BPMTier.tier(89), 1)
        XCTAssertEqual(BPMTier.tier(95), 2)    // medium
        XCTAssertEqual(BPMTier.tier(119), 2)
        XCTAssertEqual(BPMTier.tier(128), 3)   // fast
        XCTAssertEqual(BPMTier.tier(159), 3)
        XCTAssertEqual(BPMTier.tier(174), 4)   // hyper
        XCTAssertEqual(BPMTier.tier(399), 4)
    }
    func testTierBoundariesAreLowerInclusive() {
        // Each boundary belongs to the HIGHER tier (upper bound exclusive).
        XCTAssertEqual(BPMTier.tier(90), 2)
        XCTAssertEqual(BPMTier.tier(120), 3)
        XCTAssertEqual(BPMTier.tier(160), 4)
    }
    func testTierNilAndZero() {
        XCTAssertNil(BPMTier.tier(nil))
        XCTAssertNil(BPMTier.tier(0))
        XCTAssertNil(BPMTier.tier(-5))
    }
}

final class FilterEngineTests: XCTestCase {
    func testGenreEqualsOnAlbums() throws {
        let items = try TestData.albumItems()
        let c = Clause(field: "genre", op: .eq, value: "Electronic")
        let out = FilterEngine.apply(items, [c])
        XCTAssertEqual(out.map(\.idString), ["alb_1"])
    }

    func testYearBetweenOnAlbums() throws {
        let items = try TestData.albumItems()
        var c = Clause(field: "year", op: .between); c.min = 1990; c.max = 2025
        let out = FilterEngine.apply(items, [c])
        XCTAssertEqual(Set(out.map(\.idString)), ["alb_1", "alb_2"])
    }

    func testBpmBetweenOnSongs() throws {
        let items = try TestData.songItems()
        var c = Clause(field: "bpm", op: .between); c.min = 100; c.max = 130
        let out = FilterEngine.apply(items, [c])
        XCTAssertEqual(Set(out.map(\.idString)), ["sng_1", "sng_2", "sng_4", "sng_6"])
    }

    func testExplicitTrue() throws {
        let items = try TestData.songItems()
        let c = Clause(field: "explicit", op: .eq, value: "true")
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.idString)), ["sng_2", "sng_6"])
    }

    func testCamelotInList() throws {
        let items = try TestData.songItems()
        var c = Clause(field: "camelot", op: .inList); c.values = ["8A", "8B"]
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.idString)), ["sng_1", "sng_2"])
    }

    func testSentimentInList() throws {
        let items = try TestData.songItems()
        var c = Clause(field: "sentiment", op: .inList); c.values = ["drive"]
        XCTAssertEqual(FilterEngine.apply(items, [c]).map(\.idString), ["sng_1"])
    }

    func testIncompleteClauseIsNoOp() throws {
        let items = try TestData.songItems()
        let c = Clause(field: "bpm", op: .eq, value: "")   // no operand yet
        XCTAssertEqual(FilterEngine.apply(items, [c]).count, items.count)
    }

    func testAndComposition() throws {
        let items = try TestData.songItems()
        var bpm = Clause(field: "bpm", op: .between); bpm.min = 100; bpm.max = 130
        let expl = Clause(field: "explicit", op: .eq, value: "true")
        XCTAssertEqual(FilterEngine.apply(items, [bpm, expl]).map(\.idString), ["sng_2", "sng_6"])
    }

    // MARK: Source clause (matches the origin source threaded onto each item)

    func testSourceEqualsOnSongs() throws {
        // Tag sng_1..3 with "My Vinyl" and the rest with "Apple Music (Local)".
        let items = try TestData.songItems().map { item -> BrowseItem in
            guard case .song(let s, let an, _, _, _) = item else { return item }
            let src = ["sng_1", "sng_2", "sng_3"].contains(s.id) ? "My Vinyl" : "Apple Music (Local)"
            return .song(s, albumName: an, source: src)
        }
        let c = Clause(field: "source", op: .eq, value: "My Vinyl")
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.idString)), ["sng_1", "sng_2", "sng_3"])
    }

    func testSourceInListOnAlbums() throws {
        let items = [
            BrowseItem.album(try TestData.index().albums[0], source: "My Vinyl"),       // alb_1
            BrowseItem.album(try TestData.index().albums[1], source: "Apple Music (Local)"), // alb_2
            BrowseItem.album(try TestData.index().albums[2], source: "Web"),            // alb_3
        ]
        var c = Clause(field: "source", op: .inList); c.values = ["My Vinyl", "Web"]
        XCTAssertEqual(Set(FilterEngine.apply(items, [c]).map(\.idString)), ["alb_1", "alb_3"])
    }

    func testSourceNotEquals() throws {
        let items = try TestData.albumItemsTagged(source: "My Vinyl")
        // None match "is not My Vinyl"; all match "is not Web".
        let none = Clause(field: "source", op: .neq, value: "My Vinyl")
        XCTAssertTrue(FilterEngine.apply(items, [none]).isEmpty)
        let all = Clause(field: "source", op: .neq, value: "Web")
        XCTAssertEqual(FilterEngine.apply(items, [all]).count, items.count)
    }
}

final class SortEngineTests: XCTestCase {
    func testBpmAscending() throws {
        let items = try TestData.songItems()
        let out = SortEngine.apply(items, [SortKey(field: "bpm", dir: .asc)])
        XCTAssertEqual(out.first?.idString, "sng_7")  // 72
        XCTAssertEqual(out.last?.idString, "sng_1")   // 128
    }

    func testYearDescendingOnAlbums() throws {
        let items = try TestData.albumItems()
        let out = SortEngine.apply(items, [SortKey(field: "year", dir: .desc)])
        XCTAssertEqual(out.map(\.idString), ["alb_1", "alb_2", "alb_3"])
    }

    func testCamelotSortsByWheelNotAlpha() throws {
        let items = try TestData.songItems()
        let out = SortEngine.apply(items, [SortKey(field: "camelot", dir: .asc)])
        // ranks: 7A,7B,8A,8B,9A,9B,10A  → not "10A" first as a string sort would give
        XCTAssertEqual(out.first?.idString, "sng_5")  // 7A
        XCTAssertEqual(out.last?.idString, "sng_7")   // 10A
    }

    func testMultiKeyStable() throws {
        let items = try TestData.songItems()
        // primary artist asc, secondary bpm desc
        let out = SortEngine.apply(items, [SortKey(field: "artist", dir: .asc),
                                           SortKey(field: "bpm", dir: .desc)])
        // Aria block first (bpm desc): 128,124,90 → sng_1,sng_2,sng_3
        XCTAssertEqual(out.prefix(3).map(\.idString), ["sng_1", "sng_2", "sng_3"])
    }

    func testEmptyKeysReturnsInput() throws {
        let items = try TestData.songItems()
        XCTAssertEqual(SortEngine.apply(items, []).map(\.idString), items.map(\.idString))
    }
}

final class DecodingTests: XCTestCase {
    func testDecodesFixture() throws {
        let idx = try TestData.index()
        XCTAssertEqual(idx.albums.count, 3)
        XCTAssertEqual(idx.songs.count, 7)
        XCTAssertEqual(idx.manifest.sourceName, "Test Crate")
        XCTAssertEqual(idx.albums[0].trackList.count, 3)
        XCTAssertEqual(idx.songs[0].camelot, "8A")
    }
}

/// F10 lock-screen ♥ — the `MPRemoteCommandCenter.likeCommand` handler routes through the two
/// injected closures (`toggleCurrentFavorite` / `isCurrentFavorite`), wired in PocketDJApp from the
/// favorites store + the catalog. The command render/tap itself (MediaPlayer UI) needs on-device
/// verification, but the closure wiring — the part with the logic — is unit-testable: invoke the
/// closures exactly as the handler does and assert the FavoritesStore state.
@MainActor
final class PlayerEngineFavoriteTests: XCTestCase {
    private func wire(_ player: PlayerEngine, _ favorites: FavoritesStore, appleMusicId: String? = nil) {
        // Mirror PocketDJApp.init's wiring: the current song is the engine's own nowPlayingSongId;
        // the catalog id (nil ⇒ still favorited local-only) rides the toggle for the owner push.
        player.toggleCurrentFavorite = { [weak player, weak favorites] in
            guard let player, let favorites, let id = player.nowPlayingSongId else { return }
            favorites.toggle(id, appleMusicId: appleMusicId)
        }
        player.isCurrentFavorite = { [weak player, weak favorites] in
            guard let player, let favorites, let id = player.nowPlayingSongId else { return false }
            return favorites.isFavorite(id)
        }
    }

    func testInjectedClosuresToggleTheStoreForTheCurrentTrack() {
        let favURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pe-fav-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: favURL) }
        let favorites = FavoritesStore(fileURL: favURL)
        let player = PlayerEngine()
        wire(player, favorites, appleMusicId: "am_9")

        // No current song → both closures are inert (the idle lock-screen case).
        XCTAssertFalse(player.isCurrentFavorite?() ?? true)
        player.toggleCurrentFavorite?()
        XCTAssertTrue(favorites.favoriteIds.isEmpty, "a ♥ with no current track is a no-op")

        // Load a track (sets nowPlayingSongId) — the URL never has to actually play for the
        // favorite path, which keys only on the id.
        let dummy = FileManager.default.temporaryDirectory.appendingPathComponent("none.mp3")
        player.load(url: dummy, live: false, startMs: nil, title: "Neon", artist: "Aria", songId: "sng_9")

        XCTAssertFalse(player.isCurrentFavorite?() ?? true, "starts unfavorited")
        player.toggleCurrentFavorite?()
        XCTAssertTrue(favorites.isFavorite("sng_9"))
        XCTAssertTrue(player.isCurrentFavorite?() ?? false)
        XCTAssertEqual(favorites.entry("sng_9")?.appleMusicId, "am_9",
                       "the catalog id rides the toggle for the owner-gated push")

        // Re-pushing the card (the observer's refreshFavoriteState path) must not crash and leaves
        // the state intact.
        player.refreshFavoriteState()
        XCTAssertTrue(favorites.isFavorite("sng_9"))

        player.toggleCurrentFavorite?()
        XCTAssertFalse(favorites.isFavorite("sng_9"), "second tap un-favorites")
        player.stop()
    }

    /// A track with NO Apple Music id (vinyl / My Digital / Studio) still favorites — local-only.
    func testLocalOnlyTrackFavoritesWithNilCatalogId() {
        let favURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pe-fav2-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: favURL) }
        let favorites = FavoritesStore(fileURL: favURL)
        let player = PlayerEngine()
        wire(player, favorites, appleMusicId: nil)

        let dummy = FileManager.default.temporaryDirectory.appendingPathComponent("none.mp3")
        player.load(url: dummy, live: false, startMs: nil, title: "Vinyl Cut", artist: "Local", songId: "vinyl_1")
        player.toggleCurrentFavorite?()
        XCTAssertTrue(favorites.isFavorite("vinyl_1"))
        XCTAssertNil(favorites.entry("vinyl_1")?.appleMusicId, "local-only favorite carries no catalog id")
        player.stop()
    }

    /// FIX 5(a) — the lock-screen ♥ FILL (`likeCommand.isActive`) tracks the current track's favorite
    /// state on every card write, and (FIX 2) resets to false when the card is cleared so a favorited
    /// track's filled heart can't bleed into the next owner / the idle lock screen.
    func testLikeCommandIsActiveTracksFavoriteAndResetsOnClear() {
        let favURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pe-active-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: favURL) }
        let favorites = FavoritesStore(fileURL: favURL)
        let player = PlayerEngine()
        wire(player, favorites, appleMusicId: "am_a")
        let like = MPRemoteCommandCenter.shared().likeCommand

        // load() claims the arbiter (PlayerEngine owns the card) and pushes the card → the fill mirrors
        // the (currently absent) favorite.
        let dummy = FileManager.default.temporaryDirectory.appendingPathComponent("none.mp3")
        player.load(url: dummy, live: false, startMs: nil, title: "Neon", artist: "Aria", songId: "sng_a")
        player.refreshFavoriteState()
        XCTAssertFalse(like.isActive, "non-favorite → outline ♥")

        // Favoriting + re-pushing the card fills the ♥ …
        player.toggleCurrentFavorite?()
        player.refreshFavoriteState()
        XCTAssertTrue(like.isActive, "favorited current track → filled ♥")

        // … and un-favoriting empties it again.
        player.toggleCurrentFavorite?()
        player.refreshFavoriteState()
        XCTAssertFalse(like.isActive, "un-favorited → outline ♥")

        // Re-favorite, then STOP: clearing the card must reset the fill (FIX 2) even though the track
        // was favorited, so the next owner / idle screen doesn't inherit a stale filled heart.
        player.toggleCurrentFavorite?()
        player.refreshFavoriteState()
        XCTAssertTrue(like.isActive)
        player.stop()
        XCTAssertFalse(like.isActive, "clearNowPlayingInfo resets the ♥ fill on resign")
    }

    /// FIX 5(b) — the ♥ handler is guarded by the SAME single-owner arbiter check as play/pause: it only
    /// services the like while PlayerEngine OWNS the card. A second uncoordinated owner (the Mix engine,
    /// the "ghost second card" case) must be REJECTED (`.commandFailed`) and must NOT flip the favorite.
    func testLikeCommandHandlerRejectsWhenNotCardOwner() {
        let favURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pe-owner-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: favURL) }
        let favorites = FavoritesStore(fileURL: favURL)
        let player = PlayerEngine()
        wire(player, favorites, appleMusicId: "am_b")

        let dummy = FileManager.default.temporaryDirectory.appendingPathComponent("none.mp3")
        player.load(url: dummy, live: false, startMs: nil, title: "Owned", artist: "DJ", songId: "sng_b")

        // Owner + wired → the handler services the like.
        XCTAssertEqual(player.handleLikeCommand(), .success, "owner services the ♥")
        XCTAssertTrue(favorites.isFavorite("sng_b"))

        // A SECOND owner takes the card (mirrors a Mix deck starting). Held strongly for the test — the
        // arbiter's owner ref is weak. The ♥ handler must now reject and leave the favorite untouched.
        let mixLike: AnyObject = NSObject()
        NowPlayingArbiter.shared.claim(mixLike)
        XCTAssertFalse(NowPlayingArbiter.shared.isActive(player), "PlayerEngine no longer owns the card")
        XCTAssertEqual(player.handleLikeCommand(), .commandFailed, "non-owner ♥ is rejected")
        XCTAssertTrue(favorites.isFavorite("sng_b"), "rejected handler did NOT flip the favorite")

        // Reclaim (PlayerEngine plays again) → the handler services the like once more.
        NowPlayingArbiter.shared.claim(player)
        XCTAssertEqual(player.handleLikeCommand(), .success, "owner services the ♥ again after reclaim")
        XCTAssertFalse(favorites.isFavorite("sng_b"), "second successful tap un-favorites")

        // An unwired handler (no injected closure) also fails, never crashing.
        player.toggleCurrentFavorite = nil
        XCTAssertEqual(player.handleLikeCommand(), .commandFailed, "no toggle closure → rejected")
        withExtendedLifetime(mixLike) {}
        player.stop()
    }

    /// FIX 5(c) — the ♥ ENABLEMENT follows card ownership, mirroring the ⏭/⏮ dance: PlayerEngine
    /// re-enables `likeCommand` on every claim; while another owner (the Mix card) holds the card the
    /// command is disabled; reclaiming heals it. (The Mix-side disable lives in MixEngine.updateSystem-
    /// NowPlaying, which needs the live audio graph — flaky headless — so its effect is SIMULATED here.)
    func testLikeCommandEnablementFollowsCardOwnership() {
        let favURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pe-enable-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: favURL) }
        let favorites = FavoritesStore(fileURL: favURL)
        let player = PlayerEngine()
        wire(player, favorites)
        let like = MPRemoteCommandCenter.shared().likeCommand

        let dummy = FileManager.default.temporaryDirectory.appendingPathComponent("none.mp3")
        player.load(url: dummy, live: false, startMs: nil, title: "Enabled", artist: "DJ", songId: "sng_c")
        XCTAssertTrue(like.isEnabled, "PlayerEngine claim enables the ♥")

        // Simulate the Mix taking the card: it claims the arbiter and DISABLES the shared like command
        // (exactly what MixEngine.updateSystemNowPlaying now does).
        let mixLike: AnyObject = NSObject()
        NowPlayingArbiter.shared.claim(mixLike)
        like.isEnabled = false
        XCTAssertFalse(like.isEnabled, "Mix card → ♥ disabled")
        XCTAssertFalse(NowPlayingArbiter.shared.isActive(player))

        // PlayerEngine reclaims (a row ▶ / setlist track starts) → the ♥ is HEALED back on.
        player.play()
        XCTAssertTrue(NowPlayingArbiter.shared.isActive(player), "PlayerEngine reclaimed the card")
        XCTAssertTrue(like.isEnabled, "reclaim re-enables the ♥")
        withExtendedLifetime(mixLike) {}
        player.stop()
    }
}
