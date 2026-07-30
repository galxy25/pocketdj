import Foundation

/// The UNATTENDED Apple Music sync (Levi 2026-07-29: "the sync needs to be able to happen async
/// and auto resume, it's ridiculous to think a user will just sit on the sync screen every day"
/// + "add an auto sync setting with a user adjustable schedule … default to 4:20 pm").
///
/// Two halves:
///   • `isDue` — the pure daily-schedule check (fire once per day at the user's chosen local
///     time; a missed slot fires on the next launch/foreground/periodic tick after it).
///   • `runFullPass` — the same halves the pane's "⇅ Sync collections" runs, minus the UI:
///     backend (private server re-index + device-token push, or the public two-way sync +
///     library re-index) then the shared halves (converted-collections reconcile, write-back
///     backfill). Every piece is idempotent end-to-end, so unattended re-runs are safe.
enum AppleMusicAutoSync {

    /// 4:20 PM local — the default daily fire time.
    nonisolated static let defaultMinutes = 16 * 60 + 20

    /// PURE (testable): is a run due at `nowMs`, given the last completed run and the fire time
    /// (minutes past local midnight)? Due ⇔ we're past today's fire AND the last run predates it.
    nonisolated static func isDue(nowMs: Double, lastRunMs: Double?, minutesOfDay: Int,
                                  calendar: Calendar = .current) -> Bool {
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = max(0, min(minutesOfDay, 1439)) / 60
        comps.minute = max(0, min(minutesOfDay, 1439)) % 60
        guard let todayFire = calendar.date(from: comps), now >= todayFire else { return false }
        guard let lastRunMs else { return true }
        return Date(timeIntervalSince1970: lastRunMs / 1000) < todayFire
    }

    /// The full unattended pass — mirrors `AppleMusicSettingsView.runCollectionsNow(.both)`
    /// (kept in sync by hand; the view keeps its own richer status plumbing).
    @MainActor
    static func runFullPass(settings: SettingsStore,
                            collections: CollectionsStore,
                            activity: CollectionActivityStore,
                            app: AppModel,
                            musicSync: MusicSyncClient,
                            writeBack: PlaylistWriteBack?,
                            playlistSync: PlaylistAppleMusicSync?) async {
        // Backend half.
        if settings.appleMusicPrivateSync {
            if musicSync.hasServer, settings.hasAppleMusic {
                if (try? await musicSync.sync()) != nil {
                    URLCache.shared.removeCachedResponse(for: URLRequest(url: Config.appleMusicIndexURL))
                    await app.reload()
                }
            }
            if let playlistSync, playlistSync.isAvailable {
                await playlistSync.syncNow(collections: collections, app: app, direction: .push)
            }
        } else if let playlistSync, playlistSync.isAvailable {
            await playlistSync.syncNow(collections: collections, app: app, direction: .both)
            await app.refreshAppleMusicLibrary?()
        }
        // Shared halves — identical to the pane.
        _ = collections.syncConvertedCollections(with: app.indexPlaylists)
        if writeBack?.canWriteBack == true {
            _ = collections.backfillSourceWriteBacks(from: activity.events,
                                                     days: settings.writeBackBackfillDays,
                                                     localInstallId: activity.installId)
        }
    }
}
