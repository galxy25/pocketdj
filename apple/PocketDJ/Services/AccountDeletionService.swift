import Foundation
import Observation
import os

/// Account-deletion orchestrator — App Store Review Guideline 5.1.1(v).
///
/// PocketDJ has NO server-side account. A "user" is the union of four things:
///   1. private-CloudKit `PDJDoc` records — the synced session documents (`CloudSyncService`),
///   2. local single-file JSON documents in Application Support (collections, favorites,
///      history, the durable playback / mix-deck / mix-session snapshots, the profile, …),
///   3. on-disk media (burned songs + sidecars, studio samples/loops/sequences/takes) and the
///      Keychain-held streaming tokens, and
///   4. the synced profile identity plus the per-install device id.
///
/// `deleteAccountAndAllData()` removes ALL of it, in a deliberately safe order, BEST-EFFORT:
/// a failure in any single step — a store throwing, iCloud being offline or signed out — is
/// logged and the remaining steps still run, so the user always lands on a genuinely clean
/// device. The local wipe never depends on the cloud delete succeeding (the confirmation copy
/// is honest that the cloud copies are removed "now", from the signed-in private database).
///
/// Order invariants (load-bearing):
///   • the CloudKit delete runs BEFORE the local wipe — "remove the cloud copies" stays ahead
///     of "forget everything locally";
///   • settings are reset AFTER the media stores are cleared — BurnStore / MixSessionStore /
///     StudioStore read the user-picked folder bookmarks out of `SettingsStore`, so resetting
///     settings first would strip those bookmarks and strand the media on disk; and
///   • the identity reset (fresh profile id + forgotten device id) is LAST, so a re-created
///     account starts from a clean identity with nothing left pointing at the deleted one.
///
/// Every dependency is injected (PocketDJApp constructs this with the live stores) — the
/// orchestrator reaches for no globals of its own. `@Observable` only so it can ride the
/// SwiftUI environment into `SettingsView`; it holds no observable state.
@MainActor
@Observable
final class AccountDeletionService {

    /// The private-CloudKit `PDJDoc` record keys removed on account deletion — the EXACT set
    /// registered with `CloudSyncService` in `PocketDJApp.init` (the `cloudSync.register(…)`
    /// block). Must stay in lockstep with that registry: a newly-synced document has to be
    /// added here too, or its cloud copy would survive an account deletion.
    static let cloudDocKeys: [String] = [
        "profile", "collections", "edits", "favorites", "play-stats", "play-history",
        "collection-activity", "mix-sessions", "playback-session", "mix-decks",
        "discover-adds", "imported-songs", "profile-source", "apple-music-library", "studio-cues",
        "game-scores", "puzzle-decisions", "rec-key",
    ]

    /// Recommendation-engine wipe seams (WS-E), wired in PocketDJApp. Optional so tests that
    /// construct the service without the rec engine degrade to a no-op:
    ///  • `recDeleteCloudData` — DELETE of the profile's server-side rec state (needs the live
    ///    key, so it runs BEFORE the local wipe removes it). It RETURNS whether the delete
    ///    landed: unlike the CloudKit deletes above (the user's own iCloud account, which
    ///    self-heals), this state lives in the developer's S3 bucket with no lifecycle expiry,
    ///    so a swallowed failure orphans it permanently. Absent seam ⇒ `true` (nothing owed).
    ///  • `recClearLocal` — removes the cursor document AND the key document; when the cloud
    ///    delete failed, the credential first moves into a device-local tombstone (key + the
    ///    profile id the delete must target) so a later launch can finish the erasure — a
    ///    re-enable meanwhile mints a FRESH identity instead of resurrecting the erased one.
    var recDeleteCloudData: (() async -> Bool)?
    var recClearLocal: ((_ cloudDeleted: Bool) -> Void)?

    private static let log = Logger(subsystem: "com.levi.pocketdj", category: "account-deletion")

    // Live activity (stopped first).
    private let jukebox: JukeboxStore
    private let setlistPlayer: SetlistPlayer
    private let mix: MixEngine
    /// Cancel all in-flight background transfers. Wired in PocketDJApp to
    /// `TransferCoordinator.shared.cancelAll()` — the coordinator is a process-wide singleton,
    /// so the global reach lives in the wiring, not in this service.
    private let cancelTransfers: () -> Void

    // Cloud copies.
    private let cloudDatabase: any CloudDocDatabase
    /// Whether the CloudKit delete may run. Wired to `{ !fixtureRun }` so UI-test runs
    /// (PDJ_USE_FIXTURE) never touch a real iCloud account. NOT gated on the sync toggle: a
    /// full account deletion must remove any cloud copies even if the user turned sync off.
    private let cloudDeleteEnabled: () -> Bool

