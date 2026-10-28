state: reviewed

# SURF-7 - Glance Now Playing widget
Tests: 3702 total, 0 failed (+19 new in the implementation pass... JVM). assembleDebug green.

- [x] NowPlayingSnapshot (iOS keys + additive `favoriteAvailable`), store (write-if-changed, atomic), PendingWidgetCommands, WidgetSync (cover token discipline)
- [x] Glance widget: small/medium/large + idle; transport via ACTION_MEDIA_BUTTON actionStartService; ♥/repeat/shuffle via WidgetActionReceiver
- [x] WidgetBridge (new file) wired from ShellGraph: inputs flow, Coil cover fetch, live executor, widgetDrain on foreground
- [x] Manifest receivers, appwidget info, vector glyph drawables, widget_strings.xml

## Deviations / notes
- Extra files: widget/WidgetBridge.kt, widget/WidgetModelTest, res/values/widget_strings.xml, res/drawable/ic_widget_*.xml.
- Pending queue is an atomic JSON file (filesDir/widget/pending-commands.json), not DataStore.
- "Process dead" = no WidgetCommandBus.executor (set when ShellGraph starts the bridge); no AppGraph edit.
- Repeat/shuffle commands are transport-class (expire 20 s); favorite/verdicts never. Favorite carries desired state, applied idempotently.
- Dead-process taps are shown optimistically in the snapshot.
- recVerdict/recScope always "" (no For You verdicts on Android); thumbs absent.
- Build needed -Pkotlin.compiler.execution.strategy=in-process (shared Kotlin daemon OOM under parallel agents).
- Not verified on emulator (forbidden): widget rendering, service start from media-button.

## Questions for Levi
- None blocking.

## Review
Tests after fixes: 3705 total, 0 failed (+3 over 3702: 2 WidgetSyncPublish, 1 WidgetFilesSingleton). assembleDebug green. fixes applied.
- MAJOR NowPlayingWidget stale session: fixed. Snapshot and cover now read inside the composition, keyed on a Preferences version bumped by refreshNowPlayingWidget() (updateAppWidgetState + update).
- MAJOR WidgetSync blocking collector: fixed. Cover fetch runs in its own job, cancelled on identity change; token check kept. New test drives start() with a MutableStateFlow.
- MAJOR drain on cold start: fixed. start() drains once immediately after installing the executor.
- MAJOR foreground-service start for NEXT/PREVIOUS: fixed. Only play/pause is a foreground start; NEXT/PREVIOUS go through WidgetActionReceiver (live: sequencer, dead: queued with 20 s TTL). Device-only verification still owed.
- MINOR catalog not in combine: fixed. Catalog added to the combine; `artSourceReady` is part of the cover identity, so the fetch is retried when the catalog lands (test added).
- MINOR switchboard ownership: fixed. Widget goes idle while the switchboard owner engine is "mix" (polled 1 s). Exo and Apple Music engines remain setlist audio.
- MINOR store/queue instances: fixed. WidgetFiles returns process-wide singletons (shared lock and lastEncoded cache).
- MINOR ARCHITECTURE-ANDROID.md ledger: fixed. SURF-7 row is PARTIAL.
- NIT atomic favorite: fixed. FavoritesAccess.set used.
- NIT test count: fixed (19).
