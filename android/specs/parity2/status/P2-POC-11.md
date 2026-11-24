state: implemented

# P2-POC-11 Motion engine

- [x] MotionSettle (verbatim port), MotionTimelineStore, ListeningMotionStore, ActivityTransitionSource, receivers
- [x] Manifest (ACTIVITY_RECOGNITION, RECEIVE_BOOT_COMPLETED, receivers), debug manifest exports transition receiver for adb
- [x] PocketsGraph wiring (motionStore/motionTimeline, motionNow, wheel clear, start re-register + settle), AppLifecycleObserver.motionSettle hook
- [x] Tests: MotionSettleTest, MotionTimelineStoreTest, ManifestPermissionsTest
- [x] testDebugUnitTest + assembleDebug + assembleRelease green; 661 test classes, new tests: MotionSettleTest 11, MotionTimelineStoreTest 8, ManifestPermissionsTest +1 (4 total). Total new: 20

## Notes / deviations
- Foreground settle is a companion hook `AppLifecycleObserver.motionSettle` (installed by PocketsGraph.start()) instead of editing PocketDjApplication's hook list.
- Debug builds: debug manifest re-declares MotionTransitionReceiver exported=true so `adb shell am broadcast -n .../.data.motion.MotionTransitionReceiver --es pdj.motionFake WALKING` works; release stays exported=false and ignores the fake extra.
- Settings UI / prominent-disclosure dialog is NOT in this package (not in owned files); setEnabled expects the caller to have obtained the permission.

## Questions for Levi
- None.