    // Local stores.
    private let collections: CollectionsStore
    private let favorites: FavoritesStore
    private let playStats: PlayStatsStore
    private let playHistory: PlayHistoryStore
    private let collectionActivity: CollectionActivityStore
    private let edits: EditsStore
    private let discoverAdds: DiscoverAddsStore
    private let importedSongs: ImportedSongsStore
    /// The on-device Apple Music library index (cloud key "apple-music-library").
    private let appleMusicLibrary: AppleMusicLibraryStore
    /// The per-profile "Pocket DJ" custom-audio source. A real synced store (cloud key
    /// "profile-source", step 2) that ALSO owns durable on-disk media — its `clear()` purges both
    /// the JSON and `profile-audio/` (originals + stems), so it must be wiped in step 3 like every
    /// other local store.
    private let profileSource: ProfileSourceStore
    private let playlistWriteBack: PlaylistWriteBack
    private let mixSessions: MixSessionStore
    private let playbackSession: PlaybackSessionStore
    private let mixDeckSession: MixDeckSessionStore
    private let burns: BurnStore
    private let studio: StudioStore
    /// Games: the durable run scoreboard (cloud key "game-scores").
    private let gameScores: GameScoreboardStore
    /// Games: the Collectors Puzzle decision log — per-song behavioral data
    /// (cloud key "puzzle-decisions").
    private let puzzleDecisions: PuzzleDecisionStore
    /// The recommendation accept/reject log (cloud key "rec-feedback") — per-song behavioral data
    /// exactly like the puzzle log, so it is erased on the same terms. A SEAM rather than a
    /// constructor parameter for the reason `recClearLocal` already is: this service's fixed
    /// store list has to stay test-buildable without the recommendation graph.
    var recFeedbackClear: (() -> Void)?
    /// Games: Music with Friends session entries (bearer memberKeys/leaderKeys live in
    /// UserDefaults, not a synced doc — but they are account data all the same).
    private let friends: MusicWithFriendsStore

    // Keychain (streaming account links) + settings + cloud-sync state + identity.
    private let streaming: StreamingStore
    private let settings: SettingsStore
    private let cloudSync: CloudSyncService
    private let profile: ProfileStore

    init(jukebox: JukeboxStore,
         setlistPlayer: SetlistPlayer,
         mix: MixEngine,
         cancelTransfers: @escaping () -> Void,
         cloudDatabase: any CloudDocDatabase,
         cloudDeleteEnabled: @escaping () -> Bool,
         collections: CollectionsStore,
         favorites: FavoritesStore,
         playStats: PlayStatsStore,
         playHistory: PlayHistoryStore,
         collectionActivity: CollectionActivityStore,
         edits: EditsStore,
         discoverAdds: DiscoverAddsStore,
         importedSongs: ImportedSongsStore,
         appleMusicLibrary: AppleMusicLibraryStore,
         profileSource: ProfileSourceStore,
         playlistWriteBack: PlaylistWriteBack,
         mixSessions: MixSessionStore,
         playbackSession: PlaybackSessionStore,
         mixDeckSession: MixDeckSessionStore,
         burns: BurnStore,
         studio: StudioStore,
         gameScores: GameScoreboardStore,
         puzzleDecisions: PuzzleDecisionStore,
         friends: MusicWithFriendsStore,
         streaming: StreamingStore,
         settings: SettingsStore,
         cloudSync: CloudSyncService,
         profile: ProfileStore) {
        self.jukebox = jukebox
        self.setlistPlayer = setlistPlayer
        self.mix = mix
        self.cancelTransfers = cancelTransfers
        self.cloudDatabase = cloudDatabase
        self.cloudDeleteEnabled = cloudDeleteEnabled
        self.collections = collections
        self.favorites = favorites
        self.playStats = playStats
        self.playHistory = playHistory
        self.collectionActivity = collectionActivity
        self.edits = edits
        self.discoverAdds = discoverAdds
        self.importedSongs = importedSongs
        self.appleMusicLibrary = appleMusicLibrary
        self.profileSource = profileSource
        self.playlistWriteBack = playlistWriteBack
        self.mixSessions = mixSessions
        self.playbackSession = playbackSession
        self.mixDeckSession = mixDeckSession
        self.burns = burns
        self.studio = studio
        self.gameScores = gameScores
        self.puzzleDecisions = puzzleDecisions
        self.friends = friends
        self.streaming = streaming
        self.settings = settings
        self.cloudSync = cloudSync
        self.profile = profile
    }

