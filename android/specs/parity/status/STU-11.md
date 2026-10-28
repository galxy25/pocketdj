state: reviewed

# STU-11 — Tracks arranger: model CRUD, home list + folders, lanes/clips UI, clip baker, artifacts browser

Summary: the Producer "Tracks" sub-tab is live. Home browser (arrangements + collapsible folders, rename/move/delete,
Bounces/Recordings artifact groups with audition / convert-to-sample / add-as-track / share / delete); an open arrangement
goes fullscreen (hides the sub-tab row via `TracksNav.arrangerFullscreen`) with header, collapsible transport on compact
(time, BPM dialog, zoom ladder + fit floor, follow toggle), beat ruler (tap seeks the cursor), lanes with draggable clips
(Beat Match snaps drops), per-track header (M/S/gain/colour/menu), add-clip picker (samples/loops/sequences/instrumentals/
stems/artifacts, searchable), TrackEditSheet (name, 8-colour grid, pan dial, pitch/tempo/EQ/FX strip).
The store CRUD core (arrangements/tracks/clips/strip setters/mutateArrangement/bpm seeding/artifact CRUD/duplicate copies clip
files) already landed in STU-1; STU-11 adds `ArtifactSampleConverter` (createSampleFromArtifact), `ArrangerClipBaker`, the pure
`ArrangerMath` timeline math and `TrackPalette`.

Tests: +23 new JVM tests (StudioStoreArrangerTest 14, ArrangerClipBakerTest 5, ClipPickerModelTest 4). Full
`:app:testDebugUnitTest :app:assembleDebug` green: 3404 tests, 0 failures.

## Checklist
- [x] StudioStoreArranger.kt: ArrangerMath (zoom ladder/fit, anchors, follow target, ruler ticks, snap/drop, pan dial), TrackPalette, ArtifactSampleConverter
- [x] ArrangerClipBaker (prepare -> import canonical AAC snapshot; bakeFromFile; SAF materialize/release seam)
- [x] TracksHomeScreen (+ TracksActions, TracksPrefs, TracksNav) / ArtifactsSection (MediaPlayer audition, share via FileProvider)
- [x] ArrangementScreen / LaneRow / BeatRuler
- [x] ClipPickerSheet / TrackEditSheet
- [x] ProducerScreen wiring (Tracks tab + fullscreen hides sub-tab row)
- [x] tests + full suite green

## Deviations / notes
- Files outside the owned list: `screens/producer/ProducerScreen.kt` (2 additive lines: Tracks branch + hide tabs while an arrangement is open); extra test `screens/producer/tracks/ClipPickerModelTest.kt`.
- No transport PLAY/record/loop/scissor/bounce/master-FX controls: those belong to STU-12 (MultitrackPlayer) and STU-13. `ArrangementScreen(playheadMs = ...)` is the seam: when non-null it drives the cursor and follow-scroll; otherwise the tap-set seek cursor is shown.
- Stems in the picker: `TracksStemSource` interface (songs + stemFiles) is the seam; no Android stem store exists yet so `TracksActions.stemSource` is null and the Stems section is hidden. STU-14/15 wires it.
- Follow-scroll uses `ArrangerMath.followScrollTarget` + a horizontalScroll state instead of ~3600 per-second anchor cells; the cursor is a real layout anchor (`tracks-cursor-anchor`, spacer flow, not an offset) for the semantics check. The anchor-count cap is still exposed (`anchorSecondsCount`) for parity.
- Clip context menu is tap-to-open (Remove clip) rather than long-press, to keep long-press/drag free of scroll conflicts.
- No automatic beat-grid analysis on open (StudioArrangerGridAnalyzer is STU-13).
- Artifacts "Share" copies to cacheDir/shared-artifacts and shares via the existing FileProvider.
- No ARCHITECTURE-ANDROID.md edit (integrator). Ledger: DONE for model/home/lanes/picker/edit/artifacts; transport playback + stems import are PARTIAL pending STU-12/14.

## Emulator steps (not run; emulator is integrator-owned)
New arrangement -> + Track -> + clip from a seeded sample -> clip renders at 0:00; zoom +/-; ruler tap moves the cursor; artifact row audition.

## Questions for Levi
- none

## Review
fixes applied

- MAJOR TracksHomeScreen back: fixed (BackHandler(enabled = current != null) closes the arrangement).
- MAJOR follow-scroll wiring untested: fixed in part. Wiring extracted to `FollowTimeline` (internal) + `CursorOverlay`; new `FollowTimelineInstrumentedTest` (androidTest, ui-test-junit4 added) asserts the cursor anchor is centred in `tracks-timeline` past the first screenful and does not scroll early. It compiles (`compileDebugAndroidTestKotlin`) but is NOT run: emulator is integrator-owned. JVM count unchanged at 3404 (no JVM Compose infra / Robolectric in the project).
- MAJOR ledger row: fixed (docs/ARCHITECTURE-ANDROID.md STU-11 -> PARTIAL with remaining items).
- MINOR audition keeps playing: fixed (audition.stop() when an arrangement opens/closes, covers delete-inside).
- MINOR silent add-clip failures: fixed (toast on all null paths; importStems and addArtifactAsTrack bake before addTrack).
- MINOR main-thread IO: fixed (prepareAsync + OnPreparedListener; share copy on Dispatchers.IO).
- MINOR ProducerScreen global flag: fixed (TracksNav removed; `onFullscreenChange` callback, per-host state). ProducerScreen.kt recorded as shared touchpoint for STU-12/13.
- NIT BPM range: fixed (Set enabled only for 20..300); pxPerSec/cursorMs now rememberSaveable.
