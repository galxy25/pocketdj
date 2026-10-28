state: implemented

# SURF-7 - Glance Now Playing widget
Tests: 3702 total, 0 failed (+22 new: Codec 5, PendingWidgetCommands 6, WidgetSyncPublish 6, WidgetModel 4... JVM). assembleDebug green.

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