    /// Delete the account and every trace of the user's data. Idempotent-ish and total: safe to
    /// run to completion regardless of iCloud state, and every step runs even if an earlier one
    /// fails. See the type doc for the order rationale.
    func deleteAccountAndAllData() async {
        Self.log.notice("Account deletion started")

        // ── 1) STOP LIVE ACTIVITY ────────────────────────────────────────────
        // End any Jukebox session (also drops the guest broker), stop the app-scoped sequencer
        // (which internally stops the player + coordinator AND clears the durable playback
        // session), eject both Mix decks (which clears the durable mix-deck session), and cancel
        // every in-flight background transfer. Nothing here throws; `jukebox.end` swallows its
        // own network error internally.
        await jukebox.end()
        setlistPlayer.stop()
        mix.ejectAll()
        cancelTransfers()

        // ── 2) DELETE THE CLOUD COPIES (before the local wipe) ───────────────
        // Every private-CloudKit PDJDoc record. Best-effort: no account / iCloud offline
        // throws here — we log and press on so the local wipe still completes. The delete is
        // idempotent (already-gone records are success), so a partial cloud state never fails.
        if cloudDeleteEnabled() {
            do {
                try await cloudDatabase.deleteAll(Self.cloudDocKeys)
                Self.log.notice("Deleted \(Self.cloudDocKeys.count, privacy: .public) CloudKit documents")
            } catch {
                Self.log.error("CloudKit deletion failed (continuing local wipe): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            Self.log.notice("CloudKit deletion skipped (disabled / test run)")
        }
        // Recommendation-engine server state: must run while the bearer key still exists
        // locally. NOT best-effort-and-forget — the result decides whether the local key can be
        // erased (see the seam docs); a failure here leaves a retry tombstone instead.
        let recCloudDeleted = await recDeleteCloudData?() ?? true
        if !recCloudDeleted {
            Self.log.error("Rec-engine cloud delete failed — tombstoned for retry on a later launch")
        }

        // ── 3) CLEAR EVERY LOCAL STORE ───────────────────────────────────────
        // All non-throwing by contract, so one can never skip the next; each resets its
        // @Observable state AND deletes its persisted file/media. Snapshot the session-folder
        // bookmark BEFORE settings are reset (step 5 strips it) so MixSessionStore can still
        // reach + delete captured recordings that live in a user-picked folder.
        let sessionBookmark = settings.sessionFolderBookmark
        collections.clear()
        favorites.clear()
        playStats.clear()
        playHistory.clear()
        collectionActivity.clear()
        edits.clearAll()
        discoverAdds.clear()
        importedSongs.clear()
        appleMusicLibrary.clear()
        profileSource.clear()        // wipes both the JSON metadata AND profile-audio/ (originals + stems)
        playlistWriteBack.clear()
        mixSessions.clear(bookmark: sessionBookmark)
        playbackSession.clear()      // idempotent with setlistPlayer.stop()'s own clear
        mixDeckSession.clear()       // idempotent with mix.ejectAll()'s own clear
        burns.removeAllBurns()
        for family in StudioFamily.allCases { studio.deleteAll(family: family) }
        studio.clearCues()   // the synced "studio-cues" doc — deleting the cloud copy must wipe local too
        gameScores.clear()       // the synced "game-scores" doc
        puzzleDecisions.clear()  // the synced "puzzle-decisions" doc — per-song behavioral data
        recFeedbackClear?()      // the synced "rec-feedback" doc — the 👍/👎 tuning log
        // Music with Friends: session entries carry bearer memberKeys/leaderKeys; the scored
        // set and cached states are per-account too. WITHDRAW the APNs device tokens FIRST —
        // they are personal data sitting on a broker the user may not own, and only the
        // memberKeys `eraseAll()` is about to destroy can authorize the retraction. Bounded
        // and best-effort (a dead broker costs one 6 s timeout; the registration would then
        // die with the session's 24 h TTL anyway).
        await friends.unregisterPushEverywhere()
        friends.eraseAll()
        recClearLocal?(recCloudDeleted)   // rec-engine cursor doc (+ the key IF the cloud delete landed)

        // ── 4) CLEAR THE KEYCHAIN (streaming account links) ──────────────────
        // Each provider's `logout()` severs the link and forgets its stored token — for a
        // future OAuth provider that is exactly its `StreamingTokenStore.clear()` (Keychain).
        streaming.providers.forEach { $0.logout() }

        // ── 5) RESET SETTINGS ────────────────────────────────────────────────
        // Sources, rip / search / jukebox config, cached covers + catalog disk cache — and
        // (load-bearing here) re-arm the zero-to-hero onboarding flow for the next launch via
        // `OnboardingStore.markPendingAfterReset`. Runs AFTER the media stores above, which read
        // the folder bookmarks this clears.
        settings.resetEverything()

        // ── 6) CLEAR LOCAL CLOUD-SYNC STATE ──────────────────────────────────
        // Drop the in-sync watermark, delete the state file, and sweep the `.pre-cloud` backups,
        // so a just-erased document can't be resurrected off a stale watermark or a leftover
        // backup. (The cloud documents themselves went in step 2; this touches no CloudKit.)
        cloudSync.clearLocalSyncState()

        // ── 7) RESET IDENTITY — LAST ─────────────────────────────────────────
        // Mint a brand-new profile id (empty name, fresh createdAt) and forget the per-install
        // device id, so a re-created account presents to the backend as a clean, brand-new user
        // with nothing tying back to the deleted one. The MwF re-join secret is identity too:
        // its sha256 lives in broker session files, and a surviving secret would re-bind the
        // deleted account's memberId/display-name on the next join of a previously joined
        // session.
        profile.reset()
        DeviceIdentity.reset()
        MwFJoinSecret.reset()

        Self.log.notice("Account deletion complete")
    }
}
